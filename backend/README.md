# FieldOps Backend

REST API for the FieldOps field-agent app (Peachblossoms Flutter capstone). Node 20+, Express, Postgres.

## Test credentials
| Agent | Email | Password | Data |
|---|---|---|---|
| Ada Okafor | `agent1@fieldops.test` | `FieldOps#2026` | 12 seeded jobs in every status |
| Tunde Bello | `agent2@fieldops.test` | `FieldOps#2026` | no jobs (empty-state testing) |

Demo-only accounts, created by the seed script.

## Run locally
```bash
cp .env.example .env      # set DATABASE_URL and JWT_SECRET
npm install
npm run seed              # applies db/schema.sql and seeds demo data
npm start
```
On boot the server applies `db/schema.sql` (idempotent) and, if `AUTO_SEED=true` and there are no users, seeds demo data.

## Environment
| Var | Purpose |
|---|---|
| `DATABASE_URL` | Postgres connection string |
| `JWT_SECRET` | Signs access tokens (required, server refuses to start without it) |
| `PORT` | Defaults to 3000 |
| `AUTO_SEED` | `true` seeds demo data into an empty database |

## Tests
```bash
npm test                                   # state machine unit tests; API tests skipped
TEST_DATABASE_URL=postgres://... npm test  # also runs API integration tests
```
**Warning:** the integration tests drop and recreate the `public` schema of `TEST_DATABASE_URL`. Never point it at real data.

## API
All errors: `{ "error": { "code": "...", "message": "...", "fields": { "field": "msg" } } }`.
Authenticated routes need `Authorization: Bearer <accessToken>`. Every job is scoped to its assigned agent (another agent's job returns 404).

### Auth
| Method | Path | Body | Result |
|---|---|---|---|
| POST | `/auth/login` | `{email, password}` | `{accessToken, refreshToken, expiresIn, user}`; 401 `invalid_credentials` |
| POST | `/auth/refresh` | `{refreshToken}` | new token pair (refresh tokens are single-use); 401 `session_expired` |
| POST | `/auth/logout` | `{refreshToken}` | 204 |

Access tokens last 15 min. Expired access tokens return 401 `token_expired` (refresh and retry); a failed refresh means sign in again.

### Jobs
| Method | Path | Notes |
|---|---|---|
| GET | `/jobs` | Query: `status` (comma list), `priority`, `q` (title/customer/location/description), `updatedSince` (ISO, for incremental sync), `limit` (≤100), `offset`. Returns `{items, total}` |
| GET | `/jobs/:id` | Job + `notes`, `evidence` metadata, `history` (status events), `allowedTransitions` |
| GET | `/dashboard` | `{counts, summary{total,pending,inProgress,completed}, important[], recent[]}` |
| POST | `/jobs/:id/status` | `{status, reason?, clientId?, occurredAt?}` |
| PUT | `/jobs/:id/form` | `{answers: {fieldKey: value}}`, keys must match the job's `requiredFields` |
| POST | `/jobs/:id/notes` | `{body, clientId?}` |
| POST | `/jobs/:id/evidence` | multipart: `kind` (`photo`/`document`), `file`, `clientId?`; or JSON `{kind:"text", text, clientId?}` |
| GET | `/jobs/:id/evidence/:eid/file` | Download file |
| DELETE | `/jobs/:id/evidence/:eid` | 204 |
| GET | `/health` | DB connectivity check |

### Job lifecycle
```
assigned    -> accepted | declined
accepted    -> in_progress | cancelled
in_progress -> completed | failed
completed, declined, cancelled, failed are final
```
- `declined`, `cancelled`, `failed` require a `reason` (422).
- `completed` is rejected with 422 `incomplete_job` (field-level `fields`) until every required field is filled and `evidenceRequired` items are submitted.
- Notes, form answers and evidence can only be changed while the job is `accepted` or `in_progress` (otherwise 409 `job_not_active`).
- Invalid transitions return 409 `invalid_transition`.

### Offline sync support
Send a client-generated UUID as `clientId` on status changes, notes and evidence. Replaying the same `clientId` returns the original result instead of creating a duplicate (status replays return the job unchanged), so the app can safely retry its queue. `occurredAt` records when a status change really happened on the device. Replay queued actions in order.

### Limits
- Files: 10 MB; photos jpeg/png/webp/heic; documents pdf/txt/doc(x)/xls(x).

## Known limitations
- Evidence files are stored in Postgres (`bytea`) for simplicity; move to object storage for production volume.
- No rate limiting on login, no admin API for creating jobs (seed script only).
- Last-write-wins on form answers; no server-side conflict detection.
