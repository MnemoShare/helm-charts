#!/usr/bin/env bash
# Renders the chart in several shapes and runs hack/check-render.py on each.
set -euo pipefail
cd "$(dirname "$0")/.."
BASE=(
  --set customerId=ci-test
  --set image.digest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  --set cors.allowedOrigins=https://ci.example.com
  --set mongodb.external.enabled=true
  --set mongodb.external.uri=mongodb://test:test@localhost:27017/test
  --set s3.bucket=test-bucket --set s3.accessKey=test-key --set s3.secretKey=test-secret
  --set-string jwt.ecPrivateKey=test-ec-key
  --set encryption.key=test-encryption-key-exactly-32by
  --set license.key=test-license-key
  --set appUrl=https://test.example.com
  --set ingress.enabled=false
)
ALL=(
  --set sftpGateway.enabled=true --set sftpGateway.hostKey.existingSecret=hk
  --set mcp.enabled=true --set mcp.apiKey.key=mcp_test --set ices.enabled=true
  --set emailGateway.enabled=true --set inboundGateway.enabled=true
  --set inboundGateway.relayHost=postfix:25
  --set redis.mode=external --set redis.external.host=redis.example.com --set redis.external.sentinelPort=26379
  --set richMedia.url=http://rm:8080 --set dlp.tikaUrl=http://tika:9998 --set dlp.presidioUrl=http://pres:3000
  --set networkPolicy.stepCA.namespace=step --set stepCA.mode=external --set mtls.caProvider.url=https://step-ca.step:9000
)
run() {
  local label=$1; shift
  helm template mnemoshare charts/mnemoshare "${BASE[@]}" "$@" | python3 hack/check-render.py | sed "s/^/[$label] /"
}
run default
run all-components "${ALL[@]}"
run worker-deployment "${ALL[@]}" --set workflowWorker.enabled=true
run worker-statefulset "${ALL[@]}" --set workflowWorker.enabled=true --set workflowWorker.persistence.enabled=true
run legacy-workflows-flag "${ALL[@]}" --set networkPolicy.workflows.enabled=true
run vault-k8s-auth "${ALL[@]}" --set workflowWorker.enabled=true --set vault.kubernetesAuth.enabled=true
run ftp-passive "${ALL[@]}" --set workflowWorker.enabled=true --set networkPolicy.workflows.ftpPassive.enabled=true --set "networkPolicy.workflows.ftpPassive.cidrs={203.0.113.0/28}"
run vault-k8s-auth-no-tmp "${ALL[@]}" --set workflowWorker.enabled=true --set workflowWorker.tmpVolume.enabled=false --set diskBuffer.enabled=false --set vault.kubernetesAuth.enabled=true
run vault-k8s-auth-statefulset-no-tmp "${ALL[@]}" --set workflowWorker.enabled=true --set workflowWorker.persistence.enabled=true --set workflowWorker.tmpVolume.enabled=false --set diskBuffer.enabled=false --set vault.kubernetesAuth.enabled=true
run extra-egress "${ALL[@]}" --set workflowWorker.enabled=true --set mtls.enabled=true --set-json 'networkPolicy.workflowWorker.extraEgress=[{"to":[{"namespaceSelector":{"matchLabels":{"kubernetes.io/metadata.name":"tailscale"}}}],"ports":[{"protocol":"TCP","port":2525}]}]'
run strict-all-cidrs "${ALL[@]}" --set networkPolicy.strict=true --set "networkPolicy.database.cidrs={10.0.0.0/24}" --set "networkPolicy.redis.cidrs={10.0.1.0/24}" --set "emailGateway.relay.db.networkPolicyCIDRs={10.0.2.0/24}" --set "formatMigrations.networkPolicy.databaseCIDRs={10.0.0.0/24}" --set "formatMigrations.networkPolicy.kubernetesApiTargets[0].cidr=10.96.0.1/32" --set "formatMigrations.networkPolicy.kubernetesApiTargets[0].port=443"
run sandbox-api-host "${ALL[@]}" --set sandbox.enabled=true --set sandbox.runner.replicas=1 --set sandbox.runner.tls.issuerRef.name=issuer
run sandbox-worker-host "${ALL[@]}" --set workflowWorker.enabled=true --set sandbox.enabled=true --set sandbox.createNamespace=true --set sandbox.runner.tls.issuerRef.name=issuer
run policy-off --set networkPolicy.enabled=false
run postgres --set database.driver=postgres --set-string postgres.dsn=postgres://u:p@h:5432/d
run db2 --set database.driver=db2 --set formatMigrations.mode=operator
run sqlite --set database.driver=sqlite --set formatMigrations.mode=operator
run in-cluster-ca-clamav-redis --set stepCA.mode=inCluster --set redis.mode=inCluster --set redis.password=x --set clamav.enabled=true
run api-only "${ALL[@]}" --set workflowWorker.enabled=true --set workflowWorker.command[0]=/usr/local/bin/run-workers --set api.embeddedWorkers=false
run migration-operation "${ALL[@]}" --set formatMigrations.mode=operator --set migrationOperation.enabled=true --set migrationOperation.phase=apply --set migrationOperation.operationId=ci-op --set migrationOperation.targetImage.repository=mnemoshare/mnemoshare --set migrationOperation.targetImage.digest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --set migrationOperation.transport.existingClaim=c --set migrationOperation.planDigest=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb --set migrationOperation.verifiedPlanDigest=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb --set migrationOperation.contractFingerprint=$(jq -r .fingerprint charts/mnemoshare/tests/contracts/migration-operation/v1/contract.json)
