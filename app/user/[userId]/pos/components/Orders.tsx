'use client';

import { JSX, ReactNode, useState, useTransition, useMemo } from 'react';
import { ShoppingCart, Coins, X } from 'lucide-react';
import { CartItemsProducts, Carts, OrderSteps } from '@/lib/types/Carts';
import { Card, CardContent, CardFooter } from '@/components/ui/card';
import { Separator } from '@/components/ui/separator';
import { OrdersCard } from './OrdersCards';
import { OrdersTable } from './OrdersTable';
import { TabsContainer } from '@/components/custom/Tabs';
import { EmptyContainer } from '@/components/custom/EmptyContainer';
import { MenuOptions } from '@/lib/types/MenuOptions';
import { calculateCartTotal } from '../helpers/calculateCartTotal';
import { calculateTotalPayment, calculateVat } from '../helpers/calculateVat';
import { formatCurrency } from '@/helpers/formatAmountPh';
import { CustomButton } from '@/components/custom/CustomButton';
import { addOrders } from '@/services/orders/orders.services';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { OrdersInsert } from '@/lib/types/Orders';
import { useRouter } from 'next/navigation';
import { usePathname } from 'next/navigation';
import { debounce } from 'lodash';
import { Vat } from '@/lib/types/vat';
import { useRealtimeCarts } from '../helpers/useRealtimeCarts';

interface OrdersForm {
  cartItems: CartItemsProducts[];
  carts: Carts[];
  cartId: string;
  userId: string;
  tax: Pick<Vat, 'id' | 'rate'>;
}

export function Orders({
  cartItems,
  carts,
  cartId,
  userId,
  tax,
}: OrdersForm): JSX.Element {
  const [currentStep, setCurrentStep] = useState<OrderSteps>('calculations');
  const [isPending, startTransition] = useTransition();
  const [hasDiscount, setHasDiscount] = useState<boolean>(false);
  const [discount, setDiscount] = useState<number>(0);

  const pathname = usePathname();
  const router = useRouter();

  useRealtimeCarts();

  const tabsOptions: MenuOptions[] = [
    {
      value: 'calculations',
      label: 'Calculations',
    },
    {
      value: 'orders',
      label: 'Orders',
    },
  ];

  const vatRate = tax?.rate || 0;
  const subTotal = calculateCartTotal(cartItems) - discount;
  const vatTax = calculateVat(subTotal, vatRate);
  const totalPayment = calculateTotalPayment(subTotal, vatTax);

  const toggleDiscount = (): void => {
    setHasDiscount((prevState) => !prevState);
  };

  const onDebounce = useMemo(
    () =>
      debounce((value) => {
        if (value) {
          router.replace(`${pathname}?search=${value}`);
          return;
        }

        router.replace(pathname);
      }, 500),
    [pathname, router],
  );

  const onSearch = (event: React.ChangeEvent<HTMLInputElement>): void => {
    const { value } = event.target;
    onDebounce(value);
  };

  const onCompleteOrder = (): void => {
    startTransition(async () => {
      const data = {
        subtotal: subTotal,
        vat_amount: vatTax,
        discount_amount: discount,
        total_amount: totalPayment,
        cart_id: cartId,
        user_id: userId,
      } as OrdersInsert;

      await addOrders(data);
      router.refresh();
      setDiscount(0);
      setHasDiscount(false);
    });
  };

  const isDisabledButton = cartItems.length > 0;

  const tabContent: { [key: string]: ReactNode } = {
    calculations: (
      <Card className="w-full max-w-sm border-none shadow-none">
        <CardContent className="space-y-4 pt-6">
          {/* Subtotal Row */}
          <div className="flex items-center justify-between text-sm">
            <span className="text-muted-foreground">Subtotal</span>
            <span className="text-foreground font-semibold">
              {formatCurrency(subTotal)}
            </span>
          </div>

          {/* Service Tax Row */}
          <div className="flex items-center justify-between text-sm">
            <span className="text-muted-foreground">
              Service Tax ({vatRate}%)
            </span>
            <span className="text-foreground font-semibold">
              {formatCurrency(vatTax)}
            </span>
          </div>

          {/* Discount Row */}
          <div className="flex items-center justify-between text-sm">
            <span className="text-muted-foreground">Discount</span>
            <span className="text-foreground font-semibold">
              {formatCurrency(discount)}
            </span>
          </div>

          {hasDiscount && (
            <div className="flex items-center gap-2">
              <Input
                type="number"
                placeholder="0"
                title="Discount"
                onChange={(e) => {
                  const target = e.target as HTMLInputElement;
                  setDiscount(Number(target.value));
                }}
              />
              <X
                className="mt-6 cursor-pointer text-gray-400"
                onClick={toggleDiscount}
              />
            </div>
          )}
        </CardContent>

        <Separator className="my-2" />

        <CardFooter className="flex items-center justify-between py-4">
          <span className="text-foreground text-sm font-bold">
            Total payment
          </span>
          <span className="text-foreground text-lg font-bold">
            {formatCurrency(totalPayment)}
          </span>
        </CardFooter>
      </Card>
    ),
    orders: (
      <div className="space-2-4 flex-2">
        {carts.length >= 0 && (
          <Input
            placeholder="Search user by id..."
            onChange={(event) => onSearch(event)}
            className="max-w-sm"
          />
        )}
        <OrdersCard carts={carts as Carts[]} />
        {carts.length <= 0 && <EmptyContainer />}
      </div>
    ),
  };

  const onChangeSteps = (value: OrderSteps): void => {
    if (value === 'calculations') {
      setCurrentStep(value);
      return;
    }

    setCurrentStep(value);
  };

  return (
    <div className="space-y-4">
      <section className="flex items-center justify-end gap-2">
        <Button onClick={toggleDiscount}>
          <Coins />
          Add Discount
        </Button>
        <CustomButton
          isLoading={isPending}
          disabled={isPending || !isDisabledButton}
          onClick={onCompleteOrder}
        >
          <ShoppingCart />
          Complete Order
        </CustomButton>
      </section>
      <section className="flex w-full gap-2">
        <div className="flex-4">
          <OrdersTable cartItems={cartItems as CartItemsProducts[]} />
        </div>
        <TabsContainer
          menuOptions={tabsOptions}
          currentStep={currentStep}
          changeOnClick={(value) => onChangeSteps(value as OrderSteps)}
        >
          {tabContent[currentStep]}
        </TabsContainer>
      </section>
    </div>
  );
}
