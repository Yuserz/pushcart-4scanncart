import { JSX } from 'react';
import { getCartItemsById } from '@/services/cart/cart.services';
import { getCarts } from '@/services/cart/cart.services';
import { Orders } from './components/Orders';
import { CartItemsProducts, Carts } from '@/lib/types/Carts';
import { getSpecificVat } from '@/services/vat/vat.services';

export default async function PostPage({
  searchParams,
  params,
}: {
  searchParams: Promise<{ cartId: string; search: string }>;
  params: Promise<{ userId: string }>;
}): Promise<JSX.Element> {
  const { cartId, search } = await searchParams;
  const { userId } = await params;

  const carts = await getCarts(search ? `?search=${search}` : '');
  const cartItems = !cartId ? [] : await getCartItemsById(cartId, 'unpaid');
  const getAllVat = await getSpecificVat();

  return (
    <div className="container mx-auto h-auto space-y-4 p-12">
      <header>
        <h1 className="text-4xl font-bold">Orders</h1>
        <span className="text-gray-500">all users orders can see here</span>
      </header>

      <Orders
        carts={carts as Carts[]}
        cartItems={cartItems as CartItemsProducts[]}
        cartId={cartId}
        userId={userId}
        tax={getAllVat.vat}
      />
    </div>
  );
}
