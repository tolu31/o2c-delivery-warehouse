# Data quality log

| # | Check | Finding | Impact | Decision |
|---|-------|---------|--------|----------|
| 1 | Key uniqueness | order_id, customer_id, product_id, seller_id are unique. Items are unique on (order_id, order_item_id) and payments on (order_id, payment_sequential). | Safe to use as keys. | Keep as is. |
| 2 | Orphan keys | 0 orphans in orders-customers, items-orders, items-products, items-sellers, payments-orders, reviews-orders. | Joins will not lose rows. | No action. |
| 3 | customer_id vs customer_unique_id | 99,441 customer_id but 96,096 customer_unique_id. | customer_id is per order, not per person. | Use customer_unique_id for repeat-customer metrics. |
| 4 | Repeated review_id | 99,224 review rows but 98,410 distinct review_id. | Joining reviews could duplicate orders. | Pending: investigate, then deduplicate in staging. |
| 5 | Orders with no items | 775 orders. | Cannot have revenue or sellers. | Pending: break down by status. |
| 6 | Orders with no payment | 1 order. | Minor. | Pending: inspect the order. |
