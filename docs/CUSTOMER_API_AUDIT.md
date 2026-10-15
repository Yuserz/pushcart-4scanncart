# Customer API authorization audit — 2026-10-02

## Scope and evidence

Audited customer-accessible Next.js APIs with two real anonymous customer cookies against the local app/Supabase. The existing POS end-to-end harness reproduced the gaps before fixes: 34 passed, 12 failed. Replay after fixes: **57 passed, 0 failed**. This is an API-boundary audit, not certification of the database or every staff/admin flow.

### Confirmed before fixes

- GET `/api/protected/cart/:id` and `/cart/get_one/:id` returned another customer's cart with HTTP 200.
- Legacy cart status PUT, item quantity PUT, item insert POST and item DELETE accepted another customer's IDs with HTTP 200. The delete probe used a disposable row.
- `/profiles` exposed the directory and `/profiles/update/:id` accepted another customer's profile update.
- `/pos-overview` exposed other sessions and edit history to a customer.
- Middleware treated cookie presence as authentication, with no verified user/role boundary. A forged cookie reached page-style redirect behavior instead of API 401.
- Orders/dashboard were reachable by customers (returning query/runtime errors rather than an authorization refusal). Code inspection confirmed there was no role check before privileged queries.

## Changes

- Protected API middleware verifies the Supabase user and checks database profile role. Anonymous users are never treated as staff/admin solely because their profile uses role `user`.
- Customer routes are explicitly allowed; other protected APIs require admin, except legacy orders for authenticated non-anonymous staff.
- Shared `cartAccess`/`cartItemAccess` checks permit the cart customer, assigned cashier, or verified admin. Both legacy reads and all legacy cart/item writes use them.
- Cart list is scoped to caller ownership/assignment unless admin; staff order list is scoped to `user_id`; legacy order creation checks cart assignment and submitted order user.
- Customers cannot use cart status updates to mark a cart paid or assign another anonymous customer as cashier.
- Own profile editing rejects role changes; foreign profile edits are blocked before model/file side effects.
- Customer cashier picker no longer consumes the full profile directory. `/cashiers` returns only IDs of non-archived user profiles with email, with account validation on assignment.
- Server Axios now actually serializes the current request's cookies; verified API authentication needs the same identity for server-rendered shopping requests.

## Verification

- 57/57 real-request checks in `scripts/pos-e2e.sh`: foreign and own cart reads, malformed IDs, legacy foreign writes, forbidden profile/order/overview/dashboard access, forged auth cookie, self-promotion, payment bypass, own legacy edit, public customer catalog/directory reads, plus existing POS reconcile/edit/finish/stock checks.
- Typecheck, focused ESLint for new authorization/core routes, production build, recorded POS contract check, shell syntax and whitespace checks passed.
- The existing component naming-rule lint issue remains in the cashier component (outside the authorization changes); the profile model passes focused lint. No claim that repository-wide lint is clean.
- Admin and registered-cashier paths were reviewed in code but not exercised with real staff credentials in this audit; assignment/admin exceptions require a separate role-matrix replay.

## Important unresolved risks

1. **Follow-up database repair applied locally.** Migration `20261002150000_customer_data_isolation.sql` removes the old permissive policies on profiles/carts/cart_items/orders, replaces them with owner/assigned-cashier/admin access, denies direct customer order creation, and guards role/ownership/payment changes with triggers. `scripts/customer-rls-e2e.mjs` reproduced 9 failing direct-token checks before the repair; after it, 29 checks pass using two real anonymous tokens plus temporary registered cashier/admin tokens. The script cleans its own fixtures and refuses non-local Supabase URLs. The migration has NOT been deployed to a cloud/production project. Storage policies and privileged RPCs outside POS are not covered by this result.
2. The general server client uses a service-role key. Every route doing privileged work must retain an explicit permission boundary; API middleware alone does not constrain direct database access or calls to model functions outside routes.
3. Default production service-worker caching of API responses was not audited. Shared-device sign-out/cache isolation remains a separate test.
4. Legacy order creation still trusts staff-supplied totals and updates paid status separately from order insertion. This audit adds assignment authorization, not transactional money correctness.
5. Avatar mutation accepts client-supplied old image paths in the existing profile model. Cross-profile route access is blocked, but storage-path ownership was not audited.

## Ownership and side effects

Authorization lives in the middleware (route/role boundary) and `app/api/helpers/cart-access.ts` (cart ownership). Financial reconciliation remains in the existing POS RPCs. The shopping UI changed only to use a minimal directory instead of private profile data.

The pre-fix profile probe changed the synthetic first customer's name; all probes used locally created test customers/products/stations. The harness retains synthetic completed orders and fixtures as it already did. No production/cloud database or real shopper account was touched. Changes are uncommitted, and prior playtest changes were preserved.
