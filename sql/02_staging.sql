-- 02_staging.sql
-- Typed, cleaned views over the raw layer. Each rule traces to docs/data_quality_log.md.

CREATE SCHEMA IF NOT EXISTS staging;

-- Orders: typed timestamps plus quality flags (log items 7, 8, 12)
DROP VIEW IF EXISTS staging.orders CASCADE;
CREATE VIEW staging.orders AS
WITH typed AS (
    SELECT
        order_id,
        customer_id,
        order_status,
        NULLIF(order_purchase_timestamp, '')::timestamp      AS purchased_at,
        NULLIF(order_approved_at, '')::timestamp             AS approved_at,
        NULLIF(order_delivered_carrier_date, '')::timestamp  AS carrier_at,
        NULLIF(order_delivered_customer_date, '')::timestamp AS delivered_at,
        NULLIF(order_estimated_delivery_date, '')::timestamp AS estimated_at
    FROM raw.orders
)
SELECT
    typed.*,
    (purchased_at >= DATE '2017-01-01' AND purchased_at < DATE '2018-09-01') AS in_analysis_window,
    (order_status = 'delivered' AND delivered_at IS NOT NULL)                AS is_delivered_with_date,
    (COALESCE(carrier_at < purchased_at, FALSE)
     OR COALESCE(delivered_at < carrier_at, FALSE))                          AS has_timestamp_conflict
FROM typed;

-- Customers: zip prefix as integer so it joins cleanly to geolocation (log item 3 keeps both ids)
DROP VIEW IF EXISTS staging.customers CASCADE;
CREATE VIEW staging.customers AS
SELECT
    customer_id,
    customer_unique_id,
    customer_zip_code_prefix::int AS zip_prefix,
    INITCAP(TRIM(customer_city))  AS city,
    UPPER(TRIM(customer_state))   AS state
FROM raw.customers;

-- Order items: typed money and dates
DROP VIEW IF EXISTS staging.order_items CASCADE;
CREATE VIEW staging.order_items AS
SELECT
    order_id,
    order_item_id::int                          AS order_item_id,
    product_id,
    seller_id,
    NULLIF(shipping_limit_date, '')::timestamp  AS shipping_limit_at,
    price::numeric(10,2)                        AS price,
    freight_value::numeric(10,2)                AS freight_value
FROM raw.order_items;

-- Payments: flag the odd rows (log item 10)
DROP VIEW IF EXISTS staging.order_payments CASCADE;
CREATE VIEW staging.order_payments AS
SELECT
    order_id,
    payment_sequential::int       AS payment_sequential,
    payment_type,
    payment_installments::int     AS installments,
    payment_value::numeric(12,2)  AS payment_value,
    (payment_value::numeric = 0
     OR payment_type = 'not_defined'
     OR payment_installments::int = 0) AS is_odd_payment
FROM raw.order_payments;

-- Reviews: exactly one review per order, the latest (log item 4)
DROP VIEW IF EXISTS staging.order_reviews CASCADE;
CREATE VIEW staging.order_reviews AS
SELECT
    order_id,
    review_id,
    review_score::int                            AS review_score,
    NULLIF(review_creation_date, '')::timestamp  AS review_created_at,
    NULLIF(review_answer_timestamp, '')::timestamp AS review_answered_at
FROM (
    SELECT r.*,
           ROW_NUMBER() OVER (
               PARTITION BY order_id
               ORDER BY NULLIF(review_answer_timestamp, '')::timestamp DESC NULLS LAST,
                        NULLIF(review_creation_date, '')::timestamp DESC NULLS LAST,
                        review_id
           ) AS rn
    FROM raw.order_reviews r
) ranked
WHERE rn = 1;

-- Products: English category with fallbacks (log item 11)
DROP VIEW IF EXISTS staging.products CASCADE;
CREATE VIEW staging.products AS
SELECT
    p.product_id,
    COALESCE(NULLIF(t.product_category_name_english, ''),
             NULLIF(p.product_category_name, ''),
             'uncategorised')                          AS category,
    NULLIF(p.product_weight_g, '')::numeric            AS weight_g,
    NULLIF(p.product_length_cm, '')::numeric           AS length_cm,
    NULLIF(p.product_height_cm, '')::numeric           AS height_cm,
    NULLIF(p.product_width_cm, '')::numeric            AS width_cm,
    NULLIF(p.product_photos_qty, '')::numeric::int     AS photos_qty
FROM raw.products p
LEFT JOIN raw.product_category_name_translation t
       ON t.product_category_name = p.product_category_name;

-- Sellers
DROP VIEW IF EXISTS staging.sellers CASCADE;
CREATE VIEW staging.sellers AS
SELECT
    seller_id,
    seller_zip_code_prefix::int AS zip_prefix,
    INITCAP(TRIM(seller_city))  AS city,
    UPPER(TRIM(seller_state))   AS state
FROM raw.sellers;

-- Geolocation: one row per zip prefix (log item 9)
DROP VIEW IF EXISTS staging.geolocation CASCADE;
CREATE VIEW staging.geolocation AS
SELECT
    geolocation_zip_code_prefix::int  AS zip_prefix,
    AVG(geolocation_lat::numeric)     AS lat,
    AVG(geolocation_lng::numeric)     AS lng,
    MODE() WITHIN GROUP (ORDER BY UPPER(TRIM(geolocation_state))) AS state
FROM raw.geolocation
GROUP BY 1;


-- Prove staging matches your findings
SELECT 'staging.orders' AS view_name, COUNT(*) AS rows, 99441 AS expected FROM staging.orders
UNION ALL SELECT 'staging.customers', COUNT(*), 99441 FROM staging.customers
UNION ALL SELECT 'staging.order_items', COUNT(*), 112650 FROM staging.order_items
UNION ALL SELECT 'staging.order_payments', COUNT(*), 103886 FROM staging.order_payments
UNION ALL SELECT 'staging.order_reviews', COUNT(*), 98673 FROM staging.order_reviews
UNION ALL SELECT 'staging.products', COUNT(*), 32951 FROM staging.products
UNION ALL SELECT 'staging.sellers', COUNT(*), 3095 FROM staging.sellers
UNION ALL SELECT 'staging.geolocation', COUNT(*), 19015 FROM staging.geolocation;


-- Checking order flags
SELECT COUNT(*) FILTER (WHERE in_analysis_window)     AS in_window,
       COUNT(*) FILTER (WHERE is_delivered_with_date) AS delivered_with_date,
       COUNT(*) FILTER (WHERE has_timestamp_conflict) AS timestamp_conflicts
FROM staging.orders;