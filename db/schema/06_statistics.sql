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
    ), top_product_candidates AS (
        SELECT s.restaurant_id, array_agg(s.product_id) AS candidates
        FROM product_sales s
        JOIN (
            SELECT restaurant_id, max(quantity) AS quantity
            FROM product_sales GROUP BY restaurant_id
        ) leaders USING (restaurant_id, quantity)
        GROUP BY s.restaurant_id
    ), user_sales AS (
        SELECT restaurant_id, client_id, count(*) purchases
        FROM delivered GROUP BY restaurant_id, client_id
    ), best_products AS MATERIALIZED (
        SELECT restaurant_id, candidates[
            CASE WHEN cardinality(candidates) > 1
                 THEN 1 + floor(random() * cardinality(candidates))::integer ELSE 1 END] AS product_id
        FROM top_product_candidates
    ), top_user_candidates AS (
        SELECT s.restaurant_id, array_agg(s.client_id) AS candidates
        FROM user_sales s
        JOIN (
            SELECT restaurant_id, max(purchases) AS purchases
            FROM user_sales GROUP BY restaurant_id
        ) leaders USING (restaurant_id, purchases)
        GROUP BY s.restaurant_id
    ), best_users AS MATERIALIZED (
        SELECT restaurant_id, candidates[
            CASE WHEN cardinality(candidates) > 1
                 THEN 1 + floor(random() * cardinality(candidates))::integer ELSE 1 END] AS client_id
        FROM top_user_candidates
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
