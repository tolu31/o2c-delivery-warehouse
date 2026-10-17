# Model decisions

| # | Decision | Reason |
|---|----------|--------|
| 1 | fact_orders has one row per order. fact_order_items has one row per item. | Delivery and review questions are order-level. Revenue, product and seller questions are item-level. |
| 2 | Children (items, payments) are aggregated to order level before joining. | Joining them directly would multiply rows and inflate revenue. |
| 3 | dim_customer has one row per person (customer_unique_id), with location from their latest order. | customer_id is created per order (quality log item 3). |
| 4 | Revenue is the sum of item prices, excluding canceled and unavailable orders (is_revenue_order). Freight is reported separately. | Payments include vouchers and instalments. Orders that never shipped are not revenue. |
| 5 | An order is late when the delivery date is after the estimated date (compared by calendar day). | The estimate has no time of day, so comparing timestamps would count same-day deliveries as late. |
| 6 | Stage durations (to carrier, carrier to customer) are NULL when the timestamps conflict. | Negative durations are impossible (quality log item 8). |
| 7 | Order-level delivery flags are copied onto fact_order_items. | Facts never join to each other, so Power BI relationships stay simple. |
| 8 | An order with several sellers counts toward each seller on the item rows. | Limitation: seller-level lateness is approximated by the order's delivery. |
| 9 | Marts are tables with primary keys and foreign keys. | Keys prove the model is consistent and load faster in Power BI. |
