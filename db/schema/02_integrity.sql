BEGIN;
SET LOCAL search_path = lukovkin_food, pg_catalog;

-- Совместимый интерфейс оплаты принимает сумму, но не хранит её повторно.
CREATE FUNCTION write_payment() RETURNS trigger
LANGUAGE plpgsql SET search_path = lukovkin_food, pg_catalog AS $$
DECLARE v_total numeric; v_current payment_core%ROWTYPE;
BEGIN
    IF TG_OP <> 'INSERT' THEN
        SELECT * INTO v_current FROM payment_core
        WHERE payment_id = OLD.payment_id FOR UPDATE;
        IF NOT FOUND THEN RETURN NULL; END IF;
        -- NEW представления может быть прочитан до ожидания чужого UPDATE.
        -- Не перезаписываем более свежие поля устаревшим снимком.
        IF (v_current.order_id, v_current.type, v_current.transaction_id,
            v_current.transaction_timestamp, v_current.status)
           IS DISTINCT FROM
           (OLD.order_id, OLD.type, OLD.transaction_id, OLD.transaction_timestamp, OLD.status) THEN
            RAISE EXCEPTION 'Оплата % изменена параллельно; повторите транзакцию', OLD.payment_id
                USING ERRCODE = '40001';
        END IF;
    END IF;
    IF TG_OP = 'DELETE' THEN
        DELETE FROM payment_core WHERE payment_id = OLD.payment_id;
        IF NOT FOUND THEN RETURN NULL; END IF;
        RETURN OLD;
    END IF;

    SELECT total_amount INTO v_total FROM "order"
    WHERE order_id = NEW.order_id FOR NO KEY UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Оплата ссылается на отсутствующий заказ %', NEW.order_id
            USING ERRCODE = '23503';
    END IF;
    IF NEW.amount IS DISTINCT FROM v_total THEN
        RAISE EXCEPTION 'BR-8.4: сумма оплаты заказа % должна равняться %', NEW.order_id, v_total
            USING ERRCODE = '23514';
    END IF;
    IF TG_OP = 'INSERT' THEN
        INSERT INTO payment_core (payment_id, order_id, type, transaction_id, transaction_timestamp, status)
        VALUES (NEW.payment_id, NEW.order_id, NEW.type, NEW.transaction_id, NEW.transaction_timestamp, NEW.status);
    ELSE
        UPDATE payment_core SET payment_id = NEW.payment_id, order_id = NEW.order_id,
            type = NEW.type, transaction_id = NEW.transaction_id,
            transaction_timestamp = NEW.transaction_timestamp, status = NEW.status
        WHERE payment_id = OLD.payment_id;
        IF NOT FOUND THEN RETURN NULL; END IF;
    END IF;
    NEW.amount := v_total;
    RETURN NEW;
END $$;

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

-- Заказ, позиции и успешная оплата образуют одну транзакцию.
-- Общая функция трёх constraint triggers проверяет итог на COMMIT.
CREATE FUNCTION order_integrity() RETURNS trigger
LANGUAGE plpgsql SET search_path = lukovkin_food, pg_catalog AS $$
DECLARE
    v_ids uuid[] := '{}';
    v_id uuid;
    v_subtotal numeric;
    v_expected numeric;
    v_pay order_pay_status;
    v_positions bigint;
    v_success bigint;
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
        SELECT order_amount, pay_status
        INTO v_subtotal, v_pay
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

        SELECT count(*) FILTER (WHERE status = 'успех') INTO v_success
        FROM payment_core
        WHERE order_id = v_id;
        IF v_success <> 1 THEN
            RAISE EXCEPTION 'BR-8.1: заказ % должен иметь ровно одну успешную оплату на COMMIT', v_id
                USING ERRCODE = '23514';
        END IF;
        IF v_pay <> 'оплачен' THEN
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
    IF EXISTS (SELECT 1 FROM order_core) THEN
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
    UPDATE "order" o SET pay_status = x.expected
    FROM (
        SELECT a.order_id,
          CASE WHEN bool_or(p.status = 'успех') THEN 'оплачен'::order_pay_status
               WHEN count(p.payment_id) > 0 AND bool_and(p.status = 'ошибка') THEN 'ошибка'::order_pay_status
               ELSE 'ожидает'::order_pay_status END AS expected
        FROM unnest(v_ids) a(order_id) LEFT JOIN payment_core p USING (order_id)
        GROUP BY a.order_id
    ) x
    WHERE o.order_id = x.order_id AND o.pay_status IS DISTINCT FROM x.expected;
    RETURN NULL;
END $$;
COMMIT;
