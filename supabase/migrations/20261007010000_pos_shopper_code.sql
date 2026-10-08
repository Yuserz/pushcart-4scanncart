-- Shopper display code: a human-readable daily label ("Shopper_0007") shown next to the
-- cart's UUID everywhere a customer or operator reads it. The UUID stays the machine key
-- (URLs, joins, orders); this is the label that tells staff and shoppers "7th shopper today".
--
-- Assignment rules:
--   * Drawn inside pos_open_session's transaction, so only an actual shopper consumes a
--     number — a cart that never opens a session keeps shopper_no NULL.
--   * The per-day counter row is bumped under row lock (INSERT .. ON CONFLICT DO UPDATE),
--     so two parallel Starts — even on different stations — draw distinct numbers.
--   * "Day" is shop-local (Asia/Manila), not UTC, so the count resets at local midnight.
--   * A cart re-opened on a later day draws the new day's next number; the old cart's
--     number stays on its own day's sequence, which is what the label claims to be.

ALTER TABLE public.carts
    ADD COLUMN shopper_no INT,
    ADD COLUMN shopper_day DATE;

CREATE TABLE public.pos_shopper_counters (
    day DATE PRIMARY KEY,
    last_no INT NOT NULL
);

-- Written only by the SECURITY DEFINER functions below; no client role reads it.
REVOKE ALL ON public.pos_shopper_counters FROM PUBLIC, anon, authenticated;

-- ============================================================
-- pos_open_session: assign the number between the busy-check and the session INSERT,
-- so a refused or raced Start never consumes one.
-- ============================================================
CREATE OR REPLACE FUNCTION public.pos_open_session(
    p_station_id TEXT,
    p_cart_id UUID,
    p_idle_cancel_minutes INT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_customer UUID;
    v_status TEXT;
    v_open_id UUID;
    v_last TIMESTAMPTZ;
    v_code UUID;
    v_ref TEXT;
    v_shopper_no INT;
    v_shopper_day DATE;
    v_today DATE;
BEGIN
    SELECT customer_id, status, code_token, shopper_no, shopper_day
      INTO v_customer, v_status, v_code, v_shopper_no, v_shopper_day
      FROM public.carts
     WHERE id = p_cart_id;

    IF NOT FOUND OR v_customer IS DISTINCT FROM auth.uid() THEN
        RETURN jsonb_build_object('error', 'forbidden');
    END IF;

    IF v_status <> 'active' THEN
        RETURN jsonb_build_object('error', 'cart_not_active');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM public.stations WHERE id = p_station_id) THEN
        RETURN jsonb_build_object('error', 'unknown_station');
    END IF;

    -- Lock any open session on this station and either clear an abandoned one or refuse.
    SELECT id, last_activity_at INTO v_open_id, v_last
      FROM public.station_sessions
     WHERE station_id = p_station_id AND status = 'open'
     FOR UPDATE;

    IF FOUND THEN
        IF v_last < now() - make_interval(mins => COALESCE(p_idle_cancel_minutes, 5)) THEN
            UPDATE public.station_sessions
               SET status = 'cancelled', ended_at = now()
             WHERE id = v_open_id;
        ELSE
            RETURN jsonb_build_object('error', 'busy');
        END IF;
    END IF;

    v_today := (now() AT TIME ZONE 'Asia/Manila')::date;
    IF v_shopper_no IS NULL OR v_shopper_day IS DISTINCT FROM v_today THEN
        INSERT INTO public.pos_shopper_counters (day, last_no)
        VALUES (v_today, 1)
        ON CONFLICT (day) DO UPDATE
            SET last_no = public.pos_shopper_counters.last_no + 1
        RETURNING last_no INTO v_shopper_no;

        UPDATE public.carts
           SET shopper_no = v_shopper_no, shopper_day = v_today
         WHERE id = p_cart_id;
    END IF;

    v_ref := 'scanncart-' || p_station_id || '-'
             || (extract(epoch FROM clock_timestamp()) * 1000)::bigint;

    BEGIN
        INSERT INTO public.station_sessions (station_id, session_ref, cart_id, status, last_activity_at)
        VALUES (p_station_id, v_ref, p_cart_id, 'open', now());
    EXCEPTION WHEN unique_violation THEN
        -- The partial unique index caught a race with another tablet.
        RETURN jsonb_build_object('error', 'busy');
    END;

    RETURN jsonb_build_object(
        'session_ref', v_ref,
        'cart_id', p_cart_id,
        'cart_code', v_code,
        'shopper_code', 'Shopper_' || lpad(v_shopper_no::text, 4, '0'));
END;
$$;

REVOKE EXECUTE ON FUNCTION public.pos_open_session(TEXT, UUID, INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pos_open_session(TEXT, UUID, INT) TO authenticated;

-- ============================================================
-- pos_my_session: report the label. lpad(NULL) is NULL, so carts that never
-- opened a session simply report no shopper_code. Built on the 20261003120000
-- definition — the review state the tablet reads must survive this rewrite.
-- ============================================================
CREATE OR REPLACE FUNCTION public.pos_my_session()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_out JSONB;
BEGIN
    SELECT jsonb_build_object(
        'session_ref', ss.session_ref,
        'cart_id', ss.cart_id,
        'cart_code', c.code_token,
        'shopper_code', 'Shopper_' || lpad(c.shopper_no::text, 4, '0'),
        -- Liveness for the tablet's "camera offline" notice: the desktop writes a
        -- pos_sync_log row for every sync (including the 15 s heartbeat).
        'last_sync_at', (
            SELECT MAX(l.created_at)
              FROM public.pos_sync_log l
             WHERE l.session_ref = ss.session_ref AND l.kind = 'sync'),
        'pending_review', ss.pending_review,
        'review_reasons', ss.review_reasons)
      INTO v_out
      FROM public.station_sessions ss
      JOIN public.carts c ON c.id = ss.cart_id
     WHERE ss.status = 'open'
       AND c.customer_id = auth.uid()
     ORDER BY ss.created_at DESC
     LIMIT 1;

    RETURN v_out;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.pos_my_session() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pos_my_session() TO authenticated;
