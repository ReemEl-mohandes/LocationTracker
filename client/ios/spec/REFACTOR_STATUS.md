# Refactor Status — Phases 2–4

Tracks the MVC + SOLID + TDD refactor against the four-phase plan. Honest about what runs on this
machine (WSL + xtool, no Mac) vs what needs a Mac/simulator.

## Phase 2 — Sign-off ✅
Checklist approved (every feature has happy/edge/error scenarios; every service has an interface +
mock plan; scenarios assertable; no unlisted services; no impl leakage; no behavior changes).

## Phase 3 — Interfaces + runnable tests ✅ (for the Model layer)
- **Deviation from the brief, on purpose:** the brief wanted tests written *red first* against the
  current code. The current code imports CoreLocation/UIKit and **cannot be compiled or tested on
  Linux/WSL**, so red-first against it is impossible here. Instead the pure **Model** was extracted
  into `Core/` *and* tested together, landing green. The tests still assert the Phase 1
  characterization (behavior unchanged).
- Delivered: `LocationTrackerCore` package — entities, `Clock`, and policies for F3–F7 — with
  **30 XCTest cases that run via `swift test`** on this machine.

## Phase 4 — Strangler refactor 🔶 (started)
Order per the brief: interfaces → Services → Model → View → Controller → composition root.

| Step | State | Notes |
|---|---|---|
| Interfaces (protocols/entities) | ✅ | In `Core` (`Clock`) and `spec/services.md` (S1–S11 frozen). |
| **Model** extracted | ✅ | `Core` policies; **wired in** — `LocationTracker.point(from:)` now calls `PointValidator` (first strangler swap; app rebuilt green). |
| Services extracted | 🔶 | **Done:** S3 API split into `AuthAPI` + `LocationAPI` (ISP), injected into `SessionStore`/`UploadQueue` (DIP). S4 `TokenStoring` + `KeychainTokenStore`. **S1 `LocationProviding` — the `startUpdatingLocation` service — now fully extracted into `CLLocationProvider` (the ONLY file importing CoreLocation), injected into the tracker, with a pure boundary (`RawFix`, `LocationAuthorization`, `Coordinate`, `DesiredMode`).** `TrackerState` data moved to Core; file/Keychain I/O in `TrackerStateStore`. All rebuild green. **Remaining:** `Reachability` (NWPathMonitor), `Notifying` (UNUserNotificationCenter), `BackgroundTaskRunning` (UIApplication), `PointStore` (queue file), motion (CMMotionActivityManager), `PowerState`. |
| View extracted | ⬜ | `LoginView`/`TrackingView` already thin; formalize as pure SwiftUI over published state. |
| Controller extracted | 🔶 | **`LocationTracker` is now a Controller:** it imports no CoreLocation, holds an injected `LocationProviding`, and delegates every decision to the tested Core policies (`AccuracyPolicy`, `ActivityPolicy`, `GeofencePolicy`, `PointValidator`, `Geo`). Remaining direct OS use: CMMotionActivityManager (motion), to extract next. `UploadQueue`/`SessionStore` hold injected API/token services. |
| Composition root | ⬜ | `LocationTrackerClientApp.init` becomes the only place constructing concretes (already close). |

### Why the remaining steps aren't finished here
Everything below the Model touches iOS frameworks, so on this WSL/xtool setup it can be *written*
and *compiled for iOS* (via `./package.sh`) but **not unit-tested** — that needs a Mac or the iOS
Simulator. Continuing to extract Services/Controller without a way to run their tests would move
code without the TDD safety net the brief requires. Options to unblock: run the suite on a Mac, or
add a macOS CI runner (needs a paid Apple account).

## What is verifiable on this machine, today
- `cd ios/Core && swift test` → **30 Model tests green**.
- `./ios/spec/endpoint-tests.sh` → **25 endpoint checks green** against the live server.
- `cd ios && ./package.sh` → the iOS app **builds** with the Model wired in.

## Next actions (when ready)
1. Extract Services behind their protocols, injected into `LocationTracker`/`UploadQueue`/
   `SessionStore` via constructors (no more `CLLocationManager()`/`shared`/direct Keychain).
2. Move the remaining pure decisions (movement classification, tick orchestration) into `Core`
   and have the controllers call them — grows the tested surface.
3. Stand up a macOS CI runner to test the Service/View/Controller layers with the fakes from
   `spec/services.md`.
