#!/usr/bin/env bash
# build-s3-mirror.sh
# ──────────────────────────────────────────────────────────────────────────────
# Run this in a BUILD ACCOUNT THAT HAS INTERNET EGRESS.
# It mirrors every toolchain installer into an S3 bucket so the locked-down,
# S3-only runner host can install everything via 'aws s3 cp' (no public URLs).
#
# Mirrored:
#   - gitlab-runner binary   (gitlab-runner-downloads.s3.amazonaws.com is genuinely S3)
#   - aws-cli v2 zip         (awscli.amazonaws.com is NOT S3 -> must be mirrored)
#   - mise binary            (mise.run / github.com are blocked on the runner)
#   - Node dist tarballs     (laid out as mise's node.mirror_url expects)
#   - python-build-standalone (date-tagged release assets, for mise url_replacements)
#
# Key layout written under s3://<MIRROR_BUCKET>/:
#   gitlab-runner/linux-<arch>
#   aws-cli/awscli-exe-linux-<unamearch>.zip
#   mise/v<MISE_VERSION>/linux-<arch>
#   node-builds/v<X.Y.Z>/node-v<X.Y.Z>-linux-<arch>.tar.gz   (+ SHASUMS256.txt)
#   python-builds/<DATE_TAG>/<asset-filename>
#
# Pass bash -n. Requires internet + an S3 bucket you can write to.
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ==============================================================================
# Config (override via env)
# ==============================================================================
MIRROR_BUCKET="${MIRROR_BUCKET:?set MIRROR_BUCKET=your-mirror-bucket}"
AWS_REGION="${AWS_REGION:-ap-northeast-2}"

# Architecture mapping. mise/node use x64/arm64; uname uses x86_64/aarch64.
ARCH_UNAME="${ARCH_UNAME:-x86_64}"            # x86_64 | aarch64
case "${ARCH_UNAME}" in
  x86_64)  GLR_ARCH="amd64"; NODE_ARCH="x64";   MISE_ARCH="x64";   PBS_ARCH="x86_64" ;;
  aarch64) GLR_ARCH="arm64"; NODE_ARCH="arm64"; MISE_ARCH="arm64"; PBS_ARCH="aarch64" ;;
  *) echo "unsupported ARCH_UNAME=${ARCH_UNAME}" >&2; exit 1 ;;
esac

# Version pins (override to match your runtime matrix)
GITLAB_RUNNER_CHANNEL="${GITLAB_RUNNER_CHANNEL:-latest}"   # 'latest' or e.g. 'v17.5.3'
MISE_VERSION="${MISE_VERSION:-2025.1.0}"                   # mise release (without leading v)
NODE_VERSIONS="${NODE_VERSIONS:-18.20.4 20.18.1 22.12.0}" # full semvers (node.mirror_url needs exact dirs)
# python-build-standalone: "PYVER:DATE_TAG" pairs. Date tags are NOT semver; find them at
# https://github.com/astral-sh/python-build-standalone/releases (look for cpython-<pyver>+<date>).
PBS_PAIRS="${PBS_PAIRS:-3.10.16:20250115 3.11.11:20250115 3.12.8:20250115}"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

log()  { printf '\033[1;34m[mirror]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

command -v aws  >/dev/null 2>&1 || die "aws CLI required."
command -v curl >/dev/null 2>&1 || die "curl required."

s3cp() { aws s3 cp "$1" "s3://${MIRROR_BUCKET}/$2" --region "${AWS_REGION}" --only-show-errors; }

# ==============================================================================
# 1. gitlab-runner binary (already S3-backed; mirror into our bucket for one source of truth)
# ==============================================================================
mirror_gitlab_runner() {
  log "gitlab-runner (${GITLAB_RUNNER_CHANNEL}, ${GLR_ARCH})"
  local url="https://gitlab-runner-downloads.s3.amazonaws.com/${GITLAB_RUNNER_CHANNEL}/binaries/gitlab-runner-linux-${GLR_ARCH}"
  curl -fsSL "${url}" -o "${WORK}/gitlab-runner"
  s3cp "${WORK}/gitlab-runner" "gitlab-runner/linux-${GLR_ARCH}"
}

# ==============================================================================
# 2. aws-cli v2 zip (NOT S3 at source -> must mirror)
# ==============================================================================
mirror_awscli() {
  log "aws-cli v2 (${ARCH_UNAME})"
  local url="https://awscli.amazonaws.com/awscli-exe-linux-${ARCH_UNAME}.zip"
  curl -fsSL "${url}" -o "${WORK}/awscliv2.zip"
  s3cp "${WORK}/awscliv2.zip" "aws-cli/awscli-exe-linux-${ARCH_UNAME}.zip"
}

# ==============================================================================
# 3. mise binary
# ==============================================================================
mirror_mise() {
  log "mise v${MISE_VERSION} (${MISE_ARCH})"
  local url="https://github.com/jdx/mise/releases/download/v${MISE_VERSION}/mise-v${MISE_VERSION}-linux-${MISE_ARCH}"
  curl -fsSL "${url}" -o "${WORK}/mise"
  s3cp "${WORK}/mise" "mise/v${MISE_VERSION}/linux-${MISE_ARCH}"
}

# ==============================================================================
# 4. Node dist tarballs — mirror the exact layout node.mirror_url expects:
#    <mirror>/node-builds/v<X.Y.Z>/node-v<X.Y.Z>-linux-<arch>.tar.gz  (+ SHASUMS256.txt)
# ==============================================================================
mirror_node() {
  local v file
  for v in ${NODE_VERSIONS}; do
    log "node v${v} (${NODE_ARCH})"
    file="node-v${v}-linux-${NODE_ARCH}.tar.gz"
    curl -fsSL "https://nodejs.org/dist/v${v}/${file}" -o "${WORK}/${file}"
    s3cp "${WORK}/${file}" "node-builds/v${v}/${file}"
    # SHASUMS so mise can verify integrity offline
    curl -fsSL "https://nodejs.org/dist/v${v}/SHASUMS256.txt" -o "${WORK}/SHASUMS256.txt" \
      && s3cp "${WORK}/SHASUMS256.txt" "node-builds/v${v}/SHASUMS256.txt" \
      || warn "node v${v}: SHASUMS256.txt mirror failed (continuing)"
    rm -f "${WORK}/${file}"
  done
}

# ==============================================================================
# 5. python-build-standalone — mirror under the github release path tail so the
#    mise url_replacements regex rewrites the github URL to our S3 key.
#    regex captures everything after .../releases/download/ -> we store it verbatim.
#    Source URL form:
#      https://github.com/astral-sh/python-build-standalone/releases/download/<DATE_TAG>/<asset>
#    Asset (install_only, most portable):
#      cpython-<pyver>+<DATE_TAG>-<pbsarch>-unknown-linux-gnu-install_only.tar.gz
# ==============================================================================
mirror_python() {
  local pair pyver date asset url
  for pair in ${PBS_PAIRS}; do
    pyver="${pair%%:*}"; date="${pair##*:}"
    asset="cpython-${pyver}+${date}-${PBS_ARCH}-unknown-linux-gnu-install_only.tar.gz"
    url="https://github.com/astral-sh/python-build-standalone/releases/download/${date}/${asset}"
    log "python ${pyver} (pbs ${date}, ${PBS_ARCH})"
    if curl -fsSL "${url}" -o "${WORK}/${asset}"; then
      # store under python-builds/<DATE_TAG>/<asset> to match url_replacements: ".../python-builds/$1"
      s3cp "${WORK}/${asset}" "python-builds/${date}/${asset}"
      rm -f "${WORK}/${asset}"
    else
      warn "python ${pyver}: download failed for ${asset}. Verify the DATE_TAG at the python-build-standalone releases page."
    fi
  done
}

# ==============================================================================
# main
# ==============================================================================
main() {
  log "mirror bucket=s3://${MIRROR_BUCKET} region=${AWS_REGION} arch=${ARCH_UNAME}"
  aws s3 ls "s3://${MIRROR_BUCKET}" --region "${AWS_REGION}" >/dev/null 2>&1 \
    || die "cannot access s3://${MIRROR_BUCKET} (create it and check credentials)."

  mirror_gitlab_runner
  mirror_awscli
  mirror_mise
  mirror_node
  mirror_python

  log "Done. Mirrored layout under s3://${MIRROR_BUCKET}/:"
  log "  gitlab-runner/linux-${GLR_ARCH}"
  log "  aws-cli/awscli-exe-linux-${ARCH_UNAME}.zip"
  log "  mise/v${MISE_VERSION}/linux-${MISE_ARCH}"
  log "  node-builds/v<ver>/node-v<ver>-linux-${NODE_ARCH}.tar.gz"
  log "  python-builds/<date>/cpython-<ver>+<date>-${PBS_ARCH}-...-install_only.tar.gz"
  log ""
  log "Next: set MIRROR_BUCKET/REGION in init-runner-golden-ami.sh and bake the AMI."
}

main "$@"
