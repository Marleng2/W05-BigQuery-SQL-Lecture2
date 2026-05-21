-- Query 1: Total users + new users using a CTE
-- Create a temporary table called UserInfo
-- Identify whether each user is a new user
-- based on first_visit or first_open events
-- Count total users and total new users

WITH UserInfo AS (
SELECT
user_pseudo_id,
MAX(IF(event_name IN ('first_visit', 'first_open'), 1, 0)) AS is_new_user
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20201130'
GROUP BY user_pseudo_id
)
SELECT
COUNT(*) AS total_users,
SUM(is_new_user) AS new_users
FROM UserInfo;


-- Query 2A: Extract page_location from event_params
-- Convert event timestamps into readable format
-- Extract the page_location parameter
-- from the event_params array
-- Return page_view events only

SELECT
TIMESTAMP_MICROS(event_timestamp) AS event_time,
(
SELECT value.string_value
FROM UNNEST(event_params)
WHERE key = 'page_location' LIMIT 1
) AS page_location
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
WHERE event_name = 'page_view'
AND _TABLE_SUFFIX BETWEEN '20201201' AND '20201202'
LIMIT 50;


-- Query 2B: Analyze purchase items using UNNEST
-- Flatten the items array
-- Return one row per item
-- Count how often each item appeared in purchase

SELECT
event_date,
item.item_name,
COUNT(*) AS item_rows
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*` e,
UNNEST(e.items) AS item
WHERE e.event_name = 'purchase'
AND _TABLE_SUFFIX BETWEEN '20201201' AND '20201231'
GROUP BY event_date, item.item_name
ORDER BY item_rows DESC
LIMIT 20;

-- Query 3A: Show event types seen each day
-- Group events by date
-- Combine event names 
-- Sort event names alphabetically

SELECT
event_date,
STRING_AGG(DISTINCT event_name, ', ' ORDER BY event_name) AS events_seen
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
WHERE _TABLE_SUFFIX BETWEEN '20201201' AND '20201203'
GROUP BY event_date
ORDER BY event_date;


-- Query 3B: Create list of items added to cart
-- Flatten the items array
-- Group data by user
-- Store item names inside an array

SELECT
    user_pseudo_id,
    ARRAY_AGG(item_name) AS items_added_to_cart
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`,
UNNEST(items) AS item
WHERE event_name = 'add_to_cart'
AND _TABLE_SUFFIX BETWEEN '20201201' AND '20201231'
GROUP BY user_pseudo_id
ORDER BY user_pseudo_id
LIMIT 10;


-- Query 3C: Build a session-level cart summary
-- Create a CTE for add_to_cart events
-- Extract session ID from event_params
-- Flatten item data
-- Build an array of cart items per session

WITH add_to_cart AS (
  SELECT
    user_pseudo_id,
    (
      SELECT value.int_value 
      FROM UNNEST(event_params) 
      WHERE key = 'ga_session_id'
    ) AS session_id,
    TIMESTAMP_MICROS(event_timestamp) AS event_timestamp,
    i.item_id,
    i.item_name,
    i.quantity,
    i.price
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`,
  UNNEST(items) AS i
  WHERE event_name = 'add_to_cart'
    AND _TABLE_SUFFIX BETWEEN '20210101' AND '20211231'  -- cost control
)
SELECT
  user_pseudo_id,
  session_id,
  COUNT(*) AS total_add_to_cart_events,              -- added insight
  ARRAY_AGG(
    STRUCT(item_id, item_name, quantity, price, event_timestamp)
    ORDER BY quantity DESC, event_timestamp ASC
    LIMIT 10
  ) AS cart_items
FROM add_to_cart
WHERE session_id IS NOT NULL                          --  filter nulls
GROUP BY user_pseudo_id, session_id;



-- Query 4: Join daily users with daily purchases
-- Create a CTE for daily users
-- Create a CTE for daily purchases
-- Join both datasets by event_date
-- Calculate conversion rate

WITH daily_users AS (
  SELECT
    event_date,
    COUNT(DISTINCT user_pseudo_id) AS users
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE _TABLE_SUFFIX BETWEEN '20201201' AND '20201231'
  GROUP BY event_date
),
daily_purchases AS (
  SELECT
    event_date,
    COUNT(DISTINCT
      (SELECT value.string_value
       FROM UNNEST(event_params)
       WHERE key = 'transaction_id')
    ) AS purchases    -- distinct transactions
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE event_name = 'purchase'
    AND _TABLE_SUFFIX BETWEEN '20201201' AND '20201231'
  GROUP BY event_date
)
SELECT
  u.event_date,
  u.users,
  -- turns “no purchase row (NULL)” into 0 purchases, which is what you want for a daily time series
  IFNULL(p.purchases, 0) AS purchases,              
  -- Conversion rate: what % of daily users made a purchase
  ROUND(
    IFNULL(p.purchases, 0) / NULLIF(u.users, 0) * 100, 2
  ) AS conversion_rate_pct        -- NULLIF prevents division by zero
FROM daily_users u
LEFT JOIN daily_purchases p
  ON u.event_date = p.event_date
ORDER BY u.event_date;



-- Query 5A: Find top 3 event types per day
-- Count events by date and event name
-- Rank event types within each day
-- Keep only the top 3 ranked events

WITH daily_event_counts AS (
SELECT
event_date,
event_name,
COUNT(*) AS events
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
WHERE _TABLE_SUFFIX BETWEEN '20201201' AND '20201207'
GROUP BY event_date, event_name
)
SELECT
event_date,
event_name,
events,
RANK() OVER (PARTITION BY event_date ORDER BY events DESC) AS rnk
FROM daily_event_counts
QUALIFY rnk <= 3 
ORDER BY event_date, rnk;

-- Query 5B: Calculate rolling 7-day average of purchases
-- Count purchases per day
-- Use a window function to calculate
-- a moving 7-day average

WITH daily_purchases AS (
SELECT
PARSE_DATE('%Y%m%d', event_date) AS dt,
COUNT(*) AS purchases
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
WHERE event_name = 'purchase'
AND _TABLE_SUFFIX BETWEEN '20201201' AND '20201231' GROUP BY dt
)
SELECT
dt,
purchases,
AVG(purchases) OVER (
ORDER BY dt
ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
) AS purchases_7d_avg
FROM daily_purchases
ORDER BY dt;


-- Query 6: Approximate distinct users by event type
-- Group events by event_name
-- Estimate distinct users using APPROX_COUNT_DISTINCT
-- Sort event types by estimated users

SELECT
event_name,
APPROX_COUNT_DISTINCT(user_pseudo_id) AS approx_users
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
WHERE _TABLE_SUFFIX BETWEEN '20201201' AND '20201231'
GROUP BY event_name
ORDER BY approx_users DESC
LIMIT 15;