#!/usr/bin/env bash
# init-runner-s3-bootstrap.sh
# ──────────────────────────────────────────────────────────────────────────────
# TIER 2 (fallback): bootstrap the S3-only runner AT BOOT (no golden AMI).
#
# Intended to run from EC2 user-data (or once via SSM) in the private subnet,
# using the INSTANCE ROLE to pull every toolchain artifact from the S3 mirror.
# Prefer the golden AMI (init-runner-golden-ami.sh) — this tier is slower per boot
# and depends on the base AMI already shipping aws-cli/unzip/tar/zstd.
#
# It reuses the same mirror layout and mise settings as the golden-AMI script, then
# registers the runner if GITLAB_URL + GITLAB_RUNNER_TOKEN are provided.
#
# Pass bash -n. Idempotent.
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ==============================================================================
# Config (override via env / user-data)
# ==============================================================================
MIRROR_BUCKET="${MIRROR_BUCKET:?set MIRROR_BUCKET=your-mirror-bucket}"
AWS_REGION="${AWS_REGION:-ap-northeast-2}"

ARCH_UNAME="${ARCH_UNAME:-x86_64}"
# Only gitlab-runner and mise arch suffixes are needed here (Node arch is a mirror concern).
case "${ARCH_UNAME}" in
  x86_64)  GLR_ARCH="amd64"; MISE_ARCH="x64" ;;
  aarch64) GLR_ARCH="arm64"; MISE_ARCH="arm64" ;;
  *) echo "unsupported ARCH_UNAME=${ARCH_UNAME}" >&2; exit 1 ;;
esac

MISE_VERSION="${MISE_VERSION:-2025.1.0}"
NODE_VERSIONS="${NODE_VERSIONS:-18.20.4 20.18.1 22.12.0}"
PYTHON_VERSIONS="${PYTHON_VERSIONS:-3.10.16 3.11.11 3.12.8}"

MISE_BIN="${MISE_BIN:-/usr/local/bin/mise}"
MISE_DATA_DIR="${MISE_DATA_DIR:-/usr/local/share/mise}"
MISE_CONFIG_DIR="${MISE_CONFIG_DIR:-/etc/mise}"
RUNNER_USER="${RUNNER_USER:-gitlab-runner}"
RUNNER_HOME="${RUNNER_HOME:-/home/gitlab-runner}"
RUNNER_CONFIG="${RUNNER_CONFIG:-/etc/gitlab-runner/config.toml}"

# Registration (optional at boot; if unset, only the toolchain is installed)
GITLAB_URL="${GITLAB_URL:-}"
GITLAB_RUNNER_TOKEN="${GITLAB_RUNNER_TOKEN:-}"
RUNNER_NAME="${RUNNER_NAME:-al2023-s3only-shell-runner}"
RUNNER_TAGS="${RUNNER_TAGS:-shell,cdk,s3only}"

MIRROR_URL="https://${MIRROR_BUCKET}.s3.${AWS_REGION}.amazonaws.com"

log()  { printf '\033[1;34m[s3boot]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

require_root() { [[ "${EUID}" -eq 0 ]] || die "run as root (user-data runs as root)."; }
s3get() { aws s3 cp "s3://${MIRROR_BUCKET}/$1" "$2" --region "${AWS_REGION}" --only-show-errors; }

install_base() {
  log "STEP 1: base packages + docker"
  if command -v dnf >/dev/null 2>&1; then
    dnf install -y tar gzip xz unzip which shadow-utils docker zstd || warn "dnf partial."
  fi
  systemctl enable docker 2>/dev/null || true
  systemctl start docker 2>/dev/null || true
  command -v aws >/dev/null 2>&1 || die "no aws CLI on the base AMI — cannot reach the S3 mirror."
}

setup_user() {
  log "STEP 2: ${RUNNER_USER} user"
  id -u "${RUNNER_USER}" >/dev/null 2>&1 || \
    useradd --system --create-home --home-dir "${RUNNER_HOME}" --shell /bin/bash "${RUNNER_USER}"
  usermod -aG docker "${RUNNER_USER}" 2>/dev/null || true
}

install_mise_and_settings() {
  log "STEP 3: mise + settings.toml (S3 mirror redirects)"
  install -d -m 0755 "${MISE_DATA_DIR}" "${MISE_CONFIG_DIR}"
  if [[ ! -x "${MISE_BIN}" ]]; then
    s3get "mise/v${MISE_VERSION}/linux-${MISE_ARCH}" "${MISE_BIN}"; chmod +x "${MISE_BIN}"
  fi
  # NOTE: $1 below is mise's regex capture, NOT a shell var — escape the \$.
  cat > "${MISE_CONFIG_DIR}/settings.toml" <<EOF
# Managed by init-runner-s3-bootstrap.sh — S3 mirror redirects for an S3-only host.
[settings]
node.mirror_url = "${MIRROR_URL}/node-builds"

[settings.url_replacements]
"regex:^https://github\\.com/astral-sh/python-build-standalone/releases/download/(.+)" = "${MIRROR_URL}/python-builds/\$1"
EOF
  chmod 0644 "${MISE_CONFIG_DIR}/settings.toml"
}

warm_runtimes() {
  log "STEP 4: install runtimes from mirror"
  export MISE_DATA_DIR MISE_CONFIG_DIR MISE_YES=1
  local v
  for v in ${NODE_VERSIONS};   do log "  node@${v}";   "${MISE_BIN}" install "node@${v}"   || die "node@${v} failed"; done
  for v in ${PYTHON_VERSIONS}; do log "  python@${v}"; "${MISE_BIN}" install "python@${v}" || die "python@${v} failed"; done
  "${MISE_BIN}" use --global "node@${NODE_VERSIONS%% *}" "python@${PYTHON_VERSIONS%% *}" || true
  "${MISE_BIN}" reshim
  chmod -R a+rX "${MISE_DATA_DIR}" "${MISE_CONFIG_DIR}"
}

write_profiles() {
  log "STEP 5: profile.d shims"
  cat > /etc/profile.d/mise-shims.sh <<EOF
# Managed by init-runner-s3-bootstrap.sh — non-login job shell via BASH_ENV
export MISE_DATA_DIR=${MISE_DATA_DIR}
export MISE_CONFIG_DIR=${MISE_CONFIG_DIR}
export AWS_REGION=${AWS_REGION}
export AWS_DEFAULT_REGION=${AWS_REGION}
export PATH=${MISE_DATA_DIR}/shims:\$PATH
EOF
  chmod 0644 /etc/profile.d/mise-shims.sh
}

install_runner() {
  log "STEP 6: gitlab-runner binary + service"
  if ! command -v gitlab-runner >/dev/null 2>&1; then
    s3get "gitlab-runner/linux-${GLR_ARCH}" /usr/local/bin/gitlab-runner
    chmod +x /usr/local/bin/gitlab-runner
  fi
  if ! systemctl list-unit-files 2>/dev/null | grep -q '^gitlab-runner\.service'; then
    gitlab-runner install --user="${RUNNER_USER}" --working-directory="${RUNNER_HOME}"
  fi
  systemctl enable gitlab-runner 2>/dev/null || true
}

register_and_tune() {
  if [[ -z "${GITLAB_URL}" || -z "${GITLAB_RUNNER_TOKEN}" ]]; then
    warn "GITLAB_URL/GITLAB_RUNNER_TOKEN unset — toolchain installed but runner NOT registered."
    return 0
  fi
  log "STEP 7: register runner ${RUNNER_NAME}"
  if [[ -f "${RUNNER_CONFIG}" ]] && grep -q "name = \"${RUNNER_NAME}\"" "${RUNNER_CONFIG}"; then
    log "  already registered — skip"
  else
    gitlab-runner register --non-interactive \
      --url "${GITLAB_URL%/}" --token "${GITLAB_RUNNER_TOKEN}" \
      --name "${RUNNER_NAME}" --executor "shell" --shell "bash" \
      --tag-list "${RUNNER_TAGS}" --run-untagged="false" --locked="false"
  fi
  # Inject runtime env into the non-login job shell (mirror of the golden-AMI design).
  if command -v python3 >/dev/null 2>&1 && [[ -f "${RUNNER_CONFIG}" ]]; then
    RUNNER_CONFIG="${RUNNER_CONFIG}" RUNNER_NAME="${RUNNER_NAME}" \
    MISE_DATA_DIR="${MISE_DATA_DIR}" MISE_CONFIG_DIR="${MISE_CONFIG_DIR}" \
    AWS_REGION="${AWS_REGION}" RUNNER_HOME="${RUNNER_HOME}" \
    python3 - <<'PYEOF'
import os, re, sys
path=os.environ["RUNNER_CONFIG"]; name=os.environ["RUNNER_NAME"]
mdata=os.environ["MISE_DATA_DIR"]; mconf=os.environ["MISE_CONFIG_DIR"]
region=os.environ["AWS_REGION"]; home=os.environ["RUNNER_HOME"]
text=open(path,encoding="utf-8").read()
parts=re.split(r'(?m)^\[\[runners\]\]\s*$', text)
if len(parts)<2: sys.exit(0)
env_lines=[f'BASH_ENV=/etc/profile.d/mise-shims.sh',f'MISE_DATA_DIR={mdata}',
           f'MISE_CONFIG_DIR={mconf}',f'AWS_REGION={region}',f'AWS_DEFAULT_REGION={region}',
           f'PATH={mdata}/shims:/usr/local/bin:/usr/bin:/bin']
env_toml="environment = ["+", ".join(f'"{e}"' for e in env_lines)+"]"
def patch(body):
    if f'name = "{name}"' not in body: return body
    lines=body.split("\n"); out=[]; seen=False
    for ln in lines:
        if ln.strip().startswith("environment"): out.append("  "+env_toml); seen=True
        else: out.append(ln)
    if not seen:
        idx=0
        while idx<len(out) and out[idx].strip()=="": idx+=1
        out=out[:idx+1]+["  "+env_toml]+out[idx+1:]
    return "\n".join(out)
rebuilt=parts[0]
for b in parts[1:]: rebuilt+="[[runners]]"+patch(b)
open(path,"w",encoding="utf-8").write(rebuilt)
print("[s3boot] config.toml environment[] injected")
PYEOF
    systemctl restart gitlab-runner || warn "restart failed."
  fi
}

main() {
  require_root
  log "S3-only boot bootstrap — mirror=s3://${MIRROR_BUCKET} region=${AWS_REGION}"
  install_base
  setup_user
  install_mise_and_settings
  warm_runtimes
  write_profiles
  install_runner
  register_and_tune
  log "Done."
}

main "$@"
