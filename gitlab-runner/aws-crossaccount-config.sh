#!/usr/bin/env bash
# =============================================================================
# aws-crossaccount-config.sh
# -----------------------------------------------------------------------------
# gitlab-runner 사용자의 ~/.aws/config 에 cross-account 프로파일을 생성한다.
# 각 프로파일은 인스턴스 프로파일(EC2 메타데이터)을 통해 대상 계정 역할을 가정한다.
#
# 핵심:
#   - credential_source = Ec2InstanceMetadata + role_arn 사용.
#   - source_profile 은 사용하지 않는다(IAM User 가 없으므로).
#   - sts_regional_endpoints = regional 강제(in-VPC sts.<region> 사용; global 금지).
#   - role_session_name 은 alias 를 포함해 CloudTrail 상관관계를 높인다.
#   - (옵션) external_id 를 emit 해 confused-deputy 를 방어(orgdeployrole-trust.json 과 동일 값).
#   - 멱등: 관리 마커 블록만 재작성하고 중복 append 하지 않는다.
#
# CDK 신뢰 모델:
#   - Model A(권장): cdk bootstrap --trust <runner-account> 로 부트스트랩하면
#     CDK 가 cdk-hnb659fds-* 역할을 인스턴스 메타데이터로 "자동" 가정한다.
#     => 이 경우 프로파일이 필요 없다. 아래 블록은 Model B / 명시 --profile 용.
#   - Model B: 대상 계정마다 전용 OrgDeployRole 을 두고 --profile 로 명시 가정.
#
# 실행:
#   - root 로 실행하면 gitlab-runner 홈에 쓰고 소유권을 보정한다.
#   - gitlab-runner 사용자로 직접 실행해도 동작한다.
# =============================================================================

set -euo pipefail

# =============================================================================
# 0. 설정 블록 (다른 파일과 동일 명명 규칙)
# =============================================================================
AWS_REGION="${AWS_REGION:-ap-northeast-2}"
RUNNER_USER="${RUNNER_USER:-gitlab-runner}"

# Model B 에서 사용할 대상 계정 역할명(계정마다 동일하다고 가정).
ORG_DEPLOY_ROLE_NAME="${ORG_DEPLOY_ROLE_NAME:-OrgDeployRole}"

# CDK 부트스트랩 qualifier (기본 hnb659fds). iam-runner-policy.json 과 일치시킬 것.
CDK_QUALIFIER="${CDK_QUALIFIER:-hnb659fds}"

# (옵션) ExternalId — confused-deputy 방어. 설정 시 각 프로파일에 external_id 를 emit 하며,
# orgdeployrole-trust.json 의 sts:ExternalId 조건과 *동일한 값*이어야 한다.
# 빈 값이면 external_id 라인을 생략한다.
EXTERNAL_ID="${EXTERNAL_ID:-}"

# -----------------------------------------------------------------------------
# 대상 계정 매핑: alias -> "accountId:region:roleName"
#   - alias    : ~/.aws/config 의 [profile <alias>] 이름이자 사람이 읽는 별칭.
#   - accountId: 대상 AWS 계정 ID.
#   - region   : 해당 프로파일 기본 리전.
#   - roleName : 가정할 역할명(Model B -> ${ORG_DEPLOY_ROLE_NAME}).
#
# [수정 필요] 실제 계정/리전/역할에 맞게 채운다.
# (Model A 만 쓰면 이 맵을 비워도 된다 — cdk 가 프로파일 없이 자동 가정.)
# -----------------------------------------------------------------------------
declare -A TARGETS=(
  ["dev"]="111111111111:ap-northeast-2:${ORG_DEPLOY_ROLE_NAME}"
  ["staging"]="222222222222:ap-northeast-2:${ORG_DEPLOY_ROLE_NAME}"
  ["prod"]="333333333333:ap-northeast-2:${ORG_DEPLOY_ROLE_NAME}"
  # 동일 계정 다중 리전 예시:
  # ["dev-usw2"]="111111111111:us-west-2:${ORG_DEPLOY_ROLE_NAME}"
)

# 관리 블록 마커(멱등 재작성용). 이 마커 사이만 우리가 관리한다.
MARK_BEGIN="# >>> aws-crossaccount-config.sh managed (BEGIN) >>>"
MARK_END="# <<< aws-crossaccount-config.sh managed (END) <<<"

# =============================================================================
# 유틸
# =============================================================================
log()  { printf '\033[1;34m[XACC]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[XACC-WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[XACC-ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

# gitlab-runner 홈 경로 조회
resolve_runner_home() {
  getent passwd "${RUNNER_USER}" >/dev/null 2>&1 \
    || die "사용자 ${RUNNER_USER} 가 없습니다. init-gitlab-runner-al2023.sh 를 먼저 실행하세요."
  getent passwd "${RUNNER_USER}" | cut -d: -f6
}

# =============================================================================
# 1. 관리 블록 생성
# =============================================================================
build_managed_block() {
  printf '%s\n' "${MARK_BEGIN}"
  printf '%s\n' "# 이 블록은 스크립트가 관리합니다. 직접 수정 금지(재실행 시 덮어씀)."
  printf '%s\n' "# Model A(권장)는 프로파일 없이 cdk 가 자동 가정하므로, 아래는 Model B/명시 가정용."
  printf '\n'

  local alias accountId region roleName role_arn
  for alias in "${!TARGETS[@]}"; do
    IFS=':' read -r accountId region roleName <<< "${TARGETS[$alias]}"
    role_arn="arn:aws:iam::${accountId}:role/${roleName}"
    printf '[profile %s]\n' "${alias}"
    printf 'role_arn = %s\n' "${role_arn}"
    printf 'credential_source = Ec2InstanceMetadata\n'
    # 세션 이름에 alias 포함 -> CloudTrail 상관관계. 잡 단위 유일성이 더 필요하면
    # CLI 에서 --role-session-name "gitlab-${alias}-${CI_JOB_ID}" 로 오버라이드.
    printf 'role_session_name = gitlab-%s\n' "${alias}"
    printf 'region = %s\n' "${region}"
    # STS 는 항상 in-VPC 리전 엔드포인트.
    printf 'sts_regional_endpoints = regional\n'
    if [[ -n "${EXTERNAL_ID}" ]]; then
      printf 'external_id = %s\n' "${EXTERNAL_ID}"
    fi
    printf '\n'
  done

  printf '%s\n' "${MARK_END}"
}

# =============================================================================
# 2. ~/.aws/config 에 멱등 반영
# -----------------------------------------------------------------------------
# 기존 관리 블록(MARK_BEGIN..MARK_END)이 있으면 제거 후 재삽입.
# 마커 밖의 사용자 내용은 보존한다.
# =============================================================================
apply_config() {
  local home aws_dir cfg tmp
  home="$(resolve_runner_home)"
  aws_dir="${home}/.aws"
  cfg="${aws_dir}/config"

  install -d -m 700 "${aws_dir}"
  touch "${cfg}"

  tmp="$(mktemp)"
  # 기존 관리 블록 제거(awk: 마커 사이 라인 스킵, 마커 자체도 제거).
  awk -v b="${MARK_BEGIN}" -v e="${MARK_END}" '
    $0 == b { skip=1; next }
    $0 == e { skip=0; next }
    skip != 1 { print }
  ' "${cfg}" > "${tmp}"

  # 끝에 개행 보장 후 새 관리 블록 추가.
  if [[ -s "${tmp}" ]] && [[ -n "$(tail -c1 "${tmp}")" ]]; then
    printf '\n' >> "${tmp}"
  fi
  build_managed_block >> "${tmp}"

  mv "${tmp}" "${cfg}"
  chmod 600 "${cfg}"

  # root 로 실행했다면 소유권을 gitlab-runner 로 보정.
  if [[ "$(id -u)" -eq 0 ]]; then
    chown -R "${RUNNER_USER}:${RUNNER_USER}" "${aws_dir}"
  fi

  log "프로파일 작성 완료 -> ${cfg}"
  log "생성된 프로파일: ${!TARGETS[*]}"
  if [[ -n "${EXTERNAL_ID}" ]]; then
    log "external_id 적용됨 — orgdeployrole-trust.json 의 sts:ExternalId 와 동일해야 함."
  else
    warn "EXTERNAL_ID 미설정 — confused-deputy 방어가 필요하면 EXTERNAL_ID 를 지정하세요."
  fi
}

# =============================================================================
# 메인
# =============================================================================
main() {
  log "cross-account ~/.aws/config 구성 시작 (user=${RUNNER_USER})"
  apply_config
  cat <<EOF

사용 예:
  # Model B / 명시 가정:
  AWS_PROFILE=dev npx cdk deploy --require-approval never
  AWS_PROFILE=prod aws sts get-caller-identity

  # Model A(권장): 프로파일 없이 환경변수로 대상만 지정하면 CDK 가 자동 가정.
  export CDK_DEFAULT_ACCOUNT=111111111111
  export CDK_DEFAULT_REGION=${AWS_REGION}
  npx cdk deploy --require-approval never

참고:
  - Model A 전제: 대상 계정을 'cdk bootstrap aws://<acct>/<region> --trust <러너계정>' 으로
    부트스트랩하여 cdk-${CDK_QUALIFIER}-* 역할이 러너 계정을 신뢰해야 한다.
  - 인스턴스 프로파일(RunnerRole)에는 대상 역할에 대한 sts:AssumeRole 권한이 필요하다
    (iam-runner-policy.json 의 region 와일드카드 ARN 참고).
  - [중요] cross-account CodeBuild StartBuild 는 RunnerRole 로 직접 불가하다.
    타겟 역할(OrgDeployRole)을 먼저 가정한 뒤 StartBuild 해야 하며, codebuild:StartBuild
    권한은 *타겟 계정의 OrgDeployRole* 에 있어야 한다.
EOF
}

main "$@"
