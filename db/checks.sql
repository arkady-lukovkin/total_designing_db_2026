\set ON_ERROR_STOP on
\timing on
-- Destructive acceptance script: only an explicitly named disposable database.
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
SELECT current_user, version();
CREATE TEMP TABLE test_marker (id integer);
CREATE FUNCTION pg_temp.ok(p_ok boolean, p_label text) RETURNS void
LANGUAGE plpgsql AS $$ BEGIN
    IF p_ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL: %', p_label; END IF;
    RAISE NOTICE 'OK: %', p_label;
END $$;
CREATE FUNCTION pg_temp.rejected(p_sql text, p_state text, p_label text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE v_state text;
BEGIN
    BEGIN
        EXECUTE p_sql;
        SET CONSTRAINTS ALL IMMEDIATE;
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
        IF v_state <> p_state THEN
            RAISE EXCEPTION 'FAIL: %, SQLSTATE % вместо %', p_label, v_state, p_state;
        END IF;
        RAISE NOTICE 'OK: % (SQLSTATE %)', p_label, v_state;
        RETURN;
    END;
    RAISE EXCEPTION 'FAIL: %: ошибочная операция разрешена', p_label;
END $$;

SELECT pg_temp.ok(current_user = 'inspector', 'проверки под inspector');
SELECT pg_temp.ok(NOT EXISTS (
    SELECT unnest(ARRAY['client','address','client_address','restaurant','courier','courier_pay',
        'product_category','product','order','order_structure','payment','review'])
    EXCEPT SELECT table_name::text FROM information_schema.tables
    WHERE table_schema = 'lukovkin_food' AND table_type = 'BASE TABLE'), 'все 12 исходных таблиц существуют');
SELECT pg_temp.ok((SELECT count(DISTINCT t.oid) = 8 FROM pg_type t JOIN pg_namespace n ON n.oid=t.typnamespace
    WHERE n.nspname='lukovkin_food' AND t.typtype='e'), '8 enum-типов');
SELECT pg_temp.ok(NOT EXISTS(SELECT 1 FROM information_schema.columns
    WHERE table_schema='lukovkin_food' AND column_name LIKE '%_id' AND data_type<>'uuid'), 'все поля *_id имеют тип UUID');
SELECT pg_temp.ok((SELECT count(*) >= 15 FROM pg_constraint
    WHERE connamespace='lukovkin_food'::regnamespace AND contype='f'), 'реализованы внешние ключи');
CALL erase_test_data();
CALL erase_test_data();
SELECT pg_temp.ok((SELECT count(*) = 0 FROM "order"), 'повторная очистка');
SELECT pg_temp.rejected('CALL insert_test_data(0)', '22023', 'value=0');
SELECT pg_temp.rejected('CALL insert_test_data(-1)', '22023', 'value<0');
SELECT pg_temp.rejected('CALL insert_test_data(NULL)', '22023', 'value=NULL');
CALL insert_test_data(10);
SELECT pg_temp.ok((SELECT count(*)=10 FROM client)
    AND (SELECT count(*)=10 FROM courier) AND (SELECT count(*)=10 FROM restaurant)
    AND (SELECT count(*)=10 FROM product_category) AND (SELECT count(*)=50 FROM address)
    AND (SELECT count(*)=50 FROM product) AND (SELECT count(*)=50 FROM "order")
    AND (SELECT count(*)=50 FROM payment) AND (SELECT count(*)=50 FROM review)
    AND (SELECT count(*)=60 FROM courier_pay), 'распределение при n=10, включая 6 месяцев выплат');
SELECT pg_temp.ok((SELECT count(DISTINCT a.address_id)=40 FROM address a JOIN client_address ca USING(address_id)),
    '40 клиентских адресов используются');
SELECT pg_temp.ok(EXISTS(SELECT 1 FROM courier WHERE status<>'уволен'), 'есть активный курьер');
SELECT pg_temp.ok(NOT EXISTS(SELECT 1 FROM client WHERE login='' OR password !~ '^[0-9a-f]{32}$'
    OR length(phone_number)<>11), 'логины, MD5 и телефоны');
SELECT pg_temp.ok(NOT EXISTS(SELECT 1 FROM product WHERE product_name !~ '^[а-яё]+$')
    AND NOT EXISTS(SELECT 1 FROM restaurant WHERE restaurant_name !~ '^[а-яё]+$'), 'названия на кириллице без префиксов');
SELECT pg_temp.ok(NOT EXISTS(SELECT 1 FROM "order" WHERE total_amount<1000
    OR commission<>round(order_amount*0.1,2) OR total_amount<>order_amount+commission
    OR delivery_timestamp<order_timestamp OR (status='доставлен' AND delivery_timestamp IS NULL)), 'суммы, комиссия и даты заказов');
SELECT pg_temp.ok(NOT EXISTS(SELECT 1 FROM "order" o LEFT JOIN (
    SELECT order_id, round(sum(quantity * unit_price),2) amount FROM order_structure GROUP BY order_id
    ) s USING(order_id) WHERE o.order_amount IS DISTINCT FROM s.amount), 'сумма каждого заказа равна стоимости его позиций');
SELECT pg_temp.ok(NOT EXISTS(SELECT 1 FROM "order" WHERE order_timestamp<localtimestamp-interval '180 days'
    OR order_timestamp>localtimestamp), 'даты в последних 180 днях');
SELECT pg_temp.ok(NOT EXISTS(SELECT 1 FROM order_structure os JOIN "order" o USING(order_id)
    JOIN product p USING(product_id) WHERE p.restaurant_id<>o.restaurant_id), 'в позициях правильный ресторан');
SELECT pg_temp.ok(NOT EXISTS(SELECT 1 FROM "order" o LEFT JOIN client_address ca
    ON ca.client_id=o.client_id AND ca.address_id=o.address_id WHERE ca.client_id IS NULL), 'адрес принадлежит клиенту');
SELECT pg_temp.ok(NOT EXISTS(SELECT 1 FROM "order" o LEFT JOIN payment p
    ON p.order_id=o.order_id AND p.status='успех' GROUP BY o.order_id HAVING count(p.payment_id)<>1),
    'ровно одна успешная оплата, в том числе проверка заказов без попыток');
SELECT pg_temp.ok(NOT EXISTS(SELECT 1 FROM payment p JOIN "order" o USING(order_id)
    WHERE p.amount<>o.total_amount OR o.pay_status<>'оплачен'), 'оплаты согласованы с заказами');
SELECT pg_temp.ok(NOT EXISTS(SELECT 1 FROM courier_pay cp LEFT JOIN (
    SELECT courier_id, extract(year FROM order_timestamp)::int y, extract(month FROM order_timestamp)::int m,
           sum(commission) commission FROM "order" WHERE status='доставлен' GROUP BY courier_id,y,m
    ) a ON a.courier_id=cp.courier_id AND a.y=cp.year AND a.m=cp.month
    WHERE cp.amount<>round(coalesce(a.commission,0)*cp.coefficient_used,2)), 'вся история выплат соответствует заказам');
SELECT pg_temp.ok(NOT EXISTS(SELECT 1 FROM product p LEFT JOIN (
    SELECT entity_id, round(avg(rating),2) rating FROM review WHERE entity_type='блюдо' GROUP BY entity_id
    ) a ON a.entity_id=p.product_id WHERE p.rating IS DISTINCT FROM a.rating)
    AND NOT EXISTS(SELECT 1 FROM restaurant r LEFT JOIN (
    SELECT entity_id, round(avg(rating),2) rating FROM review WHERE entity_type='ресторан' GROUP BY entity_id
    ) a ON a.entity_id=r.restaurant_id WHERE r.rating IS DISTINCT FROM a.rating), 'все агрегаты рейтингов после генерации');
DO $$ BEGIN FOR i IN 1..10 LOOP CALL insert_test_data(10); END LOOP; END $$;
SELECT pg_temp.ok((SELECT count(*)=110 FROM client) AND (SELECT count(*)=550 FROM "order")
    AND (SELECT count(*)=550 FROM payment) AND (SELECT count(*)=660 FROM courier_pay), '10 повторных запусков добавляют данные');
-- Diversity detects constants, not statistical uniformity. Exact frequencies and every
-- possible enum are deliberately not demanded from a finite random sample.
SELECT pg_temp.ok((SELECT count(DISTINCT work_start)>1 AND count(DISTINCT work_end)>1 FROM restaurant),
    'часы работы не являются константами');
SELECT pg_temp.ok((SELECT count(DISTINCT length(product_name))>1 FROM product)
    AND (SELECT count(DISTINCT description)>1 FROM product)
    AND (SELECT count(DISTINCT description)>1 FROM restaurant), 'разнообразие длины имен и описаний');
SELECT pg_temp.ok((SELECT count(DISTINCT status)>1 FROM "order")
    AND (SELECT count(DISTINCT status)>1 FROM product)
    AND (SELECT count(DISTINCT status)>1 FROM courier), 'генератор использует несколько допустимых статусов');
SELECT pg_temp.ok(NOT EXISTS(SELECT 1 FROM "order" o LEFT JOIN (
    SELECT order_id, round(sum(quantity*unit_price),2) amount FROM order_structure GROUP BY order_id
    ) s USING(order_id) WHERE o.order_amount IS DISTINCT FROM s.amount), 'повторные партии сохраняют суммы позиций');
SELECT pg_temp.ok(NOT EXISTS(SELECT 1 FROM review_with_client r JOIN "order" o USING(order_id)
    WHERE r.client_id IS DISTINCT FROM o.client_id), 'автор отзыва выводится из заказа');
SELECT pg_temp.ok((SELECT count(*)=110 FROM get_statistic()), 'статистика: одна строка на ресторан');
SELECT pg_temp.ok(NOT EXISTS(SELECT 1 FROM get_statistic() WHERE total_amount<avg_amount
    OR (total_amount>0 AND (best_product_name IS NULL OR best_user IS NULL))), 'контракт статистики');
CALL courier_salary();
CREATE TEMP TABLE old_salary AS SELECT * FROM courier_pay;
CREATE TEMP TABLE old_coefficient AS SELECT courier_id, coefficient FROM courier;
CALL courier_salary();
SELECT pg_temp.ok(NOT EXISTS((SELECT * FROM courier_pay EXCEPT SELECT * FROM old_salary)
    UNION ALL (SELECT * FROM old_salary EXCEPT SELECT * FROM courier_pay)), 'повторный расчёт выплат не меняет результат');
SELECT pg_temp.ok(NOT EXISTS((SELECT courier_id,coefficient FROM courier EXCEPT SELECT * FROM old_coefficient)
    UNION ALL (SELECT * FROM old_coefficient EXCEPT SELECT courier_id,coefficient FROM courier)),
    'повторный расчёт не меняет коэффициенты');
SELECT pg_temp.ok((SELECT count(*)=8 FROM information_schema.columns
    WHERE table_schema='lukovkin_food' AND table_name='how_much_money'), '8 колонок денежного отчёта');
SELECT pg_temp.ok(NOT EXISTS(SELECT 1 FROM how_much_money WHERE commission<>sum_with_commission-sum_no_commission
    OR net_profit<>commission-courier_pay OR commission_diff IS DISTINCT FROM commission-prev_commission), 'арифметика денежного отчёта');

SELECT pg_temp.rejected('UPDATE product SET price=''NaN''::numeric', '23514', 'NaN не является ценой');
SELECT pg_temp.rejected('UPDATE product SET price=-1', '23514', 'отрицательная цена');
SELECT pg_temp.rejected('UPDATE order_structure SET quantity=0', '23514', 'нулевое количество');
SELECT pg_temp.rejected('UPDATE "order" SET order_amount=1', '23514', 'заказ меньше 1000');
SELECT pg_temp.rejected('UPDATE courier SET status=''уволен'', dismissal_date=NULL', '23514', 'дата увольнения обязательна');
SELECT pg_temp.rejected('UPDATE restaurant SET work_end=work_start', '23514', 'некорректное время работы');
SELECT pg_temp.rejected('UPDATE payment SET amount=amount+1', '23514', 'сумма оплаты не совпадает');
SELECT pg_temp.rejected('DELETE FROM payment', '23514', 'нельзя оставить заказ без успешной оплаты');
SELECT pg_temp.rejected('DELETE FROM order_structure', '23503', 'FK защищает купленные объекты отзывов');
SELECT pg_temp.rejected('UPDATE review SET rating=6', '23514', 'рейтинг вне диапазона');
SELECT pg_temp.rejected('UPDATE review SET entity_id=exts.uuid_generate_v4() WHERE entity_type=''блюдо''', '23503', 'несуществующее блюдо отзыва');
SELECT pg_temp.rejected('UPDATE "order" SET address_id=(SELECT address_id FROM restaurant LIMIT 1)', '23503', 'чужой адрес доставки');
SELECT pg_temp.rejected('INSERT INTO client_address SELECT * FROM client_address LIMIT 1', '23505', 'дубликат клиент–адрес');
SELECT pg_temp.rejected('INSERT INTO order_structure SELECT * FROM order_structure LIMIT 1', '23505', 'дубликат позиции');
SELECT pg_temp.rejected('INSERT INTO payment(order_id,type,amount,transaction_id,status)
    SELECT order_id,''карта'',total_amount,exts.uuid_generate_v4(),''успех'' FROM "order" LIMIT 1', '23505', 'две успешные оплаты');

DO $$ DECLARE r uuid; c uuid; n bigint; BEGIN
    SELECT restaurant_id INTO r FROM restaurant LIMIT 1;
    SELECT product_category_id INTO c FROM product_category LIMIT 1;
    SELECT count(*) INTO n FROM product;
    CALL add_product(r,c,'Проверочное блюдо',250,NULL,'доступно','Описание',NULL);
    PERFORM pg_temp.ok((SELECT count(*)=n+1 FROM product), 'add_product добавляет блюдо');
    PERFORM pg_temp.ok((SELECT rating IS NULL FROM product WHERE product_name='Проверочное блюдо'), 'новое блюдо без отзывов имеет рейтинг NULL');
    PERFORM pg_temp.rejected(format('CALL add_product(%L,%L,''Блюдо'',250,4.5,''доступно'',''Описание'',NULL)',r,c),
        '22023','add_product: рейтинг без отзывов отклоняется');
    PERFORM pg_temp.rejected(format('CALL add_product(%L,%L,''Блюдо'',250,NULL,''доступно'',''Описание'',NULL)',
        exts.uuid_generate_v4(),c),'23503','add_product: несуществующий ресторан');
    PERFORM pg_temp.rejected(format('CALL add_product(%L,%L,''Блюдо'',-1,NULL,''доступно'',''Описание'',NULL)',r,c),
        '23514','add_product: отрицательная цена');
END $$;
CALL erase_test_data();
CALL erase_test_data();
SELECT pg_temp.ok((SELECT count(*)=0 FROM "order") AND (SELECT count(*)=0 FROM review)
    AND (SELECT count(*)=0 FROM product) AND (SELECT count(*)=0 FROM courier_pay), 'окончательная очистка');
SELECT pg_temp.ok((SELECT count(*)=0 FROM how_much_money), 'пустой денежный отчёт');
DO $$ DECLARE t record; n bigint; BEGIN
    FOR t IN SELECT tablename FROM pg_catalog.pg_tables WHERE schemaname='lukovkin_food' LOOP
        EXECUTE format('SELECT count(*) FROM lukovkin_food.%I',t.tablename) INTO n;
        PERFORM pg_temp.ok(n=0,format('очищена таблица %s',t.tablename));
    END LOOP;
END $$;
SELECT pg_temp.ok((SELECT count(*)>=12 FROM pg_catalog.pg_tables WHERE schemaname='lukovkin_food'), 'каталог доступен, структура сохранена');
\echo ALL_CHECKS_PASSED
