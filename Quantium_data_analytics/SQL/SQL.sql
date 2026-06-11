CREATE TABLE IF NOT EXISTS transactions (
    date           INTEGER,        
    store_nbr    INTEGER,
    lylty_card_nbr BIGINT,
    txn_id       BIGINT,
    prod_nbr     INTEGER,
    prod_name    TEXT,
    prod_qty     INTEGER,
    tot_sales    NUMERIC
);

CREATE TABLE IF NOT EXISTS customers (
    lylty_card_nbr  BIGINT,
    lifestage        TEXT,
    premium_customer TEXT
);

ALTER TABLE transactions ADD COLUMN IF NOT EXISTS date_dt DATE;

UPDATE transactions
SET    date_dt = DATE '1899-12-30' + date
WHERE  date_dt IS NULL;  

SELECT MIN(date_dt) AS min_date,
       MAX(date_dt) AS max_date
FROM   transactions;

-- Data cleaning views (salsa filter + outlier removal)


DROP VIEW IF EXISTS transactions_clean CASCADE;


CREATE VIEW transactions_clean AS
WITH normalised AS (
    -- clean whitespace on prod_name at the source
    SELECT
        date,
        date_dt,
        store_nbr,
        lylty_card_nbr,
        txn_id,
        prod_nbr,
        prod_qty,
        tot_sales,
        prod_name                                               AS prod_name_raw,
        trim(regexp_replace(prod_name, '\s+', ' ', 'g'))        AS prod_name_clean
    FROM  transactions
    WHERE LOWER(prod_name) NOT LIKE '%salsa%'    -- remove non-chip products
      AND  lylty_card_nbr  <> 226000              -- remove bulk buyer outlier
      AND  prod_qty        <> 200                 -- remove qty outlier
),
extracted AS (
    -- extract pack_size and raw brand from the clean name
    SELECT
        *,
        (regexp_match(prod_name_clean, '([0-9]+)[gG]'))[1]::int  AS pack_size,
        split_part(prod_name_clean, ' ', 1)                      AS brand_raw
    FROM  normalised
)
SELECT
    date,
    date_dt,
    store_nbr,
    lylty_card_nbr,
    txn_id,
    prod_nbr,
    prod_name_clean                                  AS prod_name,
    prod_name_raw,
    prod_qty,
    tot_sales,
    pack_size,
    brand_raw,
    -- standardised brand map: update this list if new variants are found
    CASE brand_raw
        WHEN 'WW'      THEN 'Woolworths'
        WHEN 'Smith'   THEN 'Smiths'
        WHEN 'Dorito'  THEN 'Doritos'
        WHEN 'GrnWves' THEN 'Grain Waves'
        WHEN 'Snbts'   THEN 'Sunbites'
        WHEN 'Infzns'  THEN 'Infuzions'
        WHEN 'RRD'     THEN 'Red Rock Deli'
        WHEN 'NCC'     THEN 'Natural'
        ELSE brand_raw
    END AS brand
FROM extracted;

--  clean transactions joined with customer segment
CREATE OR REPLACE VIEW transactions_enriched AS
SELECT
    t.date_dt,
    t.store_nbr,
    t.lylty_card_nbr,
    t.txn_id,
    t.prod_nbr,
    t.prod_name,
    t.prod_qty,
    t.tot_sales,
    t.pack_size,
    t.brand,
    
    c.lifestage,
    c.premium_customer,
   
    ROUND(t.tot_sales / NULLIF(t.prod_qty, 0), 2)          AS unit_price,

    EXTRACT(YEAR    FROM t.date_dt)::int                    AS year,
    EXTRACT(MONTH   FROM t.date_dt)::int                    AS month,
    EXTRACT(DAY     FROM t.date_dt)::int                    AS day,
    EXTRACT(QUARTER FROM t.date_dt)::int                    AS quarter,
    (EXTRACT(YEAR FROM t.date_dt)::int * 100
      + EXTRACT(MONTH FROM t.date_dt)::int)               AS yearmonth,
    DATE_TRUNC('month', t.date_dt)::date                   AS month_start_date,
    TO_CHAR(t.date_dt, 'Mon')                              AS month_name
FROM       transactions_clean t
LEFT JOIN  customers c ON t.lylty_card_nbr = c.lylty_card_nbr;

Select *
FROM transactions_enriched;


-- customer segmentation
WITH segment_base AS (
    SELECT
        lifestage,
        premium_customer,
        COUNT(DISTINCT lylty_card_nbr)  AS n_customers,
        SUM(prod_qty)                     AS total_units,
        SUM(tot_sales)                    AS total_sales,
        SUM(prod_qty)                     AS total_qty
    FROM   transactions_enriched
    GROUP BY lifestage, premium_customer   
)
SELECT
    lifestage,
    premium_customer,
    n_customers,
    ROUND(total_units::numeric / NULLIF(n_customers, 0), 2)  AS avg_units_per_customer,
    ROUND(total_sales        / NULLIF(total_qty, 0),   2)  AS avg_price_per_unit
FROM   segment_base
ORDER BY n_customers DESC;
  


SELECT COUNT(*) AS missing_customer_rows
FROM transactions_enriched
WHERE lifestage IS NULL OR premium_customer IS NULL;





--Task2


WITH monthly_store_metrics AS (
    
    SELECT
        store_nbr,
        yearmonth,
        SUM(tot_sales)                                                       AS tot_sales,
        COUNT(DISTINCT lylty_card_nbr)                                      AS n_customers,
        COUNT(DISTINCT txn_id)::numeric
          / NULLIF(COUNT(DISTINCT lylty_card_nbr), 0)                    AS n_txn_per_cust,
        SUM(prod_qty)::numeric
          / NULLIF(COUNT(DISTINCT lylty_card_nbr), 0)                    AS n_chips_per_cust,
        SUM(tot_sales)::numeric / NULLIF(SUM(prod_qty), 0)               AS avg_price_per_unit
    FROM   transactions_enriched
    GROUP BY store_nbr, yearmonth
),
full_year_stores AS (
   
    SELECT store_nbr
    FROM   monthly_store_metrics
    GROUP BY store_nbr
    HAVING COUNT(DISTINCT yearmonth) = 12  
)

SELECT m.*
FROM   monthly_store_metrics m
JOIN   full_year_stores f ON m.store_nbr = f.store_nbr  
WHERE  m.yearmonth < 201902;


DROP VIEW IF EXISTS measure_over_time CASCADE;

CREATE VIEW measure_over_time AS
SELECT
    store_nbr,
    yearmonth,                                              
    month_start_date,                                       
    SUM(tot_sales)                               AS tot_sales,
    COUNT(DISTINCT lylty_card_nbr)              AS n_customers,
    COUNT(DISTINCT txn_id)                      AS n_transactions,
    ROUND(
        COUNT(DISTINCT txn_id)::numeric
        / NULLIF(COUNT(DISTINCT lylty_card_nbr), 0)
    , 2)                                         AS n_txn_per_cust,
    ROUND(
        SUM(prod_qty)::numeric
        / NULLIF(COUNT(DISTINCT lylty_card_nbr), 0)
    , 2)                                         AS n_chips_per_cust,
    ROUND(
        SUM(tot_sales)::numeric
        / NULLIF(SUM(prod_qty), 0)
    , 2)                                         AS avg_price_per_unit
FROM   transactions_enriched       
GROUP BY store_nbr, yearmonth, month_start_date;





DROP VIEW IF EXISTS stores_with_full_obs CASCADE;

CREATE VIEW stores_with_full_obs AS
SELECT   store_nbr
FROM     measure_over_time
GROUP BY store_nbr
HAVING   COUNT(DISTINCT yearmonth) = 12;  

SELECT COUNT(*) AS n_full_year_stores FROM stores_with_full_obs;




DROP VIEW IF EXISTS pretrial_measures CASCADE;

CREATE VIEW pretrial_measures AS
SELECT   m.*
FROM     measure_over_time        m
JOIN     stores_with_full_obs     f  ON m.store_nbr = f.store_nbr
WHERE    m.yearmonth < 201902;       

SELECT
    COUNT(DISTINCT store_nbr)  AS n_stores,
    MIN(yearmonth)             AS earliest,
    MAX(yearmonth)             AS latest,
    COUNT(DISTINCT yearmonth)  AS n_months
FROM   pretrial_measures;


WITH trial_store AS (
    
    SELECT
        yearmonth,
        tot_sales,
        n_customers
    FROM   pretrial_measures
    WHERE  store_nbr = 77
),
candidate_stores AS (
    
    SELECT
        store_nbr,
        yearmonth,
        tot_sales,
        n_customers
    FROM   pretrial_measures
    WHERE  store_nbr <> 77
),
comparison AS (
    
    SELECT
        c.store_nbr,
        SUM(ABS(c.tot_sales    - t.tot_sales))   AS total_sales_diff,
        SUM(ABS(c.n_customers - t.n_customers)) AS total_cust_diff
    FROM       candidate_stores c
    JOIN       trial_store t ON c.yearmonth = t.yearmonth
    GROUP BY   c.store_nbr
)
SELECT
    store_nbr,
    ROUND(total_sales_diff) AS total_sales_diff,
    ROUND(total_cust_diff)  AS total_cust_diff
FROM   comparison
ORDER BY total_sales_diff  
LIMIT  5;

--  store 233 appear first as control store



WITH pretrial_pair AS (
    
    SELECT
        trial.yearmonth,
        trial.tot_sales    AS trial_sales,
        ctrl.tot_sales     AS control_sales,
        trial.n_customers  AS trial_customers,
        ctrl.n_customers   AS control_customers
    FROM   pretrial_measures trial
    JOIN   pretrial_measures ctrl ON trial.yearmonth = ctrl.yearmonth
    WHERE  trial.store_nbr = 77
      AND  ctrl.store_nbr  = 233
),
trial_period AS (
    
    SELECT
        trial.yearmonth,
        trial.month_start_date,
        trial.tot_sales    AS trial_sales,
        ctrl.tot_sales     AS control_sales,
        trial.n_customers  AS trial_customers,
        ctrl.n_customers   AS control_customers
    FROM   measure_over_time trial
    JOIN   measure_over_time ctrl ON trial.yearmonth = ctrl.yearmonth
    WHERE  trial.store_nbr = 77
      AND  ctrl.store_nbr  = 233
      AND  trial.yearmonth BETWEEN 201902 AND 201906
)
SELECT
    tp.yearmonth,
    tp.month_start_date,

    
    tp.trial_sales,
    tp.control_sales,
    tp.trial_customers,
    tp.control_customers,

    -- sales uplift: how much more did trial store sell vs control? (trial - control) / control
    ROUND(
        (tp.trial_sales - tp.control_sales)
        / NULLIF(tp.control_sales, 0) * 100
    , 2)                                    AS sales_uplift_pct,

    -- customer uplift: did more customers come in during trial? (trial - control) / control
    ROUND(
        (tp.trial_customers - tp.control_customers)::numeric
        / NULLIF(tp.control_customers, 0) * 100
    , 2)                                    AS cust_uplift_pct,

    -- absolute dollar difference between trial and control
    ROUND(
        tp.trial_sales - tp.control_sales
    , 2)                                    AS sales_uplift_abs

FROM   trial_period tp
ORDER BY tp.yearmonth;






--Trial store 86

WITH trial_store AS (
    -- isolate trial store 86 pre-trial data
    SELECT
        yearmonth,
        tot_sales,
        n_customers
    FROM   pretrial_measures
    WHERE  store_nbr = 86
),
candidate_stores AS (
   
    SELECT
        store_nbr,
        yearmonth,
        tot_sales,
        n_customers
    FROM   pretrial_measures
    WHERE  store_nbr <> 86
),
comparison AS (
   
    SELECT
        c.store_nbr,
        SUM(ABS(c.tot_sales    - t.tot_sales))   AS total_sales_diff,
        SUM(ABS(c.n_customers - t.n_customers)) AS total_cust_diff
    FROM       candidate_stores c
    JOIN       trial_store t ON c.yearmonth = t.yearmonth
    GROUP BY   c.store_nbr
)
SELECT
    store_nbr,
    ROUND(total_sales_diff) AS total_sales_diff,
    ROUND(total_cust_diff)  AS total_cust_diff
FROM   comparison
ORDER BY total_sales_diff   
LIMIT  5;
-- Store 155 choose as control store



--trial store 88


WITH trial_store AS (
    
    SELECT
        yearmonth,
        tot_sales,
        n_customers
    FROM   pretrial_measures
    WHERE  store_nbr = 88
),
candidate_stores AS (
    
    SELECT
        store_nbr,
        yearmonth,
        tot_sales,
        n_customers
    FROM   pretrial_measures
    WHERE  store_nbr <> 88
),
comparison AS (
    
    SELECT
        c.store_nbr,
        SUM(ABS(c.tot_sales    - t.tot_sales))   AS total_sales_diff,
        SUM(ABS(c.n_customers - t.n_customers)) AS total_cust_diff
    FROM       candidate_stores c
    JOIN       trial_store t ON c.yearmonth = t.yearmonth
    GROUP BY   c.store_nbr
)
SELECT
    store_nbr,
    ROUND(total_sales_diff) AS total_sales_diff,
    ROUND(total_cust_diff)  AS total_cust_diff
FROM   comparison
ORDER BY total_sales_diff   
LIMIT  5;
-- Store 237 is choosed as control store

--power BI input

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