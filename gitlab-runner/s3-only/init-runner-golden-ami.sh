#!/usr/bin/env bash
# init-runner-golden-ami.sh
# ──────────────────────────────────────────────────────────────────────────────
# TIER 1 (preferred): bake a golden AMI for the S3-only GitLab Runner.
#
# Run this in an EGRESS-ENABLED build account (it only needs S3 to reach the mirror,
# so it also works in a restricted build subnet that can reach S3). It installs
# aws-cli v2, mise, Node, Python, and the gitlab-runner binary ENTIRELY from the
# S3 mirror produced by build-s3-mirror.sh — no public URLs.
#
# After this completes successfully, snapshot the instance into an AMI (Packer
# recommended). Do NOT bake a GitLab runner token into the image; register at
# launch time in the private subnet.
#
# Pass bash -n. Idempotent. Inline comments in English (repo convention).
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ==============================================================================
# Config (override via env) — keep MIRROR_BUCKET/REGION identical to build-s3-mirror.sh
# ==============================================================================
MIRROR_BUCKET="${MIRROR_BUCKET:?set MIRROR_BUCKET=your-mirror-bucket}"
AWS_REGION="${AWS_REGION:-ap-northeast-2}"

ARCH_UNAME="${ARCH_UNAME:-x86_64}"
# Node arch naming is only needed by build-s3-mirror.sh (which lays out the tarballs);
# here we only need the gitlab-runner and mise arch suffixes.
case "${ARCH_UNAME}" in
  x86_64)  GLR_ARCH="amd64"; MISE_ARCH="x64" ;;
  aarch64) GLR_ARCH="arm64"; MISE_ARCH="arm64" ;;
  *) echo "unsupported ARCH_UNAME=${ARCH_UNAME}" >&2; exit 1 ;;
esac

MISE_VERSION="${MISE_VERSION:-2025.1.0}"
# Runtimes to warm into the AMI (must be mirrored already). Node uses full semvers.
NODE_VERSIONS="${NODE_VERSIONS:-18.20.4 20.18.1 22.12.0}"
PYTHON_VERSIONS="${PYTHON_VERSIONS:-3.10.16 3.11.11 3.12.8}"

# mise shared system-wide locations (shared with the gitlab-runner job shell)
MISE_BIN="${MISE_BIN:-/usr/local/bin/mise}"
MISE_DATA_DIR="${MISE_DATA_DIR:-/usr/local/share/mise}"
MISE_CONFIG_DIR="${MISE_CONFIG_DIR:-/etc/mise}"

RUNNER_USER="${RUNNER_USER:-gitlab-runner}"
RUNNER_HOME="${RUNNER_HOME:-/home/gitlab-runner}"

# S3 base URL for mise mirror redirects (virtual-hosted-style, regional).
MIRROR_URL="https://${MIRROR_BUCKET}.s3.${AWS_REGION}.amazonaws.com"

log()  { printf '\033[1;34m[golden]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

require_root() { [[ "${EUID}" -eq 0 ]] || die "run as root (sudo)."; }
s3get() { aws s3 cp "s3://${MIRROR_BUCKET}/$1" "$2" --region "${AWS_REGION}" --only-show-errors; }

# ==============================================================================
# STEP 1. System packages (build account has dnf egress; or pre-installed base)
# ==============================================================================
install_system_packages() {
  log "STEP 1: system packages"
  if command -v dnf >/dev/null 2>&1; then
    dnf install -y tar gzip xz unzip which shadow-utils docker zstd || warn "dnf install partial — verify base AMI has these."
  else
    warn "dnf not present — assuming the base AMI already has tar/unzip/xz/zstd/docker."
  fi
  systemctl enable docker 2>/dev/null || true
  systemctl start docker 2>/dev/null || true
}

# ==============================================================================
# STEP 2. gitlab-runner user
# ==============================================================================
setup_user() {
  log "STEP 2: ${RUNNER_USER} user"
  if ! id -u "${RUNNER_USER}" >/dev/null 2>&1; then
    useradd --system --create-home --home-dir "${RUNNER_HOME}" --shell /bin/bash "${RUNNER_USER}"
  fi
  usermod -aG docker "${RUNNER_USER}" 2>/dev/null || true
}

# ==============================================================================
# STEP 3. aws-cli v2 from mirror (bootstrap aws is needed; if missing, the base AMI
#         must already ship a temporary aws to fetch this — AL2023 ships aws-cli v2).
# ==============================================================================
install_awscli() {
  log "STEP 3: aws-cli v2 from S3 mirror"
  command -v aws >/dev/null 2>&1 || die "no aws CLI available to read the mirror. AL2023 ships aws-cli v2; ensure the base AMI has it."
  local tmp; tmp="$(mktemp -d)"
  s3get "aws-cli/awscli-exe-linux-${ARCH_UNAME}.zip" "${tmp}/awscliv2.zip"
  ( cd "${tmp}" && unzip -q awscliv2.zip && ./aws/install --update )
  rm -rf "${tmp}"
  log "  $(aws --version 2>&1)"
}

# ==============================================================================
# STEP 4. mise binary + mirror settings (settings MUST exist before any install)
# ==============================================================================
install_mise_and_settings() {
  log "STEP 4: mise + /etc/mise/settings.toml (S3 mirror redirects)"
  install -d -m 0755 "${MISE_DATA_DIR}" "${MISE_CONFIG_DIR}"

  if [[ ! -x "${MISE_BIN}" ]]; then
    s3get "mise/v${MISE_VERSION}/linux-${MISE_ARCH}" "${MISE_BIN}"
    chmod +x "${MISE_BIN}"
  fi
  log "  $("${MISE_BIN}" --version 2>&1 | head -n1)"

  # Redirect Node downloads to the mirror; redirect python-build-standalone github
  # release URLs to the mirror via a url_replacements regex (no python mirror env var exists).
  # NOTE: $1 in the replacement is mise's capture group, NOT a shell var — single-quote the heredoc.
  cat > "${MISE_CONFIG_DIR}/settings.toml" <<EOF
# Managed by init-runner-golden-ami.sh — S3 mirror redirects for an S3-only host.
[settings]
node.mirror_url = "${MIRROR_URL}/node-builds"

[settings.url_replacements]
"regex:^https://github\\.com/astral-sh/python-build-standalone/releases/download/(.+)" = "${MIRROR_URL}/python-builds/\$1"
EOF
  chmod 0644 "${MISE_CONFIG_DIR}/settings.toml"
  log "  wrote ${MISE_CONFIG_DIR}/settings.toml"
}

# ==============================================================================
# STEP 5. Warm Node + Python toolchains into the AMI (from the mirror, offline-capable)
# ==============================================================================
warm_runtimes() {
  log "STEP 5: install runtimes from mirror"
  export MISE_DATA_DIR MISE_CONFIG_DIR
  export MISE_YES=1

  local v
  for v in ${NODE_VERSIONS}; do
    log "  mise install node@${v}"
    "${MISE_BIN}" install "node@${v}" || die "node@${v} install failed — check node-builds mirror layout."
  done
  for v in ${PYTHON_VERSIONS}; do
    log "  mise install python@${v}"
    "${MISE_BIN}" install "python@${v}" || die "python@${v} install failed — check python-builds DATE_TAG/asset in the mirror."
  done

  # Set sensible globals; jobs override via mise use / .mise.toml
  "${MISE_BIN}" use --global "node@${NODE_VERSIONS%% *}" "python@${PYTHON_VERSIONS%% *}" || true
  "${MISE_BIN}" reshim
  chmod -R a+rX "${MISE_DATA_DIR}" "${MISE_CONFIG_DIR}"
}

# ==============================================================================
# STEP 6. /etc/profile.d shims (login convenience + non-login job shell via BASH_ENV)
# ==============================================================================
write_profiles() {
  log "STEP 6: profile.d activation scripts"
  cat > /etc/profile.d/mise.sh <<EOF
# Managed by init-runner-golden-ami.sh — convenience for human logins (SSM)
export MISE_DATA_DIR=${MISE_DATA_DIR}
export MISE_CONFIG_DIR=${MISE_CONFIG_DIR}
export AWS_REGION=${AWS_REGION}
export AWS_DEFAULT_REGION=${AWS_REGION}
if [ -x ${MISE_BIN} ]; then eval "\$(${MISE_BIN} activate bash --shims)"; fi
EOF
  cat > /etc/profile.d/mise-shims.sh <<EOF
# Managed by init-runner-golden-ami.sh — injected into the non-login job shell via BASH_ENV
export MISE_DATA_DIR=${MISE_DATA_DIR}
export MISE_CONFIG_DIR=${MISE_CONFIG_DIR}
export AWS_REGION=${AWS_REGION}
export AWS_DEFAULT_REGION=${AWS_REGION}
export PATH=${MISE_DATA_DIR}/shims:\$PATH
EOF
  chmod 0644 /etc/profile.d/mise.sh /etc/profile.d/mise-shims.sh
}

# ==============================================================================
# STEP 7. gitlab-runner binary from mirror + systemd (registration is at launch time)
# ==============================================================================
install_gitlab_runner() {
  log "STEP 7: gitlab-runner binary from mirror"
  if ! command -v gitlab-runner >/dev/null 2>&1; then
    s3get "gitlab-runner/linux-${GLR_ARCH}" /usr/local/bin/gitlab-runner
    chmod +x /usr/local/bin/gitlab-runner
  fi
  log "  $(gitlab-runner --version 2>&1 | head -n1)"
  if ! systemctl list-unit-files 2>/dev/null | grep -q '^gitlab-runner\.service'; then
    gitlab-runner install --user="${RUNNER_USER}" --working-directory="${RUNNER_HOME}"
  fi
  systemctl enable gitlab-runner 2>/dev/null || true
}

# ==============================================================================
# STEP 8. Offline verification — reproduce the real non-login job shell
# ==============================================================================
verify() {
  log "STEP 8: verify runtimes in the non-login job shell env"
  sudo -u "${RUNNER_USER}" env -i HOME="${RUNNER_HOME}" \
    BASH_ENV=/etc/profile.d/mise-shims.sh \
    bash -c 'command -v node && node -v && command -v python && python -V && command -v npm && npm -v' \
    || die "runtime verification failed (mise shims/PATH)."
  log "  installed mise versions:"
  sudo -u "${RUNNER_USER}" env -i HOME="${RUNNER_HOME}" \
    MISE_DATA_DIR="${MISE_DATA_DIR}" MISE_CONFIG_DIR="${MISE_CONFIG_DIR}" \
    "${MISE_BIN}" ls || true
}

main() {
  require_root
  log "Golden AMI bake (S3-only) — mirror=s3://${MIRROR_BUCKET} region=${AWS_REGION}"
  install_system_packages
  setup_user
  install_awscli
  install_mise_and_settings
  warm_runtimes
  write_profiles
  install_gitlab_runner
  verify
  log "Bake complete. Snapshot this instance into an AMI now (Packer recommended)."
  log "Do NOT bake a GitLab runner token. Register at launch in the private subnet."
}

main "$@"
