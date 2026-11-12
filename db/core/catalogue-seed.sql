/*
<pgmi-meta id="035d3774-4696-43b5-921e-7ce89dc4aa40" idempotent="true">
  <description>Catalogue seed: the categories from their catalog file, and the demo products when missing.</description>
  <sortKeys><key>005/100/catalogue/3</key></sortKeys>
</pgmi-meta>
*/
-- Runs on every deploy in every environment (it is not under dev/): the demo
-- deploys with env=test and needs the products too.
--
-- Categories are the whole content of data/catalogs/core.category.json.
-- Products are only added when missing (core.fn_add_product), never reset:
-- an approved patch changes a product, and the next deploy keeps the change.

SELECT pg_temp.sync_catalog('core.category');

SELECT count(p.product_code) AS products_added
FROM (VALUES
    ('P-1001', 'Sparkling water 1 l',      'BEV',   0.89),
    ('P-1002', 'Orange juice 1 l',         'BEV',   2.49),
    ('P-1003', 'Cold brew coffee 250 ml',  'BEV',   2.99),
    ('P-1004', 'Green tea, 20 bags',       'BEV',   3.29),
    ('P-2001', 'Sourdough loaf',           'BAKE',  3.95),
    ('P-2002', 'Butter croissant',         'BAKE',  1.20),
    ('P-2003', 'Rye crackers 200 g',       'BAKE',  2.15),
    ('P-2004', 'Cinnamon roll',            'BAKE',  1.85),
    ('P-3001', 'Whole milk 1 l',           'DAIRY', 1.19),
    ('P-3002', 'Greek yogurt 500 g',       'DAIRY', 2.79),
    ('P-3003', 'Aged gouda 200 g',         'DAIRY', 4.49),
    ('P-3004', 'Salted butter 250 g',      'DAIRY', 2.99),
    ('P-4001', 'Sea salt crisps 150 g',    'SNACK', 1.99),
    ('P-4002', 'Dark chocolate 100 g',     'SNACK', 2.29),
    ('P-4003', 'Roasted almonds 200 g',    'SNACK', 3.99),
    ('P-4004', 'Oat bar',                  'SNACK', 0.99),
    ('P-5001', 'Dish soap 500 ml',         'HOME',  2.49),
    ('P-5002', 'Paper towels, 4 rolls',    'HOME',  3.79),
    ('P-5003', 'Laundry pods, 20',         'HOME',  7.99),
    ('P-5004', 'Sponges, 5 pack',          'HOME',  1.49),
    ('P-6001', 'Apples 1 kg',              'FRESH', 2.49),
    ('P-6002', 'Carrots 1 kg',             'FRESH', 1.29),
    -- Deliberately wrong, for the planned AI agent to find:
    ('P-4005', 'Granola bar',              'SNACK', 39.90),  -- price far above its category
    ('P-3005', 'whole MILK  1 l',          'DAIRY', 1.25),   -- odd casing, doubled space
    ('P-5005', 'Bananas 1 kg',             'HOME',  1.89)    -- fruit filed under Household
) AS s(product_code, name, category, unit_price)
CROSS JOIN LATERAL core.fn_add_product(s.product_code, s.name, s.category, s.unit_price) AS p;
