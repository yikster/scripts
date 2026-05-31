#!/usr/bin/env bash
# codeartifact-login.sh
# ──────────────────────────────────────────────────────────────────────────────
# AWS CodeArtifact 12h 토큰을 갱신하고 npm/pip/uv (옵션: poetry/twine) 를 설정한다.
#
# 듀얼 모드:
#   1) 직접 실행 (./codeartifact-login.sh) : set -euo pipefail 로 엄격 실행, 실패 시 exit.
#   2) source ( . ./codeartifact-login.sh ): CI before_script 용.
#      - 자동으로 ca_main 을 호출한다 (호출부는 별도 호출 불필요).
#      - 단, source 된 셸의 -e 를 오염시키지 않으며, 실패 시 exit 대신 return 한다.
#        => 호출부(before_script)는 반드시 토큰 비어있음을 직접 검증해야 한다:
#             . /usr/local/bin/codeartifact-login.sh
#             [ -n "${CODEARTIFACT_AUTH_TOKEN:-}" ] || { echo "CA login failed"; exit 1; }
#
# 중요(프라이빗 서브넷): CodeArtifact 도메인은 *러너 계정* 소유다. 잡에서 AWS_PROFILE
# (cross-account deploy role) 이 설정돼 있으면 토큰 호출이 엉뚱한 계정으로 가므로,
# CodeArtifact 호출은 항상 AWS_PROFILE 을 비워(instance role) 수행한다.
# ──────────────────────────────────────────────────────────────────────────────

# source 여부 감지
_ca_sourced=0
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  _ca_sourced=1
fi

# 직접 실행일 때만 엄격 모드 (source 시 호출부 -e 오염 방지)
if [[ "${_ca_sourced}" -eq 0 ]]; then
  set -euo pipefail
fi

# ==============================================================================
# 공유 설정 헤더 (companion 스크립트들과 동일 변수명)
# ==============================================================================
AWS_REGION="${AWS_REGION:-ap-northeast-2}"
CA_DOMAIN="${CA_DOMAIN:-my-domain}"
CA_DOMAIN_OWNER="${CA_DOMAIN_OWNER:-999999999999}"   # CodeArtifact 도메인 소유 = 러너 계정
CA_NPM_REPO="${CA_NPM_REPO:-npm-store}"
CA_PYPI_REPO="${CA_PYPI_REPO:-pypi-store}"

# 도구별 토글
CONFIGURE_NPM="${CONFIGURE_NPM:-true}"
CONFIGURE_PIP="${CONFIGURE_PIP:-true}"
CONFIGURE_UV="${CONFIGURE_UV:-true}"
CONFIGURE_POETRY="${CONFIGURE_POETRY:-false}"
CONFIGURE_TWINE="${CONFIGURE_TWINE:-false}"

# uv 네임드 인덱스 이름 (pyproject.toml 의 [[tool.uv.index]] name 과 반드시 일치해야 함)
# 환경변수 세그먼트는 대문자 + 비영숫자->underscore 규칙: private-registry -> PRIVATE_REGISTRY
UV_INDEX_NAME="${UV_INDEX_NAME:-private-registry}"

# ==============================================================================
# 유틸
# ==============================================================================
_ca_log()  { printf '\033[1;34m[ca]\033[0m %s\n' "$*"; }
_ca_warn() { printf '\033[1;33m[ca-warn]\033[0m %s\n' "$*" >&2; }

# 실패 처리: 직접 실행이면 exit, source 면 return (exported 변수 보존).
_ca_fail() {
  printf '\033[1;31m[ca-fail]\033[0m %s\n' "$*" >&2
  if [[ "${_ca_sourced}" -eq 1 ]]; then
    return 1
  else
    exit 1
  fi
}

# HOME 해석 (root/sudo/systemd 모두 안전)
_ca_resolve_home() {
  if [[ -n "${HOME:-}" && -d "${HOME}" ]]; then
    printf '%s' "${HOME}"
    return 0
  fi
  # systemd/cron 등에서 HOME 이 비어있을 때
  local u; u="$(id -un)"
  getent passwd "${u}" | cut -d: -f6
}

# 환경변수 세그먼트 변환: private-registry -> PRIVATE_REGISTRY
_ca_env_segment() {
  printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_'
}

# ==============================================================================
# 토큰 + 엔드포인트 취득 (항상 instance role 로; AWS_PROFILE 오염 방지)
# ==============================================================================
ca_fetch_token_and_endpoints() {
  command -v aws >/dev/null 2>&1 || { _ca_fail "aws CLI 가 없습니다."; return 1; }

  # AWS_PROFILE 을 비워 instance role(러너 계정)로 강제. STS 는 리전 엔드포인트.
  local token
  token="$(AWS_PROFILE= AWS_STS_REGIONAL_ENDPOINTS=regional \
            aws codeartifact get-authorization-token \
              --domain "${CA_DOMAIN}" \
              --domain-owner "${CA_DOMAIN_OWNER}" \
              --region "${AWS_REGION}" \
              --query authorizationToken --output text 2>/dev/null)" || true

  if [[ -z "${token}" || "${token}" == "None" ]]; then
    _ca_fail "CodeArtifact 토큰 발급 실패. 확인: sts:GetServiceBearerToken 권한, codeartifact.api 엔드포인트, AWS_PROFILE 누수."
    return 1
  fi
  export CODEARTIFACT_AUTH_TOKEN="${token}"

  CA_NPM_ENDPOINT="$(AWS_PROFILE= aws codeartifact get-repository-endpoint \
      --domain "${CA_DOMAIN}" --domain-owner "${CA_DOMAIN_OWNER}" \
      --repository "${CA_NPM_REPO}" --format npm \
      --region "${AWS_REGION}" --query repositoryEndpoint --output text 2>/dev/null)" || true
  CA_PYPI_ENDPOINT="$(AWS_PROFILE= aws codeartifact get-repository-endpoint \
      --domain "${CA_DOMAIN}" --domain-owner "${CA_DOMAIN_OWNER}" \
      --repository "${CA_PYPI_REPO}" --format pypi \
      --region "${AWS_REGION}" --query repositoryEndpoint --output text 2>/dev/null)" || true

  if [[ -z "${CA_NPM_ENDPOINT:-}" || "${CA_NPM_ENDPOINT}" == "None" ]]; then
    _ca_fail "npm 레포 엔드포인트 조회 실패 (codeartifact.api 엔드포인트/권한 확인)."; return 1
  fi
  if [[ -z "${CA_PYPI_ENDPOINT:-}" || "${CA_PYPI_ENDPOINT}" == "None" ]]; then
    _ca_fail "pypi 레포 엔드포인트 조회 실패."; return 1
  fi
  export CA_NPM_ENDPOINT CA_PYPI_ENDPOINT
  _ca_log "토큰/엔드포인트 취득 완료 (npm=${CA_NPM_ENDPOINT}, pypi=${CA_PYPI_ENDPOINT})"
  return 0
}

# ==============================================================================
# npm (.npmrc)
# ==============================================================================
ca_configure_npm() {
  [[ "${CONFIGURE_NPM}" == "true" ]] || return 0
  local home host
  home="$(_ca_resolve_home)"
  # registry URL 에서 스킴 제거 -> //host/path/ 형태의 authToken 키 생성
  host="${CA_NPM_ENDPOINT#https://}"

  umask 077
  cat > "${home}/.npmrc" <<EOF
registry=${CA_NPM_ENDPOINT}
//${host}:_authToken=${CODEARTIFACT_AUTH_TOKEN}
//${host}:always-auth=true
# 스코프 패키지 예시:
# @myorg:registry=${CA_NPM_ENDPOINT}
EOF
  chmod 600 "${home}/.npmrc"
  _ca_log "npm 설정 완료: ${home}/.npmrc"
}

# ==============================================================================
# pip (~/.config/pip/pip.conf) — 토큰은 conf 파일(600)에만 두고 env 로 export 하지 않는다.
# (PIP_INDEX_URL 로 export 하면 CI_DEBUG_TRACE/set -x 시 토큰이 로그로 새어나간다.)
# ==============================================================================
ca_configure_pip() {
  [[ "${CONFIGURE_PIP}" == "true" ]] || return 0
  local home host enc_token index_url cfg_dir
  home="$(_ca_resolve_home)"
  host="${CA_PYPI_ENDPOINT#https://}"
  host="${host%/}"

  # 토큰을 URL userinfo 로 안전하게 인코딩 (드물지만 URL-unsafe 문자 대비)
  if command -v python3 >/dev/null 2>&1; then
    enc_token="$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "${CODEARTIFACT_AUTH_TOKEN}")"
  else
    enc_token="${CODEARTIFACT_AUTH_TOKEN}"
  fi

  # pip index-url 은 반드시 /simple/ 로 끝나야 한다.
  index_url="https://aws:${enc_token}@${host}/simple/"

  cfg_dir="${home}/.config/pip"
  install -d -m 700 "${cfg_dir}"
  umask 077
  cat > "${cfg_dir}/pip.conf" <<EOF
[global]
index-url = ${index_url}
EOF
  chmod 600 "${cfg_dir}/pip.conf"
  # 부모 디렉터리도 그룹/기타 읽기 차단
  chmod 700 "${home}/.config" 2>/dev/null || true
  # 명시적으로 PIP_INDEX_URL 을 *export 하지 않는다* (토큰 로그 누수 방지).
  unset PIP_INDEX_URL || true
  _ca_log "pip 설정 완료: ${cfg_dir}/pip.conf (토큰은 env 로 노출하지 않음)"
}

# ==============================================================================
# uv (네임드 인덱스 + 자격증명; UV_DEFAULT_INDEX 로 PyPI 대체)
# uv 는 UV_INDEX_<NAME>_USERNAME/PASSWORD 를 *이름 있는* 인덱스에만 매칭한다.
# 따라서 UV_INDEX="name=url" 로 이름을 부여하고, 동일 NAME 세그먼트로 자격증명을 준다.
# ==============================================================================
ca_configure_uv() {
  [[ "${CONFIGURE_UV}" == "true" ]] || return 0
  local host index_url seg
  host="${CA_PYPI_ENDPOINT#https://}"
  host="${host%/}"
  index_url="https://${host}/simple/"
  seg="$(_ca_env_segment "${UV_INDEX_NAME}")"   # private-registry -> PRIVATE_REGISTRY

  # 네임드 인덱스 정의 + 기본 인덱스로 지정 (공개 PyPI 대체)
  export UV_INDEX="${UV_INDEX_NAME}=${index_url}"
  export UV_DEFAULT_INDEX="${index_url}"
  # 동일 이름 세그먼트로 자격증명 (UV_INDEX_PRIVATE_REGISTRY_USERNAME/PASSWORD)
  export "UV_INDEX_${seg}_USERNAME=aws"
  export "UV_INDEX_${seg}_PASSWORD=${CODEARTIFACT_AUTH_TOKEN}"

  if [[ "${_ca_sourced}" -eq 0 ]]; then
    _ca_warn "uv 환경변수는 *현재 셸*에만 export 됩니다. CI 에서는 이 스크립트를 'source' 하세요."
  fi
  _ca_log "uv 설정 완료 (index name='${UV_INDEX_NAME}'; pyproject 의 인덱스 이름이 동일해야 함)"
}

# ==============================================================================
# poetry (옵션) — POETRY_HTTP_BASIC_* (source 시에만 propagate)
# ==============================================================================
ca_configure_poetry() {
  [[ "${CONFIGURE_POETRY}" == "true" ]] || return 0
  local host
  host="${CA_PYPI_ENDPOINT#https://}"; host="${host%/}"
  # poetry repository 이름은 'private' 로 가정 (pyproject 의 source name 과 일치 필요)
  export POETRY_REPOSITORIES_PRIVATE_URL="https://${host}/simple/"
  export POETRY_HTTP_BASIC_PRIVATE_USERNAME="aws"
  export POETRY_HTTP_BASIC_PRIVATE_PASSWORD="${CODEARTIFACT_AUTH_TOKEN}"
  if [[ "${_ca_sourced}" -eq 0 ]]; then
    _ca_warn "poetry 환경변수는 source 시에만 propagate 됩니다."
  fi
  _ca_log "poetry 설정 완료 (source name 'private' 가정)"
}

# ==============================================================================
# twine (옵션) — ~/.pypirc
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
  _ca_log "twine 설정 완료: ${home}/.pypirc"
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
  # 성공 센티넬 (호출부가 확인 가능)
  export CA_LOGIN_OK=1
  _ca_log "CodeArtifact 로그인 완료 (토큰 TTL 최대 12h — 잡마다 재실행 필요)."
  return 0
}

# 디스패치: 직접 실행/소스 모두 ca_main 을 호출한다.
# source 시 ca_main 실패는 return 으로 처리되며 export 된 변수는 보존된다.
# (before_script 는 CODEARTIFACT_AUTH_TOKEN/CA_LOGIN_OK 로 성공을 직접 검증할 것)
ca_main || _ca_fail "CodeArtifact 설정 중 실패"

# ──────────────────────────────────────────────────────────────────────────────
# (옵션) systemd 타이머 백업 — before_script 가 주 갱신 경로, 타이머는 보조.
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
