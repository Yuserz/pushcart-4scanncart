-- Store catalog for the SCANnCART seven-class grocery detector.
--
-- Safe to re-run (cloud: `make cloud-seed`): every insert is keyed on a natural key, so a
-- second run changes nothing. Accounts are not created here; `make seed-accounts` makes
-- them through the Auth admin API, since auth.users rows need GoTrue-managed fields.
DO $$
DECLARE
  v_cat_canned_id UUID;
  v_cat_drinks_id UUID;
  v_cat_noodles_id UUID;
  v_cat_condiments_id UUID;
  v_cat_personal_id UUID;
BEGIN
  -- ==========================================
  -- 1. VAT RATE
  -- ==========================================

  INSERT INTO public.vat_rates (name, rate, is_active)
  SELECT 'Standard VAT', 12.00, true
  WHERE NOT EXISTS (SELECT 1 FROM public.vat_rates WHERE name = 'Standard VAT');

  -- ==========================================
  -- 2. CATEGORIES
  -- ==========================================
  -- UNIQUE(name, parent_id) does not fire for top-level rows (NULL parent), so guard by name.

  INSERT INTO public.categories (name, description)
  SELECT v.name, v.description
  FROM (VALUES
    ('Canned Goods', 'Sardines, tuna and other canned food'),
    ('Beverages', 'Powdered milk and drink sachets'),
    ('Instant Noodles', 'Pancit canton and instant noodles'),
    ('Condiments', 'Vinegar, soy sauce and cooking essentials'),
    ('Personal Care', 'Soap and toiletries')
  ) AS v(name, description)
  WHERE NOT EXISTS (
    SELECT 1 FROM public.categories c WHERE c.name = v.name AND c.parent_id IS NULL
  );

  SELECT id INTO v_cat_canned_id FROM public.categories WHERE name = 'Canned Goods' AND parent_id IS NULL;
  SELECT id INTO v_cat_drinks_id FROM public.categories WHERE name = 'Beverages' AND parent_id IS NULL;
  SELECT id INTO v_cat_noodles_id FROM public.categories WHERE name = 'Instant Noodles' AND parent_id IS NULL;
  SELECT id INTO v_cat_condiments_id FROM public.categories WHERE name = 'Condiments' AND parent_id IS NULL;
  SELECT id INTO v_cat_personal_id FROM public.categories WHERE name = 'Personal Care' AND parent_id IS NULL;

  -- ==========================================
  -- 3. PRODUCTS
  -- ==========================================
  -- One product per detector class. Prices are typical sari-sari/supermarket prices (PHP).
  -- Silver Swan is deliberately low (4) so the dashboard's low-stock list and the POS
  -- insufficient-stock check have something to show.

  INSERT INTO public.products (name, sku, price, stock_quantity, category_id) VALUES
    ('Bear Brand Fortified Powdered Milk 33g', 'SKU-BEAR-033', 16.00, 50, v_cat_drinks_id),
    ('Milo Chocolate Drink 22g Sachet', 'SKU-MILO-022', 10.00, 60, v_cat_drinks_id),
    ('Lucky Me Pancit Canton Calamansi 60g', 'SKU-LMPC-060', 17.00, 40, v_cat_noodles_id),
    ('555 Sardines 155g', 'SKU-555S-155', 25.00, 30, v_cat_canned_id),
    ('Century Tuna Flakes in Oil 155g', 'SKU-CTFO-155', 42.00, 25, v_cat_canned_id),
    ('Silver Swan Sukang Puti 200ml', 'SKU-SSSP-200', 14.00, 4, v_cat_condiments_id),
    ('Safeguard Pure White 60g', 'SKU-SGPW-060', 28.00, 20, v_cat_personal_id)
  ON CONFLICT (sku) DO NOTHING;

  -- ==========================================
  -- 4. DETECTOR CLASS -> PRODUCT MAP
  -- ==========================================
  -- class_slug is the detector's class name *verbatim* (scanncart SLUG_TO_CLASS): the
  -- desktop posts the raw model label as class_name, and pos_reconcile matches it exactly.

  INSERT INTO public.product_class_map (class_slug, product_id, note)
  SELECT v.class_name, p.id, 'seed'
  FROM (VALUES
    ('Bear Brand Fortified Powdered Milk 33g', 'SKU-BEAR-033'),
    ('Milo Chocolate Drink 22g Sachet', 'SKU-MILO-022'),
    ('lucky_me_pancit_canton_calamansi_flavor', 'SKU-LMPC-060'),
    ('555 sardines 155grams', 'SKU-555S-155'),
    ('century_tuna_flakes_in_oil_155_grams', 'SKU-CTFO-155'),
    ('silver_swan_sukang_puti_200ML', 'SKU-SSSP-200'),
    ('safeguard_pure_white_60g', 'SKU-SGPW-060')
  ) AS v(class_name, sku)
  JOIN public.products p ON p.sku = v.sku
  ON CONFLICT (class_slug) DO NOTHING;

  -- ==========================================
  -- 5. STATIONS
  -- ==========================================
  -- `counter-1` is the SCANnCART desktop's default station id.

  INSERT INTO public.stations (id, name) VALUES
    ('counter-1', 'Counter 1')
  ON CONFLICT (id) DO NOTHING;

END $$;
