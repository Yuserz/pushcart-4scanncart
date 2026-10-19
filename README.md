# Pushcart Web

Next.js 16 (App Router) storefront, admin dashboard and POS self-checkout tablet, backed by
Supabase (Postgres, Auth, Storage, Realtime).

> **This project uses Yarn 1 (`yarn@1.22.22`).** The lockfile is `yarn.lock`. Do not run
> `npm install`, `pnpm install` or `bun install`: they ignore `yarn.lock` and create a second lockfile.

## Prerequisites

| Tool | Version | Notes |
| --- | --- | --- |
| Node.js | 20 or newer | CI uses 20. |
| Yarn | 1.22.22 | `corepack enable` picks up the version pinned in `package.json`, or `npm i -g yarn@1.22.22`. |
| Docker Desktop | running | Needed by the local Supabase stack. |
| `make` + a POSIX shell | optional | For the `make` shortcuts. On Windows use Git Bash. Every target has a plain `yarn` equivalent below. |

The Supabase CLI is a project dependency, so no global install is needed. Always call it as
`yarn supabase …`. It goes through `scripts/supabase.mjs`, which picks the right binary on Windows.

## Cloud development (default, no Docker)

Day-to-day work runs against the shared Supabase cloud project **pushcart-dev**
(ref `ssitglvklxcdxmgpeoti`, Tokyo), so the laptop does not run the Supabase containers.

1. `yarn install`
2. Get `.env.cloud` from a teammate (password manager, never git or chat) and put it in the
   project root. It holds the cloud URL and keys, `POS_INGEST_SECRET`, and the `SEED_*`
   account passwords and staff PIN.
3. `make dev`, which copies `.env.cloud` over `.env` and runs `yarn dev`.

The cloud is already migrated and seeded with the SCANnCART seven-class catalog (one product per
detector class, mapped in `product_class_map`), 12% VAT and station `counter-1`. Accounts:

| Account | Role | Password |
| --- | --- | --- |
| `admin@pushcart.test` | admin | `SEED_ADMIN_PASSWORD` in `.env.cloud` |
| `cashier@pushcart.test` | cashier (`user`) | `SEED_CASHIER_PASSWORD` in `.env.cloud` |
| guest | anonymous customer | none: the customer pages (`/customer`, **Start shopping**) sign in anonymously |

Changing the cloud (once per machine: `yarn supabase login` in a real terminal, then
`yarn supabase link --project-ref ssitglvklxcdxmgpeoti`):

| Task | `make` shortcut |
| --- | --- |
| Push new migrations | `make cloud-push` |
| Load the seed (re-runs only after `supabase/seeds` changes) | `make cloud-seed` |
| Create / reset the admin and cashier accounts and staff PIN | `make seed-accounts` |
| Push `[auth]` settings from `supabase/config.toml` | `make cloud-config-push` |

The cloud database is shared: try new migrations and run the e2e scripts on the local Docker
stack first (`make dev-local`, setup below), and never `db reset --linked`. A free-tier project
pauses after about a week without traffic; resume it from the Supabase dashboard.

## Local Docker setup (optional)

### 1. Install dependencies

```bash
yarn install
```

### 2. Start local Supabase and create `.env`

```bash
make setup-supabase
```

This starts the Supabase containers (the first start applies `supabase/migrations` and
`supabase/seeds`) and writes `.env` with the local URL and keys.

`make setup-supabase` **deletes and rewrites `.env`** every time it runs. Re-add any extra
variables (the `POS_*` ones below) afterwards.

<details>
<summary>Without make</summary>

```bash
yarn supabase start     # prints the API URL, keys and DB URL
```

Create `.env` in the project root from that output:

```dotenv
NEXT_PUBLIC_SUPABASE_URL=http://127.0.0.1:54321
NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY=sb_publishable_...   # "Publishable" key
SUPABASE_SECRET_KEY=sb_secret_...                         # "Secret" key, server only
NEXT_PUBLIC_SUPABASE_DB_URL=postgresql://postgres:postgres@127.0.0.1:54322/postgres
NEXT_PUBLIC_SUPABASE_TOKEN=127
NEXT_PUBLIC_DESTINATION=/auth/sign-in
NEXT_PUBLIC_APP_URL=http://localhost:3000
NEXT_IMAGE_PUBLIC_URL=http://127.0.0.1:54321/storage/**
```

Run `yarn supabase status` any time to see the values again.
</details>

### 3. Add the POS variables (only if you use the self-checkout)

Append to `.env` (details in [POS self-checkout integration](#pos-self-checkout-integration-scanncart)):

```dotenv
POS_INGEST_SECRET=<32+ hex chars, same as SCANnCART posSecret>
POS_STAFF_PIN=<4-8 digits, optional>
POS_IDLE_CANCEL_MINUTES=15
```

Generate a secret with `node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"`.

### 4. Create the accounts

The seed adds VAT, categories, the seven products and their class mapping, and station
`counter-1`, but no users. Add passwords to `.env`, then create the admin and cashier:

```dotenv
SEED_ADMIN_PASSWORD=<password>
SEED_CASHIER_PASSWORD=<password>
SEED_STAFF_PIN=<4-8 digits, optional>
```

```bash
make seed-accounts      # or: node scripts/seed-accounts.mjs
```

Sign in at <http://localhost:3000/auth/sign-in> as `admin@pushcart.test` or `cashier@pushcart.test`.

### 5. Run the app

```bash
yarn dev            # http://localhost:3000 (Turbopack, hot reload)
```

`/` redirects to `/auth/sign-in`. Restart `yarn dev` after editing `.env`.

## Daily workflow

| Task | Command | `make` shortcut |
| --- | --- | --- |
| Dev server on Supabase cloud | `cp .env.cloud .env`, then `yarn dev` | `make dev` |
| Local Supabase (rewrites `.env`) + dev server | `make setup-supabase`, then `yarn dev` | `make dev-local` |
| Start Supabase + dev server | `yarn supabase start`, then `yarn dev` | `make run-dev` |
| Stop Supabase | `yarn supabase stop` | `make stop-db` |
| Show Supabase URLs / keys | `yarn supabase status` | — |
| Lint | `yarn lint` | — |
| Production build | `yarn build` | `make build-app` (lint + build) |
| Serve the build | `yarn start` | `make start-app` |
| Supabase + production server | `yarn supabase start`, then `yarn start` | `make run-start` |
| Delete leftover anonymous shoppers | `yarn cleanup:anonymous` (add `--dry-run` to preview) | `make cleanup-anonymous` |
| Stop Supabase and remove `.env` | — | `make clean` |

Local Supabase: API `http://127.0.0.1:54321`, Studio `http://127.0.0.1:54323`,
mail catcher (Inbucket) `http://127.0.0.1:54324`, Postgres `127.0.0.1:54322`.

## Database changes

| Task | Command | `make` shortcut |
| --- | --- | --- |
| New empty migration | `yarn supabase migration new <name>` | `make migrate-new name=<name>` |
| Apply pending migrations | `yarn supabase migration up` | `make migrate-up` |
| Diff Studio edits into a migration | `yarn supabase db diff --local` | `make migrate-diff` |
| Rebuild DB from migrations + seeds | `yarn supabase db reset` | `make migrate-reset` |
| Print TypeScript types | `yarn supabase gen types typescript --local` | `make generate-types` |

`db reset` wipes everything, users included. Run `make seed-accounts` afterwards.

## Tests and checks

The app and Supabase must be running, with the `.env` values exported in your shell:

```bash
bash scripts/pos-e2e.sh                 # POS end to end (needs POS_INGEST_SECRET, POS_STAFF_PIN)
node scripts/customer-rls-e2e.mjs       # customer data isolation
node scripts/pos-admin-routes-e2e.mjs   # admin POS routes (POS_APP_URL, default http://localhost:3000)
node scripts/pos-contract.mjs           # POS API contract (also runs in CI)
```

## Troubleshooting

- **`Cannot find module '.../node_modules/supabase/bin/supabase'`**: use `yarn supabase …`,
  not `npx supabase`. If it persists, run `yarn install` again. `scripts/supabase.mjs` handles
  both the old `bin/` CLI layout and the newer `dist/supabase.js` one.
- **`yarn install` rewrote `yarn.lock`**: the committed lockfile is in Yarn Berry format while
  `package.json` pins Yarn 1, so Yarn 1 regenerates it. Discard it with `git checkout yarn.lock`.
- **`yarn supabase login` says "non-TTY"**: run it in a normal terminal window, not through an
  editor or agent shell.
- **`make dev` says `.env.cloud not found`**: get the file from a teammate (see
  [Cloud development](#cloud-development-default-no-docker)).
- **`supabase start` fails**: Docker Desktop is not running, or ports 54321–54327 are in use.
  Run `yarn supabase stop` and retry.
- **`Missing NEXT_PUBLIC_SUPABASE_URL …` or images not loading**: `.env` is missing or stale.
  Rerun `make setup-supabase` (or rebuild it from `yarn supabase status`) and restart `yarn dev`.
- **Signed in but no admin pages**: the profile's role is not `admin`. Rerun `make seed-accounts`.
- **POS routes return 401**: `POS_INGEST_SECRET` is unset or differs from SCANnCART's `posSecret`.
  Remember that `make setup-supabase` removes it from `.env`.

## Deploy

Any Node host or Vercel: set the same variables using a hosted Supabase project's URL and keys,
then `yarn build && yarn start`. Push migrations with `yarn supabase link` and
`yarn supabase db push`. Never expose `SUPABASE_SECRET_KEY`, `POS_INGEST_SECRET` or
`POS_STAFF_PIN` as `NEXT_PUBLIC_*`.

## POS self-checkout integration (SCANnCART)

The counter tablet runs inside this app at `/customer/<userId>/scan-start`, and the
SCANnCART desktop camera talks to the token-authenticated routes below. Configure:

| Variable | Purpose |
| --- | --- |
| `POS_INGEST_SECRET` | Shared secret the desktop sends as `x-pos-token`. 32+ hex chars; must match SCANnCART's `posSecret`. Server-only — never prefix with `NEXT_PUBLIC_`. |
| `POS_IDLE_CANCEL_MINUTES` | Optional. Minutes an open session may sit idle before the next *Start shopping* cancels it. Default `15`. |
| `POS_STAFF_PIN` | Optional. The **default** staff code (4–8 digits), used only until an admin sets one in POS Mapping (below). Empty and no admin code = staff removal off. Server-only. |

### Staff code

Customers cannot edit a camera-managed cart. When the camera misses a removal, staff tap
**Staff** on the cart tablet, enter the **staff code**, and tap **Remove 1** on the line. It can
only lower a quantity, is logged (`pos_sync_log.kind = staff_edit`), and stops the camera
managing that product for the rest of the session. Five wrong codes lock it on that cart for a minute.

**Changing the code (no restart):** sign in as an admin → `/admin/<userId>/pos-mapping` →
**Staff code** card → type the new code twice → **Set** / **Change**. It works on the tablet
immediately. **Remove this code** returns to the server default (`POS_STAFF_PIN`), or turns staff
removal off when there is none.

The card shows which code is in force (*Set here*, *Server default* or *Off*) and when it
changed, never the code itself: it is stored as a bcrypt hash in `pos_settings` (migration
`20261005000000_pos_staff_pin.sql`), settable only by database functions that check
`is_admin()`. A forgotten code is replaced, not recovered. Give the code to staff in person;
do not write it into this repository.

Routes:

| Route | Auth | Purpose |
| --- | --- | --- |
| `GET /api/pos/session?station_id=…` | `x-pos-token` | Open session for a counter, or `data: null` when unbound. |
| `POST /api/pos/sync` | `x-pos-token` | Desired cart snapshot; reconciles camera rows in one Postgres transaction. |
| `/api/protected/station-session` | cookie | Open / read the customer's own session. |
| `/api/protected/stations` | cookie | Station picker. |
| `/api/protected/station-session/items/[productId]` | cookie | Customer edit (records an override). |
| `/api/protected/station-session/finish` | cookie | Stock check, order, session complete. |
| `/api/protected/pos-stations`, `/api/protected/pos-mapping` | cookie (admin) | Admin CRUD; the mapping screen lives at `/admin/<userId>/pos-mapping`. |

The desktop points at whichever host serves this app (`posBaseUrl`): `http://<lan-ip>:3000`
when it runs in Docker on the shop LAN, or an HTTPS host when deployed to the cloud. If the
host is not localhost, use HTTPS — the secret travels in a header. See SCANnCART's
`docs/POS_INTEGRATION.md` for setup and troubleshooting.
