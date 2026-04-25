CREATE TABLE transactions (
    DATE INTEGER,
    STORE_NBR INTEGER,
    LYLTY_CARD_NBR BIGINT,
    TXN_ID BIGINT,
    PROD_NBR INTEGER,
    PROD_NAME TEXT,
    PROD_QTY INTEGER,
    TOT_SALES NUMERIC
);

CREATE TABLE IF NOT EXISTS customers (
    LYLTY_CARD_NBR BIGINT,
    LIFESTAGE TEXT,
    PREMIUM_CUSTOMER TEXT
);


SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema='public' AND table_name='transactions'
ORDER BY ordinal_position;

SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema='public' AND table_name='customers'
ORDER BY ordinal_position;


ALTER TABLE transactions ADD COLUMN date_dt DATE;
UPDATE transactions
SET date_dt = DATE '1899-12-30' + (date::int);

SELECT MIN(date_dt) AS min_date, MAX(date_dt) AS max_date
FROM transactions;

SELECT COUNT(*) AS salsa_rows
FROM transactions
WHERE LOWER(prod_name) LIKE '%salsa%';

CREATE OR REPLACE VIEW transactions_no_salsa AS
SELECT *
FROM transactions
WHERE LOWER(prod_name) NOT LIKE '%salsa%';

SELECT MIN(prod_qty) AS min_qty, MAX(prod_qty) AS max_qty
FROM transactions_no_salsa;

SELECT *
FROM transactions_no_salsa
WHERE prod_qty = 200;

CREATE OR REPLACE VIEW transactions_clean AS
SELECT *
FROM transactions_no_salsa
WHERE lylty_card_nbr <> 226000;

ALTER TABLE transactions_clean ADD COLUMN pack_size INTEGER;
UPDATE transactions_clean
SET pack_size = (regexp_match(prod_name, '([0-9]+)g'))[1]::int
WHERE pack_size IS NULL;



ALTER TABLE transactions_clean ADD COLUMN brand TEXT;
UPDATE transactions_clean
SET brand = split_part(prod_name, ' ', 1)
WHERE brand IS NULL;



CREATE OR REPLACE VIEW data2 AS
SELECT
  t.*,
  c.lifestage,
  c.premium_customer,
  ROUND(t.tot_sales / NULLIF(t.prod_qty, 0),2) AS unit_price,

  EXTRACT(YEAR FROM t.date_dt)::int AS year,
  EXTRACT(MONTH FROM t.date_dt)::int AS month,
  EXTRACT(DAY FROM t.date_dt)::int AS day,
  (
    EXTRACT(YEAR FROM t.date_dt)::int * 100 +
    EXTRACT(MONTH FROM t.date_dt)::int
  ) AS yearmonth,
  DATE_TRUNC('month', t.date_dt)::date AS month_start_date,
  TO_CHAR(t.date_dt, 'Mon') AS month_name,
  EXTRACT(QUARTER FROM t.date_dt)::int AS quarter

FROM transactions_clean t
LEFT JOIN customers c
  ON t.lylty_card_nbr = c.lylty_card_nbr;
  


SELECT COUNT(*) AS missing_customer_rows
FROM data2
WHERE lifestage IS NULL OR premium_customer IS NULL;



SELECT
  lifestage,
  premium_customer,
  COUNT(DISTINCT lylty_card_nbr) AS n_customers
FROM data2
GROUP BY 1,2
ORDER BY n_customers DESC
LIMIT 20;

SELECT
  lifestage,
  premium_customer,
  SUM(prod_qty)::numeric / COUNT(DISTINCT lylty_card_nbr) AS avg_units_per_customer
FROM data2
GROUP BY 1,2
ORDER BY avg_units_per_customer DESC;

SELECT
  lifestage,
  premium_customer,
  SUM(tot_sales) / NULLIF(SUM(prod_qty),0) AS avg_price_per_unit
FROM data2
GROUP BY 1,2
ORDER BY avg_price_per_unit DESC;

--Task2

CREATE OR REPLACE VIEW measure_over_time AS
SELECT
    store_nbr,
    (EXTRACT(YEAR FROM date_dt)::int * 100 + EXTRACT(MONTH FROM date_dt)::int) AS yearmonth,
    SUM(tot_sales) AS tot_sales,
    COUNT(DISTINCT lylty_card_nbr) AS n_customers,
    COUNT(DISTINCT txn_id)::numeric / NULLIF(COUNT(DISTINCT lylty_card_nbr), 0) AS n_txn_per_cust,
    SUM(prod_qty)::numeric / NULLIF(COUNT(DISTINCT lylty_card_nbr), 0) AS n_chips_per_cust,
    SUM(tot_sales)::numeric / NULLIF(SUM(prod_qty), 0) AS avg_price_per_unit
FROM data2
GROUP BY store_nbr, yearmonth
ORDER BY store_nbr, yearmonth;


SELECT
    MIN(yearmonth) AS min_month,
    MAX(yearmonth) AS max_month,
    COUNT(DISTINCT yearmonth) AS n_months
FROM measure_over_time;


CREATE OR REPLACE VIEW stores_with_full_obs AS
SELECT store_nbr
FROM measure_over_time
GROUP BY store_nbr
HAVING COUNT(DISTINCT yearmonth) = 12;

SELECT COUNT(*) FROM stores_with_full_obs;

CREATE OR REPLACE VIEW pretrial_measures AS
SELECT *
FROM measure_over_time
WHERE yearmonth < 201902
  AND store_nbr IN (SELECT store_nbr FROM stores_with_full_obs);

SELECT
    MIN(yearmonth) AS min_month,
    MAX(yearmonth) AS max_month,
    COUNT(DISTINCT yearmonth) AS n_months
FROM pretrial_measures;


SELECT * FROM measure_over_time LIMIT 10;
SELECT COUNT(*) FROM stores_with_full_obs;
SELECT MIN(yearmonth), MAX(yearmonth), COUNT(DISTINCT yearmonth) FROM pretrial_measures;

CREATE OR REPLACE VIEW candidate_stores AS
SELECT *
FROM pretrial_measures
WHERE store_nbr <> 77;

CREATE OR REPLACE VIEW trial_store_77 AS
SELECT *
FROM pretrial_measures
WHERE store_nbr = 77;

CREATE OR REPLACE VIEW store_comparison AS
SELECT
    c.store_nbr,
    c.yearmonth,
    c.tot_sales AS candidate_sales,
    t.tot_sales AS trial_sales,
    ABS(c.tot_sales - t.tot_sales) AS sales_difference
FROM candidate_stores c
JOIN trial_store_77 t
ON c.yearmonth = t.yearmonth;

SELECT
    store_nbr,
    SUM(sales_difference) AS total_difference
FROM store_comparison
GROUP BY store_nbr
ORDER BY total_difference;

SELECT
    store_nbr,
    yearmonth,
    tot_sales
FROM measure_over_time
WHERE store_nbr IN (77,233)
AND yearmonth >= 201902
ORDER BY yearmonth;

SELECT
    store_nbr,
    yearmonth,
    tot_sales
FROM measure_over_time
WHERE store_nbr IN (77,233)
AND yearmonth < 201902
ORDER BY yearmonth;

CREATE OR REPLACE VIEW pretrial_sales_compare AS
SELECT
    t.yearmonth,
    t.tot_sales AS trial_sales,
    c.tot_sales AS control_sales
FROM measure_over_time t
JOIN measure_over_time c
ON t.yearmonth = c.yearmonth
WHERE t.store_nbr = 77
AND c.store_nbr = 233
AND t.yearmonth < 201902;

SELECT
    SUM(trial_sales) / SUM(control_sales) AS scaling_factor
FROM pretrial_sales_compare;


SELECT
    yearmonth,
    trial_sales,
    control_sales,
    control_sales * (
        SELECT SUM(trial_sales) / SUM(control_sales)
        FROM pretrial_sales_compare
    ) AS scaled_control_sales
FROM pretrial_sales_compare;

SELECT
    yearmonth,
    trial_sales,
    scaled_control_sales,
    ABS(trial_sales - scaled_control_sales)
/ scaled_control_sales AS pct_difference
FROM (
    SELECT
        yearmonth,
        trial_sales,
        control_sales * (
            SELECT SUM(trial_sales) / SUM(control_sales)
            FROM pretrial_sales_compare
        ) AS scaled_control_sales
    FROM pretrial_sales_compare
) t;


CREATE OR REPLACE VIEW trial_sales_compare AS
SELECT
    t.yearmonth,
    t.tot_sales AS trial_sales,
    c.tot_sales AS control_sales
FROM measure_over_time t
JOIN measure_over_time c
ON t.yearmonth = c.yearmonth
WHERE t.store_nbr = 77
AND c.store_nbr = 233
AND t.yearmonth >= 201902
AND t.yearmonth <= 201904;

SELECT
    yearmonth,
    trial_sales,
    control_sales,
    control_sales * (
        SELECT SUM(trial_sales) / SUM(control_sales)
        FROM pretrial_sales_compare
    ) AS scaled_control_sales
FROM trial_sales_compare;

SELECT
    yearmonth,
    trial_sales,
    scaled_control_sales,
    (trial_sales - scaled_control_sales) / scaled_control_sales
    AS trial_uplift
FROM (
    SELECT
        yearmonth,
        trial_sales,
        control_sales * (
            SELECT SUM(trial_sales) / SUM(control_sales)
            FROM pretrial_sales_compare
        ) AS scaled_control_sales
    FROM trial_sales_compare
) t;

SELECT *
FROM measure_over_time
ORDER BY store_nbr, yearmonth;


--Trial store 86

CREATE OR REPLACE VIEW candidate_stores86 AS
SELECT *
FROM pretrial_measures
WHERE store_nbr <> 86;

CREATE OR REPLACE VIEW trial_store_86 AS
SELECT *
FROM pretrial_measures
WHERE store_nbr = 86;

CREATE OR REPLACE VIEW store_comparison86 AS
SELECT
    c.store_nbr,
    c.yearmonth,
    c.tot_sales AS candidate_sales,
    t.tot_sales AS trial_sales,
    ABS(c.tot_sales - t.tot_sales) AS sales_difference
FROM candidate_stores86 c
JOIN trial_store_86 t
ON c.yearmonth = t.yearmonth;

SELECT
    store_nbr,
    SUM(sales_difference) AS total_difference
FROM store_comparison86
GROUP BY store_nbr
ORDER BY total_difference;


--trial store 88

CREATE OR REPLACE VIEW candidate_stores88 AS
SELECT *
FROM pretrial_measures
WHERE store_nbr <> 88;

CREATE OR REPLACE VIEW trial_store_88 AS
SELECT *
FROM pretrial_measures
WHERE store_nbr = 88;

CREATE OR REPLACE VIEW store_comparison88 AS
SELECT
    c.store_nbr,
    c.yearmonth,
    c.tot_sales AS candidate_sales,
    t.tot_sales AS trial_sales,
    ABS(c.tot_sales - t.tot_sales) AS sales_difference
FROM candidate_stores88 c
JOIN trial_store_88 t
ON c.yearmonth = t.yearmonth;

SELECT
    store_nbr,
    SUM(sales_difference) AS total_difference
FROM store_comparison88
GROUP BY store_nbr
ORDER BY total_difference;

powerBi

CREATE OR REPLACE VIEW powerbi_trial_dataset AS
SELECT
    m.store_nbr,
    m.yearmonth,
    TO_DATE(m.yearmonth::text || '01', 'YYYYMMDD') AS month_start_date,
    m.tot_sales,
    m.n_customers,
    m.n_txn_per_cust,
    m.n_chips_per_cust,
    m.avg_price_per_unit,
    CASE
        WHEN m.store_nbr IN (77, 86, 88) THEN 'Trial'
        WHEN m.store_nbr IN (233, 155, 237) THEN 'Control'
        ELSE 'Other'
    END AS store_role,
    CASE
        WHEN m.store_nbr IN (77, 233) THEN 'Trial 77'
        WHEN m.store_nbr IN (86, 155) THEN 'Trial 86'
        WHEN m.store_nbr IN (88, 237) THEN 'Trial 88'
        ELSE 'Other'
    END AS trial_group,
    CASE
        WHEN m.yearmonth < 201902 THEN 'Pre-Trial'
        ELSE 'Trial'
    END AS period_flag
FROM measure_over_time m
WHERE m.store_nbr IN (77, 233, 86, 155, 88, 237)
ORDER BY
    trial_group,
    store_role,
    yearmonth;

SELECT * 
FROM powerbi_trial_dataset
ORDER BY trial_group, yearmonth, store_role;

SELECT COUNT(*) AS total_rows
FROM powerbi_trial_dataset;