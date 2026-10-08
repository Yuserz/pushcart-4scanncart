import { NextRequest } from 'next/server';
import { createClient, createServiceClient } from '@/config';
import {
  forbiddenResponse,
  generalErrorResponse,
  successResponse,
  unauthorizedResponse,
} from '@/app/api/helpers/response';

// Staff checked the basket by eye from the admin POS screen: clear the review so the
// tablet's Finish unblocks, and stamp `review_cleared_at` — which the desktop's session
// poll reads so its ledger drops the interactions a human just cleared, keeping its own
// next sync from re-raising them.
export async function POST(
  _req: NextRequest,
  { params }: { params: Promise<{ id: string }> },
) {
  try {
    const { id } = await params;

    // Same gate as the cart routes: a signed-in admin. A customer (or an anonymous
    // counter tablet cookie) gets 403, and only an *open* session is clearable.
    const supabase = createClient();
    const {
      data: { user },
    } = await supabase.auth.getUser();
    if (!user) return unauthorizedResponse();
    const { data: profile } = await supabase
      .from('profiles')
      .select('role')
      .eq('id', user.id)
      .maybeSingle();
    if (!user.is_anonymous && profile?.role !== 'admin') {
      return forbiddenResponse({ error: 'Admin only' });
    }

    const service = createServiceClient();

    const { data: session, error: fetchError } = await service
      .from('station_sessions')
      .select('session_ref, station_id, status')
      .eq('id', id)
      .maybeSingle();
    if (fetchError) return generalErrorResponse({ error: fetchError.message });
    if (!session || session.status !== 'open') {
      return generalErrorResponse({ error: 'session_closed' });
    }

    const { error } = await service
      .from('station_sessions')
      .update({
        pending_review: 0,
        review_reasons: [],
        review_cleared_at: new Date().toISOString(),
      })
      .eq('id', id)
      .eq('status', 'open');

    if (error) return generalErrorResponse({ error: error.message });

    return successResponse({ message: 'Successfully cleared basket review' });
  } catch (error) {
    const newError = error as Error;
    return generalErrorResponse({ error: newError.message });
  }
}
