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
CREATE TRIGGER position_restaurant BEFORE INSERT OR UPDATE ON order_structure
FOR EACH ROW EXECUTE FUNCTION check_position_restaurant();

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
CREATE TRIGGER product_restaurant_change BEFORE UPDATE OF restaurant_id ON product
FOR EACH ROW WHEN (OLD.restaurant_id IS DISTINCT FROM NEW.restaurant_id)
EXECUTE FUNCTION guard_restaurant_change();
CREATE TRIGGER order_restaurant_change BEFORE UPDATE OF restaurant_id ON "order"
FOR EACH ROW WHEN (OLD.restaurant_id IS DISTINCT FROM NEW.restaurant_id)
EXECUTE FUNCTION guard_restaurant_change();

-- Заказ, позиции и успешная оплата образуют одну транзакцию.
-- Общая функция трёх constraint triggers проверяет итог на COMMIT.
CREATE FUNCTION order_integrity() RETURNS trigger
LANGUAGE plpgsql SET search_path = lukovkin_food, pg_catalog AS $$
DECLARE
    v_ids uuid[] := '{}';
    v_id uuid;
    v_subtotal numeric;
    v_total numeric;
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
        SELECT order_amount, total_amount, pay_status
        INTO v_subtotal, v_total, v_pay
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
        FROM payment
        WHERE order_id = v_id;
        IF v_success <> 1 THEN
            RAISE EXCEPTION 'BR-8.1: заказ % должен иметь ровно одну успешную оплату на COMMIT', v_id
                USING ERRCODE = '23514';
        END IF;
        IF EXISTS (
            SELECT 1 FROM payment
            WHERE order_id = v_id AND amount <> v_total
        ) THEN
            RAISE EXCEPTION 'BR-8.4: сумма каждой попытки оплаты заказа % должна равняться %', v_id, v_total
                USING ERRCODE = '23514';
        END IF;
        IF v_pay <> 'оплачен' THEN
            RAISE EXCEPTION 'BR-8.7: статус оплаты заказа % не соответствует попыткам', v_id
                USING ERRCODE = '23514';
        END IF;
    END LOOP;
    RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER complete_order AFTER INSERT OR UPDATE ON "order"
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION order_integrity();
CREATE CONSTRAINT TRIGGER complete_positions AFTER INSERT OR UPDATE OR DELETE ON order_structure
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION order_integrity();
CREATE CONSTRAINT TRIGGER complete_payments AFTER INSERT OR UPDATE OR DELETE ON payment
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION order_integrity();

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
        FROM unnest(v_ids) a(order_id) LEFT JOIN payment p USING (order_id)
        GROUP BY a.order_id
    ) x
    WHERE o.order_id = x.order_id AND o.pay_status IS DISTINCT FROM x.expected;
    RETURN NULL;
END $$;
CREATE TRIGGER payment_insert_status AFTER INSERT ON payment
REFERENCING NEW TABLE AS new_payments FOR EACH STATEMENT EXECUTE FUNCTION sync_payment_status();
CREATE TRIGGER payment_update_status AFTER UPDATE ON payment
REFERENCING OLD TABLE AS old_payments NEW TABLE AS new_payments
FOR EACH STATEMENT EXECUTE FUNCTION sync_payment_status();
CREATE TRIGGER payment_delete_status AFTER DELETE ON payment
REFERENCING OLD TABLE AS old_payments FOR EACH STATEMENT EXECUTE FUNCTION sync_payment_status();
COMMIT;
