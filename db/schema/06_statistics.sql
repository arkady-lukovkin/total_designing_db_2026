BEGIN;
SET LOCAL search_path = lukovkin_food, pg_catalog;

CREATE FUNCTION get_statistic()
RETURNS TABLE (restaurant_name text, best_product_name text, total_amount numeric,
               avg_amount numeric, best_user text)
LANGUAGE sql VOLATILE SET search_path = lukovkin_food, pg_catalog AS $$
    WITH delivered AS MATERIALIZED (
        SELECT order_id, restaurant_id, client_id, total_amount
        FROM "order" WHERE status = 'доставлен'
    ), totals AS (
        SELECT restaurant_id, sum(total_amount) total, avg(total_amount) average
        FROM delivered GROUP BY restaurant_id
    ), product_sales AS (
        SELECT d.restaurant_id, os.product_id, sum(os.quantity) quantity
        FROM delivered d JOIN order_structure os USING (order_id)
        GROUP BY d.restaurant_id, os.product_id
    ), best_products AS (
        SELECT DISTINCT ON (restaurant_id) restaurant_id, product_id
        FROM product_sales ORDER BY restaurant_id, quantity DESC, random()
    ), user_sales AS (
        SELECT restaurant_id, client_id, count(*) purchases
        FROM delivered GROUP BY restaurant_id, client_id
    ), best_users AS (
        SELECT DISTINCT ON (restaurant_id) restaurant_id, client_id
        FROM user_sales ORDER BY restaurant_id, purchases DESC, random()
    )
    SELECT r.restaurant_name::text, p.product_name::text,
           coalesce(t.total, 0), coalesce(t.average, 0), c.login::text
    FROM restaurant r LEFT JOIN totals t ON t.restaurant_id = r.restaurant_id
    LEFT JOIN best_products bp ON bp.restaurant_id = r.restaurant_id
    LEFT JOIN product p ON p.product_id = bp.product_id
    LEFT JOIN best_users bu ON bu.restaurant_id = r.restaurant_id
    LEFT JOIN client c ON c.client_id = bu.client_id
$$;
COMMIT;
