# LocationTrackerCore

The **pure, platform-agnostic Model** for the iOS client: entities, the injected `Clock`, and the
behavioral rules (point validation, accuracy modes, heartbeat/stationary timing, geofence
placement, upload-queue policy). No CoreLocation / UIKit / Security / Network imports, so it
compiles and **unit-tests on Linux/WSL**:

```bash
cd ios/Core && swift test        # 30 tests, runs on this machine (no Mac/simulator needed)
```

The iOS app package (`../Package.swift`) depends on this via a local path and calls into it, so
the tested rules are the ones that run in production (strangler pattern — see
[../spec/REFACTOR_STATUS.md](../spec/REFACTOR_STATUS.md)).

Contents:
- `Entities.swift` — `LocationPoint`, `Coordinate`, `MotionState`, `GPSAccuracy`, `ActivityKind`,
  `DesiredMode`, `TrackerState`.
- `TrackingConfig.swift` — all tunables (defaults mirror the app's `AppConfig`), `Clock`, `Geo`.
- `Policies.swift` — `PointValidator` (F3), `AccuracyPolicy` (F4), `ActivityPolicy` (F5),
  `GeofencePolicy` (F6), `UploadPolicy` (F7).

Behavior is frozen to match the Phase 1 characterization, including the `// TODO: bug?` quirks
(e.g. a 4xx upload drops the batch) — preserved, not fixed.
