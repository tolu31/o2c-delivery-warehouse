-- 1. Uniqueness and grain
SELECT 'orders: rows' AS check_name, COUNT(*) AS result FROM raw.orders
UNION ALL SELECT 'orders: distinct order_id', COUNT(DISTINCT order_id) FROM raw.orders
UNION ALL SELECT 'customers: rows', COUNT(*) FROM raw.customers
UNION ALL SELECT 'customers: distinct customer_id', COUNT(DISTINCT customer_id) FROM raw.customers
UNION ALL SELECT 'customers: distinct customer_unique_id', COUNT(DISTINCT customer_unique_id) FROM raw.customers
UNION ALL SELECT 'order_items: rows', COUNT(*) FROM raw.order_items
UNION ALL SELECT 'order_items: distinct (order_id, order_item_id)',
  COUNT(*) FROM (SELECT DISTINCT order_id, order_item_id FROM raw.order_items) t
UNION ALL SELECT 'order_payments: rows', COUNT(*) FROM raw.order_payments
UNION ALL SELECT 'order_payments: distinct (order_id, payment_sequential)',
  COUNT(*) FROM (SELECT DISTINCT order_id, payment_sequential FROM raw.order_payments) t
UNION ALL SELECT 'order_reviews: rows', COUNT(*) FROM raw.order_reviews
UNION ALL SELECT 'order_reviews: distinct review_id', COUNT(DISTINCT review_id) FROM raw.order_reviews
UNION ALL SELECT 'products: rows', COUNT(*) FROM raw.products
UNION ALL SELECT 'products: distinct product_id', COUNT(DISTINCT product_id) FROM raw.products
UNION ALL SELECT 'sellers: rows', COUNT(*) FROM raw.sellers
UNION ALL SELECT 'sellers: distinct seller_id', COUNT(DISTINCT seller_id) FROM raw.sellers
UNION ALL SELECT 'geolocation: rows', COUNT(*) FROM raw.geolocation
UNION ALL SELECT 'geolocation: distinct zip prefix', COUNT(DISTINCT geolocation_zip_code_prefix) FROM raw.geolocation;

-- 2. Orphan keys
SELECT 'orders without a customer' AS check_name, COUNT(*) AS result
FROM raw.orders o LEFT JOIN raw.customers c ON c.customer_id = o.customer_id
WHERE c.customer_id IS NULL
UNION ALL SELECT 'order_items without an order', COUNT(*)
FROM raw.order_items i LEFT JOIN raw.orders o ON o.order_id = i.order_id WHERE o.order_id IS NULL
UNION ALL SELECT 'order_items without a product', COUNT(*)
FROM raw.order_items i LEFT JOIN raw.products p ON p.product_id = i.product_id WHERE p.product_id IS NULL
UNION ALL SELECT 'order_items without a seller', COUNT(*)
FROM raw.order_items i LEFT JOIN raw.sellers s ON s.seller_id = i.seller_id WHERE s.seller_id IS NULL
UNION ALL SELECT 'payments without an order', COUNT(*)
FROM raw.order_payments p LEFT JOIN raw.orders o ON o.order_id = p.order_id WHERE o.order_id IS NULL
UNION ALL SELECT 'reviews without an order', COUNT(*)
FROM raw.order_reviews r LEFT JOIN raw.orders o ON o.order_id = r.order_id WHERE o.order_id IS NULL
UNION ALL SELECT 'orders with no items', COUNT(*)
FROM raw.orders o LEFT JOIN raw.order_items i ON i.order_id = o.order_id WHERE i.order_id IS NULL
UNION ALL SELECT 'orders with no payment', COUNT(*)
FROM raw.orders o LEFT JOIN raw.order_payments p ON p.order_id = o.order_id WHERE p.order_id IS NULL;

-- Q3a: Which orders have no items?
SELECT o.order_status, COUNT(*) AS orders_without_items
FROM raw.orders o
LEFT JOIN raw.order_items i ON i.order_id = o.order_id
WHERE i.order_id IS NULL
GROUP BY o.order_status
ORDER BY 2 DESC;

-- Q3b: The order with no payment
SELECT o.order_id, o.order_status, o.order_purchase_timestamp
FROM raw.orders o
LEFT JOIN raw.order_payments p ON p.order_id = o.order_id
WHERE p.order_id IS NULL;

-- Q3c: How are review IDs repeated?
SELECT COUNT(*) AS repeated_review_ids,
       SUM(CASE WHEN distinct_orders > 1 THEN 1 ELSE 0 END) AS shared_across_orders
FROM (
  SELECT review_id, COUNT(*) AS n, COUNT(DISTINCT order_id) AS distinct_orders
  FROM raw.order_reviews
  GROUP BY review_id
  HAVING COUNT(*) > 1
) d;

-- Q3d: Reviews per order
SELECT reviews_per_order, COUNT(*) AS orders
FROM (SELECT order_id, COUNT(*) AS reviews_per_order FROM raw.order_reviews GROUP BY order_id) t
GROUP BY reviews_per_order
ORDER BY reviews_per_order;

-- Q4: Delivery dates and date logic
WITH o AS (
  SELECT order_status,
         NULLIF(order_purchase_timestamp,'')::timestamp       AS purchased,
         NULLIF(order_approved_at,'')::timestamp              AS approved,
         NULLIF(order_delivered_carrier_date,'')::timestamp   AS carrier,
         NULLIF(order_delivered_customer_date,'')::timestamp  AS delivered,
         NULLIF(order_estimated_delivery_date,'')::timestamp  AS estimated
  FROM raw.orders
)
SELECT
  COUNT(*) FILTER (WHERE order_status = 'delivered' AND delivered IS NULL)     AS delivered_no_date,
  COUNT(*) FILTER (WHERE order_status <> 'delivered' AND delivered IS NOT NULL) AS not_delivered_has_date,
  COUNT(*) FILTER (WHERE approved  < purchased) AS approved_before_purchase,
  COUNT(*) FILTER (WHERE carrier   < purchased) AS carrier_before_purchase,
  COUNT(*) FILTER (WHERE carrier   < approved)  AS carrier_before_approval,
  COUNT(*) FILTER (WHERE delivered < carrier)   AS delivered_before_carrier,
  COUNT(*) FILTER (WHERE delivered < purchased) AS delivered_before_purchase,
  COUNT(*) FILTER (WHERE estimated < purchased) AS estimated_before_purchase
FROM o;
