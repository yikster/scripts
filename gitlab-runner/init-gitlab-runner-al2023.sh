#!/usr/bin/env bash
# init-gitlab-runner-al2023.sh
# ──────────────────────────────────────────────────────────────────────────────
# AL2023 EC2 GitLab Runner 부트스트랩 (shell executor + mise + host Docker)
#
# 대상: 프라이빗 서브넷(인터넷 게이트웨이/NAT egress 없음, VPC 엔드포인트만)에서
#       동작하는 GitLab Runner 호스트.
#
# 핵심 설계:
#   - GOLDEN_AMI=true  : egress 가 가능한 빌드 계정에서 미리 구워둔 AMI 기준.
#                        다운로드가 필요한 단계는 SKIP 하고, 사전 설치 여부만 검증한다.
#                        (mise/aws/gitlab-runner/docker/git 누락 시 die)
#   - GOLDEN_AMI=false : egress 가능한 빌드 계정에서 실제 다운로드/설치를 수행한다.
#
#   - 셸 executor 는 비-로그인(non-login) bash 로 잡을 실행한다. 비-로그인 bash 는
#     /etc/profile, /etc/profile.d/*.sh 를 읽지 않으므로, 런타임(PATH/mise shims)을
#     config.toml 의 environment[] (BASH_ENV/MISE_DATA_DIR/MISE_CONFIG_DIR) 로 주입한다.
#     /etc/profile.d/mise.sh 는 사람이 SSM 으로 로그인했을 때를 위한 보조 수단이다.
#
# 멱등성: 모든 다운로드는 need_egress 게이트를 통과해야 하며, 재실행 시 안전하다.
# bash -n 통과, chmod +x.
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ==============================================================================
# 공유 설정 헤더 (companion 스크립트들과 변수명 동일하게 유지)
# ==============================================================================
AWS_REGION="${AWS_REGION:-ap-northeast-2}"
RUNNER_ACCOUNT_ID="${RUNNER_ACCOUNT_ID:-999999999999}"   # 러너가 사는 계정 (CodeArtifact 도메인 소유 계정)

# CodeArtifact (러너 계정 소유)
CA_DOMAIN="${CA_DOMAIN:-my-domain}"
CA_DOMAIN_OWNER="${CA_DOMAIN_OWNER:-$RUNNER_ACCOUNT_ID}"
CA_NPM_REPO="${CA_NPM_REPO:-npm-store}"
CA_PYPI_REPO="${CA_PYPI_REPO:-pypi-store}"

# GitLab
GITLAB_URL="${GITLAB_URL:-https://gitlab.example.com}"
# glrt-* 인증 토큰 (GitLab 18.0 부터 legacy registration-token 제거됨).
# UI 에서 instance/project runner 생성 후 발급된 glrt-* 토큰을 넣는다.
GITLAB_RUNNER_TOKEN="${GITLAB_RUNNER_TOKEN:-}"
RUNNER_NAME="${RUNNER_NAME:-al2023-private-shell-runner}"
RUNNER_TAGS="${RUNNER_TAGS:-shell,cdk,aws-private}"

# 런타임 버전 매트릭스
NODE_VERSIONS=(18 20 22)
PYTHON_VERSIONS=(3.10 3.11 3.12)
# 글로벌 기본값 (잡에서 .mise.toml/.tool-versions 또는 `mise use` 로 오버라이드 가능)
MISE_GLOBAL_NODE="${MISE_GLOBAL_NODE:-20}"
MISE_GLOBAL_PYTHON="${MISE_GLOBAL_PYTHON:-3.11}"

# mise 경로 — root 빌드 설치 결과를 gitlab-runner 런타임 셸과 공유하기 위해
# data/config 를 시스템 공용 위치로 둔다.
MISE_BIN="${MISE_BIN:-/usr/local/bin/mise}"
MISE_DATA_DIR="${MISE_DATA_DIR:-/usr/local/share/mise}"
MISE_CONFIG_DIR="${MISE_CONFIG_DIR:-/etc/mise}"

# 골든 AMI 모드 (true=다운로드 skip + 사전설치 검증, false=다운로드 수행)
GOLDEN_AMI="${GOLDEN_AMI:-true}"

# gitlab-runner 사용자/홈
RUNNER_USER="gitlab-runner"
RUNNER_HOME="/home/${RUNNER_USER}"
RUNNER_CONFIG="/etc/gitlab-runner/config.toml"

# gitlab-runner 바이너리 (검증용 sha256 은 배포 시 채워 넣는다; 빈 값이면 검증 skip)
GITLAB_RUNNER_VERSION="${GITLAB_RUNNER_VERSION:-latest}"
GITLAB_RUNNER_SHA256="${GITLAB_RUNNER_SHA256:-}"

# ==============================================================================
# 유틸리티
# ==============================================================================
log()  { printf '\033[1;34m[init]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

# 다운로드가 필요한 작업의 게이트.
# GOLDEN_AMI=true 이면 false 를 반환 -> 호출부는 다운로드를 건너뛴다.
need_egress() {
  if [[ "${GOLDEN_AMI}" == "true" ]]; then
    return 1
  fi
  return 0
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "root 권한이 필요합니다. sudo 로 실행하세요."
  fi
}

# ==============================================================================
# STEP 1. 시스템 패키지 (docker, git, 빌드 의존성)
# ==============================================================================
install_system_packages() {
  log "STEP 1: 시스템 패키지 확인/설치 (GOLDEN_AMI=${GOLDEN_AMI})"

  if need_egress; then
    # 아래 다운로드는 egress 가 있는 빌드 계정에서만 성공한다.
    dnf update -y
    # python-build-standalone 사용 시 컴파일 툴체인은 사실 불필요하지만,
    # 일부 네이티브 npm 모듈/CDK 번들링을 위해 기본 빌드 도구는 포함한다.
    dnf install -y \
      git docker tar gzip xz which shadow-utils \
      gcc gcc-c++ make openssl-devel bzip2-devel libffi-devel \
      zlib-devel readline-devel sqlite-devel xz-devel
  else
    # 골든 AMI 모드: docker/git 은 셸 executor 의 하드 의존성이므로 누락 시 die.
    # (CDK NodejsFunction/PythonFunction 번들링은 docker.sock 을 사용)
    command -v docker >/dev/null 2>&1 || die "GOLDEN_AMI 모드인데 docker 가 없습니다. AMI 빌드 단계에서 설치하세요."
    command -v git    >/dev/null 2>&1 || die "GOLDEN_AMI 모드인데 git 이 없습니다. AMI 빌드 단계에서 설치하세요."
    log "  docker, git 사전 설치 확인 완료"
  fi
}

# ==============================================================================
# STEP 2. Docker 활성화 + gitlab-runner 사용자
# ==============================================================================
setup_docker_and_user() {
  log "STEP 2: Docker 활성화 + ${RUNNER_USER} 사용자 구성"

  command -v docker >/dev/null 2>&1 || die "docker 미설치 — STEP 1 을 먼저 통과해야 합니다."

  systemctl enable docker
  systemctl start docker

  # gitlab-runner 사용자 생성 (멱등)
  if ! id -u "${RUNNER_USER}" >/dev/null 2>&1; then
    useradd --system --create-home --home-dir "${RUNNER_HOME}" --shell /bin/bash "${RUNNER_USER}"
    log "  ${RUNNER_USER} 사용자 생성"
  else
    log "  ${RUNNER_USER} 사용자 이미 존재"
  fi

  # docker 그룹 추가 (그룹 반영은 서비스 재시작/재로그인 후 적용됨)
  usermod -aG docker "${RUNNER_USER}"
}

# ==============================================================================
# STEP 3. AWS CLI v2
# ==============================================================================
install_awscli() {
  log "STEP 3: AWS CLI v2 확인/설치"

  if command -v aws >/dev/null 2>&1; then
    log "  aws 이미 설치됨: $(aws --version 2>&1)"
    return 0
  fi

  if need_egress; then
    local tmp arch url
    tmp="$(mktemp -d)"
    arch="$(uname -m)"  # x86_64 또는 aarch64
    url="https://awscli.amazonaws.com/awscli-exe-linux-${arch}.zip"
    log "  다운로드: ${url}"
    curl -fsSL "${url}" -o "${tmp}/awscliv2.zip"
    ( cd "${tmp}" && unzip -q awscliv2.zip && ./aws/install --update )
    rm -rf "${tmp}"
  else
    die "GOLDEN_AMI 모드인데 aws CLI 가 없습니다. AMI 빌드 단계에서 설치하세요."
  fi
}

# ==============================================================================
# STEP 4. mise + Node/Python 다중 버전 설치 (시스템 공용 위치)
# ==============================================================================
install_mise_and_runtimes() {
  log "STEP 4: mise + 런타임 설치/검증"

  install -d -m 0755 "${MISE_DATA_DIR}" "${MISE_CONFIG_DIR}"

  if [[ ! -x "${MISE_BIN}" ]]; then
    if need_egress; then
      log "  mise 다운로드 (https://mise.run)"
      curl -fsSL https://mise.run | MISE_INSTALL_PATH="${MISE_BIN}" sh
    else
      die "GOLDEN_AMI 모드인데 mise 가 없습니다 (${MISE_BIN}). AMI 빌드 단계에서 설치하세요."
    fi
  else
    log "  mise 이미 설치됨: $(${MISE_BIN} --version 2>&1 | head -n1)"
  fi

  # mise 가 시스템 공용 data/config 를 쓰도록 환경 고정
  export MISE_DATA_DIR MISE_CONFIG_DIR
  export MISE_YES=1   # 비대화식 동의

  # 런타임 설치 (egress 필요). 골든 AMI 모드면 설치 대신 존재 검증.
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
    # 글로벌 기본값 지정
    "${MISE_BIN}" use --global "node@${MISE_GLOBAL_NODE}" "python@${MISE_GLOBAL_PYTHON}"
    "${MISE_BIN}" reshim
  else
    for v in "${NODE_VERSIONS[@]}"; do
      "${MISE_BIN}" ls "node@${v}" >/dev/null 2>&1 || die "node@${v} 미설치 (골든 AMI). 빌드 단계에서 설치하세요."
    done
    for v in "${PYTHON_VERSIONS[@]}"; do
      "${MISE_BIN}" ls "python@${v}" >/dev/null 2>&1 || die "python@${v} 미설치 (골든 AMI). 빌드 단계에서 설치하세요."
    done
    log "  모든 node/python 버전 사전 설치 확인 완료"
  fi

  # 공용 디렉터리는 gitlab-runner 가 읽을 수 있어야 한다 (실행은 reshim 으로 충분).
  chmod -R a+rX "${MISE_DATA_DIR}" "${MISE_CONFIG_DIR}"
}

# ==============================================================================
# STEP 5. /etc/profile.d/mise.sh (사람 로그인용 보조) + 글로벌 환경 파일
# ==============================================================================
write_mise_profile() {
  log "STEP 5: /etc/profile.d/mise.sh 작성 (사람 SSM 로그인 보조)"

  # 주의: 이 파일은 *로그인 셸*에서만 source 된다.
  #       gitlab-runner 의 잡 셸은 비-로그인 이므로 여기에 의존하지 않는다.
  #       잡의 실제 런타임 주입은 STEP 7 의 config.toml environment[] 에서 한다.
  cat > /etc/profile.d/mise.sh <<EOF
# Managed by init-gitlab-runner-al2023.sh — 사람 로그인(SSM) 보조용
export MISE_DATA_DIR=${MISE_DATA_DIR}
export MISE_CONFIG_DIR=${MISE_CONFIG_DIR}
export AWS_REGION=${AWS_REGION}
export AWS_DEFAULT_REGION=${AWS_REGION}
# STS 는 반드시 리전 엔드포인트(in-VPC interface endpoint)를 쓴다 (global 은 엔드포인트 없음)
export AWS_STS_REGIONAL_ENDPOINTS=regional
if [ -x ${MISE_BIN} ]; then
  eval "\$(${MISE_BIN} activate bash --shims)"
fi
EOF
  chmod 0644 /etc/profile.d/mise.sh

  # 비-로그인 bash 가 자동으로 읽는 유일한 파일을 위한 환경 스크립트.
  # config.toml 의 BASH_ENV 가 이 파일을 가리킨다 (STEP 7 참조).
  cat > /etc/profile.d/mise-shims.sh <<EOF
# Managed by init-gitlab-runner-al2023.sh — BASH_ENV 로 비-로그인 잡 셸에 주입됨
export MISE_DATA_DIR=${MISE_DATA_DIR}
export MISE_CONFIG_DIR=${MISE_CONFIG_DIR}
export AWS_REGION=${AWS_REGION}
export AWS_DEFAULT_REGION=${AWS_REGION}
export AWS_STS_REGIONAL_ENDPOINTS=regional
# shims 디렉터리를 PATH 최우선으로
export PATH=${MISE_DATA_DIR}/shims:\$PATH
EOF
  chmod 0644 /etc/profile.d/mise-shims.sh
}

# ==============================================================================
# STEP 6. gitlab-runner 바이너리 설치 + systemd 서비스 + 등록
# ==============================================================================
install_gitlab_runner() {
  log "STEP 6: gitlab-runner 설치/등록"

  if ! command -v gitlab-runner >/dev/null 2>&1; then
    if need_egress; then
      local arch dl
      case "$(uname -m)" in
        x86_64)  arch="amd64" ;;
        aarch64) arch="arm64" ;;
        *) die "지원하지 않는 아키텍처: $(uname -m)" ;;
      esac
      dl="https://gitlab-runner-downloads.s3.amazonaws.com/${GITLAB_RUNNER_VERSION}/binaries/gitlab-runner-linux-${arch}"
      log "  다운로드: ${dl}"
      curl -fsSL "${dl}" -o /usr/local/bin/gitlab-runner
      if [[ -n "${GITLAB_RUNNER_SHA256}" ]]; then
        echo "${GITLAB_RUNNER_SHA256}  /usr/local/bin/gitlab-runner" | sha256sum -c - \
          || die "gitlab-runner sha256 검증 실패"
      else
        warn "GITLAB_RUNNER_SHA256 미설정 — 바이너리 무결성 검증을 건너뜁니다."
      fi
      chmod +x /usr/local/bin/gitlab-runner
    else
      die "GOLDEN_AMI 모드인데 gitlab-runner 바이너리가 없습니다. AMI 빌드 단계에서 설치하세요."
    fi
  else
    log "  gitlab-runner 이미 설치됨: $(gitlab-runner --version 2>&1 | head -n1)"
  fi

  # systemd 서비스 설치 (멱등)
  if ! systemctl list-unit-files 2>/dev/null | grep -q '^gitlab-runner\.service'; then
    gitlab-runner install --user="${RUNNER_USER}" --working-directory="${RUNNER_HOME}"
  fi
  systemctl enable gitlab-runner

  register_runner
}

# 등록은 RUNNER_NAME + GITLAB_URL 조합으로 멱등 처리한다.
# (executor 타입만 보는 약한 가드는 토큰 회전/중복 등록 문제가 있어 사용하지 않는다.)
register_runner() {
  if [[ -z "${GITLAB_RUNNER_TOKEN}" ]]; then
    warn "GITLAB_RUNNER_TOKEN 미설정 — 등록을 건너뜁니다. 토큰 설정 후 재실행하세요."
    return 0
  fi

  # GitLab 도달성 사전 점검 (프라이빗 서브넷에서 가장 흔한 하드 블로커).
  if command -v curl >/dev/null 2>&1; then
    if ! curl -fsS --max-time 10 -o /dev/null "${GITLAB_URL%/}/-/health" 2>/dev/null \
       && ! curl -fsS --max-time 10 -o /dev/null "${GITLAB_URL%/}/" 2>/dev/null; then
      warn "GitLab(${GITLAB_URL}) 에 도달할 수 없습니다. PrivateLink/프록시/라우팅을 확인하세요."
      warn "  -> 도달 불가 상태로도 등록을 시도하지만 실패할 수 있습니다."
    fi
  fi

  # 죽은(서버측 해제된) 러너 정리 — 재실행/토큰 회전 안전성.
  gitlab-runner verify --delete >/dev/null 2>&1 || true

  # 동일 URL + 동일 RUNNER_NAME 이 config.toml 에 이미 있으면 건너뛴다.
  if [[ -f "${RUNNER_CONFIG}" ]] \
     && grep -q "name = \"${RUNNER_NAME}\"" "${RUNNER_CONFIG}" \
     && grep -q "url = \"${GITLAB_URL%/}\"" "${RUNNER_CONFIG}"; then
    log "  러너 '${RUNNER_NAME}' (${GITLAB_URL}) 이미 등록됨 — skip"
    log "  (태그/URL 변경 시 해당 [[runners]] 블록을 먼저 삭제하거나 토큰을 회전하세요)"
    return 0
  fi

  log "  러너 등록: name=${RUNNER_NAME} url=${GITLAB_URL} tags=${RUNNER_TAGS}"
  # --shell "login bash" 도 가능하지만, 환경 주입을 config.toml environment[] 로
  # 명시(STEP 7)하므로 비-로그인 bash 로 등록한다. 두 방식을 섞지 않는다.
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
# STEP 7. config.toml 튜닝 — builds_dir/cache_dir + environment[] 런타임 주입
# ==============================================================================
tune_runner_config() {
  log "STEP 7: config.toml 튜닝 (environment[] 로 런타임 주입)"

  [[ -f "${RUNNER_CONFIG}" ]] || { warn "config.toml 없음 — 등록 후 다시 실행하세요."; return 0; }
  command -v python3 >/dev/null 2>&1 || die "python3 필요 (config.toml 편집). 골든 AMI 에 python3 를 포함하세요."

  # 멱등 마커로 우리가 관리하는 키만 갱신한다.
  # RUNNER_NAME 에 해당하는 [[runners]] 블록을 대상으로 한다.
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

# [[runners]] 블록 단위 분할
parts = re.split(r'(?m)^\[\[runners\]\]\s*$', text)
# parts[0] 은 글로벌 헤더, parts[1:] 가 각 러너 블록 본문
if len(parts) < 2:
    print("[tune] [[runners]] 블록을 찾지 못했습니다 — skip", file=sys.stderr)
    sys.exit(0)

builds_dir = f'{home}/builds'
cache_dir  = f'{home}/cache'

env_lines = [
    f'BASH_ENV=/etc/profile.d/mise-shims.sh',   # 비-로그인 bash 가 자동 source 하는 유일한 파일
    f'MISE_DATA_DIR={mdata}',
    f'MISE_CONFIG_DIR={mconf}',
    f'AWS_REGION={region}',
    f'AWS_DEFAULT_REGION={region}',
    f'AWS_STS_REGIONAL_ENDPOINTS=regional',     # STS 는 항상 in-VPC 리전 엔드포인트
    f'PATH={mdata}/shims:/usr/local/bin:/usr/bin:/bin',
]
env_toml = "environment = [" + ", ".join(f'"{e}"' for e in env_lines) + "]"

def patch_block(body):
    # name = "..." 매칭으로 대상 블록 식별
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
    # 누락된 키는 블록 시작 직후에 삽입
    inject = []
    if not seen["builds_dir"]:  inject.append(f'  builds_dir = "{builds_dir}"')
    if not seen["cache_dir"]:   inject.append(f'  cache_dir = "{cache_dir}"')
    if not seen["environment"]: inject.append("  " + env_toml)
    if inject:
        # 첫 비어있지 않은 줄(name 등) 다음에 삽입
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
    print(f"[tune] name=\"{name}\" 블록을 찾지 못했습니다 — skip", file=sys.stderr)
    sys.exit(0)

new_text = "[[runners]]".join(new_parts)
# split 이 분리자를 제거했으므로 재조립: parts[0] + ('[[runners]]'+body) ...
# 위 join 은 parts[0] 와 첫 블록 사이에도 '[[runners]]' 를 넣지 못하므로 수동 재구성
rebuilt = new_parts[0]
for body in new_parts[1:]:
    rebuilt += "[[runners]]" + body
new_text = rebuilt

with open(path, "w", encoding="utf-8") as f:
    f.write(new_text)
print("[tune] config.toml 갱신 완료")
PYEOF

  # 디렉터리 보장 + 소유권
  install -d -o "${RUNNER_USER}" -g "${RUNNER_USER}" "${RUNNER_HOME}/builds" "${RUNNER_HOME}/cache"

  # 분산 S3 캐시는 주석 블록으로 안내 (ServerAddress 는 절대 global 이 아니라 리전 URL).
  if ! grep -q '\[runners.cache\]' "${RUNNER_CONFIG}"; then
    cat >> "${RUNNER_CONFIG}" <<EOF

# ──────────────────────────────────────────────────────────────────────────
# (옵션) S3 분산 캐시 — 인스턴스 교체 시에도 node_modules/cdk.out 재사용.
# ServerAddress 는 반드시 리전 S3 엔드포인트(s3.<region>.amazonaws.com).
# 절대 global s3.amazonaws.com 을 쓰지 말 것 (프라이빗 서브넷에서 미해결).
# 자격증명은 인스턴스 프로파일을 사용하므로 AccessKey/SecretKey 를 넣지 않는다.
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

  systemctl restart gitlab-runner || warn "gitlab-runner 재시작 실패 — 등록 상태를 확인하세요."
}

# ==============================================================================
# STEP 8. IMDSv2 / SSM / STS 도달성 점검
# ==============================================================================
check_imds_and_ssm() {
  log "STEP 8: IMDSv2 / SSM / STS 점검"

  # IMDSv2 토큰 방식으로 메타데이터 접근 확인
  local token iid
  token="$(curl -fsS --max-time 5 -X PUT "http://169.254.169.254/latest/api/token" \
            -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null || true)"
  if [[ -n "${token}" ]]; then
    iid="$(curl -fsS --max-time 5 -H "X-aws-ec2-metadata-token: ${token}" \
            "http://169.254.169.254/latest/meta-data/instance-id" 2>/dev/null || true)"
    log "  IMDSv2 OK (instance-id=${iid:-unknown})"
  else
    warn "IMDSv2 토큰을 가져오지 못했습니다 (hop limit/HttpTokens 설정 확인)."
  fi

  # SSM agent
  if systemctl is-active --quiet amazon-ssm-agent 2>/dev/null; then
    log "  amazon-ssm-agent active"
  else
    warn "amazon-ssm-agent 가 active 가 아닙니다 — Session Manager 접속이 안 될 수 있습니다."
  fi

  # STS 리전 엔드포인트 스모크 테스트 (in-VPC sts.<region> 도달성 확인)
  if command -v aws >/dev/null 2>&1; then
    if AWS_STS_REGIONAL_ENDPOINTS=regional aws sts get-caller-identity \
         --region "${AWS_REGION}" >/dev/null 2>&1; then
      log "  STS get-caller-identity OK (sts.${AWS_REGION} 도달)"
    else
      warn "STS 호출 실패 — sts.${AWS_REGION} interface endpoint / IAM 역할을 확인하세요."
    fi
  fi
}

# ==============================================================================
# STEP 9. 런타임 검증 — *실제 잡 셸 환경*을 그대로 재현
# ==============================================================================
verify_runtime() {
  log "STEP 9: 런타임 검증 (실제 비-로그인 잡 셸 환경 재현)"

  # 셸 executor 는 비-로그인 bash 로 잡을 돌리고, config.toml environment[] 의
  # BASH_ENV=/etc/profile.d/mise-shims.sh 만 자동 source 된다.
  # 따라서 검증도 동일하게 env -i + BASH_ENV 로 한다 (false GREEN 방지).
  local verify_cmd='command -v node && node -v && command -v python && python -V && command -v npm && npm -v'

  if ! sudo -u "${RUNNER_USER}" env -i \
        HOME="${RUNNER_HOME}" \
        BASH_ENV=/etc/profile.d/mise-shims.sh \
        bash -c "${verify_cmd}"; then
    die "런타임 검증 실패 — 잡 셸에서 node/python/npm 을 찾을 수 없습니다. (mise shims/PATH 확인)"
  fi

  # 모든 버전이 shims 로 노출되는지 확인
  log "  설치된 mise 버전 목록:"
  sudo -u "${RUNNER_USER}" env -i HOME="${RUNNER_HOME}" \
    MISE_DATA_DIR="${MISE_DATA_DIR}" MISE_CONFIG_DIR="${MISE_CONFIG_DIR}" \
    "${MISE_BIN}" ls || true

  log "런타임 검증 완료 — 잡 셸 환경에서 런타임이 정상 노출됩니다."
}

# ==============================================================================
# 필요한 VPC 엔드포인트 (참고용; 네트워크 팀이 서브넷에 attach)
# ==============================================================================
print_endpoint_reminder() {
  cat <<'EOF'

──────────────────────────────────────────────────────────────────────────────
[참고] 이 러너가 필요로 하는 VPC 엔드포인트 (모두 같은 프라이빗 서브넷/SG):
  Gateway:
    com.amazonaws.<region>.s3            (필수: CDK 에셋/부트스트랩 버킷 + CodeArtifact
                                          패키지 페이로드는 AWS 소유 S3 버킷에서 제공됨 + 러너 캐시)
  Interface (모두 Private DNS=ENABLED 여야 함):
    com.amazonaws.<region>.sts                    (리전, NOT global)
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
  (옵션) secretsmanager, ec2, dynamodb(Gateway)

  주의:
   - Private DNS 가 모든 interface endpoint 에서 ENABLED 여야 service.region.amazonaws.com
     호스트네임이 in-VPC 로 해석된다 (아니면 get-repository-endpoint 호스트네임 해석 실패).
   - S3 Gateway 는 "캐시용 옵션"이 아니라 CodeArtifact 패키지 다운로드의 필수 경로다.
   - STS 는 반드시 리전 엔드포인트. global sts.amazonaws.com 은 엔드포인트가 없어 hang 한다.
──────────────────────────────────────────────────────────────────────────────
EOF
}

# ==============================================================================
# main
# ==============================================================================
main() {
  require_root
  log "AL2023 GitLab Runner 부트스트랩 시작 (GOLDEN_AMI=${GOLDEN_AMI}, region=${AWS_REGION})"

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

  log "부트스트랩 완료."
}

main "$@"
