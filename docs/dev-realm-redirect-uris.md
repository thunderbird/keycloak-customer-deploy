# tb-dev: codified tbpro `thunderbird-accounts` client config (survives Neon resets)

The tb-dev Customer Auth Keycloak (`tbpro` realm) runs against a **Neon copy-on-write
branch (`mzla-tb-dev`) cloned from stage**. Stage's `thunderbird-accounts` OIDC client
only trusts the **stage** redirect URIs, and stage's app URLs point at
`accounts-stage.tb.pro`. tb-dev needs its own redirect URIs, web origins,
`rootUrl`/`baseUrl`/`adminUrl`, and an `is_services_admin` mapper on top — and these
live only in the branch DB.

**Any Neon branch reset ("sync with parent"/main) reverts the realm to the stage clone
and wipes all of that.** Previously this meant a manual `kcadm` re-add after every reset
(accounts login would 400 `invalid_redirect_uri`, and the "Back to Application" button
pointed at `accounts-stage.tb.pro`).

## How it's codified now

This config is **reconciled automatically on every Keycloak start** via
**keycloak-config-cli** (already shipped in the image, `/opt/keycloak/keycloak-config-cli.jar`) —
the same tool the image uses for the MFA step-up flow. Nothing is baked into the
`thunderbird-accounts` image; the config is delivered from **this deploy repo** as
ConfigMaps:

| Piece | File |
|-------|------|
| Desired client state (redirect URIs, web origins, app URLs, `is_services_admin` mapper) | `overlays/tb-dev/keycloak/realm-config/tbpro-accounts-client.yaml` → ConfigMap `keycloak-realm-config` (mounted at `/config`) |
| Reconcile script (waits for ready, runs config-cli, fail-soft) | `overlays/tb-dev/keycloak/realm-config/apply-client-config.sh` → ConfigMap `keycloak-realm-config-scripts` (mounted at `/scripts-extra`, launched from the overlay `command:`) |
| config-cli auth secret | `overlays/tb-dev/keycloak/admin-client-externalsecret.yaml` → env `KEYCLOAK_ADMIN_CLIENT_SECRET` |

**Auth:** config-cli authenticates via `client_credentials` as the master-realm
`tb-accounts-admin` service account (`KEYCLOAK_ADMIN_CLIENT_ID` / `KEYCLOAK_ADMIN_CLIENT_SECRET`).
That client is part of the **cloned stage `master` realm**, and its secret is stored in
`mzla/tb-dev/keycloak-customer-admin-client` as the **same value stage uses** — so it
keeps matching after a branch reset. (Wiring this also un-skips the image's
`apply-mfa-config.sh`, which was silently skipping on tb-dev because the secret was unset.)

**Safety:** `IMPORT_MANAGED_CLIENT=no-delete` — config-cli only adds/updates the one
listed client. It never deletes other `tbpro` clients or the ~150 real users. Verified
live: client/user counts unchanged across a reconcile.

## After a Neon branch reset

Just restart Keycloak — the reconcile re-applies the client config on boot:

```bash
kubectl --context tb-dev rollout restart statefulset keycloak-customer -n keycloak-customer
kubectl --context tb-dev rollout status  statefulset keycloak-customer -n keycloak-customer --timeout=180s
```

Then verify accounts login returns HTTP 200 (not 400 `invalid_redirect_uri`):

```bash
curl -s -o /dev/null -w '%{http_code}\n' \
  "https://auth.tb-dev.thunderbird.dev/realms/tbpro/protocol/openid-connect/auth?client_id=thunderbird-accounts&redirect_uri=https%3A%2F%2Faccounts.tb-dev.thunderbird.dev%2Foidc%2Fcallback%2F&response_type=code&scope=openid&state=probe"
```

To watch the reconcile itself: `kubectl --context tb-dev logs keycloak-customer-0 -c keycloak | grep -i 'apply-client-config\|config-cli\|Importing'`.

## Changing the domain / prod cutover (#142)

Hostnames are the only env-specific values, all in `tbpro-accounts-client.yaml`. A domain
change is an edit to that file. The **prod cutover reuses this exact mechanism**: the
tb-prod overlay ships its own `tbpro-accounts-client.yaml` with the real-domain URLs
(`accounts.tb.pro`, dropping the `accounts-stage.tb.pro` entries) plus the same
ExternalSecret / mount / `command` wiring, and its own
`mzla/tb-prod/keycloak-customer-admin-client` secret.

## Known residual: the `is_services_admin` **user attribute**

The codified mapper restores the *emission* of the `is_services_admin` claim, but the
per-user attribute (`is_services_admin=yes`, which the accounts middleware turns into
`is_staff`/`is_superuser`) is per-user data that a reset also reverts. It is **not**
codified here (this repo doesn't manage individual `tbpro` customer users). After a reset,
re-grant a staff user with the temp-admin technique below.

## Fallback: manual re-add (only if config-cli auth ever breaks)

Create a throwaway admin (the bootstrap env creds don't work on the stage-clone DB — the
master realm already has stage's admin), then re-apply with `kcadm`:

```bash
kubectl --context tb-dev exec -i -n keycloak-customer keycloak-customer-0 -c keycloak -- sh -s <<'EOF'
  PW=$(head -c 24 /dev/urandom | base64 | tr -d "=+/"); export PW
  env KC_CACHE=local KC_CACHE_STACK= KC_HTTP_MANAGEMENT_PORT=9990 KC_HTTP_PORT=8099 \
    /opt/keycloak/bin/kc.sh bootstrap-admin user --username tmp-admin --password:env PW
  KC=/opt/keycloak/bin/kcadm.sh
  $KC config credentials --server http://localhost:8080 --realm master --user tmp-admin --password "$PW"
  CID=$($KC get clients -r tbpro -q clientId=thunderbird-accounts --fields id --format csv --noquotes)
  # redirect URIs / web origins / app URLs: see tbpro-accounts-client.yaml for the values
  # is_services_admin user attribute (re-grant staff, USERID is that user's tbpro id):
  #   $KC update users/$USERID -r tbpro -s 'attributes.is_services_admin=["yes"]'
  AID=$($KC get users -r master -q username=tmp-admin --fields id --format csv --noquotes)
  $KC delete users/$AID -r master; rm -f ~/.keycloak/kcadm.config
EOF
```

Prod (`auth.tb.pro`) uses the real domain and is out of scope for tb-dev URIs.
