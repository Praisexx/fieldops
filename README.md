# FieldOps

Mobile app for Peachblossoms field agents to receive, execute and report on operational assignments, including in places with poor or no connectivity.

Repo layout
- `app/`: Flutter (Android) application
- `backend/`: Node/Express + Postgres API (see [backend/README.md](backend/README.md) for the full API reference)
- `docs/TECHNICAL_DECISIONS.md`: major technical decisions and trade-offs

## Features
- Sign in / sign out, session kept between launches, automatic token refresh, clear feedback for wrong password, offline, timeouts and expired sessions
- Dashboard: assigned / pending / in-progress / completed counts, jobs needing attention (by priority and due date), recently updated jobs
- Jobs: search, filter by status and priority, full job details (customer, location, instructions, due date, assignment info)
- Job lifecycle with enforced rules: accept or decline, start or cancel, complete or report failure (reasons required where it matters)
- Required information per job type, notes, evidence (photo from camera or gallery, documents, text) with upload progress, retry and removal
- Activity feed of everything the agent did
- Works offline: browse everything previously loaded, keep working, and changes sync automatically when connectivity returns

## Setup
Requirements: Flutter (stable, Dart ^3.13), Android SDK.
```bash
cd app
flutter pub get
flutter run                      # uses the deployed API by default
flutter test
flutter build apk --release      # build/app/outputs/flutter-apk/app-release.apk
```
Point at a different API (for example a local backend on the Android emulator):
```bash
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:3000
```
(Release builds block cleartext HTTP, so use HTTPS for anything but local debug.)

Backend: see [backend/README.md](backend/README.md). The deployed API is at `https://api-production-7e8d.up.railway.app`.

## Test credentials
| Email | Password | Notes |
|---|---|---|
| `agent1@fieldops.test` | `FieldOps#2026` | 12 jobs in every status |
| `agent2@fieldops.test` | `FieldOps#2026` | no jobs (empty state) |

Demo accounts only. They are seeded by the backend.

## Technologies
Flutter, Riverpod (state), Dio (HTTP), sqflite (local database), flutter_secure_storage (tokens), connectivity_plus, image_picker, file_picker. Backend: Node, Express, Postgres, JWT, Zod, Railway.

## Architecture
```
lib/
  core/      config, theme, formatting, AppException (single error type)
  domain/    models, job status rules, outbox overlay          (pure Dart)
  data/      ApiClient, LocalDb (SQLite), JobRepository, SyncService, token storage
  state/     Riverpod providers and controllers
  features/  auth, shell, dashboard, jobs, activity            (screens)
  widgets/   shared UI (status chips, job card, empty/error states)
```
UI → providers → repository → (SQLite | API). The UI only reads the local database; the network only feeds it.

## State management
Riverpod. Notifiers for auth, sync and filters; `FutureProvider`s for data that reload when the repository bumps a revision counter after any local change. Providers also provide dependency injection, so tests replace the API or database with overrides.

## API information
Full reference in [backend/README.md](backend/README.md). Used by the app: `/auth/login|refresh|logout`, `GET /jobs`, `GET /jobs/:id`, `POST /jobs/:id/status`, `PUT /jobs/:id/form`, `POST /jobs/:id/notes`, `POST|DELETE /jobs/:id/evidence`, `GET /jobs/:id/evidence/:eid/file`. The server enforces the lifecycle and returns errors as `{error: {code, message, fields}}`.

## Offline approach
1. **Read path:** the app reads SQLite. After every sync it stores the job list and every job's detail (notes, evidence, history), so everything seen online opens offline. Search and filters run locally.
2. **Write path:** every action goes into an `outbox` table and is applied to the screen immediately; pending items show "waiting to sync".
3. **Sync:** runs on app start, when connectivity returns, every 45 s while anything is queued, on pull-to-refresh and from the banner's "Sync now". Items replay in order. Transient failures keep items queued; server rejections mark them *failed* with the reason, and the job screen offers Retry / Discard.
4. **Safety:** each action has a client UUID so replays never duplicate data; evidence files are copied into app storage before queuing; an expired session keeps queued work until the agent signs in again.
Details and trade-offs: [docs/TECHNICAL_DECISIONS.md](docs/TECHNICAL_DECISIONS.md).

## Testing approach
`flutter test` runs unit and widget tests focused on the risky logic:
- lifecycle rules and completion requirements
- the outbox overlay (what the agent sees while offline)
- the sync service: ordered replay, offline stop, retry reusing the same clientId, server rejection → failed, crash recovery, expired session
- repository validation (invalid transitions, reasons, 10 MB limit, queued evidence handling)
- API error mapping (timeouts, offline, 4xx/5xx)
- search/filter/sorting and the login form (validation, wrong password, offline)

Backend tests (`backend/`, `npm test`) cover the state machine and the full API flow against a real Postgres.

Manual checklist for what automated tests can't see: toggle airplane mode while working a job, take a photo, restore the connection and watch it upload; sign in on a small and a large device; rotate; large font size.

## Environment configuration
- App: `API_BASE_URL` via `--dart-define` (defaults to the deployed API). No secrets are in the app.
- Backend: `DATABASE_URL`, `JWT_SECRET`, `PORT`, `AUTO_SEED` (see `backend/.env.example`). Secrets live in Railway variables, never in git.

## Known limitations
- Documents can be attached and uploaded but not previewed in the app (photos and text can).
- Evidence is stored in the database (10 MB per file); fine for this scale, not for large volume.
- Form answers are last-write-wins; no merge UI if two devices edit the same job.
- Connectivity is detected via the OS network state plus request failures; a captive portal looks "online" until a request fails.
- No push notifications; new assignments appear on the next sync/pull.
- No rate limiting on login; no admin tooling for creating jobs (seed script only).
- Android only.
