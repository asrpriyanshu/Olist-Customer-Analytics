-- Olist Customer Analytics
-- Import 'Data Blocks' using SQL




-- Dim Locations
-- Locations from Olist Geolocation
CREATE MATERIALIZED VIEW dim_locations AS (WITH master_locations AS (SELECT
geolocation_city AS city,
geolocation_state AS state
FROM olist.olist_geolocation
-- Locations from Olist Customers
-- Using UNION to get unique rows only
UNION
SELECT
customer_city AS city,
customer_state AS state
FROM olist.olist_customers
-- Locations from Olist Sellers
UNION
SELECT
seller_city AS city,
seller_state AS state
FROM olist.olist_sellers),
-- Using REGEXP_REPLACE to remove special characters
-- Creating a bucket using UNION to get NULL values as Unknown and Space / Empty String as Invalid
-- Clean Master Locations for Power BI
clean_locations AS (SELECT
CASE
WHEN city IS NULL THEN 'Unknown'
WHEN INITCAP(TRIM(REPLACE(
REGEXP_REPLACE(city, '[^a-zA-Z0-9\sÀ-ÿº''-]', '', 'g'), '4o', '4º'))) = '' THEN 'Invalid'
ELSE INITCAP(TRIM(REPLACE(
REGEXP_REPLACE(city, '[^a-zA-Z0-9\sÀ-ÿº''-]', '', 'g'), '4o', '4º'))) END AS city,
CASE
WHEN state IS NULL THEN 'Unknown'
WHEN UPPER(TRIM(state)) = '' THEN 'Invalid' ELSE UPPER(TRIM(state)) END AS state
FROM master_locations
UNION
SELECT
'Unknown' AS city,
'Unknown' AS state
UNION
SELECT
'Invalid' AS city,
'Invalid' AS state
UNION
SELECT
'Not Applicable' AS city,
'Not Applicable' AS state)
SELECT
CASE
WHEN city = 'Invalid'
AND state = 'Invalid' THEN -1
WHEN city = 'Unknown'
AND state = 'Unknown' THEN -2 
WHEN city = 'Not Applicable'
AND state = 'Not Applicable' THEN -3 ELSE ROW_NUMBER() OVER(
ORDER BY state ASC, city ASC) END AS location_key,
state,
city
FROM clean_locations);




-- Dim Customers
-- Customers from Olist Customers
CREATE MATERIALIZED VIEW dim_customers AS (WITH customers_data AS (SELECT
CASE
WHEN customer_id IS NULL THEN 'Unknown'
WHEN TRIM(customer_id) = '' THEN 'Invalid' ELSE TRIM(customer_id) END AS customer_id,
CASE
WHEN customer_unique_id IS NULL THEN 'Unknown'
WHEN TRIM(customer_unique_id) = '' THEN 'Invalid' ELSE TRIM(customer_unique_id) END AS customer_unique_id
FROM olist.olist_customers
-- Customers from Olist Orders that isn't in Olist Customers as bucket
-- Using Order Status to filter only valid orders
UNION
SELECT
TRIM(oo.customer_id) AS customer_id,
'Ghost Data' AS customer_unique_id
FROM olist.olist_orders oo
WHERE oo.order_status = 'delivered'
AND oo.customer_id IS NOT NULL
AND TRIM(oo.customer_id) <> ''
-- Getting Non Matched Data using NOT EXISTS
AND NOT EXISTS(SELECT 1
FROM olist.olist_customers oc
WHERE
TRIM(oo.customer_id) = TRIM(oc.customer_id))
-- Creating a bucket using UNION for Unknown and Invalid data
UNION
SELECT
'Invalid' AS customer_id,
'Invalid' AS customer_unique_id
UNION
SELECT
'Unknown' AS customer_id,
'Unknown' AS customer_unique_id),
-- Using Olist Orders and Olist Order Payments to get Customers Static data
-- Data that won't change using Sorting and Filtering
orders AS (SELECT
oo.order_id,
SUM(oop.payment_value) AS spend,
CASE
WHEN oo.customer_id IS NULL THEN 'Unknown'
WHEN TRIM(oo.customer_id) = '' THEN 'Invalid' ELSE TRIM(oo.customer_id) END AS customer_id,
order_purchase_timestamp
FROM olist.olist_orders oo
INNER JOIN olist.olist_order_payments oop ON oo.order_id = oop.order_id
AND order_status = 'delivered'
GROUP BY 1, 3, 4),
clean_customers AS (SELECT
cd.customer_unique_id,
SUM(o.spend) AS life_time_spend,
CAST(MIN(o.order_purchase_timestamp) AS DATE) AS first_valid_order_date,
CAST(MAX(o.order_purchase_timestamp) AS DATE) AS last_valid_order_date,
100 * CAST(SUM(SUM(o.spend)) OVER(ORDER BY SUM(o.spend) DESC NULLS LAST, cd.customer_unique_id ASC) AS NUMERIC) /
NULLIF(SUM(SUM(o.spend)) OVER(), 0) AS cumulative_spend_percentage
FROM customers_data cd
LEFT JOIN orders o ON cd.customer_id = o.customer_id
GROUP BY cd.customer_unique_id)
-- Using Cumulative Spend Percentage for Segmentation
-- ROW_NUMBER to create Surrogate Key that we use in JOIN
SELECT
CASE
WHEN customer_unique_id = 'Unknown' THEN -1
WHEN customer_unique_id = 'Invalid' THEN -2
WHEN customer_unique_id = 'Ghost Data' THEN -3
ELSE ROW_NUMBER() OVER(
ORDER BY customer_unique_id ASC) END AS customer_key,
customer_unique_id,
life_time_spend,
first_valid_order_date,
last_valid_order_date,
CASE
WHEN customer_unique_id IN ('Ghost Data', 'Invalid', 'Unknown') THEN 'Not Applicable'
WHEN life_time_spend IS NULL THEN 'Inactive'
WHEN cumulative_spend_percentage <= 20 THEN 'VIP Level'
WHEN cumulative_spend_percentage <= 50 THEN 'High Level'
WHEN cumulative_spend_percentage <= 80 THEN 'Medium Level'
ELSE 'Low Level' END AS segmentation
FROM clean_customers);




-- Dim Products
CREATE MATERIALIZED VIEW dim_products AS (WITH products AS (SELECT
op.product_id,
pcnt.product_category_name_english AS product_category_name
FROM olist.olist_products op
LEFT JOIN olist.product_category_name_translation pcnt
ON op.product_category_name = pcnt.product_category_name),
clean_products AS (SELECT
CASE
WHEN product_id IS NULL THEN 'Unknown'
WHEN TRIM(product_id) = '' THEN 'Invalid' ELSE TRIM(product_id) END AS product_id,
CASE
WHEN product_category_name IS NULL THEN 'Unknown'
WHEN UPPER(TRIM(product_category_name)) = '' THEN 'Invalid'
ELSE UPPER(TRIM(product_category_name)) END AS product_category_name
FROM products
-- Using UION to create fallback buckets
UNION
SELECT
'Unknown' AS product_id,
'Unknown' AS product_category_name
UNION
SELECT
'Invalid' AS product_id,
'Invalid' AS product_category_name)
-- Creating Surrogate Key using ROW_NUMBER
SELECT
CASE
WHEN product_category_name = 'Unknown'
AND product_id = 'Unknown' THEN -1 
WHEN product_category_name = 'Invalid'
AND product_id = 'Invalid' THEN -2 ELSE ROW_NUMBER() OVER(
ORDER BY product_category_name ASC, product_id ASC) END AS product_key,
product_id,
product_category_name
FROM clean_products);




-- Fact Orders
-- Olist Customers
CREATE MATERIALIZED VIEW fact_orders AS (WITH customers AS (SELECT 
CASE
WHEN customer_id IS NULL THEN 'Unknown'
WHEN TRIM(customer_id) = '' THEN 'Invalid' ELSE TRIM(customer_id) END AS customer_id,
CASE
WHEN customer_unique_id IS NULL THEN 'Unknown'
WHEN TRIM(customer_unique_id) = '' THEN 'Invalid' ELSE TRIM(customer_unique_id) END AS customer_unique_id,
CASE
WHEN customer_city IS NULL THEN 'Unknown'
WHEN INITCAP(TRIM(REPLACE(
REGEXP_REPLACE(customer_city, '[^a-zA-Z0-9\sÀ-ÿº''-]', '', 'g'), '4o', '4º'))) = '' THEN 'Invalid'
ELSE INITCAP(TRIM(REPLACE(
REGEXP_REPLACE(customer_city, '[^a-zA-Z0-9\sÀ-ÿº''-]', '', 'g'), '4o', '4º'))) END AS customer_city,
CASE
WHEN customer_state IS NULL THEN 'Unknown'
WHEN UPPER(TRIM(customer_state)) = '' THEN 'Invalid' ELSE UPPER(TRIM(customer_state)) END AS customer_state
FROM olist.olist_customers
UNION
SELECT
'Unknown' AS customer_id,
'Unknown' AS customer_unique_id,
'Unknown' AS customer_city,
'Unknown' AS customer_state
UNION
SELECT
'Invalid' AS customer_id,
'Invalid' AS customer_unique_id,
'Invalid' AS customer_city,
'Invalid' AS customer_state),
-- Order Grain using Olist Orders and Olist Order Payments
orders AS (SELECT
oo.order_id,
CASE
WHEN oo.customer_id IS NULL THEN 'Unknown'
WHEN TRIM(oo.customer_id) = '' THEN 'Invalid' ELSE TRIM(oo.customer_id) END AS customer_id,
CAST(oo.order_purchase_timestamp AS DATE) AS order_purchase_date,
SUM(oop.payment_value) AS spend
-- Using LEFT JOIN because of thinking of having Order ID equally in Orders and Order Payments
-- If not then it most likely Data Integrity issue that needed to be flagged
FROM olist.olist_orders oo
LEFT JOIN olist.olist_order_payments oop ON oo.order_id = oop.order_id
WHERE oo.order_status = 'delivered'
GROUP BY 1, 2, 3),
-- Preparing Data to JOIN with Dim Customer and Dim Locations to get Customer Key and Location Key
join_orders AS (SELECT
o.order_id,
CASE
WHEN o.customer_id IN ('Unknown', 'Invalid') THEN o.customer_id
WHEN c.customer_id IS NULL THEN 'Ghost Data' ELSE c.customer_id END AS customer_id,
COALESCE(c.customer_unique_id, 'Ghost Data') AS customer_unique_id,
COALESCE(c.customer_city, 'Not Applicable') AS customer_city,
COALESCE(c.customer_state, 'Not Applicable') AS customer_state,
o.order_purchase_date,
o.spend
FROM orders o
LEFT JOIN customers c ON o.customer_id = c.customer_id)
SELECT
jo.order_id,
dc.customer_key,
dl.location_key,
jo.order_purchase_date,
jo.spend
FROM join_orders jo
LEFT JOIN dim_customers dc ON jo.customer_unique_id = dc.customer_unique_id
LEFT JOIN dim_locations dl ON jo.customer_city = dl.city
AND jo.customer_state = dl.state);




-- Fact Order Items
-- In Order Items we have Order Item ID referring Product Count and Freight is for one Product Unit
-- Changing Grain using GROUP BY Product ID and Order ID
CREATE MATERIALIZED VIEW fact_order_items AS (WITH order_items AS (SELECT
ooi.order_id,
CASE
WHEN ooi.product_id IS NULL THEN 'Unknown'
WHEN TRIM(ooi.product_id) = '' THEN 'Invalid' ELSE TRIM(ooi.product_id) END AS product_id,
COUNT(*) AS product_units,
SUM(ooi.price) AS total_price,
SUM(ooi.freight_value) AS total_freight
FROM olist.olist_order_items ooi
LEFT JOIN olist.olist_orders oo ON ooi.order_id = oo.order_id
WHERE oo.order_status = 'delivered'
GROUP BY 1, 2)
-- JOIN using Product ID to get Product Key
SELECT
oi.order_id,
dp.product_key,
oi.product_units,
oi.total_price,
oi.total_freight
FROM order_items oi
LEFT JOIN dim_products dp ON oi.product_id = dp.product_id);