# keycloak-customer-deploy

Kustomize manifests for **Thunderbird Pro Customer Auth** — the Keycloak instance
serving realm `tbpro` (`auth.tb.pro`) — deployed to the Thunderbird Pro EKS
clusters via ArgoCD. Migration plan & target architecture:
[`platform-infrastructure/docs/keycloak-customer-auth-migration.md`](https://github.com/thunderbird/platform-infrastructure/blob/main/docs/keycloak-customer-auth-migration.md).
Epic: [platform-infrastructure#132](https://github.com/thunderbird/platform-infrastructure/issues/132).

## Layout

```
bases/
  aws/        ACK RDS: DBInstance, DBSubnetGroup, FieldExport
  keycloak/   namespace, StatefulSet, services, PDB, RDS-endpoint ConfigMap,
              db/admin ExternalSecrets, VMServiceScrape
overlays/
  tb-dev/     tailnet-only (Tailscale Ingress); single-AZ dev DB
  tb-prod/    public Cloudflare tunnel (auth) + tailnet admin Ingress; Multi-AZ DB
```

The ArgoCD app-of-apps for each cluster lives in `platform-infrastructure`
(`argocd/tb-{dev,prod}/apps/keycloak-customer.yaml`) and points at
`overlays/<cluster>`. The cluster's Pulumi stack provides the `ack-rds` IRSA role
and the Keycloak RDS security group; the ACK RDS controller is deployed from
`platform-infrastructure`.

## Build / validate

```bash
./util/kustomize-build-all.sh          # builds every overlay (CI gate)
kustomize build overlays/tb-dev        # or a single overlay
```

## Exposure model

- **Admin is never public.** It is reached over **Tailscale**, like the Staff SSO
  Keycloak. tb-dev is tailnet-only (whole service). tb-prod exposes only the
  customer auth host publicly via Cloudflare tunnel; the admin console/REST is on
  the tailnet (`KC_HOSTNAME_ADMIN`), with public `/admin` denied at the edge.
- **Realm `tbpro` arrives via the database** (snapshot restore for dev / logical
  replication for the prod cutover) — there is no `--import-realm`.

## Placeholders to resolve before deploy

Per overlay (`overlays/<cluster>/`), replace:

| Token | Source |
|-------|--------|
| `REPLACE_MZLA_ECR/keycloak-customer` + `REPLACE_*_MIRRORED_SHA` (`kustomization.yaml` `images:`) | mirrored image ([platform-infrastructure#531](https://github.com/thunderbird/platform-infrastructure/issues/531)) |
| `REPLACE_*_RDS_SG_KEYCLOAK_ID` (`aws/db-instance.yaml`) | `pulumi stack output rds_sg_keycloak_id` |
| `REPLACE_*_PRIVATE_SUBNET_A/B` (`aws/db-subnet-group.yaml`) | `pulumi stack output private_subnet_ids` |
| tb-dev `KC_HOSTNAME` tailnet host / tb-prod `auth.tb.pro` + Cloudflare zone | confirm tailnet name + that `tb.pro` is a managed Cloudflare zone |

Secrets (AWS Secrets Manager, per account, eu-central-1) referenced by the
ExternalSecrets: `mzla/<env>/keycloak-customer-db` and
`mzla/<env>/keycloak-customer-admin` (`{username, password}`).
`mzla/shared-services/cloudflare-operator` already exists (read cross-account).

## Not yet included (follow-ups)

- Public `/admin` deny for tb-prod (Cloudflare Access) — gates the prod cutover.
- DR backup CronJob (port from Staff SSO `argocd/keycloak/dr-backup-*`) before the
  [#142](https://github.com/thunderbird/platform-infrastructure/issues/142) cutover.
