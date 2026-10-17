# Network egress inventory

`networkPolicy.enabled` is on by default. Each component gets a default-deny plus one egress
policy; every rule lists explicit TCP/UDP ports (`hack/check-render.py` fails CI otherwise).
Standard `networking.k8s.io/v1` only. FQDN-based egress (e.g. `*.amazonaws.com`) is not
expressible there; use a CNI-specific policy (CiliumNetworkPolicy `toFQDNs`, Calico
`GlobalNetworkPolicy` domains) as an optional add-on layered on top, and set
`networkPolicy.customerEgress.publicInternet=false` to drop the CIDR-based public rule.

"Public" below means `0.0.0.0/0` minus RFC1918, 169.254.0.0/16 (IMDS) and 100.64.0.0/10.

## Destinations by class

| Destination | Port(s) | Peer | Chart control | App evidence |
|---|---|---|---|---|
| kube-dns | 53 UDP/TCP | `k8s-app=kube-dns` | always | n/a |
| MongoDB | 27017 | `networkPolicy.database.cidrs` / `mongodb.cidr`, else any destination on that port | `database.driver` | `internal/config/config.go` `MONGODB_URI`, `DB_DRIVER` |
| PostgreSQL / MySQL / MSSQL / Oracle / Db2 | 5432 / 3306 / 1433 / 1521 / 50000 | same | `database.driver`, `networkPolicy.database.port` | `internal/config/config.go` `DB_DRIVER`; `internal/repository/{postgres,mysql,mssql,oracle,db2}` |
| Redis / Sentinel | 6379 / `redis.external.sentinelPort` (26379) | in-cluster pod, or `networkPolicy.redis.cidrs`, else any destination on those ports | `redis.mode` | `internal/envvars/envvars.go` `REDIS_URL`; `internal/dispatch/asynq/backend.go` |
| S3 / GCS / Spaces | 443 (+9000 for self-hosted MinIO on a public address) | public, or `networkPolicy.s3.cidrs` (private VPC endpoint) | `networkPolicy.s3.*` | `internal/config/config.go` `S3_ENDPOINT` |
| In-cluster MinIO | 9000 | pod `name=minio` | `minio.enabled` | chart `S3_ENDPOINT` |
| License server | 443 public; 8090 and 8443 (targetPort) in-cluster | public / ingress namespace / `licenseServer.internalNamespace` | `networkPolicy.licenseServer.*` | `internal/config/config.go` `LICENSE_SERVER_URL` |
| KeyGuard / idp-lite federation | 8443 | `keyguard.federationNamespace` | `keyguard.enabled` | `templates/_keyguard.tpl` |
| Step-CA | 9000 | in-release pod or `networkPolicy.stepCA.namespace` | `stepCA.mode` | `internal/config/config.go` `CA_SMALLSTEP_URL` |
| ClamAV ICAP | 1344 | in-release pod or `networkPolicy.icap.*` | `icapMode` | `internal/icap/client.go` |
| Rich-media / Tika / Presidio | `networkPolicy.{richMedia,tika,presidio}.port` (8080 / 9998 / 3000) | namespace-scoped when `.namespace` set | `richMedia.url`, `dlp.tikaUrl`, `dlp.presidioUrl` | `internal/config/config.go` `RICH_MEDIA_URL`, `TIKA_URL`, `PRESIDIO_URL`. Thumbnails are generated in-process (`internal/background/metadata_processor.go`): no extra destination |
| SendGrid / SES / OAuth-SSO IdPs / Google Workspace / Microsoft Graph | 443 | public | `sendgrid`, `platformEmail`, `networkPolicy.oauth.enabled`; ICES always 443 | `internal/mailsettings/client.go` (Gmail), Graph URLs in `internal/repository/*mailbox_registry*` |
| SMTP relays | `networkPolicy.smtp.ports` (25, 465, 587, 2525) | public + `smtp.cidrs` | `networkPolicy.smtp.*` | `internal/config/config.go` SMTP settings |
| Connectors, webhooks, SIEM, LLM (customer-chosen hosts) | `networkPolicy.<component>.customerEgressPorts` | `customerEgress.publicInternet` + `customerEgress.cidrs` | see below | `internal/messaging/kinds/remote`, `internal/webhook/delivery.go`, `internal/siemsyslog`, `internal/llmclient` |
| API (from gateways, MCP) | `service.targetPort` (8080) | pod `component=api` | always | `MNEMOSHARE_API_URL`, `SFTP_GATEWAY_API_BASE_URL` |

## Per component

| Component | Egress |
|---|---|
| api | DNS, database, storage, ICAP, Redis, rich-media/Tika/Presidio, Step-CA, license, KeyGuard, SendGrid/SES, SSO, SMTP, customer ports = `api.customerEgressPorts` (443) plus `workflowWorker.customerEgressPorts` when `workflowWorker.enabled=false` (the API then hosts the engines) |
| workflow-worker | same destinations; customer ports = `workflowWorker.customerEgressPorts` (21, 22, 443, 990) |
| ices | same destinations; customer ports = `ices.customerEgressPorts` (443); plus Gmail/Pub-Sub 443 |
| email-gateway | DNS, API, ICAP, rich-media/Tika/Presidio, relay database (when `emailGateway.relay.db` is set), SMTP, `emailGateway.customerEgressPorts` (443, AI provider) |
| inbound-gateway | DNS, API, database, storage, ICAP, rich-media/Tika/Presidio, SMTP ports to `inboundGateway.relayHost` (any destination, SMTP ports only), `inboundGateway.customerEgressPorts` (443) |
| mcp | DNS, API |
| sftp-gateway | DNS, API |
| step-ca (in-cluster) | DNS; ingress from release pods on 9000 |
| clamav | DNS, 80/443 public (signature updates) |
| redis (in-cluster) | DNS |

## Adding ports

Steps that dial other services need their port added to the worker list, e.g. rsync 873,
AS2 4080, `database_connect` 5432/3306/1433/1521/50000/27017:

```yaml
networkPolicy:
  workflowWorker:
    customerEgressPorts: [21, 22, 443, 990, 873, 5432]
  customerEgress:
    cidrs: [10.50.0.0/16]   # partner SFTP behind a VPN
```

Hook Jobs: this chart line renders none. Any future hook Job running the app image
must be covered by an egress policy (DNS + database) before shipping.

## Service account token

App pods set `automountServiceAccountToken: false`; the chart renders no Role/RoleBinding.
For Vault `kubernetes` auth set `vault.kubernetesAuth.enabled=true`: a projected,
audience-bound token (default audience `vault`, 3600 s) is mounted on api and
workflow-worker pods at `/var/run/secrets/mnemoshare/vault/token` and
`VAULT_K8S_TOKEN_PATH` points the app at it. Bind the same audience in the Vault role.
