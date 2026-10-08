This is a [Next.js](https://nextjs.org) project bootstrapped with [`create-next-app`](https://nextjs.org/docs/app/api-reference/cli/create-next-app).

## Getting Started

First, run the development server:

```bash
npm run dev
# or
yarn dev
# or
pnpm dev
# or
bun dev
```

Open [http://localhost:3000](http://localhost:3000) with your browser to see the result.

You can start editing the page by modifying `app/page.tsx`. The page auto-updates as you edit the file.

This project uses [`next/font`](https://nextjs.org/docs/app/building-your-application/optimizing/fonts) to automatically optimize and load [Geist](https://vercel.com/font), a new font family for Vercel.

## Learn More

To learn more about Next.js, take a look at the following resources:

- [Next.js Documentation](https://nextjs.org/docs) - learn about Next.js features and API.
- [Learn Next.js](https://nextjs.org/learn) - an interactive Next.js tutorial.

You can check out [the Next.js GitHub repository](https://github.com/vercel/next.js) - your feedback and contributions are welcome!

## Deploy on Vercel

The easiest way to deploy your Next.js app is to use the [Vercel Platform](https://vercel.com/new?utm_medium=default-template&filter=next.js&utm_source=create-next-app&utm_campaign=create-next-app-readme) from the creators of Next.js.

Check out our [Next.js deployment documentation](https://nextjs.org/docs/app/building-your-application/deploying) for more details.

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
