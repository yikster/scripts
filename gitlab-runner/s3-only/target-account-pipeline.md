# Target / deploy-account pipeline (S3-event offload)

This is the half of the S3-only architecture that runs **outside** the locked-down
runner. It lives in the **deploy account** (the account that owns the trigger
bucket and the CodePipeline/CodeBuild that actually runs `cdk deploy`). The deploy
account has normal egress (or its own endpoints), so STS, CloudFormation,
CodeArtifact, and ECR all work there.

> The runner only does `aws s3 cp` of `source.zip` and polls `status.json`.
> Everything below reacts to that upload and produces that status object.

---

## Flow

```
runner (S3-only)                 deploy account
────────────────                 ─────────────────────────────────────────────
git archive -> source.zip
aws s3 cp (SSE-KMS) ───────────► s3://trigger-bucket/runs/<id>/source.zip
                                   │  (EventBridge notifications ENABLED on bucket)
                                   ▼
                                 EventBridge rule (aws.s3 "Object Created")
                                   ▼
                                 CodePipeline  (S3 source, PollForSourceChanges=false)
                                   ▼
                                 CodeBuild project:
                                   - aws codeartifact login --tool npm|pip ...
                                   - npm ci / pip install
                                   - npx cdk synth
                                   - for each target acct: sts:AssumeRole
                                       cdk-hnb659fds-deploy-role-<acct>-<region>
                                   - npx cdk deploy --all --require-approval never
                                   - write status.json {"exit_code":N}
                                   ▼
aws s3api head-object ◄────────── s3://status-bucket/runs/<id>/status.json
exit <N>  (GitLab shows pass/fail)
```

---

## 1. Trigger bucket + EventBridge

S3 does **not** auto-forward to EventBridge — you must enable it:

```bash
aws s3api put-bucket-notification-configuration \
  --bucket trigger-bucket \
  --notification-configuration '{"EventBridgeConfiguration":{}}'
```

EventBridge rule (in the deploy account) matching the upload:

```json
{
  "source": ["aws.s3"],
  "detail-type": ["Object Created"],
  "detail": { "bucket": { "name": ["trigger-bucket"] },
              "object": { "key": [{ "prefix": "runs/" }] } }
}
```

Target the rule at CodePipeline (the rule's IAM role needs `codepipeline:StartPipelineExecution`).

---

## 2. CodePipeline (S3 source)

- Source action: S3, bucket `trigger-bucket`, object key `runs/<id>/source.zip`.
  Set **`PollForSourceChanges: false`** (EventBridge drives it).
- `artifactStore` must reference the **KMS key by explicit ARN**, not an alias
  (aliases only resolve in the owning account; cross-account needs the ARN).
- Build stage: the CodeBuild project below.

> Simplest topology: keep the trigger bucket **in the deploy account**, so the
> runner writes cross-account into it (bucket policy + runner IAM both required),
> and the pipeline is same-account with its source — no cross-account event bus.

---

## 3. CodeBuild project + buildspec

The CodeBuild **service role** is where the real privileges live: it can reach
CodeArtifact/ECR and can `sts:AssumeRole` into each target account's CDK roles.

`buildspec.yml`:

```yaml
version: 0.2
env:
  variables:
    AWS_STS_REGIONAL_ENDPOINTS: regional
    CA_DOMAIN: my-domain
    CA_DOMAIN_OWNER: "999999999999"
    CA_NPM_REPO: npm-store
    CA_PYPI_REPO: pypi-store
    STATUS_BUCKET: status-bucket
    KMS_KEY_ARN: arn:aws:kms:ap-northeast-2:RUNNER-ACCOUNT:key/KEY-ID
phases:
  install:
    runtime-versions:
      nodejs: 22
      python: 3.12
  pre_build:
    commands:
      # RUN_ID comes from the source object key; pass via CodePipeline variables or parse here.
      - export RUN_ID="${RUN_ID:?}"
      - aws codeartifact login --tool npm --domain "$CA_DOMAIN" --domain-owner "$CA_DOMAIN_OWNER" --repository "$CA_NPM_REPO"
      - aws codeartifact login --tool pip --domain "$CA_DOMAIN" --domain-owner "$CA_DOMAIN_OWNER" --repository "$CA_PYPI_REPO"
  build:
    commands:
      - npm ci
      - npx cdk synth
      # Model A: CDK auto-assumes cdk-hnb659fds-* in each bootstrapped target account.
      - npx cdk deploy --all --require-approval never
  finally:
    # Always write a status object so the runner's poll terminates (success OR failure).
    - |
      code=$?
      printf '{"exit_code":%s,"run_id":"%s","build":"%s"}' "$code" "${RUN_ID}" "${CODEBUILD_BUILD_ID}" > status.json
      aws s3 cp status.json "s3://${STATUS_BUCKET}/runs/${RUN_ID}/status.json" \
        --sse aws:kms --sse-kms-key-id "${KMS_KEY_ARN}"
artifacts:
  files: ['**/*']
```

> `finally:` runs even when `build` fails, so `exit_code` reflects the real result.
> Bootstrap each target account once: `cdk bootstrap aws://<acct>/<region> --trust <deploy-account>`.
> The CodeBuild role needs `sts:AssumeRole` on `arn:aws:iam::<target>:role/cdk-hnb659fds-*`.

---

## 4. Cross-account essentials

- **KMS CMK** (customer-managed, not `aws/s3`): key policy grants
  `kms:Decrypt` + `kms:GenerateDataKey*` + `kms:DescribeKey` to **both** the runner
  account root and the deploy account root. See `iam/kms-cross-account-key-policy.json`.
- **Trigger bucket policy**: allow the runner role `s3:PutObject` (+ `GetObject`,
  `ListBucket`), deny non-KMS puts, deny insecure transport. See
  `iam/trigger-bucket-policy.json`.
- **Status bucket policy**: allow the runner role read; allow the CodeBuild role
  `s3:PutObject`. See `iam/status-bucket-policy.json`.
- **Cross-account S3 needs both sides**: the runner's own IAM
  (`iam/runner-minimal-policy.json`) *and* the bucket's resource policy.

---

## 5. Optional: cross-account event bus

If the trigger bucket must live in the **runner account** instead, forward the
event to the deploy account:

- Sender rule target = the deploy account's default event bus
  `arn:aws:events:<region>:<deploy>:event-bus/default`, with an IAM role that has
  `events:PutEvents` (mandatory for rules created after 2023-03-02).
- Target bus needs a **resource policy** allowing `events:PutEvents` from the
  runner account.
- A second rule in the deploy account matches the forwarded event and starts the
  pipeline.

Prefer the same-account-trigger-bucket topology (§2) unless policy forces the
bucket into the runner account.
