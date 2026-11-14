BEGIN;
SET LOCAL search_path = lukovkin_food, pg_catalog;

CREATE OR REPLACE PROCEDURE add_product(
    p_restaurant_id uuid, p_product_category_id uuid, p_name varchar,
    p_price numeric, p_rating numeric, p_status product_status,
    p_description text, p_photo_url text DEFAULT NULL)
LANGUAGE plpgsql SET search_path = lukovkin_food, pg_catalog AS $$
BEGIN
    INSERT INTO product (restaurant_id, product_category_id, product_name, price,
                         rating, status, description, photo_url)
    VALUES (p_restaurant_id, p_product_category_id, p_name, p_price,
            p_rating, p_status, p_description, p_photo_url);
END $$;
COMMIT;
