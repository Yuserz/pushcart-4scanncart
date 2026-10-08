'use client';

import { JSX, useCallback, useEffect, useRef, useState } from 'react';
import { useParams, useRouter } from 'next/navigation';
import Image from 'next/image';
import { Container } from '@/components/custom/Container';
import { CustomButton } from '@/components/custom/CustomButton';
import {
  Card,
  CardContent,
  CardFooter,
  CardHeader,
} from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Separator } from '@/components/ui/separator';
import { Alert, AlertDescription, AlertTitle } from '@/components/ui/alert';
import {
  AlertTriangle,
  CameraOff,
  CheckCircle2,
  EyeOff,
  KeyRound,
  ShieldAlert,
} from 'lucide-react';
import {
  calculateVat,
  calculateTotalPayment,
} from '@/app/user/[userId]/pos/helpers/calculateVat';
import { signOut } from '@/services/auth/auth.services';
import {
  finishPosCart,
  getActiveVatRate,
  getMySession,
  getPosCartItems,
  PosApiError,
  staffRemovePosItem,
  type PosCartItem,
  type PosSessionInfo,
} from '@/services/pos/pos.services';

const POLL_MS = 2000;
const CAMERA_OFFLINE_MS = 30000;
const CONFIRM_COUNTDOWN_S = 6;

export default function ScanPage(): JSX.Element {
  const params = useParams<{ userId: string; cartId: string }>();
  const { userId, cartId } = params;
  const router = useRouter();

  const [items, setItems] = useState<PosCartItem[]>([]);
  const [session, setSession] = useState<PosSessionInfo | null>(null);
  const [loaded, setLoaded] = useState(false);
  const [loadError, setLoadError] = useState('');
  const [editing, setEditing] = useState(false);
  const mutation = useRef(false);
  const loading = useRef(false);
  const [rate, setRate] = useState<number>(0);
  const [offline, setOffline] = useState<boolean>(false);
  const [message, setMessage] = useState<string>('');
  const [finishing, setFinishing] = useState<boolean>(false);
  const [done, setDone] = useState<boolean>(false);
  const [countdown, setCountdown] = useState<number>(CONFIRM_COUNTDOWN_S);
  // Staff correction: the cart is the camera's, so the only manual change is a staff member
  // lowering a quantity. The PIN is held only while staff mode is open and is checked on the
  // server with every removal.
  const [staffOpen, setStaffOpen] = useState<boolean>(false);
  const [pin, setPin] = useState<string>('');
  const [staffMode, setStaffMode] = useState<boolean>(false);

  const load = useCallback(async (): Promise<void> => {
    if (loading.current) return;
    loading.current = true;
    try {
      const mySession = await getMySession();
      if (!mySession || mySession.cart_id !== cartId) {
        setSession(null);
        setItems([]);
        setLoadError(
          'This checkout is no longer available. Return to the start screen to continue.',
        );
        return;
      }
      const [cartItems, vatRate] = await Promise.all([
        getPosCartItems(cartId),
        getActiveVatRate(),
      ]);
      setLoadError('');

      setItems(cartItems);
      setSession(mySession);
      setRate(vatRate);

      const lastSync = mySession?.last_sync_at
        ? Date.parse(mySession.last_sync_at)
        : 0;
      setOffline(!lastSync || Date.now() - lastSync > CAMERA_OFFLINE_MS);
    } catch {
      setLoadError(
        'Could not refresh your cart. Retrying automatically; please wait before finishing.',
      );
    } finally {
      setLoaded(true);
      loading.current = false;
    }
  }, [cartId]);

  useEffect(() => {
    void load();
    const timer = setInterval(() => {
      if (!mutation.current) void load();
    }, POLL_MS);
    return () => clearInterval(timer);
  }, [load]);

  // After a successful Finish, sign the customer out and clear the tablet for the next one.
  useEffect(() => {
    if (!done) return;
    if (countdown <= 0) {
      void signOut().finally(() => {
        router.push(`/customer/${userId}/scan-start`);
      });
      return;
    }
    const timer = setTimeout(() => setCountdown((c) => c - 1), 1000);
    return () => clearTimeout(timer);
  }, [done, countdown, router, userId]);

  const leaveStaffMode = (): void => {
    setStaffMode(false);
    setStaffOpen(false);
    setPin('');
  };

  const onStaffRemove = (item: PosCartItem): void => {
    if (mutation.current) return;
    mutation.current = true;
    setEditing(true);
    void (async () => {
      setMessage('');
      try {
        await staffRemovePosItem(cartId, item.product_id, 1, pin);
        await load();
      } catch (error) {
        const code = error instanceof PosApiError ? error.message : '';
        if (code === 'staff_pin_invalid' || code === 'staff_pin_locked') {
          leaveStaffMode();
          setMessage(
            code === 'staff_pin_locked'
              ? 'Too many wrong PINs. Wait a minute and try again.'
              : 'Wrong staff PIN.',
          );
        } else if (code === 'staff_removal_disabled') {
          leaveStaffMode();
          setMessage('Staff removal is not enabled on this counter.');
        } else {
          setMessage(String(error));
        }
      } finally {
        mutation.current = false;
        setEditing(false);
      }
    })();
  };

  const onFinish = (): void => {
    if (mutation.current || !loaded || loadError) return;
    mutation.current = true;
    void (async () => {
      setFinishing(true);
      setMessage('');
      try {
        await finishPosCart(cartId);
        setDone(true);
      } catch (error) {
        if (
          error instanceof PosApiError &&
          error.message === 'review_pending'
        ) {
          setMessage(
            'The camera needs a staff check before you can finish. Please wait for staff.',
          );
        } else if (
          error instanceof PosApiError &&
          error.message === 'insufficient_stock'
        ) {
          const short = (error.data?.items ?? []) as { name: string }[];
          setMessage(
            `These items need staff: ${short.map((i) => i.name).join(', ')}`,
          );
        } else {
          setMessage(String(error));
        }
      } finally {
        mutation.current = false;
        setFinishing(false);
      }
    })();
  };

  const subtotal = items.reduce(
    (acc, item) => acc + (item.products?.price ?? 0) * item.quantity,
    0,
  );
  const reviewPending = (session?.pending_review ?? 0) > 0;
  const vat = calculateVat(subtotal, rate);
  const total = calculateTotalPayment(subtotal, vat);

  if (done) {
    return (
      <Container title="Thank you" description="Your order is complete">
        <div className="flex items-center justify-center py-10">
          <Card className="w-full max-w-lg text-center shadow-xs">
            <CardHeader className="items-center">
              <CheckCircle2 className="h-12 w-12 text-green-600" />
              <h1 className="text-3xl font-bold">Order placed</h1>
            </CardHeader>
            <CardContent>
              <p className="text-gray-500">
                Your order is complete. Returning to the start screen in{' '}
                {countdown}s.
              </p>
            </CardContent>
          </Card>
        </div>
      </Container>
    );
  }

  return (
    <Container
      title="Your cart"
      description="Items are added and removed automatically as you put them in or take them out of the basket"
    >
      <div className="mx-auto flex max-w-2xl flex-col gap-4">
        {loadError && (
          <Alert className="border-red-500 bg-red-500/20">
            <AlertTriangle className="h-4 w-4" />
            <AlertTitle>Cart unavailable</AlertTitle>
            <AlertDescription>{loadError}</AlertDescription>
            <Button
              variant="outline"
              className="col-span-2 justify-self-start"
              onClick={() => router.push(`/customer/${userId}/scan-start`)}
            >
              Return to start
            </Button>
          </Alert>
        )}
        {!loaded && <p role="status">Loading your cart…</p>}
        {offline && !loadError && (
          <Alert className="border-amber-500 bg-amber-500/20">
            <CameraOff className="h-4 w-4" />
            <AlertTitle>Camera offline</AlertTitle>
            <AlertDescription>
              Ask staff to add items. You can still review and finish your cart.
            </AlertDescription>
          </Alert>
        )}

        {reviewPending && !loadError && (
          <Alert className="border-amber-500 bg-amber-500/20">
            <ShieldAlert className="h-4 w-4" />
            <AlertTitle>Staff check needed</AlertTitle>
            <AlertDescription>
              The camera saw something it could not count for sure. Staff will
              check the basket before you finish.
              {(session?.review_reasons ?? []).length > 0 && (
                <ul className="mt-1 list-disc pl-5">
                  {(session?.review_reasons ?? [])
                    .slice(-3)
                    .map((reason, i) => (
                      <li key={i}>{reason}</li>
                    ))}
                </ul>
              )}
            </AlertDescription>
          </Alert>
        )}

        {message && (
          <Alert className="border-red-500 bg-red-500/20">
            <AlertTriangle className="h-4 w-4" />
            <AlertTitle>Note!</AlertTitle>
            <AlertDescription>{message}</AlertDescription>
          </Alert>
        )}

        {!loadError && (
          <Card className="w-full shadow-xs">
            <CardHeader className="flex items-center justify-between">
              <h1 className="text-2xl font-bold">Items</h1>
              {(session?.shopper_code || session?.cart_code) && (
                <Badge variant="secondary">
                  {session?.shopper_code ??
                    `Cart ${session?.cart_code.slice(0, 8)}`}
                </Badge>
              )}
            </CardHeader>
            <CardContent className="space-y-4">
              {loaded && !loadError && items.length === 0 && (
                <p className="py-8 text-center text-gray-500">
                  Place an item on the counter.
                </p>
              )}

              {items.map((item) => (
                <div
                  key={item.id}
                  className="flex items-center justify-between gap-3"
                >
                  <section className="flex items-center gap-3">
                    <Image
                      src={item.products.image_url || '/images/empty-food.jpg'}
                      width={500}
                      height={500}
                      alt={item.products.name}
                      className={`h-16 w-16 rounded-lg object-cover ${
                        item.camera_lost_at ? 'opacity-50' : ''
                      }`}
                    />
                    <div>
                      <h2 className="text-lg font-bold">
                        {item.products.name}
                      </h2>
                      <p className="text-gray-500">
                        ₱{item.products.price.toFixed(2)}
                      </p>
                      {/* The camera stopped seeing this item, so its quantity is held by the
                          desktop's floor rather than observed. Saying so keeps a row that would
                          otherwise sit silently from reading as a vanish (spec §6). */}
                      {item.camera_lost_at && (
                        <p
                          className="mt-1 flex items-center gap-1 text-xs font-medium text-amber-600"
                          role="status"
                        >
                          <EyeOff className="h-3.5 w-3.5 shrink-0" />
                          Camera lost this item — still in your cart
                        </p>
                      )}
                    </div>
                  </section>

                  <section className="flex items-center gap-2">
                    <Badge
                      variant="secondary"
                      className="min-w-8 justify-center"
                      aria-label={`Quantity of ${item.products.name}`}
                    >
                      ×{item.quantity}
                    </Badge>
                    {staffMode && (
                      <Button
                        size="sm"
                        variant="outline"
                        aria-label={`Staff: remove one ${item.products.name}`}
                        disabled={editing || finishing || Boolean(loadError)}
                        onClick={() => onStaffRemove(item)}
                      >
                        Remove 1
                      </Button>
                    )}
                  </section>
                </div>
              ))}

              <Separator />

              <div className="space-y-1 text-sm">
                <div className="flex justify-between">
                  <span>Subtotal</span>
                  <span>₱{subtotal.toFixed(2)}</span>
                </div>
                <div className="flex justify-between text-gray-500">
                  <span>VAT ({rate.toFixed(2)}%)</span>
                  <span>₱{vat.toFixed(2)}</span>
                </div>
                <div className="flex justify-between text-lg font-bold">
                  <span>Total</span>
                  <span>₱{total.toFixed(2)}</span>
                </div>
              </div>
            </CardContent>
            <CardFooter>
              <CustomButton
                className="w-full"
                onClick={onFinish}
                isLoading={finishing}
                disabled={
                  finishing ||
                  editing ||
                  !loaded ||
                  Boolean(loadError) ||
                  reviewPending ||
                  items.length === 0
                }
              >
                Finish
              </CustomButton>
            </CardFooter>
          </Card>
        )}

        {!loadError && (
          <p className="text-center text-xs text-gray-400">
            Put items in one at a time, label towards the camera. To take one
            back, lift it out of the basket the same way. Ask staff for anything
            the camera misses.
          </p>
        )}

        {!loadError && items.length > 0 && (
          <div className="flex flex-col items-center gap-2">
            {staffMode ? (
              <Button variant="ghost" size="sm" onClick={leaveStaffMode}>
                Done (staff)
              </Button>
            ) : staffOpen ? (
              <form
                className="flex items-center gap-2"
                onSubmit={(e) => {
                  e.preventDefault();
                  if (pin) setStaffMode(true);
                }}
              >
                <input
                  type="password"
                  inputMode="numeric"
                  autoComplete="off"
                  aria-label="Staff PIN"
                  placeholder="Staff PIN"
                  className="w-32 rounded-md border px-2 py-1 text-sm"
                  value={pin}
                  onChange={(e) => setPin(e.target.value)}
                />
                <Button
                  type="submit"
                  size="sm"
                  variant="outline"
                  disabled={!pin}
                >
                  Unlock
                </Button>
                <Button
                  type="button"
                  size="sm"
                  variant="ghost"
                  onClick={leaveStaffMode}
                >
                  Cancel
                </Button>
              </form>
            ) : (
              <Button
                variant="ghost"
                size="sm"
                onClick={() => setStaffOpen(true)}
              >
                <KeyRound className="mr-1 h-4 w-4" /> Staff
              </Button>
            )}
          </div>
        )}
      </div>
    </Container>
  );
}
