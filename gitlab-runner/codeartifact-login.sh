#!/usr/bin/env bash
# codeartifact-login.sh
# ──────────────────────────────────────────────────────────────────────────────
# Refreshes the AWS CodeArtifact 12h token and configures npm/pip/uv (optional: poetry/twine).
#
# Dual mode:
#   1) direct run (./codeartifact-login.sh) : runs strictly with set -euo pipefail, exits on failure.
#   2) sourced   ( . ./codeartifact-login.sh): for CI before_script.
#      - automatically calls ca_main (the caller does not need a separate call).
#      - does NOT pollute the sourcing shell's -e, and on failure it returns instead of exiting.
#        => the caller (before_script) MUST verify the token is non-empty itself:
#             . /usr/local/bin/codeartifact-login.sh
#             [ -n "${CODEARTIFACT_AUTH_TOKEN:-}" ] || { echo "CA login failed"; exit 1; }
#
# IMPORTANT (private subnet): the CodeArtifact domain is owned by the *runner account*.
# If a job has AWS_PROFILE set (a cross-account deploy role), the token call would go to
# the wrong account, so CodeArtifact calls are always made with AWS_PROFILE emptied (instance role).
# ──────────────────────────────────────────────────────────────────────────────

# Detect whether we are sourced
_ca_sourced=0
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  _ca_sourced=1
fi

# Strict mode only when run directly (avoid polluting the caller's -e when sourced)
if [[ "${_ca_sourced}" -eq 0 ]]; then
  set -euo pipefail
fi

# ==============================================================================
# Shared config header (same variable names as the companion scripts)
# ==============================================================================
AWS_REGION="${AWS_REGION:-ap-northeast-2}"
CA_DOMAIN="${CA_DOMAIN:-my-domain}"
CA_DOMAIN_OWNER="${CA_DOMAIN_OWNER:-999999999999}"   # CodeArtifact domain owner = runner account
CA_NPM_REPO="${CA_NPM_REPO:-npm-store}"
CA_PYPI_REPO="${CA_PYPI_REPO:-pypi-store}"

# Per-tool toggles
CONFIGURE_NPM="${CONFIGURE_NPM:-true}"
CONFIGURE_PIP="${CONFIGURE_PIP:-true}"
CONFIGURE_UV="${CONFIGURE_UV:-true}"
CONFIGURE_POETRY="${CONFIGURE_POETRY:-false}"
CONFIGURE_TWINE="${CONFIGURE_TWINE:-false}"

# uv named-index name (MUST match the [[tool.uv.index]] name in pyproject.toml)
# The env-var segment rule is uppercase + non-alphanumeric->underscore: private-registry -> PRIVATE_REGISTRY
UV_INDEX_NAME="${UV_INDEX_NAME:-private-registry}"

# ==============================================================================
# Utilities
# ==============================================================================
_ca_log()  { printf '\033[1;34m[ca]\033[0m %s\n' "$*"; }
_ca_warn() { printf '\033[1;33m[ca-warn]\033[0m %s\n' "$*" >&2; }

# Failure handling: exit if run directly, return if sourced (preserve exported vars).
_ca_fail() {
  printf '\033[1;31m[ca-fail]\033[0m %s\n' "$*" >&2
  if [[ "${_ca_sourced}" -eq 1 ]]; then
    return 1
  else
    exit 1
  fi
}

# Resolve HOME (safe under root/sudo/systemd)
_ca_resolve_home() {
  if [[ -n "${HOME:-}" && -d "${HOME}" ]]; then
    printf '%s' "${HOME}"
    return 0
  fi
  # when HOME is empty under systemd/cron, etc.
  local u; u="$(id -un)"
  getent passwd "${u}" | cut -d: -f6
}

# Env-var segment conversion: private-registry -> PRIVATE_REGISTRY
_ca_env_segment() {
  printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_'
}

# ==============================================================================
# Fetch token + endpoints (always as the instance role; prevent AWS_PROFILE pollution)
# ==============================================================================
ca_fetch_token_and_endpoints() {
  command -v aws >/dev/null 2>&1 || { _ca_fail "the aws CLI is missing."; return 1; }

  # Empty AWS_PROFILE to force the instance role (runner account). STS uses the regional endpoint.
  local token
  token="$(AWS_PROFILE='' AWS_STS_REGIONAL_ENDPOINTS=regional \
            aws codeartifact get-authorization-token \
              --domain "${CA_DOMAIN}" \
              --domain-owner "${CA_DOMAIN_OWNER}" \
              --region "${AWS_REGION}" \
              --query authorizationToken --output text 2>/dev/null)" || true

  if [[ -z "${token}" || "${token}" == "None" ]]; then
    _ca_fail "CodeArtifact token issuance failed. Check: sts:GetServiceBearerToken permission, codeartifact.api endpoint, AWS_PROFILE leakage."
    return 1
  fi
  export CODEARTIFACT_AUTH_TOKEN="${token}"

  CA_NPM_ENDPOINT="$(AWS_PROFILE='' aws codeartifact get-repository-endpoint \
      --domain "${CA_DOMAIN}" --domain-owner "${CA_DOMAIN_OWNER}" \
      --repository "${CA_NPM_REPO}" --format npm \
      --region "${AWS_REGION}" --query repositoryEndpoint --output text 2>/dev/null)" || true
  CA_PYPI_ENDPOINT="$(AWS_PROFILE='' aws codeartifact get-repository-endpoint \
      --domain "${CA_DOMAIN}" --domain-owner "${CA_DOMAIN_OWNER}" \
      --repository "${CA_PYPI_REPO}" --format pypi \
      --region "${AWS_REGION}" --query repositoryEndpoint --output text 2>/dev/null)" || true

  if [[ -z "${CA_NPM_ENDPOINT:-}" || "${CA_NPM_ENDPOINT}" == "None" ]]; then
    _ca_fail "npm repo endpoint lookup failed (check the codeartifact.api endpoint/permissions)."; return 1
  fi
  if [[ -z "${CA_PYPI_ENDPOINT:-}" || "${CA_PYPI_ENDPOINT}" == "None" ]]; then
    _ca_fail "pypi repo endpoint lookup failed."; return 1
  fi
  export CA_NPM_ENDPOINT CA_PYPI_ENDPOINT
  _ca_log "fetched token/endpoints (npm=${CA_NPM_ENDPOINT}, pypi=${CA_PYPI_ENDPOINT})"
  return 0
}

# ==============================================================================
# npm (.npmrc)
# ==============================================================================
ca_configure_npm() {
  [[ "${CONFIGURE_NPM}" == "true" ]] || return 0
  local home host
  home="$(_ca_resolve_home)"
  # strip the scheme from the registry URL -> build the //host/path/ authToken key
  host="${CA_NPM_ENDPOINT#https://}"

  umask 077
  cat > "${home}/.npmrc" <<EOF
registry=${CA_NPM_ENDPOINT}
//${host}:_authToken=${CODEARTIFACT_AUTH_TOKEN}
//${host}:always-auth=true
# scoped package example:
# @myorg:registry=${CA_NPM_ENDPOINT}
EOF
  chmod 600 "${home}/.npmrc"
  _ca_log "npm configured: ${home}/.npmrc"
}

# ==============================================================================
# pip (~/.config/pip/pip.conf) — keep the token only in the conf file (600), do not export via env.
# (Exporting via PIP_INDEX_URL would leak the token to logs under CI_DEBUG_TRACE/set -x.)
# ==============================================================================
ca_configure_pip() {
  [[ "${CONFIGURE_PIP}" == "true" ]] || return 0
  local home host enc_token index_url cfg_dir
  home="$(_ca_resolve_home)"
  host="${CA_PYPI_ENDPOINT#https://}"
  host="${host%/}"

  # Safely URL-encode the token as URL userinfo (in the rare case of URL-unsafe chars)
  if command -v python3 >/dev/null 2>&1; then
    enc_token="$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "${CODEARTIFACT_AUTH_TOKEN}")"
  else
    enc_token="${CODEARTIFACT_AUTH_TOKEN}"
  fi

  # the pip index-url must end with /simple/.
  index_url="https://aws:${enc_token}@${host}/simple/"

  cfg_dir="${home}/.config/pip"
  install -d -m 700 "${cfg_dir}"
  umask 077
  cat > "${cfg_dir}/pip.conf" <<EOF
[global]
index-url = ${index_url}
EOF
  chmod 600 "${cfg_dir}/pip.conf"
  # also block group/other read on the parent directory
  chmod 700 "${home}/.config" 2>/dev/null || true
  # explicitly do NOT export PIP_INDEX_URL (prevent token log leakage).
  unset PIP_INDEX_URL || true
  _ca_log "pip configured: ${cfg_dir}/pip.conf (token not exposed via env)"
}

# ==============================================================================
# uv (named index + credentials; UV_DEFAULT_INDEX replaces PyPI)
# uv matches UV_INDEX_<NAME>_USERNAME/PASSWORD only against a *named* index.
# So we name the index via UV_INDEX="name=url" and supply credentials using the same NAME segment.
# ==============================================================================
ca_configure_uv() {
  [[ "${CONFIGURE_UV}" == "true" ]] || return 0
  local host index_url seg
  host="${CA_PYPI_ENDPOINT#https://}"
  host="${host%/}"
  index_url="https://${host}/simple/"
  seg="$(_ca_env_segment "${UV_INDEX_NAME}")"   # private-registry -> PRIVATE_REGISTRY

  # define the named index + set it as the default index (replacing public PyPI)
  export UV_INDEX="${UV_INDEX_NAME}=${index_url}"
  export UV_DEFAULT_INDEX="${index_url}"
  # credentials using the same name segment (UV_INDEX_PRIVATE_REGISTRY_USERNAME/PASSWORD)
  export "UV_INDEX_${seg}_USERNAME=aws"
  export "UV_INDEX_${seg}_PASSWORD=${CODEARTIFACT_AUTH_TOKEN}"

  if [[ "${_ca_sourced}" -eq 0 ]]; then
    _ca_warn "uv env vars are exported to the *current shell* only. In CI, 'source' this script."
  fi
  _ca_log "uv configured (index name='${UV_INDEX_NAME}'; the index name in pyproject must match)"
}

# ==============================================================================
# poetry (optional) — POETRY_HTTP_BASIC_* (propagated only when sourced)
# ==============================================================================
ca_configure_poetry() {
  [[ "${CONFIGURE_POETRY}" == "true" ]] || return 0
  local host
  host="${CA_PYPI_ENDPOINT#https://}"; host="${host%/}"
  # assumes the poetry repository name is 'private' (must match the source name in pyproject)
  export POETRY_REPOSITORIES_PRIVATE_URL="https://${host}/simple/"
  export POETRY_HTTP_BASIC_PRIVATE_USERNAME="aws"
  export POETRY_HTTP_BASIC_PRIVATE_PASSWORD="${CODEARTIFACT_AUTH_TOKEN}"
  if [[ "${_ca_sourced}" -eq 0 ]]; then
    _ca_warn "poetry env vars only propagate when sourced."
  fi
  _ca_log "poetry configured (assumes source name 'private')"
}

# ==============================================================================
# twine (optional) — ~/.pypirc
# ==============================================================================
ca_configure_twine() {
  [[ "${CONFIGURE_TWINE}" == "true" ]] || return 0
  local home host
  home="$(_ca_resolve_home)"
  host="${CA_PYPI_ENDPOINT#https://}"; host="${host%/}"
  umask 077
  cat > "${home}/.pypirc" <<EOF
[distutils]
index-servers = codeartifact

[codeartifact]
repository = https://${host}/
username = aws
password = ${CODEARTIFACT_AUTH_TOKEN}
EOF
  chmod 600 "${home}/.pypirc"
  _ca_log "twine configured: ${home}/.pypirc"
}

# ==============================================================================
# main
# ==============================================================================
ca_main() {
  ca_fetch_token_and_endpoints || return 1
  ca_configure_npm    || return 1
  ca_configure_pip    || return 1
  ca_configure_uv     || return 1
  ca_configure_poetry || return 1
  ca_configure_twine  || return 1
  # success sentinel (the caller can verify it)
  export CA_LOGIN_OK=1
  _ca_log "CodeArtifact login complete (token TTL max 12h — must be re-run per job)."
  return 0
}

# Dispatch: both direct run and source call ca_main.
# When sourced, a ca_main failure is handled via return and exported vars are preserved.
# (before_script must verify success itself via CODEARTIFACT_AUTH_TOKEN/CA_LOGIN_OK)
ca_main || _ca_fail "failed during CodeArtifact setup"

# ──────────────────────────────────────────────────────────────────────────────
# (optional) systemd timer backup — before_script is the primary refresh path, the timer is a backup.
#  /etc/systemd/system/codeartifact-login.service:
#    [Unit]
#    Description=Refresh CodeArtifact token
#    [Service]
#    Type=oneshot
#    User=gitlab-runner
#    Environment=AWS_REGION=ap-northeast-2
#    Environment=CA_DOMAIN=my-domain
#    Environment=CA_DOMAIN_OWNER=999999999999
#    ExecStart=/usr/local/bin/codeartifact-login.sh
#  /etc/systemd/system/codeartifact-login.timer:
#    [Unit]
#    Description=Refresh CodeArtifact token every 6h
#    [Timer]
#    OnBootSec=2min
#    OnUnitActiveSec=6h
#    Persistent=true
#    [Install]
#    WantedBy=timers.target
#  systemctl enable --now codeartifact-login.timer
# ──────────────────────────────────────────────────────────────────────────────
