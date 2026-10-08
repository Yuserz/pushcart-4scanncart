import { NextRequest } from 'next/server';
import {
  unauthorizedResponse,
  validationErrorNextResponse,
} from '@/app/api/helpers/response';
import {
  reconcileCart,
  type PosSyncItem,
  type PosSyncPayload,
} from '@/app/api/model/pos_sync';

function hasValidToken(req: NextRequest): boolean {
  const secret = process.env.POS_INGEST_SECRET;
  if (!secret) return false;
  return req.headers.get('x-pos-token') === secret;
}

// All payload validation lives here in TypeScript; the Postgres function assumes a
// well-formed snapshot (§3.2 step 1).
function validate(
  body: unknown,
): { payload: PosSyncPayload } | { error: string } {
  const b = body as Partial<PosSyncPayload> | null;

  if (!b || typeof b !== 'object') return { error: 'invalid body' };
  if (typeof b.session_ref !== 'string' || !b.session_ref) {
    return { error: 'session_ref required' };
  }
  if (typeof b.station_id !== 'string' || !b.station_id) {
    return { error: 'station_id required' };
  }
  if (!Array.isArray(b.items)) return { error: 'items must be an array' };
  if (b.items.length > 200) return { error: 'at most 200 items' };

  const seen = new Set<string>();

  for (const item of b.items as PosSyncItem[]) {
    if (!item || typeof item.class_name !== 'string' || !item.class_name) {
      return { error: 'class_name required' };
    }
    if (!Number.isInteger(item.quantity) || item.quantity < 1) {
      return { error: 'quantity must be an integer >= 1' };
    }
    // pos_reconcile casts this with ::boolean, which throws (a 500) on anything Postgres cannot
    // read as one — refuse it here as the 400 it is.
    if (item.lost !== undefined && typeof item.lost !== 'boolean') {
      return { error: 'lost must be a boolean' };
    }
    if (seen.has(item.class_name)) {
      return { error: `duplicate class_name: ${item.class_name}` };
    }
    seen.add(item.class_name);
  }

  if (b.pending_review !== undefined) {
    if (!Number.isInteger(b.pending_review) || b.pending_review < 0) {
      return { error: 'pending_review must be an integer >= 0' };
    }
  }
  if (b.review_reasons !== undefined) {
    if (
      !Array.isArray(b.review_reasons) ||
      b.review_reasons.length > 50 ||
      b.review_reasons.some((r) => typeof r !== 'string' || r.length > 300)
    ) {
      return { error: 'review_reasons must be at most 50 strings' };
    }
  }
  // The as-of stamp for the review count: the newest interaction the count includes.
  // pos_set_review uses it to let a staff clear (admin POS screen) outrank a stale
  // desktop re-post while still accepting genuinely newer interactions.
  if (b.review_as_of !== undefined) {
    if (
      typeof b.review_as_of !== 'string' ||
      Number.isNaN(Date.parse(b.review_as_of))
    ) {
      return { error: 'review_as_of must be an ISO timestamp' };
    }
  }

  return { payload: b as PosSyncPayload };
}

export async function POST(req: NextRequest) {
  if (!hasValidToken(req)) {
    return unauthorizedResponse({ error: 'unauthorized' });
  }

  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return validationErrorNextResponse({ error: 'invalid json' });
  }

  const validated = validate(body);

  if ('error' in validated) {
    return validationErrorNextResponse({ error: validated.error });
  }

  return reconcileCart(validated.payload);
}
