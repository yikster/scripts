#!/usr/bin/env bash
# diagnose-runner-env.sh
# ──────────────────────────────────────────────────────────────────────────────
# Read-only diagnosis of an already-running AL2023 EC2 GitLab Runner host.
# Installs/modifies nothing; never die()s on failure — runs every check to the end
# and prints a PASS/WARN/FAIL summary.
#
# Checks:
#   1. Base tools      : aws CLI v2 / mise / gitlab-runner / docker(daemon) / git / python3
#   2. Runtimes        : node/python/npm exposure in the *real non-login job shell*,
#                        whether required versions (NODE_VERSIONS/PYTHON_VERSIONS) are installed,
#                        and whether version switching (mise exec) works  <- the core check
#   3. Runner config   : config.toml environment[] runtime injection (BASH_ENV/MISE_*),
#                        systemd service active, gitlab-runner's docker group membership
#   4. IMDSv2 / role   : IMDSv2 token, instance-profile (role) name
#   5. Network         : DNS resolution (Private DNS) + TCP 443 reachability of required VPC endpoints
#   6. CodeArtifact    : get-authorization-token / get-repository-endpoint (npm/pypi)
#   7. Cross-account   : actual sts:AssumeRole attempt against target roles (Model A/B)
#
# Usage:
#   bash diagnose-runner-env.sh                 # full check (recommended: run with sudo for the runner-user shell check)
#   sudo bash diagnose-runner-env.sh
#   SKIP_NET=1 SKIP_AWS=1 bash diagnose-runner-env.sh   # runtimes only, fast
#   TARGET_ACCOUNTS="111111111111 222222222222" bash diagnose-runner-env.sh
#   DIAG_JSON=1 bash diagnose-runner-env.sh > /dev/null  # print a JSON summary at the end
#
# Exit code: 1 if there is >=1 FAIL, otherwise 0. (WARN keeps 0.)
# Passes bash -n. Read-only (no install/modify).
# ──────────────────────────────────────────────────────────────────────────────
set -uo pipefail   # NOTE: -e is intentionally omitted so a failed check does not stop the run.

# ==============================================================================
# Shared config header (same variable names/defaults as init-gitlab-runner-al2023.sh)
# ==============================================================================
AWS_REGION="${AWS_REGION:-ap-northeast-2}"
RUNNER_ACCOUNT_ID="${RUNNER_ACCOUNT_ID:-999999999999}"

CA_DOMAIN="${CA_DOMAIN:-my-domain}"
CA_DOMAIN_OWNER="${CA_DOMAIN_OWNER:-$RUNNER_ACCOUNT_ID}"
CA_NPM_REPO="${CA_NPM_REPO:-npm-store}"
CA_PYPI_REPO="${CA_PYPI_REPO:-pypi-store}"

# Required runtimes (multi-version) — these versions must be switchable in the job shell.
# Safely split the space-separated string into an array (avoid SC2206: use read -a).
read -r -a NODE_VERSIONS   <<< "${NODE_VERSIONS:-18 20 22}"
read -r -a PYTHON_VERSIONS <<< "${PYTHON_VERSIONS:-3.10 3.11 3.12}"

# mise shared location / runner user
MISE_BIN="${MISE_BIN:-/usr/local/bin/mise}"
MISE_DATA_DIR="${MISE_DATA_DIR:-/usr/local/share/mise}"
MISE_CONFIG_DIR="${MISE_CONFIG_DIR:-/etc/mise}"
RUNNER_USER="${RUNNER_USER:-gitlab-runner}"
RUNNER_HOME="${RUNNER_HOME:-/home/gitlab-runner}"
MISE_SHIMS_PROFILE="${MISE_SHIMS_PROFILE:-/etc/profile.d/mise-shims.sh}"
RUNNER_CONFIG="${RUNNER_CONFIG:-/etc/gitlab-runner/config.toml}"

# Cross-account targets (space-separated). If empty, the cross-account check is skipped.
TARGET_ACCOUNTS="${TARGET_ACCOUNTS:-111111111111 222222222222 333333333333}"
CDK_QUALIFIER="${CDK_QUALIFIER:-hnb659fds}"
ORG_DEPLOY_ROLE="${ORG_DEPLOY_ROLE:-OrgDeployRole}"
EXTERNAL_ID="${EXTERNAL_ID:-}"

# Section skip toggles
SKIP_NET="${SKIP_NET:-0}"
SKIP_AWS="${SKIP_AWS:-0}"
SKIP_XACCT="${SKIP_XACCT:-0}"

# ==============================================================================
# Output / aggregation helpers
# ==============================================================================
PASS=0; WARN=0; FAIL=0
declare -a RESULTS   # holds "ST|message" (for the JSON summary)

c_g='\033[1;32m'; c_y='\033[1;33m'; c_r='\033[1;31m'; c_b='\033[1;34m'; c_d='\033[2m'; c_0='\033[0m'
# strip colors for non-TTY (pipe/log)
if [[ ! -t 1 ]]; then c_g=; c_y=; c_r=; c_b=; c_d=; c_0=; fi

section() { printf '\n%b== %s ==%b\n' "$c_b" "$*" "$c_0"; }
ok()   { PASS=$((PASS+1)); RESULTS+=("PASS|$*"); printf '  %b[PASS]%b %s\n' "$c_g" "$c_0" "$*"; }
wn()   { WARN=$((WARN+1)); RESULTS+=("WARN|$*"); printf '  %b[WARN]%b %s\n' "$c_y" "$c_0" "$*"; }
bad()  { FAIL=$((FAIL+1)); RESULTS+=("FAIL|$*"); printf '  %b[FAIL]%b %s\n' "$c_r" "$c_0" "$*"; }
info() { RESULTS+=("INFO|$*"); printf '  %b[INFO]%b %s\n' "$c_d" "$c_0" "$*"; }

have() { command -v "$1" >/dev/null 2>&1; }

# Reproduce the runner user's *real non-login job shell environment* and run a command.
# (the environment where only config.toml environment[]'s BASH_ENV=mise-shims.sh is auto-sourced)
RUN_AS_RUNNER_OK=1
run_as_runner() {
  # $1: command string to run via bash -c
  if [[ "$(id -un)" == "${RUNNER_USER}" ]]; then
    env -i HOME="${RUNNER_HOME}" BASH_ENV="${MISE_SHIMS_PROFILE}" bash -c "$1"
  elif [[ "${EUID}" -eq 0 ]]; then
    sudo -u "${RUNNER_USER}" env -i HOME="${RUNNER_HOME}" BASH_ENV="${MISE_SHIMS_PROFILE}" bash -c "$1"
  elif sudo -n true 2>/dev/null; then
    sudo -u "${RUNNER_USER}" env -i HOME="${RUNNER_HOME}" BASH_ENV="${MISE_SHIMS_PROFILE}" bash -c "$1"
  else
    return 97   # no-permission signal
  fi
}

# Call mise directly in the runner-user environment (the mise binary, not the shims)
run_mise() {
  if [[ "$(id -un)" == "${RUNNER_USER}" ]]; then
    env -i HOME="${RUNNER_HOME}" MISE_DATA_DIR="${MISE_DATA_DIR}" MISE_CONFIG_DIR="${MISE_CONFIG_DIR}" "${MISE_BIN}" "$@"
  elif [[ "${EUID}" -eq 0 ]] || sudo -n true 2>/dev/null; then
    sudo -u "${RUNNER_USER}" env -i HOME="${RUNNER_HOME}" MISE_DATA_DIR="${MISE_DATA_DIR}" MISE_CONFIG_DIR="${MISE_CONFIG_DIR}" "${MISE_BIN}" "$@"
  else
    return 97
  fi
}

# DNS resolution -> first IPv4
resolve_ipv4() {
  local host="$1" ip=""
  if have getent; then
    ip="$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1{print $1}')"
  fi
  if [[ -z "$ip" ]] && have python3; then
    ip="$(python3 - "$host" <<'PY' 2>/dev/null
import socket,sys
try: print(socket.gethostbyname(sys.argv[1]))
except Exception: pass
PY
)"
  fi
  printf '%s' "$ip"
}

# Whether an IP is RFC1918 private (a Private-DNS-enabled interface endpoint resolves to a private IP)
is_private_ip() {
  case "$1" in
    10.*|192.168.*) return 0;;
    172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) return 0;;
    *) return 1;;
  esac
}

# TCP 443 reachability (no nc; bash /dev/tcp + timeout)
tcp443() {
  local host="$1" port="${2:-443}" t="${3:-5}"
  if have timeout; then
    timeout "$t" bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null
  else
    bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null
  fi
}

# For AWS API calls: always the runner account / regional endpoint (STS pinned regional)
awsr() { AWS_PROFILE="" AWS_STS_REGIONAL_ENDPOINTS=regional aws --region "${AWS_REGION}" "$@"; }

# ==============================================================================
# 0. Context
# ==============================================================================
section "0. Diagnosis context"
info "host: $(uname -srm 2>/dev/null)  /  run-as user: $(id -un) (EUID=${EUID})"
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  info "OS: ${PRETTY_NAME:-unknown}"
  case "${ID:-}:${VERSION_ID:-}" in
    amzn:2023*) ok "Amazon Linux 2023 confirmed";;
    amzn:2*)    wn "This is Amazon Linux 2 — this design targets AL2023 (mind dnf/glibc differences)";;
    *)          wn "Not AL2023 (${PRETTY_NAME:-unknown}) — some checks may be inaccurate";;
  esac
fi
if [[ "${EUID}" -ne 0 && "$(id -un)" != "${RUNNER_USER}" ]] && ! sudo -n true 2>/dev/null; then
  wn "Not root/sudo, so the '${RUNNER_USER}' job-shell runtime check may be skipped. 'sudo bash $0' recommended."
  RUN_AS_RUNNER_OK=0
fi

# ==============================================================================
# 1. Base tools
# ==============================================================================
section "1. Base tools"
if have aws; then ok "aws CLI: $(aws --version 2>&1)"; else bad "aws CLI missing — AWS CLI v2 is absent from the golden AMI."; fi
have aws && { aws --version 2>&1 | grep -q 'aws-cli/2' || wn "looks like aws CLI v1 — v2 is required (codeartifact login, etc.)."; }
if [[ -x "${MISE_BIN}" ]]; then ok "mise: $("${MISE_BIN}" --version 2>&1 | head -n1) (${MISE_BIN})"; else bad "mise missing (${MISE_BIN}) — multi-runtime not possible."; fi
if have gitlab-runner; then ok "gitlab-runner: $(gitlab-runner --version 2>&1 | awk '/Version/{print $2; exit}')"; else bad "gitlab-runner missing."; fi
if have git; then ok "git: $(git --version 2>&1)"; else wn "git missing — CI clone step may fail."; fi
if have python3; then ok "python3(system): $(python3 --version 2>&1)"; else wn "system python3 missing (needed for editing config.toml / some tools)."; fi
if have jq; then info "jq: present"; else info "jq missing (optional) — JSON parsing uses the built-in method."; fi

# Docker daemon
if have docker; then
  ok "docker CLI: $(docker --version 2>&1)"
  if docker info >/dev/null 2>&1; then
    ok "docker daemon running (CDK asset bundling possible)"
  else
    bad "cannot reach the docker daemon — daemon not started or current user not in the docker group (CDK bundling fails)."
  fi
else
  bad "docker missing — CDK NodejsFunction/PythonFunction bundling / image assets not possible."
fi

# ==============================================================================
# 2. Runtimes (core) — exactly the real non-login job shell environment
# ==============================================================================
section "2. Runtimes — based on the real (non-login) job shell"
if [[ ! -r "${MISE_SHIMS_PROFILE}" ]]; then
  bad "${MISE_SHIMS_PROFILE} missing — the job shell (BASH_ENV) must source this file to get PATH/shims."
fi

if [[ "${RUN_AS_RUNNER_OK}" -eq 1 ]]; then
  out="$(run_as_runner 'command -v node && node -v && command -v python && python -V && command -v npm && npm -v' 2>&1)"; rc=$?
  if [[ $rc -eq 97 ]]; then
    wn "insufficient permissions to run the '${RUNNER_USER}' job-shell check (re-run with sudo)."
  elif [[ $rc -eq 0 ]]; then
    ok "node/python/npm exposed in the job shell:"
    printf '%s\n' "$out" | sed 's/^/        /'
  else
    bad "node/python/npm not exposed in the job shell — check config.toml environment[] (BASH_ENV/PATH) or mise shims:"
    printf '%s\n' "$out" | sed 's/^/        /'
  fi

  # list of installed mise versions
  ls_out="$(run_mise ls 2>/dev/null)"; lrc=$?
  if [[ $lrc -eq 0 && -n "$ls_out" ]]; then
    info "installed mise runtimes:"; printf '%s\n' "$ls_out" | sed 's/^/        /'
  fi

  # whether the required Node versions actually switch (mise exec)
  for v in "${NODE_VERSIONS[@]}"; do
    got="$(run_mise exec "node@${v}" -- node -v 2>/dev/null)"; xrc=$?
    if [[ $xrc -eq 0 && "${got}" == v${v}.* ]]; then
      ok "Node ${v} switch OK (${got})"
    elif [[ $xrc -eq 0 && -n "${got}" ]]; then
      wn "requested Node ${v} but got ${got} — check the version pin."
    else
      bad "Node ${v} not installed / switch failed — 'mise install node@${v}' may be missing from the golden AMI."
    fi
  done

  # whether the required Python versions actually switch
  for v in "${PYTHON_VERSIONS[@]}"; do
    got="$(run_mise exec "python@${v}" -- python -V 2>&1)"; xrc=$?
    if [[ $xrc -eq 0 && "${got}" == "Python ${v}."* ]]; then
      ok "Python ${v} switch OK (${got})"
    elif [[ $xrc -eq 0 && -n "${got}" ]]; then
      wn "requested Python ${v} but got '${got}' — check the version pin."
    else
      bad "Python ${v} not installed / switch failed — 'mise install python@${v}' (python-build-standalone) may be missing."
    fi
  done
else
  wn "skipping the runtime job-shell check (permissions). Re-run with 'sudo bash $0'."
fi

# ==============================================================================
# 3. Runner config
# ==============================================================================
section "3. GitLab Runner config"
if [[ -r "${RUNNER_CONFIG}" ]]; then
  ok "config.toml found: ${RUNNER_CONFIG}"
  cfg="$(cat "${RUNNER_CONFIG}" 2>/dev/null)"
  grep -q 'executor[[:space:]]*=[[:space:]]*"shell"' <<<"$cfg" && ok "executor = shell" || wn "executor is not shell — this design targets the shell executor."
  grep -q 'BASH_ENV='"${MISE_SHIMS_PROFILE//\//\\/}" <<<"$cfg" && ok "environment[] has BASH_ENV=${MISE_SHIMS_PROFILE} injected" \
    || bad "config.toml environment[] missing BASH_ENV=${MISE_SHIMS_PROFILE} — the non-login job shell cannot see the runtimes."
  grep -q 'MISE_DATA_DIR=' <<<"$cfg" && ok "environment[] has MISE_DATA_DIR injected" || wn "environment[] missing MISE_DATA_DIR (may not see the shared mise directory)."
  grep -q 'AWS_STS_REGIONAL_ENDPOINTS=regional' <<<"$cfg" && ok "environment[] has AWS_STS_REGIONAL_ENDPOINTS=regional injected" || wn "STS regional pin missing from environment[] — risk of hanging on global STS."
  grep -q '\[runners.cache\]' <<<"$cfg" && info "cache config block present ([runners.cache])." || info "no cache config (local cache only)."
else
  wn "config.toml (${RUNNER_CONFIG}) missing/unreadable — not registered yet or a different path."
fi

# systemd services
if have systemctl; then
  if systemctl is-active --quiet gitlab-runner 2>/dev/null; then ok "systemd: gitlab-runner active"; else wn "gitlab-runner service not active."; fi
  if systemctl is-active --quiet amazon-ssm-agent 2>/dev/null; then ok "systemd: amazon-ssm-agent active (Session Manager access possible)"; else wn "amazon-ssm-agent inactive — SSM access may be impossible."; fi
fi

# gitlab-runner's docker group membership
if id "${RUNNER_USER}" >/dev/null 2>&1; then
  if id -nG "${RUNNER_USER}" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
    ok "${RUNNER_USER} is in the docker group (CDK bundling can access docker.sock)"
  else
    bad "${RUNNER_USER} is not in the docker group — jobs cannot use docker."
  fi
else
  wn "user ${RUNNER_USER} does not exist."
fi

# ==============================================================================
# 4. IMDSv2 / instance role
# ==============================================================================
section "4. IMDSv2 / instance role"
imds_token="$(curl -fsS --max-time 5 -X PUT 'http://169.254.169.254/latest/api/token' -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' 2>/dev/null || true)"
if [[ -n "$imds_token" ]]; then
  ok "IMDSv2 token obtained OK"
  iid="$(curl -fsS --max-time 5 -H "X-aws-ec2-metadata-token: $imds_token" 'http://169.254.169.254/latest/meta-data/instance-id' 2>/dev/null || true)"
  role="$(curl -fsS --max-time 5 -H "X-aws-ec2-metadata-token: $imds_token" 'http://169.254.169.254/latest/meta-data/iam/security-credentials/' 2>/dev/null || true)"
  info "instance-id=${iid:-unknown}"
  if [[ -n "$role" ]]; then ok "instance profile role: ${role}"; else bad "no IAM role attached to the instance — all AWS calls will fail."; fi
else
  # also try IMDSv1 to catch 'IMDSv2 not enforced'
  if curl -fsS --max-time 5 'http://169.254.169.254/latest/meta-data/instance-id' >/dev/null 2>&1; then
    wn "IMDSv1 responds but the IMDSv2 token failed — recommend HttpTokens=required (enforce IMDSv2)."
  else
    bad "no IMDS response — check the metadata hop limit/network."
  fi
fi

# ==============================================================================
# 5. Network — VPC endpoint DNS (Private DNS) + TCP 443
# ==============================================================================
if [[ "${SKIP_NET}" == "1" ]]; then
  section "5. Network (skipped via SKIP_NET=1)"
else
  section "5. Network — VPC endpoint reachability (DNS + TCP 443)"
  info "A private-IP resolution means a Private-DNS-enabled interface endpoint; a public IP (except the S3 gateway) suggests Private DNS is not set."
  R="${AWS_REGION}"
  # format: "display|hostname|kind(iface|gw)"
  endpoints=(
    "sts(regional)|sts.${R}.amazonaws.com|iface"
    "cloudformation|cloudformation.${R}.amazonaws.com|iface"
    "codeartifact.api|codeartifact.${R}.amazonaws.com|iface"
    "ecr.api|api.ecr.${R}.amazonaws.com|iface"
    "ecr.dkr|${RUNNER_ACCOUNT_ID}.dkr.ecr.${R}.amazonaws.com|iface"
    "logs|logs.${R}.amazonaws.com|iface"
    "kms|kms.${R}.amazonaws.com|iface"
    "ssm|ssm.${R}.amazonaws.com|iface"
    "ssmmessages|ssmmessages.${R}.amazonaws.com|iface"
    "ec2messages|ec2messages.${R}.amazonaws.com|iface"
    "codebuild|codebuild.${R}.amazonaws.com|iface"
    "s3(gateway)|s3.${R}.amazonaws.com|gw"
  )
  for e in "${endpoints[@]}"; do
    IFS='|' read -r name host kind <<<"$e"
    ip="$(resolve_ipv4 "$host")"
    if [[ -z "$ip" ]]; then
      bad "${name}: DNS resolution failed (${host})"
      continue
    fi
    # judge by DNS kind
    if [[ "$kind" == "iface" ]]; then
      if is_private_ip "$ip"; then dnsmsg="private IP ${ip} (Private DNS OK)"; dnsok=1
      else dnsmsg="public IP ${ip} (Private DNS likely unset -> hangs without internet)"; dnsok=0; fi
    else
      dnsmsg="${ip} (gateway: public IP is normal, routing goes via the prefix list)"; dnsok=1
    fi
    # TCP 443
    if tcp443 "$host" 443 5; then
      if [[ "$dnsok" -eq 1 ]]; then ok "${name}: TCP443 OK / ${dnsmsg}"
      else wn "${name}: TCP443 OK but ${dnsmsg}"; fi
    else
      if [[ "$kind" == "iface" && "$dnsok" -eq 0 ]]; then
        bad "${name}: TCP443 failed / ${dnsmsg} — interface endpoint + Private DNS not configured."
      else
        bad "${name}: TCP443 failed / ${dnsmsg} — check the endpoint/SG (443)."
      fi
    fi
  done
  info "(optional endpoints secretsmanager/ec2/dynamodb are only needed when used — not checked here.)"
fi

# ==============================================================================
# 6. CodeArtifact auth
# ==============================================================================
if [[ "${SKIP_AWS}" == "1" ]]; then
  section "6. CodeArtifact (skipped via SKIP_AWS=1)"
else
  section "6. CodeArtifact auth/endpoints"
  if ! have aws; then
    wn "aws CLI missing, skipping the CodeArtifact check."
  else
    # caller identity
    cid="$(awsr sts get-caller-identity --query Arn --output text 2>&1)"; crc=$?
    if [[ $crc -eq 0 ]]; then ok "sts get-caller-identity: ${cid}"; else bad "sts get-caller-identity failed — check the STS endpoint/role: ${cid}"; fi

    tok="$(awsr codeartifact get-authorization-token --domain "${CA_DOMAIN}" --domain-owner "${CA_DOMAIN_OWNER}" --query authorizationToken --output text 2>&1)"; trc=$?
    if [[ $trc -eq 0 && -n "$tok" && "$tok" != "None" ]]; then
      ok "CodeArtifact token issued OK (domain=${CA_DOMAIN}) — sts:GetServiceBearerToken permission is fine."
    else
      bad "CodeArtifact token failed — sts:GetServiceBearerToken (with the codeartifact condition) or codeartifact:GetAuthorizationToken may be missing: ${tok}"
    fi

    for repo in "${CA_NPM_REPO}:npm" "${CA_PYPI_REPO}:pypi"; do
      rname="${repo%%:*}"; fmt="${repo##*:}"
      ep="$(awsr codeartifact get-repository-endpoint --domain "${CA_DOMAIN}" --domain-owner "${CA_DOMAIN_OWNER}" --repository "${rname}" --format "${fmt}" --query repositoryEndpoint --output text 2>&1)"; erc=$?
      if [[ $erc -eq 0 && "$ep" == https://* ]]; then
        ok "repo-endpoint(${fmt}/${rname}): ${ep}"
        ephost="${ep#https://}"; ephost="${ephost%%/*}"
        if [[ "${SKIP_NET}" != "1" ]]; then
          tcp443 "$ephost" 443 5 && ok "  └ ${fmt} repository TCP443 OK" || bad "  └ ${fmt} repository (${ephost}) TCP443 failed — check the codeartifact.repositories endpoint / S3 gateway."
        fi
      else
        bad "repo-endpoint(${fmt}/${rname}) failed — check repository existence/permissions: ${ep}"
      fi
    done
  fi
fi

# ==============================================================================
# 7. Cross-account AssumeRole
# ==============================================================================
if [[ "${SKIP_AWS}" == "1" || "${SKIP_XACCT}" == "1" || -z "${TARGET_ACCOUNTS// /}" ]]; then
  section "7. Cross-account AssumeRole (skipped)"
  info "SKIP_AWS/SKIP_XACCT set, or TARGET_ACCOUNTS empty."
else
  section "7. Cross-account sts:AssumeRole actual attempt"
  if ! have aws; then
    wn "aws CLI missing, skipping."
  else
    extid_args=(); [[ -n "${EXTERNAL_ID}" ]] && extid_args=(--external-id "${EXTERNAL_ID}")
    for acct in ${TARGET_ACCOUNTS}; do
      a_ok=0
      # Model A: CDK bootstrap deploy-role
      a_role="arn:aws:iam::${acct}:role/cdk-${CDK_QUALIFIER}-deploy-role-${acct}-${AWS_REGION}"
      if awsr sts assume-role --role-arn "$a_role" --role-session-name "diag-${acct}" --duration-seconds 900 >/dev/null 2>&1; then
        ok "account ${acct}: Model A assume OK (cdk-${CDK_QUALIFIER}-deploy-role)"; a_ok=1
      fi
      # Model B: OrgDeployRole
      b_role="arn:aws:iam::${acct}:role/${ORG_DEPLOY_ROLE}"
      if awsr sts assume-role --role-arn "$b_role" --role-session-name "diag-${acct}" --duration-seconds 900 "${extid_args[@]+"${extid_args[@]}"}" >/dev/null 2>&1; then
        ok "account ${acct}: Model B assume OK (${ORG_DEPLOY_ROLE})"; a_ok=1
      fi
      if [[ $a_ok -eq 0 ]]; then
        bad "account ${acct}: both A/B assume failed — check target bootstrap (--trust) or the ${ORG_DEPLOY_ROLE} trust policy/ExternalId."
      fi
    done
    info "(cross-account CodeBuild StartBuild must be run from the assumed target role — not directly by RunnerRole.)"
  fi
fi

# ==============================================================================
# Summary
# ==============================================================================
section "Summary"
printf '  %bPASS=%d%b  %bWARN=%d%b  %bFAIL=%d%b\n' "$c_g" "$PASS" "$c_0" "$c_y" "$WARN" "$c_0" "$c_r" "$FAIL" "$c_0"
if [[ $FAIL -eq 0 && $WARN -eq 0 ]]; then
  printf '  %ball checks passed — ready to run jobs.%b\n' "$c_g" "$c_0"
elif [[ $FAIL -eq 0 ]]; then
  printf '  %bno FAILs. Review WARN items per your usage scenario.%b\n' "$c_y" "$c_0"
else
  printf '  %bresolve the FAIL items first (see the [FAIL] lines above).%b\n' "$c_r" "$c_0"
fi

# JSON summary (optional): if DIAG_JSON=1, print to stderr (easy to parse in a pipeline)
if [[ "${DIAG_JSON:-0}" == "1" ]]; then
  {
    printf '{"pass":%d,"warn":%d,"fail":%d,"results":[' "$PASS" "$WARN" "$FAIL"
    for i in "${!RESULTS[@]}"; do
      st="${RESULTS[$i]%%|*}"; msg="${RESULTS[$i]#*|}"
      msg="${msg//\\/\\\\}"; msg="${msg//\"/\\\"}"
      [[ $i -gt 0 ]] && printf ','
      printf '{"status":"%s","msg":"%s"}' "$st" "$msg"
    done
    printf ']}\n'
  } >&2
fi

# Exit code: 1 if any FAIL
[[ $FAIL -eq 0 ]]
