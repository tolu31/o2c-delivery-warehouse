-- 03_marts.sql
-- Star schema built from the staging views. Grain is stated for every table.

CREATE SCHEMA IF NOT EXISTS marts;

DROP TABLE IF EXISTS marts.fact_order_items CASCADE;
DROP TABLE IF EXISTS marts.fact_orders      CASCADE;
DROP TABLE IF EXISTS marts.dim_customer     CASCADE;
DROP TABLE IF EXISTS marts.dim_product      CASCADE;
DROP TABLE IF EXISTS marts.dim_seller       CASCADE;
DROP TABLE IF EXISTS marts.dim_geography    CASCADE;
DROP TABLE IF EXISTS marts.dim_date         CASCADE;

-- dim_date: one row per calendar day
CREATE TABLE marts.dim_date AS
SELECT
    TO_CHAR(d, 'YYYYMMDD')::int       AS date_key,
    d::date                           AS date,
    EXTRACT(YEAR FROM d)::int         AS year,
    EXTRACT(QUARTER FROM d)::int      AS quarter,
    EXTRACT(MONTH FROM d)::int        AS month_number,
    TO_CHAR(d, 'Mon')                 AS month_name,
    TO_CHAR(d, 'YYYY-MM')             AS year_month,
    TO_CHAR(d, 'Dy')                  AS weekday_name,
    EXTRACT(ISODOW FROM d)::int       AS weekday_number,
    (d >= TIMESTAMP '2017-01-01' AND d < TIMESTAMP '2018-09-01') AS in_analysis_window
FROM generate_series(TIMESTAMP '2016-09-01', TIMESTAMP '2018-12-31', INTERVAL '1 day') AS g(d);
ALTER TABLE marts.dim_date ADD PRIMARY KEY (date_key);

-- dim_geography: one row per zip prefix
CREATE TABLE marts.dim_geography AS
SELECT zip_prefix, lat, lng, state FROM staging.geolocation;
ALTER TABLE marts.dim_geography ADD PRIMARY KEY (zip_prefix);

-- dim_customer: one row per PERSON, location taken from their latest order
CREATE TABLE marts.dim_customer AS
WITH latest AS (
    SELECT DISTINCT ON (c.customer_unique_id)
           c.customer_unique_id, c.zip_prefix, c.city, c.state
    FROM staging.customers c
    JOIN staging.orders o ON o.customer_id = c.customer_id
    ORDER BY c.customer_unique_id, o.purchased_at DESC, c.customer_id
)
SELECT ROW_NUMBER() OVER (ORDER BY customer_unique_id)::int AS customer_key,
       customer_unique_id, zip_prefix, city, state
FROM latest;
ALTER TABLE marts.dim_customer ADD PRIMARY KEY (customer_key);
CREATE UNIQUE INDEX ON marts.dim_customer (customer_unique_id);

-- dim_product
CREATE TABLE marts.dim_product AS
SELECT ROW_NUMBER() OVER (ORDER BY product_id)::int AS product_key,
       product_id, category, weight_g, length_cm, height_cm, width_cm, photos_qty
FROM staging.products;
ALTER TABLE marts.dim_product ADD PRIMARY KEY (product_key);
CREATE UNIQUE INDEX ON marts.dim_product (product_id);

-- dim_seller
CREATE TABLE marts.dim_seller AS
SELECT ROW_NUMBER() OVER (ORDER BY seller_id)::int AS seller_key,
       seller_id, zip_prefix, city, state
FROM staging.sellers;
ALTER TABLE marts.dim_seller ADD PRIMARY KEY (seller_key);
CREATE UNIQUE INDEX ON marts.dim_seller (seller_id);

-- fact_orders: one row per order. Children are aggregated to order level first.
CREATE TABLE marts.fact_orders AS
WITH items AS (
    SELECT order_id, COUNT(*) AS items_count,
           SUM(price) AS order_revenue, SUM(freight_value) AS order_freight
    FROM staging.order_items GROUP BY order_id
),
pay AS (
    SELECT order_id, SUM(payment_value) AS payment_total, MAX(installments) AS max_installments
    FROM staging.order_payments GROUP BY order_id
),
pay_type AS (
    SELECT DISTINCT ON (order_id) order_id, payment_type AS primary_payment_type
    FROM staging.order_payments
    ORDER BY order_id, payment_value DESC, payment_sequential
)
SELECT
    o.order_id,
    c.customer_key,
    TO_CHAR(o.purchased_at, 'YYYYMMDD')::int AS purchase_date_key,
    o.order_status,
    o.purchased_at, o.approved_at, o.carrier_at, o.delivered_at, o.estimated_at,
    o.in_analysis_window, o.is_delivered_with_date, o.has_timestamp_conflict,
    (o.order_status NOT IN ('canceled', 'unavailable')) AS is_revenue_order,
    COALESCE(i.items_count, 0) AS items_count,
    i.order_revenue, i.order_freight,
    p.payment_total, p.max_installments, pt.primary_payment_type,
    r.review_score,
    CASE WHEN o.is_delivered_with_date
         THEN ROUND((EXTRACT(EPOCH FROM (o.delivered_at - o.purchased_at)) / 86400)::numeric, 2) END AS days_to_deliver,
    CASE WHEN o.is_delivered_with_date
         THEN (o.delivered_at::date > o.estimated_at::date) END AS is_late,
    CASE WHEN o.is_delivered_with_date
         THEN GREATEST(0, o.delivered_at::date - o.estimated_at::date) END AS days_late,
    CASE WHEN o.carrier_at >= o.purchased_at
         THEN ROUND((EXTRACT(EPOCH FROM (o.carrier_at - o.purchased_at)) / 86400)::numeric, 2) END AS days_to_carrier,
    CASE WHEN o.delivered_at >= o.carrier_at
         THEN ROUND((EXTRACT(EPOCH FROM (o.delivered_at - o.carrier_at)) / 86400)::numeric, 2) END AS days_carrier_to_customer
FROM staging.orders o
JOIN staging.customers sc ON sc.customer_id = o.customer_id
JOIN marts.dim_customer c ON c.customer_unique_id = sc.customer_unique_id
LEFT JOIN items i     ON i.order_id  = o.order_id
LEFT JOIN pay p       ON p.order_id  = o.order_id
LEFT JOIN pay_type pt ON pt.order_id = o.order_id
LEFT JOIN staging.order_reviews r ON r.order_id = o.order_id;
ALTER TABLE marts.fact_orders ADD PRIMARY KEY (order_id);
ALTER TABLE marts.fact_orders ADD FOREIGN KEY (customer_key) REFERENCES marts.dim_customer (customer_key);
ALTER TABLE marts.fact_orders ADD FOREIGN KEY (purchase_date_key) REFERENCES marts.dim_date (date_key);

-- fact_order_items: one row per order item. Order-level flags are copied in so
-- Power BI never has to join one fact to another.
CREATE TABLE marts.fact_order_items AS
SELECT
    i.order_id, i.order_item_id,
    fo.customer_key, p.product_key, s.seller_key, fo.purchase_date_key,
    i.price, i.freight_value, (i.price + i.freight_value) AS item_total,
    fo.order_status, fo.is_revenue_order, fo.in_analysis_window,
    fo.is_delivered_with_date, fo.is_late, fo.days_late, fo.days_to_deliver, fo.review_score
FROM staging.order_items i
JOIN marts.fact_orders fo ON fo.order_id = i.order_id
JOIN marts.dim_product p  ON p.product_id = i.product_id
JOIN marts.dim_seller s   ON s.seller_id = i.seller_id;
ALTER TABLE marts.fact_order_items ADD PRIMARY KEY (order_id, order_item_id);
ALTER TABLE marts.fact_order_items ADD FOREIGN KEY (customer_key) REFERENCES marts.dim_customer (customer_key);
ALTER TABLE marts.fact_order_items ADD FOREIGN KEY (product_key) REFERENCES marts.dim_product (product_key);
ALTER TABLE marts.fact_order_items ADD FOREIGN KEY (seller_key) REFERENCES marts.dim_seller (seller_key);
ALTER TABLE marts.fact_order_items ADD FOREIGN KEY (purchase_date_key) REFERENCES marts.dim_date (date_key);


--- Prove the model
SELECT 'dim_date' AS tbl, COUNT(*) AS rows, 852 AS expected FROM marts.dim_date
UNION ALL SELECT 'dim_customer', COUNT(*), 96096 FROM marts.dim_customer
UNION ALL SELECT 'dim_product', COUNT(*), 32951 FROM marts.dim_product
UNION ALL SELECT 'dim_seller', COUNT(*), 3095 FROM marts.dim_seller
UNION ALL SELECT 'dim_geography', COUNT(*), 19015 FROM marts.dim_geography
UNION ALL SELECT 'fact_orders', COUNT(*), 99441 FROM marts.fact_orders
UNION ALL SELECT 'fact_order_items', COUNT(*), 112650 FROM marts.fact_order_items;


--- Revenue reconciliation:
SELECT (SELECT SUM(price) FROM staging.order_items)      AS staging_total,
       (SELECT SUM(price) FROM marts.fact_order_items)   AS fact_items_total,
       (SELECT SUM(order_revenue) FROM marts.fact_orders) AS fact_orders_total;


--- FIRST KPI
SELECT COUNT(*) AS delivered_orders_in_window,
       ROUND(100.0 * COUNT(*) FILTER (WHERE NOT is_late) / COUNT(*), 2) AS on_time_pct,
       ROUND(AVG(days_to_deliver), 1) AS avg_days_to_deliver
FROM marts.fact_orders
WHERE in_analysis_window AND is_delivered_with_date;