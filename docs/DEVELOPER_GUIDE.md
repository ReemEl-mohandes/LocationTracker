# Location Tracker — Full Developer Guide

Written for: the person who owns and maintains this project — treat it as if you built every
part yourself. It explains the whole system, the exact background-execution behaviour on iOS
(the part that keeps causing confusion), how to develop it, how to sign and push the app onto
an iPhone, and how to run and deploy the server.

Everything here matches the code in this repository as of the current commit. Numbers (timers,
thresholds) are the real values from [`AppConfig.swift`](../ios/Sources/LocationTrackerClient/AppConfig.swift)
and [`TripDetectionOptions.cs`](../src/LocationTracker.Api/Common/TripDetectionOptions.cs).

---

## Table of contents

1. [What the system is](#1-what-the-system-is)
2. [The three parts and how data flows](#2-the-three-parts-and-how-data-flows)
3. [iOS background execution — the complete technical report](#3-ios-background-execution--the-complete-technical-report)
4. [Scenario matrix: exactly what happens, when](#4-scenario-matrix-exactly-what-happens-when)
5. [How the iOS app works internally (file by file)](#5-how-the-ios-app-works-internally-file-by-file)
6. [How the server works](#6-how-the-server-works)
7. [Development environment and the build loop](#7-development-environment-and-the-build-loop)
8. [Signing and pushing the app onto an iPhone](#8-signing-and-pushing-the-app-onto-an-iphone)
9. [Running and deploying the server](#9-running-and-deploying-the-server)
10. [Testing, debugging, reading crash reports](#10-testing-debugging-reading-crash-reports)
11. [Honest limits and the options that remove them](#11-honest-limits-and-the-options-that-remove-them)
12. [Glossary](#12-glossary)

---

## 1. What the system is

A phone reports its GPS position over time to a server. The server turns the raw stream of
points into **trips** (a start, a route, a distance, a duration, a top speed) and an
administrator watches everyone live on a map.

- **Client:** a native iOS app (SwiftUI), built on Linux/WSL with **xtool** — no Mac, no Xcode.
- **Server:** ASP.NET Core 9 + PostgreSQL + nginx, in Docker Compose, on an AWS EC2 instance.
- **Admin:** a web page served by the same server, showing every user's latest position and trips.

The defining constraint of the whole project is **how much background execution Apple allows a
sideloaded app**. Most of this guide is about that, because that is what governs "does it keep
tracking when I close it / restart the phone."

---

## 2. The three parts and how data flows

```
   ┌─────────────────────────┐        HTTPS (TLS, cert-pinned)        ┌──────────────────────────┐
   │      iPhone app         │  ───────────────────────────────────► │   nginx  (port 443/80)   │
   │  (SwiftUI + CoreLocation│    POST /api/locations/batch           │   terminates TLS, proxies │
   │   + CoreMotion)         │  ◄─────────────────────────────────── │        ▼                  │
   │                         │    JSON: trips, auth cookies           │   ASP.NET Core API :8080  │
   │  - GPS fixes            │                                        │   - auth (JWT in cookies) │
   │  - queue on disk        │                                        │   - trip detection        │
   │  - upload in batches    │                                        │   - trip smoothing        │
   └─────────────────────────┘                                        │        ▼                  │
                                                                      │   PostgreSQL 16 (volume)  │
   ┌─────────────────────────┐        HTTPS                           │                          │
   │   Admin web page        │  ───────────────────────────────────► │   GET /api/admin/*        │
   │  /admin/ (Leaflet map)  │  ◄─────────────────────────────────── │   served from wwwroot/    │
   └─────────────────────────┘    JSON: everyone's latest fix         └──────────────────────────┘
```

**The data unit** is a *location fix*: latitude, longitude, accuracy (metres), speed, heading,
and a timestamp. The app collects these, stores them on disk, and uploads them in batches. The
server stores every raw fix forever and derives trips from them.

---

## 3. iOS background execution — the complete technical report

This is the heart of every question you have asked ("does it run when closed / when I reboot").
Read this section slowly; it is the ground truth.

### 3.1 The five states an app can be in

| State | Meaning | Can it get GPS and upload? |
|---|---|---|
| **Foreground** | On screen | Yes, everything works |
| **Background** | Another app on screen, or screen locked, app still resident in memory | **Yes**, if it holds a location background session (this app does) |
| **Suspended** | In memory but frozen; no code runs | No code runs, but iOS will **wake** it for a location event |
| **Not running (terminated by iOS)** | iOS reclaimed its memory | Not running, but iOS **relaunches** it for a location event |
| **Not running (force-quit by user)** | User swiped it away in the app switcher | iOS treats this as "user wants it off" — **most** relaunch triggers are suppressed |

The entire difficulty is the last two rows.

### 3.2 The mechanisms Apple gives you, and precisely what each does

The app uses all of the location-based ones. There is no single "run forever" switch; you
combine them.

**a) `UIBackgroundModes = location` (Info.plist) + `allowsBackgroundLocationUpdates = true`**
Lets the app keep receiving GPS while backgrounded or the screen is locked. This is what makes
"close the screen, keep tracking" work. It does **not** survive force-quit or reboot on its own.

**b) `CLBackgroundActivitySession` (iOS 17)**
Declares to iOS "I am actively using location in the background right now." Keeps standard
location updates flowing while backgrounded and shows the blue status-bar indicator. Recreated
on every launch. Used in `beginUpdates()`.

**c) Significant-location-change monitoring (`startMonitoringSignificantLocationChanges`)**
iOS watches cell-tower / Wi-Fi changes (roughly every 500 m). When one happens and the app is
**suspended or terminated by iOS**, iOS **relaunches the app in the background** and delivers
the change. Very low power. Requires movement of ~500 m. **Suppressed after force-quit.**

**d) Region monitoring / geofence (`startMonitoring(for: CLCircularRegion)`)**
iOS watches a circle (this app uses a **150 m** radius around the last known position). When the
phone **leaves** the circle, iOS **relaunches the app in the background** — this survives app
termination **and phone reboot**. This is the strongest relaunch lever available to a normal
app. It needs the user to physically move out of the circle. It is what
[`LocationTracker.swift`](../ios/Sources/LocationTrackerClient/LocationTracker.swift)
re-centres on each fix (`placeWakeFenceIfNeeded`). **Suppressed after force-quit** on most iOS
versions, honoured after a reboot.

> Note: this project originally used the newer `CLMonitor` API for the geofence. It **crashed
> the app at launch on the real device**, found by a systematic feature-by-feature bisect
> (building four variants, each missing one feature, and seeing which opened). It was replaced
> with the classic `CLLocationManager` region API, which is stable. Lesson: on sideloaded
> builds, prefer the long-established CoreLocation APIs.

**e) Visit monitoring (`startMonitoringVisits`)**
iOS relaunches the app when it detects you arrived at or left a place. Coarse, low power, a
secondary relaunch trigger.

**f) `voip` background mode (the "boot relaunch" entry)**
Apple's documentation states an app declaring the `voip` background mode is *"relaunched in the
background immediately after system boot."* This is the **only** mechanism that can relaunch an
app after a reboot **without the user moving**. It is a legacy behaviour from the old VoIP push
era. Current builds include it (`UIBackgroundModes` in
[`Info.plist`](../ios/Info.plist) contains `voip`). **Whether a given modern iOS version
still honours it must be confirmed on the device** — Apple has weakened it over the years. It
costs nothing to include for a sideloaded app.

**g) BGTaskScheduler (background app refresh / processing tasks)**
Lets you ask iOS for occasional background time. iOS decides when, based on usage and battery —
could be minutes, could be hours, and never on a fixed schedule. Not used here because it is far
too irregular for live tracking, but worth knowing it exists.

**h) Remote push / PushKit VoIP push — why they do NOT solve this**
A **standard push** (APNs) cannot launch a terminated app and cannot run your code unless the
user taps it; it only shows a banner. A **PushKit VoIP push** *can* wake a force-quit app — but
since iOS 13 Apple **requires** you to report a real incoming phone call (CallKit) on every VoIP
push, or iOS kills the app and stops delivering pushes. So VoIP push cannot be used to silently
send a location. Both also require a **paid Apple Developer account** for the push certificate.
Neither is a path to silent continuous tracking.

### 3.3 Why force-quit is a hard wall

When the user swipes the app away in the app switcher, iOS records an explicit "the user does
not want this app running" signal. It then suppresses significant-change and (on most versions)
geofence relaunches for that app until the user manually opens it again. **No API, entitlement,
background mode, or push overrides this on a normal iPhone.** The only platforms without this
rule are:

- **Jailbroken** devices (not relevant, unstable, insecure), or
- **Supervised / MDM-managed** devices, where a device owner can enforce an always-running app.

This is not a limitation of this app's code. It is enforced by iOS itself.

### 3.4 The "first unlock after reboot" subtlety (important, and handled)

After a reboot, iOS keeps every app's protected data — the Keychain, `UserDefaults`, and files
with default protection — **encrypted and unreadable until the user unlocks the phone once**.
iOS may relaunch the app for a location event *before* that first unlock. A naive app then:

- can't read whether tracking was on → assumes off → doesn't start;
- can't read its saved login → can't upload;
- might overwrite its saved offline backlog with an empty file.

This app handles it explicitly:

- `TokenStore.isUnlockedSinceBoot` probes a Keychain item to tell "locked away" from "absent."
- Tracking intent lives in `TrackerState` (a file), and while it's unreadable the app **assumes
  tracking is on if location permission is "Always"** — a safe default, since nobody grants
  Always to an app they don't want tracking them.
- The upload queue refuses to overwrite its file while it can't read it, and **merges** in-memory
  points with the saved backlog once unlocked.
- `UIApplication.protectedDataDidBecomeAvailableNotification` fires on unlock; the app then
  re-reads real state and reconciles (`reloadAfterUnlock()` in the tracker and the queue).

So after a reboot, once the phone is unlocked once, the app corrects itself and uploads
everything it buffered.

---

## 4. Scenario matrix: exactly what happens, when

Assumptions: location permission is **Always**, Motion and Notifications allowed, sharing was
turned on.

| # | Scenario | Does tracking continue / resume? | How | Delay |
|---|---|---|---|---|
| 1 | App in foreground | Yes | Directly | none |
| 2 | Switch to another app / lock screen | Yes | Location background session (b) | none |
| 3 | Phone sitting still, app backgrounded | Yes, at low power | Heartbeat every **2 min** (low-accuracy fix) | ≤2 min per point |
| 4 | Driving/walking, app backgrounded | Yes, full accuracy | Standard updates + motion detection | seconds |
| 5 | No internet (Wi-Fi + cellular off) | Yes — keeps recording | Points queue on disk, upload when back online | until reconnect |
| 6 | iOS terminates the app for memory | Resumes when you move ~500 m or leave the 150 m fence | Significant-change (c) + geofence (d) | until you move |
| 7 | **You force-quit (swipe away)** | **No, until you reopen** | iOS suppresses relaunch | indefinite |
| 8 | **Phone reboot, then you MOVE** | Resumes | Geofence (d) survives reboot; fires on leaving 150 m | when you move |
| 9 | **Phone reboot, you DON'T move** | **Only if `voip` boot-relaunch is honoured by your iOS**; otherwise no | voip mode (f) | seconds if honoured, else never until you move/open |
| 10 | App stopped for any reason, 20 min pass | User is nudged | "Location sharing stopped" local notification (watchdog) | ≤20 min |
| 11 | You delete the app | Nothing is sent, ever | App and all its background registrations are gone | — |

**Row 9 is the one you keep asking about.** The code already contains the only mechanism Apple
offers for it (`voip`). It is untested on your specific device. If it doesn't fire there, no
sideloaded app can do "instant relaunch standing still after reboot" — see
[section 11](#11-honest-limits-and-the-options-that-remove-them).

**Practical rule for the user:** *don't swipe the app away*, and plug the phone in after a
reboot (a charger-connected Shortcut automation reopens the app within seconds — see 8.6).

---

## 5. How the iOS app works internally (file by file)

All Swift files live in [`ios/Sources/LocationTrackerClient/`](../ios/Sources/LocationTrackerClient/).
It is a SwiftUI app, one screen for sign-in and one for status.

### `LocationTrackerClientApp.swift` — entry point and wiring
Creates the three long-lived objects and connects them:
- `SessionStore` (who is signed in), `UploadQueue` (points waiting to send), `LocationTracker`
  (the CoreLocation driver).
- Registers the notification presenter and the **`protectedDataDidBecomeAvailable`** observer
  (the first-unlock reconciliation from 3.4).
- On sign-out: stops tracking; discards the backlog only on an **explicit** sign-out, keeps it
  if the server merely expired the session.

### `LocationTracker.swift` — the core state machine
Wraps `CLLocationManager` and `CMMotionActivityManager`. Responsibilities:
- **Start/stop** tracking; `autoStart()` starts automatically for a signed-in user unless they
  turned it off.
- **Background session, significant-change, visits, region geofence** all started in
  `beginUpdates()`.
- **Motion-driven accuracy** (`handleMotion`): the motion coprocessor reports Still / On-foot /
  Cycling / Driving within seconds at almost no battery cost. Driving → navigation-grade GPS +
  automotive activity type; walking/cycling → fitness type; still → low power. This is the fix
  for GPS staying off during drives.
- **Battery modes** (`applyMode`): full accuracy while moving; after **3 min** still (or **1 min**
  if the motion chip says still) it drops to ~100 m accuracy with a 50 m filter.
- **Heartbeat** (`tick`): while stationary, request one fix every **2 min** so the server keeps
  seeing the user as online and can close trips.
- **Wake geofence** (`placeWakeFenceIfNeeded` / `wakeFenceExited`): 150 m circle re-centred as
  you move; leaving it resumes tracking after termination/reboot.
- **`TrackerState`** (bottom of file): tracking intent stored in a file, with the first-unlock
  handling from 3.4.

### `UploadQueue.swift` — durable, offline-first upload
- Points are appended and **persisted to disk** (`pending-locations.json`, file-protected).
- `flush()` sends oldest-first in batches of **500**, inside a `beginBackgroundTask` so a batch
  in flight can finish before iOS suspends the app.
- An `NWPathMonitor` triggers an immediate flush **the moment connectivity returns**, and sends
  the "Offline"/"Back online" notifications.
- Survives session expiry; `claim(for:)` drops another user's backlog so histories never mix.
- `reloadAfterUnlock()` merges in-memory + on-disk points after a reboot's first unlock.
- Detects a trip ending (the server's active-trip id changed) and fires the "Trip recorded"
  notification with the server's smoothed figures.

### `APIClient.swift` — networking, auth, TLS pinning
- The server issues auth as **HttpOnly cookies**. The app lifts them into the Keychain and sends
  the access token as a `Bearer` header (which sidesteps CSRF for bearer requests). On a 401 it
  refreshes once, **single-flight** (refresh tokens rotate; a double refresh would revoke the
  session).
- **Certificate pinning** (`urlSession(_:didReceive:)`): the server uses a self-signed cert on a
  bare IP. Instead of disabling validation, the app accepts **only** certs whose SHA-256
  fingerprint is in `AppConfig.pinnedCertificateSHA256`. Plain `http://` is refused.

### `TokenStore.swift` — Keychain storage + the unlock probe
Stores the session tokens; `isUnlockedSinceBoot` is the first-unlock detector.

### `Notifier.swift` / `TrackingWatchdog.swift` — local notifications
- Trip summaries, tracking on/off, offline/online — each kind reuses one identifier so they
  replace rather than stack.
- The watchdog keeps a notification scheduled **20 min** out and pushes it back while the app
  runs; if the app stops, it fires ("tap to resume"). This is a dead-man's switch that works
  even without a termination callback.

### `Models.swift`, `SessionStore.swift`, `LoginView.swift`, `TrackingView.swift`
DTOs mirroring the server; the sign-in/session state machine; the two screens. `TrackingView`
shows GPS mode, motion state, queue depth, last upload, and the trip list.

### `AppConfig.swift` — every tunable in one place
Server URL, pinned fingerprints, and all the timers/thresholds quoted above.

---

## 6. How the server works

ASP.NET Core 9, one Web API project. Full API and security details are in the main
[`README.md`](../README.md); this is the essence.

### Auth
ASP.NET Core Identity, JWT access token (15 min) + rotating refresh token (7 days), both
delivered as HttpOnly cookies, with a CSRF double-submit check and per-IP rate limits.

### Trip detection ([`TripDetector.cs`](../src/LocationTracker.Api/Services/TripDetector.cs))
Runs on every ingested point. Because phones often report ±30–100 m Wi-Fi/cell positions,
movement is judged by **averaging** the last 10 s of fixes against the average from 20–60 s
earlier (noise shrinks by √n), not by comparing single points. A move must beat
`MovementNoiseFactor` (2×) the combined accuracy. Trips open where the baseline began, close on
5 min idle or a 15 min reporting gap.

### Trip measuring ([`TripFinalizer.cs`](../src/LocationTracker.Api/Services/TripFinalizer.cs) + [`TrackSmoother.cs`](../src/LocationTracker.Api/Common/TrackSmoother.cs))
Summing raw fix-to-fix hops counts noise as distance (this is why you saw 233 km/h). Instead, a
**Kalman filter with an RTS smoother** estimates the true path, weighting each fix by its
accuracy; distance and top speed are read off the smoothed track. On ±40 m test data this lands
within a few percent of truth. `POST /api/admin/trips/recalculate` re-runs it over old trips
(the **Recalculate** button on the admin page).

### Stale-trip sweeper
A background service closes trips whose phone went silent, so one is never left open forever.

### Admin page ([`wwwroot/admin/`](../src/LocationTracker.Api/wwwroot/admin/))
Static Leaflet map, polls `/api/admin/locations/latest` every 5 s. A user is **online** if the
server received a point within the last 5 minutes (measured by receive time), else **offline**.

---

## 7. Development environment and the build loop

You build iOS apps here **without a Mac**, using **xtool** inside **WSL (Ubuntu)**.

### One-time setup (already done on this machine)
- WSL Ubuntu with Swift 6 toolchain (via swiftly).
- `xtool` installed at `/usr/local/bin/xtool`.
- The Darwin Swift SDK installed into xtool from an `Xcode.xip` (`xtool sdk install …`).

### Project shape (an xtool SwiftPM package, not an Xcode project)
```
ios/
├── Package.swift          # one library product = the app; Swift 5 language mode
├── xtool.yml              # bundleID, infoPath, iconPath
├── Info.plist            # background modes, permission strings, ATS
├── Resources/AppIcon.png  # 1024×1024 icon
├── Sources/LocationTrackerClient/*.swift
├── package.sh             # build + wrap into .ipa on the Desktop
└── mkipa.py               # zips the .app into a .ipa (WSL has no `zip`)
```

### The edit → build loop
From WSL, always a **login shell** (so swiftly's PATH is loaded):
```bash
wsl -d Ubuntu -- bash -lc 'cd /mnt/c/dev/LocationTracker/ios && ./package.sh'
```
`package.sh` runs `xtool dev build`, then `mkipa.py`, and copies
`LocationTrackerClient.ipa` to the Windows Desktop. A clean build is ~1 min; incremental ~10–20 s.

**Two gotchas learned the hard way:**
- Run xtool in a **login** shell (`bash -lc`), or Swift isn't on PATH ("Failed to obtain Swift
  version").
- `xtool dev build --ipa` needs the `zip` binary, which stock Ubuntu lacks — hence `mkipa.py`.

### Changing settings
- **Bundle ID** → `xtool.yml`.
- **Background modes / permission strings / ATS** → `Info.plist` (xtool merges it into the
  generated plist).
- **App icon** → replace `Resources/AppIcon.png` (1024×1024), keep `iconPath` in `xtool.yml`.
- **Timers/thresholds/server URL/pinned certs** → `AppConfig.swift`.

---

## 8. Signing and pushing the app onto an iPhone

xtool produces an **unsigned** `.ipa`. To install it you sign it with your Apple ID and
sideload it. There are two common routes.

### 8.1 What "signing" means here
An iPhone only runs apps signed by a certificate it trusts. With a **free Apple ID** you get a
7-day development certificate; with a **paid Apple Developer account ($99/yr)** you get a 1-year
one. The sideloading tool creates that certificate for you from your Apple ID and re-signs the
`.ipa`.

### 8.2 Route A — Sideloadly (what you have been using; Windows-friendly)
1. Install **iTunes** (the Apple version, for the device drivers) and **Sideloadly**
   (sideloadly.io) on the PC.
2. Plug the iPhone in over USB; trust the computer on the phone.
3. Open Sideloadly, drag in `LocationTrackerClient.ipa`.
4. Enter your **Apple ID**. (Use an app-specific password if the account has 2FA — create one at
   appleid.apple.com.)
5. Click **Start**. Sideloadly re-signs and installs.
6. On the phone: **Settings → General → VPN & Device Management → [your Apple ID] → Trust**.
7. **Settings → Privacy & Security → Developer Mode → on** (reboot when prompted).

### 8.3 Route B — AltStore / SideStore (auto-re-signs before the 7 days expire)
AltStore installs a companion that renews the signature in the background over Wi-Fi, so the app
doesn't die every 7 days. Heavier to set up; better if you don't want to re-sign manually.

### 8.4 The 7-day expiry (free account)
A free-account app **stops launching after 7 days** and must be re-installed/re-signed. When it
stops launching, tracking stops. Options: re-run Sideloadly weekly, use AltStore/SideStore, or
get the paid account for 1-year installs. **This is the single biggest reliability issue for a
sideloaded tracker.**

### 8.5 Bundle ID
Change `com.example.LocationTrackerClient` in `xtool.yml` to something unique to you before wide
use. Free accounts are limited to a handful of distinct app IDs per week.

### 8.6 Recommended Shortcut automations (cover reboot/force-quit gaps)
These are created on the phone in the **Shortcuts** app (they cannot be imported from a file —
Apple only allows building automations by hand):
- **Automation → Charger → Is Connected → Run Immediately → Open App → Location Tracker.**
  Reopens the app within seconds of plugging in, which is what you do after a reboot.
- **Automation → Time of Day → 8:00 AM → Daily → Open App → Location Tracker.** A daily safety net.

### 8.7 Permissions to grant on the phone (once)
- **Location → Always**, **Precise Location → on**.
- **Motion & Fitness → on** (drives the accuracy switching).
- **Notifications → Allow**.
- **Background App Refresh → on**.
- Keep **Low Power Mode** off when possible (it reduces background frequency).

---

## 9. Running and deploying the server

### 9.1 Local (developer machine)
```bash
cp .env.example .env        # fill in every value
./generate-certs.sh         # self-signed cert for nginx (once)
docker compose up -d --build
./smoke-test.sh             # 31-check end-to-end verification
```
Reachable at `https://localhost` (self-signed, so `-k` in curl). Swagger at `/swagger` when
`SWAGGER_ENABLED=true`.

### 9.2 AWS EC2 (the live server, `34.199.20.93`)
One Ubuntu 24.04 `t3.micro`, Elastic IP, security group `reem-sg` (SSH from your IP only,
80/443 public). First-time provisioning:
```bash
# on the instance, repo copied over:
PUBLIC_IP=<elastic ip> ./deploy/ec2-setup.sh   # Docker, swap, fresh .env secrets, cert
sudo docker compose up -d --build
```
`ec2-setup.sh` generates its own DB password, JWT key, and admin password (printed once), sets
Swagger off, and makes a cert naming the public IP.

### 9.3 Redeploying code
```bash
git ls-files -co --exclude-standard | grep -v '^ios/' | tar -czf - -T - \
  | ssh -i ~/.ssh/reem-key.pem ubuntu@34.199.20.93 'tar -xzf - -C ~/LocationTracker'
ssh -i ~/.ssh/reem-key.pem ubuntu@34.199.20.93 \
  'cd ~/LocationTracker && sudo docker compose up -d --build'
```
On a t3.micro, flip CPU credits to `unlimited` for the build, then back to `standard`
(`aws ec2 modify-instance-credit-specification`), or the .NET build crawls.

### 9.4 After changing the server certificate
The app pins the cert fingerprint. If you re-run `generate-certs.sh`, update the matching entry
in `AppConfig.pinnedCertificateSHA256` and rebuild the app, or it will refuse to connect.

---

## 10. Testing, debugging, reading crash reports

### 10.1 Server
`./smoke-test.sh` exercises auth, CSRF, trip detection, drift rejection, teleport rejection,
lockout, rate limiting, refresh rotation, and the sweeper — 31 checks. Run it after any server
change.

### 10.2 App won't open (crash at launch)
The iPhone writes a crash log. Read it either way:
- **On the phone:** Settings → Privacy & Security → Analytics & Improvements → Analytics Data →
  newest `LocationTrackerClient-…` entry → share to yourself.
- **Bisect method (used to find the `CLMonitor` crash):** build several `.ipa` variants, each
  with one feature disabled, install them in turn, and see which opens. The one feature whose
  removal fixes the launch is the culprit. This found the geofence-API crash without a Mac
  debugger.

### 10.3 "Phone shows offline / tracking gaps"
Query the server DB directly (read-only) to see the last received point and any reporting gaps:
```sql
select max("ReceivedAtUtc") from "Locations";
```
Gaps line up with force-quits, dead zones, or the phone being off. Compare against the scenario
matrix in section 4.

### 10.4 Common causes of "not tracking"
- App was **swiped away** (row 7).
- **Low Power Mode** on.
- Location set to **While Using** instead of **Always**.
- Free-account signature **expired after 7 days**.
- **Motion & Fitness** permission denied → GPS accuracy switching won't kick in.

---

## 11. Honest limits and the options that remove them

**What a normal sideloaded iPhone app — this one included — cannot do:**
- Keep running after the user **force-quits** it (swipes it away).
- **Launch itself instantly after reboot while the phone sits still**, unless the legacy `voip`
  boot-relaunch is honoured by that iOS version (included, unverified on your device).
- Have a **notification silently open the app** — only a user tap opens it.
- Run **at exact fixed intervals** in the background — iOS decides the timing.

These are iOS platform rules, not bugs in this code, and no API/entitlement/push overrides them.

**The only ways to truly remove them:**

| Goal | Real solution | Cost / requirement |
|---|---|---|
| Survive 7-day expiry; reliable background; real push | **Paid Apple Developer account** | $99/year; still won't beat force-quit |
| Force an app to always run, relaunch after reboot, resist force-quit | **Supervised / MDM-managed device** | You must own/administer the phone and enrol it (Apple Configurator or an MDM) |
| Anything-goes background | Jailbreak | Not recommended: insecure, unstable, per-iOS-version |

If continuous, tamper-resistant tracking is a genuine requirement (e.g. a fleet/company phone),
the **supervised-device** route is the supported answer and changes the whole picture — the app
can then be locked running. That needs a decision about device ownership before it's worth
building.

---

## 12. Glossary

- **Fix** — one GPS reading (lat, lon, accuracy, speed, heading, time).
- **Trip** — a server-derived journey: start, route, distance, duration, top speed.
- **Sideloading** — installing an app outside the App Store by signing it with your own Apple ID.
- **Geofence / region monitoring** — iOS watching a circle and waking/relaunching your app when
  the phone crosses its edge.
- **Significant-location-change** — iOS waking your app on ~500 m cell/Wi-Fi movement.
- **Force-quit** — swiping the app away in the app switcher; iOS then suppresses relaunch.
- **First unlock after reboot** — the point at which iOS makes protected data readable again.
- **Kalman + RTS smoother** — the server algorithm that estimates the true path from noisy fixes.
- **MDM / supervised** — enterprise device management that can enforce an always-running app.
- **xtool** — the tool that builds iOS apps from a Swift package on Linux/WSL, no Xcode.

---

*This guide describes the system as built in this repository. When you change a timer,
threshold, endpoint, or background mode, update the matching section here so it stays the single
source of truth.*
