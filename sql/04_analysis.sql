-- 04_analysis.sql  (batch 1: delivery performance)
-- Window: Jan 2017 - Aug 2018. On-time population: delivered orders with a delivery date.

-- Q1. Is lateness getting better or worse over time?
SELECT d.year_month,
       COUNT(*)                                                         AS delivered_orders,
       COUNT(*) FILTER (WHERE fo.is_late)                               AS late_orders,
       ROUND(100.0 * COUNT(*) FILTER (WHERE fo.is_late) / COUNT(*), 2)  AS late_pct,
       ROUND(AVG(fo.days_to_deliver), 1)                                AS avg_days_to_deliver
FROM marts.fact_orders fo
JOIN marts.dim_date d ON d.date_key = fo.purchase_date_key
WHERE fo.in_analysis_window AND fo.is_delivered_with_date
GROUP BY d.year_month
ORDER BY d.year_month;
-- Finding: Late deliveries stayed between 2.8% and 6.6% a month until Oct 2017, then peaked at 12.4% in
-- Nov 2017 and at 14.1% and 19.0% in Feb and Mar 2018. Those three months hold 22% of delivered orders
-- but 48% of all late orders.
-- So what: lateness comes from peak periods and specific failures, not everyday performance, so weekly
-- late-rate monitoring with a capacity review trigger would catch it early.
-- Limitation: the data has no carrier field, so the cause of the Feb-Mar 2018 spike cannot be identified,
-- and delivery times in the latest months are biased low because in-transit orders are excluded.

-- Q2. Which customer states get the worst delivery performance?
SELECT c.state,
       COUNT(*)                                                         AS delivered_orders,
       ROUND(100.0 * COUNT(*) FILTER (WHERE fo.is_late) / COUNT(*), 2)  AS late_pct,
       ROUND(AVG(fo.days_to_deliver), 1)                                AS avg_days_to_deliver
FROM marts.fact_orders fo
JOIN marts.dim_customer c ON c.customer_key = fo.customer_key
WHERE fo.in_analysis_window AND fo.is_delivered_with_date
GROUP BY c.state
HAVING COUNT(*) >= 200
ORDER BY late_pct DESC;
-- Finding: Alagoas (AL) has the highest late rate at 21.5% (24.5 days average) against 4.5% (8.7 days) in
-- Sao Paulo, and the six worst states are all in the north-east. Rio de Janeiro (RJ) is late on 12.15% of
-- 12,312 orders, about 1,500 late orders or roughly 23% of all late orders.
-- So what: lateness is geographic. RJ is the largest single fix by volume, and slow lanes such as the
-- north-east need faster carriers or more realistic delivery estimates (Rondonia averages 19.4 days but
-- is only 2.9% late).
-- Limitation: states use the customer's latest-order location, four states with fewer than 200 delivered
-- orders are excluded, and without carrier data distance, carrier and estimate effects cannot be separated.

-- Q3. How long does each stage take, and how bad is the slow tail?
SELECT
    ROUND(AVG(EXTRACT(EPOCH FROM (approved_at - purchased_at)) / 3600)::numeric, 1) AS avg_hours_to_approval,
    ROUND(AVG(days_to_carrier), 1)           AS avg_days_to_carrier,
    ROUND(AVG(days_carrier_to_customer), 1)  AS avg_days_carrier_to_customer,
    ROUND(AVG(days_to_deliver), 1)           AS avg_days_total,
    ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY days_to_deliver))::numeric, 1) AS median_days_total,
    ROUND((PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY days_to_deliver))::numeric, 1) AS p90_days_total
FROM marts.fact_orders
WHERE in_analysis_window AND is_delivered_with_date;
-- Finding: Delivery takes 12.5 days on average but 10.2 days at the median, and 1 in 10 orders takes 23.1
-- days or more. The carrier leg averages 9.3 days (about three quarters of the wait), seller handover 3.2
-- days and approval 10.2 hours.
-- So what: the transport leg and a slow tail drive the customer experience, so carrier performance has
-- more upside than faster approval, and a seller dispatch target is the second lever.
-- Limitation: stage averages use slightly different order sets (conflicting timestamps are excluded) so
-- they do not sum exactly, and in-transit orders are excluded, which biases durations low.

-- Q4. Which sellers account for the most late items?
WITH seller_perf AS (
    SELECT s.seller_id, s.state,
           COUNT(*)                                  AS delivered_items,
           COUNT(*) FILTER (WHERE foi.is_late)       AS late_items,
           ROUND(100.0 * COUNT(*) FILTER (WHERE foi.is_late) / COUNT(*), 2) AS late_pct,
           SUM(foi.price)                            AS revenue
    FROM marts.fact_order_items foi
    JOIN marts.dim_seller s ON s.seller_key = foi.seller_key
    WHERE foi.in_analysis_window AND foi.is_delivered_with_date
    GROUP BY s.seller_id, s.state
),
ranked AS (
    SELECT *, SUM(late_items) OVER () AS total_late_items
    FROM seller_perf
)
SELECT RANK() OVER (ORDER BY late_items DESC)               AS rank_by_late_items,
       seller_id, state, delivered_items, late_items, late_pct,
       ROUND(100.0 * late_items / total_late_items, 2)      AS pct_of_all_late_items,
       ROUND(revenue, 0)                                    AS revenue
FROM ranked
WHERE delivered_items >= 30
ORDER BY late_items DESC
LIMIT 15;
-- Finding: The 15 sellers with the most late items account for about 21% of all late items and 13 of them
-- are in Sao Paulo, but most sit at 5-11% late, close to the 6.6% platform average.
-- So what: ranking by late count mostly reflects volume, so it is the wrong list to act on (see Q4b).
-- Limitation: seller lateness is the order's delivery applied to each seller on the order, and only
-- sellers with at least 30 delivered items are ranked.


-- Q4b. Which sellers are late MORE than their volume explains?
WITH platform AS (
    SELECT 1.0 * COUNT(*) FILTER (WHERE is_late) / COUNT(*) AS platform_late_rate
    FROM marts.fact_order_items
    WHERE in_analysis_window AND is_delivered_with_date
),
seller_perf AS (
    SELECT s.seller_id, s.state,
           COUNT(*) AS delivered_items,
           COUNT(*) FILTER (WHERE foi.is_late) AS late_items
    FROM marts.fact_order_items foi
    JOIN marts.dim_seller s ON s.seller_key = foi.seller_key
    WHERE foi.in_analysis_window AND foi.is_delivered_with_date
    GROUP BY s.seller_id, s.state
)
SELECT sp.seller_id, sp.state, sp.delivered_items, sp.late_items,
       ROUND(100.0 * sp.late_items / sp.delivered_items, 2) AS late_pct,
       ROUND(100 * p.platform_late_rate, 2)                 AS platform_late_pct,
       ROUND(sp.late_items - sp.delivered_items * p.platform_late_rate, 0) AS excess_late_items
FROM seller_perf sp CROSS JOIN platform p
WHERE sp.delivered_items >= 30
ORDER BY excess_late_items DESC
LIMIT 15;
-- Finding: Measured against the 6.6% platform average, the 15 sellers with the most excess late items
-- account for only about 440 extra late items, roughly 6% of all late items. The worst are a Maranhao
-- seller at 19.4% late (402 items) and a Sao Paulo seller at 9.7% on 1,949 items (60 excess).
-- So what: lateness is spread across the whole network, so fixing the worst sellers alone would remove
-- only a small share, and regional carrier and estimate fixes (Q2) have more upside.
-- Limitation: small sellers with extreme rates (50% of 46 items) are noisy, seller results depend on
-- destination mix, and seller attribution is approximate.

-- Q5. How does lateness affect review scores?
SELECT CASE WHEN days_late = 0 THEN '1. on time'
            WHEN days_late BETWEEN 1 AND 3 THEN '2. 1-3 days late'
            WHEN days_late BETWEEN 4 AND 7 THEN '3. 4-7 days late'
            ELSE '4. 8+ days late' END                                         AS delivery_band,
       COUNT(*)                                                                AS orders_with_review,
       ROUND(AVG(review_score), 2)                                             AS avg_review_score,
       ROUND(100.0 * COUNT(*) FILTER (WHERE review_score <= 2) / COUNT(*), 1)  AS pct_negative
FROM marts.fact_orders
WHERE in_analysis_window AND is_delivered_with_date AND review_score IS NOT NULL
GROUP BY 1
ORDER BY 1;
-- Finding: Average review score falls from 4.29 for on-time orders to 3.29 (1-3 days late), 2.10 (4-7
-- days late) and 1.70 (8+ days late), and the share of 1-2 star reviews rises from 9.2% to 79.3%. The
-- 6.7% of reviewed orders that arrive late produce about a third of all negative reviews.
-- So what: even a short delay costs a full review point and orders 8+ days late are almost always rated
-- badly, so preventing long delays protects reputation most.
-- Limitation: this is an association, not proof of cause. About two thirds of negative reviews come from
-- on-time orders, so product and service issues matter more in total, and only reviewed orders are counted.

-- Q6. Which categories earn the most, and what share is freight?
SELECT p.category,
       COUNT(*)                                                           AS items_sold,
       ROUND(SUM(foi.price), 0)                                           AS revenue,
       ROUND(100.0 * SUM(foi.price) / SUM(SUM(foi.price)) OVER (), 2)     AS pct_of_revenue,
       ROUND(100.0 * SUM(foi.freight_value) / SUM(foi.price), 1)          AS freight_pct_of_price
FROM marts.fact_order_items foi
JOIN marts.dim_product p ON p.product_key = foi.product_key
WHERE foi.in_analysis_window AND foi.is_revenue_order
GROUP BY p.category
ORDER BY revenue DESC
LIMIT 15;
-- Finding: Health and beauty (9.3%), watches and gifts (8.9%), bed/bath/table (7.7%), sports and leisure
-- (7.3%) and computer accessories (6.7%) bring in about 40% of item revenue, and the top 15 categories
-- bring in 76%. Freight is 8.4% of price for watches and gifts but 23-25% for furniture, housewares and
-- office furniture.
-- So what: bulky, lower-priced categories give up a quarter of the item price to freight, so regional
-- stock or freight thresholds could lift conversion there, while watches and gifts earn about R$200 per
-- item with little freight.
-- Limitation: freight is what customers were charged, not the platform's cost, there is no margin data
-- so revenue is not profit, and canceled and unavailable orders are excluded.

-- Q7. How many customers come back?
WITH per_customer AS (
    SELECT customer_key, COUNT(*) AS orders
    FROM marts.fact_orders
    WHERE in_analysis_window AND is_revenue_order
    GROUP BY customer_key
)
SELECT COUNT(*)                                                                   AS customers,
       COUNT(*) FILTER (WHERE orders >= 2)                                        AS repeat_customers,
       ROUND(100.0 * COUNT(*) FILTER (WHERE orders >= 2) / COUNT(*), 2)           AS repeat_rate_pct,
       ROUND(100.0 * SUM(orders) FILTER (WHERE orders >= 2) / SUM(orders), 2)     AS pct_of_orders_from_repeat
FROM per_customer;
-- Finding: Only 3.0% of customers (2,875 of 94,707) ordered more than once in the 20-month window, and
-- they placed 6.2% of orders.
-- So what: the business is acquisition-led, and each extra percentage point of repeat rate is about 950
-- more returning customers, so a retention programme such as follow-up offers after delivery has room.
-- Limitation: customers acquired late in the window had little time to return, customers are identified
-- only by customer_unique_id, and only non-canceled orders are counted.

-- Q8. How do customers pay? (odd payment types excluded, per the quality log)
SELECT primary_payment_type,
       COUNT(*)                                              AS orders,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)    AS pct_of_orders,
       ROUND(AVG(order_revenue), 2)                          AS avg_order_value,
       ROUND(AVG(max_installments), 1)                       AS avg_installments
FROM marts.fact_orders
WHERE in_analysis_window AND is_revenue_order
  AND primary_payment_type IS NOT NULL AND primary_payment_type <> 'not_defined'
GROUP BY primary_payment_type
ORDER BY orders DESC;
-- Finding: Credit card is the main payment method at 75.5% of orders (average order value R$143.61, 3.6
-- instalments), followed by boleto at 19.9% (R$121.68), voucher at 3.1% and debit card at 1.5%.
-- So what: instalments go with larger orders (credit-card orders are about 18% bigger than boleto orders),
-- so keeping instalments available protects order size, and boleto buyers are a separate cash segment.
-- Limitation: the payment type is the one with the largest value in the order, orders can mix methods,
-- order value excludes freight, and the odd payment rows in the quality log are excluded.
