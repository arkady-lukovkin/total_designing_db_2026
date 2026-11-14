BEGIN;
SET LOCAL search_path = lukovkin_food, pg_catalog;

CREATE OR REPLACE PROCEDURE erase_test_data()
LANGUAGE plpgsql SET search_path = lukovkin_food, pg_catalog AS $$
BEGIN
    TRUNCATE review, payment, order_structure, "order", courier_pay,
             product, product_category, restaurant, client_address, client, courier, address;
END $$;

CREATE OR REPLACE PROCEDURE insert_test_data(value integer)
LANGUAGE plpgsql SET search_path = lukovkin_food, pg_catalog AS $$
DECLARE
    v_alphabet constant text := 'абвгдеёжзийклмнопрстуфхцчшщъыьэюя';
    v_previous_mode text := current_setting('lukovkin_food.generating', true);
    v_clients uuid[] := '{}'; v_couriers uuid[] := '{}';
    v_categories uuid[] := '{}'; v_restaurants uuid[] := '{}';
    v_addresses uuid[] := '{}'; v_products uuid[] := '{}';
    v_orders uuid[] := '{}';
    v_payment_times timestamp[] := '{}'; v_payment_types payment_type[] := '{}';
    v_payment_statuses payment_status[] := '{}';
    v_position_orders uuid[] := '{}'; v_position_products uuid[] := '{}';
    v_position_quantities numeric[] := '{}'; v_position_prices numeric[] := '{}';
    v_review_times timestamp[] := '{}'; v_review_entities uuid[] := '{}';
    v_review_types review_entity_type[] := '{}'; v_review_descriptions text[] := '{}';
    v_review_photos text[] := '{}'; v_review_ratings numeric[] := '{}';
    v_prices numeric[] := '{}'; v_hires date[] := '{}'; v_dismissals date[] := '{}';
    v_id uuid; v_order uuid; v_first_product uuid; v_entity uuid;
    v_review_description text;
    v_hire date; v_dismissal date; v_courier_status courier_status;
    v_order_status order_status; v_review_type review_entity_type; v_payment_type payment_type;
    v_payment_status payment_status;
    v_client_index integer; v_restaurant_index integer; v_courier_index integer;
    v_product_index integer; v_count integer; v_swap integer; v_temp integer;
    v_indices integer[];
    v_selected integer[]; v_quantities numeric[]; v_quantity numeric; v_amount numeric;
    v_target_amount numeric;
    v_quantity_limit integer; v_work_start integer; v_work_end integer;
    v_now timestamp := localtimestamp;
    v_history_start timestamp := greatest(date_trunc('month', localtimestamp) - interval '5 months',
                                          localtimestamp - interval '180 days');
    v_start timestamp; v_finish timestamp; v_created timestamp; v_delivered timestamp;
BEGIN
    IF value IS NULL OR value < 1 OR value > 429496729 THEN
        RAISE EXCEPTION 'value должен быть положительным целым, 5 * value должно помещаться в integer'
            USING ERRCODE='22023';
    END IF;
    PERFORM set_config('lukovkin_food.generating', 'on', true);
    -- Работаем только с новым пакетом, не сортируем всю существующую БД по random().
    FOR i IN 1..value LOOP
        LOOP
            BEGIN
                INSERT INTO client (login, password, phone_number)
                VALUES ((SELECT string_agg(substr(v_alphabet, 1 + floor(random() * 33)::int, 1), '')
                        FROM generate_series(1, 1 + floor(random() * 80)::int)), md5(random()::text),
                        lpad(floor(random() * 100000000000)::bigint::text, 11, '0'))
                RETURNING client_id INTO v_id;
                EXIT;
            EXCEPTION WHEN unique_violation THEN NULL;
            END;
        END LOOP;
        v_clients := array_append(v_clients, v_id);
        INSERT INTO product_category (product_category_name) VALUES ((SELECT string_agg(substr(v_alphabet, 1 + floor(random() * 33)::int, 1), '')
                        FROM generate_series(1, 1 + floor(random() * 80)::int)))
        RETURNING product_category_id INTO v_id;
        v_categories := array_append(v_categories, v_id);
        v_courier_status := (enum_range(NULL::courier_status))[
            1 + floor(random() * CASE WHEN i = 1 THEN 3 ELSE 4 END)::integer];
        v_hire := current_date - floor(random() * 181)::integer;
        v_dismissal := CASE WHEN v_courier_status = 'уволен'
                            THEN greatest(v_hire, v_history_start::date)
                                 + floor(random() * (current_date - greatest(v_hire, v_history_start::date) + 1))::integer END;
        INSERT INTO courier (last_name, first_name, patronymic, phone_number, status, hire_date, dismissal_date)
        VALUES ((SELECT string_agg(substr(v_alphabet, 1 + floor(random() * 33)::int, 1), '')
                        FROM generate_series(1, 1 + floor(random() * 50)::int)),
                (SELECT string_agg(substr(v_alphabet, 1 + floor(random() * 33)::int, 1), '')
                        FROM generate_series(1, 1 + floor(random() * 50)::int)),
                CASE WHEN random() < 0.25 THEN NULL ELSE
                    (SELECT string_agg(substr(v_alphabet, 1 + floor(random() * 33)::int, 1), '')
                        FROM generate_series(1, 1 + floor(random() * 50)::int)) END,
                lpad(floor(random() * 100000000000)::bigint::text, 11, '0'),
                v_courier_status, v_hire, v_dismissal)
        RETURNING courier_id INTO v_id;
        v_couriers := array_append(v_couriers, v_id);
        v_hires := array_append(v_hires, v_hire);
        v_dismissals := array_append(v_dismissals, v_dismissal);
    END LOOP;

    FOR i IN 1..(5 * value) LOOP
        LOOP
            BEGIN
                INSERT INTO address (street, house_number, apartment_office)
                VALUES ((SELECT string_agg(substr(v_alphabet, 1 + floor(random() * 33)::int, 1), '')
                        FROM generate_series(1, 1 + floor(random() * 100)::int)), (SELECT string_agg(substr(v_alphabet, 1 + floor(random() * 33)::int, 1), '')
                        FROM generate_series(1, 1 + floor(random() * 12)::int)),
                        CASE WHEN random() < 0.25 THEN NULL ELSE (SELECT string_agg(substr(v_alphabet, 1 + floor(random() * 33)::int, 1), '')
                        FROM generate_series(1, 1 + floor(random() * 12)::int)) END)
                RETURNING address_id INTO v_id;
                EXIT;
            EXCEPTION WHEN unique_violation THEN NULL;
            END;
        END LOOP;
        IF i <= value THEN
            v_work_start := floor(random() * 86399)::integer;
            v_work_end := v_work_start + 1 + floor(random() * (86399 - v_work_start))::integer;
            INSERT INTO restaurant (restaurant_name, address_id, description,
                                    work_start, work_end, inn, ogrn, settlement_account, status)
            VALUES ((SELECT string_agg(substr(v_alphabet, 1 + floor(random() * 33)::int, 1), '')
                        FROM generate_series(1, 1 + floor(random() * 100)::int)), v_id, (SELECT string_agg(substr(v_alphabet, 1 + floor(random() * 33)::int, 1), '')
                        FROM generate_series(1, 1 + floor(random() * 240)::int)),
                    time '00:00' + v_work_start * interval '1 second',
                    time '00:00' + v_work_end * interval '1 second',
                    (SELECT string_agg(floor(random() * 10)::integer::text, '')
                        FROM generate_series(1, 10 + 2 * floor(random() * 2)::integer)),
                    (SELECT string_agg(floor(random() * 10)::integer::text, '')
                        FROM generate_series(1, 13 + 2 * floor(random() * 2)::integer)),
                    (SELECT string_agg(floor(random() * 10)::integer::text, '') FROM generate_series(1, 20)),
                    (enum_range(NULL::restaurant_status))[1 + floor(random() * 2)::integer])
            RETURNING restaurant_id INTO v_id;
            v_restaurants := array_append(v_restaurants, v_id);
        ELSE
            v_addresses := array_append(v_addresses, v_id);
        END IF;
    END LOOP;
    FOR i IN 1..value LOOP
        FOR j IN 1..4 LOOP
            INSERT INTO client_address VALUES (v_clients[i], v_addresses[(i - 1) * 4 + j]);
        END LOOP;
        -- Один из адресов также доступен соседнему клиенту: пример M:N.
        INSERT INTO client_address VALUES (v_clients[i], v_addresses[(i % value) * 4 + 1])
        ON CONFLICT DO NOTHING;
        FOR j IN 1..5 LOOP
            v_amount := 300 + floor(random() * 100001)::numeric / 100;
            INSERT INTO product (product_name, product_category_id, price, restaurant_id,
                                 photo_url, status, description)
            VALUES ((SELECT string_agg(substr(v_alphabet, 1 + floor(random() * 33)::int, 1), '')
                        FROM generate_series(1, 1 + floor(random() * 120)::int)), v_categories[1 + floor(random() * value)::integer],
                    v_amount, v_restaurants[i],
                    CASE WHEN random() < 0.25 THEN NULL
                         ELSE 'https://example.invalid/' || exts.uuid_generate_v4()::text || '.jpg' END,
                    (enum_range(NULL::product_status))[1 + floor(random() * 3)::integer], (SELECT string_agg(substr(v_alphabet, 1 + floor(random() * 33)::int, 1), '')
                        FROM generate_series(1, 1 + floor(random() * 240)::int)))
            RETURNING product_id INTO v_id;
            v_products := array_append(v_products, v_id);
            v_prices := array_append(v_prices, v_amount);
        END LOOP;
    END LOOP;

    FOR i IN 1..(5 * value) LOOP
        v_client_index := 1 + floor(random() * value)::integer;
        v_restaurant_index := 1 + floor(random() * value)::integer;
        v_courier_index := 1 + floor(random() * value)::integer;
        v_count := 1 + floor(random() * 5)::integer;
        -- Перемешиваем пять индексов, а не всю таблицу; любые подмножества доступны.
        v_indices := ARRAY[1, 2, 3, 4, 5];
        FOR j IN REVERSE 5..2 LOOP
            v_swap := 1 + floor(random() * j)::integer;
            v_temp := v_indices[j]; v_indices[j] := v_indices[v_swap]; v_indices[v_swap] := v_temp;
        END LOOP;
        v_selected := '{}';
        v_quantities := array_fill(0::numeric, ARRAY[v_count]);
        v_amount := 0;
        -- Оставляем запас на округление количества до 0.001.
        -- Итог с комиссией укладывается в 1000–5000 рублей.
        v_target_amount := 910 + floor(random() * 363301)::numeric / 100;
        FOR j IN 1..v_count LOOP
            v_selected[j] := (v_restaurant_index - 1) * 5 + v_indices[j];
        END LOOP;
        FOR j IN 2..v_count LOOP
            v_product_index := v_selected[j];
            v_quantity_limit := floor(v_target_amount / v_count / v_prices[v_product_index] * 1000)::integer;
            v_quantity := (1 + floor(random() * v_quantity_limit))::numeric / 1000;
            v_quantities[j] := v_quantity;
            v_amount := v_amount + v_prices[v_product_index] * v_quantity;
        END LOOP;
        v_product_index := v_selected[1];
        v_quantities[1] := ceil((v_target_amount - v_amount) / v_prices[v_product_index] * 1000) / 1000;
        v_amount := round(v_amount + v_prices[v_product_index] * v_quantities[1], 2);
        v_first_product := v_products[v_selected[1]];
        v_start := greatest(v_hires[v_courier_index]::timestamp,
                            v_history_start);
        -- Дата увольнения включается в период работы; за её пределами заказов нет.
        v_finish := least(v_now, coalesce(v_dismissals[v_courier_index]::timestamp + interval '1 day', v_now));
        v_created := v_start + random() * (v_finish - v_start);
        -- В каждом блоке из пяти заказов есть ожидание, ошибка и успешная оплата.
        v_order_status := (enum_range(NULL::order_status))[1 + (i - 1) % 5];
        v_payment_status := (enum_range(NULL::payment_status))[
            CASE v_order_status WHEN 'создан' THEN 3 WHEN 'отменён' THEN 2 ELSE 1 END];
        v_delivered := CASE WHEN v_order_status = 'доставлен' THEN v_created + random() * (v_finish - v_created) END;
        INSERT INTO "order" (courier_id, client_id, address_id, restaurant_id,
                             order_timestamp, delivery_timestamp, order_amount, status, description)
        VALUES (v_couriers[v_courier_index], v_clients[v_client_index],
                v_addresses[(v_client_index - 1) * 4 + 1 + floor(random() * 4)::integer],
                v_restaurants[v_restaurant_index], v_created, v_delivered,
                v_amount, v_order_status, CASE WHEN random() < 0.25 THEN NULL ELSE
                    (SELECT string_agg(substr(v_alphabet, 1 + floor(random() * 33)::int, 1), '')
                        FROM generate_series(1, 1 + floor(random() * 240)::int)) END)
        RETURNING order_id INTO v_order;
        FOR j IN 1..v_count LOOP
            v_position_orders := array_append(v_position_orders, v_order);
            v_position_products := array_append(v_position_products, v_products[v_selected[j]]);
            v_position_quantities := array_append(v_position_quantities, v_quantities[j]);
            v_position_prices := array_append(v_position_prices, v_prices[v_selected[j]]);
        END LOOP;
        v_payment_type := (enum_range(NULL::payment_type))[1 + floor(random() * 3)::integer];
        v_orders := array_append(v_orders, v_order);
        v_payment_times := array_append(v_payment_times, v_created + random() * (v_now - v_created));
        v_payment_types := array_append(v_payment_types, v_payment_type);
        v_payment_statuses := array_append(v_payment_statuses, v_payment_status);
        v_review_type := (enum_range(NULL::review_entity_type))[1 + floor(random() * 3)::integer];
        v_entity := CASE v_review_type WHEN 'блюдо' THEN v_first_product
                      WHEN 'ресторан' THEN v_restaurants[v_restaurant_index] ELSE v_order END;
        v_review_times := array_append(v_review_times, v_created + random() * (v_now - v_created));
        v_review_entities := array_append(v_review_entities, v_entity);
        v_review_types := array_append(v_review_types, v_review_type);
        -- Сначала скаляр: подзапрос внутри array_append копировал бы растущий массив.
        SELECT string_agg(substr(v_alphabet, 1 + floor(random() * 33)::int, 1), '')
        INTO v_review_description
        FROM generate_series(1, 1 + floor(random() * 240)::int);
        v_review_descriptions := array_append(v_review_descriptions, v_review_description);
        v_review_photos := array_append(v_review_photos,
            CASE WHEN random() < 0.25 THEN NULL
                 ELSE 'https://example.invalid/' || exts.uuid_generate_v4()::text || '.jpg' END);
        v_review_ratings := array_append(v_review_ratings, (100 + floor(random() * 401))::numeric / 100);
    END LOOP;

    -- Все заказы уже существуют: позиции вставляются одним пакетом, затем отзывы.
    -- Немедленные FK отзывов видят уже заполненный состав заказа.
    INSERT INTO order_structure (order_id, product_id, quantity, unit_price)
    SELECT u.order_id, u.product_id, u.quantity, u.unit_price
    FROM unnest(v_position_orders, v_position_products, v_position_quantities, v_position_prices)
         AS u(order_id, product_id, quantity, unit_price);

    INSERT INTO review (review_timestamp, entity_id, entity_type, order_id, description, photo_url, rating)
    SELECT u.review_timestamp, u.entity_id, u.entity_type, u.order_id, u.description, u.photo_url, u.rating
    FROM unnest(v_orders, v_review_times, v_review_entities, v_review_types,
                v_review_descriptions, v_review_photos, v_review_ratings)
         AS u(order_id, review_timestamp, entity_id, entity_type, description, photo_url, rating);

    -- По одной текущей попытке на заказ. Статус заказа синхронизируется после INSERT.
    INSERT INTO payment (order_id, type, amount, transaction_id, transaction_timestamp, status)
    SELECT u.order_id, u.type, o.total_amount,
           CASE WHEN u.type = 'наличные' THEN NULL ELSE exts.uuid_generate_v4() END,
           u.transaction_timestamp, u.status
    FROM unnest(v_orders, v_payment_types, v_payment_times, v_payment_statuses)
         AS u(order_id, type, transaction_timestamp, status)
    JOIN "order" o ON o.order_id = u.order_id;

    -- Шесть календарных месяцев: коэффициент месяца зависит от доставок прошлого.
    INSERT INTO courier_pay (year, month, courier_id, amount, coefficient_used)
    WITH months AS (
        SELECT (date_trunc('month', current_date) - i * interval '1 month')::date m
        FROM generate_series(0, 5) i
    ), actual AS (
        SELECT courier_id, date_trunc('month', order_timestamp)::date m,
               count(*) deliveries, sum(commission) commissions
        FROM "order" WHERE courier_id = ANY(v_couriers) AND status = 'доставлен'
        GROUP BY courier_id, date_trunc('month', order_timestamp)::date
    ), history AS (
        SELECT c.courier_id, m.m, coalesce(a.deliveries, 0) deliveries,
               coalesce(a.commissions, 0) commissions
        FROM unnest(v_couriers) c(courier_id) CROSS JOIN months m
        LEFT JOIN actual a ON a.courier_id = c.courier_id AND a.m = m.m
    ), coefficients AS (
        SELECT *, CASE WHEN previous_count > 500 THEN 0.5
                       WHEN previous_count > 250 THEN 0.3
                       WHEN previous_count > 150 THEN 0.2 ELSE 0.1 END used
        FROM (SELECT *, lag(deliveries, 1, 0::bigint)
              OVER (PARTITION BY courier_id ORDER BY m) previous_count FROM history) h
    )
    SELECT extract(year FROM h.m)::integer, extract(month FROM h.m)::integer,
           h.courier_id, round(h.commissions *
               CASE WHEN h.m > date_trunc('month', c.dismissal_date)::date THEN frozen.used ELSE h.used END, 2),
           CASE WHEN h.m > date_trunc('month', c.dismissal_date)::date THEN frozen.used ELSE h.used END
    FROM coefficients h
    JOIN courier c ON c.courier_id = h.courier_id
    LEFT JOIN coefficients frozen ON frozen.courier_id = h.courier_id
        AND frozen.m = date_trunc('month', c.dismissal_date)::date;

    UPDATE courier c SET coefficient = CASE WHEN x.deliveries > 500 THEN 0.5
        WHEN x.deliveries > 250 THEN 0.3 WHEN x.deliveries > 150 THEN 0.2 ELSE 0.1 END
    FROM (
        SELECT n.courier_id, count(o.order_id) deliveries
        FROM unnest(v_couriers) n(courier_id) LEFT JOIN "order" o ON o.courier_id = n.courier_id
            AND o.status = 'доставлен' AND o.order_timestamp >= date_trunc('month', current_date)
        GROUP BY n.courier_id
    ) x WHERE c.courier_id = x.courier_id AND c.status <> 'уволен';

    -- После увольнения ставка не меняется: сохраняем коэффициент месяца увольнения,
    -- в том числе в последующих нулевых строках шестимесячной истории.
    UPDATE courier c SET coefficient = cp.coefficient_used
    FROM courier_pay cp
    WHERE c.courier_id = ANY(v_couriers) AND c.status = 'уволен'
      AND cp.courier_id = c.courier_id
      AND cp.year = extract(year FROM c.dismissal_date)::integer
      AND cp.month = extract(month FROM c.dismissal_date)::integer;

    -- Генератор рассчитывает агрегаты самостоятельно, без вызова rating_change.
    UPDATE product p SET rating = x.rating
    FROM (SELECT entity_id, round(avg(rating), 2) rating FROM review
          WHERE entity_type = 'блюдо' AND entity_id = ANY(v_products)
          GROUP BY entity_id) x WHERE p.product_id = x.entity_id;
    UPDATE restaurant r SET rating = x.rating
    FROM (SELECT entity_id, round(avg(rating), 2) rating FROM review
          WHERE entity_type = 'ресторан' AND entity_id = ANY(v_restaurants)
          GROUP BY entity_id) x WHERE r.restaurant_id = x.entity_id;
    PERFORM set_config('lukovkin_food.generating', coalesce(v_previous_mode, 'off'), true);
END $$;
COMMIT;
