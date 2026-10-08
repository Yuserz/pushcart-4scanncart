#!/usr/bin/env bash
# POS self-checkout end-to-end check (spec §7).
#
# Requires a running pushcart-web and a reachable Supabase. Seeds its own station,
# product and class mapping, then walks the integration and asserts each step.
#
# Env:
#   APP_URL                 default http://localhost:3000
#   POS_INGEST_SECRET       required; must match the app's .env
#   NEXT_PUBLIC_SUPABASE_URL  default from the environment
#   SUPABASE_SECRET_KEY       default from the environment
#   NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY  for the customer's own direct-write probe
#   POS_STAFF_PIN           required; must match the app's .env (staff removal)
#
# Usage: bash scripts/pos-e2e.sh
set -uo pipefail

APP_URL="${APP_URL:-http://localhost:3000}"
SB_URL="${NEXT_PUBLIC_SUPABASE_URL:-}"
SB_KEY="${SUPABASE_SECRET_KEY:-}"

if [[ -z "${POS_INGEST_SECRET:-}" ]]; then
  echo "POS_INGEST_SECRET is required" >&2
  exit 2
fi
if [[ -z "${POS_STAFF_PIN:-}" ]]; then
  echo "POS_STAFF_PIN is required (staff removal is the only manual correction)" >&2
  exit 2
fi
if [[ -z "$SB_URL" || -z "$SB_KEY" ]]; then
  echo "NEXT_PUBLIC_SUPABASE_URL and SUPABASE_SECRET_KEY are required" >&2
  exit 2
fi

WORK="$(mktemp -d)"
COOKIE="$WORK/one.txt"
COOKIE2="$WORK/two.txt"
COOKIE3="$WORK/three.txt"
PASS=0
FAIL=0

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

ok()   { PASS=$((PASS + 1)); echo "  ok   - $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL - $1"; }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected [$3], got [$2])"; fi; }

# Read a dotted path out of JSON on stdin.
jqr() {
  node -e 'const p=process.argv[1].split(".");let o;try{o=JSON.parse(require("fs").readFileSync(0,"utf8"))}catch(e){process.stdout.write("");process.exit(0)}let v=o;for(const k of p){if(k==="")continue;v=(v==null?undefined:v[k])}process.stdout.write(v==null?"":String(v))' "$1"
}

rest() {
  # rest METHOD PATH [JSON]
  local method="$1" path="$2" body="${3:-}"
  if [[ -n "$body" ]]; then
    curl -s -X "$method" "$SB_URL/rest/v1/$path" \
      -H "apikey: $SB_KEY" -H "Authorization: Bearer $SB_KEY" \
      -H "Content-Type: application/json" -H "Prefer: return=representation,resolution=merge-duplicates" \
      -d "$body"
  else
    curl -s -X "$method" "$SB_URL/rest/v1/$path" \
      -H "apikey: $SB_KEY" -H "Authorization: Bearer $SB_KEY"
  fi
}

pos_get() {
  curl -s -o "$WORK/body" -w '%{http_code}' \
    "$APP_URL/api/pos/session?station_id=$1" -H "x-pos-token: $POS_INGEST_SECRET"
}

pos_sync() {
  # pos_sync SESSION_REF ITEMS_JSON [EXTRA_JSON_FIELDS] -> http code, body in $WORK/body
  local extra="${3:-}"
  curl -s -o "$WORK/body" -w '%{http_code}' -X POST "$APP_URL/api/pos/sync" \
    -H "x-pos-token: $POS_INGEST_SECRET" -H 'Content-Type: application/json' \
    -d "{\"session_ref\":\"$1\",\"station_id\":\"$STATION\",\"items\":$2${extra:+,$extra}}"
}

staff_remove() {
  # staff_remove COOKIE CART PRODUCT QTY PIN -> http code, body in $WORK/body
  curl -s -o "$WORK/body" -w '%{http_code}' -b "$1" -X POST \
    "$APP_URL/api/protected/station-session/items/$3/staff-remove" \
    -H 'Content-Type: application/json' \
    -d "{\"cart_id\":\"$2\",\"quantity\":$4,\"pin\":\"$5\"}"
}

# The customer's own access token, read out of the Supabase SSR cookie in a curl jar (the
# value is `base64-<json>`, possibly split into .0/.1 chunks).
customer_token() {
  node -e '
    const lines = require("fs").readFileSync(process.argv[1], "utf8").split("\n");
    const parts = {};
    for (const l of lines) {
      const f = l.replace(/^#HttpOnly_/, "").split("\t");
      if (f.length < 7) continue;
      const m = /^(sb-.+-auth-token)(?:\.(\d+))?$/.exec(f[5]);
      if (m) parts[Number(m[2] ?? 0)] = f[6];
    }
    let v = Object.keys(parts).sort((a, b) => a - b).map((k) => parts[k]).join("");
    v = decodeURIComponent(v);
    if (v.startsWith("base64-")) v = Buffer.from(v.slice(7), "base64").toString("utf8");
    try { process.stdout.write(JSON.parse(v).access_token || ""); } catch { process.stdout.write(""); }
  ' "$1"
}

echo "POS e2e against $APP_URL"

STATION="e2e-counter-$$"
CLASS="e2e_class_$$"
CLASS2="e2e_class2_$$"

# --- seed ----------------------------------------------------------------
rest POST 'stations' "{\"id\":\"$STATION\",\"name\":\"E2E Counter\"}" >/dev/null
PRODUCT_ID="$(rest POST 'products' "{\"name\":\"E2E Item $$\",\"price\":10,\"stock_quantity\":100}" | jqr '0.id')"
if [[ -z "$PRODUCT_ID" ]]; then echo "could not seed a product" >&2; exit 2; fi
rest POST 'product_class_map' "{\"class_slug\":\"$CLASS\",\"product_id\":\"$PRODUCT_ID\"}" >/dev/null
rest POST 'product_class_map' "{\"class_slug\":\"$CLASS2\",\"product_id\":\"$PRODUCT_ID\"}" >/dev/null
echo "seeded station=$STATION product=$PRODUCT_ID"

# The idle window both idle sections backdate past. Read once, here, because both the poll
# sweep and the on-Start cancel are measured against it.
IDLE_MIN="${POS_IDLE_CANCEL_MINUTES:-5}"

# --- unknown station -> 404 ---------------------------------------------
code="$(pos_get "nope-$STATION")"
check "unknown station -> 404" "$code" "404"

# --- wrong token -> 401 --------------------------------------------------
code="$(curl -s -o /dev/null -w '%{http_code}' "$APP_URL/api/pos/session?station_id=$STATION" -H 'x-pos-token: wrong')"
check "bad token -> 401" "$code" "401"

# --- first customer opens a session -------------------------------------
LOGIN="$(curl -s -c "$COOKIE" -X POST "$APP_URL/api/auth" -H 'Content-Type: application/json' -d '{"type":"customer-sign-in"}')"
CART="$(printf '%s' "$LOGIN" | jqr 'data.cart.id')"
USER="$(printf '%s' "$LOGIN" | jqr 'data.user.id')"
if [[ -z "$CART" ]]; then echo "anonymous sign-in failed: $LOGIN" >&2; exit 2; fi

OPEN="$(curl -s -b "$COOKIE" -X POST "$APP_URL/api/protected/station-session" -H 'Content-Type: application/json' -d "{\"station_id\":\"$STATION\",\"cart_id\":\"$CART\"}")"
REF="$(printf '%s' "$OPEN" | jqr 'data.session_ref')"
if [[ -z "$REF" ]]; then echo "open session failed: $OPEN" >&2; exit 2; fi
ok "session opened ($REF)"

# The daily shopper label, assigned inside the open's transaction (spec: a display code next
# to the machine UUID, one counter per Manila day, only actual shoppers consume numbers).
SHOP1="$(printf '%s' "$OPEN" | jqr 'data.shopper_code')"
if [[ "$SHOP1" =~ ^Shopper_[0-9]{4}$ ]]; then ok "the open carries a daily shopper label ($SHOP1)"; else bad "open response has no Shopper_NNNN label: [$SHOP1]"; fi

# --- session poll sees it -----------------------------------------------
code="$(pos_get "$STATION")"
check "session poll -> 200" "$code" "200"
check "the session poll carries the same label" "$(jqr 'data.shopper_code' <"$WORK/body")" "$SHOP1"

# --- sync adds -----------------------------------------------------------
code="$(pos_sync "$REF" "[{\"class_name\":\"$CLASS\",\"quantity\":1}]")"
check "sync add -> 200" "$code" "200"
check "sync add status" "$(jqr 'data.results.0.status' <"$WORK/body")" "added"

rows="$(rest GET "cart_items?cart_id=eq.$CART&session_ref=not.is.null&select=id" | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>console.log(JSON.parse(d).length))')"
check "one camera row" "$rows" "1"

# --- identical sync is a no-op ------------------------------------------
code="$(pos_sync "$REF" "[{\"class_name\":\"$CLASS\",\"quantity\":1}]")"
check "no-op sync -> 200" "$code" "200"
rows="$(rest GET "cart_items?cart_id=eq.$CART&session_ref=not.is.null&select=id" | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>console.log(JSON.parse(d).length))')"
check "no duplicate row" "$rows" "1"

# --- the camera loses sight of the item, then sees it again ---------------
# SCANnCART holds a posted quantity as a floor, so a taken item reads as `lost: true` rather
# than as a lower count. pos_reconcile stamps camera_lost_at on the first such sync, leaves the
# stamp (and last_activity_at) alone on repeats, and clears it the first sync without the flag.
lost_at() { rest GET "cart_items?cart_id=eq.$CART&session_ref=not.is.null&select=camera_lost_at" | jqr '0.camera_lost_at'; }
activity() { rest GET "station_sessions?session_ref=eq.$REF&select=last_activity_at" | jqr '0.last_activity_at'; }
code="$(pos_sync "$REF" "[{\"class_name\":\"$CLASS\",\"quantity\":1,\"lost\":true}]")"
check "lost sync -> 200" "$code" "200"
stamp="$(lost_at)"
[[ -n "$stamp" ]] && ok "camera_lost_at stamped" || bad "camera_lost_at not stamped"
before_activity="$(activity)"
sleep 1
code="$(pos_sync "$REF" "[{\"class_name\":\"$CLASS\",\"quantity\":1,\"lost\":true}]")"
check "repeated lost sync -> 200" "$code" "200"
check "a repeat keeps the first stamp" "$(lost_at)" "$stamp"
check "a repeat is not customer activity" "$(activity)" "$before_activity"
code="$(pos_sync "$REF" "[{\"class_name\":\"$CLASS\",\"quantity\":1}]")"
check "seen-again sync -> 200" "$code" "200"
check "camera_lost_at cleared" "$(lost_at)" ""
code="$(pos_sync "$REF" "[{\"class_name\":\"$CLASS\",\"quantity\":1,\"lost\":\"abc\"}]")"
check "non-boolean lost -> 400" "$code" "400"

# --- two classes map to one product are summed ---------------------------
code="$(pos_sync "$REF" "[{\"class_name\":\"$CLASS\",\"quantity\":1},{\"class_name\":\"$CLASS2\",\"quantity\":2}]")"
check "summed sync -> 200" "$code" "200"
qty="$(rest GET "cart_items?cart_id=eq.$CART&session_ref=not.is.null&select=quantity" | jqr '0.quantity')"
check "summed quantity" "$qty" "3"

# --- unmapped class is reported, never inserted --------------------------
code="$(pos_sync "$REF" "[{\"class_name\":\"totally_unmapped_$$\",\"quantity\":1}]")"
check "unmapped sync -> 200" "$code" "200"
check "unmapped status" "$(jqr 'data.results.0.status' <"$WORK/body")" "unmapped"

# --- empty snapshot removes ---------------------------------------------
code="$(pos_sync "$REF" "[]")"
check "empty snapshot -> 200" "$code" "200"
rows="$(rest GET "cart_items?cart_id=eq.$CART&session_ref=not.is.null&select=id" | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>console.log(JSON.parse(d).length))')"
check "rows deleted" "$rows" "0"

# --- customers cannot edit the camera's cart ---------------------------
code="$(pos_sync "$REF" "[{\"class_name\":\"$CLASS\",\"quantity\":5}]")"
check "re-add -> 200" "$code" "200"
code="$(curl -s -o "$WORK/body" -w '%{http_code}' -b "$COOKIE" -X PUT \
  "$APP_URL/api/protected/station-session/items/$PRODUCT_ID" \
  -H 'Content-Type: application/json' -d "{\"cart_id\":\"$CART\",\"quantity\":9}")"
check "customer edit -> 403" "$code" "403"
check "customer edit refused as disabled" "$(jqr 'error' <"$WORK/body")" "customer_edits_disabled"
code="$(curl -s -o /dev/null -w '%{http_code}' -b "$COOKIE" -X DELETE \
  "$APP_URL/api/protected/station-session/items/$PRODUCT_ID?cart_id=$CART")"
check "customer remove -> 403" "$code" "403"
qty="$(rest GET "cart_items?cart_id=eq.$CART&product_id=eq.$PRODUCT_ID&select=quantity" | jqr '0.quantity')"
check "camera quantity untouched" "$qty" "5"

# The customer's browser holds a Supabase token: writing cart_items directly, around every
# route, must be refused by the database itself.
TOKEN="$(customer_token "$COOKIE")"
if [[ -z "$TOKEN" ]]; then
  bad "could not read the customer's token from the cookie jar"
else
  # The token must be live, or the refusals below would only be a 401 proving nothing.
  seen="$(curl -s "$SB_URL/rest/v1/cart_items?cart_id=eq.$CART&select=id"     -H "apikey: ${NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY:-$SB_KEY}" -H "Authorization: Bearer $TOKEN" |
    node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{try{console.log(JSON.parse(d).length)}catch{console.log("x")}})')"
  check "customer token reads its own cart" "$seen" "1"
  curl -s -o /dev/null -X PATCH "$SB_URL/rest/v1/cart_items?cart_id=eq.$CART&product_id=eq.$PRODUCT_ID" \
    -H "apikey: ${NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY:-$SB_KEY}" -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' -d '{"quantity":1}'
  curl -s -o /dev/null -X POST "$SB_URL/rest/v1/cart_items" \
    -H "apikey: ${NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY:-$SB_KEY}" -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' -d "{\"cart_id\":\"$CART\",\"product_id\":\"$PRODUCT_ID\",\"quantity\":1}"
  qty="$(rest GET "cart_items?cart_id=eq.$CART&product_id=eq.$PRODUCT_ID&select=quantity" | jqr '0.quantity')"
  rows="$(rest GET "cart_items?cart_id=eq.$CART&select=id" | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>console.log(JSON.parse(d).length))')"
  check "direct customer write refused (quantity)" "$qty" "5"
  check "direct customer insert refused (rows)" "$rows" "1"
fi

# --- staff removal: the one manual correction, decrease-only -----------
code="$(staff_remove "$COOKIE" "$CART" "$PRODUCT_ID" 1 "not-$POS_STAFF_PIN")"
check "wrong staff PIN -> 403" "$code" "403"
check "wrong PIN refused as invalid" "$(jqr 'error' <"$WORK/body")" "staff_pin_invalid"
code="$(staff_remove "$COOKIE" "$CART" "$PRODUCT_ID" 9 "$POS_STAFF_PIN")"
check "staff cannot remove more than is there -> 400" "$code" "400"
code="$(staff_remove "$COOKIE" "$CART" "$PRODUCT_ID" 1 "$POS_STAFF_PIN")"
check "staff remove 1 -> 200" "$code" "200"
qty="$(rest GET "cart_items?cart_id=eq.$CART&product_id=eq.$PRODUCT_ID&select=quantity" | jqr '0.quantity')"
check "quantity lowered by one" "$qty" "4"
code="$(pos_sync "$REF" "[{\"class_name\":\"$CLASS\",\"quantity\":5}]")"
check "post-staff sync -> 200" "$code" "200"
check "camera no longer manages it" "$(jqr 'data.results.0.status' <"$WORK/body")" "overridden"
qty="$(rest GET "cart_items?cart_id=eq.$CART&product_id=eq.$PRODUCT_ID&select=quantity" | jqr '0.quantity')"
check "staff quantity stands" "$qty" "4"
logged="$(rest GET "pos_sync_log?session_ref=eq.$REF&kind=eq.staff_edit&select=id" | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>console.log(JSON.parse(d).length))')"
check "staff edit logged" "$logged" "1"

# --- a second customer cannot touch the first cart -----------------------
LOGIN2="$(curl -s -c "$COOKIE2" -X POST "$APP_URL/api/auth" -H 'Content-Type: application/json' -d '{"type":"customer-sign-in"}')"
CART2="$(printf '%s' "$LOGIN2" | jqr 'data.cart.id')"
code="$(curl -s -o /dev/null -w '%{http_code}' -b "$COOKIE2" -X POST \
  "$APP_URL/api/protected/station-session/finish" -H 'Content-Type: application/json' \
  -d "{\"cart_id\":\"$CART\"}")"
check "foreign finish -> 403" "$code" "403"
code="$(staff_remove "$COOKIE2" "$CART" "$PRODUCT_ID" 1 "$POS_STAFF_PIN")"
check "foreign staff remove -> 403 (a PIN is not a licence for any cart)" "$code" "403"

# --- cart reads enforce ownership and reject malformed IDs -------------
code="$(curl -s -o /dev/null -w '%{http_code}' -b "$COOKIE2" \
  "$APP_URL/api/protected/cart_items/$CART/active")"
check "foreign cart read -> 403" "$code" "403"
code="$(curl -s -o /dev/null -w '%{http_code}' -b "$COOKIE" \
  "$APP_URL/api/protected/cart_items/$CART/active")"
check "own cart read -> 200" "$code" "200"
code="$(curl -s -o /dev/null -w '%{http_code}' -b "$COOKIE" \
  "$APP_URL/api/protected/cart_items/not-a-cart/active")"
check "malformed cart read -> 400" "$code" "400"

# --- legacy routes must not bypass POS ownership -----------------------
for path in "cart/$CART" "cart/get_one/$CART"; do
  code="$(curl -s -o /dev/null -w '%{http_code}' -b "$COOKIE2" "$APP_URL/api/protected/$path")"
  check "foreign $path read -> 403" "$code" "403"
done
ITEM_ID="$(rest GET "cart_items?cart_id=eq.$CART&select=id" | jqr '0.id')"
code="$(curl -s -o /dev/null -w '%{http_code}' -b "$COOKIE2" -X PUT \
  "$APP_URL/api/protected/cart_items/$ITEM_ID" -H 'Content-Type: application/json' \
  -d '{"type":"update-quantity","quantity":5}')"
check "foreign legacy item edit -> 403" "$code" "403"
code="$(curl -s -o /dev/null -w '%{http_code}' -b "$COOKIE2" -X PUT \
  "$APP_URL/api/protected/cart/$CART" -H 'Content-Type: application/json' \
  -d '{"type":"update-cart-status","status":"active"}')"
check "foreign legacy cart edit -> 403" "$code" "403"
code="$(curl -s -o /dev/null -w '%{http_code}' -b "$COOKIE2" -X POST \
  "$APP_URL/api/protected/cart_items" -H 'Content-Type: application/json' \
  -d "{\"type\":\"add-to-cart\",\"cartId\":\"$CART\",\"productId\":\"$PRODUCT_ID\"}")"
check "foreign legacy item insert -> 403" "$code" "403"
# Use a disposable row so a pre-fix delete probe cannot destroy the checkout fixture.
PROBE_ITEM="$(rest POST 'cart_items' "{\"cart_id\":\"$CART\",\"product_id\":\"$PRODUCT_ID\",\"quantity\":1}" | jqr '0.id')"
code="$(curl -s -o /dev/null -w '%{http_code}' -b "$COOKIE2" -X DELETE \
  "$APP_URL/api/protected/cart_items/$PROBE_ITEM")"
check "foreign legacy item delete -> 403" "$code" "403"
# Remove only the disposable/manual probe rows, leaving the original edited row intact.
rest DELETE "cart_items?cart_id=eq.$CART&id=neq.$ITEM_ID" >/dev/null
for path in profiles orders dashboard/2026 pos-overview; do
  code="$(curl -s -o /dev/null -w '%{http_code}' -b "$COOKIE2" "$APP_URL/api/protected/$path")"
  check "customer $path read -> 403" "$code" "403"
done
code="$(curl -s -o /dev/null -w '%{http_code}' -b "$COOKIE2" -X PUT \
  "$APP_URL/api/protected/profiles/update/$USER" \
  -F 'type=update-user-info' -F 'role=user' -F 'first_name=Foreign probe')"
check "foreign profile edit -> 403" "$code" "403"
code="$(curl -s -o /dev/null -w '%{http_code}' \
  -H "Cookie: sb-${NEXT_PUBLIC_SUPABASE_TOKEN:-127}-auth-token=forged" \
  "$APP_URL/api/protected/products")"
check "forged auth cookie -> 401" "$code" "401"

# --- positive customer paths and privilege escalation -------------------
for path in "cart/$CART" "cart/get_one/$CART" cashiers products categories vat/all stations; do
  code="$(curl -s -o /dev/null -w '%{http_code}' -b "$COOKIE" "$APP_URL/api/protected/$path")"
  check "own/customer $path read -> 200" "$code" "200"
done
code="$(curl -s -o /dev/null -w '%{http_code}' -b "$COOKIE2" -X PUT \
  "$APP_URL/api/protected/profiles/update/$(printf '%s' "$LOGIN2" | jqr 'data.user.id')" \
  -F 'type=update-user-info' -F 'role=admin')"
check "customer self-promotion -> 403" "$code" "403"
code="$(curl -s -o /dev/null -w '%{http_code}' -b "$COOKIE2" -X POST \
  "$APP_URL/api/protected/orders" -H 'Content-Type: application/json' \
  -d "{\"type\":\"add-orders\",\"cart_id\":\"$CART\",\"user_id\":\"$USER\",\"subtotal\":0,\"vat_amount\":0,\"total_amount\":0}")"
check "customer legacy order insert -> 403" "$code" "403"
code="$(curl -s -o /dev/null -w '%{http_code}' -b "$COOKIE" -X PUT \
  "$APP_URL/api/protected/cart/$CART" -H 'Content-Type: application/json' \
  -d '{"type":"update-cart-status","status":"paid"}')"
check "customer cannot bypass payment -> 403" "$code" "403"
code="$(curl -s -o /dev/null -w '%{http_code}' -b "$COOKIE" -X PUT \
  "$APP_URL/api/protected/cart_items/$ITEM_ID" -H 'Content-Type: application/json' \
  -d '{"type":"update-quantity","quantity":5}')"
check "own legacy item edit on a camera cart -> 403" "$code" "403"

# --- second Start on a busy counter -> 409 ------------------------------
code="$(curl -s -o /dev/null -w '%{http_code}' -b "$COOKIE2" -X POST \
  "$APP_URL/api/protected/station-session" -H 'Content-Type: application/json' \
  -d "{\"station_id\":\"$STATION\",\"cart_id\":\"$CART2\"}")"
check "busy counter -> 409" "$code" "409"

# --- the scanner's review blocks Finish until it clears ----------------
code="$(pos_sync "$REF" "[{\"class_name\":\"$CLASS\",\"quantity\":5}]" '"pending_review":1,"review_reasons":["two items crossed the opening at once"]')"
check "sync with review -> 200" "$code" "200"
code="$(curl -s -o "$WORK/body" -w '%{http_code}' -b "$COOKIE" "$APP_URL/api/protected/station-session")"
check "tablet sees the review" "$(jqr 'data.pending_review' <"$WORK/body")" "1"
check "tablet sees the reason" "$(jqr 'data.review_reasons.0' <"$WORK/body")" "two items crossed the opening at once"
code="$(curl -s -o "$WORK/body" -w '%{http_code}' -b "$COOKIE" -X POST \
  "$APP_URL/api/protected/station-session/finish" -H 'Content-Type: application/json' \
  -d "{\"cart_id\":\"$CART\"}")"
check "finish under review -> 409" "$code" "409"
check "refused as review_pending" "$(jqr 'error' <"$WORK/body")" "review_pending"
code="$(pos_sync "$REF" "[]" '"pending_review":-1')"
check "negative review count -> 400" "$code" "400"
code="$(pos_sync "$REF" "[{\"class_name\":\"$CLASS\",\"quantity\":5}]")"
code="$(curl -s -o "$WORK/body" -w '%{http_code}' -b "$COOKIE" "$APP_URL/api/protected/station-session")"
check "a counter-mode sync leaves the review alone" "$(jqr 'data.pending_review' <"$WORK/body")" "1"
code="$(pos_sync "$REF" "[{\"class_name\":\"$CLASS\",\"quantity\":5}]" '"pending_review":0,"review_reasons":[]')"
check "review cleared -> 200" "$code" "200"

# --- the admin POS screen's own Basket checked (staff at the tablet) ------
# The desktop's review re-posts carry review_as_of — the newest interaction the count
# includes — so a staff clear stamped on the session outranks a stale re-post while a
# genuinely newer interaction still gets through. And the clear itself is admin-gated.
BACKDATED_AS_OF="$(node -e "process.stdout.write(new Date(Date.now()-60000).toISOString())")"
code="$(pos_sync "$REF" "[{\"class_name\":\"$CLASS\",\"quantity\":5}]" "\"pending_review\":1,\"review_reasons\":[\"two items crossed the opening at once\"],\"review_as_of\":\"$BACKDATED_AS_OF\"")"
check "sync with review + as_of -> 200" "$code" "200"
code="$(curl -s -o /dev/null -w '%{http_code}' -b "$COOKIE" -X POST \
  "$APP_URL/api/protected/pos-sessions/00000000-0000-0000-0000-000000000000/review-clear")"
check "customer clear -> 403 (admin only)" "$code" "403"
rest PATCH "station_sessions?session_ref=eq.$REF" "{\"pending_review\":0,\"review_reasons\":\"[]\",\"review_cleared_at\":\"$(node -e 'process.stdout.write(new Date().toISOString())')\"}" >/dev/null
code="$(pos_get "$STATION")"
check "the desktop poll carries the staff clear" "$(jqr 'data.review_cleared_at' <"$WORK/body")" "$(rest GET "station_sessions?session_ref=eq.$REF&select=review_cleared_at" | jqr '0.review_cleared_at')"
code="$(pos_sync "$REF" "[{\"class_name\":\"$CLASS\",\"quantity\":5}]" "\"pending_review\":1,\"review_reasons\":[\"two items crossed the opening at once\"],\"review_as_of\":\"$BACKDATED_AS_OF\"")"
check "a stale re-post loses to the staff clear" "$(rest GET "station_sessions?session_ref=eq.$REF&select=pending_review" | jqr '0.pending_review')" "0"
NEWER_AS_OF="$(node -e "process.stdout.write(new Date(Date.now()+5000).toISOString())")"
code="$(pos_sync "$REF" "[{\"class_name\":\"$CLASS\",\"quantity\":5}]" "\"pending_review\":1,\"review_reasons\":[\"two items crossed the opening at once\"],\"review_as_of\":\"$NEWER_AS_OF\"")"
check "a newer interaction raises the review again" "$(rest GET "station_sessions?session_ref=eq.$REF&select=pending_review" | jqr '0.pending_review')" "1"
code="$(pos_sync "$REF" "[{\"class_name\":\"$CLASS\",\"quantity\":5}]" '"pending_review":0,"review_reasons":[]')"
check "review cleared again for the finish chain -> 200" "$code" "200"

# --- insufficient stock blocks Finish -----------------------------------
rest PATCH "products?id=eq.$PRODUCT_ID" '{"stock_quantity":2}' >/dev/null
code="$(curl -s -o "$WORK/body" -w '%{http_code}' -b "$COOKIE" -X POST \
  "$APP_URL/api/protected/station-session/finish" -H 'Content-Type: application/json' \
  -d "{\"cart_id\":\"$CART\"}")"
check "short stock -> 409" "$code" "409"
cart_status="$(rest GET "carts?id=eq.$CART&select=status" | jqr '0.status')"
check "cart still active" "$cart_status" "active"
rest PATCH "products?id=eq.$PRODUCT_ID" '{"stock_quantity":100}' >/dev/null

# --- Finish creates the order and completes the session -----------------
code="$(curl -s -o "$WORK/body" -w '%{http_code}' -b "$COOKIE" -X POST \
  "$APP_URL/api/protected/station-session/finish" -H 'Content-Type: application/json' \
  -d "{\"cart_id\":\"$CART\"}")"
check "finish -> 200" "$code" "200"
ORDER_ID="$(jqr 'data.order_id' <"$WORK/body")"
if [[ -n "$ORDER_ID" ]]; then ok "order created ($ORDER_ID)"; else bad "no order id"; fi

orders="$(rest GET "orders?cart_id=eq.$CART&select=id" | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>console.log(JSON.parse(d).length))')"
check "one order row" "$orders" "1"
cart_status="$(rest GET "carts?id=eq.$CART&select=status" | jqr '0.status')"
check "cart paid" "$cart_status" "paid"
sess_status="$(rest GET "station_sessions?session_ref=eq.$REF&select=status" | jqr '0.status')"
check "session completed" "$sess_status" "completed"
stock="$(rest GET "products?id=eq.$PRODUCT_ID&select=stock_quantity" | jqr '0.stock_quantity')"
check "stock deducted" "$stock" "96"

# --- a sync after Finish -> 409 -----------------------------------------
code="$(pos_sync "$REF" "[{\"class_name\":\"$CLASS\",\"quantity\":1}]")"
check "post-finish sync -> 409" "$code" "409"

# --- the poll itself sweeps an expired session, no Start needed ----------
# The idle window's clock is the desktop's session poll: `GET /api/pos/session` runs
# `pos_cancel_idle_sessions` before its read, so a session abandoned past the window is
# `cancelled` within one poll of expiring — the tablet stops showing a live cart and the
# desktop unbinds on the poll's empty answer, without anybody tapping Start. The fresh
# session beside it must survive: the sweep takes only past-window rows.

# --- the window's near edge pins the configured value ---------------------
# A session idle just INSIDE the window must survive the same poll that kills expired ones.
# Backdated to IDLE_MIN-5 minutes: a server still on the old 5-minute default fails here
# whenever the env carries 15, because a 10-minute-old session would be swept.
LOGIN_B="$(curl -s -c "$COOKIE3" -X POST "$APP_URL/api/auth" -H 'Content-Type: application/json' -d '{"type":"customer-sign-in"}')"
CART_B="$(printf '%s' "$LOGIN_B" | jqr 'data.cart.id')"
OPEN_B="$(curl -s -b "$COOKIE3" -X POST "$APP_URL/api/protected/station-session" -H 'Content-Type: application/json' -d "{\"station_id\":\"$STATION\",\"cart_id\":\"$CART_B\"}")"
REF_B="$(printf '%s' "$OPEN_B" | jqr 'data.session_ref')"
if [[ -n "$REF_B" ]]; then ok "near-edge session opened ($REF_B)"; else bad "near-edge session failed to open: $OPEN_B"; fi
BACKDATE_B="$(node -e "process.stdout.write(new Date(Date.now()-($IDLE_MIN-5)*60000).toISOString())")"
rest PATCH "station_sessions?session_ref=eq.$REF_B" "{\"last_activity_at\":\"$BACKDATE_B\"}" >/dev/null
code="$(curl -s -o /dev/null -w '%{http_code}' "$APP_URL/api/pos/session?station_id=$STATION" -H "x-pos-token: $POS_INGEST_SECRET")"
check "a poll over a session inside the window answers 200" "$code" "200"
check "a session idle just inside the window survives the poll" "$(rest GET "station_sessions?session_ref=eq.$REF_B&select=status" | jqr '0.status')" "open"
BACKDATE_B="$(node -e "process.stdout.write(new Date(Date.now()-($IDLE_MIN+10)*60000).toISOString())")"
rest PATCH "station_sessions?session_ref=eq.$REF_B" "{\"last_activity_at\":\"$BACKDATE_B\"}" >/dev/null
curl -s -o /dev/null "$APP_URL/api/pos/session?station_id=$STATION" -H "x-pos-token: $POS_INGEST_SECRET"
check "the same session pushed past the window is cancelled" "$(rest GET "station_sessions?session_ref=eq.$REF_B&select=status" | jqr '0.status')" "cancelled"
LOGIN3="$(curl -s -c "$COOKIE3" -X POST "$APP_URL/api/auth" -H 'Content-Type: application/json' -d '{"type":"customer-sign-in"}')"
CART3="$(printf '%s' "$LOGIN3" | jqr 'data.cart.id')"
OPEN5="$(curl -s -b "$COOKIE3" -X POST "$APP_URL/api/protected/station-session" -H 'Content-Type: application/json' -d "{\"station_id\":\"$STATION\",\"cart_id\":\"$CART3\"}")"
REF5="$(printf '%s' "$OPEN5" | jqr 'data.session_ref')"
if [[ -n "$REF5" ]]; then ok "sweep-test session opened ($REF5)"; else bad "sweep-test session failed to open: $OPEN5"; fi
BACKDATE5="$(node -e "process.stdout.write(new Date(Date.now()-($IDLE_MIN+10)*60000).toISOString())")"
rest PATCH "station_sessions?session_ref=eq.$REF5" "{\"last_activity_at\":\"$BACKDATE5\"}" >/dev/null
code="$(curl -s -o "$WORK/body" -w '%{http_code}' "$APP_URL/api/pos/session?station_id=$STATION" -H "x-pos-token: $POS_INGEST_SECRET")"
check "the desktop poll itself answers 200" "$code" "200"
check "the poll answers unbound (the sweep ran inside it)" "$(jqr 'data.session_ref' <"$WORK/body")" ""
check "the expired session is cancelled by the poll" "$(rest GET "station_sessions?session_ref=eq.$REF5&select=status" | jqr '0.status')" "cancelled"
ended5="$(rest GET "station_sessions?session_ref=eq.$REF5&select=ended_at" | jqr '0.ended_at')"
[[ -n "$ended5" ]] && ok "the swept session has an ended_at" || bad "swept session has no ended_at"
code="$(pos_sync "$REF5" "[{\"class_name\":\"$CLASS\",\"quantity\":1}]")"
check "a sync on the swept session -> 409" "$code" "409"

# --- the idle window clears an abandoned session on the next Start -------
# Spec §7: a session whose last_activity_at is past POS_IDLE_CANCEL_MINUTES is cancelled by the
# next customer's Start (which then succeeds) rather than answering busy forever, and the
# abandoned session_ref stops accepting syncs. The window is read so the backdate always clears
# it, whatever the host's setting is.
LOGIN3="$(curl -s -c "$COOKIE3" -X POST "$APP_URL/api/auth" -H 'Content-Type: application/json' -d '{"type":"customer-sign-in"}')"
CART3="$(printf '%s' "$LOGIN3" | jqr 'data.cart.id')"
OPEN3="$(curl -s -b "$COOKIE3" -X POST "$APP_URL/api/protected/station-session" -H 'Content-Type: application/json' -d "{\"station_id\":\"$STATION\",\"cart_id\":\"$CART3\"}")"
REF3="$(printf '%s' "$OPEN3" | jqr 'data.session_ref')"
if [[ -n "$REF3" ]]; then ok "idle-test session opened ($REF3)"; else bad "idle-test session failed to open: $OPEN3"; fi
BACKDATE="$(node -e "process.stdout.write(new Date(Date.now()-($IDLE_MIN+10)*60000).toISOString())")"
rest PATCH "station_sessions?session_ref=eq.$REF3" "{\"last_activity_at\":\"$BACKDATE\"}" >/dev/null
code="$(curl -s -o "$WORK/body" -w '%{http_code}' -b "$COOKIE2" -X POST \
  "$APP_URL/api/protected/station-session" -H 'Content-Type: application/json' \
  -d "{\"station_id\":\"$STATION\",\"cart_id\":\"$CART2\"}")"
check "start past the idle window -> 200 (not busy forever)" "$code" "200"
REF4="$(jqr 'data.session_ref' <"$WORK/body")"
if [[ -n "$REF4" && "$REF4" != "$REF3" ]]; then ok "the new Start carries a fresh session_ref"; else bad "expected a fresh session_ref, got [$REF4]"; fi
check "the abandoned session is cancelled" "$(rest GET "station_sessions?session_ref=eq.$REF3&select=status" | jqr '0.status')" "cancelled"
ended="$(rest GET "station_sessions?session_ref=eq.$REF3&select=ended_at" | jqr '0.ended_at')"
[[ -n "$ended" ]] && ok "the abandoned session has an ended_at" || bad "abandoned session has no ended_at"
code="$(pos_sync "$REF3" "[{\"class_name\":\"$CLASS\",\"quantity\":1}]")"
check "a sync on the cancelled session -> 409" "$code" "409"

# ...and the same poll over a session that is NOT expired must leave it alone: the sweep takes
# only past-window rows, or every Start would be cancelled out from under the customer it bound.
code="$(curl -s -o /dev/null -w '%{http_code}' "$APP_URL/api/pos/session?station_id=$STATION" -H "x-pos-token: $POS_INGEST_SECRET")"
check "a poll over a fresh session answers 200" "$code" "200"
check "the fresh session survives the sweep" "$(rest GET "station_sessions?session_ref=eq.$REF4&select=status" | jqr '0.status')" "open"

# --- shopper numbering: consecutive, daily reset, distinct under parallel Starts ---
# The label's contract: one counter per Manila day, bumped under row lock inside the open's
# transaction. So the next Start draws previous+1 whatever ran in between (measured against
# the counter row itself, not a hardcoded number), a new day restarts at 0001, and two
# parallel Starts — even on different stations — can never draw the same number.
STATION2="e2e-counter-b-$$"
rest POST 'stations' "{\"id\":\"$STATION2\",\"name\":\"E2E Counter B\"}" >/dev/null
TODAY="$(TZ=Asia/Manila date +%F)"
COUNTER() { rest GET "pos_shopper_counters?day=eq.$1&select=last_no" | jqr '0.last_no'; }

login_open() {
  # login_open COOKIEFILE STATION -> prints the open response JSON. The station is freed
  # first (service key): a previous section's or previous check's session is still open and
  # the busy branch would otherwise refuse this one — the busy path is covered elsewhere.
  local login cart
  rest PATCH "station_sessions?station_id=eq.$2&status=eq.open" "{\"status\":\"cancelled\",\"ended_at\":\"$(node -e 'process.stdout.write(new Date().toISOString())')\"}" >/dev/null
  login="$(curl -s -c "$1" -X POST "$APP_URL/api/auth" -H 'Content-Type: application/json' -d '{"type":"customer-sign-in"}')"
  cart="$(printf '%s' "$login" | jqr 'data.cart.id')"
  curl -s -b "$1" -X POST "$APP_URL/api/protected/station-session" -H 'Content-Type: application/json' -d "{\"station_id\":\"$2\",\"cart_id\":\"$cart\"}"
}

NO_BEFORE="$(COUNTER "$TODAY")"
OPEN_B="$(login_open "$COOKIE3" "$STATION2")"
SHOP_B="$(printf '%s' "$OPEN_B" | jqr 'data.shopper_code')"
if [[ "$SHOP_B" =~ ^Shopper_[0-9]{4}$ ]]; then
  check "the next Start draws previous+1 whatever ran before" "$((10#${SHOP_B#Shopper_}))" "$((NO_BEFORE + 1))"
else
  bad "station-B open drew no label: [$SHOP_B]"
fi

# Daily reset at Manila midnight: move today's counter row to yesterday, and the next Start
# draws the new day's first number.
rest PATCH "pos_shopper_counters?day=eq.$TODAY" "{\"day\":\"$(TZ=Asia/Manila date -d yesterday +%F)\"}" >/dev/null
OPEN_C="$(login_open "$COOKIE3" "$STATION2")"
check "a new day restarts the count at 0001" "$(printf '%s' "$OPEN_C" | jqr 'data.shopper_code')" "Shopper_0001"
rest DELETE "pos_shopper_counters?day=eq.$(TZ=Asia/Manila date -d yesterday +%F)" >/dev/null

# Distinct under parallel Starts: two customers tapping Start at the same instant, on two
# stations, must never draw the same number. The counter row lock is what serializes them
# (login_open frees each station, so neither Start hits the busy branch).
# NOTE: `VAR="$(cmd)" &` assigns inside the background subshell — the parent never sees it —
# so the parallel opens write to files instead.
login_open "$COOKIE2" "$STATION" > "$WORK/p1.json" & P1=$!
login_open "$COOKIE3" "$STATION2" > "$WORK/p2.json" & P2=$!
wait "$P1"; wait "$P2"
SHOP_P1="$(jqr 'data.shopper_code' <"$WORK/p1.json")"
SHOP_P2="$(jqr 'data.shopper_code' <"$WORK/p2.json")"
if [[ "$SHOP_P1" =~ ^Shopper_[0-9]{4}$ && "$SHOP_P2" =~ ^Shopper_[0-9]{4}$ ]]; then
  ok "both parallel Starts drew a label ($SHOP_P1 / $SHOP_P2)"
else
  bad "a parallel Start drew no label: [$SHOP_P1] / [$SHOP_P2]"
fi
if [[ "$SHOP_P1" =~ ^Shopper_[0-9]{4}$ && "$SHOP_P2" =~ ^Shopper_[0-9]{4}$ && "$SHOP_P1" != "$SHOP_P2" ]]; then
  ok "parallel Starts drew distinct numbers"
else
  bad "parallel Starts collided or drew nothing: [$SHOP_P1] / [$SHOP_P2]"
fi

# Leftover seed rows poison the real rig: scan-start opens on stations[0], and the admin
# mapping screen lists every class map — so this run's stations, mappings and product are
# deleted on the way out. The trap covers early exits; the tail covers the normal one.
cleanup() {
  rest DELETE "station_sessions?station_id=in.($STATION,$STATION2)" >/dev/null
  rest DELETE "cart_items?product_id=eq.$PRODUCT_ID" >/dev/null
  rest DELETE "product_class_map?class_slug=like.e2e_class*" >/dev/null
  rest DELETE "products?id=eq.$PRODUCT_ID" >/dev/null
  rest DELETE "stations?id=in.($STATION,$STATION2)" >/dev/null
}
trap cleanup EXIT

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
