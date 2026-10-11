import {
  validationErrorNextResponse,
  generalErrorResponse,
  successResponse,
} from '@/app/api/helpers/response';
import { createClient } from '@/config';
import { cartAccess } from '@/app/api/helpers/cart-access';
import { isEmpty } from 'lodash';
import { NextRequest } from 'next/server';
import { editCart } from '@/app/api/model/cart';

export async function GET(
  req: NextRequest,
  { params }: { params: Promise<{ id: string }> },
) {
  try {
    const { id } = await params;
    const supabase = await createClient();
    const access = await cartAccess(supabase, id);
    if (access.response) return access.response;

    const { data, error } = await supabase
      .from('carts')
      .select(
        'id, user_id, customer_id, code_token, status, created_at, updated_at, archived_at',
      )
      .eq('id', id)
      .maybeSingle();

    if (error) {
      return generalErrorResponse({ message: error.message });
    }

    return successResponse({
      message: 'Successfully fetched cart',
      data,
    });
  } catch (error) {
    const newError = error as Error;
    return generalErrorResponse({ error: newError.message });
  }
}

export async function PUT(
  req: NextRequest,
  { params }: { params: Promise<{ id: string }> },
) {
  const { id } = await params;
  const body = await req.json();

  if (isEmpty(body)) {
    return validationErrorNextResponse();
  }

  if (body.type === 'update-cart-status') {
    return editCart({ status: body.status }, id);
  }
}
