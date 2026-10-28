#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'usage: %s [--dry-run]\n' "$0" >&2
  printf 'env: KC_LEGACY_PG_HOST KC_LEGACY_PG_USER KUBECONFIG_STAGE [KC_IMAGE_VERSION]\n' >&2
  exit 2
}

dry_run=0
case "${1:-}" in
  --dry-run) dry_run=1 ;;
  '') ;;
  *) usage ;;
esac

: "${KC_LEGACY_PG_HOST:?}" "${KC_LEGACY_PG_USER:?}" "${KUBECONFIG_STAGE:?}"

if ! declare -F pod >/dev/null; then
  pod() { kubectl --kubeconfig "$KUBECONFIG_STAGE" -n thundermail exec runner -c postgres -- "$@"; }
fi

image_version() {
  if [ -n "${KC_IMAGE_VERSION:-}" ]; then
    printf '%s\n' "$KC_IMAGE_VERSION"
    return
  fi
  local image
  image=$(kubectl --kubeconfig "$KUBECONFIG_STAGE" -n keycloak-customer get sts keycloak-customer \
    -o jsonpath='{.spec.template.spec.containers[?(@.name=="keycloak")].image}')
  podman run --rm --entrypoint /opt/keycloak/bin/kc.sh "$image" --version | awk '$1 == "Keycloak" { print $2 }'
}

query='select version from migration_model order by update_time desc limit 1'

if [ "$dry_run" = 1 ]; then
  printf 'dry-run: pod psql -h %s -U <%d chars> -d keycloak -Atc "%s"\n' "$KC_LEGACY_PG_HOST" "${#KC_LEGACY_PG_USER}" "$query"
  printf 'dry-run: image version from KC_IMAGE_VERSION or kc.sh --version on the keycloak-customer image\n'
  exit 0
fi

expected=$(image_version)
actual=$(pod psql -h "$KC_LEGACY_PG_HOST" -U "$KC_LEGACY_PG_USER" -d keycloak -Atc "$query")
printf 'migration_model=%s image=%s\n' "$actual" "$expected"

if [ -z "$actual" ] || [ "$actual" != "$expected" ]; then
  printf 'GATE FAIL: migration_model on main differs from the image version; stop\n' >&2
  exit 1
fi
printf 'GATE OK\n'
