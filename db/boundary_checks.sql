\set ON_ERROR_STOP on
\timing on
-- Guarded regression also installs pg_temp fixture builders. Use a fresh session.
\ir regression_checks.sql
SELECT pg_temp.seed();
CREATE TEMP TABLE salary_cases(deliveries integer PRIMARY KEY, expected numeric, courier_id uuid);
DO $$ DECLARE v_n integer; v_id uuid; BEGIN
    FOREACH v_n IN ARRAY ARRAY[0,150,151,250,251,500,501] LOOP
        INSERT INTO courier(last_name,first_name,phone_number,coefficient)
        VALUES('Граница','Тест','79222222222',0.3) RETURNING courier_id INTO v_id;
        INSERT INTO salary_cases VALUES(v_n,CASE WHEN v_n>500 THEN .5 WHEN v_n>250 THEN .3 WHEN v_n>150 THEN .2 ELSE .1 END,v_id);
    END LOOP;
END $$;
-- Build the larger boundary fixture in batches, not 1803 procedure invocations.
BEGIN;
CREATE TEMP TABLE salary_orders AS
SELECT exts.uuid_generate_v4() AS order_id,s.courier_id FROM salary_cases s
CROSS JOIN LATERAL generate_series(1,s.deliveries) AS n;
INSERT INTO "order"(order_id,courier_id,client_id,address_id,restaurant_id,order_timestamp,
    delivery_timestamp,order_amount,status,description)
SELECT order_id,courier_id,pg_temp.id('c1'),pg_temp.id('a1'),pg_temp.id('r1'),
    date_trunc('month',localtimestamp)+interval '1 day',date_trunc('month',localtimestamp)+interval '25 hours',
    1000,'доставлен',NULL FROM salary_orders;
INSERT INTO order_structure(order_id,product_id,quantity,unit_price)
SELECT order_id,pg_temp.id('p1'),1,1000 FROM salary_orders;
INSERT INTO payment(order_id,type,amount,status)
SELECT order_id,'наличные',1100,'успех' FROM salary_orders;
COMMIT;
CALL courier_salary();
SELECT pg_temp.ok(NOT EXISTS(SELECT 1 FROM salary_cases s JOIN courier c USING(courier_id)
    LEFT JOIN courier_pay cp ON cp.courier_id=s.courier_id AND cp.year=extract(year FROM current_date)
        AND cp.month=extract(month FROM current_date)
    WHERE c.coefficient<>s.expected OR cp.amount IS DISTINCT FROM s.deliveries*30::numeric
        OR cp.coefficient_used IS DISTINCT FROM .3::numeric),
    'courier_salary: реальные пороги 0/150/151/250/251/500/501, выплата по старой ставке .3');
CREATE TEMP TABLE salary_snapshot AS SELECT * FROM courier_pay;
CREATE TEMP TABLE coefficient_snapshot AS SELECT courier_id,coefficient FROM courier;
CALL courier_salary();
SELECT pg_temp.ok(NOT EXISTS((SELECT * FROM courier_pay EXCEPT SELECT * FROM salary_snapshot)
    UNION ALL (SELECT * FROM salary_snapshot EXCEPT SELECT * FROM courier_pay))
    AND NOT EXISTS((SELECT courier_id,coefficient FROM courier EXCEPT SELECT * FROM coefficient_snapshot)
    UNION ALL (SELECT * FROM coefficient_snapshot EXCEPT SELECT courier_id,coefficient FROM courier)),
    'повторная salary не меняет выплату и следующий коэффициент');
UPDATE courier SET status='уволен',dismissal_date=current_date,coefficient=.5
WHERE courier_id=(SELECT courier_id FROM salary_cases WHERE deliveries=151);
CALL courier_salary();
SELECT pg_temp.ok((SELECT coefficient=.5 FROM courier WHERE courier_id=(SELECT courier_id FROM salary_cases WHERE deliveries=151))
    AND (SELECT amount=4530 AND coefficient_used=.3 FROM courier_pay
        WHERE courier_id=(SELECT courier_id FROM salary_cases WHERE deliveries=151)
        AND year=extract(year FROM current_date) AND month=extract(month FROM current_date)),
    'уволенный получает заработанное, его коэффициент не меняется');
-- Microsecond boundaries; order and delivery dates deliberately cross months.
CALL erase_test_data();
SELECT pg_temp.seed();
INSERT INTO fixture_ids VALUES
    ('before_month',pg_temp.make_order(pg_temp.id('courier'),'c1','r1','p1',1,1000,date_trunc('month',localtimestamp)-interval '1 microsecond')),
    ('month_start',pg_temp.make_order(pg_temp.id('courier'),'c1','r1','p1',1,2000,date_trunc('month',localtimestamp))),
    ('month_end',pg_temp.make_order(pg_temp.id('courier'),'c1','r1','p1',1,3000,date_trunc('month',localtimestamp)+interval '1 month'-interval '1 microsecond')),
    ('next_month',pg_temp.make_order(pg_temp.id('courier'),'c1','r1','p1',1,4000,date_trunc('month',localtimestamp)+interval '1 month')),
    ('cancelled',pg_temp.make_order(pg_temp.id('courier'),'c1','r1','p1',1,5000,date_trunc('month',localtimestamp),'отменён'));
CALL courier_salary();
SELECT pg_temp.ok((SELECT amount=150 AND coefficient_used=.3 FROM courier_pay
    WHERE courier_id=pg_temp.id('courier') AND year=extract(year FROM current_date) AND month=extract(month FROM current_date)),
    'salary: полуоткрытый месяц по дате заказа, не доставки, только доставленные');
SELECT pg_temp.ok((SELECT sum_no_commission=5000 AND commission=500 AND courier_pay=150 AND net_profit=350
    FROM how_much_money WHERE year_month=to_char(current_date,'YYYY-MM')),
    'денежный отчёт использует ту же границу месяца и фактическую выплату');
-- A year boundary with an empty January.
CALL erase_test_data();
SELECT pg_temp.seed();
SELECT pg_temp.make_order(pg_temp.id('courier'),'c1','r1','p1',1,1000,'2025-12-31 23:59:59.999999');
SELECT pg_temp.make_order(pg_temp.id('courier'),'c1','r1','p1',1,2000,'2026-02-01 00:00:00');
SELECT pg_temp.ok((SELECT count(*)=3 FROM how_much_money),'отчёт заполняет январь между декабрём и февралём');
SELECT pg_temp.ok((SELECT sum_no_commission=0 AND sum_with_commission=0 AND commission=0
    AND courier_pay=0 AND net_profit=0 AND prev_commission=100 AND commission_diff=-100
    FROM how_much_money WHERE year_month='2026-01'),'пустой месяц содержит нули, изменение комиссии -100');
SELECT pg_temp.ok((SELECT prev_commission=0 AND commission_diff=200 FROM how_much_money WHERE year_month='2026-02'),
    'LAG учитывает пустой календарный месяц');
SELECT pg_temp.ok((SELECT prev_commission IS NULL AND commission_diff IS NULL FROM how_much_money WHERE year_month='2025-12'),
    'первый месяц не имеет предыдущего значения');
CALL erase_test_data();
SELECT pg_temp.ok((SELECT count(*)=0 FROM how_much_money),'пустая база даёт пустой денежный отчёт');
\echo BOUNDARY_CHECKS_PASSED
