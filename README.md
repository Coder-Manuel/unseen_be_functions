# Zuru — Backend

The Supabase backend for Zuru: the Postgres schema, row-level security, database functions and cron jobs, plus the Deno edge functions for streaming, payments and push notifications.

| Repo | What |
| --- | --- |
| [`zuru`](https://github.com/Coder-Manuel/zuru) | Flutter app (Viewer and Guide) |
| [`unseen_be_functions`](https://github.com/Coder-Manuel/unseen_be_functions) | This backend |
| [`zuru-web`](https://github.com/Coder-Manuel/zuru-web) | Marketing site |

**Stack:** Supabase (Postgres 17, Auth, Storage, Realtime, `pg_cron`, `pg_net`, Vault, PostGIS), Edge Functions on Deno, LiveKit for streaming, M-Pesa Daraja and IntaSend for payments, Firebase Cloud Messaging for push.

> There is a single hosted project, `unseen`, and it is **production**. There's no hosted staging yet, so develop against the local stack and treat every remote command (`db push`, `functions deploy`, `secrets set`) as a production change.

## Prerequisites

| Tool | Version | Notes |
| --- | --- | --- |
| [Supabase CLI](https://supabase.com/docs/guides/local-development/cli/getting-started) | **3.x** (tested with 3.4.0) | `brew install supabase/tap/supabase`. `config.toml` uses 3.x keys such as `[local_smtp]`. |
| Docker Desktop (or OrbStack) | latest | Runs the local stack. Keep 10 GB or more free for the images. |
| [Deno](https://deno.com) | 2.x | For editor support, linting and running functions outside the stack. |
| VS Code + Deno extension | | `.vscode/` sets the extension up for `supabase/functions`. |

## Setup

```bash
git clone git@github.com:Coder-Manuel/unseen_be_functions.git
```

```bash
cd unseen_be_functions && git checkout dev
```

```bash
supabase start
```

`supabase start` runs Postgres and the other services in Docker, then applies every file in `supabase/migrations` in order. When it finishes it prints the local URLs and keys:

| Service | URL |
| --- | --- |
| API (also used by the apps) | http://127.0.0.1:54321 |
| Postgres | `postgresql://postgres:postgres@127.0.0.1:54322/postgres` |
| Studio | http://127.0.0.1:54323 |
| Email testing (Mailpit) | http://127.0.0.1:54324 |

To point the mobile app at your local stack, set `SUPABASE_URL` and `SUPABASE_ANON_KEY` in its `.env` to these values. A physical device needs your machine's LAN IP instead of `127.0.0.1`.

Other local commands:

| Task | Command |
| --- | --- |
| Rebuild the database from the migrations | `supabase db reset` |
| Stop the stack (data is kept) | `supabase stop` |
| Serve edge functions with hot reload | `supabase functions serve --env-file supabase/functions/.env` |
| Lint and format functions | `deno lint supabase/functions` and `deno fmt supabase/functions` |

Only maintainers need to link the hosted project:

```bash
supabase login
```

```bash
supabase link --project-ref <ref from the project lead>
```

### Secrets

Nothing secret is committed. Ask the project lead for the values.

**Edge function secrets.** For local work, put them in `supabase/functions/.env`, which is gitignored. In production they're set with `supabase secrets set`. `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are injected automatically.

| Secret | Used by |
| --- | --- |
| `LIVEKIT_URL`, `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET` | `go-live`, `end-session`, `end-livekit-room`, `livekit-webhook` |
| `RECORDINGS_BUCKET`, `RECORDINGS_S3_ENDPOINT`, `RECORDINGS_S3_REGION`, `RECORDINGS_S3_ACCESS_KEY`, `RECORDINGS_S3_SECRET` | `livekit-webhook` (stream recordings) |
| `MPESA_BASE_URL`, `MPESA_CONSUMER_KEY`, `MPESA_CONSUMER_SECRET`, `MPESA_SHORTCODE`, `MPESA_PASSKEY`, `MPESA_TRANSACTION_TYPE`, `MPESA_CALLBACK_SECRET` | `mpesa-stk-push`, `mpesa-callback` |
| `INTASEND_BASE_URL`, `INTASEND_PUBLIC_KEY`, `INTASEND_SECRET_KEY`, `INTASEND_REDIRECT_URL`, `INTASEND_WEBHOOK_CHALLENGE` | `intasend-collect`, `intasend-payout`, `intasend-webhook` |
| `FIREBASE_SERVICE_ACCOUNT` | `send-fcm` |
| `UNSEEN_FN_KEY` | Verifies service tokens on internal functions (`send-fcm`, `intasend-payout`, `end-livekit-room`) |
| `SB_JWT_ISSUER` | Optional. Overrides the expected issuer of user JWTs. |

**Vault secrets.** Database functions call edge functions through `pg_net`, and they read two secrets from Vault:

| Vault secret | Value |
| --- | --- |
| `app_supabase_url` | The project URL. Locally, from inside Docker: `http://host.docker.internal:54321` |
| `service_api_key` | An HS256 JWT signed with `UNSEEN_FN_KEY`, with `iss: "unseen-internal"` and `role: "service"` |

Set them locally once, from Studio's SQL editor:

```sql
select vault.create_secret('http://host.docker.internal:54321', 'app_supabase_url');
select vault.create_secret('<service token>', 'service_api_key');
```

Without them, notifications, payouts and session expiry log a warning and do nothing.

## Project structure

```text
supabase/
├── config.toml                 Local stack settings and per-function config
├── migrations/                 Schema history, applied in filename order
│   ├── 20261017000000_initial_migration.sql   Baseline: the schema before the first tracked migration
│   └── <timestamp>_<name>.sql
└── functions/
    ├── _shared/                Code shared by functions, imported as "shared"
    │   ├── jwt/                Client (user JWT) and service auth middleware
    │   ├── mpesa/, intasend/   Payment provider clients and types
    │   ├── fcm/                FCM client
    │   └── notifications/      Notification templates
    └── <function>/
        ├── index.ts            Entry point (Deno.serve)
        ├── deno.json           Import map, including "shared": "../_shared/index.ts"
        └── deno.lock
```

### Edge functions

| Function | Called by | JWT verified by the gateway | What it does |
| --- | --- | --- | --- |
| `go-live` | App | Yes | Issues LiveKit tokens to join a mission's room |
| `end-session` | App (guide) | Yes | Ends a live check for both sides |
| `end-livekit-room` | Database | No (service token) | Deletes the LiveKit rooms of expired sessions |
| `livekit-webhook` | LiveKit | No (verifies the LiveKit signature) | Tracks room, participant and recording events |
| `mpesa-stk-push` | App (viewer) | Yes | Starts an M-Pesa STK push for a mission |
| `mpesa-callback` | Safaricom | No (shared-secret query parameter) | Finalises an M-Pesa payment |
| `intasend-collect` | App (viewer) | Yes | Collects payment by M-Pesa or card through IntaSend |
| `intasend-webhook` | IntaSend | No (challenge, then re-fetches the status) | Finalises IntaSend payments and payouts |
| `intasend-payout` | Database cron | No (service token) | Pays a guide their share after commission |
| `send-fcm` | Database | No (service token) | Delivers one queued notification |

### Rules

**Migrations**
- Every schema change is a migration. Never change the hosted database by hand in Studio.
- Create one with `supabase migration new <snake_case_name>`, which adds the timestamp prefix.
- Never edit a migration that has been pushed. Write a new one.
- Write idempotent SQL: `create table if not exists`, `add column if not exists`, `create or replace function`, `drop policy if exists` before `create policy`, `drop trigger if exists` before `create trigger`, and unschedule a cron job by name before scheduling it.
- Every new table enables RLS and gets explicit policies. `SECURITY DEFINER` functions set `search_path` and `revoke` execute from roles that shouldn't call them.
- Run `supabase db reset` before opening a PR. It must replay every migration from scratch without errors.

**Edge functions**
- One folder per function, with its own `deno.json` and an entry in `config.toml` (`verify_jwt`, `import_map`, `entrypoint`).
- Shared code goes in `_shared` and is exported from `_shared/index.ts`.
- A function the apps call keeps `verify_jwt = true`. A function called by a third party or by the database turns it off and checks its own signature, secret or service token.
- Treat request bodies as untrusted. Load prices, ownership and status from the database.
- Webhooks and callbacks must be idempotent, because providers retry.
- Read configuration from `Deno.env`, never hard-code it, and add any new secret to the table above.
- Comment only what the code can't say: a non-obvious reason, a workaround, a provider contract.

## Deploying

Maintainers deploy from `master` after a release PR merges:

```bash
supabase db push
```

```bash
supabase functions deploy <function-name>
```

```bash
supabase secrets set NAME=value
```

Run `supabase migration list --remote` first to compare the local and remote history. `db push` applies only the migrations the remote doesn't have yet.

> **One-time step for the baseline.** `20261017000000_initial_migration.sql` describes a schema that production already has. Before the first `db push` after it lands, mark it as applied, or the push will refuse:
>
> ```bash
> supabase migration repair --status applied 20261017000000
> ```

## Contributing

The same process applies to all three repos.

### Branches

| Branch | Purpose |
| --- | --- |
| `master` | Production. Changes arrive only through a release PR from `dev`. |
| `dev` | Integration. Every feature branch starts here and merges back here. |
| `<type>/<short-description>` | Your work, e.g. `feat/guide-payouts`, `fix/mpesa-callback-retry`. |

`<type>` is one of the commit types below. Keep branches short-lived and rebase on `dev` when they fall behind.

### Commits

Use [Conventional Commits](https://www.conventionalcommits.org): `type(scope): summary`

- **type:** `feat`, `fix`, `perf`, `refactor`, `docs`, `style`, `test`, `chore`, `ci`
- **scope** (optional): the area, e.g. `payments`, `livekit`, `notifications`, `migrations`
- **summary:** imperative and lower case, with no trailing period

```text
feat(payments): add platform commission and automatic guide payouts
fix(payments): run payment_statements as the querying user
```

### Pull requests

1. Open the PR against `dev`, with a title in the commit format.
2. Say what changed and why. For a migration, say what it does to existing rows and whether the apps must update first.
3. `supabase db reset` replays cleanly, and any function you touched passes `deno lint` and `deno fmt --check`.
4. Get at least one approving review. A maintainer merges and deploys.

Never commit secrets, `.env` files or service-account JSON.

## Versioning and releases

Releases follow [Semantic Versioning](https://semver.org) and are tagged on `master`:

- **MAJOR**: a breaking change to an API, RPC or table the apps use, so older app versions stop working.
- **MINOR**: a new function, RPC, table or column.
- **PATCH**: fixes and internal changes.

To release:
1. Open a PR from `dev` to `master` titled `chore: release vX.Y.Z`.
2. After it merges, deploy (see Deploying).
3. Tag the release on `master` (`git tag vX.Y.Z && git push origin vX.Y.Z`).

Ship backend changes before the app versions that depend on them, and keep them working for app versions still in use.
