# GitLab Runner on Amazon Linux 2023 — private subnet, multi-runtime, cross-account CDK

Bootstrap + CI scaffolding for a **self-hosted GitLab Runner** that runs **AWS CDK
(TypeScript & Python)** and **CodeBuild triggers** into **multiple AWS accounts**, on an
**EC2 instance in a security-team-controlled private subnet with no public/Internet routing**.

All package and AWS-API traffic leaves the box **only through VPC endpoints + CodeArtifact**.

## Files

| File | Purpose |
|------|---------|
| `init-gitlab-runner-al2023.sh` | Master EC2 bootstrap. `GOLDEN_AMI` vs build-mode split. Installs Docker / AWS CLI v2 / mise + Node 18,20,22 + Python 3.10,3.11,3.12; writes `/etc/profile.d/mise.sh` (human SSM logins) **and** `/etc/profile.d/mise-shims.sh` (consumed by the non-login job shell via `config.toml` `BASH_ENV`); registers + tunes the runner; verifies runtimes in the **real** non-login job environment. |
| `diagnose-runner-env.sh` | **Read-only** health check for an already-running EC2. No installs, never `die`s — runs every check and prints a `PASS/WARN/FAIL` summary (exit 1 if any FAIL). Verifies node/python/npm + required versions in the **real non-login job shell**, `config.toml` runtime injection, systemd + docker-group, IMDSv2/role, VPC-endpoint DNS (Private DNS) + TCP 443, CodeArtifact auth, and cross-account `AssumeRole`. Run with `sudo` for runtime checks; `SKIP_NET=1 SKIP_AWS=1` for a fast runtimes-only pass; `DIAG_JSON=1` for a JSON summary on stderr. |
| `codeartifact-login.sh` | Refreshes the 12h CodeArtifact token and points npm/pip/uv (+ optional poetry/twine) at CodeArtifact. Dual-mode: strict when run directly, safe when `source`d from CI `before_script`. Exports `CA_LOGIN_OK=1` sentinel. |
| `aws-crossaccount-config.sh` | Generates the `gitlab-runner` user's `~/.aws/config` with one profile per target account using `credential_source = Ec2InstanceMetadata` + `role_arn` (no IAM users, no static keys). Optional `external_id`. |
| `iam-runner-policy.json` | Permission policy for the EC2 instance role (`RunnerRole`) — the sole identity. CodeArtifact read, `sts:GetServiceBearerToken`, cross-account `sts:AssumeRole`, SSM, Logs, same-account CodeBuild/CFN. |
| `orgdeployrole-trust.json` | Sample trust policy for the target-account `OrgDeployRole` (Model B), trusting `RunnerRole` with an `ExternalId` condition. |
| `sample.gitlab-ci.yml` | Reference pipeline: per-job runtime selection, CodeArtifact `before_script`, cross-account `cdk diff/deploy` (TS + Python), and a bounded cross-account CodeBuild trigger. |

## The one hard blocker — decide first

**GitLab server reachability.** With no public routing, the runner can only register/poll a
GitLab it can reach in-VPC. **Self-managed GitLab inside the VPC** (or via peering/Transit
Gateway/Direct Connect) works. **GitLab.com SaaS has no AWS PrivateLink** — it requires a
security-approved HTTP(S) proxy or NAT exception. Nothing else functions until this is settled.

## Executor decision

**Primary: shell executor + `mise` (multi Node/Python) + a host Docker daemon.**
In an internet-isolated subnet this pulls the fewest images, needs no per-job ECR fetch, and
gives CDK direct `docker.sock` access for asset bundling (`NodejsFunction`/`PythonFunction`,
container image assets).
**Alternative:** Docker executor with a single pre-baked ECR image (all runtimes + CDK) — only
if you need hard per-job isolation or high concurrency.

## Why a golden AMI

The bootstrap installers themselves need the internet (`mise.run`, python-build-standalone,
runtime tarballs, the `gitlab-runner` RPM). In the locked-down subnet an in-place install
**will fail**. Build the AMI in a separate **egress-enabled build account** with
`GOLDEN_AMI=false` (no token → bakes everything but does not register), snapshot it (Packer
recommended), then launch it in the private subnet and register with `GOLDEN_AMI=true`.

## Required VPC endpoints (network/security team provisions these)

**Gateway (route table):**
- `com.amazonaws.<region>.s3` — **mandatory**. Carries CDK assets/bootstrap buckets, ECR
  layers, the runner cache, **and CodeArtifact package payloads** (served from an AWS-owned S3
  bucket). Not just a cache nicety.

**Interface (Private DNS = ENABLED on every one):**
`sts` (regional — **not** global `sts.amazonaws.com`), `cloudformation`,
`codeartifact.api`, `codeartifact.repositories`, `ecr.api`, `ecr.dkr`, `logs`, `kms`,
`ssm`, `ssmmessages`, `ec2messages`, `codebuild`.
Optional: `secretsmanager`, `ec2`, `dynamodb` (Gateway).

Pin `AWS_STS_REGIONAL_ENDPOINTS=regional` everywhere (the scripts/CI already do this).

## Cross-account model

- **Model A (recommended):** `cdk bootstrap aws://<target>/<region> --trust <runner-account>`
  in every target account/region. `RunnerRole` then auto-assumes the
  `cdk-hnb659fds-*` deploy/file-publish/image-publish/**lookup** roles. CDK re-assumes
  per operation, which sidesteps the 1h STS role-chaining cap on long deploys.
- **Model B:** a dedicated `OrgDeployRole` per target (trusts `RunnerRole`, optional
  `ExternalId`), used via an `~/.aws/config` profile (`aws-crossaccount-config.sh`).

> Cross-account **CodeBuild** cannot be started directly by `RunnerRole`. Assume the target
> role first, then `StartBuild` — so `codebuild:StartBuild` lives on the **target** `OrgDeployRole`,
> not on `RunnerRole` (which only keeps same-account CodeBuild).

## Deploy order

1. Network team: create the VPC endpoints above; SG inbound 443 from the subnet CIDR; resolve GitLab egress.
2. Runner account: CodeArtifact domain + `npm-store` (upstream `public:npmjs`) + `pypi-store` (upstream `public:pypi`).
3. IAM: create `RunnerRole` (EC2 trust) + attach `iam-runner-policy.json` (substitute account IDs/region; drop the Model A or Model B `AssumeRole` block you don't use); create the instance profile.
4. Targets: `cdk bootstrap … --trust <runner-account>` (Model A) and/or create `OrgDeployRole` with `orgdeployrole-trust.json` (Model B).
5. Build the golden AMI in an egress-enabled account: `sudo GOLDEN_AMI=false GITLAB_RUNNER_TOKEN= bash init-gitlab-runner-al2023.sh`, verify, snapshot. **Never bake a runner token into the image.**
6. Launch from the AMI in the private subnet: attach `RunnerRole`; metadata `HttpTokens=required`, `HopLimit=1` (IMDSv2); no public IP, no IGW/NAT route.
7. Register (over SSM Session Manager): `sudo GOLDEN_AMI=true GITLAB_URL=… GITLAB_RUNNER_TOKEN=glrt-… bash init-gitlab-runner-al2023.sh`.
8. (Model B only) `sudo EXTERNAL_ID=<shared-id> bash aws-crossaccount-config.sh`.
9. `sudo install -m 0755 codeartifact-login.sh /usr/local/bin/codeartifact-login.sh`.
10. Drop `sample.gitlab-ci.yml` into a consuming repo as `.gitlab-ci.yml`; pin `aws-cdk`/`aws-cdk-lib` in `package.json` (run via `npx`).

## Substitute consistently across all files

`AWS_REGION=ap-northeast-2` · runner/CA-owner account `999999999999` · `CA_DOMAIN=my-domain` ·
`CA_NPM_REPO=npm-store` · `CA_PYPI_REPO=pypi-store` · targets `111111111111/222222222222/333333333333` ·
CDK qualifier `hnb659fds` · runner tags `shell,cdk` · mise dirs `/usr/local/share/mise` + `/etc/mise`.

## Known limits

- Chained STS sessions are hard-capped at **1h** regardless of `MaxSessionDuration` → prefer Model A per-operation re-assume for long deploys; the CodeBuild poll is bounded under 1h.
- CodeArtifact tokens expire at **12h** → re-`source` `codeartifact-login.sh` mid-job for very long jobs.
- Never enable `CI_DEBUG_TRACE`/`set -x` in `before_script` — `pip.conf` holds the token (`PIP_INDEX_URL` is intentionally not exported).

## Validation

The shell scripts pass `bash -n`; the JSON parses; `sample.gitlab-ci.yml` was validated with a
real YAML parser (Ruby Psych) plus an AST duplicate-key/trap scan — clean. This box has **no
internet egress**, so the authoritative **GitLab-semantic** lint must be run by you:

```bash
# Pipeline Editor → Validate tab, or the CI Lint API:
JSON=$(jq -Rs . < gitlab-runner/sample.gitlab-ci.yml)
curl -s --header "PRIVATE-TOKEN: <token>" \
  --header "Content-Type: application/json" \
  --data "{\"content\": $JSON}" \
  "https://<your-gitlab-host>/api/v4/ci/lint" | jq .

# or, if you have npm egress:
npx --yes gitlab-ci-local --file gitlab-runner/sample.gitlab-ci.yml --list
```
