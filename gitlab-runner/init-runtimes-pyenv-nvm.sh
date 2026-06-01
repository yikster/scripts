#!/usr/bin/env bash
# init-runtimes-pyenv-nvm.sh
# ──────────────────────────────────────────────────────────────────────────────
# Install nvm (multi Node) + pyenv (multi Python) for a GitLab Runner whose jobs
# run on the SHELL executor, then wire them into the *non-login* job shell so a
# GitLab CI matrix can switch/execute each Node and Python version.
#
# This is the pyenv/nvm alternative to init-gitlab-runner-al2023.sh's `mise` step.
# It installs into the gitlab-runner user's HOME (per-user layout) and replaces the
# config.toml environment[] BASH_ENV wiring so jobs see nvm+pyenv instead of mise.
# Run this AFTER the runner is registered (so config.toml exists) — or set
# TUNE_CONFIG=false and wire BASH_ENV yourself.
#
# [ORDERING] This script REPLACES the mise BASH_ENV in config.toml's environment[]
#   (it tags the block with `# env-managed-by: pyenv-nvm`). Run it AFTER
#   init-gitlab-runner-al2023.sh. Do NOT re-run that script's tune step afterward —
#   its STEP 7 rewrites environment[] back to the mise BASH_ENV and restarts the
#   runner, silently reverting jobs to mise. If that happens, just re-run THIS script.
#
# Why the wiring matters (the whole point):
#   The shell executor runs each job in a *non-login, non-interactive* bash, which
#   does NOT read ~/.bashrc or ~/.bash_profile. So the usual nvm/pyenv init lines in
#   a dotfile never run. Instead config.toml's environment[] sets
#   BASH_ENV=/etc/profile.d/pyenv-nvm.sh — the one file a non-login bash auto-sources
#   — and that file loads pyenv (shims) and *sources* nvm (a shell function).
#
# Two key facts that shape this script:
#   - nvm is a shell FUNCTION, not a binary. `node` only appears after nvm.sh is
#     sourced and a version is selected. So nvm.sh is sourced in BASH_ENV; jobs then
#     call `nvm use <ver>`.
#   - pyenv COMPILES CPython from source (unlike mise's prebuilt binaries), so STEP 1
#     installs a full build toolchain and each version takes minutes to build.
#
# Modes:
#   GOLDEN_AMI=false (DEFAULT here): actually download + install everything. Run this
#                    on a host WITH internet egress (e.g. the AMI build account).
#   GOLDEN_AMI=true : skip all downloads; verify the pre-baked nvm/pyenv + versions
#                    exist (for launching a golden AMI into a no-egress private subnet).
#
# Idempotent + re-runnable. Passes `bash -n`.
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ==============================================================================
# Config (override via env). Keep names aligned with the companion scripts.
# ==============================================================================
AWS_REGION="${AWS_REGION:-ap-northeast-2}"

# gitlab-runner user/home + config (the runtimes live under this user's HOME)
RUNNER_USER="${RUNNER_USER:-gitlab-runner}"
RUNNER_HOME="${RUNNER_HOME:-/home/${RUNNER_USER}}"
RUNNER_CONFIG="${RUNNER_CONFIG:-/etc/gitlab-runner/config.toml}"
# Must match the registered runner's `name = "..."` so config.toml tuning finds the block.
RUNNER_NAME="${RUNNER_NAME:-al2023-private-shell-runner}"

# Version matrix (space-separated overrides supported, e.g. NODE_VERSIONS="20 22")
read -r -a NODE_VERSIONS   <<< "${NODE_VERSIONS:-18 20 22 24}"
read -r -a PYTHON_VERSIONS <<< "${PYTHON_VERSIONS:-3.10 3.11 3.12 3.13}"
# Default selected when a job does not call `nvm use` / `pyenv shell`.
NVM_NODE_DEFAULT="${NVM_NODE_DEFAULT:-22}"
PYENV_PYTHON_DEFAULT="${PYENV_PYTHON_DEFAULT:-3.12}"

# Install locations (per-user, under the runner HOME)
NVM_DIR="${NVM_DIR:-${RUNNER_HOME}/.nvm}"
PYENV_ROOT="${PYENV_ROOT:-${RUNNER_HOME}/.pyenv}"
# Pin a git ref; empty = latest release tag. NOTE: do NOT name this PYENV_VERSION
# (that env var is how pyenv itself selects a Python version).
NVM_GIT_REF="${NVM_GIT_REF:-}"
PYENV_GIT_REF="${PYENV_GIT_REF:-}"

# Single profile file: auto-sourced by login shells AND used as the job shell's BASH_ENV.
PROFILE_D="${PROFILE_D:-/etc/profile.d/pyenv-nvm.sh}"

# false = install now (needs egress); true = verify a pre-baked golden AMI.
GOLDEN_AMI="${GOLDEN_AMI:-false}"
# false = do not touch config.toml (just install + write the profile).
TUNE_CONFIG="${TUNE_CONFIG:-true}"

# Default-first list of Python short-names for `pyenv global` (first = the `python` default).
PY_GLOBALS="${PYENV_PYTHON_DEFAULT}"
for __v in "${PYTHON_VERSIONS[@]}"; do
  [[ "${__v}" == "${PYENV_PYTHON_DEFAULT}" ]] || PY_GLOBALS+=" ${__v}"
done
unset __v

# ==============================================================================
# Utilities
# ==============================================================================
log()  { printf '\033[1;34m[init]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

# Download gate. GOLDEN_AMI=true -> returns non-zero so callers skip downloads.
need_egress() { [[ "${GOLDEN_AMI}" != "true" ]]; }

require_root() { [[ "${EUID}" -eq 0 ]] || die "Root privileges required. Run with sudo."; }

# Run a script (read from stdin) AS the gitlab-runner user, with the env it needs.
# Files created therefore end up owned by gitlab-runner (correct for a per-user layout).
# sudo's secure_path provides /usr/bin (gcc/git/make) for the pyenv source build.
as_runner_stdin() {
  sudo -u "${RUNNER_USER}" -H env \
    NVM_DIR="${NVM_DIR}" \
    PYENV_ROOT="${PYENV_ROOT}" \
    AWS_REGION="${AWS_REGION}" \
    NODE_LIST="${NODE_VERSIONS[*]}" \
    PY_LIST="${PYTHON_VERSIONS[*]}" \
    PY_GLOBALS="${PY_GLOBALS}" \
    NVM_NODE_DEFAULT="${NVM_NODE_DEFAULT}" \
    NVM_GIT_REF="${NVM_GIT_REF}" \
    PYENV_GIT_REF="${PYENV_GIT_REF}" \
    bash -s
}

# Fail fast BEFORE the (slow) source builds if a *_DEFAULT is not in its matrix.
# Otherwise `pyenv global <default>` / `nvm alias default <default>` reference an
# uninstalled version and only blow up at the very end (Python is hard-fatal; Node
# just leaves a dangling default alias).
validate_config() {
  [[ " ${PYTHON_VERSIONS[*]} " == *" ${PYENV_PYTHON_DEFAULT} "* ]] \
    || die "PYENV_PYTHON_DEFAULT=${PYENV_PYTHON_DEFAULT} is not in PYTHON_VERSIONS='${PYTHON_VERSIONS[*]}' — add it or change the default."
  [[ " ${NODE_VERSIONS[*]} " == *" ${NVM_NODE_DEFAULT} "* ]] \
    || warn "NVM_NODE_DEFAULT=${NVM_NODE_DEFAULT} is not in NODE_VERSIONS='${NODE_VERSIONS[*]}'; the default node alias will be dangling (jobs that call 'nvm use <ver>' still work)."
}

# ==============================================================================
# STEP 0. Ensure the gitlab-runner user exists (its HOME hosts the runtimes)
# ==============================================================================
ensure_runner_user() {
  if ! id -u "${RUNNER_USER}" >/dev/null 2>&1; then
    log "STEP 0: creating system user ${RUNNER_USER} (home ${RUNNER_HOME})"
    useradd --system --create-home --home-dir "${RUNNER_HOME}" --shell /bin/bash "${RUNNER_USER}"
  else
    log "STEP 0: user ${RUNNER_USER} already exists"
  fi
  [[ -d "${RUNNER_HOME}" ]] || die "runner home ${RUNNER_HOME} is missing."
}

# ==============================================================================
# STEP 1. Build toolchain (pyenv compiles CPython from source)
# ==============================================================================
install_build_deps() {
  log "STEP 1: build toolchain + headers (GOLDEN_AMI=${GOLDEN_AMI})"
  if need_egress; then
    command -v dnf >/dev/null 2>&1 || die "dnf not found — this script targets RHEL/Amazon Linux 2023."
    dnf install -y \
      git curl tar gzip xz which findutils \
      gcc gcc-c++ make patch \
      zlib-devel bzip2 bzip2-devel readline-devel \
      sqlite sqlite-devel openssl-devel tk-devel \
      libffi-devel xz-devel gdbm-devel ncurses-devel libuuid-devel
  else
    # Golden AMI: the runtime needs no compiler. Nothing to do here.
    log "  GOLDEN_AMI mode — skipping dnf (no compiler needed to *run* prebuilt versions)"
  fi
}

# ==============================================================================
# STEP 2. Install nvm + pyenv into the runner HOME (as the runner user)
# ==============================================================================
clone_tools() {
  log "STEP 2: install nvm (${NVM_DIR}) + pyenv (${PYENV_ROOT})"
  if need_egress; then
    if ! as_runner_stdin <<'EOF'
set -eo pipefail
pick_tag() { git -C "$1" tag --sort=-v:refname | grep -E '^v?[0-9]+\.' | head -n1; }

# --- nvm (a shell function, cloned as a git repo) ---
if [ ! -s "$NVM_DIR/nvm.sh" ]; then
  echo "[runner] cloning nvm -> $NVM_DIR"
  git clone --quiet https://github.com/nvm-sh/nvm.git "$NVM_DIR"
  ref="${NVM_GIT_REF:-}"; [ -n "$ref" ] || ref="$(pick_tag "$NVM_DIR")"
  [ -n "$ref" ] && git -C "$NVM_DIR" -c advice.detachedHead=false checkout --quiet "$ref"
  echo "[runner] nvm @ ${ref:-<default-branch>}"
else
  echo "[runner] nvm already present at $NVM_DIR"
fi

# --- pyenv (provides python-build to compile CPython) ---
if [ ! -x "$PYENV_ROOT/bin/pyenv" ]; then
  echo "[runner] cloning pyenv -> $PYENV_ROOT"
  git clone --quiet https://github.com/pyenv/pyenv.git "$PYENV_ROOT"
  ref="${PYENV_GIT_REF:-}"; [ -n "$ref" ] || ref="$(pick_tag "$PYENV_ROOT")"
  [ -n "$ref" ] && git -C "$PYENV_ROOT" -c advice.detachedHead=false checkout --quiet "$ref"
  echo "[runner] pyenv @ ${ref:-<default-branch>}"
  # Optional: compile the small C extension for faster shims. Safe to skip on failure.
  if ( cd "$PYENV_ROOT" && src/configure && make -C src ) >/dev/null 2>&1; then
    echo "[runner] pyenv bash extension built"
  else
    echo "[runner] pyenv bash extension skipped (pure-shell shims still work)"
  fi
else
  echo "[runner] pyenv already present at $PYENV_ROOT"
fi
EOF
    then
      die "cloning nvm/pyenv failed (check egress + git)."
    fi
  else
    [[ -s "${NVM_DIR}/nvm.sh" ]]       || die "GOLDEN_AMI but nvm missing (${NVM_DIR}). Install it during the AMI build."
    [[ -x "${PYENV_ROOT}/bin/pyenv" ]] || die "GOLDEN_AMI but pyenv missing (${PYENV_ROOT}). Install it during the AMI build."
    log "  verified nvm + pyenv are pre-installed"
  fi
}

# ==============================================================================
# STEP 3. Install Node versions via nvm
# ==============================================================================
install_node_versions() {
  log "STEP 3: Node via nvm -> ${NODE_VERSIONS[*]} (default ${NVM_NODE_DEFAULT})"
  if need_egress; then
    if ! as_runner_stdin <<'EOF'
set -eo pipefail
[ -s "$NVM_DIR/nvm.sh" ] || { echo "nvm.sh missing at $NVM_DIR" >&2; exit 1; }
# shellcheck disable=SC1090
\. "$NVM_DIR/nvm.sh"
for v in $NODE_LIST; do
  echo "[runner] nvm install $v"
  nvm install "$v"
done
nvm alias default "$NVM_NODE_DEFAULT" >/dev/null
echo "[runner] node default -> $(nvm version default)"
EOF
    then
      die "Node install via nvm failed."
    fi
  else
    if ! as_runner_stdin <<'EOF'
set -eo pipefail
\. "$NVM_DIR/nvm.sh"
for v in $NODE_LIST; do
  nvm ls "$v" >/dev/null 2>&1 || { echo "node $v not installed (golden AMI)" >&2; exit 8; }
done
echo "[runner] verified Node versions: $NODE_LIST"
EOF
    then
      die "GOLDEN_AMI but a required Node version is missing. Install it during the AMI build."
    fi
  fi
}

# ==============================================================================
# STEP 4. Install Python versions via pyenv (+ friendly short-name symlinks)
# ==============================================================================
install_python_versions() {
  log "STEP 4: Python via pyenv -> ${PYTHON_VERSIONS[*]} (default ${PYENV_PYTHON_DEFAULT})"
  if need_egress; then
    if ! as_runner_stdin <<'EOF'
set -eo pipefail
export PATH="$PYENV_ROOT/bin:$PATH"
command -v pyenv >/dev/null 2>&1 || { echo "pyenv not on PATH" >&2; exit 1; }
for major in $PY_LIST; do
  # Resolve "3.12" -> latest installable patch (e.g. 3.12.8); fall back to the list.
  full="$(pyenv latest -k "$major" 2>/dev/null || true)"
  [ -n "$full" ] || full="$(pyenv install --list | tr -d ' ' | grep -xE "${major}\.[0-9]+" | tail -n1 || true)"
  [ -n "$full" ] || { echo "could not resolve a patch release for Python $major" >&2; exit 1; }
  echo "[runner] pyenv install $full (for $major) — compiling from source, takes a few minutes"
  pyenv install -s "$full"
  # Friendly short name so jobs can `pyenv shell 3.12` instead of the exact patch.
  ln -sfn "$full" "$PYENV_ROOT/versions/$major"
done
pyenv global $PY_GLOBALS
pyenv rehash
echo "[runner] python global -> $(pyenv global | tr '\n' ' ')"
EOF
    then
      die "Python install via pyenv failed (check STEP 1 build deps + egress)."
    fi
  else
    if ! as_runner_stdin <<'EOF'
set -eo pipefail
for major in $PY_LIST; do
  [ -d "$PYENV_ROOT/versions/$major" ] || { echo "python $major not installed (golden AMI)" >&2; exit 8; }
done
echo "[runner] verified Python versions: $PY_LIST"
EOF
    then
      die "GOLDEN_AMI but a required Python version is missing. Install it during the AMI build."
    fi
  fi
}

# ==============================================================================
# STEP 5. Write the profile (login auto-source + the job shell's BASH_ENV target)
# ==============================================================================
write_profile() {
  log "STEP 5: write ${PROFILE_D}"
  # Unquoted heredoc: ${NVM_DIR}/${AWS_REGION}/... bake in now; \$… stay literal for runtime.
  cat > "${PROFILE_D}" <<EOF
# Managed by init-runtimes-pyenv-nvm.sh — DO NOT edit by hand.
# Sourced by:
#   - human login shells (SSM): /etc/profile.d/*.sh is auto-sourced, and
#   - the gitlab-runner NON-login job shell: via config.toml environment[] BASH_ENV.
# Loads pyenv (shims) + nvm (a shell function) so CI jobs can switch node/python.
export NVM_DIR="${NVM_DIR}"
export PYENV_ROOT="${PYENV_ROOT}"
export AWS_REGION="${AWS_REGION}"
export AWS_DEFAULT_REGION="${AWS_REGION}"
# STS must use the regional (in-VPC) endpoint; global sts.amazonaws.com has no VPC endpoint.
export AWS_STS_REGIONAL_ENDPOINTS=regional

# pyenv: python/pip shims + 'pyenv shell <ver>' switching.
if [ -x "\$PYENV_ROOT/bin/pyenv" ]; then
  export PATH="\$PYENV_ROOT/bin:\$PATH"
  eval "\$(pyenv init - bash)"
fi

# nvm is a shell FUNCTION (not a binary) — it must be sourced so jobs can 'nvm use <ver>'.
if [ -s "\$NVM_DIR/nvm.sh" ]; then
  # shellcheck disable=SC1090
  \. "\$NVM_DIR/nvm.sh"
  # Expose the default node for jobs that never call 'nvm use'.
  nvm use default >/dev/null 2>&1 || true
fi
EOF
  chmod 0644 "${PROFILE_D}"
}

# ==============================================================================
# STEP 6. Wire the runtimes into config.toml environment[] (BASH_ENV injection)
# ==============================================================================
tune_runner_config() {
  if [[ "${TUNE_CONFIG}" != "true" ]]; then
    log "STEP 6: skipping config.toml tuning (TUNE_CONFIG=${TUNE_CONFIG})"
    return 0
  fi
  log "STEP 6: wire config.toml environment[] -> BASH_ENV=${PROFILE_D}"
  [[ -f "${RUNNER_CONFIG}" ]] || {
    warn "config.toml not found (${RUNNER_CONFIG}). Register the runner first then re-run,"
    warn "  or set TUNE_CONFIG=false and inject BASH_ENV yourself. Skipping tuning."
    return 0
  }
  command -v python3 >/dev/null 2>&1 || die "system python3 required to edit config.toml."

  RUNNER_CONFIG="${RUNNER_CONFIG}" \
  RUNNER_NAME="${RUNNER_NAME}" \
  AWS_REGION="${AWS_REGION}" \
  NVM_DIR="${NVM_DIR}" \
  PYENV_ROOT="${PYENV_ROOT}" \
  PROFILE_D="${PROFILE_D}" \
  python3 - <<'PYEOF'
import os, re, sys

path   = os.environ["RUNNER_CONFIG"]
name   = os.environ["RUNNER_NAME"]
region = os.environ["AWS_REGION"]
nvm    = os.environ["NVM_DIR"]
pyroot = os.environ["PYENV_ROOT"]
prof   = os.environ["PROFILE_D"]

with open(path, "r", encoding="utf-8") as f:
    text = f.read()

# Split into the global header + each [[runners]] block body.
parts = re.split(r'(?m)^\[\[runners\]\]\s*$', text)
if len(parts) < 2:
    print("[tune] no [[runners]] block found — skip", file=sys.stderr)
    sys.exit(0)

env_lines = [
    f'BASH_ENV={prof}',                      # the only file a non-login bash auto-sources
    f'NVM_DIR={nvm}',
    f'PYENV_ROOT={pyroot}',
    f'AWS_REGION={region}',
    f'AWS_DEFAULT_REGION={region}',
    'AWS_STS_REGIONAL_ENDPOINTS=regional',
    f'PATH={pyroot}/bin:/usr/local/bin:/usr/bin:/bin',  # BASH_ENV prepends pyenv shims + node
]
env_toml = "environment = [" + ", ".join(f'"{e}"' for e in env_lines) + "]"

MARKER = "# env-managed-by: pyenv-nvm"

def patch(body):
    # Target only the [[runners]] block whose name matches RUNNER_NAME.
    if f'name = "{name}"' not in body:
        return body, False
    out, seen = [], False
    for ln in body.split("\n"):
        s = ln.strip()
        if s == MARKER:
            continue  # drop any prior marker; re-emitted attached to environment (idempotent)
        if s.startswith("environment"):
            out.append("  " + MARKER)
            out.append("  " + env_toml)
            seen = True
        else:
            out.append(ln)
    if not seen:
        idx = 0
        while idx < len(out) and out[idx].strip() == "":
            idx += 1
        out = out[: idx + 1] + ["  " + MARKER, "  " + env_toml] + out[idx + 1 :]
    return "\n".join(out), True

patched, new_parts = False, [parts[0]]
for body in parts[1:]:
    nb, ok = patch(body)
    patched = patched or ok
    new_parts.append(nb)

if not patched:
    print(f'[tune] block name="{name}" not found — skip', file=sys.stderr)
    sys.exit(0)

rebuilt = new_parts[0]
for body in new_parts[1:]:
    rebuilt += "[[runners]]" + body

with open(path, "w", encoding="utf-8") as f:
    f.write(rebuilt)
print("[tune] config.toml environment[] updated for pyenv/nvm")
PYEOF

  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart gitlab-runner 2>/dev/null \
      || warn "could not restart gitlab-runner (not installed yet?). It will load config.toml on next start."
  fi
}

# ==============================================================================
# STEP 7. Verify in the REAL non-login job shell (reproduce it exactly)
# ==============================================================================
verify_runtime() {
  log "STEP 7: verify node/python switching in the real non-login job shell"
  # env -i with the SAME base PATH config.toml provides, plus BASH_ENV — so nvm.sh
  # (which needs grep/sed/uname) and pyenv resolve exactly as a job would see them.
  if ! sudo -u "${RUNNER_USER}" env -i \
        HOME="${RUNNER_HOME}" \
        PATH="/usr/local/bin:/usr/bin:/bin" \
        BASH_ENV="${PROFILE_D}" \
        NODE_LIST="${NODE_VERSIONS[*]}" \
        PY_LIST="${PYTHON_VERSIONS[*]}" \
        bash <<'EOF'
set -eo pipefail
command -v node   >/dev/null || { echo "node missing on PATH";  exit 1; }
command -v npm    >/dev/null || { echo "npm missing on PATH";   exit 1; }
command -v python >/dev/null || { echo "python missing on PATH"; exit 1; }
command -v pyenv  >/dev/null || { echo "pyenv missing on PATH"; exit 1; }
[ "$(type -t nvm)" = function ] || { echo "nvm function not loaded"; exit 1; }
echo "  defaults: node=$(node -v)  npm=$(npm -v)  python=$(python -V 2>&1)"
for v in $NODE_LIST; do
  nvm use "$v" >/dev/null 2>&1 || { echo "nvm use $v failed"; exit 1; }
  node -v | grep -q "^v$v\." || { echo "node $v mismatch -> $(node -v)"; exit 1; }
  echo "  node $v OK ($(node -v))"
done
for v in $PY_LIST; do
  pyenv shell "$v" || { echo "pyenv shell $v failed"; exit 1; }
  python -V 2>&1 | grep -q "Python $v\." || { echo "python $v mismatch -> $(python -V 2>&1)"; exit 1; }
  echo "  python $v OK ($(python -V 2>&1))"
done
echo "OK: every node/python version switches in the job shell."
EOF
  then
    die "runtime verification failed. Check ${PROFILE_D} and config.toml environment[]."
  fi
}

# ==============================================================================
# Usage note
# ==============================================================================
print_usage_note() {
  cat <<EOF

──────────────────────────────────────────────────────────────────────────────
[how CI jobs select versions]  shell executor, non-login bash; nvm+pyenv are
auto-loaded via config.toml environment[] BASH_ENV=${PROFILE_D}

  # Node (nvm is a shell function, loaded for every job):
  nvm use 20            # this job now uses Node 20.x
  node -v

  # Python (pyenv shims + 'pyenv shell'):
  pyenv shell 3.12      # this job now uses Python 3.12.x
  python -V

  Installed: node ${NODE_VERSIONS[*]} (default ${NVM_NODE_DEFAULT})
             python ${PYTHON_VERSIONS[*]} (default ${PYENV_PYTHON_DEFAULT})

  Matrix example: gitlab-runner/sample.pyenv-nvm.gitlab-ci.yml

  WARNING: this replaced the mise BASH_ENV in config.toml. Do NOT re-run
  init-gitlab-runner-al2023.sh's tune step afterward (it reverts to mise). If you
  do, re-run THIS script to restore the pyenv/nvm wiring.
──────────────────────────────────────────────────────────────────────────────
EOF
}

# ==============================================================================
# main
# ==============================================================================
main() {
  require_root
  validate_config
  log "pyenv+nvm runtime bootstrap (GOLDEN_AMI=${GOLDEN_AMI}, user=${RUNNER_USER}, region=${AWS_REGION})"

  ensure_runner_user
  install_build_deps
  clone_tools
  install_node_versions
  install_python_versions
  write_profile
  tune_runner_config
  verify_runtime
  print_usage_note

  log "Done — multi-version Node/Python are ready for the shell-executor jobs."
}

main "$@"
