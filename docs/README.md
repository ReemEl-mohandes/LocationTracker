# Documentation

Deep technical documentation for the Location Tracker project. Read in this order if you are new:

1. **[DEVELOPER_GUIDE.md](DEVELOPER_GUIDE.md)** — the whole system: architecture, the iOS
   background-execution model, the scenario matrix, and how to build/sign/deploy.
2. **[SETUP_GUIDE.md](SETUP_GUIDE.md)** — every environment and every command: local server,
   WSL + xtool toolchain, signing/sideloading, AWS EC2, git, troubleshooting.
3. **[CLIENT_INTERNALS.md](CLIENT_INTERNALS.md)** — the iOS app file by file, variable by
   variable, function by function, plus a guided walk through the exact Swift/iOS commands that
   turn each capability on.
4. **[SERVER_INTERNALS.md](SERVER_INTERNALS.md)** — the ASP.NET Core backend file by file:
   pipeline, auth, ingestion, trip detection, Kalman smoothing, rate limiting, background sweeper.
5. **[FEATURES_AND_LIMITS.md](FEATURES_AND_LIMITS.md)** — what works, the deliberate limits, the
   hard iOS platform limits (and why), what's missing, what's blocking each gap, and priorities.

The top-level [../README.md](../README.md) remains the quick-start and API reference.
