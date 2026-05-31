#!/usr/bin/env bash
# diagnose-runner-env.sh
# ──────────────────────────────────────────────────────────────────────────────
# 이미 떠 있는(running) AL2023 EC2 GitLab Runner 호스트의 환경을 *읽기 전용*으로
# 진단한다. 아무것도 설치/수정하지 않으며, 실패해도 die 하지 않고 끝까지 점검 후
# PASS/WARN/FAIL 요약을 낸다.
#
# 점검 항목:
#   1. 기본 도구       : aws CLI v2 / mise / gitlab-runner / docker(데몬) / git / python3
#   2. 런타임          : *실제 비-로그인 잡 셸* 에서 node/python/npm 노출 여부,
#                        요구 버전(NODE_VERSIONS/PYTHON_VERSIONS) 설치 여부,
#                        버전 전환(mise exec) 동작 여부  ← 핵심
#   3. 러너 설정       : config.toml environment[] 런타임 주입(BASH_ENV/MISE_*),
#                        systemd 서비스 active, gitlab-runner 의 docker 그룹 소속
#   4. IMDSv2 / 역할   : IMDSv2 토큰, 인스턴스 프로파일(역할) 이름
#   5. 네트워크        : 필요한 VPC 엔드포인트의 DNS 해석(Private DNS) + TCP 443 도달
#   6. CodeArtifact    : get-authorization-token / get-repository-endpoint (npm·pypi)
#   7. 크로스계정      : 타겟 계정 역할 sts:AssumeRole 실제 시도(Model A/B)
#
# 사용법:
#   bash diagnose-runner-env.sh                 # 전체 점검(권장: sudo 로 실행해야 런너 유저 셸 점검 가능)
#   sudo bash diagnose-runner-env.sh
#   SKIP_NET=1 SKIP_AWS=1 bash diagnose-runner-env.sh   # 런타임만 빠르게
#   TARGET_ACCOUNTS="111111111111 222222222222" bash diagnose-runner-env.sh
#   DIAG_JSON=1 bash diagnose-runner-env.sh > /dev/null  # 마지막에 JSON 요약 출력
#
# 종료 코드: FAIL 1개 이상이면 1, 아니면 0. (WARN 은 0 유지)
# bash -n 통과. 읽기 전용(설치/수정 없음).
# ──────────────────────────────────────────────────────────────────────────────
set -uo pipefail   # 주의: -e 는 일부러 빼서, 점검 중 실패해도 끝까지 진행한다.

# ==============================================================================
# 공유 설정 헤더 (init-gitlab-runner-al2023.sh 와 변수명/기본값 동일)
# ==============================================================================
AWS_REGION="${AWS_REGION:-ap-northeast-2}"
RUNNER_ACCOUNT_ID="${RUNNER_ACCOUNT_ID:-999999999999}"

CA_DOMAIN="${CA_DOMAIN:-my-domain}"
CA_DOMAIN_OWNER="${CA_DOMAIN_OWNER:-$RUNNER_ACCOUNT_ID}"
CA_NPM_REPO="${CA_NPM_REPO:-npm-store}"
CA_PYPI_REPO="${CA_PYPI_REPO:-pypi-store}"

# 요구 런타임(멀티 버전) — 이 버전들이 잡 셸에서 전환 가능해야 한다.
# 공백 구분 문자열을 배열로 안전 분해(SC2206 방지: read -a 사용).
read -r -a NODE_VERSIONS   <<< "${NODE_VERSIONS:-18 20 22}"
read -r -a PYTHON_VERSIONS <<< "${PYTHON_VERSIONS:-3.10 3.11 3.12}"

# mise 공용 위치 / 런너 유저
MISE_BIN="${MISE_BIN:-/usr/local/bin/mise}"
MISE_DATA_DIR="${MISE_DATA_DIR:-/usr/local/share/mise}"
MISE_CONFIG_DIR="${MISE_CONFIG_DIR:-/etc/mise}"
RUNNER_USER="${RUNNER_USER:-gitlab-runner}"
RUNNER_HOME="${RUNNER_HOME:-/home/gitlab-runner}"
MISE_SHIMS_PROFILE="${MISE_SHIMS_PROFILE:-/etc/profile.d/mise-shims.sh}"
RUNNER_CONFIG="${RUNNER_CONFIG:-/etc/gitlab-runner/config.toml}"

# 크로스계정 타겟(공백 구분). 비우면 cross-account 점검을 건너뛴다.
TARGET_ACCOUNTS="${TARGET_ACCOUNTS:-111111111111 222222222222 333333333333}"
CDK_QUALIFIER="${CDK_QUALIFIER:-hnb659fds}"
ORG_DEPLOY_ROLE="${ORG_DEPLOY_ROLE:-OrgDeployRole}"
EXTERNAL_ID="${EXTERNAL_ID:-}"

# 섹션 스킵 토글
SKIP_NET="${SKIP_NET:-0}"
SKIP_AWS="${SKIP_AWS:-0}"
SKIP_XACCT="${SKIP_XACCT:-0}"

# ==============================================================================
# 출력 / 집계 헬퍼
# ==============================================================================
PASS=0; WARN=0; FAIL=0
declare -a RESULTS   # "ST|메시지" 보관 (JSON 요약용)

c_g='\033[1;32m'; c_y='\033[1;33m'; c_r='\033[1;31m'; c_b='\033[1;34m'; c_d='\033[2m'; c_0='\033[0m'
# 비-TTY(파이프/로그)면 색상 제거
if [[ ! -t 1 ]]; then c_g=; c_y=; c_r=; c_b=; c_d=; c_0=; fi

section() { printf '\n%b== %s ==%b\n' "$c_b" "$*" "$c_0"; }
ok()   { PASS=$((PASS+1)); RESULTS+=("PASS|$*"); printf '  %b[PASS]%b %s\n' "$c_g" "$c_0" "$*"; }
wn()   { WARN=$((WARN+1)); RESULTS+=("WARN|$*"); printf '  %b[WARN]%b %s\n' "$c_y" "$c_0" "$*"; }
bad()  { FAIL=$((FAIL+1)); RESULTS+=("FAIL|$*"); printf '  %b[FAIL]%b %s\n' "$c_r" "$c_0" "$*"; }
info() { RESULTS+=("INFO|$*"); printf '  %b[INFO]%b %s\n' "$c_d" "$c_0" "$*"; }

have() { command -v "$1" >/dev/null 2>&1; }

# 런너 유저의 *실제 비-로그인 잡 셸 환경*을 재현해서 명령 실행.
# (config.toml environment[] 의 BASH_ENV=mise-shims.sh 만 자동 source 되는 그 환경)
RUN_AS_RUNNER_OK=1
run_as_runner() {
  # $1: bash -c 로 실행할 명령 문자열
  if [[ "$(id -un)" == "${RUNNER_USER}" ]]; then
    env -i HOME="${RUNNER_HOME}" BASH_ENV="${MISE_SHIMS_PROFILE}" bash -c "$1"
  elif [[ "${EUID}" -eq 0 ]]; then
    sudo -u "${RUNNER_USER}" env -i HOME="${RUNNER_HOME}" BASH_ENV="${MISE_SHIMS_PROFILE}" bash -c "$1"
  elif sudo -n true 2>/dev/null; then
    sudo -u "${RUNNER_USER}" env -i HOME="${RUNNER_HOME}" BASH_ENV="${MISE_SHIMS_PROFILE}" bash -c "$1"
  else
    return 97   # 권한 없음 신호
  fi
}

# 런너 유저 환경에서 mise 직접 호출(shims 가 아니라 mise 바이너리)
run_mise() {
  if [[ "$(id -un)" == "${RUNNER_USER}" ]]; then
    env -i HOME="${RUNNER_HOME}" MISE_DATA_DIR="${MISE_DATA_DIR}" MISE_CONFIG_DIR="${MISE_CONFIG_DIR}" "${MISE_BIN}" "$@"
  elif [[ "${EUID}" -eq 0 ]] || sudo -n true 2>/dev/null; then
    sudo -u "${RUNNER_USER}" env -i HOME="${RUNNER_HOME}" MISE_DATA_DIR="${MISE_DATA_DIR}" MISE_CONFIG_DIR="${MISE_CONFIG_DIR}" "${MISE_BIN}" "$@"
  else
    return 97
  fi
}

# DNS 해석 → 첫 IPv4
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

# RFC1918 사설 IP 여부 (Private DNS 활성화된 interface endpoint 이면 사설 IP 로 해석됨)
is_private_ip() {
  case "$1" in
    10.*|192.168.*) return 0;;
    172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) return 0;;
    *) return 1;;
  esac
}

# TCP 443 도달성 (nc 없이 bash /dev/tcp + timeout)
tcp443() {
  local host="$1" port="${2:-443}" t="${3:-5}"
  if have timeout; then
    timeout "$t" bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null
  else
    bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null
  fi
}

# AWS API 호출용: 항상 러너 계정/리전 엔드포인트(STS 리전 고정)
awsr() { AWS_PROFILE="" AWS_STS_REGIONAL_ENDPOINTS=regional aws --region "${AWS_REGION}" "$@"; }

# ==============================================================================
# 0. 컨텍스트
# ==============================================================================
section "0. 진단 컨텍스트"
info "호스트: $(uname -srm 2>/dev/null)  /  실행 사용자: $(id -un) (EUID=${EUID})"
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  info "OS: ${PRETTY_NAME:-unknown}"
  case "${ID:-}:${VERSION_ID:-}" in
    amzn:2023*) ok "Amazon Linux 2023 확인";;
    amzn:2*)    wn "Amazon Linux 2 입니다 — 이 설계는 AL2023 기준(dnf/glibc 차이 주의)";;
    *)          wn "AL2023 이 아닙니다 (${PRETTY_NAME:-unknown}) — 일부 점검이 부정확할 수 있음";;
  esac
fi
if [[ "${EUID}" -ne 0 && "$(id -un)" != "${RUNNER_USER}" ]] && ! sudo -n true 2>/dev/null; then
  wn "root/sudo 가 아니므로 '${RUNNER_USER}' 잡 셸 런타임 점검을 건너뛸 수 있습니다. 'sudo bash $0' 권장."
  RUN_AS_RUNNER_OK=0
fi

# ==============================================================================
# 1. 기본 도구
# ==============================================================================
section "1. 기본 도구"
if have aws; then ok "aws CLI: $(aws --version 2>&1)"; else bad "aws CLI 없음 — 골든 AMI 에 AWS CLI v2 가 빠졌습니다."; fi
have aws && { aws --version 2>&1 | grep -q 'aws-cli/2' || wn "aws CLI v1 으로 보입니다 — v2 필요(codeartifact login 등)."; }
if [[ -x "${MISE_BIN}" ]]; then ok "mise: $("${MISE_BIN}" --version 2>&1 | head -n1) (${MISE_BIN})"; else bad "mise 없음(${MISE_BIN}) — 멀티 런타임 불가."; fi
if have gitlab-runner; then ok "gitlab-runner: $(gitlab-runner --version 2>&1 | awk '/Version/{print $2; exit}')"; else bad "gitlab-runner 없음."; fi
if have git; then ok "git: $(git --version 2>&1)"; else wn "git 없음 — CI clone 단계에서 실패할 수 있음."; fi
if have python3; then ok "python3(시스템): $(python3 --version 2>&1)"; else wn "시스템 python3 없음 (config.toml 편집/일부 도구에 필요)."; fi
if have jq; then info "jq: 있음"; else info "jq 없음(선택) — JSON 파싱은 내장 방식 사용."; fi

# Docker 데몬
if have docker; then
  ok "docker CLI: $(docker --version 2>&1)"
  if docker info >/dev/null 2>&1; then
    ok "docker 데몬 동작 중 (CDK 에셋 번들링 가능)"
  else
    bad "docker 데몬에 접근 불가 — 데몬 미기동이거나 현재 사용자가 docker 그룹이 아님(CDK 번들링 실패)."
  fi
else
  bad "docker 없음 — CDK NodejsFunction/PythonFunction 번들링·이미지 에셋 불가."
fi

# ==============================================================================
# 2. 런타임 (핵심) — 실제 비-로그인 잡 셸 환경 그대로
# ==============================================================================
section "2. 런타임 — 실제 잡 셸(비-로그인) 환경 기준"
if [[ ! -r "${MISE_SHIMS_PROFILE}" ]]; then
  bad "${MISE_SHIMS_PROFILE} 없음 — 잡 셸(BASH_ENV)이 이 파일을 source 해야 PATH/shims 가 잡힘."
fi

if [[ "${RUN_AS_RUNNER_OK}" -eq 1 ]]; then
  out="$(run_as_runner 'command -v node && node -v && command -v python && python -V && command -v npm && npm -v' 2>&1)"; rc=$?
  if [[ $rc -eq 97 ]]; then
    wn "권한 부족으로 '${RUNNER_USER}' 잡 셸 런타임 점검 생략(sudo 로 재실행)."
  elif [[ $rc -eq 0 ]]; then
    ok "잡 셸에서 node/python/npm 노출됨:"
    printf '%s\n' "$out" | sed 's/^/        /'
  else
    bad "잡 셸에서 node/python/npm 미노출 — config.toml environment[](BASH_ENV/PATH) 또는 mise shims 확인:"
    printf '%s\n' "$out" | sed 's/^/        /'
  fi

  # 설치된 mise 버전 목록
  ls_out="$(run_mise ls 2>/dev/null)"; lrc=$?
  if [[ $lrc -eq 0 && -n "$ls_out" ]]; then
    info "설치된 mise 런타임:"; printf '%s\n' "$ls_out" | sed 's/^/        /'
  fi

  # 요구 Node 버전들이 실제로 전환되는지 (mise exec)
  for v in "${NODE_VERSIONS[@]}"; do
    got="$(run_mise exec "node@${v}" -- node -v 2>/dev/null)"; xrc=$?
    if [[ $xrc -eq 0 && "${got}" == v${v}.* ]]; then
      ok "Node ${v} 전환 OK (${got})"
    elif [[ $xrc -eq 0 && -n "${got}" ]]; then
      wn "Node ${v} 요청했으나 ${got} 응답 — 버전 핀 확인."
    else
      bad "Node ${v} 미설치/전환 실패 — 'mise install node@${v}' 가 골든 AMI 에 빠졌을 수 있음."
    fi
  done

  # 요구 Python 버전들이 실제로 전환되는지
  for v in "${PYTHON_VERSIONS[@]}"; do
    got="$(run_mise exec "python@${v}" -- python -V 2>&1)"; xrc=$?
    if [[ $xrc -eq 0 && "${got}" == "Python ${v}."* ]]; then
      ok "Python ${v} 전환 OK (${got})"
    elif [[ $xrc -eq 0 && -n "${got}" ]]; then
      wn "Python ${v} 요청했으나 '${got}' 응답 — 버전 핀 확인."
    else
      bad "Python ${v} 미설치/전환 실패 — 'mise install python@${v}'(python-build-standalone) 누락 가능."
    fi
  done
else
  wn "런타임 잡 셸 점검 생략(권한). 'sudo bash $0' 로 다시 실행하세요."
fi

# ==============================================================================
# 3. 러너 설정
# ==============================================================================
section "3. GitLab Runner 설정"
if [[ -r "${RUNNER_CONFIG}" ]]; then
  ok "config.toml 발견: ${RUNNER_CONFIG}"
  cfg="$(cat "${RUNNER_CONFIG}" 2>/dev/null)"
  grep -q 'executor[[:space:]]*=[[:space:]]*"shell"' <<<"$cfg" && ok "executor = shell" || wn "executor 가 shell 이 아님 — 이 설계는 shell executor 기준."
  grep -q 'BASH_ENV='"${MISE_SHIMS_PROFILE//\//\\/}" <<<"$cfg" && ok "environment[] 에 BASH_ENV=${MISE_SHIMS_PROFILE} 주입됨" \
    || bad "config.toml environment[] 에 BASH_ENV=${MISE_SHIMS_PROFILE} 없음 — 비-로그인 잡 셸이 런타임을 못 봄."
  grep -q 'MISE_DATA_DIR=' <<<"$cfg" && ok "environment[] 에 MISE_DATA_DIR 주입됨" || wn "environment[] 에 MISE_DATA_DIR 없음(공용 mise 디렉터리 못 볼 수 있음)."
  grep -q 'AWS_STS_REGIONAL_ENDPOINTS=regional' <<<"$cfg" && ok "environment[] 에 AWS_STS_REGIONAL_ENDPOINTS=regional 주입됨" || wn "STS 리전 고정이 environment[] 에 없음 — global STS 로 hang 위험."
  grep -q '\[runners.cache\]' <<<"$cfg" && info "캐시 설정 블록 있음([runners.cache])." || info "캐시 설정 없음(로컬 캐시만 사용)."
else
  wn "config.toml(${RUNNER_CONFIG}) 없음/읽기불가 — 아직 register 안 됐거나 경로가 다름."
fi

# systemd 서비스
if have systemctl; then
  if systemctl is-active --quiet gitlab-runner 2>/dev/null; then ok "systemd: gitlab-runner active"; else wn "gitlab-runner 서비스가 active 아님."; fi
  if systemctl is-active --quiet amazon-ssm-agent 2>/dev/null; then ok "systemd: amazon-ssm-agent active (Session Manager 접속 가능)"; else wn "amazon-ssm-agent 비활성 — SSM 접속 불가 가능."; fi
fi

# gitlab-runner 의 docker 그룹 소속
if id "${RUNNER_USER}" >/dev/null 2>&1; then
  if id -nG "${RUNNER_USER}" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
    ok "${RUNNER_USER} 가 docker 그룹 소속 (CDK 번들링 docker.sock 접근 가능)"
  else
    bad "${RUNNER_USER} 가 docker 그룹이 아님 — 잡에서 docker 사용 불가."
  fi
else
  wn "${RUNNER_USER} 사용자 없음."
fi

# ==============================================================================
# 4. IMDSv2 / 인스턴스 역할
# ==============================================================================
section "4. IMDSv2 / 인스턴스 역할"
imds_token="$(curl -fsS --max-time 5 -X PUT 'http://169.254.169.254/latest/api/token' -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' 2>/dev/null || true)"
if [[ -n "$imds_token" ]]; then
  ok "IMDSv2 토큰 획득 OK"
  iid="$(curl -fsS --max-time 5 -H "X-aws-ec2-metadata-token: $imds_token" 'http://169.254.169.254/latest/meta-data/instance-id' 2>/dev/null || true)"
  role="$(curl -fsS --max-time 5 -H "X-aws-ec2-metadata-token: $imds_token" 'http://169.254.169.254/latest/meta-data/iam/security-credentials/' 2>/dev/null || true)"
  info "instance-id=${iid:-unknown}"
  if [[ -n "$role" ]]; then ok "인스턴스 프로파일 역할: ${role}"; else bad "인스턴스에 IAM 역할이 붙어있지 않음 — 모든 AWS 호출 실패."; fi
else
  # IMDSv1 으로도 시도해서 'IMDSv2 미강제' 를 잡아냄
  if curl -fsS --max-time 5 'http://169.254.169.254/latest/meta-data/instance-id' >/dev/null 2>&1; then
    wn "IMDSv1 은 응답하지만 IMDSv2 토큰 실패 — HttpTokens=required(IMDSv2 강제) 설정 권장."
  else
    bad "IMDS 응답 없음 — 메타데이터 hop limit/네트워크 확인."
  fi
fi

# ==============================================================================
# 5. 네트워크 — VPC 엔드포인트 DNS(Private DNS) + TCP 443
# ==============================================================================
if [[ "${SKIP_NET}" == "1" ]]; then
  section "5. 네트워크 (SKIP_NET=1 로 생략)"
else
  section "5. 네트워크 — VPC 엔드포인트 도달성 (DNS + TCP 443)"
  info "사설 IP 로 해석되면 Private DNS 활성 interface endpoint, 공인 IP 면 (S3 게이트웨이 제외) Private DNS 미설정 의심."
  R="${AWS_REGION}"
  # 형식: "표시명|호스트네임|종류(iface|gw)"
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
      bad "${name}: DNS 해석 실패 (${host})"
      continue
    fi
    # DNS 종류별 판정
    if [[ "$kind" == "iface" ]]; then
      if is_private_ip "$ip"; then dnsmsg="사설IP ${ip} (Private DNS OK)"; dnsok=1
      else dnsmsg="공인IP ${ip} (Private DNS 미설정 의심 → 인터넷 없으면 hang)"; dnsok=0; fi
    else
      dnsmsg="${ip} (게이트웨이: 공인IP 정상, 라우팅은 prefix-list 경유)"; dnsok=1
    fi
    # TCP 443
    if tcp443 "$host" 443 5; then
      if [[ "$dnsok" -eq 1 ]]; then ok "${name}: TCP443 OK / ${dnsmsg}"
      else wn "${name}: TCP443 OK 이나 ${dnsmsg}"; fi
    else
      if [[ "$kind" == "iface" && "$dnsok" -eq 0 ]]; then
        bad "${name}: TCP443 실패 / ${dnsmsg} — interface endpoint+Private DNS 미구성."
      else
        bad "${name}: TCP443 실패 / ${dnsmsg} — 엔드포인트/SG(443) 확인."
      fi
    fi
  done
  info "(옵션 엔드포인트 secretsmanager/ec2/dynamodb 는 사용 시에만 필요 — 여기선 미점검.)"
fi

# ==============================================================================
# 6. CodeArtifact 인증
# ==============================================================================
if [[ "${SKIP_AWS}" == "1" ]]; then
  section "6. CodeArtifact (SKIP_AWS=1 로 생략)"
else
  section "6. CodeArtifact 인증/엔드포인트"
  if ! have aws; then
    wn "aws CLI 없어 CodeArtifact 점검 생략."
  else
    # 호출자 신원
    cid="$(awsr sts get-caller-identity --query Arn --output text 2>&1)"; crc=$?
    if [[ $crc -eq 0 ]]; then ok "sts get-caller-identity: ${cid}"; else bad "sts get-caller-identity 실패 — STS 엔드포인트/역할 확인: ${cid}"; fi

    tok="$(awsr codeartifact get-authorization-token --domain "${CA_DOMAIN}" --domain-owner "${CA_DOMAIN_OWNER}" --query authorizationToken --output text 2>&1)"; trc=$?
    if [[ $trc -eq 0 && -n "$tok" && "$tok" != "None" ]]; then
      ok "CodeArtifact 토큰 발급 OK (domain=${CA_DOMAIN}) — sts:GetServiceBearerToken 권한 정상."
    else
      bad "CodeArtifact 토큰 실패 — sts:GetServiceBearerToken(조건 codeartifact) 또는 codeartifact:GetAuthorizationToken 누락 가능: ${tok}"
    fi

    for repo in "${CA_NPM_REPO}:npm" "${CA_PYPI_REPO}:pypi"; do
      rname="${repo%%:*}"; fmt="${repo##*:}"
      ep="$(awsr codeartifact get-repository-endpoint --domain "${CA_DOMAIN}" --domain-owner "${CA_DOMAIN_OWNER}" --repository "${rname}" --format "${fmt}" --query repositoryEndpoint --output text 2>&1)"; erc=$?
      if [[ $erc -eq 0 && "$ep" == https://* ]]; then
        ok "repo-endpoint(${fmt}/${rname}): ${ep}"
        ephost="${ep#https://}"; ephost="${ephost%%/*}"
        if [[ "${SKIP_NET}" != "1" ]]; then
          tcp443 "$ephost" 443 5 && ok "  └ ${fmt} 저장소 TCP443 OK" || bad "  └ ${fmt} 저장소(${ephost}) TCP443 실패 — codeartifact.repositories 엔드포인트/S3 게이트웨이 확인."
        fi
      else
        bad "repo-endpoint(${fmt}/${rname}) 실패 — 저장소 존재/권한 확인: ${ep}"
      fi
    done
  fi
fi

# ==============================================================================
# 7. 크로스계정 AssumeRole
# ==============================================================================
if [[ "${SKIP_AWS}" == "1" || "${SKIP_XACCT}" == "1" || -z "${TARGET_ACCOUNTS// /}" ]]; then
  section "7. 크로스계정 AssumeRole (생략)"
  info "SKIP_AWS/SKIP_XACCT 또는 TARGET_ACCOUNTS 비어있음."
else
  section "7. 크로스계정 sts:AssumeRole 실제 시도"
  if ! have aws; then
    wn "aws CLI 없어 생략."
  else
    extid_args=(); [[ -n "${EXTERNAL_ID}" ]] && extid_args=(--external-id "${EXTERNAL_ID}")
    for acct in ${TARGET_ACCOUNTS}; do
      a_ok=0
      # Model A: CDK 부트스트랩 deploy-role
      a_role="arn:aws:iam::${acct}:role/cdk-${CDK_QUALIFIER}-deploy-role-${acct}-${AWS_REGION}"
      if awsr sts assume-role --role-arn "$a_role" --role-session-name "diag-${acct}" --duration-seconds 900 >/dev/null 2>&1; then
        ok "계정 ${acct}: Model A 가정 OK (cdk-${CDK_QUALIFIER}-deploy-role)"; a_ok=1
      fi
      # Model B: OrgDeployRole
      b_role="arn:aws:iam::${acct}:role/${ORG_DEPLOY_ROLE}"
      if awsr sts assume-role --role-arn "$b_role" --role-session-name "diag-${acct}" --duration-seconds 900 "${extid_args[@]+"${extid_args[@]}"}" >/dev/null 2>&1; then
        ok "계정 ${acct}: Model B 가정 OK (${ORG_DEPLOY_ROLE})"; a_ok=1
      fi
      if [[ $a_ok -eq 0 ]]; then
        bad "계정 ${acct}: A/B 모두 가정 실패 — 타겟 부트스트랩(--trust) 또는 ${ORG_DEPLOY_ROLE} 신뢰정책/ExternalId 확인."
      fi
    done
    info "(cross-account CodeBuild StartBuild 는 가정한 타겟 역할에서 수행되어야 함 — RunnerRole 직접 불가.)"
  fi
fi

# ==============================================================================
# 요약
# ==============================================================================
section "요약 (Summary)"
printf '  %bPASS=%d%b  %bWARN=%d%b  %bFAIL=%d%b\n' "$c_g" "$PASS" "$c_0" "$c_y" "$WARN" "$c_0" "$c_r" "$FAIL" "$c_0"
if [[ $FAIL -eq 0 && $WARN -eq 0 ]]; then
  printf '  %b모든 점검 통과 — 잡 실행 준비 완료.%b\n' "$c_g" "$c_0"
elif [[ $FAIL -eq 0 ]]; then
  printf '  %bFAIL 없음. WARN 항목은 사용 시나리오에 따라 검토.%b\n' "$c_y" "$c_0"
else
  printf '  %bFAIL 항목을 먼저 해결하세요(위 [FAIL] 라인 참고).%b\n' "$c_r" "$c_0"
fi

# JSON 요약(선택): DIAG_JSON=1 이면 stderr 로 출력(파이프라인에서 파싱 용이)
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

# 종료 코드: FAIL 있으면 1
[[ $FAIL -eq 0 ]]
