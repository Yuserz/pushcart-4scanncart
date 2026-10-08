-- Staff can clear the basket review from the admin POS screen, not only from the
-- desktop's "Basket checked" button. Two pieces:
--
-- 1. `review_cleared_at` on the open session: stamped by the admin route, read by the
--    desktop's session poll. It is both the audit trail and the desktop's signal — the
--    ledger resolves the interactions the staff just eyeballed, so the next sync does
--    not re-raise what a human just cleared.
--
-- 2. An as-of guard in pos_set_review: the desktop's sync states its pending count
--    "as of" the newest unresolved interaction. A count whose newest interaction
--    predates the staff clear loses to the clear; a newer one (a fresh interaction
--    after staff checked) wins. Without it, the desktop's next heartbeat would
--    re-post the cleared review for up to one poll cycle and the tablet banner
--    would flicker back on.

ALTER TABLE public.station_sessions
    ADD COLUMN review_cleared_at TIMESTAMPTZ;

CREATE OR REPLACE FUNCTION public.pos_set_review(
    p_session_ref TEXT,
    p_station_id TEXT,
    p_pending INT,
    p_reasons JSONB,
    p_review_as_of TIMESTAMPTZ DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
DECLARE
    v_cleared_at TIMESTAMPTZ;
BEGIN
    SELECT review_cleared_at INTO v_cleared_at
      FROM public.station_sessions
     WHERE session_ref = p_session_ref
       AND station_id = p_station_id
       AND status = 'open';

    IF NOT FOUND THEN
        RETURN jsonb_build_object('error', 'session_closed');
    END IF;

    -- A raise whose newest interaction is older than the staff clear is stale news
    -- about a basket a human has already checked; leave the clear standing.
    IF COALESCE(p_pending, 0) > 0
       AND p_review_as_of IS NOT NULL
       AND v_cleared_at IS NOT NULL
       AND p_review_as_of <= v_cleared_at THEN
        RETURN jsonb_build_object('status', 'stale');
    END IF;

    UPDATE public.station_sessions
       SET pending_review = GREATEST(COALESCE(p_pending, 0), 0),
           review_reasons = COALESCE(p_reasons, '[]'::jsonb)
     WHERE session_ref = p_session_ref
       AND station_id = p_station_id
       AND status = 'open';

    RETURN jsonb_build_object('status', 'ok');
END;
$$;
REVOKE EXECUTE ON FUNCTION public.pos_set_review(TEXT, TEXT, INT, JSONB, TIMESTAMPTZ) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.pos_set_review(TEXT, TEXT, INT, JSONB, TIMESTAMPTZ) TO service_role;
