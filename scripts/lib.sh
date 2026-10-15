# Shared helpers for the admin API scripts. Source it; needs bash, curl, jq, openssl.
#
#   ADMIN_URL     the gateway admin API (default http://localhost:8080)
#   KAWA_TOKEN    an access token; fetched with token.sh when unset

ADMIN_URL="${ADMIN_URL:-http://localhost:8080}"
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Waits until the admin API answers (GET /docs is public).
wait_for_admin() {
    local tries=0
    until curl -fsS -o /dev/null "$ADMIN_URL/docs" 2>/dev/null; do
        tries=$((tries + 1))
        [ "$tries" -lt 90 ] || { echo "admin API at $ADMIN_URL did not come up" >&2; return 1; }
        [ "$tries" -eq 1 ] && echo "waiting for the admin API at $ADMIN_URL ..."
        sleep 2
    done
}

ensure_token() {
    if [ -z "${KAWA_TOKEN:-}" ]; then
        KAWA_TOKEN=$("$SCRIPTS_DIR/token.sh")
        export KAWA_TOKEN
    fi
}

# api METHOD PATH  (JSON body on stdin for PUT/POST). Fails on an HTTP error, printing the body.
api() {
    local method="$1" path="$2" out status
    out=$(mktemp)
    local body=()
    if [ "$method" = PUT ] || [ "$method" = POST ]; then body=(--data-binary @-); fi
    status=$(curl -sS -o "$out" -w '%{http_code}' -X "$method" \
        -H "Authorization: Bearer $KAWA_TOKEN" -H 'Content-Type: application/json' \
        ${body[@]+"${body[@]}"} "$ADMIN_URL$path")
    printf '%-6s %-44s %s\n' "$method" "$path" "$status"
    if [ "$status" -ge 400 ]; then cat "$out" >&2; echo >&2; rm -f "$out"; return 1; fi
    rm -f "$out"
}
