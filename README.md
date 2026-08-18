# keycloak-customer-deploy

Kustomize manifests for **Thunderbird Pro Customer Auth** — the Keycloak instance
serving realm `tbpro` (`auth.tb.pro`) — deployed to the Thunderbird Pro EKS
clusters via ArgoCD. Migration plan & target architecture:
[`platform-infrastructure/docs/keycloak-customer-auth-migration.md`](https://github.com/thunderbird/platform-infrastructure/blob/main/docs/keycloak-customer-auth-migration.md).
Epic: [platform-infrastructure#132](https://github.com/thunderbird/platform-infrastructure/issues/132).

> **Database is shared Neon, not RDS.** Source ECS and the EKS target use the same
> shared Neon Postgres DB, reached over PrivateLink. There is **no data migration** —
> the prod cutover is a traffic flip. Validation runs against isolated Neon branches
> (`mzla-tb-{dev,prod}`). The vestigial ACK-RDS machinery was removed
> ([platform-infrastructure#579](https://github.com/thunderbird/platform-infrastructure/issues/579)).

## Layout

```
bases/
  keycloak/   namespace, StatefulSet, services (incl. metrics), PDB,
              db/admin ExternalSecrets, VMServiceScrape
overlays/
  tb-dev/     tailnet-only (Tailscale Ingress); Neon branch mzla-tb-dev; 2 replicas
  tb-prod/    tailnet-only validation; Neon branch mzla-tb-prod; 2 replicas
              (public Cloudflare tunnel + tailnet admin + 3 replicas are kept in the
              overlay dir but unreferenced until the cutover, #142)
```

The ArgoCD app-of-apps for each cluster lives in `platform-infrastructure`
(`argocd/tb-{dev,prod}/apps/keycloak-customer.yaml`) and points at
`overlays/<cluster>`. The cluster's Pulumi stack (`mzla-tb-{dev,prod}`, Phase 4e)
provides the Keycloak **Neon PrivateLink endpoint SG + pod SG + IRSA**; the pod SG
is assigned to the pods via the overlay's `SecurityGroupPolicy`.

## Build / validate

```bash
./util/kustomize-build-all.sh          # builds every overlay (CI gate)
kustomize build overlays/tb-dev        # or a single overlay
```

## Exposure model

- **Admin is never public.** It is reached over **Tailscale**, like the Staff SSO
  Keycloak. Both dev and prod are tailnet-only today (whole service). At the prod
  cutover (#142) tb-prod adds a public Cloudflare tunnel for the auth host, with the
  admin console/REST kept on the tailnet (`KC_HOSTNAME_ADMIN`) and public `/admin`
  denied at the edge (Cloudflare Access).
- **Realm `tbpro` lives in the shared Neon DB** (validated via isolated Neon
  branches) — there is no `--import-realm` and no data migration.
- **Admin front-channel host.** The `master` realm's front-channel (issuer + admin-console
  login + session iframe) is pinned to `KC_HOSTNAME_ADMIN` via a per-realm `frontendUrl`
  reconciled at startup (`realm-config/apply-master-frontendurl.sh`); without it the
  console's master login/iframe requests hit the public host and the `/realms/master`
  edge deny (KC 26 hostname v2, KC #32458).
- **Break-glass (admin unreachable).** If Tailscale is down, or `master`'s `frontendUrl`
  is set wrong (points at an unreachable/incorrect host), the admin console has no public
  path in. Reach it directly and, if needed, repair the attribute over a port-forward:
  ```bash
  kubectl -n keycloak-customer port-forward sts/keycloak-customer 8080:8080
  # then, in the pod (secret via env, never argv):
  kubectl -n keycloak-customer exec keycloak-customer-0 -- sh -c '
    KC_CLI_CLIENT_SECRET="$KEYCLOAK_ADMIN_CLIENT_SECRET" /opt/keycloak/bin/kcadm.sh \
      config credentials --server http://localhost:8080 --realm master \
      --client "$KEYCLOAK_ADMIN_CLIENT_ID";
    /opt/keycloak/bin/kcadm.sh update realms/master -s "attributes.frontendUrl=$KC_HOSTNAME_ADMIN"'
  ```
  The reconcile is idempotent and re-runs on the next pod start, so a manual fix is only
  a bridge until the config/branch is corrected.

## DB connectivity (Neon over PrivateLink)

The overlay's `keycloak/statefulset.yaml` sets `KC_DB_URL_HOST` to the env's Neon
endpoint (the `mzla-tb-{dev,prod}` branch today) + `KC_DB_URL_PROPERTIES=?sslmode=require`.
The pods reach Neon over the manually-created Neon interface endpoints, gated by the
dedicated `mzla-tb-{dev,prod}-keycloak-neondb-privatelink` endpoint SG; the pods carry
the dedicated pod SG via `keycloak/securitygrouppolicy.yaml`.

## Placeholders / per-env values

| Token / value | Source |
|-------|--------|
| `REPLACE_MZLA_ECR/keycloak-customer` (`kustomization.yaml` `images:`) | the per-account mzla ECR mirror (done, [platform-infrastructure#558](https://github.com/thunderbird/platform-infrastructure/pull/558)); each overlay sets `newName` + `newTag` |
| `keycloak/securitygrouppolicy.yaml` `groupIds` | the cluster's eks-cluster-sg + `pulumi stack output keycloak_customer_pod_sg_id` (`mzla-tb-{dev,prod}`) |
| `KC_DB_URL_HOST` (overlay `keycloak/statefulset.yaml`) | the env's Neon endpoint (branch today; live shared endpoint at cutover) |

Secrets (AWS Secrets Manager, per account, eu-central-1) referenced by the
ExternalSecrets: `mzla/<env>/keycloak-customer-db` and
`mzla/<env>/keycloak-customer-admin` (`{username, password}`).
tb-dev also uses `mzla/tb-dev/keycloak-customer-admin-client` (`{client-secret}`) for
keycloak-config-cli auth (the `tb-accounts-admin` service account) — see
[docs/dev-realm-redirect-uris.md](docs/dev-realm-redirect-uris.md) for the codified
`thunderbird-accounts` client reconcile that keeps tb-dev config across Neon resets.
`mzla/shared-services/cloudflare-operator` already exists (read cross-account; used by the cutover Cloudflare resources).

## Not yet included (cutover follow-ups, #142)

- Public Cloudflare tunnel (`auth.tb.pro`) + tailnet admin ingress + 3 replicas (files present, unreferenced).
- Public `/admin` deny for tb-prod (Cloudflare Access).
- Repoint `KC_DB_URL_HOST` from the validation branch to the live shared Neon endpoint.
