BEGIN;
SET LOCAL search_path = lukovkin_food, pg_catalog;

CREATE VIEW how_much_money AS
WITH RECURSIVE delivered AS MATERIALIZED (
    SELECT date_trunc('month', order_timestamp)::date month_start,
           sum(order_amount) no_commission, sum(total_amount) with_commission
    FROM "order" WHERE status = 'доставлен'
    GROUP BY date_trunc('month', order_timestamp)::date
), bounds AS (
    SELECT min(month_start) first_month, max(month_start) last_month FROM delivered
), months(month_start) AS (
    SELECT first_month FROM bounds WHERE first_month IS NOT NULL
    UNION ALL
    SELECT (m.month_start + interval '1 month')::date
    FROM months m CROSS JOIN bounds b WHERE m.month_start < b.last_month
), salaries AS (
    SELECT make_date(year, month, 1) month_start, sum(amount) salary
    FROM courier_pay GROUP BY year, month
), amounts AS (
    SELECT m.month_start, coalesce(d.no_commission, 0) no_commission,
           coalesce(d.with_commission, 0) with_commission,
           coalesce(d.with_commission - d.no_commission, 0) commission,
           coalesce(s.salary, 0) salary
    FROM months m LEFT JOIN delivered d USING (month_start)
    LEFT JOIN salaries s USING (month_start)
), comparison AS (
    SELECT *, lag(commission) OVER (ORDER BY month_start) prev_commission FROM amounts
)
SELECT to_char(month_start, 'YYYY-MM')::text year_month,
       no_commission::numeric sum_no_commission, with_commission::numeric sum_with_commission,
       commission::numeric, prev_commission::numeric,
       (commission - prev_commission)::numeric commission_diff,
       salary::numeric courier_pay, (commission - salary)::numeric net_profit
FROM comparison ORDER BY month_start;
COMMIT;
