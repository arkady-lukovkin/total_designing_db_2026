BEGIN;
SET LOCAL search_path = lukovkin_food, pg_catalog;

CREATE PROCEDURE courier_salary()
LANGUAGE plpgsql SET search_path = lukovkin_food, pg_catalog AS $$
DECLARE v_month timestamp := date_trunc('month', localtimestamp);
BEGIN
    -- Одинаковый порядок блокировок для параллельных запусков расчёта.
    PERFORM 1 FROM courier ORDER BY courier_id FOR UPDATE;
    -- Сумма комиссии и число доставок получаются из одной выборки месяца.
    -- При повторном расчёте берём сохранённую ставку, а не ставку следующего месяца.
    WITH month_totals AS MATERIALIZED (
        SELECT c.courier_id, coalesce(cp.coefficient_used, c.coefficient) AS used,
               count(o.order_id) AS deliveries, coalesce(sum(o.commission), 0) AS commissions
        FROM courier c
        LEFT JOIN courier_pay cp ON cp.courier_id = c.courier_id
            AND cp.year = extract(year FROM v_month) AND cp.month = extract(month FROM v_month)
        LEFT JOIN "order" o ON o.courier_id = c.courier_id
            AND o.status = 'доставлен' AND o.order_timestamp >= v_month
            AND o.order_timestamp < v_month + interval '1 month'
        GROUP BY c.courier_id, c.coefficient, cp.coefficient_used
    ), paid AS (
        INSERT INTO courier_pay (year, month, courier_id, amount, coefficient_used)
        SELECT extract(year FROM v_month)::int, extract(month FROM v_month)::int,
               courier_id, round(commissions * used, 2), used
        FROM month_totals
        ON CONFLICT (year, month, courier_id) DO UPDATE SET amount = EXCLUDED.amount
        RETURNING courier_id
    )
    UPDATE courier c
    SET coefficient = CASE WHEN x.deliveries > 500 THEN 0.5
                           WHEN x.deliveries > 250 THEN 0.3
                           WHEN x.deliveries > 150 THEN 0.2 ELSE 0.1 END
    FROM month_totals x JOIN paid p USING (courier_id)
    WHERE c.courier_id = x.courier_id AND c.status <> 'уволен';
END $$;
COMMIT;
