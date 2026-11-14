BEGIN;
SET LOCAL search_path = lukovkin_food, pg_catalog;

CREATE FUNCTION check_position_restaurant() RETURNS trigger
LANGUAGE plpgsql SET search_path = lukovkin_food, pg_catalog AS $$
DECLARE v_restaurant uuid; v_product_restaurant uuid;
BEGIN
    -- Сразу берём режим последующего изменения, без SHARE → UPDATE upgrade.
    -- KEY SHARE внешних ключей совместим с NO KEY UPDATE.
    SELECT restaurant_id INTO v_restaurant FROM "order"
    WHERE order_id = NEW.order_id FOR NO KEY UPDATE;
    SELECT restaurant_id INTO v_product_restaurant FROM product
    WHERE product_id = NEW.product_id FOR NO KEY UPDATE;
    IF v_restaurant IS DISTINCT FROM v_product_restaurant THEN
        RAISE EXCEPTION 'BR-7.3: блюдо и заказ должны относиться к одному ресторану'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END $$;

CREATE FUNCTION guard_restaurant_change() RETURNS trigger
LANGUAGE plpgsql SET search_path = lukovkin_food, pg_catalog AS $$
BEGIN
    -- После ожидания блокировки REPEATABLE READ сохраняет старый снимок позиций.
    IF current_setting('transaction_isolation') = 'repeatable read' THEN
        RAISE EXCEPTION 'Для изменения принадлежности блюда/заказа используйте READ COMMITTED или SERIALIZABLE'
            USING ERRCODE = '0A000';
    END IF;
    IF TG_TABLE_NAME = 'product' THEN
        IF EXISTS (SELECT 1 FROM order_structure os JOIN "order" o USING (order_id)
                   WHERE os.product_id = NEW.product_id AND o.restaurant_id <> NEW.restaurant_id) THEN
            RAISE EXCEPTION 'BR-7.3: блюдо уже есть в заказах другого ресторана' USING ERRCODE='23514';
        END IF;
    ELSE
        IF EXISTS (SELECT 1 FROM order_structure os JOIN product p USING (product_id)
                   WHERE os.order_id = NEW.order_id AND p.restaurant_id <> NEW.restaurant_id) THEN
            RAISE EXCEPTION 'BR-7.3: ресторан заказа не совпадает с рестораном позиций' USING ERRCODE='23514';
        END IF;
    END IF;
    RETURN NEW;
END $$;

-- Проверяется итоговое состояние заказа, его позиций и оплаты.
-- Общая функция трёх constraint triggers проверяет итог на COMMIT.
CREATE FUNCTION order_integrity() RETURNS trigger
LANGUAGE plpgsql SET search_path = lukovkin_food, pg_catalog AS $$
DECLARE
    v_ids uuid[] := '{}';
    v_id uuid;
    v_subtotal numeric;
    v_expected numeric;
    v_status order_status;
    v_pay order_pay_status;
    v_expected_pay order_pay_status;
    v_positions bigint;
BEGIN
    IF TG_OP <> 'INSERT' THEN
        v_ids := array_append(v_ids, OLD.order_id);
    END IF;
    IF TG_OP <> 'DELETE' THEN
        v_ids := array_append(v_ids, NEW.order_id);
    END IF;

    -- При переносе позиции или платежа проверяются оба заказа.
    -- Единый порядок блокировок уменьшает риск взаимоблокировок.
    FOR v_id IN
        SELECT DISTINCT id FROM unnest(v_ids) AS changed(id) ORDER BY id
    LOOP
        SELECT order_amount, status, pay_status
        INTO v_subtotal, v_status, v_pay
        FROM "order"
        WHERE order_id = v_id
        FOR NO KEY UPDATE;
        -- Удаление заказа каскадно удаляет дочерние строки; проверять уже нечего.
        IF NOT FOUND THEN
            CONTINUE;
        END IF;

        SELECT count(*), round(sum(quantity * unit_price), 2)
        INTO v_positions, v_expected
        FROM order_structure
        WHERE order_id = v_id;
        IF v_positions = 0 THEN
            RAISE EXCEPTION 'BR-7.14: заказ % должен содержать хотя бы одну позицию', v_id
                USING ERRCODE = '23514';
        END IF;
        IF v_subtotal IS DISTINCT FROM v_expected THEN
            RAISE EXCEPTION 'BR-7.10: сумма заказа % равна %, сумма позиций равна %',
                v_id, v_subtotal, v_expected
                USING ERRCODE = '23514';
        END IF;

        SELECT CASE WHEN bool_or(status = 'успех') THEN 'оплачен'::order_pay_status
                    WHEN bool_and(status = 'ошибка') THEN 'ошибка'::order_pay_status
                    ELSE 'ожидает'::order_pay_status END
        INTO v_expected_pay
        FROM payment
        WHERE order_id = v_id;

        IF v_status = 'доставлен' AND v_expected_pay <> 'оплачен' THEN
            RAISE EXCEPTION 'BR-8.1: доставленный заказ % требует успешной оплаты', v_id
                USING ERRCODE = '23514';
        END IF;
        IF v_pay IS DISTINCT FROM v_expected_pay THEN
            RAISE EXCEPTION 'BR-8.7: статус оплаты заказа % не соответствует попыткам', v_id
                USING ERRCODE = '23514';
        END IF;
    END LOOP;
    RETURN NULL;
END $$;

-- TRUNCATE не запускает отложенные строковые проверки заказа.
CREATE FUNCTION guard_order_truncate() RETURNS trigger
LANGUAGE plpgsql SET search_path = lukovkin_food, pg_catalog AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM "order") THEN
        RAISE EXCEPTION 'Нельзя очистить все позиции или оплаты при сохранённых заказах'
            USING ERRCODE = '23514';
    END IF;
    RETURN NULL;
END $$;

CREATE FUNCTION sync_payment_status() RETURNS trigger
LANGUAGE plpgsql SET search_path = lukovkin_food, pg_catalog AS $$
DECLARE v_ids uuid[];
BEGIN
    IF TG_OP = 'INSERT' THEN
        SELECT array_agg(DISTINCT order_id) INTO v_ids FROM new_payments;
    ELSIF TG_OP = 'DELETE' THEN
        SELECT array_agg(DISTINCT order_id) INTO v_ids FROM old_payments;
    ELSE
        SELECT array_agg(order_id) INTO v_ids FROM (
            SELECT order_id FROM old_payments UNION SELECT order_id FROM new_payments
        ) changed;
    END IF;
    -- Платежи одного заказа сериализуются до чтения их общего статуса.
    PERFORM 1 FROM "order" WHERE order_id = ANY(v_ids)
    ORDER BY order_id FOR NO KEY UPDATE;

    UPDATE "order" o SET pay_status = x.expected
    FROM (
        SELECT a.order_id,
          CASE WHEN bool_or(p.status = 'успех') THEN 'оплачен'::order_pay_status
               WHEN bool_and(p.status = 'ошибка') THEN 'ошибка'::order_pay_status
               ELSE 'ожидает'::order_pay_status END AS expected
        FROM unnest(v_ids) a(order_id) LEFT JOIN payment p USING (order_id)
        GROUP BY a.order_id
    ) x
    -- Меняем версию строки и при равном статусе, чтобы старый снимок
    -- REPEATABLE READ не пересчитал оплату по неполным данным.
    WHERE o.order_id = x.order_id;
    RETURN NULL;
END $$;
COMMIT;
