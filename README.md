# Location Tracker API

A .NET 9 backend where regular users report their GPS position over time and administrators
track them. Raw points are rolled up automatically into **trips**: the server notices when a
user starts moving, accumulates distance as points arrive, and closes the trip with a total
distance and duration when they stop.

Stack: ASP.NET Core 9 · ASP.NET Core Identity · EF Core 9 · PostgreSQL 16 · nginx (TLS) · Docker Compose.

---

## Running it

The repo has two halves: `server/` (API, Postgres, nginx, deploy scripts) and `client/`
(the iOS app in `client/ios/`, the admin web page in `client/wwwroot/`). Everything
server-side runs from `server/`:

```bash
cd server
cp .env.example .env        # then edit every value
./generate-certs.sh         # self-signed cert for nginx, once
docker compose up -d --build
./smoke-test.sh             # end-to-end verification
```

The API is reachable at **https://localhost**. The certificate is self-signed, so pass
`-k` to curl or trust it explicitly. Plain HTTP on port 80 redirects to HTTPS.

Swagger is served at `/swagger` in Development, or in any environment when `SWAGGER_ENABLED=true`
in `.env`. Log in via `/api/auth/login` first; the UI then sends the CSRF header automatically.

### Required configuration

Everything lives in `.env`, which is gitignored. `JWT_SIGNING_KEY` must be at least 32 bytes
or **the API refuses to start** — a short key is a deployment mistake, not something to
discover in production. Generate one with `openssl rand -base64 48`.

`SEED_ADMIN_EMAIL` / `SEED_ADMIN_PASSWORD` create the bootstrap administrator on first
startup. Registration only ever grants the `User` role, so without this there is no way to
obtain an admin account. The seeder only ever *creates* — it will not reset the password of
an existing admin on restart.

---

## Architecture

Single Web API project with layered folders:

| folder | contents |
|---|---|
| `Entities/` | `ApplicationUser`, `ApplicationRole`, `Location`, `Trip`, `RefreshToken` |
| `Data/` | `AppDbContext`, fluent configurations, migrations, seeder |
| `Services/` | auth, tokens, location ingestion, trip detection, the sweeper |
| `Security/` | cookie writing, CSRF, rate-limit policies, authorization policies |
| `Controllers/` | `Auth`, `Locations`, `Trips`, `Admin` |
| `Common/` | `GeoMath`, paging, error shape, exception middleware, options |

### Identity, not a hand-rolled user table

`ApplicationUser : IdentityUser<Guid>` adds only `DisplayName` and `CreatedAtUtc`. Password
hashing (PBKDF2-HMAC-SHA256 at 210,000 iterations), `AccessFailedCount`, `LockoutEnd`,
`SecurityStamp`, normalized emails and the role tables all come from Identity.

Wiring uses `AddIdentityCore` rather than `AddIdentity`. The latter registers the
`Identity.Application` cookie scheme *and makes it the default authentication scheme*, which
silently takes over from JwtBearer. There are no Razor Pages and no scaffolded Identity UI.

Two tables are genuinely custom: `Location`, and `RefreshToken` — Identity's
`AspNetUserTokens` is keyed `(UserId, LoginProvider, Name)` and so cannot represent
per-device token chains or detect replay of a revoked token.

---

## Trip detection

`TripDetector` runs on every ingested point, inside the transaction that stores it. It
decides where trips start and end. `TripFinalizer` then measures them.

Phones often report ±30–100 m positions from Wi-Fi and cell towers rather than GPS. At that
accuracy, comparing a fix with the one just before it fails in both directions: a real 13 m
hop at driving speed looks like noise, while a 60 m sideways wobble looks like travel.
Replaying real trips showed top speeds of 233 km/h on city drives, and summed distances that
were mostly wobble.

1. **Fixes vaguer than `MaxAccuracyMeters` (100 m)** are stored but take no part in
   detection.
2. **Movement is judged on averages.** The mean position over the last 10 seconds is compared
   with the mean over 20–60 seconds earlier. Averaging n fixes shrinks their noise by √n, and
   the move must exceed `MovementNoiseFactor` (2) times the combined remaining uncertainty,
   and at least `MinDisplacementMeters` (15 m), at `MovingSpeedMps` or faster. A GPS fix of
   ±20 m or better that reports its own (Doppler) speed is trusted directly. With sparse
   reporting each window holds one fix, which reduces to a point-to-point comparison.
3. A single hop faster than `MaxPlausibleSpeedMps` (70 m/s) is a teleport and is rejected.
4. The first movement **opens a trip where the baseline began**, so the stretch just
   travelled is included.
5. Stillness beyond `IdleTimeoutMinutes` (5) closes the trip **at its last moving point**, so
   time spent idling at the destination is not counted as travel time.
6. A silence longer than `GapTimeoutMinutes` (15) closes the trip with `ReportingGap` rather
   than bridging the unknown interval with a straight line.

**Measuring.** After every save, `TripFinalizer` runs the trip's points through a Kalman
filter with a Rauch–Tung–Striebel backward pass (`TrackSmoother`). Each fix is weighted by its
reported accuracy against a constant-velocity model (`SmoothingAccelerationMps2`, 0.5). The
trip's distance and top speed are read off that smoothed track, and the trip detail
endpoint draws it. On ±40 m test tracks the smoothed distance landed within a few percent of
the truth, where summing raw hops was off by 2–15×.

On close, a trip is deleted (its points detached, raw history kept) if its smoothed distance
is under `MinTripDistanceMeters` (100 m), or if it never got further from its start than
`TripExtentAccuracyFactor` (3) × its typical fix accuracy. That second rule removes the
wobble of a phone lying still, which can add up to a respectable distance without going
anywhere. `POST /api/admin/trips/recalculate[?userId=]` (the **Recalculate** button on the
admin page) re-measures existing trips with the current settings. It does not re-detect
where they start and end.

`StaleTripSweeper` closes trips whose client stopped reporting entirely. It is **required,
not optional** — trips are otherwise only ever closed by the arrival of a later point, so a
user who kills the app mid-journey would leave one open forever.

A **partial unique index**, `UX_Trips_UserId_Active` on `(UserId) WHERE "EndedAtUtc" IS NULL`,
guarantees one open trip per user in the database rather than only in application code; a
concurrent ping and a batch upload would otherwise race into two.

Batch uploads replay points in recorded order through the same detector, so an offline
backlog produces the same trips it would have produced live.

All thresholds are bound from the `TripDetection` config section — tune them without rebuilding.

---

## Security

**Tokens in cookies.** A 15-minute access token and a 7-day rotating refresh token, both
`HttpOnly`, `Secure`, `SameSite=Strict`. Nothing is returned in a response body for script to
store, so an XSS payload cannot read them. JwtBearer only reads the `Authorization` header by
default, so `OnMessageReceived` lifts the token out of the cookie. `ClockSkew` is zeroed —
the 5-minute default meaningfully extends a 15-minute token.

**Refresh rotation with replay detection.** Tokens are stored as SHA-256 hashes, never raw.
Each refresh revokes its predecessor. Presenting an already-revoked token means either a
stale cookie jar or theft; the two are indistinguishable, so the entire chain is revoked.

**Global logout.** `POST /api/auth/logout-all` rotates the Identity security stamp, which the
access token carries as a claim, invalidating every outstanding session at once.

**Brute force, two independent layers.** Per-account lockout comes from Identity
(`MaxFailedAccessAttempts = 5`, 15-minute window, `AllowedForNewUsers = true` — off by
default and easy to miss). Per-IP rate limiting catches credential stuffing spread across
many accounts, which per-account lockout never sees:

| policy | partition | limit |
|---|---|---|
| `login` | sliding window per IP | 5 / min |
| `register` | fixed window per IP | 3 / hour |
| `location-write` | token bucket per **user** | 60 / min, burst 120 |
| global | fixed window per IP | 100 / min |

**No enumeration oracle.** Wrong password, unknown account and locked-out all return a
byte-identical 401. An unknown email still runs a real hash verification against a dummy
hash so response timing does not reveal which addresses are registered.

**`UseForwardedHeaders` runs before `UseRateLimiter`.** Behind nginx every request arrives
from the proxy's container IP; without this the limiters collapse into a single shared bucket
and protect nothing. `KnownNetworks`/`KnownProxies` are cleared for the Docker bridge network.

**CSRF.** Cookie credentials are attached by the browser automatically, so `SameSite=Strict`
alone is not sufficient. A readable `csrf_token` cookie must be echoed in an `X-CSRF-Token`
header on every non-GET request, compared in constant time. Tokens use the **base64url**
alphabet on purpose: ASP.NET Core percent-encodes cookie values on write and decodes them on
read, but header values are not decoded, so a `+` or `/` in the token would make a client
echoing the cookie verbatim fail the comparison. Restricting to `[A-Za-z0-9_-]` keeps the two
forms identical, so clients can read `document.cookie` and send the value unchanged. CORS is restricted to an explicit
origin list with `AllowCredentials` — `AllowAnyOrigin` is invalid alongside credentials anyway.

**Fallback authorization policy.** Every endpoint requires authentication unless it carries an
explicit `[AllowAnonymous]`, so a new controller cannot ship unprotected by omission.

---

## API

| method | route | access |
|---|---|---|
| POST | `/api/auth/register` | anonymous |
| POST | `/api/auth/login` | anonymous |
| POST | `/api/auth/refresh` | refresh cookie |
| POST | `/api/auth/logout` | authenticated |
| POST | `/api/auth/logout-all` | authenticated |
| GET | `/api/auth/me` | authenticated |
| POST | `/api/locations` | User |
| POST | `/api/locations/batch` | User |
| GET | `/api/locations/me` | User — `?from&to&page&pageSize` |
| GET | `/api/locations/me/latest` | User |
| GET | `/api/trips/me` | User — `?from&to&activeOnly&page&pageSize` |
| GET | `/api/trips/me/active` | User — 204 when not moving |
| GET | `/api/trips/me/{id}` | User — summary + ordered path |
| GET | `/api/admin/users` | **Admin** — `?search&page&pageSize` |
| GET | `/api/admin/users/{id}/locations` | **Admin** |
| GET | `/api/admin/users/{id}/trips` | **Admin** |
| GET | `/api/admin/trips/{id}` | **Admin** |
| GET | `/api/admin/locations/latest` | **Admin** — every user's last fix, for a map |
| POST | `/api/admin/users/{id}/unlock` | **Admin** — clear a lockout early |
| POST | `/api/admin/trips/recalculate` | **Admin** — re-measure trips with current smoothing, `?userId` |
| GET | `/health` | anonymous |

A user requesting another user's trip gets **404**, not 403 — trip ids cannot be probed to
learn who exists.

### Example

```bash
# Register (cookies land in the jar; the tokens are HttpOnly and unreadable to script)
curl -k -c jar.txt -X POST https://localhost/api/auth/register \
  -H 'Content-Type: application/json' \
  -d '{"email":"user@example.com","password":"StrongPass!123","displayName":"Test User"}'

CSRF=$(awk '$6=="csrf_token"{print $7}' jar.txt | tail -1)

# Report a position
curl -k -b jar.txt -c jar.txt -X POST https://localhost/api/locations \
  -H 'Content-Type: application/json' -H "X-CSRF-Token: $CSRF" \
  -d '{"latitude":30.0444,"longitude":31.2357,"accuracyMeters":5}'

# Current trip, if one is open
curl -k -b jar.txt https://localhost/api/trips/me/active
```

---

## Deploying to AWS EC2

The public deployment is one Ubuntu 24.04 `t3.micro` (`reem-server`, us-east-1) running the
same Docker Compose stack, behind an Elastic IP (`34.199.20.93`). Its security group
(`reem-sg`) allows SSH only from the owner's IP, plus HTTP and HTTPS from anywhere.

First-time setup on a fresh instance, after copying the repo to it:

```bash
cd ~/LocationTracker/server
PUBLIC_IP=<elastic ip> ./deploy/ec2-setup.sh   # Docker, swap, new .env secrets, certificate
sudo docker compose up -d --build
```

`ec2-setup.sh` generates its own secrets and admin password. It never reuses the local
`.env`, and it prints the admin credentials once. Swagger stays off (`SWAGGER_ENABLED=false`).
The certificate names the public IP, and its fingerprint must be listed in the iOS app's
`AppConfig.pinnedCertificateSHA256`.

Redeploying code from this machine. Only committed code is sent (`git archive`), and only
the two parts the server needs: `server/` and the admin page in `client/wwwroot/`. The
server's `.env` and certificates are gitignored, so they are never overwritten:

```bash
git archive HEAD server client/wwwroot \
  | ssh -i ~/.ssh/reem-key.pem ubuntu@34.199.20.93 'tar -xf - -C ~/LocationTracker'
ssh -i ~/.ssh/reem-key.pem ubuntu@34.199.20.93 'cd ~/LocationTracker/server && sudo docker compose up -d --build'
```

**One-time migration for a server deployed before the `client/`/`server/` split.** The
instance has `.env` and `nginx/certs/` at the top of `~/LocationTracker`. Move them into
`server/` once, before the first redeploy with the new layout:

```bash
cd ~/LocationTracker && mkdir -p server/nginx
mv .env server/.env && mv nginx/certs server/nginx/certs
```

`docker-compose.yml` pins the project name to `locationtracker`, so the existing containers
and the `locationtracker_pgdata` volume (the database) are reused, not recreated empty.

A t3.micro in standard credit mode is capped at about 10% CPU until it has earned credits,
which makes the .NET build crawl. Switch it to `unlimited` for the build and back to
`standard` afterwards (`aws ec2 modify-instance-credit-specification`). If your home IP
changes, update the SSH rule in `reem-sg`.

---

## Admin live map

**https://localhost/admin/** (or `https://<this PC's IP>/admin/` from another device). Sign in
with the seeded administrator from `.env`. The page shows every user's latest position,
refreshed every 5 seconds: green means on a trip, blue means seen in the last 5 minutes, and
grey means older than that. Click a user to see their last 500 points and their trips. Click a
trip to draw its path.

The page is static content in `client/wwwroot/admin/`, served by nginx. It is same-origin,
so it uses the normal cookie session, and every piece of data it shows comes from
`/api/admin/*`. Leaflet is bundled under `vendor/`. Only the map tiles come from
OpenStreetMap.

---

## iOS client

`client/ios/` is a SwiftUI app (iOS 17+) that signs a user in, records GPS in the foreground and
background, and uploads to `/api/locations/batch`. Trips are then detected by the server as
usual. It is an [xtool](https://github.com/xtool-org/xtool) SwiftPM project, so it builds on
Linux or WSL without a Mac.

1. Check `client/ios/Sources/LocationTrackerClient/App/AppConfig.swift`:
   - `defaultServerURL` is this PC's LAN address as the phone sees it (`ipconfig`). It can
     also be edited on the sign-in screen.
   - `pinnedCertificateSHA256` must match the current certificate:
     `openssl x509 -in nginx/certs/server.crt -noout -fingerprint -sha256`. Update it every
     time `generate-certs.sh` is re-run.
2. Build from WSL:
   ```bash
   cd /mnt/c/dev/LocationTracker/client/ios && ./package.sh
   ```
   This runs `xtool dev build` and wraps the result into an unsigned
   `LocationTrackerClient.ipa` on the Windows Desktop. `mkipa.py` stands in for
   `xtool dev build --ipa`, which needs `zip`, and a stock WSL Ubuntu doesn't have it.
3. Sideload the `.ipa` with your usual signing tool, then run it on an iPhone on the same
   network as the PC. Sign in, turn on **Share my location**, and choose **Always** when iOS
   asks, so tracking keeps going in the background.

Settings that were Xcode build settings live in `xtool.yml` (the bundle ID) and `Info.plist`
(background location, permission prompts, ATS). xtool merges `Info.plist` into the plist it
generates.

How it talks to the server:

- **Auth.** The login cookies are copied into the Keychain. API calls send the access token
  as `Authorization: Bearer`, which the server already accepts. A bearer request carries no
  cookies, so the CSRF check does not apply to it. On a 401 the app refreshes once (the
  refresh cookie plus the `X-CSRF-Token` header) and retries. Refreshes are single-flight,
  because refresh tokens rotate and a reused one revokes the whole session.
- **TLS.** The self-signed certificate names only `localhost`, but the phone connects by IP.
  Rather than turn validation off, the app accepts exactly one certificate: the one whose
  SHA-256 fingerprint is pinned. A publicly trusted certificate passes normal validation
  and never reaches the pin check.
- **Uploads.** Fixes are queued on disk and sent in batches of up to 500. With no network
  they keep queueing and go up the moment connectivity returns. The backlog survives the
  session expiring and is uploaded after the same user signs in again. Only an explicit
  sign-out, or a different user signing in, discards it.
  That is a few requests a minute, well inside the per-user write limit. The queue survives
  going offline and app restarts. Fixes worse than 150 m accuracy are dropped on the device.
- **Background.** The app uses the `location` background mode, with automatic pausing off so
  the server still sees the stop that ends a trip. A 150 m geofence (`CLMonitor`) around the
  last position, plus significant-change and visit monitoring, lets iOS relaunch the app
  after it has been terminated, swiped away or the phone restarted, as soon as the user
  moves. If the app stops anyway (for
  example, swiped away), a local "Location sharing stopped" notification fires within
  20 minutes. The app keeps pushing it back while it runs.
- **Notifications.** "Trip recorded" with the server's smoothed distance, duration and top
  speed when a trip ends. "Location sharing is on/off" with the reason (permission removed,
  signed out). "Offline" after a minute without internet, and "Back online" with the number
  of saved points uploaded. Each kind replaces its previous notification instead of piling up.
- **Icon.** `Resources/AppIcon.png` (1024×1024), wired in through `iconPath` in `xtool.yml`.
- **Battery.** GPS-level accuracy is used only while moving. After 3 minutes still, the app
  drops to about 100 m accuracy with a 50 m distance filter, which uses Wi-Fi and cell
  positioning with GPS mostly off. It then takes one heartbeat fix every 2 minutes, which
  keeps the user "online" on the admin map and gives the server the stillness points that
  close a trip. The admin map shows a user as offline 5 minutes after the server last heard
  from them (by receive time), even if a trip is still open. Uploads are batched every 30 seconds,
  or every 60 in Low Power Mode.

---

## Development without Docker

```bash
cd server
docker compose up -d db          # Postgres only; uncomment its ports first
cd src/LocationTracker.Api
dotnet run                        # reads appsettings.Development.json
```

Migrations:

```bash
dotnet ef migrations add <Name> --output-dir Data/Migrations
dotnet ef database update
```

`DesignTimeDbContextFactory` exists so `dotnet ef` does not execute `Program.cs`, which would
trip the startup signing-key validation and demand a reachable database just to scaffold.
Migrations are applied automatically at startup.

---

## Notes and limitations

- The TLS certificate is **self-signed** and suitable for local use only. Production wants a
  real certificate; the nginx config is otherwise unchanged.
- Rate-limiter state is per-instance and in-memory. Running more than one API container needs
  a distributed limiter, or the effective limit multiplies by the replica count.
- Migrations run at startup, which assumes a single instance applying them. Multi-replica
  deployments should run migrations as a separate step.
- Distance uses Haversine rather than PostGIS. Revisit if you want spatial queries such as
  "who is within 500 m of this point".
