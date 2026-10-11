import { JSX } from 'react';
import { getProducts } from '@/services/products/product.services';
import { ProductCards } from './components/ProductCards';
import { Container } from '@/components/custom/Container';
import { getCartItemsById, getCartsById } from '@/services/cart/cart.services';
import { CartItemsProducts } from '@/lib/types/Carts';
import { CartItems } from './components/CartItems';
import { EmptyImageData } from '@/components/custom/EmptyData';
import { formatCurrency } from '@/helpers/formatAmountPh';
import {
  Card,
  CardContent,
  CardHeader,
  CardFooter,
} from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { calculateCartTotal } from '@/app/user/[userId]/pos/helpers/calculateCartTotal';
import { GoToCashier } from './components/GoToCashier';

export default async function Shop({
  params,
  searchParams,
}: {
  params: Promise<{ cartId: string }>;
  searchParams: Promise<{ page: string; search: string; category: string }>;
}): Promise<JSX.Element> {
  const { cartId } = await params;
  const { page, search, category } = await searchParams;

  const hasFilterCategory = !category
    ? `?page=${page || 1}&perPage=10&search=${search}&sortBy=created_at`
    : `?page=${page || 1}&perPage=10&search=${search}&sortBy=created_at&filter=${category}`;

  const response = await getProducts(hasFilterCategory);

  const cartResponse = await getCartsById(cartId);

  const cartItems = !cartId ? [] : await getCartItemsById(cartId, 'active');
  const subTotal = calculateCartTotal(cartItems as CartItemsProducts[]);
  const countCartItems = (cartItems as CartItemsProducts[]).length;

  return (
    <Container title="Shops" description="Customers can shops here">
      {cartResponse?.status === 'unpaid' && (
        <div className="flex items-center justify-center">
          <Card className="w-full max-w-lg shadow-xs">
            <CardHeader>
              <h1>
                <strong className="text-3xl font-bold">Congratulations!</strong>
              </h1>
              <span className="text-gray-500">
                for checking out your product, please proceed to any available
                cashier, the id below is your cart identification.
              </span>
            </CardHeader>
            <CardContent className="space-y-4 text-center">
              <Badge className="text-xl font-bold">
                {cartResponse.code_token}
              </Badge>
            </CardContent>
            <CardFooter>
              <GoToCashier cartId={cartId} title="Reset Cart" status="active" />
            </CardFooter>
          </Card>
        </div>
      )}
      {cartResponse?.status === 'active' && (
        <main className="flex gap-2">
          <section className="flex-3">
            <ProductCards
              {...{
                cartId,
                products: response.products,
                totalPages: response?.totalPages,
                currentPage: response?.currentPage,
                count: response?.count,
              }}
            />
          </section>
          <section className="flex-2 space-y-4">
            <div>
              <h1 className="text-3xl font-bold">Cart Orders</h1>
              <p className="text-gray-500">
                all user cart orders can be seen here
              </p>
            </div>
            <section
              className={`${countCartItems > 0 ? 'h-[20rem]' : 'h-auto'} space-y-4 overflow-auto`}
            >
              {countCartItems <= 0 ? (
                <EmptyImageData />
              ) : (
                (cartItems as CartItemsProducts[]).map(
                  (item: CartItemsProducts) => (
                    <CartItems key={item.id} cartItems={item} />
                  ),
                )
              )}
            </section>

            <Card className="w-full border-none shadow-none">
              <CardFooter className="flex items-center justify-between py-4">
                <span className="text-foreground text-sm font-bold">
                  Total payment
                </span>
                <span className="text-foreground text-lg font-bold">
                  {formatCurrency(subTotal)}
                </span>
              </CardFooter>

              {countCartItems > 0 && (
                <GoToCashier
                  cartId={cartId}
                  title="Go to Cashier"
                  status="unpaid"
                />
              )}
            </Card>
          </section>
        </main>
      )}
    </Container>
  );
}
