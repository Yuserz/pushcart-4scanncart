import { createServiceClient } from '@/config';
import {
  generalErrorResponse,
  successResponse,
} from '@/app/api/helpers/response';

interface SyncLogRow {
  created_at: string;
  results: { class_name?: string; status?: string }[] | null;
  payload: { product_id?: string }[] | null;
}

// One read for the admin POS panel: the raw tables carry no RLS policies, so it runs
// with the service key. The unmapped/customer-edit lists are derived from the audit
// table here rather than in a second endpoint.
export async function GET() {
  try {
    const supabase = createServiceClient();

    const [sessions, products, recentSyncs, edits] = await Promise.all([
      supabase
        .from('station_sessions')
        .select(
          'id, station_id, session_ref, cart_id, status, created_at, last_activity_at, pending_review, review_cleared_at, review_reasons, stations(name), carts(code_token)',
        )
        .eq('status', 'open')
        .order('created_at', { ascending: false }),
      supabase
        .from('products')
        .select('id, name, sku, price, stock_quantity')
        .is('archived_at', null)
        .order('name')
        .limit(500),
      supabase
        .from('pos_sync_log')
        .select('created_at, results, payload')
        .eq('kind', 'sync')
        .order('created_at', { ascending: false })
        .limit(100),
      supabase
        .from('pos_sync_log')
        .select('id, session_ref, payload, created_at')
        .eq('kind', 'customer_edit')
        .order('created_at', { ascending: false })
        .limit(50),
    ]);

    const firstError =
      sessions.error || products.error || recentSyncs.error || edits.error;

    if (firstError) {
      return generalErrorResponse({ error: firstError.message });
    }

    // Recent unmapped classes, most-recent first, de-duplicated.
    const unmappedMap = new Map<string, string>();
    for (const row of (recentSyncs.data ?? []) as SyncLogRow[]) {
      for (const result of row.results ?? []) {
        if (result.status === 'unmapped' && result.class_name) {
          if (!unmappedMap.has(result.class_name)) {
            unmappedMap.set(result.class_name, row.created_at);
          }
        }
      }
    }

    const unmapped = [...unmappedMap.entries()].map(
      ([class_name, last_seen]) => ({
        class_name,
        last_seen,
      }),
    );

    return successResponse({
      message: 'Successfully fetched POS overview',
      data: {
        sessions: sessions.data ?? [],
        products: products.data ?? [],
        unmapped,
        customer_edits: edits.data ?? [],
      },
    });
  } catch (error) {
    const newError = error as Error;
    return generalErrorResponse({ error: newError.message });
  }
}
