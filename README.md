# Location Tracker API

A .NET 9 backend where regular users report their GPS position over time and administrators
track them. Raw points are rolled up automatically into **trips**: the server notices when a
user starts moving, accumulates distance as points arrive, and closes the trip with a total
distance and duration when they stop.

Stack: ASP.NET Core 9 · ASP.NET Core Identity · EF Core 9 · PostgreSQL 16 · nginx (TLS) · Docker Compose.

---

## Running it

```bash
cp .env.example .env        # then edit every value
./generate-certs.sh         # self-signed cert for nginx, once
docker compose up -d --build
./smoke-test.sh             # end-to-end verification
```

The API is reachable at **https://localhost**. The certificate is self-signed, so pass
`-k` to curl or trust it explicitly. Plain HTTP on port 80 redirects to HTTPS.

Swagger is served at `/swagger` in Development only (`ASPNETCORE_ENVIRONMENT=Development`).

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

`TripDetector` runs on every ingested point, inside the transaction that stores it.

1. Compare against the previous point: Haversine distance, elapsed time, implied speed.
2. **Reject noise before it becomes distance.** A segment is discarded if it is shorter than
   `MinDisplacementMeters` (15 m), if the reported accuracy is worse than the displacement,
   or if the implied speed exceeds `MaxPlausibleSpeedMps` (70 m/s — a GPS teleport, not a car).
   Without these gates a stationary phone accumulates kilometres of phantom travel overnight.
3. Surviving segments at or above `MovingSpeedMps` count as movement. The first one **opens a
   trip at the previous point**, not the current one, so the leg just travelled is included.
4. Stillness beyond `IdleTimeoutMinutes` (5) closes the trip **at its last moving point**, so
   time spent idling at the destination is not counted as travel time.
5. A silence longer than `GapTimeoutMinutes` (15) closes the trip with `ReportingGap` rather
   than bridging the unknown interval with a straight line.
6. On close, trips shorter than `MinTripDistanceMeters` (100 m) are deleted and their points
   detached. Raw history always survives; only the derived rollup goes away.

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

## Development without Docker

```bash
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
