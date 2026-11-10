-- PostgreSQL 15+. Схема exts заранее подготовлена администратором.
BEGIN;
CREATE SCHEMA lukovkin_food;
SET LOCAL search_path = lukovkin_food, pg_catalog;

CREATE TYPE restaurant_status AS ENUM (
    'активен',
    'неактивен'
);

CREATE TYPE product_status AS ENUM (
    'доступно',
    'нет_в_наличии',
    'архив'
);

CREATE TYPE courier_status AS ENUM (
    'свободен',
    'занят',
    'на_доставке',
    'уволен'
);

CREATE TYPE order_status AS ENUM (
    'создан',
    'готовится',
    'в_доставке',
    'доставлен',
    'отменён'
);

CREATE TYPE order_pay_status AS ENUM (
    'ожидает',
    'оплачен',
    'ошибка'
);

CREATE TYPE payment_status AS ENUM (
    'успех',
    'ошибка',
    'в_обработке'
);

CREATE TYPE payment_type AS ENUM (
    'карта',
    'наличные',
    'безнал'
);

CREATE TYPE review_entity_type AS ENUM (
    'блюдо',
    'ресторан',
    'заказ'
);

COMMIT;
