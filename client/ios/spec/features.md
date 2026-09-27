# Phase 1 — Feature Inventory (as-is)

Target: the **iOS Swift client** in [`ios/Sources/LocationTrackerClient/`](../Sources/LocationTrackerClient/).
This document records **current behavior**, not desired behavior. Nothing here proposes a change.
Suspicious behavior is flagged inline with `// TODO: bug?` and preserved, not fixed.

Spec vocabulary mapped to Swift (the pasted brief is written for a web/TS app):
- "TS-style interface" → Swift `protocol`.
- "entity" → Swift value type (`struct`).
- "View owns the DOM" → **View owns SwiftUI/UIKit and CoreLocation/CoreMotion *presentation* only**; here the app has almost no view logic — the status screen is declarative SwiftUI bound to published state.
- "Service owns I/O" → the boundaries to CoreLocation, CoreMotion, URLSession, Keychain, the file system, `UserDefaults`, `NWPathMonitor`, `UNUserNotificationCenter`, `UIApplication` background tasks, and the system clock.

Current architecture is **not** MVC: `LocationTracker` and `UploadQueue` mix Model (state/rules),
Controller (coordination), and Service (I/O) concerns, and read the clock and OS singletons
directly. That is the target of Phases 2–4; Phase 1 only freezes what they *do*.

---

## Feature list

| ID | Feature | Primary source files |
|----|---------|----------------------|
| F1 | Session & authentication | `SessionStore.swift`, `APIClient.swift`, `TokenStore.swift`, `LoginView.swift` |
| F2 | Tracking lifecycle (auto-start / start / pause / stop / resume) | `LocationTracker.swift`, `TrackingView.swift`, `LocationTrackerClientApp.swift` |
| F3 | Location capture & validation | `LocationTracker.swift` |
| F4 | Motion-driven accuracy modes | `LocationTracker.swift` |
| F5 | Power saving & heartbeat | `LocationTracker.swift`, `AppConfig.swift` |
| F6 | Wake geofence & background relaunch | `LocationTracker.swift` |
| F7 | Upload queue durability & batching | `UploadQueue.swift`, `APIClient.swift` |
| F8 | Connectivity handling & offline/online notices | `UploadQueue.swift`, `Notifier.swift` |
| F9 | Trip-end & tracking notifications | `UploadQueue.swift`, `LocationTracker.swift`, `Notifier.swift`, `TrackingWatchdog.swift` |
| F10 | Reboot / first-unlock recovery | `TokenStore.swift`, `LocationTracker.swift` (`TrackerState`), `UploadQueue.swift`, `LocationTrackerClientApp.swift` |
| F11 | Queue ownership (user switch / sign-out) | `UploadQueue.swift`, `SessionStore.swift` |
| F12 | TLS certificate pinning | `APIClient.swift`, `AppConfig.swift` |

Each has a characterization file in [`spec/tests/`](tests/). Scenarios there are grouped by layer
(Model / View / Controller / Service) as the brief requires, even though the current code does not
yet separate those layers — the grouping describes which *responsibility* each assertion targets,
which is what Phases 2–4 will pull apart.

---

## F1 — Session & authentication

- On launch `SessionStore.restore()` runs: if the Keychain has tokens it calls `GET /api/auth/me`;
  success → `signedIn(profile)`; `401` → session ended; **network failure → keeps a cached
  profile and stays signed in** so tracking continues offline; no cached profile → `signedOut`.
- `login(email,password)` → `POST /api/auth/login`; on success stores the three cookies
  (access/refresh/csrf) into the Keychain and publishes `signedIn`.
- `register(...)` → `POST /api/auth/register`, same session handling.
- `logout()` → best-effort `POST /api/auth/logout`, then clears tokens and cached profile and
  publishes `signedOut` with `explicit = true`.
- A server-side expiry (refresh rejected) posts `.sessionExpired`; `SessionStore` ends the session
  with `explicit = false`.
- `LoginView` normalizes the server URL (trim, strip trailing `/`), maps `URLError`s to friendly
  copy, and on a pinning failure shows the fingerprint the server presented.
- **Login screen requires the account to have the `Admin`… no** — the Swift app does *not* require
  Admin (that check is only in the web client). Any valid account signs in. // TODO: bug? (product
  question, not fixed) — confirm whether a non-privileged account should be able to use the app.

## F2 — Tracking lifecycle

- `autoStart()` starts tracking for a signed-in user **unless** they explicitly paused it, it is
  already running, or location is denied. Called from `TrackingView.onAppear`.
- `start()` clears `pausedByUser`, sets `wantsTracking`, requests notification permission, then
  requests When-In-Use authorization if undetermined; on denial sets `lastError`.
- The status toggle maps ON→`start()`, OFF→`pauseByUser()` (persisted; blocks `autoStart`).
- `stop(flushRemaining:)` tears down every service; `flushRemaining == false` on sign-out.
- `resumeIfNeeded()` restarts if intent is on and authorized — the cold-start/relaunch entry point.
- The authorization delegate callback starts updates headlessly (no UI) when relaunched.

## F3 — Location capture & validation

- Each `CLLocation` from `didUpdateLocations` is converted to a `LocationPoint`:
  - dropped if `horizontalAccuracy < 0` or `> maxAcceptedAccuracyMeters` (150);
  - `speed` kept only if in `0...1000`, else `nil`; `course` kept only if in `0...360`, else `nil`;
  - `recordedAtUtc = location.timestamp`.
- Accepted points are enqueued; `lastLocation`/`lastPointAt` updated; the geofence re-centred.

## F4 — Motion-driven accuracy modes

- `CMMotionActivity` updates map to `MotionState { unknown, stationary, onFoot, cycling,
  automotive }`; `.low` confidence is ignored.
- Moving mode accuracy depends on state: automotive → `bestForNavigation` +
  `.automotiveNavigation`; onFoot/cycling → best + `.fitness`; unknown/stationary → best + `.other`.
  Low Power Mode drops each one notch.
- A motion change to a moving state refreshes `lastMovementAt` and re-applies mode.

## F5 — Power saving & heartbeat

- After `stationaryAfter` (180 s) with no movement — or `stationaryAfterMotionStill` (60 s) when
  the motion chip says still — mode drops to `hundredMeters` accuracy + 50 m filter.
- While stationary, `tick()` (every 30 s) requests one fix every `heartbeatInterval` (120 s) by
  temporarily removing the distance filter; if no fix arrives within 60 s the filter is restored.
- `uploadInterval` is 30 s normally, 60 s in Low Power Mode.

## F6 — Wake geofence & background relaunch

- A 150 m `CLCircularRegion` (`notifyOnExit = true`) is kept centred on the user, re-centred only
  after moving ≥ 2/3 of the radius.
- Leaving it (`didExitRegion` with the matching id) marks movement and resumes tracking.
- `beginUpdates()` also starts significant-change and visit monitoring and a
  `CLBackgroundActivitySession`; `Info.plist` declares `location` and `voip` background modes.

## F7 — Upload queue durability & batching

- `enqueue` appends and persists to `pending-locations.json` (file-protected), trimming oldest
  beyond `maxQueuedPoints` (20000).
- `flush()` sends oldest-first slices of `maxBatchSize` (500) via `POST /api/locations/batch`
  inside a `beginBackgroundTask`; drops a slice only on success (2xx).
- Failure semantics: **429** → set `notBefore` back-off, stop; **4xx** → drop the batch (it will
  never be accepted) and record an error; **offline/5xx/other** → keep points, stop.
- Guards: not already flushing, non-empty, a token exists, and `notBefore` not in the future.

## F8 — Connectivity handling & offline/online notices

- `NWPathMonitor` tracks reachability. On reconnect: clear back-off, flush, and if an offline
  notice had fired, post "Back online" with the count uploaded.
- On a drop, schedule an "Offline" notice after `offlineNoticeDelay` (60 s), only if still offline
  and a token exists.

## F9 — Trip-end & tracking notifications

- When a batch response's `activeTripId` differs from the stored one, the previous trip is treated
  as ended: fetch `GET /api/trips/me/{id}` and, if not active, post a "Trip recorded" summary
  (once per trip id).
- `Notifier.trackingOn()` (rate-limited to once/10 min), `trackingOff(reason)` on pause/denial/
  sign-out.
- `TrackingWatchdog` keeps a "tracking stopped" notification scheduled `watchdogDelay` (20 min)
  ahead and pushes it back on every `arm()`; it fires only if the app stops running.

## F10 — Reboot / first-unlock recovery

- `TokenStore.isUnlockedSinceBoot` distinguishes "data locked (post-boot)" from "data absent."
- `TrackerState` (a file) holds `wantsTracking`/`pausedByUser`; `load()` returns `nil` while
  locked, migrating old `UserDefaults` keys on first read.
- While `state == nil`, `wantsTracking` falls back to `authorization == .authorizedAlways`.
- On `protectedDataDidBecomeAvailable`, `tracker.reloadAfterUnlock()` adopts real state (stopping
  if intent was off), and `queue.reloadAfterUnlock()` merges on-disk + in-memory points (sorted,
  deduped) and flushes. While locked, the queue does not overwrite its file (`diskLoaded == false`).

## F11 — Queue ownership (user switch / sign-out)

- `claim(for: userId)` drops the backlog if it belonged to a different user, then records the owner.
- `clear()` empties the queue and owner (used on explicit sign-out).
- App wiring: `onSignedIn` → `claim`; `onSignedOut(explicit:)` → stop tracking, and `clear()` only
  when `explicit == true` (a server expiry keeps the backlog).

## F12 — TLS certificate pinning

- The `URLSession` delegate accepts a publicly-trusted cert via default handling; otherwise it
  computes the leaf's SHA-256 and accepts only if present in `AppConfig.pinnedCertificateSHA256`,
  recording the rejected fingerprint for the login screen. Plain `http://` URLs are rejected in
  `perform`.

---

## Cross-cutting notes (not features, but characterized where relevant)

- **Clock:** the code reads `Date()` and `Date.now` directly in ~20 places (tick timing,
  heartbeat, back-off, offline delay, movement timing). For assertable tests these must become an
  injected `Clock` (Phase 2). Listed as service **S10**.
- **Id generation:** the client does not currently generate ids (the server owns trip/point ids),
  so the brief's `IdGenerator` is **not applicable** unless a future feature needs client ids.
  Recorded as **S11 (not currently used)**.
- **Concurrency:** `LocationTracker`, `UploadQueue`, `SessionStore` are `@MainActor`; OS callbacks
  are `nonisolated` and hop to main. Tests must drive them on the main actor.
