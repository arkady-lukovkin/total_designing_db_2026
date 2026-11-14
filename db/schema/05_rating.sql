BEGIN;
SET LOCAL search_path = lukovkin_food, pg_catalog;

CREATE FUNCTION rating_change() RETURNS trigger
LANGUAGE plpgsql SET search_path = lukovkin_food, pg_catalog AS $$
DECLARE
    v_id uuid;
    v_type review_entity_type;
    v_generating boolean := coalesce(current_setting('lukovkin_food.generating', true) = 'on', false);
BEGIN
    -- При переносе отзыва обновляются и старая, и новая сущности.
    FOR v_type, v_id IN
        SELECT DISTINCT t, id FROM (
            SELECT OLD.entity_type t, OLD.entity_id id WHERE TG_OP <> 'INSERT'
            UNION ALL
            SELECT NEW.entity_type, NEW.entity_id WHERE TG_OP <> 'DELETE'
        ) affected WHERE t <> 'заказ'
        ORDER BY t, id
    LOOP
        IF v_type = 'блюдо' THEN
            PERFORM 1 FROM product WHERE product_id = v_id FOR NO KEY UPDATE;
            IF v_generating THEN
                -- Даже при прежнем среднем меняем версию строки: старый снимок
                -- REPEATABLE READ должен заметить конкурентную запись отзывов.
                UPDATE product SET rating = rating WHERE product_id = v_id;
            ELSE
                UPDATE product SET rating = (
                    SELECT round(avg(r.rating), 2) FROM review r
                    WHERE r.entity_type = v_type AND r.entity_id = v_id
                ) WHERE product_id = v_id;
            END IF;
        ELSE
            PERFORM 1 FROM restaurant WHERE restaurant_id = v_id FOR NO KEY UPDATE;
            IF v_generating THEN
                UPDATE restaurant SET rating = rating WHERE restaurant_id = v_id;
            ELSE
                UPDATE restaurant SET rating = (
                    SELECT round(avg(r.rating), 2) FROM review r
                    WHERE r.entity_type = v_type AND r.entity_id = v_id
                ) WHERE restaurant_id = v_id;
            END IF;
        END IF;
    END LOOP;
    RETURN NULL;
END $$;

-- Проверяется фактическое состояние на COMMIT, а не NEW из раннего события.
-- Флаг генератора не отключает эту проверку.
CREATE FUNCTION check_rating_integrity() RETURNS trigger
LANGUAGE plpgsql SET search_path = lukovkin_food, pg_catalog AS $$
DECLARE
    v_types review_entity_type[] := '{}';
    v_ids uuid[] := '{}';
    v_type review_entity_type;
    v_id uuid;
    v_actual numeric;
    v_expected numeric;
BEGIN
    IF TG_TABLE_NAME = 'review' THEN
        IF TG_OP <> 'INSERT' THEN
            v_types := array_append(v_types, OLD.entity_type);
            v_ids := array_append(v_ids, OLD.entity_id);
        END IF;
        IF TG_OP <> 'DELETE' THEN
            v_types := array_append(v_types, NEW.entity_type);
            v_ids := array_append(v_ids, NEW.entity_id);
        END IF;
    ELSIF TG_TABLE_NAME = 'product' THEN
        v_types := ARRAY['блюдо'::review_entity_type];
        v_ids := ARRAY[NEW.product_id];
    ELSE
        v_types := ARRAY['ресторан'::review_entity_type];
        v_ids := ARRAY[NEW.restaurant_id];
    END IF;

    FOR v_type, v_id IN
        SELECT DISTINCT t, id FROM unnest(v_types, v_ids) a(t, id)
        WHERE t <> 'заказ' ORDER BY t, id
    LOOP
        IF v_type = 'блюдо' THEN
            SELECT rating INTO v_actual FROM product WHERE product_id = v_id FOR NO KEY UPDATE;
        ELSE
            SELECT rating INTO v_actual FROM restaurant WHERE restaurant_id = v_id FOR NO KEY UPDATE;
        END IF;
        IF NOT FOUND THEN CONTINUE; END IF;
        SELECT round(avg(rating), 2) INTO v_expected FROM review
        WHERE entity_type = v_type AND entity_id = v_id;
        -- Стартовая оценка блюда допустима только при его создании.
        -- После изменения отзывов действует результат AVG, в том числе NULL.
        IF TG_TABLE_NAME = 'product' AND TG_OP = 'INSERT' AND v_expected IS NULL THEN
            CONTINUE;
        END IF;
        IF v_actual IS DISTINCT FROM v_expected THEN
            RAISE EXCEPTION 'BR-9.6/9.7: рейтинг % % равен %, ожидается %',
                v_type, v_id, v_actual, v_expected USING ERRCODE = '23514';
        END IF;
    END LOOP;
    RETURN NULL;
END $$;

-- До TRUNCATE ещё доступны цели удаляемых отзывов.
CREATE FUNCTION clear_ratings() RETURNS trigger
LANGUAGE plpgsql SET search_path = lukovkin_food, pg_catalog AS $$
BEGIN
    UPDATE product p SET rating = NULL
    WHERE p.rating IS NOT NULL AND EXISTS (
        SELECT 1 FROM review r WHERE r.entity_type = 'блюдо' AND r.entity_id = p.product_id
    );
    UPDATE restaurant r SET rating = NULL
    WHERE r.rating IS NOT NULL AND EXISTS (
        SELECT 1 FROM review rv WHERE rv.entity_type = 'ресторан' AND rv.entity_id = r.restaurant_id
    );
    RETURN NULL;
END $$;
COMMIT;
