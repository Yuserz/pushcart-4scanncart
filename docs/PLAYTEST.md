# Customer checkout playtest — 2026-10-02

Scope: real browser sessions against Next.js dev on 3000 and a production build served on 3001, with local Supabase and SCANnCART running. No mocked UI or new test framework.

## Observed defects and fixes

1. **Foreign cart disclosure.** A second anonymous customer could GET the first customer's cart items with HTTP 200, including quantities, prices and images. The shared cart-items read route now validates the UUID and checks the authenticated caller against the cart's customer/user ownership. Replay: foreign read 403, malformed ID 400, own read 200. Added these cases to the existing POS e2e harness.
2. **False empty cart.** Invalid cart URL returned 500 with an empty body, while the UI silently showed “Place an item on the counter” and zero totals. The route now returns its error response; the UI distinguishes loading, failed refresh and missing/mismatched open session from a valid empty cart, supplies Return to start, and prevents Finish while the read is unavailable.
3. **Wrong API origin.** Production UI on port 3001 sent XHR to the configured port 3000 and failed. Browser Axios now uses relative requests; server requests retain the configured base URL. Production replay: session/cart/VAT requests all reached 3001 and returned 200.
4. **Lost rapid quantity clicks.** Double-clicking + from 1 sent two writes of 2. Mutation controls now disable during a pending edit, with a synchronous in-flight guard; polling does not start new reads during edits. Replay: double-clicking minus from 2 performed one accepted edit to 1, which survived reload. This is intentionally one action at a time, not a queued tap counter.
5. **Unnamed controls.** Accessibility tree exposed three anonymous buttons per item. Added product-specific accessible names to decrease, increase and remove buttons.
6. **Stranded customer on return to Start.** Start unconditionally signed out and created a fresh customer, then encountered the current customer's busy station. Start now resumes the cookie owner's open session before creating another customer. Replay resumed the same cart with unchanged quantities.

## Other flows exercised

- Fresh visitor entry renders Start shopping.
- Busy station presents “Counter busy”.
- Live scanner delivered Safeguard into a new customer's cart; image/name/price rendered.
- Seeded Century Tuna image loaded; 1 x 42 produced subtotal 42, VAT 5.04, total 47.04.
- Reload preserved the manually edited quantity.
- Finish completed checkout and returned to Start after sign-out/countdown. Browser coordinate clicks were unreliable; the successful final action invoked the rendered button's click handler through the DOM.
- Production stock-shortage test displayed the specific product needing staff. Removing the test quantity returned to a valid empty cart with Finish disabled.
- Existing e2e suite plus three regression assertions: **34 passed, 0 failed** against production on 3001.
- Typecheck, focused ESLint, production build and POS recorded-contract check passed.

## Remaining user stumbling blocks

- No customer-facing cancel/reset action for an empty abandoned checkout. Busy-counter recovery may require staff or idle expiry. Resuming a cookie-owned open cart cannot decide whether the person holding the shared tablet is the same customer.
- Live detections can disappear/reappear as the model loses the item. The UI says items appear automatically but does not explain the removal rule or that a manual edit takes ownership away from the camera.
- Header exposes a long cart UUID and a sidebar toggle rather than a checkout-specific navigation surface.
- Start still chooses the first configured station. Multiple counters need explicit tablet/station binding; this playtest did not change that policy.
- Production service worker uses default API caching. Offline/cache behavior was not exercised, so no claim of offline correctness is made.
- The seeded catalog is local and its prices are demo values, not confirmed store prices.

## Structural health

- `app/customer/[userId]/scan-start/page.tsx` owns customer creation/session opening/resumption.
- `app/customer/[userId]/[cartId]/scan/page.tsx` owns polling, local presentation, quantity mutation and Finish/countdown. It is growing into a small state machine; future lifecycle changes should not be scattered through more booleans without explicit states.
- `services/pos/pos.services.ts` owns typed HTTP calls/error translation.
- `app/api/protected/cart_items/[id]/[status]/route.ts` owns this cart read and now its authorization. It is shared with the older shopping surface, so the owner/associated-user rule is deliberately broader than a POS-only customer check.
- `app/api/model/pos_sync.ts` translates RPC results to HTTP; the POS SQL migration owns transactional reconciliation, edits, ownership and order/stock changes. Money rules remain there, not in the scanner/UI.
- `app/api/axios-client/index.ts` is shared transport; origin selection belongs here rather than patched into individual POS calls.
- Browser transport living under `app/api`, and VAT calculation imported from another UI page's directory, are existing ownership smells. They were not moved for this playtest.
- `config/index.ts` uses a service-role key for the general server client: request authentication does not by itself guarantee row ownership. This observed read leak was fixed explicitly; other routes were not audited.

## Test side effects

The prior live session was completed through Finish, creating a real local test order and deducting its cart's stock. A new browser-created session remains open for further scanning; the 61-unit shortage probe was removed without purchasing it. The existing e2e harness retains its own synthetic station/product/completed order as usual. No production/cloud database was accessed. Temporary production server/log and build-generated service-worker changes are cleaned up after testing.
