#!/usr/bin/env bash
# =============================================================================
# aws-crossaccount-config.sh
# -----------------------------------------------------------------------------
# Creates cross-account profiles in the gitlab-runner user's ~/.aws/config.
# Each profile assumes a target-account role via the instance profile (EC2 metadata).
#
# Key points:
#   - Uses credential_source = Ec2InstanceMetadata + role_arn.
#   - Does NOT use source_profile (because there is no IAM User).
#   - Forces sts_regional_endpoints = regional (use in-VPC sts.<region>; global forbidden).
#   - role_session_name includes the alias to improve CloudTrail correlation.
#   - (optional) emits external_id to defend against confused-deputy (same value as orgdeployrole-trust.json).
#   - Idempotent: rewrites only the managed-marker block, never duplicate-appends.
#
# CDK trust models:
#   - Model A (recommended): when bootstrapped with cdk bootstrap --trust <runner-account>,
#     CDK "auto-assumes" the cdk-hnb659fds-* roles via the instance metadata.
#     => in that case no profile is needed. The block below is for Model B / explicit --profile.
#   - Model B: a dedicated OrgDeployRole per target account, assumed explicitly via --profile.
#
# Running:
#   - When run as root, it writes to the gitlab-runner home and fixes ownership.
#   - It also works when run directly as the gitlab-runner user.
# =============================================================================

set -euo pipefail

# =============================================================================
# 0. Config block (same naming convention as the other files)
# =============================================================================
AWS_REGION="${AWS_REGION:-ap-northeast-2}"
RUNNER_USER="${RUNNER_USER:-gitlab-runner}"

# Target-account role name for Model B (assumed identical across accounts).
ORG_DEPLOY_ROLE_NAME="${ORG_DEPLOY_ROLE_NAME:-OrgDeployRole}"

# CDK bootstrap qualifier (default hnb659fds). Keep in sync with iam-runner-policy.json.
CDK_QUALIFIER="${CDK_QUALIFIER:-hnb659fds}"

# (optional) ExternalId — confused-deputy defense. When set, emits external_id on each profile,
# and it must be the *same value* as the sts:ExternalId condition in orgdeployrole-trust.json.
# When empty, the external_id line is omitted.
EXTERNAL_ID="${EXTERNAL_ID:-}"

# -----------------------------------------------------------------------------
# Target-account map: alias -> "accountId:region:roleName"
#   - alias    : the [profile <alias>] name in ~/.aws/config and a human-readable alias.
#   - accountId: target AWS account ID.
#   - region   : default region for that profile.
#   - roleName : role to assume (Model B -> ${ORG_DEPLOY_ROLE_NAME}).
#
# [EDIT REQUIRED] fill in your real accounts/regions/roles.
# (If you only use Model A, this map can be empty — cdk auto-assumes without a profile.)
# -----------------------------------------------------------------------------
declare -A TARGETS=(
  ["dev"]="111111111111:ap-northeast-2:${ORG_DEPLOY_ROLE_NAME}"
  ["staging"]="222222222222:ap-northeast-2:${ORG_DEPLOY_ROLE_NAME}"
  ["prod"]="333333333333:ap-northeast-2:${ORG_DEPLOY_ROLE_NAME}"
  # same-account multi-region example:
  # ["dev-usw2"]="111111111111:us-west-2:${ORG_DEPLOY_ROLE_NAME}"
)

# Managed-block markers (for idempotent rewrite). We manage only the content between these markers.
MARK_BEGIN="# >>> aws-crossaccount-config.sh managed (BEGIN) >>>"
MARK_END="# <<< aws-crossaccount-config.sh managed (END) <<<"

# =============================================================================
# Utilities
# =============================================================================
log()  { printf '\033[1;34m[XACC]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[XACC-WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[XACC-ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

# Look up the gitlab-runner home path
resolve_runner_home() {
  getent passwd "${RUNNER_USER}" >/dev/null 2>&1 \
    || die "user ${RUNNER_USER} does not exist. Run init-gitlab-runner-al2023.sh first."
  getent passwd "${RUNNER_USER}" | cut -d: -f6
}

# =============================================================================
# 1. Build the managed block
# =============================================================================
build_managed_block() {
  printf '%s\n' "${MARK_BEGIN}"
  printf '%s\n' "# This block is managed by the script. Do not edit by hand (overwritten on re-run)."
  printf '%s\n' "# Model A (recommended) auto-assumes via cdk without a profile, so the below is for Model B / explicit assume."
  printf '\n'

  local alias accountId region roleName role_arn
  for alias in "${!TARGETS[@]}"; do
    IFS=':' read -r accountId region roleName <<< "${TARGETS[$alias]}"
    role_arn="arn:aws:iam::${accountId}:role/${roleName}"
    printf '[profile %s]\n' "${alias}"
    printf 'role_arn = %s\n' "${role_arn}"
    printf 'credential_source = Ec2InstanceMetadata\n'
    # Include the alias in the session name -> CloudTrail correlation. If you need
    # more per-job uniqueness, override on the CLI with --role-session-name "gitlab-${alias}-${CI_JOB_ID}".
    printf 'role_session_name = gitlab-%s\n' "${alias}"
    printf 'region = %s\n' "${region}"
    # STS always uses the in-VPC regional endpoint.
    printf 'sts_regional_endpoints = regional\n'
    if [[ -n "${EXTERNAL_ID}" ]]; then
      printf 'external_id = %s\n' "${EXTERNAL_ID}"
    fi
    printf '\n'
  done

  printf '%s\n' "${MARK_END}"
}

# =============================================================================
# 2. Apply idempotently to ~/.aws/config
# -----------------------------------------------------------------------------
# If a managed block (MARK_BEGIN..MARK_END) exists, remove it then re-insert.
# Content outside the markers is preserved.
# =============================================================================
apply_config() {
  local home aws_dir cfg tmp
  home="$(resolve_runner_home)"
  aws_dir="${home}/.aws"
  cfg="${aws_dir}/config"

  install -d -m 700 "${aws_dir}"
  touch "${cfg}"

  tmp="$(mktemp)"
  # Remove the existing managed block (awk: skip lines between markers, also drop the markers themselves).
  awk -v b="${MARK_BEGIN}" -v e="${MARK_END}" '
    $0 == b { skip=1; next }
    $0 == e { skip=0; next }
    skip != 1 { print }
  ' "${cfg}" > "${tmp}"

  # Ensure a trailing newline, then append the new managed block.
  if [[ -s "${tmp}" ]] && [[ -n "$(tail -c1 "${tmp}")" ]]; then
    printf '\n' >> "${tmp}"
  fi
  build_managed_block >> "${tmp}"

  mv "${tmp}" "${cfg}"
  chmod 600 "${cfg}"

  # If run as root, fix ownership back to gitlab-runner.
  if [[ "$(id -u)" -eq 0 ]]; then
    chown -R "${RUNNER_USER}:${RUNNER_USER}" "${aws_dir}"
  fi

  log "profiles written -> ${cfg}"
  log "created profiles: ${!TARGETS[*]}"
  if [[ -n "${EXTERNAL_ID}" ]]; then
    log "external_id applied — must match the sts:ExternalId in orgdeployrole-trust.json."
  else
    warn "EXTERNAL_ID unset — set EXTERNAL_ID if you need confused-deputy defense."
  fi
}

# =============================================================================
# main
# =============================================================================
main() {
  log "starting cross-account ~/.aws/config setup (user=${RUNNER_USER})"
  apply_config
  cat <<EOF

Usage examples:
  # Model B / explicit assume:
  AWS_PROFILE=dev npx cdk deploy --require-approval never
  AWS_PROFILE=prod aws sts get-caller-identity

  # Model A (recommended): no profile — just set the target via env vars and CDK auto-assumes.
  export CDK_DEFAULT_ACCOUNT=111111111111
  export CDK_DEFAULT_REGION=${AWS_REGION}
  npx cdk deploy --require-approval never

Notes:
  - Model A prerequisite: bootstrap the target account with
    'cdk bootstrap aws://<acct>/<region> --trust <runner-account>' so the
    cdk-${CDK_QUALIFIER}-* roles trust the runner account.
  - The instance profile (RunnerRole) needs sts:AssumeRole on the target roles
    (see the region-wildcard ARNs in iam-runner-policy.json).
  - [IMPORTANT] cross-account CodeBuild StartBuild cannot be done directly by RunnerRole.
    You must assume the target role (OrgDeployRole) first and then StartBuild, and the
    codebuild:StartBuild permission must live on the *target account's OrgDeployRole*.
EOF
}

main "$@"
