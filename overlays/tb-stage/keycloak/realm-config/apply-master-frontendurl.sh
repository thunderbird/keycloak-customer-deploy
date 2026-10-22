#!/bin/bash
# Points the master realm front channel at the tailnet admin host (KC_HOSTNAME_ADMIN).

set -uo pipefail

KCADM=/opt/keycloak/bin/kcadm.sh
HEALTH_PORT="${KC_HTTP_MANAGEMENT_PORT:-9000}"
HTTP_PORT="${KC_HTTP_PORT:-8080}"
FRONTEND_URL="${KC_HOSTNAME_ADMIN:-}"
ATTEMPTS="${RECONCILE_ATTEMPTS:-3}"
BACKOFF="${RECONCILE_BACKOFF:-25}"

kc_ready() {
    exec 3<>"/dev/tcp/localhost/${HEALTH_PORT}" || return 1
    printf 'GET /health/ready HTTP/1.0\r\nHost: localhost\r\nConnection: close\r\n\r\n' >&3
    local status_line
    IFS= read -r status_line <&3
    exec 3>&- 3<&-
    [[ "$status_line" == *" 200 "* ]]
} 2>/dev/null

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
