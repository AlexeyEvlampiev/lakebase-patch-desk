/*
<pgmi-meta id="1a994ed6-681d-4647-83f7-1975c1ecaf73" idempotent="true">
  <description>Catalogue kernels and views: add a missing product, a product field as text, the product view.</description>
  <sortKeys><key>005/100/catalogue/2</key></sortKeys>
</pgmi-meta>
*/

-- Add a product when its code is not there yet; an existing product is left
-- as it is, so a seed run again never undoes an approved fix. Returns the new
-- row, or a row of NULLs when the code already exists.
CREATE OR REPLACE FUNCTION core.fn_add_product(
    p_product_code text,
    p_name         text,
    p_category     text,
    p_unit_price   numeric)
RETURNS core.product
LANGUAGE sql AS $$
    INSERT INTO core.product (product_code, name, category, unit_price)
    VALUES (btrim(p_product_code), btrim(p_name), p_category, p_unit_price)
    ON CONFLICT (product_code) DO NOTHING
    RETURNING *;
$$;

-- The value of one patchable field, as text: how a patch line records the
-- value seen at upload and how approval compares it. NULL for a field the
-- desk does not patch.
CREATE OR REPLACE FUNCTION core.fn_product_field_text(p_product core.product, p_field text)
RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE p_field
        WHEN 'name'       THEN p_product.name
        WHEN 'category'   THEN p_product.category
        WHEN 'unit_price' THEN p_product.unit_price::text
        WHEN 'active'     THEN p_product.active::text
    END;
$$;

SELECT core.ensure_view('core.vw_product', $view$
    CREATE OR REPLACE VIEW core.vw_product WITH (security_invoker = true) AS
    SELECT p.product_code,
           p.name,
           p.category,
           c.name AS category_name,
           p.unit_price,
           p.active,
           p.updated_at
    FROM core.product p
    JOIN core.category c ON c.code = p.category
$view$);
COMMENT ON VIEW core.vw_product IS 'Products with their category name. Read-only; changes go through approved patches.';
COMMENT ON COLUMN core.vw_product.product_code IS 'The product''s code, its key.';
COMMENT ON COLUMN core.vw_product.name IS 'The product''s name.';
COMMENT ON COLUMN core.vw_product.category IS 'The code of the product''s category.';
COMMENT ON COLUMN core.vw_product.category_name IS 'The name of the product''s category.';
COMMENT ON COLUMN core.vw_product.unit_price IS 'The price of one unit.';
COMMENT ON COLUMN core.vw_product.active IS 'Whether the product is sold.';
COMMENT ON COLUMN core.vw_product.updated_at IS 'When an approved patch last changed the product.';
