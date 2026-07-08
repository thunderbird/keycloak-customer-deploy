#!/bin/bash
#
# Reconcile the tbpro `thunderbird-accounts` OIDC client with keycloak-config-cli.
#
# tb-dev delivers this script and its import file (tbpro-accounts-client.yaml) via
# ConfigMap mounts (NOT baked into the image), so the env-specific client config
# survives a Neon branch reset without a manual kcadm re-add. Modeled on the
# image's /scripts/apply-mfa-config.sh: runs in the background from the overlay
# `command:` on every start, waits for the server to report ready, then applies
# the client config declaratively. Fail-soft -- it never blocks Keycloak from
# serving (a failed reconcile just logs and exits 0).
#
# Auth: the same tb-accounts-admin master-realm service account the MFA reconcile
# uses (client_credentials). Its secret lives in the cloned stage master realm, so
# it keeps matching after a branch reset.

set -uo pipefail

CONFIG_FILE='/config/tbpro-accounts-client.yaml'
CONFIG_CLI_JAR='/opt/keycloak/keycloak-config-cli.jar'
# Management interface (health/metrics) -- enabled via KC_HEALTH_ENABLED=true.
HEALTH_PORT="${KC_HTTP_MANAGEMENT_PORT:-9000}"
# Keycloak's HTTP listener (8080 in deploy).
HTTP_PORT="${KC_HTTP_PORT:-8080}"

# Poll /health/ready over a raw bash TCP socket -- the image ships no curl/wget.
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
    echo 'apply-client-config: Keycloak did not become ready in time; skipping client reconcile.'
    exit 0
fi

if [[ -z "${KEYCLOAK_ADMIN_CLIENT_SECRET:-}" ]]; then
    echo 'apply-client-config: KEYCLOAK_ADMIN_CLIENT_SECRET unset; skipping client reconcile.'
    exit 0
fi

# config-cli authenticates as the same admin service-account client the accounts
# app + MFA reconcile use. Override KEYCLOAK_URL via KC_CONFIG_CLI_URL if
# hostname-strict ever rejects localhost.
export KEYCLOAK_URL="${KC_CONFIG_CLI_URL:-http://localhost:${HTTP_PORT}}"
export KEYCLOAK_REALM=master
export KEYCLOAK_GRANTTYPE=client_credentials
export KEYCLOAK_CLIENTID="${KEYCLOAK_ADMIN_CLIENT_ID:-tb-accounts-admin}"
export KEYCLOAK_CLIENTSECRET="${KEYCLOAK_ADMIN_CLIENT_SECRET}"
export IMPORT_FILES_LOCATIONS="${CONFIG_FILE}"
export IMPORT_VARSUBSTITUTION_ENABLED=false
# Reconcile on every start (config-cli otherwise checksums the file and skips, so
# drift from a reset would never be repaired). The import is idempotent.
export IMPORT_CACHE_ENABLED=false
# Only ever add/update the listed client; NEVER delete other (real) tbpro clients.
export IMPORT_MANAGED_CLIENT=no-delete

# Retry on non-zero exit: a config-cli realm update can transiently time out on
# Infinispan cluster replication during a rolling restart (ISPN000476, HTTP 500)
# while the peer pod is still rejoining. A short backoff lets the cluster settle.
ATTEMPTS="${RECONCILE_ATTEMPTS:-3}"
BACKOFF="${RECONCILE_BACKOFF:-25}"
n=1
until java -jar "${CONFIG_CLI_JAR}"; do
    if [ "$n" -ge "$ATTEMPTS" ]; then
        echo "apply-client-config: keycloak-config-cli failed after ${n} attempts (non-fatal)."
        break
    fi
    echo "apply-client-config: keycloak-config-cli attempt ${n} failed (likely transient cluster timeout during rolling restart); retrying in ${BACKOFF}s."
    n=$((n + 1))
    sleep "$BACKOFF"
done
