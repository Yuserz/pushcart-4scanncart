-- Broadcast cart changes so every cashier's POS list updates live
ALTER PUBLICATION supabase_realtime ADD TABLE public.carts;
