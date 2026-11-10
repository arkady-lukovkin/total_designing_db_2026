\set ON_ERROR_STOP on
\timing on
-- This script erases all project data. Explicit disposable-database guard.
\if :{?foodexpress_test_database}
\else
  \echo 'Pass -v foodexpress_test_database=<disposable database>'
  DO $$ BEGIN RAISE EXCEPTION 'Acceptance tests require the named disposable database and inspector'; END $$;
\endif
SELECT current_database() = :'foodexpress_test_database'
       AND current_user = 'inspector' AS safe_test_target \gset
\if :safe_test_target
\else
  \echo 'Wrong database or user; no data changed'
  DO $$ BEGIN RAISE EXCEPTION 'Acceptance tests require the named disposable database and inspector'; END $$;
\endif
SET search_path TO lukovkin_food, exts, pg_catalog;
CREATE TEMP TABLE fixture_ids (key text PRIMARY KEY, id uuid NOT NULL);
CREATE FUNCTION pg_temp.ok(p_ok boolean, p_label text) RETURNS void
LANGUAGE plpgsql AS $$ BEGIN
    IF p_ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL: %',p_label; END IF;
    RAISE NOTICE 'OK: %',p_label;
END $$;
CREATE FUNCTION pg_temp.rejected(p_sql text,p_state text,p_label text) RETURNS void
LANGUAGE plpgsql AS $$ DECLARE v_state text; BEGIN
    BEGIN
        EXECUTE p_sql;
        SET CONSTRAINTS ALL IMMEDIATE;
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_state=RETURNED_SQLSTATE;
        IF v_state<>p_state THEN RAISE EXCEPTION 'FAIL: %, SQLSTATE % вместо %',p_label,v_state,p_state; END IF;
        RAISE NOTICE 'OK: % (SQLSTATE %)',p_label,v_state;
        RETURN;
    END;
    RAISE EXCEPTION 'FAIL: %: ошибочная операция разрешена',p_label;
END $$;
CREATE FUNCTION pg_temp.id(p_key text) RETURNS uuid LANGUAGE sql AS $$
    SELECT id FROM pg_temp.fixture_ids WHERE key=p_key
$$;
-- Test-only fixture helpers live in pg_temp, never in the submitted schema.
CREATE FUNCTION pg_temp.seed() RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_id uuid; i integer;
BEGIN
    DELETE FROM pg_temp.fixture_ids;
    FOR i IN 1..5 LOOP
        INSERT INTO address(street,house_number) VALUES('Тестовая',i::text) RETURNING address_id INTO v_id;
        INSERT INTO pg_temp.fixture_ids VALUES('a'||i,v_id);
    END LOOP;
    FOR i IN 1..2 LOOP
        INSERT INTO client(login,password,phone_number) VALUES('client'||i,md5('fixture'),'7900000000'||i)
        RETURNING client_id INTO v_id;
        INSERT INTO pg_temp.fixture_ids VALUES('c'||i,v_id);
        INSERT INTO client_address VALUES(v_id,pg_temp.id('a'||i));
    END LOOP;
    FOR i IN 1..3 LOOP
        INSERT INTO restaurant(restaurant_name,address_id,description,work_start,work_end,inn,ogrn,settlement_account)
        VALUES(CASE WHEN i<3 THEN 'Одинаковое имя' ELSE 'Без заказов' END,pg_temp.id('a'||(i+2)),
            'Тестовый ресторан','07:15','22:45','1234567890','1234567890123','12345678901234567890')
        RETURNING restaurant_id INTO v_id;
        INSERT INTO pg_temp.fixture_ids VALUES('r'||i,v_id);
    END LOOP;
    INSERT INTO courier(last_name,first_name,patronymic,phone_number,coefficient)
    VALUES('Иванов','Иван',NULL,'79111111111',0.3) RETURNING courier_id INTO v_id;
    INSERT INTO pg_temp.fixture_ids VALUES('courier',v_id);
    INSERT INTO product_category(product_category_name) VALUES('Категория') RETURNING product_category_id INTO v_id;
    INSERT INTO pg_temp.fixture_ids VALUES('category',v_id);
    FOR i IN 1..3 LOOP
        INSERT INTO product(product_name,product_category_id,price,restaurant_id,description)
        VALUES(CASE WHEN i=1 THEN 'Много порций' ELSE 'Одинаковое блюдо' END,
            pg_temp.id('category'),1000,pg_temp.id(CASE WHEN i=3 THEN 'r2' ELSE 'r1' END),'Тестовое блюдо')
        RETURNING product_id INTO v_id;
        INSERT INTO pg_temp.fixture_ids VALUES('p'||i,v_id);
    END LOOP;
END $$;
CREATE FUNCTION pg_temp.make_order(p_courier uuid,p_client text,p_restaurant text,p_product text,
    p_quantity numeric,p_price numeric,p_at timestamp,p_status order_status DEFAULT 'доставлен')
RETURNS uuid LANGUAGE plpgsql AS $$ DECLARE v_id uuid; v_amount numeric; BEGIN
    v_amount:=round(p_quantity*p_price,2);
    INSERT INTO "order"(courier_id,client_id,address_id,restaurant_id,order_timestamp,
        delivery_timestamp,order_amount,status,description)
    VALUES(p_courier,pg_temp.id(p_client),pg_temp.id(CASE p_client WHEN 'c1' THEN 'a1' ELSE 'a2' END),
        pg_temp.id(p_restaurant),p_at,CASE WHEN p_status='доставлен' THEN p_at+interval '1 hour' END,
        v_amount,p_status,NULL) RETURNING order_id INTO v_id;
    INSERT INTO order_structure(order_id,product_id,quantity,unit_price)
    VALUES(v_id,pg_temp.id(p_product),p_quantity,p_price);
    INSERT INTO payment(order_id,type,amount,status) VALUES(v_id,'наличные',v_amount+round(v_amount*.1,2),'успех');
    RETURN v_id;
END $$;
CALL erase_test_data();
SELECT pg_temp.seed();
INSERT INTO fixture_ids VALUES
    ('o1',pg_temp.make_order(pg_temp.id('courier'),'c1','r1','p1',3,1000,'2026-01-10')),
    ('o2',pg_temp.make_order(pg_temp.id('courier'),'c1','r1','p2',1,2000,'2026-01-11')),
    ('o3',pg_temp.make_order(pg_temp.id('courier'),'c2','r1','p2',1,2000,'2026-01-12')),
    ('o4',pg_temp.make_order(pg_temp.id('courier'),'c2','r2','p3',1,4000,'2026-01-13')),
    ('cancelled',pg_temp.make_order(pg_temp.id('courier'),'c2','r1','p2',20,2000,'2026-01-14','отменён'));
SELECT pg_temp.ok((SELECT count(*)=5 FROM "order" WHERE description IS NULL),'комментарий заказа необязателен');
SELECT pg_temp.ok((SELECT count(*)=3 FROM get_statistic()),'одноимённые рестораны не объединяются');
SELECT pg_temp.ok(EXISTS(SELECT 1 FROM get_statistic() WHERE restaurant_name='Одинаковое имя'
    AND total_amount=7700 AND avg_amount=7700::numeric/3 AND best_product_name='Много порций' AND best_user='client1')
    AND EXISTS(SELECT 1 FROM get_statistic() WHERE restaurant_name='Одинаковое имя'
    AND total_amount=4400 AND avg_amount=4400 AND best_product_name='Одинаковое блюдо' AND best_user='client2'),
    'точные суммы, лидер по количеству порций, клиент по числу заказов, отмена исключена');
SELECT pg_temp.ok(EXISTS(SELECT 1 FROM get_statistic() WHERE restaurant_name='Без заказов'
    AND total_amount=0 AND avg_amount=0 AND best_product_name IS NULL AND best_user IS NULL),'ресторан без доставок');
-- A second position must not multiply order totals in reporting.
BEGIN;
INSERT INTO order_structure VALUES(pg_temp.id('o1'),pg_temp.id('p2'),1,1000);
UPDATE "order" SET order_amount=4000 WHERE order_id=pg_temp.id('o1');
UPDATE payment SET amount=4400 WHERE order_id=pg_temp.id('o1');
COMMIT;
SELECT pg_temp.ok(EXISTS(SELECT 1 FROM get_statistic() WHERE total_amount=8800 AND avg_amount=8800::numeric/3),
    'несколько позиций не умножают общую сумму заказа');
UPDATE product SET price=1500 WHERE product_id=pg_temp.id('p1');
SELECT pg_temp.ok((SELECT unit_price=1000 FROM order_structure WHERE order_id=pg_temp.id('o1') AND product_id=pg_temp.id('p1'))
    AND (SELECT order_amount=4000 FROM "order" WHERE order_id=pg_temp.id('o1')),'смена цены меню сохраняет историю');
INSERT INTO fixture_ids VALUES('new_price',pg_temp.make_order(pg_temp.id('courier'),'c1','r1','p1',1,1500,'2026-01-15'));
SELECT pg_temp.ok((SELECT order_amount=1500 FROM "order" WHERE order_id=pg_temp.id('new_price')),'новый заказ использует новую цену');
INSERT INTO fixture_ids VALUES('fraction',pg_temp.make_order(pg_temp.id('courier'),'c1','r1','p1',1.234,999.99,'2026-01-16'));
SELECT pg_temp.ok((SELECT order_amount=1233.99 AND commission=123.40 AND total_amount=1357.39
    FROM "order" WHERE order_id=pg_temp.id('fraction')),'дробные порции и округление денежной суммы до копеек');
SELECT pg_temp.rejected('UPDATE order_structure SET unit_price=NULL','23502','цена позиции обязательна');
SELECT pg_temp.rejected('UPDATE order_structure SET unit_price=-1','23514','цена позиции неотрицательна');
SELECT pg_temp.rejected('UPDATE order_structure SET unit_price=''NaN''::numeric','23514','цена позиции не NaN');
SELECT pg_temp.rejected('UPDATE restaurant SET inn=''123''','23514','ИНН задан атомарно и проверяется');
SELECT pg_temp.rejected('UPDATE restaurant SET ogrn=''123''','23514','проверка ОГРН');
SELECT pg_temp.rejected('UPDATE restaurant SET settlement_account=''abc''','23514','проверка расчётного счёта');
SELECT pg_temp.rejected('UPDATE courier SET first_name=''''','23514','имя курьера обязательно');
SELECT pg_temp.rejected('UPDATE order_structure SET product_id=pg_temp.id(''p3'') WHERE order_id=pg_temp.id(''o2'')',
    '23514','позиция из другого ресторана');
-- The deferred check must fail at COMMIT and roll back its entire transaction.
BEGIN;
UPDATE order_structure SET unit_price=1100 WHERE order_id=pg_temp.id('new_price');
\set ON_ERROR_STOP off
COMMIT;
\set commit_state :SQLSTATE
\set ON_ERROR_STOP on
SELECT pg_temp.ok(:'commit_state'='23514','COMMIT отклоняет несогласованную стоимость позиций');
SELECT pg_temp.ok((SELECT unit_price=1500 FROM order_structure WHERE order_id=pg_temp.id('new_price')),'неуспешный COMMIT откатывает изменения');
BEGIN;
DELETE FROM payment WHERE order_id=pg_temp.id('new_price');
\set ON_ERROR_STOP off
COMMIT;
\set commit_state :SQLSTATE
\set ON_ERROR_STOP on
SELECT pg_temp.ok(:'commit_state'='23514','COMMIT отклоняет заказ без успешной оплаты');
SELECT pg_temp.ok((SELECT count(*)=1 FROM payment WHERE order_id=pg_temp.id('new_price')),'откат восстанавливает оплату');
BEGIN;
DELETE FROM order_structure WHERE order_id=pg_temp.id('new_price');
\set ON_ERROR_STOP off
COMMIT;
\set commit_state :SQLSTATE
\set ON_ERROR_STOP on
SELECT pg_temp.ok(:'commit_state'='23514','COMMIT отклоняет заказ без позиций');
SELECT pg_temp.ok((SELECT count(*)=1 FROM order_structure WHERE order_id=pg_temp.id('new_price')),'откат восстанавливает позицию');
-- Additional unsuccessful attempts are legal and must not hide an existing success.
WITH inserted AS (
    INSERT INTO payment(order_id,type,amount,status)
    SELECT order_id,'наличные',total_amount,'ошибка' FROM "order" WHERE order_id=pg_temp.id('new_price')
    RETURNING payment_id
) INSERT INTO fixture_ids SELECT 'extra_attempt',payment_id FROM inserted;
SELECT pg_temp.ok((SELECT pay_status='оплачен' FROM "order" WHERE order_id=pg_temp.id('new_price'))
    AND (SELECT count(*)=2 AND count(*) FILTER(WHERE status='успех')=1
        AND count(*) FILTER(WHERE status='ошибка')=1 FROM payment WHERE order_id=pg_temp.id('new_price')),
    'INSERT ошибочной попытки сохраняет одну успешную оплату и оплаченный заказ');
UPDATE payment SET status='в_обработке' WHERE payment_id=pg_temp.id('extra_attempt');
SELECT pg_temp.ok((SELECT pay_status='оплачен' FROM "order" WHERE order_id=pg_temp.id('new_price'))
    AND (SELECT count(*)=2 AND count(*) FILTER(WHERE status='успех')=1
        AND count(*) FILTER(WHERE status='в_обработке')=1 FROM payment WHERE order_id=pg_temp.id('new_price')),
    'UPDATE неуспешной попытки в обработку сохраняет приоритет успешной оплаты');
DELETE FROM payment WHERE payment_id=pg_temp.id('extra_attempt');
SELECT pg_temp.ok((SELECT pay_status='оплачен' FROM "order" WHERE order_id=pg_temp.id('new_price'))
    AND (SELECT count(*)=1 AND count(*) FILTER(WHERE status='успех')=1
        FROM payment WHERE order_id=pg_temp.id('new_price')),
    'DELETE неуспешной попытки оставляет оплаченный заказ и одну успешную оплату');
-- Three purchases of p2 with ratings 3/4/5. No manufactured rating column values.
INSERT INTO review(entity_id,entity_type,order_id,description,rating) VALUES
    (pg_temp.id('p2'),'блюдо',pg_temp.id('o1'),'Первый',3),
    (pg_temp.id('p2'),'блюдо',pg_temp.id('o2'),'Второй',4),
    (pg_temp.id('p2'),'блюдо',pg_temp.id('o3'),'Третий',5);
SELECT pg_temp.ok((SELECT rating=4 FROM product WHERE product_id=pg_temp.id('p2')),'рейтинг после INSERT: среднее 3/4/5');
SELECT pg_temp.ok((SELECT count(*)=3 FROM review_with_client WHERE client_id IN(pg_temp.id('c1'),pg_temp.id('c2')))
    AND (SELECT client_id=pg_temp.id('c2') FROM review_with_client WHERE order_id=pg_temp.id('o3')),'автор отзыва выводится из покупки');
DELETE FROM review WHERE order_id=pg_temp.id('o1');
SELECT pg_temp.ok((SELECT rating=4.5 FROM product WHERE product_id=pg_temp.id('p2')),'DELETE пересчитывает средний рейтинг');
UPDATE review SET entity_id=pg_temp.id('r1'),entity_type='ресторан' WHERE order_id=pg_temp.id('o2');
SELECT pg_temp.ok((SELECT rating=5 FROM product WHERE product_id=pg_temp.id('p2'))
    AND (SELECT rating=4 FROM restaurant WHERE restaurant_id=pg_temp.id('r1')),'перенос отзыва пересчитывает старый и новый объект');
UPDATE review SET rating=2 WHERE order_id=pg_temp.id('o2');
SELECT pg_temp.ok((SELECT rating=2 FROM restaurant WHERE restaurant_id=pg_temp.id('r1')),'UPDATE оценки того же объекта');
UPDATE "order" SET client_id=pg_temp.id('c2'),address_id=pg_temp.id('a2') WHERE order_id=pg_temp.id('o2');
SELECT pg_temp.ok((SELECT client_id=pg_temp.id('c2') FROM review_with_client WHERE order_id=pg_temp.id('o2')),
    'смена клиента заказа не оставляет устаревшего автора отзыва');
SELECT pg_temp.rejected('UPDATE review SET entity_id=pg_temp.id(''p1''),entity_type=''блюдо'' WHERE order_id=pg_temp.id(''o3'')',
    '23503','отзыв только о купленном блюде');
SELECT pg_temp.rejected('UPDATE review SET entity_id=pg_temp.id(''r2'') WHERE entity_type=''ресторан''',
    '23503','отзыв только о ресторане заказа');
DELETE FROM review;
SELECT pg_temp.ok((SELECT rating IS NULL FROM product WHERE product_id=pg_temp.id('p2'))
    AND (SELECT rating IS NULL FROM restaurant WHERE restaurant_id=pg_temp.id('r1')),'последний отзыв удалён: рейтинг NULL');
SELECT pg_temp.ok((SELECT array_agg(column_name::text||':'||data_type ORDER BY ordinal_position)=ARRAY[
    'year_month:text','sum_no_commission:numeric','sum_with_commission:numeric','commission:numeric',
    'prev_commission:numeric','commission_diff:numeric','courier_pay:numeric','net_profit:numeric']
    FROM information_schema.columns WHERE table_schema='lukovkin_food' AND table_name='how_much_money'),
    'точные имена, порядок и типы колонок how_much_money');
SELECT pg_temp.ok((SELECT proargnames=ARRAY['restaurant_name','best_product_name','total_amount','avg_amount','best_user']
    AND proallargtypes=ARRAY['text'::regtype::oid,'text'::regtype::oid,'numeric'::regtype::oid,'numeric'::regtype::oid,'text'::regtype::oid]
    FROM pg_proc WHERE oid='get_statistic()'::regprocedure),'контракт результата get_statistic');
SELECT pg_temp.ok(NOT EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='lukovkin_food'
    AND table_name='review' AND column_name='client_id'),'автор не дублируется в review');
SELECT pg_temp.ok((SELECT is_nullable='NO' AND column_default IS NULL AND numeric_precision=7 AND numeric_scale=2
    FROM information_schema.columns WHERE table_schema='lukovkin_food' AND table_name='order_structure'
    AND column_name='unit_price'),'снимок цены numeric(7,2), NOT NULL, без фиктивного DEFAULT');
SELECT pg_temp.ok((SELECT is_updatable='NO' FROM information_schema.views
    WHERE table_schema='lukovkin_food' AND table_name='review_with_client'),'представление автора доступно только для чтения');
CALL erase_test_data();
\echo REGRESSION_CHECKS_PASSED
