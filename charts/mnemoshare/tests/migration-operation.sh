#!/usr/bin/env bash
set -euo pipefail

chart_dir=${1:-charts/mnemoshare}
digest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
target_digest=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
base=(
  --set customerId=ci-test
  --set formatMigrations.mode=operator
  --set image.digest="$digest"
  --set mongodb.external.enabled=true
  --set mongodb.external.uri=mongodb://test:test@localhost:27017/test
  --set s3.bucket=test --set s3.accessKey=test --set s3.secretKey=test
  --set-string jwt.ecPrivateKey=test
  --set encryption.key=test-encryption-key-exactly-32by
  --set license.key=test --set appUrl=https://test.example.com
  --set ingress.enabled=false
)

ordinary=$(helm template test "$chart_dir" "${base[@]}" --set migrationOperation.enabled=false)
if grep -Fq 'app.kubernetes.io/component: migration-operation' <<<"$ordinary"; then
  echo 'disabled migration operation rendered a control resource' >&2
  exit 1
fi
grep -Fq 'replicas: 2' <<<"$ordinary"
if grep -Fq 'replicas: 0' <<<"$ordinary"; then
  echo 'ordinary mode unexpectedly scaled a workload down' >&2
  exit 1
fi

plan=$(helm template test "$chart_dir" "${base[@]}" \
  --set migrationOperation.enabled=true \
  --set migrationOperation.phase=plan \
  --set migrationOperation.targetImage.repository=mnemoshare/mnemoshare \
  --set migrationOperation.targetImage.digest="$target_digest" \
  --set migrationOperation.transport.existingClaim=migration-transport)
grep -Fq 'kind: Job' <<<"$plan"
grep -Fq 'command: ["/bin/sh", "-ec"]' <<<"$plan"
grep -Fq 'mnemoshare.io/migration-operation-contract-fingerprint: "e48308c8d8e8741fbe06d9ef4e104414c380340fcb49e33e699222ed0b94ab6c"' <<<"$plan"
grep -Fq '/usr/local/bin/mnemoshare-migrate plan --contract embedded' <<<"$plan"
grep -Fq 'cp "${result_file}" /dev/termination-log' <<<"$plan"
grep -Fq 'result_bytes=' <<<"$plan"
grep -Fq 'terminationMessagePath: /dev/termination-log' <<<"$plan"
grep -Fq 'terminationMessagePolicy: File' <<<"$plan"
grep -Fq 'mnemoshare.io/migration-operation-phase: "plan"' <<<"$plan"
grep -Fq 'mnemoshare.io/migration-operation-universe: "primary"' <<<"$plan"
grep -Fq 'mnemoshare.io/migration-operation-plan-digest: "pending"' <<<"$plan"
grep -Fq 'mnemoshare.io/migration-operation-id: "active"' <<<"$plan"
grep -Fq '/migration/primary-plan.json' <<<"$plan"
grep -Fq '/migration/primary-result.json' <<<"$plan"
if grep -Fq 'helm.sh/hook' <<<"$plan"; then
  echo 'migration-operation Job must not be a Helm hook' >&2
  exit 1
fi

apply=$(helm template test "$chart_dir" "${base[@]}" \
  --set migrationOperation.enabled=true \
  --set migrationOperation.phase=apply \
  --set migrationOperation.targetImage.repository=mnemoshare/mnemoshare \
  --set migrationOperation.targetImage.digest="$target_digest" \
  --set migrationOperation.transport.existingClaim=migration-transport \
  --set migrationOperation.planDigest=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc)
grep -Fq '/usr/local/bin/mnemoshare-migrate apply --contract embedded' <<<"$apply"
grep -Fq -- '--plan /migration/primary-plan.json --exclusive --expect-plan-digest cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc' <<<"$apply"
grep -Fq 'mnemoshare.io/migration-operation-phase: "apply"' <<<"$apply"
grep -Fq 'mnemoshare.io/migration-operation-universe: "primary"' <<<"$apply"
grep -Fq 'mnemoshare.io/migration-operation-plan-digest: "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"' <<<"$apply"
grep -Fq 'name: test-mnemoshare-migration-primary-apply-active' <<<"$apply"
grep -Fq 'outcome=succeeded' <<<"$apply"
grep -Fq 'planDigest":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"' <<<"$apply"
grep -Fq 'backoffLimit: 0' <<<"$apply"

verify=$(helm template test "$chart_dir" "${base[@]}" \
  --set migrationOperation.enabled=true \
  --set migrationOperation.phase=verify \
  --set migrationOperation.targetImage.repository=mnemoshare/mnemoshare \
  --set migrationOperation.targetImage.digest="$target_digest" \
  --set migrationOperation.transport.existingClaim=migration-transport \
  --set migrationOperation.planDigest=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc)
grep -Fq '/usr/local/bin/mnemoshare-migrate verify --contract embedded' <<<"$verify"
grep -Fq -- '--plan /migration/primary-plan.json --expect-plan-digest cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc' <<<"$verify"
if grep -Fq -- 'mnemoshare-migrate verify --contract embedded --plan /migration/primary-plan.json --exclusive' <<<"$verify"; then
  echo 'verify phase must not receive apply-only --exclusive' >&2
  exit 1
fi
grep -Fq 'mnemoshare.io/migration-operation-phase: "verify"' <<<"$verify"
grep -Fq 'outcome=succeeded' <<<"$verify"

down=$(helm template test "$chart_dir" "${base[@]}" \
  --set autoscaling.enabled=true \
  --set workflowWorker.enabled=true \
  --set workflowWorker.autoscaling.enabled=true \
  --set redis.external.enabled=true --set redis.external.host=redis.example.com \
  --set ices.enabled=true \
  --set ices.autoscaling.enabled=true \
  --set ices.autoscaling.subscriptionName=projects/test/subscriptions/test \
  --set inboundGateway.enabled=true \
  --set migrationOperation.enabled=true \
  --set migrationOperation.phase=down \
  --set migrationOperation.targetImage.repository=mnemoshare/mnemoshare \
  --set migrationOperation.targetImage.digest="$target_digest")
test "$(grep -Fc 'replicas: 0' <<<"$down")" -ge 4
grep -Fq 'mnemoshare.io/process-id: "api"' <<<"$down"
grep -Fq 'mnemoshare.io/process-profile: "default"' <<<"$down"
grep -Fq 'mnemoshare.io/process-universe: "primary"' <<<"$down"
grep -Fq 'mnemoshare.io/process-id: "workflow-worker"' <<<"$down"
grep -Fq 'mnemoshare.io/process-id: "cloud-worker"' <<<"$down"
grep -Fq 'mnemoshare.io/process-id: "inboundgateway"' <<<"$down"
if grep -Eq '^kind: (HorizontalPodAutoscaler|ScaledObject|TriggerAuthentication)$' <<<"$down"; then
  echo 'maintenance phase left an autoscaler in the rendered writer universe' >&2
  exit 1
fi

up=$(helm template test "$chart_dir" "${base[@]}" \
  --set migrationOperation.enabled=true --set migrationOperation.phase=up \
  --set migrationOperation.targetImage.repository=mnemoshare/mnemoshare \
  --set migrationOperation.targetImage.digest="$target_digest" \
  --set migrationOperation.planDigest=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc \
  --set migrationOperation.verifiedPlanDigest=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc)
grep -Fq "image: \"mnemoshare/mnemoshare@$target_digest\"" <<<"$up"
if grep -Fq 'app.kubernetes.io/component: migration-operation' <<<"$up"; then
  echo 'up phase unexpectedly rendered a migration Job' >&2
  exit 1
fi

if helm template test "$chart_dir" "${base[@]}" \
    --set migrationOperation.enabled=true --set migrationOperation.phase=up \
    --set migrationOperation.targetImage.repository=mnemoshare/mnemoshare \
    --set migrationOperation.targetImage.digest="$target_digest" \
    --set migrationOperation.planDigest=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc \
    --set migrationOperation.verifiedPlanDigest=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd >/dev/null 2>&1; then
  echo 'up phase accepted a digest that was not verified' >&2
  exit 1
fi

external=$(helm template test "$chart_dir" "${base[@]}" \
  --set emailGateway.enabled=true --set emailGateway.mode=relay \
  --set emailGateway.relay.db.uri=mongodb://relay:test@relay:27017/test \
  --set emailGateway.relay.db.name=relay --set emailGateway.relay.adminKey=admin \
  --set emailGateway.relay.spoolSharedKey=spool \
  --set emailGateway.relay.persistence.enabled=true \
  --set emailGateway.relay.spoolDir=/var/spool/mnemo-relay --set emailGateway.replicas=1 \
  --set deploymentContractV3.sourceCommit=0dd4f8eb13b9afb35a586f4ac7bc8618d25d7886 \
  --set deploymentContractV3.contractFingerprint=23dc67fb882b463fbc1bd05d0732d2a5aadc86b3070b228dd5f62cb204319cc6 \
  --set deploymentContractV3.imageDigest="$digest" \
  --set migrationOperation.enabled=true --set migrationOperation.phase=plan \
  --set migrationOperation.universe=email-relay-mongo \
  --set migrationOperation.targetImage.repository=mnemoshare/mnemoshare \
  --set migrationOperation.targetImage.digest="$target_digest" \
  --set migrationOperation.transport.existingClaim=migration-transport)
grep -Fq '"email-relay-mongo"' <<<"$external"
external_job=$(awk '
  /# Source: mnemoshare\/templates\/migration-operation-job.yaml/ { active=1 }
  active { print }
  active && /# Source:/ && ! /migration-operation-job.yaml/ { exit }
' <<<"$external")
grep -Fq '/migration/email-relay-mongo-plan.json' <<<"$external_job"
grep -Fq 'name: RELAY_DB_URI' <<<"$external_job"
grep -Fq 'mnemoshare.io/migration-operation-universe: "email-relay-mongo"' <<<"$external_job"
grep -Fq 'mnemoshare.io/process-id: "emailgateway"' <<<"$external"
grep -Fq 'mnemoshare.io/process-profile: "relay-dkim-and-tokens"' <<<"$external"
grep -Fq 'mnemoshare.io/process-universe: "email-relay-mongo"' <<<"$external"
if grep -Fq 'name: MONGODB_URI' <<<"$external_job"; then
  echo 'external universe migration Job leaked primary database credentials' >&2
  exit 1
fi
if grep -Eq 'MONGODB_DATABASE|mongodb-uri|encryption-key|license-key' <<<"$external_job"; then
  echo 'external universe migration Job leaked primary or chart-secret settings' >&2
  exit 1
fi

echo 'migration-operation/v1 chart checks passed'
