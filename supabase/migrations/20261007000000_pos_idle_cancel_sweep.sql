-- ============================================================
-- Idle-cancel sweep: sessions expire on the clock, not on the next Start
-- ============================================================
-- Until now the only thing that cleared an abandoned session was `pos_open_session`'s
-- abandoned-session branch: the window in `POS_IDLE_CANCEL_MINUTES` was measured, but the
-- cancellation waited for the *next customer* to arrive. In between — which on a real counter
-- is most of the day — the session sat `open`: the departed customer's tablet kept showing a
-- live cart, the desktop stayed bound to it, and the "wait out POS_IDLE_CANCEL_MINUTES" advice
-- on a busy 409 only worked because the *new* customer's Start did the cancelling.
--
-- `pos_cancel_idle_sessions` is that same rule, run without a Start: every `open` session whose
-- `last_activity_at` is past the window is set to `cancelled` with `ended_at = now()`, all
-- stations in one statement, and the count is returned so the caller can log it. The desktop's
-- session poll (`GET /api/pos/session`, every 1–5 s while the app runs) calls it before its
-- read, which makes the poll the window's clock: an abandoned session is cancelled within one
-- poll of expiring, the desktop unbinds on the poll's empty answer, and the counter reads free
-- without anybody tapping Start.
--
-- What still does NOT count as activity is unchanged (§3.2 item 8): a heartbeat sync, a
-- `camera_lost_at` stamp and a review-only sync all leave `last_activity_at` alone, so "idle"
-- means exactly "the camera has had nothing to say about this cart for the window" — the same
-- reading `pos_open_session` has always used. The cancelled session's cart stays `active` with
-- no order (nothing is charged), the same as the on-Start cancel; its items keep their
-- `session_ref`, so they cannot leak into the next customer's cart.
--
-- `SECURITY DEFINER` like its siblings: the sweep must see and cancel sessions regardless of
-- which role asks. `POS_IDLE_CANCEL_MINUTES` is read by the route that calls this (it already
-- reads it for `pos_open_session`), so the window lives in one place — the environment.

CREATE OR REPLACE FUNCTION public.pos_cancel_idle_sessions(p_idle_cancel_minutes INT)
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_cancelled INT := 0;
BEGIN
    UPDATE public.station_sessions
       SET status = 'cancelled',
           ended_at = now()
     WHERE status = 'open'
       AND last_activity_at < now() - make_interval(mins => COALESCE(p_idle_cancel_minutes, 5));

    GET DIAGNOSTICS v_cancelled = ROW_COUNT;
    RETURN v_cancelled;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.pos_cancel_idle_sessions(INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pos_cancel_idle_sessions(INT) TO authenticated;
