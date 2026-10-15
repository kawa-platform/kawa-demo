#!/usr/bin/env bash
# Prints an admin API access token for the bootstrap admin user, without a browser.
#
# kawa issues admin tokens through the OAuth authorization code flow with PKCE, with kawa studio
# hosting the login page. This script plays the part of studio: it starts the flow, posts the
# credentials to the login endpoint and redeems the code, exactly as the browser would.
#
#   TOKEN=$(scripts/token.sh)
#   ADMIN_URL=http://gateway:8080 STUDIO_URL=http://localhost:5173 scripts/token.sh
#
# STUDIO_URL is only used to build the redirect URI registered on the gateway
# (<STUDIO_URL>/admin/auth/callback); nothing is requested from it. Tokens last 15 minutes.
# Needs: bash, curl, jq, openssl.
set -euo pipefail

ADMIN_URL="${ADMIN_URL:-http://localhost:8080}"
STUDIO_URL="${STUDIO_URL:-http://localhost:5173}"
KAWA_ADMIN_USER="${KAWA_ADMIN_USER:-admin@kawa}"
KAWA_ADMIN_PASSWORD="${KAWA_ADMIN_PASSWORD:-admin}"
KAWA_CLIENT_ID="${KAWA_CLIENT_ID:-kawa-studio}"
REDIRECT_URI="${STUDIO_URL%/}/admin/auth/callback"

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
urlencode() { jq -rn --arg v "$1" '$v | @uri'; }
urldecode() { local v="${1//+/ }"; printf '%b' "${v//%/\\x}"; }
# The value of query parameter $2 in URL $1, decoded.
param() { urldecode "$(printf '%s' "$1" | sed -n "s/.*[?&]$2=\([^&#]*\).*/\1/p")"; }
fail() { echo "token.sh: $*" >&2; exit 1; }

verifier=$(openssl rand 48 | b64url)
challenge=$(printf '%s' "$verifier" | openssl dgst -sha256 -binary | b64url)
state=$(openssl rand 12 | b64url)

# 1. Authorization request: kawa answers with a redirect to studio's login page.
location=$(curl -sS -o /dev/null -w '%{redirect_url}' \
    "$ADMIN_URL/oauth/authorize?response_type=code&client_id=$(urlencode "$KAWA_CLIENT_ID")&redirect_uri=$(urlencode "$REDIRECT_URI")&code_challenge=$challenge&code_challenge_method=S256&state=$state") \
    || fail "cannot reach $ADMIN_URL"
[ -n "$location" ] || fail "no redirect from /oauth/authorize (is admin.auth.type oauth, and $REDIRECT_URI a registered redirect URI?)"
login_challenge=$(param "$location" login_challenge)
[ -n "$login_challenge" ] || fail "authorization failed: $location"

# 2. Login, as studio's login page does.
login=$(curl -sS -X POST "$ADMIN_URL/oauth/login" -H 'Content-Type: application/json' \
    -d "$(jq -n --arg c "$login_challenge" --arg u "$KAWA_ADMIN_USER" --arg p "$KAWA_ADMIN_PASSWORD" \
        '{login_challenge: $c, username: $u, password: $p}')")
redirect_to=$(printf '%s' "$login" | jq -r '.redirect_to // empty')
[ -n "$redirect_to" ] || fail "login failed: $login"
[ "$(param "$redirect_to" state)" = "$state" ] || fail "state mismatch in $redirect_to"
code=$(param "$redirect_to" code)

# 3. Redeem the code.
tokens=$(curl -sS -X POST "$ADMIN_URL/oauth/token" \
    --data-urlencode grant_type=authorization_code \
    --data-urlencode "code=$code" \
    --data-urlencode "redirect_uri=$REDIRECT_URI" \
    --data-urlencode "client_id=$KAWA_CLIENT_ID" \
    --data-urlencode "code_verifier=$verifier")
access_token=$(printf '%s' "$tokens" | jq -r '.access_token // empty')
[ -n "$access_token" ] || fail "token request failed: $tokens"
printf '%s\n' "$access_token"
