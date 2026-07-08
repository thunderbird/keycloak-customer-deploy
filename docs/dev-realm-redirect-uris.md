# tb-dev: dev-only OIDC redirect URIs (and re-adding them after a Neon branch reset)

The tb-dev Customer Auth Keycloak (`tbpro` realm) runs against a **Neon copy-on-write branch
(`mzla-tb-dev`) cloned from stage**. Stage's `thunderbird-accounts` OIDC client only trusts the
**stage** redirect URIs (`accounts-stage.tb.pro`). For tb-dev's public exposure we add the
**tb-dev** redirect URIs on top — but these live only in the branch DB, **not** in stage.

## When they get wiped

**Any Neon branch reset ("sync with parent"/main) reverts the realm to the stage state and
DELETES these dev-only URIs.** After a reset the accounts login fails with
`400 Invalid parameter: redirect_uri`. (The reset keeps the endpoint + `keycloak_owner`
credentials, so Keycloak itself reconnects fine — only the realm *data* is reverted.)

So after every branch reset you must: **(1)** restart Keycloak to reconnect, then **(2)** re-add
the dev redirect URIs below.

## The dev-only values (client `thunderbird-accounts`, realm `tbpro`)

The reset reverts the whole client to its stage config, so ALL of these need re-applying:

- redirect URIs: `https://accounts.tb-dev.thunderbird.dev/oidc/callback/*` and
  `https://accounts.tb-dev.thunderbird.dev/login/`
- web origin: `https://accounts.tb-dev.thunderbird.dev`
- **`rootUrl` / `baseUrl` / `adminUrl`** — these back the Keycloak **"Back to Application"** link;
  if left at the stage value the button sends users to `accounts-stage.tb.pro`. Set
  `rootUrl=https://accounts.tb-dev.thunderbird.dev`, `baseUrl=/`, `adminUrl=https://accounts.tb-dev.thunderbird.dev`.

(Keep the stage redirect-URI/webOrigin entries that the reset restores — appending is fine.)

Only the `thunderbird-accounts` client matters for the accounts deployment. The other clients the
reset reverts to stage (`stalwart`, `docs`, `grist`, `thunderbird-appointment-*`, `thunderbird-send-backend`,
`thunderbird-stormbox`) are for services **not deployed on tb-dev** — leave them, EXCEPT `stalwart`
once tb-dev mail/webmail OIDC is wired (#146), which will then need its own tb-dev URLs.

## Procedure

### 1. Restart Keycloak (reconnect to the reset branch)

```bash
kubectl --context tb-dev rollout restart statefulset keycloak-customer -n keycloak-customer
kubectl --context tb-dev rollout status statefulset keycloak-customer -n keycloak-customer --timeout=150s
```

### 2. Re-add the redirect URIs via a temporary admin

The bootstrap-admin env creds do **not** work here — the branch is a stage clone whose master
`admin` already exists with stage's password. Create a throwaway admin with
`kc.sh bootstrap-admin`, overriding the cache/ports so it doesn't collide with the running
server (Alpine image; no `jq`), then update the client and delete the temp admin:

```bash
kubectl --context tb-dev exec -n keycloak-customer keycloak-customer-0 -c keycloak -- sh -c '
  PW=$(head -c 24 /dev/urandom | base64 | tr -d "=+/"); export PW
  env KC_CACHE=local KC_CACHE_STACK= KC_HTTP_MANAGEMENT_PORT=9990 KC_HTTP_PORT=8099 \
      JAVA_OPTS_APPEND="-Xms256m -Xmx512m" \
    /opt/keycloak/bin/kc.sh bootstrap-admin user --username tmp-admin --password:env PW
  /opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080 \
    --realm master --user tmp-admin --password "$PW"

  CID=$(/opt/keycloak/bin/kcadm.sh get clients -r tbpro -q clientId=thunderbird-accounts \
        --fields id --format csv --noquotes)

  /opt/keycloak/bin/kcadm.sh update clients/$CID -r tbpro \
    -s '"'"'redirectUris=["https://accounts-stage.tb.pro/login/","https://accounts-stage.tb.pro/oidc/callback/*","https://accounts.tb-dev.thunderbird.dev/oidc/callback/*","https://accounts.tb-dev.thunderbird.dev/login/"]'"'"' \
    -s '"'"'webOrigins=["accounts-stage.tb.pro","https://accounts.tb-dev.thunderbird.dev"]'"'"'

  /opt/keycloak/bin/kcadm.sh get clients/$CID -r tbpro --fields redirectUris,webOrigins   # verify

  AID=$(/opt/keycloak/bin/kcadm.sh get users -r master -q username=tmp-admin --fields id --format csv --noquotes)
  /opt/keycloak/bin/kcadm.sh delete users/$AID -r master     # remove the throwaway admin
  rm -f ~/.keycloak/kcadm.config
'
```

### 3. Verify

```bash
# Expect HTTP 200 (login page), not 400 "Invalid parameter: redirect_uri":
curl -s -o /dev/null -w '%{http_code}\n' \
  "https://auth.tb-dev.thunderbird.dev/realms/tbpro/protocol/openid-connect/auth?client_id=thunderbird-accounts&redirect_uri=https%3A%2F%2Faccounts.tb-dev.thunderbird.dev%2Foidc%2Fcallback%2F&response_type=code&scope=openid&state=probe"
```

Then confirm a browser login round-trip at `https://accounts.tb-dev.thunderbird.dev/`.

## Notes / follow-ups

- This is a **live, non-codified** realm edit — it does not survive a branch reset (that's the
  whole point of this doc) and is not in git. Codifying the `tbpro` realm's tb-dev client via
  keycloak-config-cli / a realm import (so a reset + re-import restores it automatically) is the
  durable fix; until then, follow this runbook after each reset.
- Prod (`auth.tb.pro`) uses the real domain and is out of scope here — do not add tb-dev URIs to
  a prod client.
