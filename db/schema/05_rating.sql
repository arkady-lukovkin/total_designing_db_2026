BEGIN;
SET LOCAL search_path = lukovkin_food, pg_catalog;

CREATE FUNCTION rating_change() RETURNS trigger
LANGUAGE plpgsql SET search_path = lukovkin_food, pg_catalog AS $$
DECLARE v_id uuid; v_type review_entity_type;
BEGIN
    IF current_setting('lukovkin_food.generating', true) = 'on' THEN RETURN NULL; END IF;
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
            UPDATE product SET rating = (
                SELECT round(avg(r.rating), 2) FROM review r
                WHERE r.entity_type = v_type AND r.entity_id = v_id
            ) WHERE product_id = v_id;
        ELSE
            PERFORM 1 FROM restaurant WHERE restaurant_id = v_id FOR NO KEY UPDATE;
            UPDATE restaurant SET rating = (
                SELECT round(avg(r.rating), 2) FROM review r
                WHERE r.entity_type = v_type AND r.entity_id = v_id
            ) WHERE restaurant_id = v_id;
        END IF;
    END LOOP;
    RETURN NULL;
END $$;
CREATE TRIGGER review_rating_change AFTER INSERT OR UPDATE OR DELETE ON review
FOR EACH ROW EXECUTE FUNCTION rating_change();
COMMIT;
