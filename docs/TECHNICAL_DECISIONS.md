# FieldOps: Technical decisions

Short record of the choices that matter and why. Each one names what was traded away.

## 1. Offline-first: the local database is what the UI reads
Screens never wait on the network. They read SQLite (`sqflite`), and a background sync keeps it fresh. This is what makes "previously available information stays accessible" true by construction, not by caching tricks.
- **Alternative rejected:** HTTP response caching. It can't represent "the user did something while offline".
- **Cost:** two copies of the data (server and device), so a conflict policy is needed (see 3).

## 2. Writes go through an outbox

```
tap -> validate locally -> outbox row (+ UUID) -> screen updates at once (overlay)
    -> sync when online -> server validates -> job re-fetched -> outbox row removed
```
Every user action (status change, note, form answers, evidence upload/removal) is stored in an `outbox` table and applied to the screen immediately (`applyOutbox` overlays pending actions on the last server snapshot). A `SyncService` replays the outbox in order.
- Network error, timeout or 5xx: stop, keep everything queued, retry later (connectivity regained, 45 s timer, pull-to-refresh, "Sync now").
- 4xx rejection (e.g. the job was cancelled by dispatch meanwhile): the item is marked **failed** with the server's message; the user can retry or discard. Nothing disappears silently, and one bad item does not block the rest.
- Evidence files are copied into app storage at capture time, so a picker temp file being cleaned up can't lose them.

## 3. Idempotency and conflicts
Each action carries a client-generated UUID (`clientId`). The server stores it with a unique index, so replaying after a lost response returns the original result instead of creating a duplicate. State conflicts are decided by the server state machine (409 `invalid_transition`); the app mirrors the same rules locally so most mistakes are caught before queuing. Form answers are last-write-wins (documented limitation). Each action also carries the device time it happened (`occurredAt`); the server caps it at its own clock, so a phone with a wrong clock cannot record events in the future.

## 4. Job lifecycle
`assigned → accepted | declined`, `accepted → in_progress | cancelled`, `in_progress → completed | failed`; the last four states are final.
- Decline / cancel / fail require a reason (they are decisions someone will ask about later).
- Notes, form answers and evidence only change while the job is accepted or in progress.
- `completed` requires the job's required fields and minimum evidence count. Enforced on the server (source of truth) and in the app (so it works offline).

## 5. State management: Riverpod
- Providers are the dependency-injection mechanism too, so tests swap the API/db with overrides, with no service locator.
- Data providers (`jobsProvider`, `jobProvider`) watch a `revision` counter that the repository bumps on every local change, so UI updates come from one reliable signal, not from each caller remembering to notify.
- **Alternatives:** Bloc (more boilerplate for this size), Provider (no compile-time safety / async story as good).

## 6. Layering
`domain/` (models, status rules, outbox overlay; pure Dart) → `data/` (API client, SQLite, repository, sync) → `state/` (Riverpod) → `features/` + `widgets/` (UI). UI never sees Dio; `AppException` is the only error type that crosses layers.

## 7. Auth and session handling
- Short-lived access token (15 min) + single-use, rotating refresh token, stored in Android Keystore-backed secure storage; never in SQLite or prefs.
- The API client refreshes ahead of expiry (important because multipart uploads can't be replayed) and on 401, single-flight so concurrent requests share one refresh.
- If the refresh token is rejected, the app returns to the login screen but **keeps queued work**; it syncs after the same agent signs in again. Signing in as a different agent wipes the local cache first.
- Backups are disabled and cleartext HTTP is off.

## 8. Backend
Node/Express + Postgres on Railway. Chosen because it deploys from the repo with no config, and Postgres gives transactional status changes (row lock on the job while validating the transition). Evidence bytes are stored in Postgres (`bytea`, 10 MB cap) to avoid a second moving part; at real volume this should move to object storage.

## 9. Testing
Tests focus on logic that can silently lose or corrupt field work: the lifecycle rules, the outbox overlay, the sync loop (offline, retry, rejection, crash recovery), repository validation, error mapping, filters, and the login form. There are 49 app tests and 12 backend tests (the backend ones run against a real Postgres). See README for how to run them. Not covered: real camera/file-picker integration and real device connectivity changes (manual test checklist in README).
