/*
<pgmi-meta id="a57165f6-1ce9-4ec7-80ec-c04b74254d1e" idempotent="false">
  <description>The product catalogue: categories and products, one list shared by every organization.</description>
  <sortKeys><key>005/100/catalogue/1</key></sortKeys>
</pgmi-meta>
*/
-- One catalogue for the whole database, not one per organization: the patch
-- desk fixes one product list. Categories come from
-- data/catalogs/core.category.json; products are written only by kernels
-- (core/catalogue.sql, core/patch.sql): the seed adds missing ones, an
-- approved patch changes them.

CREATE TABLE core.category (
    code text PRIMARY KEY CONSTRAINT category_code_check CHECK (btrim(code) <> ''),
    name text NOT NULL CONSTRAINT category_name_check CHECK (btrim(name) <> '')
);

CREATE TABLE core.product (
    product_code text PRIMARY KEY CONSTRAINT product_code_check CHECK (btrim(product_code) <> ''),
    name         text NOT NULL CONSTRAINT product_name_check CHECK (btrim(name) <> ''),
    category     text NOT NULL CONSTRAINT product_category_fkey REFERENCES core.category (code),
    unit_price   numeric(12,2) NOT NULL
                 CONSTRAINT product_unit_price_check CHECK (unit_price > 0)
                 -- numeric accepts 'NaN' and orders it above every number,
                 -- so > 0 alone lets it through.
                 CONSTRAINT product_unit_price_finite_check CHECK (unit_price <> 'NaN'),
    active       boolean NOT NULL DEFAULT true,
    updated_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_product_category ON core.product (category);

COMMENT ON TABLE core.category IS 'The allowed product categories (data/catalogs/core.category.json).';
COMMENT ON TABLE core.product IS 'Current product reference data, shared by every organization. Patches change it only through approval.';

SELECT pg_temp.exempt_from_rls('core.category', 'shared catalogue: reference data synced by the deploy, the same for every organization');
SELECT pg_temp.exempt_from_rls('core.product', 'shared catalogue: one product list for every organization, written only by kernels');
