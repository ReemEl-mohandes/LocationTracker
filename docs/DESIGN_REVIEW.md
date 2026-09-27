# Design Review — Location Tracker

**Scope:** the whole system as it stands on 27 Sep 2026: iOS client (`client/ios`), admin web
page (`client/wwwroot`), ASP.NET Core server (`server/`), and the AWS EC2 deployment. Includes the
uncommitted `client/` + `server/` reorganisation.

**Method:** requirements vs design, then architecture, reliability, security, operations,
testing and maintainability. Findings were checked against the actual code and repo state, not
from memory.

---

## 1. Summary

The core design is sound. The server turns noisy GPS into accurate trips (Kalman smoothing,
averaged-window detection) and has a solid auth model. The iOS client is built to survive
backgrounding, offline periods and restarts as far as iOS allows, and its location service is now
isolated behind a protocol.

The serious problems are not in the algorithms. They are:

1. **Requirement vs platform mismatch.** The latest requirement is "send location every 30 s even
   after force-quit or reboot, without depending on movement." iOS cannot do that. It needs a
   decision, not more code.
2. **Operational fragility.** There are no database backups, the app signature expires every 7
   days, all recent work is uncommitted, and the repo reorganisation has broken several paths.
3. **One live security hazard from the reorganisation** (the TLS private key was no longer
   git-ignored). This was fixed during the review.

| Severity | Count |
|---|---|
| Critical | 3 (1 fixed during review) |
| High | 5 |
| Medium | 10 |
| Low | 3 |

---

## 2. Requirements vs design

| Requirement | Design today | Verdict |
|---|---|---|
| Report location while app is backgrounded / screen locked | Background location session, 30 s presence heartbeat | ✅ Met |
| Keep working offline, upload later | Disk-backed queue, uploads on reconnect | ✅ Met |
| Resume after iOS kills the app | Region (150 m), significant-change (~500 m), visit relaunch | ✅ Met, **on movement** |
| Resume after reboot | Geofence survives reboot; `voip` boot relaunch; first-unlock recovery | ⚠️ Met on movement; boot relaunch unverified |
| **Report every 30 s after force-quit, without movement** | — | ❌ **Not achievable on iOS** |
| **Relaunch after 10 m of movement** | Region fence is 150 m | ❌ **Not achievable.** iOS geofences are unreliable below ~100 m |
| Accurate trips | Kalman + RTS smoothing; top speeds fixed (233 → 55 km/h) | ✅ Met |
| "Don't track movement, only presence" | Server still detects trips from every point | ⚠️ Conflicts; see DR-13 |

A not-running iOS app gets **no timer**. It only wakes on movement or boot. No API, background
mode or push notification changes that on a normal iPhone. The options that actually satisfy the
two ❌ rows are outside the current design: a **dedicated GPS tracker**, an **Android** client,
or a **supervised (MDM) iPhone** that blocks force-quitting. This is **Decision D1** below.

---

## 3. Findings

Each finding has an ID, what's wrong, why it matters, and a recommendation.

### Critical

**DR-1 · TLS private key was not git-ignored after the reorganisation. ✅ Fixed during review**
- The `.gitignore` rules `nginx/certs/*.key` only matched the old top-level path.
  `server/nginx/certs/server.key` was *untracked but not ignored*, so the next `git add -A` would
  have committed the server's private key.
- **Fixed:** added `**/nginx/certs/*.{crt,key,pfx}` rules. `server/.env` was already ignored.
- **Recommendation:** after any folder move, re-run `git check-ignore` on every secret path.

**DR-2 · The admin page would have disappeared on the next deploy. ✅ Fixed**
- The admin page moved from inside the API project to `client/wwwroot/`, but the API served it
  with `UseStaticFiles()` from its own `wwwroot`, so the next image build would have returned 404
  for `/admin/`.
- **Fixed:** nginx now serves it. `docker-compose.yml` mounts `../client/wwwroot` into the nginx
  container, `nginx.conf` has `location /admin/`, and the API's static-file middleware was
  removed. This keeps the client/server split.
- **Also fixed:** `docker-compose.yml` pins `name: locationtracker`. Running Compose from
  `server/` would otherwise name the project `server` and start with a new, **empty** database
  volume instead of `locationtracker_pgdata`, on EC2 as well as locally.

**DR-3 · No database backups.**
- All accounts, points and trips live in one Postgres volume on one EC2 disk. A failed instance,
  corrupted volume or accidental `docker compose down -v` loses everything.
- **Recommendation:** a nightly EBS snapshot via AWS Data Lifecycle Manager (a few cents a month),
  or a `pg_dump` cron job to S3. Test one restore.

### High

**DR-4 · Requirement not achievable as stated** (see §2). **Decision D1.**

**DR-5 · The app stops working every 7 days.**
- A free Apple ID signs sideloaded apps for 7 days. When the signature expires the app won't
  launch, tracking stops, and no one is told.
- **Recommendation:** a paid Apple Developer account ($99/yr, 1-year signatures), or
  AltStore/SideStore auto-re-signing. **Decision D2.**

**DR-6 · Credential hygiene.**
- The EC2 admin password has been shown in chat, and there is **no change-password endpoint**,
  so it can't be rotated in-app. The AWS account is used as **root without MFA**.
- **Recommendation:** add `POST /api/auth/change-password`, then rotate the admin password. Turn
  on root MFA and create an IAM admin user.

**DR-7 · The reorganisation broke paths. ✅ Fixed**
- `smoke-test.sh` moved into `server/`, next to the `.env` it reads.
- `README.md` and every file in `docs/` now point to `client/…` and `server/…`, including the
  Swift files' new MVC subfolders. All relative links resolve.
- The redeploy command now sends committed code only (`git archive HEAD server client/wwwroot`)
  and runs Compose from `server/`. The README documents a one-time move of `.env` and
  `nginx/certs/` into `server/` on an instance deployed before the split.
- **Still open:** the PDFs in `docs/` are copies of the old Markdown. Regenerate them from the
  Markdown, or drop them.

**DR-8 · Recent work was uncommitted. ✅ Fixed**
- The reorganisation and refactor were committed and pushed (`f42ff6f`), followed by these fixes.

### Medium

**DR-9 · Two sources of truth for the same settings.**
- `AppConfig` (app) and `TrackingConfig` (Core) both define `heartbeatInterval`,
  `uploadInterval`, `wakeFenceRadiusMeters`, `maxBatchSize` and more. The 30 s heartbeat change
  had to be made in both places. The next change will be made in one and they'll drift.
- **Recommendation:** keep only non-Model settings (server URL, pinned certs) in `AppConfig`,
  and read everything else from `TrackingConfig`.

**DR-10 · Two `LocationPoint` types.**
- The app's upload DTO (`Model/Models.swift`) and Core's entity are identical in shape, and the
  controller maps one to the other.
- **Recommendation:** make the upload DTO a typealias of Core's type (it's already `Codable`), or
  map in one place only.

**DR-11 · TLS is held together by pinning.**
- `NSAllowsArbitraryLoads` turns App Transport Security off app-wide. The pin protects
  `APIClient`, but anything else the app ever loads is unprotected. The self-signed certificate
  **expires in Sep 2027**, and on that day the app stops connecting until a rebuild with the new
  fingerprint.
- **Recommendation:** a domain + Let's Encrypt. Then re-enable ATS and drop the pin.

**DR-12 · A 4xx upload silently discards points.**
- `UploadQueue` drops a batch on any 4xx, so a transient server bug returning 400 loses real
  data. (Flagged `// TODO: bug?` in the spec, and deliberately preserved during the refactor.)
- **Recommendation:** drop only on specific, known-permanent statuses (e.g. 413, 422), and keep
  and log the rest.

**DR-13 · The 30 s presence heartbeat has costs nobody has signed off on.**
- **Battery:** GPS and cellular radio wake every 30 s, even when still.
- **Storage:** about **2,880 points per user per day**, kept forever (there is no retention policy).
- **Wasted work:** the server runs trip detection on points the user says they don't want treated
  as movement.
- **Recommendation:** decide whether this is a presence product or a trip product
  (**Decision D3**). For presence only: a lighter `POST /api/presence` endpoint that updates
  "last seen" without storing a point per heartbeat, plus a per-user flag to skip trip detection.

**DR-14 · `voip` background mode relies on legacy behaviour.**
- The "relaunch right after boot" behaviour dates from iOS 7–9 and is unverified on current iOS.
  The App Store would reject a non-calling app that declares `voip`.
- **Recommendation:** keep it for sideloading, but test it on the device and record the result.
  Remove it before any App Store submission.

**DR-15 · Single-instance limits.**
- Rate limiters are in memory and migrations run at startup, so a second API container would
  double the limits and race migrations. The instance is a t3.micro with 1 GB RAM (fine for a few
  users). The register limit of 3/hour per IP already blocked real sign-ups behind one network.
- **Recommendation:** fine for now; document the ceiling. If users grow, move to Redis rate
  limiting and run migrations as a separate step. Consider raising the register limit.

**DR-16 · Test coverage gaps.**
- iOS: only the Model is unit-tested (30 tests). Services, Controllers and Views need a Mac.
- Server: no committed unit tests. The detection and smoothing tuning was validated with
  throwaway scripts.
- No CI.
- **Recommendation:** port the replay scripts into xUnit tests over `TripDetector` and
  `TrackSmoother`, and add a GitHub Actions job running `smoke-test.sh`, the endpoint tests and
  `swift test`.

**DR-17 · MVC refactor is partial, and that's acceptable.**
- The location service is extracted; motion (`CMMotionActivityManager`), reachability and
  notifications are still inline.
- **Recommendation:** stop here unless a Mac becomes available to test the remaining layers.
  Further extraction adds structure without adding verification.

**DR-18 · Location privacy.**
- The system stores precise, continuous location history of people and shows it live to admins.
  There is no retention limit, no audit log of who viewed whom, and no in-app statement of what
  is collected.
- **Recommendation:** a retention policy (e.g. raw points 90 days, trip summaries longer), an
  admin-view audit log, and a clear consent/disclosure screen in the app. Check what local law
  requires for your use case.

### Low

**DR-19 · Deploy ships untracked files.** `git ls-files -co` includes untracked files, which is
how Postman files reached EC2 once. Deploy from committed code only (`git archive HEAD`).

**DR-20 · Spec correction: F3.5's `// TODO: bug?` was wrong.** Rejected fixes do **not**
re-centre the geofence. The `guard … else { continue }` runs before the fence call, both before
and after the refactor. Close it.

**DR-21 · Spec F1.13 (non-admins can use the app) is intended.** The app is for tracked users,
who have the `User` role. Only the admin web page needs `Admin`. Close it.

---

## 4. What's working well (keep it)

- **Auth:** rotating refresh tokens with replay detection, uniform login failures with timing
  equalisation, CSRF for cookie clients only, and a fail-fast JWT key check.
- **Data integrity:** the one-open-trip rule is enforced by a database partial unique index, and
  raw points are never deleted, only the derived trips.
- **Trip accuracy:** Kalman/RTS smoothing validated against real and synthetic data, with trip
  boundaries robust to ±40 m fixes.
- **Client resilience:** the offline queue survives kills and session expiry, first-unlock
  handling after reboot, and a watchdog notification.
- **Layering:** CoreLocation lives in exactly one file, behind a protocol, with a pure boundary.
  The rules sit in a Core package that tests on Linux.
- **Documentation:** thorough internals, setup and limits docs, plus a characterization spec.

---

## 5. Decisions needed

| ID | Decision | Options |
|---|---|---|
| **D1** | How to handle "report after force-quit / stationary / 10 m" | Accept the iOS limit (don't force-quit; charger Shortcut) · supervised MDM iPhone · dedicated GPS tracker · Android client |
| **D2** | How the app stays signed | Paid Apple account ($99/yr) · AltStore/SideStore · re-sign weekly by hand |
| **D3** | Presence product or trip product? | Presence (light endpoint, no trips, less storage) · trips (keep as is, reduce heartbeat) · both (per-user flag) |
| **D4** | Where the admin page lives after the split (DR-2) | Back inside the API project · served by nginx from `client/wwwroot` |

---

## 6. Recommended order

1. **DR-2** Fix admin page serving *before* the next deploy.
2. **DR-7** Fix the broken paths, then **DR-8** commit.
3. **DR-3** Turn on backups.
4. **DR-6** Add change-password, rotate the admin password, enable AWS MFA.
5. Make decisions **D1–D3**. They determine whether DR-13 and DR-14 need work.
6. **DR-9, DR-12, DR-16** as ongoing hardening.
