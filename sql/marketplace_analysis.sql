-- Marketplace Growth & Seller Analytics
-- BigQuery SQL
-- Analysis period: 2025-07-01 through 2026-06-30
-- Project: marketplace-analytics-project

-- 1. BASIC SOURCE VALIDATION

SELECT 'users' AS table_name, COUNT(*) AS row_count
FROM `marketplace-analytics-project.marketplace_data.users`
UNION ALL
SELECT 'sellers', COUNT(*)
FROM `marketplace-analytics-project.marketplace_data.sellers`
UNION ALL
SELECT 'listings', COUNT(*)
FROM `marketplace-analytics-project.marketplace_data.listings`
UNION ALL
SELECT 'orders', COUNT(*)
FROM `marketplace-analytics-project.marketplace_data.orders`
UNION ALL
SELECT 'order_items', COUNT(*)
FROM `marketplace-analytics-project.marketplace_data.order_items`;

SELECT
  LOWER(TRIM(order_status)) AS order_status_clean,
  COUNT(*) AS orders
FROM `marketplace-analytics-project.marketplace_data.orders`
GROUP BY order_status_clean
ORDER BY orders DESC;

SELECT
  LOWER(TRIM(category)) AS category_clean,
  COUNT(*) AS listings
FROM `marketplace-analytics-project.marketplace_data.listings`
GROUP BY category_clean
ORDER BY listings DESC;

SELECT
  COUNTIF(state IS NULL OR TRIM(state) = '') AS missing_state_rows
FROM `marketplace-analytics-project.marketplace_data.users`;

SELECT
  MIN(listing_price) AS min_price,
  APPROX_QUANTILES(listing_price, 100)[OFFSET(50)] AS median_price,
  APPROX_QUANTILES(listing_price, 100)[OFFSET(90)] AS p90_price,
  APPROX_QUANTILES(listing_price, 100)[OFFSET(95)] AS p95_price,
  APPROX_QUANTILES(listing_price, 100)[OFFSET(99)] AS p99_price,
  MAX(listing_price) AS max_price,
  AVG(listing_price) AS avg_price
FROM `marketplace-analytics-project.marketplace_data.listings`;

SELECT
  listing_id,
  seller_id,
  category,
  listing_price,
  listing_status
FROM `marketplace-analytics-project.marketplace_data.listings`
WHERE listing_price < 1
   OR listing_price > 5000
ORDER BY listing_price;

-- 2. RELATIONSHIP / INTEGRITY CHECKS

SELECT 'orders' AS table_name, COUNT(*) - COUNT(DISTINCT order_id) AS duplicate_ids
FROM `marketplace-analytics-project.marketplace_data.orders`
UNION ALL
SELECT 'listings', COUNT(*) - COUNT(DISTINCT listing_id)
FROM `marketplace-analytics-project.marketplace_data.listings`
UNION ALL
SELECT 'users', COUNT(*) - COUNT(DISTINCT user_id)
FROM `marketplace-analytics-project.marketplace_data.users`
UNION ALL
SELECT 'sellers', COUNT(*) - COUNT(DISTINCT seller_id)
FROM `marketplace-analytics-project.marketplace_data.sellers`;

SELECT COUNT(*) AS orphaned_buyers
FROM `marketplace-analytics-project.marketplace_data.orders` o
LEFT JOIN `marketplace-analytics-project.marketplace_data.users` u
  ON o.buyer_id = u.user_id
WHERE u.user_id IS NULL;

SELECT COUNT(*) AS orphaned_sellers
FROM `marketplace-analytics-project.marketplace_data.orders` o
LEFT JOIN `marketplace-analytics-project.marketplace_data.sellers` s
  ON o.seller_id = s.seller_id
WHERE s.seller_id IS NULL;

SELECT
  COUNTIF(o.order_id IS NULL) AS orphaned_orders,
  COUNTIF(l.listing_id IS NULL) AS orphaned_listings
FROM `marketplace-analytics-project.marketplace_data.order_items` oi
LEFT JOIN `marketplace-analytics-project.marketplace_data.orders` o
  ON oi.order_id = o.order_id
LEFT JOIN `marketplace-analytics-project.marketplace_data.listings` l
  ON oi.listing_id = l.listing_id;

WITH item_totals AS (
  SELECT
    order_id,
    ROUND(SUM(sale_price * quantity), 2) AS item_total
  FROM `marketplace-analytics-project.marketplace_data.order_items`
  GROUP BY order_id
)
SELECT COUNT(*) AS mismatched_orders
FROM `marketplace-analytics-project.marketplace_data.orders` o
JOIN item_totals i
  ON o.order_id = i.order_id
WHERE ROUND(o.order_total, 2) != i.item_total;

-- 3. CLEAN ANALYTICAL LAYER

CREATE OR REPLACE TABLE `marketplace-analytics-project.marketplace_clean.orders_clean` AS
SELECT
  order_id,
  buyer_id,
  seller_id,
  order_date,
  LOWER(TRIM(order_status)) AS order_status,
  CAST(order_total AS NUMERIC) AS order_total
FROM `marketplace-analytics-project.marketplace_data.orders`;

CREATE OR REPLACE TABLE `marketplace-analytics-project.marketplace_clean.order_items_clean` AS
SELECT
  order_id,
  listing_id,
  CAST(sale_price AS NUMERIC) AS sale_price,
  quantity
FROM `marketplace-analytics-project.marketplace_data.order_items`;

CREATE OR REPLACE TABLE `marketplace-analytics-project.marketplace_clean.users_clean` AS
SELECT
  user_id,
  signup_date,
  LOWER(TRIM(user_type)) AS user_type,
  NULLIF(UPPER(TRIM(state)), '') AS state,
  state IS NULL OR TRIM(state) = '' AS state_missing_flag
FROM `marketplace-analytics-project.marketplace_data.users`;

CREATE OR REPLACE TABLE `marketplace-analytics-project.marketplace_clean.sellers_clean` AS
SELECT
  seller_id,
  user_id,
  signup_date,
  LOWER(TRIM(seller_status)) AS seller_status
FROM `marketplace-analytics-project.marketplace_data.sellers`;

CREATE OR REPLACE TABLE `marketplace-analytics-project.marketplace_clean.listings_clean` AS
SELECT
  listing_id,
  seller_id,
  LOWER(TRIM(category)) AS category,
  listing_date,
  CAST(listing_price AS NUMERIC) AS listing_price_original,
  CASE
    WHEN listing_price < 1 OR listing_price > 5000 THEN NULL
    ELSE CAST(listing_price AS NUMERIC)
  END AS listing_price,
  listing_price < 1 OR listing_price > 5000 AS listing_price_flag,
  LOWER(TRIM(listing_status)) AS listing_status
FROM `marketplace-analytics-project.marketplace_data.listings`;

-- 4. EXECUTIVE KPIs

CREATE OR REPLACE VIEW `marketplace-analytics-project.marketplace_clean.executive_kpis` AS
WITH completed_orders AS (
  SELECT *
  FROM `marketplace-analytics-project.marketplace_clean.orders_clean`
  WHERE order_status = 'completed'
),
gmv AS (
  SELECT SUM(oi.sale_price * oi.quantity) AS total_gmv
  FROM completed_orders o
  JOIN `marketplace-analytics-project.marketplace_clean.order_items_clean` oi
    ON o.order_id = oi.order_id
),
buyers AS (
  SELECT
    COUNT(*) AS active_buyers,
    COUNTIF(order_count >= 2) AS repeat_buyers
  FROM (
    SELECT buyer_id, COUNT(*) AS order_count
    FROM completed_orders
    GROUP BY buyer_id
  )
),
active_sellers AS (
  SELECT COUNT(DISTINCT seller_id) AS active_sellers
  FROM (
    SELECT seller_id
    FROM `marketplace-analytics-project.marketplace_clean.listings_clean`
    WHERE listing_date BETWEEN DATE '2025-07-01' AND DATE '2026-06-30'
    UNION DISTINCT
    SELECT seller_id
    FROM completed_orders
    WHERE order_date BETWEEN DATE '2025-07-01' AND DATE '2026-06-30'
  )
),
sell_through AS (
  SELECT
    COUNTIF(listing_status = 'sold') AS sold_listings,
    COUNTIF(listing_status IN ('sold', 'available')) AS eligible_listings
  FROM `marketplace-analytics-project.marketplace_clean.listings_clean`
),
seller_gmv AS (
  SELECT seller_id, SUM(order_total) AS seller_gmv
  FROM completed_orders
  GROUP BY seller_id
),
top_10 AS (
  SELECT SUM(seller_gmv) AS top_10_gmv
  FROM (
    SELECT seller_gmv
    FROM seller_gmv
    ORDER BY seller_gmv DESC
    LIMIT 10
  )
)
SELECT
  ROUND(g.total_gmv, 2) AS total_gmv,
  b.active_buyers,
  a.active_sellers,
  ROUND(SAFE_DIVIDE(b.repeat_buyers, b.active_buyers) * 100, 2) AS repeat_purchase_rate,
  ROUND(SAFE_DIVIDE(s.sold_listings, s.eligible_listings) * 100, 2) AS sell_through_rate,
  ROUND(SAFE_DIVIDE(t.top_10_gmv, g.total_gmv) * 100, 2) AS top_10_gmv_share
FROM gmv g
CROSS JOIN buyers b
CROSS JOIN active_sellers a
CROSS JOIN sell_through s
CROSS JOIN top_10 t;

SELECT *
FROM `marketplace-analytics-project.marketplace_clean.executive_kpis`;

-- 5. MONTHLY GMV & GROWTH

WITH monthly AS (
  SELECT
    DATE_TRUNC(o.order_date, MONTH) AS month,
    SUM(oi.sale_price * oi.quantity) AS monthly_gmv
  FROM `marketplace-analytics-project.marketplace_clean.orders_clean` o
  JOIN `marketplace-analytics-project.marketplace_clean.order_items_clean` oi
    ON o.order_id = oi.order_id
  WHERE o.order_status = 'completed'
  GROUP BY month
)
SELECT
  month,
  ROUND(monthly_gmv, 2) AS monthly_gmv,
  ROUND(
    SAFE_DIVIDE(
      monthly_gmv - LAG(monthly_gmv) OVER (ORDER BY month),
      LAG(monthly_gmv) OVER (ORDER BY month)
    ) * 100,
    2
  ) AS mom_growth_pct
FROM monthly
ORDER BY month;

-- 6. CATEGORY PERFORMANCE

SELECT
  l.category,
  ROUND(SUM(oi.sale_price * oi.quantity), 2) AS category_gmv,
  ROUND(
    SAFE_DIVIDE(
      SUM(oi.sale_price * oi.quantity),
      SUM(SUM(oi.sale_price * oi.quantity)) OVER ()
    ) * 100,
    2
  ) AS gmv_share_pct
FROM `marketplace-analytics-project.marketplace_clean.orders_clean` o
JOIN `marketplace-analytics-project.marketplace_clean.order_items_clean` oi
  ON o.order_id = oi.order_id
JOIN `marketplace-analytics-project.marketplace_clean.listings_clean` l
  ON oi.listing_id = l.listing_id
WHERE o.order_status = 'completed'
GROUP BY l.category
ORDER BY category_gmv DESC;

WITH buyer_category_orders AS (
  SELECT
    l.category,
    o.buyer_id,
    COUNT(DISTINCT o.order_id) AS category_orders
  FROM `marketplace-analytics-project.marketplace_clean.orders_clean` o
  JOIN `marketplace-analytics-project.marketplace_clean.order_items_clean` oi
    ON o.order_id = oi.order_id
  JOIN `marketplace-analytics-project.marketplace_clean.listings_clean` l
    ON oi.listing_id = l.listing_id
  WHERE o.order_status = 'completed'
  GROUP BY l.category, o.buyer_id
)
SELECT
  category,
  COUNT(*) AS buyers,
  COUNTIF(category_orders >= 2) AS repeat_buyers,
  ROUND(SAFE_DIVIDE(COUNTIF(category_orders >= 2), COUNT(*)) * 100, 2) AS repeat_purchase_rate
FROM buyer_category_orders
GROUP BY category
ORDER BY repeat_purchase_rate DESC;

SELECT
  category,
  COUNTIF(listing_status = 'sold') AS sold_listings,
  COUNTIF(listing_status IN ('sold', 'available')) AS eligible_listings,
  ROUND(
    SAFE_DIVIDE(
      COUNTIF(listing_status = 'sold'),
      COUNTIF(listing_status IN ('sold', 'available'))
    ) * 100,
    2
  ) AS sell_through_rate
FROM `marketplace-analytics-project.marketplace_clean.listings_clean`
GROUP BY category
ORDER BY sell_through_rate DESC;

-- 7. SELLER CONCENTRATION

WITH seller_gmv AS (
  SELECT seller_id, SUM(order_total) AS seller_gmv
  FROM `marketplace-analytics-project.marketplace_clean.orders_clean`
  WHERE order_status = 'completed'
  GROUP BY seller_id
),
total AS (
  SELECT SUM(seller_gmv) AS marketplace_gmv
  FROM seller_gmv
)
SELECT
  s.seller_id,
  ROUND(s.seller_gmv, 2) AS seller_gmv,
  ROUND(SAFE_DIVIDE(s.seller_gmv, t.marketplace_gmv) * 100, 2) AS marketplace_gmv_share
FROM seller_gmv s
CROSS JOIN total t
ORDER BY seller_gmv DESC
LIMIT 10;

-- 8. NEW VS RETURNING BUYERS

WITH completed_orders AS (
  SELECT *
  FROM `marketplace-analytics-project.marketplace_clean.orders_clean`
  WHERE order_status = 'completed'
),
first_purchase AS (
  SELECT
    buyer_id,
    DATE_TRUNC(MIN(order_date), MONTH) AS first_purchase_month
  FROM completed_orders
  GROUP BY buyer_id
)
SELECT
  DATE_TRUNC(o.order_date, MONTH) AS month,
  ROUND(SUM(CASE
    WHEN DATE_TRUNC(o.order_date, MONTH) = f.first_purchase_month
      THEN o.order_total ELSE 0 END), 2) AS new_buyer_gmv,
  ROUND(SUM(CASE
    WHEN DATE_TRUNC(o.order_date, MONTH) > f.first_purchase_month
      THEN o.order_total ELSE 0 END), 2) AS returning_buyer_gmv
FROM completed_orders o
JOIN first_purchase f
  ON o.buyer_id = f.buyer_id
GROUP BY month
ORDER BY month;

WITH completed_orders AS (
  SELECT *
  FROM `marketplace-analytics-project.marketplace_clean.orders_clean`
  WHERE order_status = 'completed'
)
SELECT
  DATE_TRUNC(order_date, MONTH) AS month,
  COUNT(DISTINCT buyer_id) AS active_buyers,
  COUNT(*) AS completed_orders,
  ROUND(SAFE_DIVIDE(COUNT(*), COUNT(DISTINCT buyer_id)), 2) AS orders_per_active_buyer,
  ROUND(AVG(order_total), 2) AS average_order_value
FROM completed_orders
GROUP BY month
ORDER BY month;

-- 9. BUYER COHORT RETENTION

WITH completed_orders AS (
  SELECT *
  FROM `marketplace-analytics-project.marketplace_clean.orders_clean`
  WHERE order_status = 'completed'
),
first_purchase AS (
  SELECT
    buyer_id,
    DATE_TRUNC(MIN(order_date), MONTH) AS cohort_month
  FROM completed_orders
  GROUP BY buyer_id
),
buyer_activity AS (
  SELECT DISTINCT
    buyer_id,
    DATE_TRUNC(order_date, MONTH) AS activity_month
  FROM completed_orders
),
cohort_activity AS (
  SELECT
    f.buyer_id,
    f.cohort_month,
    a.activity_month,
    DATE_DIFF(a.activity_month, f.cohort_month, MONTH) AS month_number
  FROM first_purchase f
  JOIN buyer_activity a
    ON f.buyer_id = a.buyer_id
  WHERE a.activity_month >= f.cohort_month
),
cohort_sizes AS (
  SELECT
    cohort_month,
    COUNT(DISTINCT buyer_id) AS cohort_size
  FROM first_purchase
  GROUP BY cohort_month
)
SELECT
  c.cohort_month,
  c.month_number,
  s.cohort_size,
  COUNT(DISTINCT c.buyer_id) AS retained_buyers,
  ROUND(SAFE_DIVIDE(COUNT(DISTINCT c.buyer_id), s.cohort_size) * 100, 2) AS retention_rate
FROM cohort_activity c
JOIN cohort_sizes s
  USING (cohort_month)
GROUP BY c.cohort_month, c.month_number, s.cohort_size
ORDER BY c.cohort_month, c.month_number;

-- 10. SELLER HEALTH

WITH listing_sellers AS (
  SELECT DISTINCT seller_id
  FROM `marketplace-analytics-project.marketplace_clean.listings_clean`
  WHERE listing_date BETWEEN DATE '2025-07-01' AND DATE '2026-06-30'
),
selling_sellers AS (
  SELECT DISTINCT seller_id
  FROM `marketplace-analytics-project.marketplace_clean.orders_clean`
  WHERE order_status = 'completed'
)
SELECT
  COUNT(*) AS sellers_with_listings,
  COUNTIF(s.seller_id IS NULL) AS listed_but_zero_sales,
  ROUND(SAFE_DIVIDE(COUNTIF(s.seller_id IS NULL), COUNT(*)) * 100, 2) AS zero_sales_rate
FROM listing_sellers l
LEFT JOIN selling_sellers s
  USING (seller_id);

SELECT
  seller_id,
  COUNTIF(listing_status = 'sold') AS sold_listings,
  COUNTIF(listing_status IN ('sold', 'available')) AS eligible_listings,
  ROUND(
    SAFE_DIVIDE(
      COUNTIF(listing_status = 'sold'),
      COUNTIF(listing_status IN ('sold', 'available'))
    ) * 100,
    2
  ) AS sell_through_rate
FROM `marketplace-analytics-project.marketplace_clean.listings_clean`
GROUP BY seller_id
HAVING eligible_listings >= 10
ORDER BY sell_through_rate
LIMIT 10;
