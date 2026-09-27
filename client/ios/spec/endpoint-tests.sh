#!/usr/bin/env bash
# Endpoint contract tests for the iOS client.
#
# Exercises every HTTP endpoint LocationTrackerClient calls, the same way the app calls it:
#   * login/register capture the three Set-Cookie tokens (access/refresh/csrf)
#   * normal calls send Authorization: Bearer <access>   (APIClient .bearer mode)
#   * refresh/logout send the refresh+csrf cookies AND the X-CSRF-Token header (.sessionCookies)
# Then asserts status codes and key response fields.
#
# Usage:
#   BASE=https://34.199.20.93 ./endpoint-tests.sh      # default: the EC2 server
#   BASE=https://localhost     ./endpoint-tests.sh      # local docker stack
#
# -k throughout because the server uses a self-signed, pinned certificate. A throwaway account
# with a random password is created; no real credentials are used or printed.
set -uo pipefail

BASE="${BASE:-https://34.199.20.93}"
JAR="$(mktemp)"
STAMP="$(date +%s)-$RANDOM"
EMAIL="endpoint-test+${STAMP}@example.com"
PASS_WORD="EpT-$(head -c 8 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')-9x!"   # meets policy; never printed
NAME="Endpoint Test"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# Extract a Set-Cookie value from the cookie jar written by curl -c.
cookie() { awk -v n="$1" '$6==n {print $7}' "$JAR" | tail -1; }

echo "Target: $BASE"
echo "Throwaway account: $EMAIL"

# ---------------------------------------------------------------------------
head_ "1. Health (GET /health) — anonymous"
code=$(curl -sk -o /dev/null -w '%{http_code}' "$BASE/health")
[ "$code" = 200 ] && ok "health 200" || bad "health expected 200, got $code"

# ---------------------------------------------------------------------------
head_ "2. Register (POST /api/auth/register)"
body=$(curl -sk -c "$JAR" -o /tmp/ept_reg.json -w '%{http_code}' \
  -H 'Content-Type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PASS_WORD\",\"displayName\":\"$NAME\"}" \
  "$BASE/api/auth/register")
[ "$body" = 201 ] && ok "register 201" || bad "register expected 201, got $body"
grep -q '"roles"' /tmp/ept_reg.json && ok "register returned a profile with roles" || bad "no roles in register response"
[ -n "$(cookie access_token)" ] && ok "access_token cookie set" || bad "access_token cookie missing"
[ -n "$(cookie refresh_token)" ] && ok "refresh_token cookie set" || bad "refresh_token cookie missing"
[ -n "$(cookie csrf_token)" ] && ok "csrf_token cookie set" || bad "csrf_token cookie missing"

# ---------------------------------------------------------------------------
head_ "3. Login (POST /api/auth/login) — refresh the token set"
code=$(curl -sk -c "$JAR" -o /tmp/ept_login.json -w '%{http_code}' \
  -H 'Content-Type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PASS_WORD\"}" \
  "$BASE/api/auth/login")
[ "$code" = 200 ] && ok "login 200" || bad "login expected 200, got $code"

ACCESS="$(cookie access_token)"; REFRESH="$(cookie refresh_token)"; CSRF="$(cookie csrf_token)"
AUTH=(-H "Authorization: Bearer $ACCESS")

# ---------------------------------------------------------------------------
head_ "4. Login with wrong password — expect 401"
code=$(curl -sk -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"password\":\"definitely-wrong-1A!\"}" "$BASE/api/auth/login")
[ "$code" = 401 ] && ok "wrong password 401" || bad "wrong password expected 401, got $code"

# ---------------------------------------------------------------------------
head_ "5. Me (GET /api/auth/me) — bearer"
code=$(curl -sk -o /tmp/ept_me.json -w '%{http_code}' "${AUTH[@]}" "$BASE/api/auth/me")
[ "$code" = 200 ] && ok "me 200" || bad "me expected 200, got $code"
grep -q "$EMAIL" /tmp/ept_me.json && ok "me returns this account" || bad "me did not return this account"

head_ "6. Me without token — expect 401"
code=$(curl -sk -o /dev/null -w '%{http_code}' "$BASE/api/auth/me")
[ "$code" = 401 ] && ok "unauthenticated me 401" || bad "unauthenticated me expected 401, got $code"

# ---------------------------------------------------------------------------
head_ "7. Batch upload (POST /api/locations/batch) — bearer, a moving track"
NOW=$(date -u +%s)
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%S.000Z; }
points=""
lat=30.100000
for i in $(seq 0 11); do
  t=$(iso $((NOW - 3600 + i*30)))
  points="$points{\"latitude\":$lat,\"longitude\":31.200000,\"accuracyMeters\":6,\"speed\":8.0,\"recordedAtUtc\":\"$t\"},"
  lat=$(awk "BEGIN{printf \"%.6f\", $lat + 0.0012}")
done
points="[${points%,}]"
code=$(curl -sk -o /tmp/ept_batch.json -w '%{http_code}' "${AUTH[@]}" -H 'Content-Type: application/json' \
  -d "{\"points\":$points}" "$BASE/api/locations/batch")
[ "$code" = 200 ] && ok "batch 200" || bad "batch expected 200, got $code"
grep -q '"accepted":12' /tmp/ept_batch.json && ok "batch accepted all 12 points" || bad "batch accepted count unexpected: $(cat /tmp/ept_batch.json)"

head_ "8. Batch without token — expect 401"
code=$(curl -sk -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
  -d "{\"points\":$points}" "$BASE/api/locations/batch")
[ "$code" = 401 ] && ok "unauthenticated batch 401" || bad "unauthenticated batch expected 401, got $code"

# ---------------------------------------------------------------------------
head_ "9. Trips list (GET /api/trips/me)"
code=$(curl -sk -o /tmp/ept_trips.json -w '%{http_code}' "${AUTH[@]}" "$BASE/api/trips/me?pageSize=20")
[ "$code" = 200 ] && ok "trips 200" || bad "trips expected 200, got $code"
grep -q '"items"' /tmp/ept_trips.json && ok "trips returns a paged result" || bad "trips response shape unexpected"

head_ "10. Active trip (GET /api/trips/me/active) — 200 with a trip or 204 when idle"
code=$(curl -sk -o /tmp/ept_active.json -w '%{http_code}' "${AUTH[@]}" "$BASE/api/trips/me/active")
{ [ "$code" = 200 ] || [ "$code" = 204 ]; } && ok "active trip $code" || bad "active trip expected 200/204, got $code"

head_ "11. Trip detail (GET /api/trips/me/{id})"
TID=$(grep -o '"id":[0-9]*' /tmp/ept_trips.json | head -1 | cut -d: -f2)
if [ -n "${TID:-}" ]; then
  code=$(curl -sk -o /tmp/ept_detail.json -w '%{http_code}' "${AUTH[@]}" "$BASE/api/trips/me/$TID")
  [ "$code" = 200 ] && ok "trip detail 200 (trip #$TID)" || bad "trip detail expected 200, got $code"
  grep -q '"path"' /tmp/ept_detail.json && ok "trip detail includes a smoothed path" || bad "trip detail missing path"
  code=$(curl -sk -o /dev/null -w '%{http_code}' "${AUTH[@]}" "$BASE/api/trips/me/999999999")
  [ "$code" = 404 ] && ok "unknown trip 404" || bad "unknown trip expected 404, got $code"
else
  echo "  (no trip formed from the sample track; skipping detail — not a failure)"
fi

# ---------------------------------------------------------------------------
head_ "12. Refresh (POST /api/auth/refresh) — cookie + CSRF header, token rotation"
code=$(curl -sk -c "$JAR" -o /dev/null -w '%{http_code}' -X POST \
  -H "Cookie: refresh_token=$REFRESH; csrf_token=$CSRF" -H "X-CSRF-Token: $CSRF" \
  "$BASE/api/auth/refresh")
[ "$code" = 200 ] && ok "refresh 200" || bad "refresh expected 200, got $code"
NEW_REFRESH="$(cookie refresh_token)"
[ -n "$NEW_REFRESH" ] && [ "$NEW_REFRESH" != "$REFRESH" ] && ok "refresh token rotated" || bad "refresh token did not rotate"

head_ "13. Replay the old refresh token — expect 401 (replay detection)"
code=$(curl -sk -o /dev/null -w '%{http_code}' -X POST \
  -H "Cookie: refresh_token=$REFRESH; csrf_token=$CSRF" -H "X-CSRF-Token: $CSRF" \
  "$BASE/api/auth/refresh")
[ "$code" = 401 ] && ok "replayed refresh 401" || bad "replayed refresh expected 401, got $code"

# The replay revoked the chain; get a clean session for the logout check.
curl -sk -c "$JAR" -o /dev/null -H 'Content-Type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PASS_WORD\"}" "$BASE/api/auth/login"
ACCESS="$(cookie access_token)"; REFRESH="$(cookie refresh_token)"; CSRF="$(cookie csrf_token)"

# ---------------------------------------------------------------------------
head_ "14. Logout (POST /api/auth/logout) — bearer + cookie + CSRF"
code=$(curl -sk -o /dev/null -w '%{http_code}' -X POST \
  -H "Authorization: Bearer $ACCESS" \
  -H "Cookie: refresh_token=$REFRESH; csrf_token=$CSRF" -H "X-CSRF-Token: $CSRF" \
  "$BASE/api/auth/logout")
{ [ "$code" = 200 ] || [ "$code" = 204 ]; } && ok "logout $code" || bad "logout expected 200/204, got $code"

head_ "15. Refresh after logout — expect 401"
code=$(curl -sk -o /dev/null -w '%{http_code}' -X POST \
  -H "Cookie: refresh_token=$REFRESH; csrf_token=$CSRF" -H "X-CSRF-Token: $CSRF" \
  "$BASE/api/auth/refresh")
[ "$code" = 401 ] && ok "refresh after logout 401" || bad "refresh after logout expected 401, got $code"

# ---------------------------------------------------------------------------
rm -f "$JAR" /tmp/ept_*.json
printf '\n\033[1mResults: %d passed, %d failed\033[0m\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
