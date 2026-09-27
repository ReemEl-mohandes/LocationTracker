#!/usr/bin/env bash
# End-to-end verification against a running stack. Exercises auth, authorization,
# trip detection and the brute-force defences.
#
#   cd server && ./generate-certs.sh && docker compose up -d --build && ./smoke-test.sh
#
# -k throughout because the certificate is self-signed. Cookie jars stand in for a
# browser: the tokens are HttpOnly, so there is nothing to copy into a header.
set -uo pipefail

BASE="${BASE:-https://localhost}"
JAR_DIR="$(mktemp -d)"
USER_JAR="$JAR_DIR/user.txt"
ADMIN_JAR="$JAR_DIR/admin.txt"
LOCK_JAR="$JAR_DIR/lock.txt"

PASS=0
FAIL=0

# shellcheck disable=SC2046
if [[ -f .env ]]; then set -a; . ./.env; set +a; fi

STAMP=$(date +%s)
USER_EMAIL="smoke+${STAMP}@example.com"
USER_PASS='SmokeTest!Pass123'
LOCK_EMAIL="lock+${STAMP}@example.com"
LOCK_PASS='LockTest!Pass123'

ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# Asserts an HTTP status. Usage: expect <label> <expected> <actual>
expect() {
  if [[ "$2" == "$3" ]]; then ok "$1 ($3)"; else bad "$1 (expected $2, got $3)"; fi
}

# The rate limiters hold their windows in memory, so restarting the API clears them.
# The limits themselves are production values and are exercised on purpose in section 10;
# this exists only so earlier sections are not starved by the budget a later one spends.
reset_limits() {
  docker compose restart api >/dev/null 2>&1
  for _ in $(seq 1 30); do
    [[ "$(curl -sk -o /dev/null -w '%{http_code}' "$BASE/health")" == "200" ]] && return 0
    sleep 2
  done
  bad "API did not come back after restart"
}

# curl helper that replays the CSRF cookie as the header the double-submit check wants.
call() {
  local method="$1" path="$2" jar="$3" body="${4:-}"
  local csrf=""
  [[ -f "$jar" ]] && csrf=$(awk '$6=="csrf_token"{print $7}' "$jar" | tail -1)

  local args=(-sk -o "$JAR_DIR/body" -w '%{http_code}' -X "$method"
              -b "$jar" -c "$jar" -H 'Content-Type: application/json')
  [[ -n "$csrf" ]] && args+=(-H "X-CSRF-Token: $csrf")
  [[ -n "$body" ]] && args+=(-d "$body")

  curl "${args[@]}" "$BASE$path"
}

iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || python -c "import time,sys;print(time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime(int(sys.argv[1]))))" "$1"; }

point() {
  printf '{"latitude":%s,"longitude":%s,"accuracyMeters":%s,"recordedAtUtc":"%s"}' "$1" "$2" "$3" "$(iso "$4")"
}

head_ "1. TLS and health"
code=$(curl -sk -o /dev/null -w '%{http_code}' "$BASE/health")
expect "health endpoint reachable over TLS" "200" "$code"

redirect=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost/health")
expect "plain HTTP redirects to TLS" "301" "$redirect"

head_ "2. Registration and login"
code=$(call POST /api/auth/register "$USER_JAR" \
  "{\"email\":\"$USER_EMAIL\",\"password\":\"$USER_PASS\",\"displayName\":\"Smoke User\"}")
expect "register returns 201" "201" "$code"

weak=$(call POST /api/auth/register "$JAR_DIR/throwaway.txt" \
  '{"email":"weak@example.com","password":"short","displayName":"Weak"}')
expect "weak password rejected" "400" "$weak"

if grep -qi 'access_token' "$USER_JAR" && grep -qi 'refresh_token' "$USER_JAR"; then
  ok "access_token and refresh_token cookies were set"
else
  bad "auth cookies missing from jar"
fi

# Netscape cookie jars mark HttpOnly entries with a #HttpOnly_ prefix on the domain line.
if grep -q '#HttpOnly_.*access_token' "$USER_JAR"; then
  ok "access_token is HttpOnly"
else
  bad "access_token is NOT HttpOnly"
fi

code=$(call GET /api/auth/me "$USER_JAR")
expect "authenticated /me" "200" "$code"
USER_ID=$(python -c "import json,sys;print(json.load(open(sys.argv[1]))['id'])" "$JAR_DIR/body" 2>/dev/null || echo "")

code=$(curl -sk -o /dev/null -w '%{http_code}' "$BASE/api/auth/me")
expect "unauthenticated /me rejected" "401" "$code"

head_ "3. CSRF"
csrf=$(awk '$6=="csrf_token"{print $7}' "$USER_JAR" | tail -1)
code=$(curl -sk -o /dev/null -w '%{http_code}' -X POST -b "$USER_JAR" \
  -H 'Content-Type: application/json' -d '{"latitude":30.0,"longitude":31.0}' \
  "$BASE/api/locations")
expect "POST without X-CSRF-Token rejected" "403" "$code"

head_ "4. Trip detection"
# ~110 m per 0.001 degree of latitude. Twelve points, 30 s apart, is roughly 3.7 m/s
# over about 1.2 km: comfortably moving, comfortably past the 100 m minimum.
NOW=$(date +%s)
START=$((NOW - 3600))
lat=30.000000
for i in $(seq 0 11); do
  t=$((START + i*30))
  code=$(call POST /api/locations "$USER_JAR" "$(point "$lat" 31.000000 5 "$t")")
  [[ "$code" != "200" ]] && bad "location POST $i returned $code"
  lat=$(python -c "print(f'{$lat + 0.001:.6f}')")
done
ok "posted 12 moving points"

code=$(call GET /api/trips/me/active "$USER_JAR")
if [[ "$code" == "200" ]]; then
  ok "an active trip was opened"
  python - "$JAR_DIR/body" <<'PY'
import json,sys
t=json.load(open(sys.argv[1]))
d=t["distanceMeters"]
# Twelve points, eleven ~111 m segments.
lo,hi=1000,1400
print(f"        distance={d:.1f} m  points={t['pointCount']}  maxSpeed={t['maxSpeedMps']:.2f} m/s")
sys.exit(0 if lo<=d<=hi else 1)
PY
  [[ $? -eq 0 ]] && ok "distance within the expected band" || bad "distance outside the expected band"
else
  bad "no active trip after moving points (got $code)"
fi

head_ "5. Idle auto-close"
# Same coordinate, past the idle timeout: the trip should close and exclude the idle time.
IDLE_START=$((START + 11*30))
for i in 1 2 3; do
  t=$((IDLE_START + i*180))
  call POST /api/locations "$USER_JAR" "$(point "$lat" 31.000000 5 "$t")" >/dev/null
done

code=$(call GET /api/trips/me/active "$USER_JAR")
expect "active trip closed after idle timeout" "204" "$code"

code=$(call GET "/api/trips/me?page=1&pageSize=5" "$USER_JAR")
if [[ "$code" == "200" ]]; then
  python - "$JAR_DIR/body" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))
if not r["items"]: print("        no trips"); sys.exit(1)
t=r["items"][0]
print(f"        endReason={t['endReason']}  duration={t['duration']}  distance={t['distanceMeters']:.1f} m")
# 11 segments x 30 s = 330 s of travel. Idle points must not inflate this.
sys.exit(0 if t["endReason"]=="Idle" and t["durationSeconds"]<=400 else 1)
PY
  [[ $? -eq 0 ]] && ok "closed with reason Idle, idle time excluded from duration" \
                 || bad "close reason or duration wrong (idle time may be counted)"
else
  bad "trip list returned $code"
fi

reset_limits
head_ "6. GPS drift must not fabricate a trip"
DRIFT_EMAIL="drift+${STAMP}@example.com"
DRIFT_JAR="$JAR_DIR/drift.txt"
call POST /api/auth/register "$DRIFT_JAR" \
  "{\"email\":\"$DRIFT_EMAIL\",\"password\":\"$USER_PASS\",\"displayName\":\"Drift\"}" >/dev/null

# 40 points jittering within a few metres, with honest accuracy values. This is the
# test that matters: without the displacement and accuracy gates a parked phone
# accumulates kilometres overnight.
DRIFT_T=$((NOW - 7200))
for i in $(seq 0 39); do
  jlat=$(python -c "import math;print(f'{30.5 + 0.00003*math.sin($i):.6f}')")
  jlon=$(python -c "import math;print(f'{31.5 + 0.00003*math.cos($i):.6f}')")
  call POST /api/locations "$DRIFT_JAR" "$(point "$jlat" "$jlon" 12 "$((DRIFT_T + i*30))")" >/dev/null
done

code=$(call GET "/api/trips/me?page=1&pageSize=5" "$DRIFT_JAR")
python - "$JAR_DIR/body" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))
print(f"        trips created from pure drift: {r['totalCount']}")
sys.exit(0 if r["totalCount"]==0 else 1)
PY
[[ $? -eq 0 ]] && ok "stationary drift produced no trip" || bad "drift fabricated a trip"

reset_limits
head_ "7. Teleport rejection"
TELE_JAR="$JAR_DIR/tele.txt"
call POST /api/auth/register "$TELE_JAR" \
  "{\"email\":\"tele+${STAMP}@example.com\",\"password\":\"$USER_PASS\",\"displayName\":\"Tele\"}" >/dev/null
TT=$((NOW - 1800))
call POST /api/locations "$TELE_JAR" "$(point 30.000000 31.000000 5 "$TT")" >/dev/null
# 500 km in 10 s.
call POST /api/locations "$TELE_JAR" "$(point 34.500000 31.000000 5 "$((TT+10))")" >/dev/null
code=$(call GET /api/trips/me/active "$TELE_JAR")
expect "implausible jump did not open a trip" "204" "$code"

reset_limits
head_ "8. Authorization"
code=$(call GET /api/admin/users "$USER_JAR")
expect "regular user blocked from admin route" "403" "$code"

code=$(call POST /api/auth/login "$ADMIN_JAR" \
  "{\"email\":\"$SEED_ADMIN_EMAIL\",\"password\":\"$SEED_ADMIN_PASSWORD\"}")
expect "seeded admin can log in" "200" "$code"

code=$(call GET /api/admin/users "$ADMIN_JAR")
expect "admin can list users" "200" "$code"

if [[ -n "$USER_ID" ]]; then
  code=$(call GET "/api/admin/users/$USER_ID/trips" "$ADMIN_JAR")
  expect "admin can read another user's trips" "200" "$code"

  code=$(call GET "/api/admin/locations/latest" "$ADMIN_JAR")
  expect "admin live map endpoint" "200" "$code"
fi

reset_limits
head_ "9. Account lockout"
call POST /api/auth/register "$LOCK_JAR" \
  "{\"email\":\"$LOCK_EMAIL\",\"password\":\"$LOCK_PASS\",\"displayName\":\"Lock\"}" >/dev/null

declare -a bodies=()
for i in 1 2 3 4 5; do
  call POST /api/auth/login "$JAR_DIR/l$i.txt" \
    "{\"email\":\"$LOCK_EMAIL\",\"password\":\"WrongPassword!1\"}" >/dev/null
  bodies+=("$(cat "$JAR_DIR/body")")
done

# Five failures is exactly the per-IP login budget, so the check below would hit the
# limiter rather than the lockout. Clearing the in-memory window isolates the two
# layers: the lockout itself lives in AspNetUsers and survives a restart.
reset_limits

# The correct password after the threshold must still fail, or lockout is not applied.
code=$(call POST /api/auth/login "$JAR_DIR/l6.txt" \
  "{\"email\":\"$LOCK_EMAIL\",\"password\":\"$LOCK_PASS\"}")
expect "correct password refused while locked out" "401" "$code"
locked_body=$(cat "$JAR_DIR/body")

call POST /api/auth/login "$JAR_DIR/l7.txt" \
  "{\"email\":\"nobody+${STAMP}@example.com\",\"password\":\"WrongPassword!1\"}" >/dev/null
unknown_body=$(cat "$JAR_DIR/body")

if [[ "$locked_body" == "$unknown_body" && "$locked_body" == "${bodies[0]}" ]]; then
  ok "locked, wrong-password and unknown-account responses are identical (no enumeration oracle)"
else
  bad "failure responses differ; account state is observable"
  printf '        locked : %s\n        unknown: %s\n' "$locked_body" "$unknown_body"
fi

head_ "10. Rate limiting"
# The login policy allows 5 per minute per IP; section 9 spent two of them since the
# last reset, so this burst crosses the threshold well inside twelve attempts.
got429=0
for i in $(seq 1 12); do
  code=$(call POST /api/auth/login "$JAR_DIR/rl.txt" \
    '{"email":"ratelimit@example.com","password":"WrongPassword!1"}')
  [[ "$code" == "429" ]] && got429=1 && break
done
[[ $got429 -eq 1 ]] && ok "login rate limiter returned 429" || bad "rate limiter never triggered"

reset_limits
head_ "11. Refresh rotation and replay detection"
FRESH_JAR="$JAR_DIR/fresh.txt"
call POST /api/auth/register "$FRESH_JAR" \
  "{\"email\":\"fresh+${STAMP}@example.com\",\"password\":\"$USER_PASS\",\"displayName\":\"Fresh\"}" >/dev/null
OLD_REFRESH=$(awk '$6=="refresh_token"{print $7}' "$FRESH_JAR" | tail -1)

code=$(call POST /api/auth/refresh "$FRESH_JAR")
expect "refresh succeeds" "200" "$code"

NEW_REFRESH=$(awk '$6=="refresh_token"{print $7}' "$FRESH_JAR" | tail -1)
[[ "$OLD_REFRESH" != "$NEW_REFRESH" ]] && ok "refresh token rotated" || bad "refresh token was not rotated"

# Replaying the superseded token must fail and revoke the whole chain.
# The hand-built request still has to satisfy CSRF, or it is rejected at 403 before
# the replay logic is ever reached.
FRESH_CSRF=$(awk '$6=="csrf_token"{print $7}' "$FRESH_JAR" | tail -1)
code=$(curl -sk -o /dev/null -w '%{http_code}' -X POST \
  -H "Cookie: refresh_token=$OLD_REFRESH; csrf_token=$FRESH_CSRF" \
  -H "X-CSRF-Token: $FRESH_CSRF" \
  "$BASE/api/auth/refresh")
expect "replayed old refresh token rejected" "401" "$code"

code=$(call POST /api/auth/refresh "$FRESH_JAR")
expect "chain revoked after replay" "401" "$code"

reset_limits
head_ "12. Stale trip sweeper"
# The sweeper is load-bearing, not a nicety: trips are otherwise only ever closed by the
# arrival of a later point, so a client that dies mid-journey would leave one open forever
# and the one-open-trip index would then block every future trip for that user.
SWEEP_JAR="$JAR_DIR/sweep.txt"
call POST /api/auth/register "$SWEEP_JAR" \
  "{\"email\":\"sweep+${STAMP}@example.com\",\"password\":\"$USER_PASS\",\"displayName\":\"Sweep\"}" >/dev/null

# Backdated past the gap timeout, and then simply never followed up.
SW_T=$((NOW - 2400))
slat=25.000000
for i in $(seq 0 9); do
  call POST /api/locations "$SWEEP_JAR" "$(point "$slat" 32.000000 5 "$((SW_T + i*30))")" >/dev/null
  slat=$(python -c "print(f'{$slat + 0.001:.6f}')")
done

code=$(call GET /api/trips/me/active "$SWEEP_JAR")
expect "trip left open when the client goes silent" "200" "$code"

swept=0
for i in $(seq 1 24); do
  code=$(call GET /api/trips/me/active "$SWEEP_JAR")
  [[ "$code" == "204" ]] && swept=1 && break
  sleep 5
done
[[ $swept -eq 1 ]] && ok "sweeper closed the abandoned trip" || bad "sweeper never closed the abandoned trip"

code=$(call GET "/api/trips/me?page=1&pageSize=1" "$SWEEP_JAR")
python - "$JAR_DIR/body" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))
if not r["items"]: print("        no trips"); sys.exit(1)
t=r["items"][0]
print(f"        endReason={t['endReason']}  duration={t['duration']}  distance={t['distanceMeters']:.1f} m")
# Nine 30 s segments of travel; the silent stretch must not be counted.
sys.exit(0 if t["endReason"]=="Swept" and t["durationSeconds"]<=330 else 1)
PY
[[ $? -eq 0 ]] && ok "closed with reason Swept, silent stretch excluded from duration" \
               || bad "sweeper close reason or duration wrong"


printf '\n\033[1mResults: %d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
rm -rf "$JAR_DIR"
[[ $FAIL -eq 0 ]]
