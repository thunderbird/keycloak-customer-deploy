#!/bin/bash
#
# tb-dev: assert the master (admin) realm's OIDC front-channel is on the PRIVATE tailnet
# admin host, so the tailnet-served admin console authenticates SAME-ORIGIN and never
# hits the public `/realms/master` 403 deny.
#
# BACKGROUND — this replaces an earlier write-based approach that was BOTH ineffective
# AND unnecessary:
#   * Ineffective: it tried to set a per-realm `frontendUrl` on master, but in KC 26.5
#     the master realm's `attributes` map is NOT writable via the Admin API (kcadm and
#     keycloak-config-cli both no-op; the master `frontendUrl` workaround in KC #32458
#     is a direct DB insert). Verified live: `attributes` stayed `{}` after the write.
#   * Unnecessary: in KC 26.5 hostname v2, the admin/master realm's front-channel URLs
#     (issuer, authorization endpoint, login-status / check_session iframe) are ALREADY
#     generated from KC_HOSTNAME_ADMIN. Verified live: master's `.well-known` issuer is
#     the tailnet host regardless of the request Host header.
#
# So there is nothing to set. Instead we make the invariant EXPLICIT and CHECKED: read
# master's public OIDC discovery and confirm its issuer is on KC_HOSTNAME_ADMIN. If a
# future KC upgrade regresses master's front-channel onto the public KC_HOSTNAME, this
# logs a loud WARNING in the pod log (the admin console would then break on the public
# deny) so we catch it at deploy time. Read-only; needs no admin credentials; fail-soft
# (never blocks Keycloak startup).

set -uo pipefail

HEALTH_PORT="${KC_HTTP_MANAGEMENT_PORT:-9000}"
HTTP_PORT="${KC_HTTP_PORT:-8080}"
ADMIN_HOST="${KC_HOSTNAME_ADMIN:-}"

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
    echo 'assert-master-frontend-host: Keycloak did not become ready in time; skipping check.'
    exit 0
fi

if [[ -z "${ADMIN_HOST}" ]]; then
    echo 'assert-master-frontend-host: KC_HOSTNAME_ADMIN unset; skipping check.'
    exit 0
fi

# Fetch master's OIDC discovery over a raw TCP socket and extract the issuer.
issuer=""
if exec 3<>"/dev/tcp/localhost/${HTTP_PORT}" 2>/dev/null; then
    printf 'GET /realms/master/.well-known/openid-configuration HTTP/1.0\r\nHost: localhost\r\nConnection: close\r\n\r\n' >&3
    issuer="$(cat <&3 | tr ',' '\n' | sed -n 's/.*"issuer":"\([^"]*\)".*/\1/p' | head -1)"
    exec 3>&- 3<&-
fi

if [[ -z "${issuer}" ]]; then
    echo 'assert-master-frontend-host: could not read master issuer from OIDC discovery; skipping check.'
    exit 0
fi

# The issuer should be "<KC_HOSTNAME_ADMIN>/realms/master" (KC_HOSTNAME_ADMIN carries no
# trailing slash), i.e. on the tailnet admin host.
case "${issuer}" in
    "${ADMIN_HOST}"/*|"${ADMIN_HOST}")
        echo "assert-master-frontend-host: OK — master issuer ${issuer} is on the admin host ${ADMIN_HOST}."
        ;;
    *)
        echo "assert-master-frontend-host: WARNING — master issuer is ${issuer}, NOT the tailnet admin host ${ADMIN_HOST}. The admin console login/session iframe will hit the public /realms/master 403 deny. Investigate KC hostname-v2 behavior (KC_HOSTNAME_ADMIN / per-realm frontendUrl; see KC #32458)."
        ;;
esac
exit 0
