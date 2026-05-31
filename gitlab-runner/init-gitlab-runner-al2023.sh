#!/usr/bin/env bash
# init-gitlab-runner-al2023.sh
# ──────────────────────────────────────────────────────────────────────────────
# AL2023 EC2 GitLab Runner bootstrap (shell executor + mise + host Docker)
#
# Target: a GitLab Runner host running in a private subnet (no Internet Gateway /
#         NAT egress; VPC endpoints only).
#
# Core design:
#   - GOLDEN_AMI=true  : based on an AMI pre-baked in a build account that has egress.
#                        Steps requiring a download are SKIPPED; only the presence of
#                        pre-installed tools is verified.
#                        (die if mise/aws/gitlab-runner/docker/git are missing)
#   - GOLDEN_AMI=false : perform the actual downloads/installs in a build account that
#                        has egress.
#
#   - The shell executor runs jobs in a non-login bash. A non-login bash does NOT read
#     /etc/profile or /etc/profile.d/*.sh, so runtimes (PATH/mise shims) are injected
#     via config.toml's environment[] (BASH_ENV/MISE_DATA_DIR/MISE_CONFIG_DIR).
#     /etc/profile.d/mise.sh is only a convenience for humans logging in via SSM.
#
# Idempotency: every download must pass the need_egress gate, and re-runs are safe.
# Passes bash -n, chmod +x.
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ==============================================================================
# Shared config header (keep variable names identical to the companion scripts)
# ==============================================================================
AWS_REGION="${AWS_REGION:-ap-northeast-2}"
RUNNER_ACCOUNT_ID="${RUNNER_ACCOUNT_ID:-999999999999}"   # account the runner lives in (owns the CodeArtifact domain)

# CodeArtifact (owned by the runner account)
CA_DOMAIN="${CA_DOMAIN:-my-domain}"
CA_DOMAIN_OWNER="${CA_DOMAIN_OWNER:-$RUNNER_ACCOUNT_ID}"
CA_NPM_REPO="${CA_NPM_REPO:-npm-store}"
CA_PYPI_REPO="${CA_PYPI_REPO:-pypi-store}"

# GitLab
GITLAB_URL="${GITLAB_URL:-https://gitlab.example.com}"
# glrt-* authentication token (legacy registration-token was removed in GitLab 18.0).
# Create an instance/project runner in the UI and paste the issued glrt-* token here.
GITLAB_RUNNER_TOKEN="${GITLAB_RUNNER_TOKEN:-}"
RUNNER_NAME="${RUNNER_NAME:-al2023-private-shell-runner}"
RUNNER_TAGS="${RUNNER_TAGS:-shell,cdk,aws-private}"

# Runtime version matrix
NODE_VERSIONS=(18 20 22)
PYTHON_VERSIONS=(3.10 3.11 3.12)
# Global defaults (a job can override via .mise.toml/.tool-versions or `mise use`)
MISE_GLOBAL_NODE="${MISE_GLOBAL_NODE:-20}"
MISE_GLOBAL_PYTHON="${MISE_GLOBAL_PYTHON:-3.11}"

# mise paths — put data/config in a system-wide location so the result of the root
# build install is shared with the gitlab-runner runtime shell.
MISE_BIN="${MISE_BIN:-/usr/local/bin/mise}"
MISE_DATA_DIR="${MISE_DATA_DIR:-/usr/local/share/mise}"
MISE_CONFIG_DIR="${MISE_CONFIG_DIR:-/etc/mise}"

# Golden AMI mode (true=skip downloads + verify pre-install, false=perform downloads)
GOLDEN_AMI="${GOLDEN_AMI:-true}"

# gitlab-runner user/home
RUNNER_USER="gitlab-runner"
RUNNER_HOME="/home/${RUNNER_USER}"
RUNNER_CONFIG="/etc/gitlab-runner/config.toml"

# gitlab-runner binary (fill in the sha256 for verification at distribution time; empty = skip verify)
GITLAB_RUNNER_VERSION="${GITLAB_RUNNER_VERSION:-latest}"
GITLAB_RUNNER_SHA256="${GITLAB_RUNNER_SHA256:-}"

# ==============================================================================
# Utilities
# ==============================================================================
log()  { printf '\033[1;34m[init]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

# Gate for operations that need a download.
# If GOLDEN_AMI=true it returns false -> callers skip the download.
need_egress() {
  if [[ "${GOLDEN_AMI}" == "true" ]]; then
    return 1
  fi
  return 0
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Root privileges required. Run with sudo."
  fi
}

# ==============================================================================
# STEP 1. System packages (docker, git, build dependencies)
# ==============================================================================
install_system_packages() {
  log "STEP 1: check/install system packages (GOLDEN_AMI=${GOLDEN_AMI})"

  if need_egress; then
    # The downloads below only succeed in a build account that has egress.
    dnf update -y
    # When using python-build-standalone the compiler toolchain is technically
    # unnecessary, but we include the basic build tools for some native npm
    # modules / CDK bundling.
    dnf install -y \
      git docker tar gzip xz which shadow-utils \
      gcc gcc-c++ make openssl-devel bzip2-devel libffi-devel \
      zlib-devel readline-devel sqlite-devel xz-devel
  else
    # Golden AMI mode: docker/git are hard dependencies of the shell executor, so die if missing.
    # (CDK NodejsFunction/PythonFunction bundling uses docker.sock)
    command -v docker >/dev/null 2>&1 || die "GOLDEN_AMI mode but docker is missing. Install it during the AMI build step."
    command -v git    >/dev/null 2>&1 || die "GOLDEN_AMI mode but git is missing. Install it during the AMI build step."
    log "  verified docker, git are pre-installed"
  fi
}

# ==============================================================================
# STEP 2. Enable Docker + gitlab-runner user
# ==============================================================================
setup_docker_and_user() {
  log "STEP 2: enable Docker + configure the ${RUNNER_USER} user"

  command -v docker >/dev/null 2>&1 || die "docker not installed — STEP 1 must pass first."

  systemctl enable docker
  systemctl start docker

  # Create the gitlab-runner user (idempotent)
  if ! id -u "${RUNNER_USER}" >/dev/null 2>&1; then
    useradd --system --create-home --home-dir "${RUNNER_HOME}" --shell /bin/bash "${RUNNER_USER}"
    log "  created user ${RUNNER_USER}"
  else
    log "  user ${RUNNER_USER} already exists"
  fi

  # Add to the docker group (group membership applies after a service restart / re-login)
  usermod -aG docker "${RUNNER_USER}"
}

# ==============================================================================
# STEP 3. AWS CLI v2
# ==============================================================================
install_awscli() {
  log "STEP 3: check/install AWS CLI v2"

  if command -v aws >/dev/null 2>&1; then
    log "  aws already installed: $(aws --version 2>&1)"
    return 0
  fi

  if need_egress; then
    local tmp arch url
    tmp="$(mktemp -d)"
    arch="$(uname -m)"  # x86_64 or aarch64
    url="https://awscli.amazonaws.com/awscli-exe-linux-${arch}.zip"
    log "  downloading: ${url}"
    curl -fsSL "${url}" -o "${tmp}/awscliv2.zip"
    ( cd "${tmp}" && unzip -q awscliv2.zip && ./aws/install --update )
    rm -rf "${tmp}"
  else
    die "GOLDEN_AMI mode but the aws CLI is missing. Install it during the AMI build step."
  fi
}

# ==============================================================================
# STEP 4. Install mise + multiple Node/Python versions (system-wide location)
# ==============================================================================
install_mise_and_runtimes() {
  log "STEP 4: install/verify mise + runtimes"

  install -d -m 0755 "${MISE_DATA_DIR}" "${MISE_CONFIG_DIR}"

  if [[ ! -x "${MISE_BIN}" ]]; then
    if need_egress; then
      log "  downloading mise (https://mise.run)"
      curl -fsSL https://mise.run | MISE_INSTALL_PATH="${MISE_BIN}" sh
    else
      die "GOLDEN_AMI mode but mise is missing (${MISE_BIN}). Install it during the AMI build step."
    fi
  else
    log "  mise already installed: $(${MISE_BIN} --version 2>&1 | head -n1)"
  fi

  # Pin the environment so mise uses the system-wide data/config
  export MISE_DATA_DIR MISE_CONFIG_DIR
  export MISE_YES=1   # non-interactive consent

  # Install runtimes (needs egress). In golden AMI mode, verify presence instead of installing.
  local v
  if need_egress; then
    for v in "${NODE_VERSIONS[@]}"; do
      log "  mise install node@${v}"
      "${MISE_BIN}" install "node@${v}"
    done
    for v in "${PYTHON_VERSIONS[@]}"; do
      log "  mise install python@${v} (python-build-standalone)"
      "${MISE_BIN}" install "python@${v}"
    done
    # Set global defaults
    "${MISE_BIN}" use --global "node@${MISE_GLOBAL_NODE}" "python@${MISE_GLOBAL_PYTHON}"
    "${MISE_BIN}" reshim
  else
    for v in "${NODE_VERSIONS[@]}"; do
      "${MISE_BIN}" ls "node@${v}" >/dev/null 2>&1 || die "node@${v} not installed (golden AMI). Install it during the build step."
    done
    for v in "${PYTHON_VERSIONS[@]}"; do
      "${MISE_BIN}" ls "python@${v}" >/dev/null 2>&1 || die "python@${v} not installed (golden AMI). Install it during the build step."
    done
    log "  verified all node/python versions are pre-installed"
  fi

  # The shared directories must be readable by gitlab-runner (reshim is enough for execution).
  chmod -R a+rX "${MISE_DATA_DIR}" "${MISE_CONFIG_DIR}"
}

# ==============================================================================
# STEP 5. /etc/profile.d/mise.sh (human-login convenience) + global env file
# ==============================================================================
write_mise_profile() {
  log "STEP 5: write /etc/profile.d/mise.sh (convenience for human SSM logins)"

  # NOTE: this file is only sourced by *login shells*.
  #       The gitlab-runner job shell is non-login, so it does not depend on this.
  #       The actual runtime injection for jobs is done by config.toml's environment[] in STEP 7.
  cat > /etc/profile.d/mise.sh <<EOF
# Managed by init-gitlab-runner-al2023.sh — convenience for human logins (SSM)
export MISE_DATA_DIR=${MISE_DATA_DIR}
export MISE_CONFIG_DIR=${MISE_CONFIG_DIR}
export AWS_REGION=${AWS_REGION}
export AWS_DEFAULT_REGION=${AWS_REGION}
# STS must use the regional endpoint (the in-VPC interface endpoint); the global one has no endpoint
export AWS_STS_REGIONAL_ENDPOINTS=regional
if [ -x ${MISE_BIN} ]; then
  eval "\$(${MISE_BIN} activate bash --shims)"
fi
EOF
  chmod 0644 /etc/profile.d/mise.sh

  # An env script for the only file a non-login bash reads automatically.
  # config.toml's BASH_ENV points at this file (see STEP 7).
  cat > /etc/profile.d/mise-shims.sh <<EOF
# Managed by init-gitlab-runner-al2023.sh — injected into the non-login job shell via BASH_ENV
export MISE_DATA_DIR=${MISE_DATA_DIR}
export MISE_CONFIG_DIR=${MISE_CONFIG_DIR}
export AWS_REGION=${AWS_REGION}
export AWS_DEFAULT_REGION=${AWS_REGION}
export AWS_STS_REGIONAL_ENDPOINTS=regional
# put the shims directory first on PATH
export PATH=${MISE_DATA_DIR}/shims:\$PATH
EOF
  chmod 0644 /etc/profile.d/mise-shims.sh
}

# ==============================================================================
# STEP 6. Install the gitlab-runner binary + systemd service + register
# ==============================================================================
install_gitlab_runner() {
  log "STEP 6: install/register gitlab-runner"

  if ! command -v gitlab-runner >/dev/null 2>&1; then
    if need_egress; then
      local arch dl
      case "$(uname -m)" in
        x86_64)  arch="amd64" ;;
        aarch64) arch="arm64" ;;
        *) die "unsupported architecture: $(uname -m)" ;;
      esac
      dl="https://gitlab-runner-downloads.s3.amazonaws.com/${GITLAB_RUNNER_VERSION}/binaries/gitlab-runner-linux-${arch}"
      log "  downloading: ${dl}"
      curl -fsSL "${dl}" -o /usr/local/bin/gitlab-runner
      if [[ -n "${GITLAB_RUNNER_SHA256}" ]]; then
        echo "${GITLAB_RUNNER_SHA256}  /usr/local/bin/gitlab-runner" | sha256sum -c - \
          || die "gitlab-runner sha256 verification failed"
      else
        warn "GITLAB_RUNNER_SHA256 unset — skipping binary integrity verification."
      fi
      chmod +x /usr/local/bin/gitlab-runner
    else
      die "GOLDEN_AMI mode but the gitlab-runner binary is missing. Install it during the AMI build step."
    fi
  else
    log "  gitlab-runner already installed: $(gitlab-runner --version 2>&1 | head -n1)"
  fi

  # Install the systemd service (idempotent)
  if ! systemctl list-unit-files 2>/dev/null | grep -q '^gitlab-runner\.service'; then
    gitlab-runner install --user="${RUNNER_USER}" --working-directory="${RUNNER_HOME}"
  fi
  systemctl enable gitlab-runner

  register_runner
}

# Registration is made idempotent on the RUNNER_NAME + GITLAB_URL combination.
# (A weak guard that only looks at the executor type is avoided — it breaks under
#  token rotation / duplicate registration.)
register_runner() {
  if [[ -z "${GITLAB_RUNNER_TOKEN}" ]]; then
    warn "GITLAB_RUNNER_TOKEN unset — skipping registration. Set the token and re-run."
    return 0
  fi

  # Pre-check GitLab reachability (the most common hard blocker in a private subnet).
  if command -v curl >/dev/null 2>&1; then
    if ! curl -fsS --max-time 10 -o /dev/null "${GITLAB_URL%/}/-/health" 2>/dev/null \
       && ! curl -fsS --max-time 10 -o /dev/null "${GITLAB_URL%/}/" 2>/dev/null; then
      warn "Cannot reach GitLab (${GITLAB_URL}). Check PrivateLink/proxy/routing."
      warn "  -> registration will still be attempted but may fail."
    fi
  fi

  # Clean up dead (server-side removed) runners — re-run / token-rotation safety.
  gitlab-runner verify --delete >/dev/null 2>&1 || true

  # If the same URL + same RUNNER_NAME already exists in config.toml, skip.
  if [[ -f "${RUNNER_CONFIG}" ]] \
     && grep -q "name = \"${RUNNER_NAME}\"" "${RUNNER_CONFIG}" \
     && grep -q "url = \"${GITLAB_URL%/}\"" "${RUNNER_CONFIG}"; then
    log "  runner '${RUNNER_NAME}' (${GITLAB_URL}) already registered — skip"
    log "  (to change tags/URL, delete that [[runners]] block first or rotate the token)"
    return 0
  fi

  log "  registering runner: name=${RUNNER_NAME} url=${GITLAB_URL} tags=${RUNNER_TAGS}"
  # --shell "login bash" is possible, but since we inject the environment explicitly
  # via config.toml's environment[] (STEP 7), we register with non-login bash. Do not mix the two.
  gitlab-runner register \
    --non-interactive \
    --url "${GITLAB_URL%/}" \
    --token "${GITLAB_RUNNER_TOKEN}" \
    --name "${RUNNER_NAME}" \
    --executor "shell" \
    --shell "bash" \
    --tag-list "${RUNNER_TAGS}" \
    --run-untagged="false" \
    --locked="false"
}

# ==============================================================================
# STEP 7. Tune config.toml — builds_dir/cache_dir + environment[] runtime injection
# ==============================================================================
tune_runner_config() {
  log "STEP 7: tune config.toml (inject runtimes via environment[])"

  [[ -f "${RUNNER_CONFIG}" ]] || { warn "config.toml not found — register first, then re-run."; return 0; }
  command -v python3 >/dev/null 2>&1 || die "python3 required (to edit config.toml). Include python3 in the golden AMI."

  # Idempotent markers: update only the keys we manage.
  # Targets the [[runners]] block matching RUNNER_NAME.
  RUNNER_CONFIG="${RUNNER_CONFIG}" \
  RUNNER_NAME="${RUNNER_NAME}" \
  RUNNER_HOME="${RUNNER_HOME}" \
  AWS_REGION="${AWS_REGION}" \
  MISE_DATA_DIR="${MISE_DATA_DIR}" \
  MISE_CONFIG_DIR="${MISE_CONFIG_DIR}" \
  python3 - <<'PYEOF'
import os, re, sys

path   = os.environ["RUNNER_CONFIG"]
name   = os.environ["RUNNER_NAME"]
home   = os.environ["RUNNER_HOME"]
region = os.environ["AWS_REGION"]
mdata  = os.environ["MISE_DATA_DIR"]
mconf  = os.environ["MISE_CONFIG_DIR"]

with open(path, "r", encoding="utf-8") as f:
    text = f.read()

# Split by [[runners]] block
parts = re.split(r'(?m)^\[\[runners\]\]\s*$', text)
# parts[0] is the global header, parts[1:] are each runner block body
if len(parts) < 2:
    print("[tune] no [[runners]] block found — skip", file=sys.stderr)
    sys.exit(0)

builds_dir = f'{home}/builds'
cache_dir  = f'{home}/cache'

env_lines = [
    f'BASH_ENV=/etc/profile.d/mise-shims.sh',   # the only file a non-login bash auto-sources
    f'MISE_DATA_DIR={mdata}',
    f'MISE_CONFIG_DIR={mconf}',
    f'AWS_REGION={region}',
    f'AWS_DEFAULT_REGION={region}',
    f'AWS_STS_REGIONAL_ENDPOINTS=regional',     # STS always uses the in-VPC regional endpoint
    f'PATH={mdata}/shims:/usr/local/bin:/usr/bin:/bin',
]
env_toml = "environment = [" + ", ".join(f'"{e}"' for e in env_lines) + "]"

def patch_block(body):
    # Identify the target block by matching name = "..."
    if f'name = "{name}"' not in body:
        return body, False
    lines = body.split("\n")
    out, seen = [], {"builds_dir": False, "cache_dir": False, "environment": False}
    for ln in lines:
        s = ln.strip()
        if s.startswith("builds_dir"):
            out.append(f'  builds_dir = "{builds_dir}"'); seen["builds_dir"] = True
        elif s.startswith("cache_dir"):
            out.append(f'  cache_dir = "{cache_dir}"'); seen["cache_dir"] = True
        elif s.startswith("environment"):
            out.append("  " + env_toml); seen["environment"] = True
        else:
            out.append(ln)
    # Insert missing keys right after the start of the block
    inject = []
    if not seen["builds_dir"]:  inject.append(f'  builds_dir = "{builds_dir}"')
    if not seen["cache_dir"]:   inject.append(f'  cache_dir = "{cache_dir}"')
    if not seen["environment"]: inject.append("  " + env_toml)
    if inject:
        # Insert after the first non-empty line (name, etc.)
        idx = 0
        while idx < len(out) and out[idx].strip() == "":
            idx += 1
        out = out[: idx + 1] + inject + out[idx + 1 :]
    return "\n".join(out), True

patched_any = False
new_parts = [parts[0]]
for body in parts[1:]:
    nb, ok = patch_block(body)
    patched_any = patched_any or ok
    new_parts.append(nb)

if not patched_any:
    print(f"[tune] block name=\"{name}\" not found — skip", file=sys.stderr)
    sys.exit(0)

# split removed the separator, so rebuild: parts[0] + ('[[runners]]'+body) ...
rebuilt = new_parts[0]
for body in new_parts[1:]:
    rebuilt += "[[runners]]" + body
new_text = rebuilt

with open(path, "w", encoding="utf-8") as f:
    f.write(new_text)
print("[tune] config.toml updated")
PYEOF

  # Ensure directories + ownership
  install -d -o "${RUNNER_USER}" -g "${RUNNER_USER}" "${RUNNER_HOME}/builds" "${RUNNER_HOME}/cache"

  # Guide the distributed S3 cache as a comment block (ServerAddress is the regional URL, never global).
  if ! grep -q '\[runners.cache\]' "${RUNNER_CONFIG}"; then
    cat >> "${RUNNER_CONFIG}" <<EOF

# ──────────────────────────────────────────────────────────────────────────
# (optional) S3 distributed cache — reuse node_modules/cdk.out across instance replacement.
# ServerAddress MUST be the regional S3 endpoint (s3.<region>.amazonaws.com).
# Never use the global s3.amazonaws.com (unresolvable in a private subnet).
# Credentials use the instance profile, so do NOT put AccessKey/SecretKey here.
#  [runners.cache]
#    Type = "s3"
#    Shared = true
#    [runners.cache.s3]
#      ServerAddress = "s3.${AWS_REGION}.amazonaws.com"
#      BucketName = "my-runner-cache-bucket"
#      BucketLocation = "${AWS_REGION}"
#      AuthenticationType = "iam"
# ──────────────────────────────────────────────────────────────────────────
EOF
  fi

  systemctl restart gitlab-runner || warn "failed to restart gitlab-runner — check the registration state."
}

# ==============================================================================
# STEP 8. IMDSv2 / SSM / STS reachability checks
# ==============================================================================
check_imds_and_ssm() {
  log "STEP 8: IMDSv2 / SSM / STS checks"

  # Verify metadata access via the IMDSv2 token method
  local token iid
  token="$(curl -fsS --max-time 5 -X PUT "http://169.254.169.254/latest/api/token" \
            -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null || true)"
  if [[ -n "${token}" ]]; then
    iid="$(curl -fsS --max-time 5 -H "X-aws-ec2-metadata-token: ${token}" \
            "http://169.254.169.254/latest/meta-data/instance-id" 2>/dev/null || true)"
    log "  IMDSv2 OK (instance-id=${iid:-unknown})"
  else
    warn "could not obtain an IMDSv2 token (check hop limit/HttpTokens settings)."
  fi

  # SSM agent
  if systemctl is-active --quiet amazon-ssm-agent 2>/dev/null; then
    log "  amazon-ssm-agent active"
  else
    warn "amazon-ssm-agent is not active — Session Manager access may not work."
  fi

  # STS regional endpoint smoke test (verify in-VPC sts.<region> reachability)
  if command -v aws >/dev/null 2>&1; then
    if AWS_STS_REGIONAL_ENDPOINTS=regional aws sts get-caller-identity \
         --region "${AWS_REGION}" >/dev/null 2>&1; then
      log "  STS get-caller-identity OK (reached sts.${AWS_REGION})"
    else
      warn "STS call failed — check the sts.${AWS_REGION} interface endpoint / IAM role."
    fi
  fi
}

# ==============================================================================
# STEP 9. Runtime verification — reproduce the *real job shell environment* exactly
# ==============================================================================
verify_runtime() {
  log "STEP 9: runtime verification (reproducing the real non-login job shell env)"

  # The shell executor runs jobs in a non-login bash, and only config.toml's
  # environment[] BASH_ENV=/etc/profile.d/mise-shims.sh is auto-sourced.
  # So we verify the same way with env -i + BASH_ENV (to avoid a false GREEN).
  local verify_cmd='command -v node && node -v && command -v python && python -V && command -v npm && npm -v'

  if ! sudo -u "${RUNNER_USER}" env -i \
        HOME="${RUNNER_HOME}" \
        BASH_ENV=/etc/profile.d/mise-shims.sh \
        bash -c "${verify_cmd}"; then
    die "runtime verification failed — node/python/npm not found in the job shell. (check mise shims/PATH)"
  fi

  # Confirm all versions are exposed via shims
  log "  installed mise versions:"
  sudo -u "${RUNNER_USER}" env -i HOME="${RUNNER_HOME}" \
    MISE_DATA_DIR="${MISE_DATA_DIR}" MISE_CONFIG_DIR="${MISE_CONFIG_DIR}" \
    "${MISE_BIN}" ls || true

  log "runtime verification complete — runtimes are exposed correctly in the job shell env."
}

# ==============================================================================
# Required VPC endpoints (reference; the network team attaches them to the subnet)
# ==============================================================================
print_endpoint_reminder() {
  cat <<'EOF'

──────────────────────────────────────────────────────────────────────────────
[NOTE] VPC endpoints this runner requires (all in the same private subnet/SG):
  Gateway:
    com.amazonaws.<region>.s3            (REQUIRED: CDK asset/bootstrap buckets +
                                          CodeArtifact package payloads are served from
                                          an AWS-owned S3 bucket + runner cache)
  Interface (Private DNS=ENABLED on all):
    com.amazonaws.<region>.sts                    (regional, NOT global)
    com.amazonaws.<region>.cloudformation
    com.amazonaws.<region>.codeartifact.api
    com.amazonaws.<region>.codeartifact.repositories
    com.amazonaws.<region>.ecr.api
    com.amazonaws.<region>.ecr.dkr
    com.amazonaws.<region>.logs
    com.amazonaws.<region>.kms
    com.amazonaws.<region>.ssm
    com.amazonaws.<region>.ssmmessages
    com.amazonaws.<region>.ec2messages
    com.amazonaws.<region>.codebuild
  (optional) secretsmanager, ec2, dynamodb(Gateway)

  Notes:
   - Private DNS must be ENABLED on every interface endpoint so that
     service.region.amazonaws.com resolves in-VPC (otherwise get-repository-endpoint
     hostname resolution fails).
   - The S3 Gateway is NOT a "cache option" — it is the required path for CodeArtifact
     package downloads.
   - STS must use the regional endpoint. The global sts.amazonaws.com has no endpoint
     and will hang.
──────────────────────────────────────────────────────────────────────────────
EOF
}

# ==============================================================================
# main
# ==============================================================================
main() {
  require_root
  log "Starting AL2023 GitLab Runner bootstrap (GOLDEN_AMI=${GOLDEN_AMI}, region=${AWS_REGION})"

  install_system_packages
  setup_docker_and_user
  install_awscli
  install_mise_and_runtimes
  write_mise_profile
  install_gitlab_runner
  tune_runner_config
  check_imds_and_ssm
  verify_runtime
  print_endpoint_reminder

  log "Bootstrap complete."
}

main "$@"
