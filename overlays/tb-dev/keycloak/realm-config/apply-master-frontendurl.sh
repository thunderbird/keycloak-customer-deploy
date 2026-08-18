#!/bin/bash
#
# tb-dev: rebind the `master` realm's front-channel to the PRIVATE tailnet admin host.
#
# Problem (KC 26 hostname v2): the admin console's REST calls use KC_HOSTNAME_ADMIN
# (the tailnet host), but the master realm's OIDC *front-channel* URLs — issuer,
# authorization endpoint, and the login-status / check_session / 3p-cookies iframe
# resources the console loads — are built from the master realm's frontend URL, which
# by default resolves to the global KC_HOSTNAME (the PUBLIC host). So a console loaded
# over the tailnet still fires its master login + session-iframe requests at
# auth.tb-dev.thunderbird.dev/realms/master/..., which the public ALB deliberately
# 403-denies -> the admin console login/session breaks.
#
# Fix: set a per-realm `frontendUrl` on the master realm to the private admin host.
# In hostname v2 the realm-level frontend URL takes precedence over KC_HOSTNAME for
# that realm, so master's issuer + all front-channel URLs are rebuilt from the tailnet
# host and the console authenticates SAME-ORIGIN, never touching the public deny. The
# public `tbpro` realm is unaffected (it keeps the public KC_HOSTNAME). This is a
# documented Keycloak pattern (server/hostname guide; KC issues #32458 / #42254).
#
# We use a surgical `kcadm update` (not keycloak-config-cli) so we touch ONLY master's
# frontendUrl attribute and never reconcile the rest of the cloned-from-stage master
# realm. The value is derived from KC_HOSTNAME_ADMIN so the admin host has a single
# source of truth per env. Idempotent; fail-soft (never blocks Keycloak startup).

set -uo pipefail

KCADM=/opt/keycloak/bin/kcadm.sh
HEALTH_PORT="${KC_HTTP_MANAGEMENT_PORT:-9000}"
HTTP_PORT="${KC_HTTP_PORT:-8080}"
# The private admin host; also what the admin console is served on (tailnet Ingress).
FRONTEND_URL="${KC_HOSTNAME_ADMIN:-}"
# Retry knobs (shared convention with apply-client-config.sh / apply-mfa-config.sh).
ATTEMPTS="${RECONCILE_ATTEMPTS:-3}"
BACKOFF="${RECONCILE_BACKOFF:-25}"

# Poll /health/ready over a raw bash TCP socket — the Keycloak image ships no curl/wget.
kc_ready() {
    exec 3<>"/dev/tcp/localhost/${HEALTH_PORT}" 2>/dev/null || return 1
    printf 'GET /health/ready HTTP/1.0\r\nHost: localhost\r\nConnection: close\r\n\r\n' >&3
    local status_line
    IFS= read -r status_line <&3
    exec 3>&- 3<&-
    [[ "$status_line" == *" 200 "* ]]
}

for _ in $(seq 1 90); do
    kc_ready && break
    sleep 2
done
if ! kc_ready; then
    echo 'apply-master-frontendurl: Keycloak did not become ready in time; skipping master frontendUrl reconcile.'
    exit 0
fi

if [[ -z "${KEYCLOAK_ADMIN_CLIENT_SECRET:-}" ]]; then
    echo 'apply-master-frontendurl: KEYCLOAK_ADMIN_CLIENT_SECRET unset; skipping master frontendUrl reconcile.'
    exit 0
fi
if [[ -z "${FRONTEND_URL}" ]]; then
    echo 'apply-master-frontendurl: KC_HOSTNAME_ADMIN unset; skipping master frontendUrl reconcile.'
    exit 0
fi

# Authenticate as the master-realm tb-accounts-admin service account (client_credentials),
# then merge the single attribute onto the master realm (kcadm GET-merges, preserving
# other attributes). Both steps must succeed for the attempt to count as done.
#
# The client secret is passed via the KC_CLI_CLIENT_SECRET env var (which kcadm reads
# when --secret is omitted), NOT as a --secret CLI arg, so it never lands in the process
# arg list / `ps` output. stderr is left un-redirected so an auth failure (bad perms,
# server error) surfaces in the pod log instead of being swallowed.
do_apply() {
    KC_CLI_CLIENT_SECRET="${KEYCLOAK_ADMIN_CLIENT_SECRET}" "${KCADM}" config credentials \
        --server "http://localhost:${HTTP_PORT}" \
        --realm master \
        --client "${KEYCLOAK_ADMIN_CLIENT_ID:-tb-accounts-admin}" >/dev/null || return 1
    "${KCADM}" update realms/master -s "attributes.frontendUrl=${FRONTEND_URL}" || return 1
}

n=1
until do_apply; do
    if [ "$n" -ge "$ATTEMPTS" ]; then
        echo "apply-master-frontendurl: kcadm failed after ${n} attempts (non-fatal)."
        exit 0
    fi
    echo "apply-master-frontendurl: kcadm attempt ${n} failed (likely transient cluster timeout during rolling restart); retrying in ${BACKOFF}s."
    n=$((n + 1))
    sleep "$BACKOFF"
done

echo "apply-master-frontendurl: master realm frontendUrl set to ${FRONTEND_URL}."
