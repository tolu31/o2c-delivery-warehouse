# Data quality log

| # | Check | Finding | Impact | Decision |
|---|-------|---------|--------|----------|
| 1 | Key uniqueness | order_id, customer_id, product_id, seller_id are unique. Items are unique on (order_id, order_item_id), payments on (order_id, payment_sequential). | Safe to use as keys. | Keep as is. |
| 2 | Orphan keys | 0 orphans across orders-customers, items-orders, items-products, items-sellers, payments-orders, reviews-orders. | Joins will not lose rows. | No action. |
| 3 | customer_id vs customer_unique_id | 99,441 customer_id but 96,096 customer_unique_id. | customer_id is per order, not per person. | Use customer_unique_id for repeat-customer metrics. |
| 4 | Reviews | 789 review_ids are reused across orders (99,224 rows, 98,410 distinct ids). 98,126 orders have 1 review, 543 have 2, 4 have 3. 768 orders have no review. | Joining reviews directly duplicates orders. | Staging keeps one review per order: the latest by review_answer_timestamp. |
| 5 | Orders with no items | 775: unavailable 603, canceled 164, created 5, invoiced 2, shipped 1. | No items means no revenue or seller. | Exclude from revenue and seller analysis. Analyse unavailable and canceled orders separately. |
| 6 | Order with no payment | 1 delivered order (purchased 2016-09-15). | Minor. | Keep. Revenue is measured from item prices, so it is unaffected. |
| 7 | Delivery date gaps | 8 delivered orders have no delivery date. 6 non-delivered orders have one. | Cannot judge on-time delivery. | On-time KPI population: status delivered with a delivery date (96,470 orders). |
| 8 | Timestamp order | 0 cases of approved, delivered or estimated before purchase. 166 carrier handovers before purchase, 1,359 before approval, 23 deliveries before carrier handover. | Some stage durations would be negative. | Keep orders. Set negative durations to NULL and flag. Headline on-time rate unaffected. |
| 9 | Geolocation grain | 1,000,163 rows but 19,015 distinct zip prefixes. | Direct joins multiply rows. | Aggregate to one row per zip prefix before any join. |
| 10 | Value checks | No price <= 0, freight < 0 or review score outside 1-5. 383 items have zero freight. 9 payments have value 0, 3 have type not_defined, 2 have 0 instalments. | Core measures are sound. Zero freight is plausible free shipping. | Keep prices and freight. Exclude the odd payment rows from payment-mix and instalment analysis only. |
| 11 | Product categories | 610 products (1.9%) have no category. 13 have a category missing from the translation table. | Category reports would show blanks. | Show the English name, else the Portuguese name, else 'uncategorised'. |
| 12 | Coverage by month | Orders run Sept 2016 to Oct 2018. 2016 is sparse (329 orders, none in Nov 2016). Sept-Oct 2018 has 20. Volume grows from 800 in Jan 2017 to 6,000-7,500 a month in 2018, with a spike in Nov 2017. | Trends outside the core period would mislead. | Analysis window: Jan 2017 to Aug 2018 (99,092 of 99,441 orders). Read 2017 volume trends as growth. |
