#!/bin/bash
#
# tb-dev OVERRIDE of the image's baked /scripts/apply-mfa-config.sh, delivered via a
# ConfigMap subPath mount (see the overlay statefulset volumeMounts). It is a copy of
# the baked script with ONE functional change: the config-cli invocation is wrapped in
# a retry loop.
#
# Why: on a rolling restart both pods bounce, and a config-cli realm update can time out
# waiting for the Infinispan cluster to replicate (ISPN000476, "Timed out waiting for
# responses ... after 15 seconds") while the peer is still rejoining -> HTTP 500 and a
# failed (but non-fatal) reconcile. Retrying after a short backoff lets the cluster settle
# and the reconcile succeed within the same pod start.
#
# KEEP IN SYNC with the image's /scripts/apply-mfa-config.sh; the only intended difference
# is the retry loop. Reconcile of the MFA step-up flow itself is unchanged.

set -uo pipefail

CONFIG_FILE='/opt/keycloak/config-cli/tbpro-mfa-stepup.yaml'
CONFIG_CLI_JAR='/opt/keycloak/keycloak-config-cli.jar'
HEALTH_PORT="${KC_HTTP_MANAGEMENT_PORT:-9000}"
HTTP_PORT="${KC_HTTP_PORT:-8080}"
# Retry knobs (shared convention with apply-client-config.sh).
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
    echo 'apply-mfa-config: Keycloak did not become ready in time; skipping MFA flow reconcile.'
    exit 0
fi

if [[ -z "${KEYCLOAK_ADMIN_CLIENT_SECRET:-}" ]]; then
    echo 'apply-mfa-config: KEYCLOAK_ADMIN_CLIENT_SECRET unset; skipping MFA flow reconcile.'
    exit 0
fi

# config-cli authenticates as the same admin service-account client the accounts app uses.
# Override KEYCLOAK_URL via KC_CONFIG_CLI_URL if hostname-strict ever rejects localhost.
export KEYCLOAK_URL="${KC_CONFIG_CLI_URL:-http://localhost:${HTTP_PORT}}"
export KEYCLOAK_REALM=master
export KEYCLOAK_GRANTTYPE=client_credentials
export KEYCLOAK_CLIENTID="${KEYCLOAK_ADMIN_CLIENT_ID:-tb-accounts-admin}"
export KEYCLOAK_CLIENTSECRET="${KEYCLOAK_ADMIN_CLIENT_SECRET}"
export IMPORT_FILES_LOCATIONS="${CONFIG_FILE}"
export IMPORT_VARSUBSTITUTION_ENABLED=true
# Only ever add/overwrite the managed step-up flow; never delete other (built-in) flows.
export IMPORT_MANAGED_AUTHENTICATIONFLOW=no-delete
# Reconcile on every start (config-cli otherwise checksums the file and skips, so manual
# drift would never be repaired). The reconcile is idempotent.
export IMPORT_CACHE_ENABLED=false
# Level-1 LoA window; must match the realm's ssoSessionMaxLifespan (see the config file).
export MFA_L1_LOA_MAX_AGE="${MFA_L1_LOA_MAX_AGE:-36000}"

# Retry on non-zero exit (transient cluster-replication timeout during rolling restart).
n=1
until java -jar "${CONFIG_CLI_JAR}"; do
    if [ "$n" -ge "$ATTEMPTS" ]; then
        echo "apply-mfa-config: keycloak-config-cli failed after ${n} attempts (non-fatal)."
        break
    fi
    echo "apply-mfa-config: keycloak-config-cli attempt ${n} failed (likely transient cluster timeout during rolling restart); retrying in ${BACKOFF}s."
    n=$((n + 1))
    sleep "$BACKOFF"
done
