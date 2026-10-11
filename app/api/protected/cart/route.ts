import { NextRequest } from 'next/server';
import {
  generalErrorResponse,
  successResponse,
  unauthorizedResponse,
} from '../../helpers/response';
import { createClient } from '@/config';

export async function GET(req: NextRequest) {
  try {
    const url = req.nextUrl.searchParams;
    const search = url.get('search') || '';

    const supabase = await createClient();

    const {
      data: { user },
    } = await supabase.auth.getUser();
    if (!user) return unauthorizedResponse();
    const { data: profile } = await supabase
      .from('profiles')
      .select('role')
      .eq('id', user.id)
      .maybeSingle();
    const admin = !user.is_anonymous && profile?.role === 'admin';

    let query = supabase
      .from('carts')
      .select('id, code_token, user_id, created_at')
      .eq('status', 'unpaid');

    if (!admin)
      query = query.or(`customer_id.eq.${user.id},user_id.eq.${user.id}`);

    // code_token is a UUID column — Postgres has no ILIKE on uuid, so the
    // keyword filter happens over the fetched rows below instead.

    const { data, error } = await query;

    if (error) {
      console.error(error.message);
      return generalErrorResponse({ error: error.message });
    }

    // code_token is a UUID column, which Postgres can't ILIKE, so match here
    const keyword = search.trim().toLowerCase();
    const carts = keyword
      ? data.filter((cart) => cart.code_token.toLowerCase().includes(keyword))
      : data;

    return successResponse({
      message: 'Successfully fetched cart',
      data: carts,
    });
  } catch (error) {
    const newError = error as Error;
    console.error(newError.message);
    return generalErrorResponse({ error: newError.message });
  }
}
