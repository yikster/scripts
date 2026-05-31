# GitLab Runner — S3-only environment (no VPC endpoints)

For a private-subnet EC2 GitLab Runner where **the only reachable network
destination is AWS S3** (plus link-local IMDS), every other public URL is blocked
(mise.run, github.com, npmjs.org, pypi.org, packages.gitlab.com, …), **and you
cannot add VPC endpoints**.

The fix: the runner becomes a dumb **"git archive + `aws s3 cp`"** agent. All real
AWS work (`cdk deploy`, CodeArtifact, ECR, cross-account `AssumeRole`) is offloaded
to **CodeBuild in the deploy account**, triggered by the S3 upload. Status returns
via S3. This needs **zero new VPC endpoints, zero proxy changes, zero public routing.**

---

## Reachability matrix

| Operation | Hostname | S3-only? |
|---|---|---|
| Instance-role credentials | `169.254.169.254` (IMDS) | YES — local, no STS call |
| `aws s3 cp/sync` | `s3.<region>.amazonaws.com` | YES — SigV4 signed locally |
| Same-account S3 | bucket endpoint | YES — via runner IAM |
| Cross-account S3 | target bucket endpoint | YES — via **bucket policy + runner IAM** (no AssumeRole) |
| Bootstrap-from-S3 | mirror bucket | YES — pre-staged artifacts |
| `cdk deploy` / CloudFormation | `cloudformation.<region>` | NO — blocked |
| Cross-account `AssumeRole` | `sts.<region>` | NO — blocked |
| CodeArtifact (npm/pip auth + repo) | `codeartifact.<region>`, `<d>-<o>.d.codeartifact.<region>` | NO — blocked |
| ECR | `api.ecr.<region>`, `<acct>.dkr.ecr.<region>` | NO — blocked |
| CloudWatch Logs | `logs.<region>` | NO — blocked |
| CodeBuild `StartBuild` | `codebuild.<region>` | NO — blocked |

> **Gotcha:** `awscli.amazonaws.com` is **not** S3-backed (CloudFront) — also
> blocked. You must mirror the CLI zip into your own S3 bucket.
> `gitlab-runner-downloads.s3.amazonaws.com` **is** genuinely S3-backed.

**Net:** the runner can only move bytes in/out of S3 and talk to IMDS. Anything
that mutates other AWS services must be offloaded.

---

## Files

| File | Purpose |
|---|---|
| `build-s3-mirror.sh` | Run in a build account **with egress**. Mirrors gitlab-runner, aws-cli v2 zip, mise, Node tarballs, and python-build-standalone into your S3 mirror bucket with the exact key layout mise expects. |
| `init-runner-golden-ami.sh` | **Tier 1 (preferred).** Bakes a golden AMI: installs everything from the S3 mirror, writes `/etc/mise/settings.toml` with `node.mirror_url` + a `url_replacements` regex for python-build-standalone, warms the runtimes. Snapshot after. |
| `init-runner-s3-bootstrap.sh` | **Tier 2 (fallback).** Same install but at boot via user-data + instance role (no AMI). Also registers + tunes the runner if a token is provided. |
| `gitlab-ci-s3-deploy-trigger.yml` | The only job the runner runs: `git archive` → `aws s3 cp` (SSE-KMS) to the trigger bucket → poll the status bucket → exit with CodeBuild's code. |
| `target-account-pipeline.md` | The deploy-account half: EventBridge → CodePipeline → CodeBuild running `cdk deploy`; cross-account KMS/bucket/event wiring; buildspec with a `finally:` status write. |
| `iam/runner-minimal-policy.json` | Runner instance-role policy — **S3 + KMS only**. No sts/cfn/codebuild/codeartifact/ecr/logs (those endpoints are unreachable; granting them is misleading). |
| `iam/trigger-bucket-policy.json` | Trigger bucket resource policy: allow runner `PutObject`, deny non-KMS puts, deny insecure transport. |
| `iam/status-bucket-policy.json` | Status bucket: runner reads, CodeBuild writes. |
| `iam/kms-cross-account-key-policy.json` | Customer-managed CMK usable by both runner and deploy accounts. |

---

## Bootstrap (Tier 1 — golden AMI)

```bash
# 1) In a build account WITH egress: mirror everything to S3.
MIRROR_BUCKET=my-mirror AWS_REGION=ap-northeast-2 bash build-s3-mirror.sh

# 2) On a build instance that can reach the mirror: bake.
sudo MIRROR_BUCKET=my-mirror AWS_REGION=ap-northeast-2 bash init-runner-golden-ami.sh
#    -> verify, then create the AMI (Packer recommended). Do NOT bake a runner token.

# 3) Launch the AMI in the private subnet; register at boot:
sudo GITLAB_URL=https://gitlab.internal GITLAB_RUNNER_TOKEN=glrt-... \
     MIRROR_BUCKET=my-mirror bash init-runner-s3-bootstrap.sh
```

**mise mirror redirects** (written into `/etc/mise/settings.toml` before any install):

```toml
[settings]
node.mirror_url = "https://my-mirror.s3.ap-northeast-2.amazonaws.com/node-builds"

[settings.url_replacements]
"regex:^https://github\\.com/astral-sh/python-build-standalone/releases/download/(.+)" = "https://my-mirror.s3.ap-northeast-2.amazonaws.com/python-builds/$1"
```

> `node.mirror_url` (env `MISE_NODE_MIRROR_URL`) is a real setting. There is **no**
> `MISE_PYTHON_MIRROR_URL` — Python must go through `url_replacements`.
> Run `mise reshim` after installs. `$1` is mise's regex capture, not a shell var.

---

## Packages

CodeArtifact is unreachable from the runner. So:

- **Primary:** run `npm ci` / `pip install` **inside CodeBuild** (where CodeArtifact
  works via `aws codeartifact login`). The runner never touches npm/pip.
- **Fallback (only if the runner must build locally):** `aws s3 sync` pre-built
  wheels from the mirror, then `pip install --no-index --find-links`. Do **not**
  host a public unsigned PEP 503 index (pip can't SigV4-sign S3). For npm, use a
  pre-synced `~/.npm` cache + `npm ci --offline`.

---

## Multi-account deploys

Cross-account `AssumeRole` is impossible on the runner. It happens **inside
CodeBuild** instead: bootstrap each target with
`cdk bootstrap aws://<acct>/<region> --trust <deploy-account>`, and CDK auto-assumes
the target `cdk-hnb659fds-*` roles. The CodeBuild role needs `sts:AssumeRole` on
those ARNs.

---

## Decision tree

- Must run a cdk/codebuild deploy, only S3 + IMDS reachable? → **S3-event offload** (this design).
- Can security allowlist AWS API domains on an existing forward proxy? → simplest alternative: keep the runner running cdk, set `HTTPS_PROXY` + `NO_PROXY=169.254.169.254`. If no → stay on offload.
- Is Transit-Gateway routing to a **shared-services VPC's** endpoints allowed (not "endpoints in my subnet")? → consume centralized interface endpoints via a Route 53 private hosted zone. If no → stay on offload.
- Need npm/pip during the build? → do it in **CodeBuild**. Genuinely need it on the runner? → `aws s3 sync` wheels + `pip --no-index`.
- Deploying into other accounts? → `AssumeRole` in CodeBuild, never on the runner.
- Can you run an AMI bake pipeline? → **golden AMI** (Tier 1). If not → Tier-2 boot bootstrap.
- Tempted to grant the runner sts/cfn/ecr/codeartifact IAM "just in case"? → **don't** — those endpoints are unreachable; grant **S3 + KMS only**.

---

## Security-ask escalation (if you outgrow offload)

Ranked least-friction first; copy-paste asks:

1. **Proxy domain allowlist** — *"On the existing egress proxy, please allowlist
   `sts.<region>.amazonaws.com`, `cloudformation.<region>.amazonaws.com`,
   `codeartifact.<region>.amazonaws.com`, `*.d.codeartifact.<region>.amazonaws.com`,
   `api.ecr.<region>.amazonaws.com`, `*.dkr.ecr.<region>.amazonaws.com`,
   `logs.<region>.amazonaws.com` for the runner subnet."* AWS CLI honors
   `HTTPS_PROXY`/`NO_PROXY` (keep `169.254.169.254` in `NO_PROXY`).
2. **Shared-services endpoints via Transit Gateway** — *"Please route the runner
   subnet to the shared-services VPC interface endpoints over TGW and associate the
   AWS-service Route 53 private hosted zones."* This is not "adding an endpoint to
   my subnet," so it may pass policy.
3. **S3-event offload** (this design) — needs nothing from security beyond the
   existing S3 reachability.
