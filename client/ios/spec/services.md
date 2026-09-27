# Phase 1 — External Services & Frozen Interfaces

Every boundary the client crosses to something outside its own pure logic. Each is (a) named,
(b) given a direction and contract, (c) confirmed mockable, and (d) given a **frozen Swift
`protocol`** to depend on. These interfaces are the seams Phases 3–4 build against; they are
**frozen** — Phase 2 sign-off is required before any change.

Direction key: **OUT** = app calls the outside; **IN** = the outside calls back into the app;
**IN/OUT** = both.

---

## Service catalogue

| ID | Service | Backed by | Direction | Mocked in tests? |
|----|---------|-----------|-----------|------------------|
| S1 | Location provider | `CLLocationManager` | IN/OUT | Yes — `LocationProviding` |
| S2 | Motion activity provider | `CMMotionActivityManager` | IN | Yes — `MotionProviding` |
| S3 | Backend API | `URLSession` → server | OUT (req) / IN (resp) | Yes — `LocationAPI` / `AuthAPI` |
| S4 | Secure token store | Keychain (`Security`) | IN/OUT | Yes — `TokenStoring` |
| S5 | Point/state persistence | file system (JSON) | IN/OUT | Yes — `PointStore`, `TrackerStateStore` |
| S6 | Small key-value prefs | `UserDefaults` | IN/OUT | Yes — `KeyValueStore` |
| S7 | Reachability | `NWPathMonitor` | IN | Yes — `Reachability` |
| S8 | Local notifications | `UNUserNotificationCenter` | OUT | Yes — `Notifying` |
| S9 | Background task assertion | `UIApplication` | OUT | Yes — `BackgroundTaskRunning` |
| S10 | Clock | `Date` / `ProcessInfo` | IN | Yes — `Clock`, `PowerState` |
| S11 | Id generator | (none today) | — | N/A — not currently used |

All eleven are **confirmed mockable**: each is an OS singleton or free function today; behind a
protocol each becomes a constructor-injected dependency with a trivial fake. No service will be
touched by a real network/disk/OS call in unit tests.

---

## Frozen entity interfaces (value types)

```ts
// Swift structs; shown in TS-style per the brief. All Codable + Equatable.

interface LocationPoint {           // one GPS fix, the unit uploaded
  latitude: number
  longitude: number
  accuracyMeters: number | null
  speed: number | null              // m/s, null = unknown
  heading: number | null            // degrees, null = unknown
  recordedAtUtc: Date
}

interface UserProfile {
  id: UUID
  email: string
  displayName: string
  roles: string[]
}

interface SessionTokens { accessToken: string; refreshToken: string; csrfToken: string }

interface BatchIngestResponse {
  accepted: number
  rejected: number
  activeTripId: Int64 | null
  warnings: string[]
}

interface Trip {
  id: Int64
  startedAtUtc: Date
  endedAtUtc: Date | null
  distanceMeters: number
  durationSeconds: number | null
  duration: string | null
  pointCount: number
  maxSpeedMps: number
  averageSpeedMps: number | null
  endReason: string | null
  isActive: boolean
}

interface TrackerState { wantsTracking: boolean; pausedByUser: boolean }

enum MotionState { unknown, stationary, onFoot, cycling, automotive }  // isMoving = last three
enum PowerMode  { full, saving }                                       // maps to isStationary
```

---

## Frozen service interfaces

```ts
// S1 — Location provider. Wraps CLLocationManager. The app sets a mode and starts/stops;
//      the provider streams fixes, auth changes, and region exits back via a delegate.
interface LocationProviding {
  authorization: AuthStatus
  delegate: LocationProviderDelegate | null
  requestWhenInUse(): void
  requestAlways(): void
  applyMode(mode: DesiredMode): void                 // accuracy + distanceFilter + activityType
  startUpdating(): void                              // + significant-change + visits + bg session
  stopUpdating(): void
  requestSingleFix(): void                           // drop distance filter until next fix (heartbeat)
  placeWakeFence(center: Coordinate, radiusMeters: number, id: string): void
  removeWakeFence(id: string): void
}
interface LocationProviderDelegate {
  didChangeAuthorization(status: AuthStatus): void
  didReceiveFixes(fixes: RawFix[]): void
  didExitRegion(id: string): void
  didVisit(): void
  didFail(transient: boolean, message: string): void
}

// S2 — Motion activity. Streams debounced activity states.
interface MotionProviding {
  isAvailable(): boolean
  start(onChange: (state: MotionState, confident: boolean) => void): void
  stop(): void
}

// S3 — Backend API. Split into two narrow interfaces (Interface Segregation): the queue needs
//      only uploads/trip reads; the session store needs only auth. Neither is a god interface.
interface LocationAPI {
  uploadBatch(points: LocationPoint[]): Promise<BatchIngestResponse>   // throws APIError
  trip(id: Int64): Promise<Trip>
}
interface AuthAPI {
  login(email: string, password: string): Promise<UserProfile>
  register(email: string, password: string, displayName: string): Promise<UserProfile>
  me(): Promise<UserProfile>
  logout(): Promise<void>
}
// APIError cases (frozen): badServerURL, invalidCredentials, unauthorized,
//   rateLimited(retryAfter?), server(status, message?), missingSessionCookies

// S4 — Secure token store.
interface TokenStoring {
  load(): SessionTokens | null
  save(tokens: SessionTokens): void
  clear(): void
  isUnlockedSinceBoot(): boolean
}

// S5 — Persistence. Two narrow stores, not one.
interface PointStore {           // pending-locations.json
  load(): LocationPoint[] | null // null = present but locked; [] = absent
  save(points: LocationPoint[]): void
  exists(): boolean
}
interface TrackerStateStore {    // tracker-state.json
  load(): TrackerState | null    // null = locked
  save(state: TrackerState): void
}

// S6 — Small prefs (serverURL, activeTripId, queueOwner, migration keys).
interface KeyValueStore {
  string(key: string): string | null
  setString(key: string, value: string | null): void
  bool(key: string): boolean
}

// S7 — Reachability.
interface Reachability {
  start(onChange: (online: boolean) => void): void
}

// S8 — Notifications.
interface Notifying {
  requestPermission(): void
  post(id: string, title: string, body: string, showInForeground: boolean): void
  cancel(id: string): void
  scheduleAfter(id: string, seconds: number, title: string, body: string): void
}

// S9 — Background task assertion.
interface BackgroundTaskRunning {
  run<T>(name: string, work: () => Promise<T>): Promise<T>   // begins + always ends the assertion
}

// S10 — Clock & power state (the injected-Clock the brief mandates for the Model).
interface Clock { now(): Date }
interface PowerState { isLowPower(): boolean }
```

---

## Mock plan (per service)

- **S1 `LocationProviding`** — `FakeLocationProvider`: records `applyMode`/`start`/`stop`/
  `placeWakeFence` calls; test drives `delegate.didReceiveFixes([...])`, `didExitRegion(id)`,
  `didChangeAuthorization(...)`. Substitutable (Liskov): the real one only forwards CoreLocation.
- **S2 `MotionProviding`** — `FakeMotion`: test invokes the `onChange` closure with chosen states.
- **S3 `LocationAPI` / `AuthAPI`** — `FakeLocationAPI` / `FakeAuthAPI`: return canned results or
  throw canned `APIError`s; record call args (which points, which trip id). No `URLSession`.
- **S4 `TokenStoring`** — `InMemoryTokenStore` with a settable `isUnlockedSinceBoot`.
- **S5 `PointStore` / `TrackerStateStore`** — in-memory fakes able to simulate the *locked* state
  (return `nil`) to test F10.
- **S6 `KeyValueStore`** — dictionary-backed fake.
- **S7 `Reachability`** — `FakeReachability` exposing a `goOffline()`/`goOnline()` trigger.
- **S8 `Notifying`** — `SpyNotifier` recording every `post`/`cancel`/`scheduleAfter`.
- **S9 `BackgroundTaskRunning`** — `PassthroughBackgroundTask` that just runs the work.
- **S10 `Clock` / `PowerState`** — `TestClock` with settable `now`; `FakePowerState` with a
  settable flag. This is what makes heartbeat, back-off, offline-delay, and stationary timing
  assertable without real waiting.

---

## What is NOT a service (stays pure, no interface)

Formatting (`ago`, `km`, `kmh`), the movement/threshold math, the smoothing decisions on the
server side (out of scope for the client), and the `MotionState`/`PowerMode` enums. These belong
to the **Model** after extraction and are tested directly with no mocks.

---

## Confirmation

- [x] Every external boundary the client touches is listed (S1–S11).
- [x] Each has a direction and a contract.
- [x] Each is confirmed mockable, with a named fake.
- [x] Interfaces are **narrow** (S3 split into `LocationAPI` + `AuthAPI`; S5 split into two stores)
      — no god interface.
- [x] No implementation detail (CoreLocation types, URLSession, Keychain queries) leaks into the
      interfaces; they speak in the app's own entities.
