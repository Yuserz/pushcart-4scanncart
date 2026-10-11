'use client';

import { useEffect } from 'react';
import { useRouter } from 'next/navigation';
import { debounce } from 'lodash';
import { createClient } from '@/config/client';

// Refreshes the POS page whenever any cart is created or changes status,
// so all cashiers see customers heading to the cashier in real time.
export const useRealtimeCarts = (): void => {
  const router = useRouter();

  useEffect(() => {
    const supabase = createClient();
    const refresh = debounce(() => router.refresh(), 300);

    const channel = supabase
      .channel('pos-carts')
      .on(
        'postgres_changes',
        { event: '*', schema: 'public', table: 'carts' },
        refresh,
      )
      .subscribe();

    return () => {
      refresh.cancel();
      supabase.removeChannel(channel);
    };
  }, [router]);
};
