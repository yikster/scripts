# GitLab Runner on Amazon Linux 2023 — Design & Implementation Plan

**Private subnet · multi-runtime (Node + Python) · cross-account AWS CDK / CodeBuild**

| | |
|---|---|
| **Status** | Draft for review |
| **Owner** | Platform / DevOps |
| **Date** | 2026-05-31 |
| **Scope** | One self-hosted GitLab Runner host that executes CDK (TS + Python) and CodeBuild triggers into multiple AWS accounts, from an EC2 instance in a locked-down private subnet |

---

## Table of contents

1. [Problem statement & constraints](#1-problem-statement--constraints)
2. [Goals and non-goals](#2-goals-and-non-goals)
3. [Architecture overview](#3-architecture-overview)
4. [Key decision — executor model](#4-key-decision--executor-model)
5. [Network design (VPC endpoints)](#5-network-design-vpc-endpoints)
6. [IAM design](#6-iam-design)
7. [Runtime management (multiple Node + Python)](#7-runtime-management-multiple-node--python)
8. [Packaging — CodeArtifact as npm/PyPI proxy](#8-packaging--codeartifact-as-npmpypi-proxy)
9. [GitLab Runner configuration](#9-gitlab-runner-configuration)
10. [Cross-account CDK & CodeBuild](#10-cross-account-cdk--codebuild)
11. [Golden AMI strategy](#11-golden-ami-strategy)
12. [Required-features checklist](#12-required-features-checklist)
13. [Open decisions](#13-open-decisions)
14. [Implementation plan (phased)](#14-implementation-plan-phased)
15. [File inventory](#15-file-inventory)
16. [Validation & testing](#16-validation--testing)
17. [Risks & known limits](#17-risks--known-limits)
18. [Appendix — variable reference](#18-appendix--variable-reference)

---

## 1. Problem statement & constraints

We need a GitLab CI runner that builds and deploys infrastructure (AWS CDK in **both**
TypeScript and Python) and triggers **CodeBuild** projects in **multiple other AWS accounts**.
The runner host is an **EC2 instance on Amazon Linux 2023** that lives in a **private subnet
owned by the security team**.

**Hard constraints (given):**

| # | Constraint | Consequence |
|---|------------|-------------|
| 1 | Runner runs on EC2 in a **private subnet** | No public IP, no inbound from internet |
| 2 | Subnet is **security-team controlled; no public routing** may be opened | No IGW route; assume **no NAT egress** to the internet either — effectively air-gapped except via PrivateLink + AWS-managed services |
| 3 | **CodeArtifact** may be attached | Use it as the npm + pip/PyPI proxy (upstream fetch happens AWS-side) |
| 4 | **An IAM Role** may be attached to the instance | Instance profile is the identity |
| 5 | **No new IAM Users** may be created | All auth chains from the instance role; no static keys anywhere |
| 6 | The role **may be updated / have policies attached** | We can grant the runner what it needs |
| 7 | Must execute **CDK (TS + Python)** on this EC2 for GitLab CI | Multiple Node + multiple Python versions required on-host |

**Derived requirement:** every outbound call — AWS API, package download, runner→GitLab —
must traverse a **VPC endpoint** or an **AWS-managed service**, or it fails.

---

## 2. Goals and non-goals

**Goals**

- Run GitLab CI jobs that need **multiple Node.js** (18/20/22) and **multiple Python** (3.10/3.11/3.12) versions.
- Execute **`cdk deploy`** (TypeScript and Python) and **trigger CodeBuild** into **multiple target accounts**.
- Operate with **no internet egress** — packages via CodeArtifact, AWS APIs via VPC endpoints.
- Use **only the instance role** for identity (no IAM users, no static credentials).
- Be **idempotent** and **reproducible** (golden AMI), and accessible without SSH (SSM Session Manager).

**Non-goals**

- Building the VPC endpoints themselves (network/security team owns that IaC — we specify the list).
- Hosting GitLab itself (we only consume it; see the reachability decision in §13).
- Autoscaling fleets of runners (single-runner host design; can be templated later).

---

## 3. Architecture overview

```
                        ┌──────────────────────── Build account (HAS egress) ───────────────────────┐
                        │  Packer/EC2 + internet → install mise, Node 18/20/22, Python 3.10/3.11/3.12 │
                        │  + AWS CLI v2 + Docker + gitlab-runner  ──►  GOLDEN AMI (no token baked in)  │
                        └───────────────────────────────────────────┬───────────────────────────────┘
                                                                     │ AMI copy/share
                                                                     ▼
┌──────────────────────────── Runner account 9999… (private subnet, NO internet) ──────────────────────────┐
│                                                                                                            │
│   EC2 (AL2023) ── instance profile: RunnerRole ── IMDSv2 only ── SSM Session Manager (no SSH)              │
│     │                                                                                                       │
│     │  mise → node@{18,20,22} / python@{3.10,3.11,3.12}     Docker daemon (CDK asset bundling)             │
│     │  gitlab-runner (shell executor)  ── config.toml environment[] injects PATH/shims into job shell      │
│     │                                                                                                       │
│     │  job before_script: codeartifact-login.sh  → npm/.npmrc + pip.conf + uv  (12h token refresh)         │
│     │                                                                                                       │
│     └── all traffic leaves ONLY via VPC endpoints ───────────────────────────────────────────────┐        │
│                                                                                                    ▼        │
│   VPC endpoints:  S3(GW) · sts(regional) · cloudformation · codeartifact.api/.repositories ·              │
│                   ecr.api/.dkr · logs · kms · ssm/ssmmessages/ec2messages · codebuild                      │
│                                                                                                            │
│   CodeArtifact domain  ──upstream──►  public:npmjs / public:pypi   (fetch happens AWS-side)                │
└───────────────────────────────────────────────┬──────────────────────────────────────────────────────────┘
                                                 │  sts:AssumeRole (regional endpoint)  +  cdk deploy / StartBuild
                                                 ▼
        ┌──────────── Target acct 111… ────────────┐ ┌──── 222… ────┐ ┌──── 333… ────┐
        │  cdk-hnb659fds-* roles  (Model A --trust) │ │  OrgDeployRole│ │  OrgDeployRole│
        │  CloudFormation · S3 assets · ECR · CodeBuild (assume → StartBuild)             │
        └───────────────────────────────────────────┘ └──────────────┘ └──────────────┘
                              ▲ GitLab server reachability (DECIDE FIRST):
                              └ self-managed in-VPC GitLab  OR  approved proxy (GitLab.com has no PrivateLink)
```

**End-to-end flow:** instance boots from the golden AMI → `mise` exposes all runtimes to the
non-login job shell via `config.toml` `environment[]` → runner registers to GitLab with a
`glrt-*` token → each job refreshes the CodeArtifact token and points npm/pip/uv at it →
the job assumes the target-account role over the regional STS endpoint → `cdk bootstrap/deploy`
(CloudFormation + S3 asset publish through their endpoints) or triggers cross-account CodeBuild.

---

## 4. Key decision — executor model

**Primary: shell executor + `mise` + a host Docker daemon.**

> **Why.** In an internet-isolated subnet this pulls the **fewest images**, needs **no per-job
> ECR fetch**, and gives CDK direct `docker.sock` access for asset bundling
> (`NodejsFunction`/`PythonFunction` esbuild, container image assets). `mise` supplies all
> Node/Python versions natively.

**Alternative: Docker executor + a single pre-baked ECR image** (all runtimes + CDK) — reserved
for teams needing strong per-job build isolation or high concurrency. Costs an ECR image
lifecycle and `ecr.*` pulls per job.

| Criterion | Shell + mise + host Docker (chosen) | Docker executor + ECR image |
|---|---|---|
| Image pulls in air-gap | None (runtimes on host) | One per job (from ECR via endpoint) |
| CDK docker bundling | Direct `docker.sock` | Docker-in-Docker or socket bind |
| Multi Node/Python | `mise use` per job | Baked into the image |
| Per-job isolation | Weaker (shared host) | Strong |
| Operational overhead | Low | ECR image build/scan/lifecycle |

---

## 5. Network design (VPC endpoints)

The network/security team provisions these on the private subnet. **Private DNS must be ENABLED**
on every interface endpoint, otherwise `service.<region>.amazonaws.com` and the CodeArtifact
`get-repository-endpoint` hostnames will not resolve in-VPC.

**Gateway endpoint (route-table association):**

| Service | Type | Why mandatory |
|---|---|---|
| `com.amazonaws.<region>.s3` | Gateway | CDK assets/bootstrap buckets, ECR layers, runner cache, **and CodeArtifact package payloads** (served from an AWS-owned S3 bucket). Not just a cache nicety. |

**Interface endpoints (Private DNS = ENABLED):**

| Service | Purpose |
|---|---|
| `com.amazonaws.<region>.sts` | **Regional** STS — cross-account `AssumeRole`. **Not** global `sts.amazonaws.com` (no endpoint → hangs). Pin `AWS_STS_REGIONAL_ENDPOINTS=regional`. |
| `com.amazonaws.<region>.cloudformation` | CDK deploy |
| `com.amazonaws.<region>.codeartifact.api` | Token / endpoint discovery |
| `com.amazonaws.<region>.codeartifact.repositories` | Package download |
| `com.amazonaws.<region>.ecr.api` + `.ecr.dkr` | CDK image assets, docker pull/push |
| `com.amazonaws.<region>.logs` | CloudWatch Logs |
| `com.amazonaws.<region>.kms` | Bootstrap-bucket / asset encryption |
| `com.amazonaws.<region>.ssm` + `.ssmmessages` + `.ec2messages` | Session Manager (the only shell access; no SSH/bastion) |
| `com.amazonaws.<region>.codebuild` | Trigger CodeBuild |

**Optional interface endpoints:** `secretsmanager` (if jobs read SM secrets), `ec2` (if jobs call
EC2 APIs directly), `dynamodb` (Gateway, if used).

**Security groups:** endpoint SG allows inbound **TCP 443 from the subnet CIDR**; the runner SG
allows egress 443 to the endpoint SG.

> **IMDS note:** IMDSv2 (`169.254.169.254`) is link-local and needs no endpoint, so the instance
> profile resolves locally — but every `sts:AssumeRole` call still needs the **STS interface
> endpoint**.

---

## 6. IAM design

The **instance profile (`RunnerRole`) is the sole identity** — no IAM users, no static keys.

**RunnerRole permission policy** (`iam-runner-policy.json`) grants:

- **CodeArtifact read** — `GetAuthorizationToken` (domain ARN); `GetRepositoryEndpoint` +
  `ReadFromRepository` (repo ARNs); `GetPackageVersionAsset` / `DescribePackageVersion` /
  `ListPackageVersions` / `ListPackages` / `GetPackageVersionReadme` (package ARNs).
- **`sts:GetServiceBearerToken`** — `Resource: "*"` (cannot be scoped) with condition
  `sts:AWSServiceName = codeartifact.amazonaws.com`. **Easy to forget; CodeArtifact auth fails without it.**
- **Cross-account `sts:AssumeRole`** — Model A: `cdk-hnb659fds-*-role-<acct>-*` (region wildcard,
  per target) and/or Model B: `OrgDeployRole` ARNs.
- **Same-account CodeBuild** `StartBuild`/`BatchGetBuilds`/`BatchGetReports` only (cross-account
  StartBuild is granted on the assumed target role — see §10).
- **Session Manager** (`ssm`/`ssmmessages`/`ec2messages`), **CloudWatch Logs**, same-account
  CloudFormation + EC2 describe (for CDK), optional SSM Parameter read and S3 cache.

**Target-account trust** (`orgdeployrole-trust.json`, Model B) trusts `RunnerRole` with an
`sts:ExternalId` condition (confused-deputy protection); remove the condition if not used.

---

## 7. Runtime management (multiple Node + Python)

**Tool: `mise`** (single binary, manages both Node and Python, fast, supports per-repo
`.mise.toml` / `.tool-versions`).

- Installed once at `/usr/local/bin/mise`; shared data/config at `/usr/local/share/mise` and `/etc/mise`.
- Versions pre-installed: **Node 18, 20, 22** and **Python 3.10, 3.11, 3.12**.
- Python comes from **python-build-standalone** (no on-host compiler needed in the air gap).

**The critical detail — the shell executor runs a *non-login* bash**, which does **not** source
`/etc/profile` or `/etc/profile.d/*.sh`. So runtimes are injected into the job shell via
`config.toml` `environment[]`:

```
BASH_ENV=/etc/profile.d/mise-shims.sh
MISE_DATA_DIR=/usr/local/share/mise
MISE_CONFIG_DIR=/etc/mise
PATH=<shims first>:...
AWS_STS_REGIONAL_ENDPOINTS=regional
```

`/etc/profile.d/mise.sh` is the human-login (SSM) convenience path; `mise-shims.sh` is the
machine path the runner actually uses. The bootstrap **verifies runtimes in the real non-login
environment** (`env -i … BASH_ENV=… bash -c 'node -v && python -V'`) so a green check can't lie.

> **CDK CLI:** install per-project via `npx` (pin `aws-cdk`/`aws-cdk-lib` in `package.json`) —
> never a global `npm i -g aws-cdk` under multi-Node.

---

## 8. Packaging — CodeArtifact as npm/PyPI proxy

The instance can't reach npmjs.org or pypi.org. CodeArtifact proxies both; its **public
upstream** fetch happens on the AWS service side, so it works with no instance egress.

- One CodeArtifact **domain** with `npm-store` (upstream `public:npmjs`) and `pypi-store`
  (upstream `public:pypi`).
- `codeartifact-login.sh` refreshes the **12-hour** token and configures **npm** (`.npmrc`),
  **pip** (`pip.conf`, index path ends `/simple/`), **uv** (named index +
  `UV_INDEX_<NAME>_USERNAME/PASSWORD`), and optionally poetry/twine.
- Token refresh strategy: run in the CI **`before_script`** every job (robust); a systemd timer
  is provided as a commented backup.

> **Secret hygiene:** the pip token lives only in `pip.conf` (chmod 600); `PIP_INDEX_URL` is
> deliberately **not** exported. Never enable `CI_DEBUG_TRACE` / `set -x` in `before_script`.

---

## 9. GitLab Runner configuration

- **Install:** the `gitlab-runner` binary/RPM needs internet → bake it into the golden AMI.
- **Register:** modern **`glrt-*` authentication token** (the legacy `registration-token` flow
  was removed in GitLab 18.0). Registration is idempotent on `RUNNER_NAME` + `GITLAB_URL` and
  prunes dead runners via `gitlab-runner verify --delete`.
- **`config.toml`:** `concurrent`, a single `[[runners]]` block with `executor = "shell"`,
  `shell = "bash"`, `builds_dir`/`cache_dir` under `/home/gitlab-runner`, and the
  `environment[]` runtime injection from §7. Optional S3 distributed cache with
  `ServerAddress = s3.<region>.amazonaws.com` (never the global host).
- **Service:** systemd, running as the `gitlab-runner` user, which is in the `docker` group.

---

## 10. Cross-account CDK & CodeBuild

**Two trust models (both shipped; pick one to tighten IAM):**

- **Model A — recommended.** `cdk bootstrap aws://<target>/<region> --trust <runner-account>
  --cloudformation-execution-policies <policy>` in every target account/region. CDK then
  **auto-assumes** the target's `cdk-hnb659fds-*` deploy / file-publishing / image-publishing /
  **lookup** roles. `RunnerRole` only needs `sts:AssumeRole` on `cdk-hnb659fds-*`. CDK re-assumes
  per operation, which avoids the 1-hour STS role-chaining cap on long deploys. No `~/.aws/config`
  profiles required.

- **Model B.** A dedicated **`OrgDeployRole`** per target account (trusts `RunnerRole`, optional
  `ExternalId`), used through an `~/.aws/config` profile generated by `aws-crossaccount-config.sh`
  with `credential_source = Ec2InstanceMetadata` + `role_arn` (no `source_profile`, no keys).

**Cross-account CodeBuild:** cannot be started directly by `RunnerRole`. The job **assumes the
target role first**, then `StartBuild` — so `codebuild:StartBuild` lives on the **target**
`OrgDeployRole`, not on `RunnerRole`. The sample pipeline does this in a subshell with a unique
`role-session-name` and a **bounded poll loop** (≤ ~60 min, under the STS chaining cap).

> CDK **context lookups** at synth time also assume the target `lookup-role` — covered by the
> Model A wildcard ARNs.

---

## 11. Golden AMI strategy

The bootstrap installers themselves need the internet (`mise.run`, python-build-standalone,
runtime tarballs, the `gitlab-runner` RPM). **In-place install in the locked-down subnet will
fail.**

- Build the AMI in a **separate egress-enabled build account**: launch AL2023 with internet, run
  `sudo GOLDEN_AMI=false GITLAB_RUNNER_TOKEN= bash init-gitlab-runner-al2023.sh` (empty token →
  bakes Docker + AWS CLI v2 + mise + all Node/Python versions + `gitlab-runner`, but does **not**
  register). Verify, then snapshot (**Packer recommended**).
- **Never bake a runner token into the image.**
- Launch the AMI in the private subnet, attach `RunnerRole`, set IMDSv2
  (`HttpTokens=required`, hop limit 1), no public IP, no IGW/NAT route. Register over SSM with
  `GOLDEN_AMI=true`.

---

## 12. Required-features checklist

Legend: **[M]** mandatory · **[O]** optional.

**Networking — VPC endpoints**
- [M] S3 **Gateway** endpoint (CDK assets + ECR layers + runner cache + CodeArtifact payloads)
- [M] STS **regional** interface endpoint (+ `AWS_STS_REGIONAL_ENDPOINTS=regional`)
- [M] cloudformation, codeartifact.api, codeartifact.repositories
- [M] ecr.api + ecr.dkr, logs, kms
- [M] ssm + ssmmessages + ec2messages (Session Manager)
- [M] codebuild
- [M] endpoint SG inbound 443 from subnet CIDR; **Private DNS enabled** on all interface endpoints
- [O] secretsmanager, ec2, dynamodb (Gateway)

**IAM**
- [M] RunnerRole instance profile (EC2 trust)
- [M] CodeArtifact read (domain/repo/package ARNs)
- [M] `sts:GetServiceBearerToken` (Resource `*`, codeartifact condition)
- [M] cross-account `sts:AssumeRole` (Model A `cdk-hnb659fds-*` and/or Model B `OrgDeployRole`)
- [M] CodeBuild `StartBuild` on the **target** OrgDeployRole for cross-account
- [M] Session Manager perms, CloudWatch Logs write
- [M] target-account trust policies
- [O] S3 cache perms, KMS on bootstrap key

**Runtimes**
- [M] mise + Node 18/20/22 + Python 3.10/3.11/3.12 (golden AMI)
- [M] CDK via `npx` (pinned), Docker Engine on host, `gitlab-runner` in `docker` group
- [M] golden AMI pre-bakes everything

**Packaging**
- [M] CodeArtifact domain + npm-store (public:npmjs) + pypi-store (public:pypi)
- [M] per-job token refresh (12h TTL); npm/pip/uv config

**Runner**
- [M] shell executor; `config.toml` `environment[]` runtime injection
- [M] `glrt-*` token registration; systemd service as gitlab-runner
- [O] S3 distributed cache; Docker-executor alternative

**Cross-account**
- [M] CDK bootstrap in runner + every target account/region
- [M] `~/.aws/config` via `Ec2InstanceMetadata` (Model B) or `--trust` (Model A)
- [M] `cdk deploy --require-approval never`
- [O] cross-account CodeBuild (assume → StartBuild)

**Management & observability**
- [M] IMDSv2 enforced; SSM Agent + Session Manager
- [M] CloudWatch Logs; **GitLab server egress path resolved** (see §13)

---

## 13. Open decisions

1. **GitLab server reachability — HARD BLOCKER, decide first.** Self-managed in-VPC GitLab
   (PrivateLink/peering/route) vs GitLab.com SaaS. **GitLab.com has no AWS PrivateLink** — the
   runner cannot register or fetch jobs without a security-approved in-VPC proxy or NAT
   exception. Nothing else works until this is settled.
2. **Golden AMI vs in-place bootstrap.** Strongly recommend the golden AMI (in-place will fail
   in the isolated subnet). Decide AMI build/versioning ownership (Packer).
3. **CDK trust model — A vs B.** A is simplest and handles long deploys (per-op re-assume); B
   gives explicit per-account control/audit + ExternalId.
4. **Executor — shell (recommended) vs Docker + ECR image.**
5. **CDK in-runner vs CodeBuild trigger** — changes which endpoints/IAM are mandatory.
6. **Runner cache backend** — S3 distributed vs local-only.
7. **Target account × region matrix** — pin the exact set to scope ARNs/bootstrap.
8. **ExternalId usage** — set the same value across trust policy, profile generator, and the
   codebuild trigger, or remove it.
9. **Secrets source** — Secrets Manager (needs endpoint) vs SSM Parameter Store (already covered).
10. **Long-job limits** — STS chaining caps at 1h; CodeArtifact token at 12h.

---

## 14. Implementation plan (phased)

### Phase 0 — Decisions & prerequisites
- Resolve the **GitLab reachability** decision (§13.1). Choose **trust model** (§13.3) and
  **executor** (§13.4). Confirm the **account × region matrix**.

### Phase 1 — Network (security/network team, IaC)
- Create all VPC endpoints from §5 (S3 Gateway + interface endpoints, Private DNS enabled).
- SG: inbound 443 from subnet CIDR. Verify DNS resolution from a test host in the subnet.

### Phase 2 — CodeArtifact (runner account)
- Create domain + `npm-store` (upstream `public:npmjs`) + `pypi-store` (upstream `public:pypi`).

### Phase 3 — IAM
- Create `RunnerRole` (EC2 trust) + attach `iam-runner-policy.json` (substitute account IDs +
  region; delete the unused Model A/B AssumeRole block). Create the instance profile.

### Phase 4 — Target accounts
- **Model A:** `cdk bootstrap aws://<target>/<region> --trust <runner-account>
  --cloudformation-execution-policies <policy>` in every target account/region.
- **Model B:** create `OrgDeployRole` with `orgdeployrole-trust.json` (set/remove ExternalId);
  grant cross-account `codebuild:StartBuild` on that role.

### Phase 5 — Golden AMI (egress-enabled build account)
- `sudo GOLDEN_AMI=false GITLAB_RUNNER_TOKEN= bash init-gitlab-runner-al2023.sh` → verify →
  snapshot (Packer). No token baked in.

### Phase 6 — Launch & register (private subnet)
- Launch from the AMI, attach `RunnerRole`, IMDSv2 (`HttpTokens=required`, hop limit 1), no
  public IP/route. Over SSM:
  `sudo GOLDEN_AMI=true GITLAB_URL=… GITLAB_RUNNER_TOKEN=glrt-… bash init-gitlab-runner-al2023.sh`.

### Phase 7 — Cross-account config & helper install
- Model B only: `sudo EXTERNAL_ID=<id> bash aws-crossaccount-config.sh`.
- `sudo install -m 0755 codeartifact-login.sh /usr/local/bin/codeartifact-login.sh` (+ optional
  systemd timer).

### Phase 8 — Wire & validate the pipeline
- Copy `sample.gitlab-ci.yml` into a consuming repo as `.gitlab-ci.yml`; pin CDK in
  `package.json`; add a repo `.mise.toml` if desired.
- Run `runtime-matrix` (proves Node 18/20/22 × Python 3.10/3.11/3.12), `build:app`,
  `diff:cdk-dev`, `deploy:cdk-ts-dev` / `deploy:cdk-py-prod`, `codebuild:trigger`.

---

## 15. File inventory

| File | Type | Purpose |
|---|---|---|
| `init-gitlab-runner-al2023.sh` | bash | Master EC2 bootstrap (golden-AMI aware); Docker/AWS CLI v2/mise + runtimes; register + tune runner; runtime verification |
| `codeartifact-login.sh` | bash | 12h token refresh; configures npm/pip/uv (+poetry/twine); dual direct/sourced mode |
| `aws-crossaccount-config.sh` | bash | Generates `~/.aws/config` profiles (Ec2InstanceMetadata + role_arn); optional ExternalId |
| `iam-runner-policy.json` | json | RunnerRole permission policy |
| `orgdeployrole-trust.json` | json | Target-account OrgDeployRole trust (Model B) |
| `sample.gitlab-ci.yml` | yaml | Reference pipeline (multi-runtime + cross-account CDK + CodeBuild) |
| `README.md` | md | Operator quick reference |
| `DESIGN.md` / `DESIGN.html` | doc | This document |

---

## 16. Validation & testing

**Static (done locally):** `bash -n` on all scripts; JSON parses; `sample.gitlab-ci.yml`
validated with a real YAML parser (Ruby Psych) + an AST duplicate-key/tab/CRLF/coercion trap
scan — clean. Scanner verified against a deliberately-broken control file (it fired correctly).

**Semantic (run on your side — needs network):**

```bash
# GitLab CI Lint API
JSON=$(jq -Rs . < gitlab-runner/sample.gitlab-ci.yml)
curl -s -H "PRIVATE-TOKEN: <token>" -H "Content-Type: application/json" \
  --data "{\"content\": $JSON}" "https://<gitlab-host>/api/v4/ci/lint" | jq .
# or Pipeline Editor → Validate, or:  npx gitlab-ci-local --file gitlab-runner/sample.gitlab-ci.yml --list
```

**End-to-end gates:** runtime matrix switches versions; `npm ci` resolves via CodeArtifact;
`cdk diff` performs a cross-account lookup; `cdk deploy` (TS + Python) succeeds; CodeBuild
trigger assumes the target role and the build reaches `SUCCEEDED`.

---

## 17. Risks & known limits

- **Chained STS sessions hard-cap at 1 hour** regardless of `MaxSessionDuration` → prefer Model A
  per-operation re-assume for long deploys; the CodeBuild poll is bounded under 1h.
- **CodeArtifact token TTL is 12h** → re-source `codeartifact-login.sh` mid-job for very long jobs.
- **Token leakage** → never enable `CI_DEBUG_TRACE`/`set -x` in `before_script` (`pip.conf` holds
  the token; `PIP_INDEX_URL` is intentionally not exported).
- **uv named index** requires the consuming `pyproject.toml` to declare an index of the same name.
- **Single-runner design** — the `config.toml` patcher is scoped to one named `[[runners]]` block.
- **GitLab.com SaaS** is a hard blocker without an approved proxy/NAT exception.

---

## 18. Appendix — variable reference

Keep these identical across all files when substituting:

| Variable | Default |
|---|---|
| `AWS_REGION` | `ap-northeast-2` |
| Runner / CodeArtifact-owner account | `999999999999` |
| `CA_DOMAIN` | `my-domain` |
| `CA_NPM_REPO` | `npm-store` |
| `CA_PYPI_REPO` | `pypi-store` |
| Target accounts | `111111111111` / `222222222222` / `333333333333` |
| CDK qualifier | `hnb659fds` |
| Runner tags | `shell,cdk` (`,aws-private`) |
| mise dirs | `/usr/local/share/mise` + `/etc/mise` |
| Runtime injection | `config.toml environment[] BASH_ENV=/etc/profile.d/mise-shims.sh` |

**VPC endpoint service names (replace `<region>`):** Gateway → `com.amazonaws.<region>.s3`
(+`.dynamodb` if used). Interface (Private DNS enabled) → `.sts`, `.cloudformation`,
`.codeartifact.api`, `.codeartifact.repositories`, `.ecr.api`, `.ecr.dkr`, `.logs`, `.kms`,
`.ssm`, `.ssmmessages`, `.ec2messages`, `.codebuild`. Optional → `.secretsmanager`, `.ec2`.
