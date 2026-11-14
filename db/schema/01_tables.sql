-- PostgreSQL 15+. Схема exts уже должна быть подготовлена администратором.
BEGIN;
SET LOCAL search_path = lukovkin_food, pg_catalog;

CREATE TABLE client (
    client_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    login varchar(80) NOT NULL CONSTRAINT client_login_unique UNIQUE,
    password char(32) NOT NULL,
    phone_number char(11) NOT NULL CONSTRAINT client_phone_unique UNIQUE,

    CONSTRAINT client_login_not_empty CHECK (length(btrim(login)) > 0),
    CONSTRAINT client_password_md5 CHECK (password ~ '^[0-9a-f]{32}$'),
    CONSTRAINT client_phone_digits CHECK (phone_number ~ '^[0-9]{11}$')
);

CREATE TABLE address (
    address_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    street varchar(100) NOT NULL,
    house_number varchar(12) NOT NULL,
    apartment_office varchar(12),

    CONSTRAINT address_not_empty CHECK (
        length(btrim(street)) > 0
        AND length(btrim(house_number)) > 0
        AND (apartment_office IS NULL OR length(btrim(apartment_office)) > 0)
    ),
    CONSTRAINT address_physical_unique UNIQUE NULLS NOT DISTINCT
        (street, house_number, apartment_office)
);

CREATE TABLE client_address (
    client_id uuid NOT NULL REFERENCES client ON DELETE CASCADE,
    address_id uuid NOT NULL REFERENCES address,

    PRIMARY KEY (client_id, address_id)
);

CREATE TABLE restaurant (
    restaurant_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    restaurant_name varchar(100) NOT NULL,
    address_id uuid NOT NULL UNIQUE REFERENCES address,
    description text NOT NULL,
    work_start time NOT NULL,
    work_end time NOT NULL,
    inn varchar(12) NOT NULL,
    ogrn varchar(15) NOT NULL,
    settlement_account char(20) NOT NULL,
    rating numeric(3, 2),
    status restaurant_status NOT NULL DEFAULT 'активен',

    CONSTRAINT restaurant_name_not_empty CHECK (length(btrim(restaurant_name)) > 0),
    CONSTRAINT restaurant_description_not_empty CHECK (length(btrim(description)) > 0),
    CONSTRAINT restaurant_inn_format CHECK (inn ~ '^([0-9]{10}|[0-9]{12})$'),
    CONSTRAINT restaurant_ogrn_format CHECK (ogrn ~ '^([0-9]{13}|[0-9]{15})$'),
    CONSTRAINT restaurant_account_format CHECK (settlement_account ~ '^[0-9]{20}$'),
    CONSTRAINT restaurant_work_hours CHECK (work_end > work_start),
    CONSTRAINT restaurant_rating_range CHECK (rating BETWEEN 0 AND 5)
);

CREATE TABLE courier (
    courier_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    last_name varchar(50) NOT NULL,
    first_name varchar(50) NOT NULL,
    patronymic varchar(50),
    phone_number char(11) NOT NULL,
    status courier_status NOT NULL DEFAULT 'свободен',
    hire_date date NOT NULL DEFAULT current_date,
    dismissal_date date,
    coefficient numeric(2, 1) NOT NULL DEFAULT 0.1,

    CONSTRAINT courier_name_not_empty CHECK (
        length(btrim(last_name)) > 0
        AND length(btrim(first_name)) > 0
        AND (patronymic IS NULL OR length(btrim(patronymic)) > 0)
    ),
    CONSTRAINT courier_phone_digits CHECK (phone_number ~ '^[0-9]{11}$'),
    CONSTRAINT courier_dismissal_required CHECK (
        status <> 'уволен'
        OR dismissal_date IS NOT NULL
    ),
    CONSTRAINT courier_dates_order CHECK (
        dismissal_date IS NULL
        OR dismissal_date >= hire_date
    ),
    CONSTRAINT courier_coefficient_range CHECK (coefficient BETWEEN 0.1 AND 0.5)
);

CREATE TABLE courier_pay (
    year integer NOT NULL,
    month integer NOT NULL,
    courier_id uuid NOT NULL REFERENCES courier,
    amount numeric(9, 2) NOT NULL,
    coefficient_used numeric(2, 1) NOT NULL,

    PRIMARY KEY (year, month, courier_id),
    CONSTRAINT courier_pay_calendar CHECK (
        year BETWEEN 1 AND 9999
        AND month BETWEEN 1 AND 12
    ),
    CONSTRAINT courier_pay_nonnegative CHECK (
        amount >= 0
        AND amount <> 'NaN'::numeric
    ),
    CONSTRAINT courier_pay_coefficient_range CHECK (coefficient_used BETWEEN 0.1 AND 0.5)
);

CREATE TABLE product_category (
    product_category_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    product_category_name varchar(80) NOT NULL,

    CONSTRAINT category_name_not_empty CHECK (length(btrim(product_category_name)) > 0)
);

CREATE TABLE product (
    product_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    product_name varchar(120) NOT NULL,
    product_category_id uuid NOT NULL REFERENCES product_category,
    price numeric(7, 2) NOT NULL,
    restaurant_id uuid NOT NULL REFERENCES restaurant,
    photo_url text,
    rating numeric(3, 2),
    status product_status NOT NULL DEFAULT 'доступно',
    description text NOT NULL,

    CONSTRAINT product_name_not_empty CHECK (length(btrim(product_name)) > 0),
    CONSTRAINT product_description_not_empty CHECK (length(btrim(description)) > 0),
    CONSTRAINT product_photo_not_empty CHECK (
        photo_url IS NULL
        OR length(btrim(photo_url)) > 0
    ),
    CONSTRAINT product_price_nonnegative CHECK (
        price >= 0
        AND price <> 'NaN'::numeric
    ),
    CONSTRAINT product_rating_range CHECK (rating BETWEEN 0 AND 5)
);

CREATE TABLE "order" (
    order_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    courier_id uuid NOT NULL REFERENCES courier,
    client_id uuid NOT NULL REFERENCES client,
    address_id uuid NOT NULL REFERENCES address,
    restaurant_id uuid NOT NULL REFERENCES restaurant,
    order_timestamp timestamp NOT NULL DEFAULT localtimestamp,
    delivery_timestamp timestamp,
    order_amount numeric(8, 2) NOT NULL,
    commission numeric(8, 2) GENERATED ALWAYS AS (round(order_amount * 0.10, 2)) STORED NOT NULL,
    total_amount numeric(9, 2) GENERATED ALWAYS AS (
        order_amount + round(order_amount * 0.10, 2)
    ) STORED NOT NULL,
    status order_status NOT NULL DEFAULT 'создан',
    pay_status order_pay_status NOT NULL DEFAULT 'ожидает',
    description text,

    CONSTRAINT order_client_address_fk
        FOREIGN KEY (client_id, address_id)
        REFERENCES client_address (client_id, address_id),
    CONSTRAINT order_restaurant_unique UNIQUE (order_id, restaurant_id),
    CONSTRAINT order_total_unique UNIQUE (order_id, total_amount),
    CONSTRAINT order_amount_nonnegative CHECK (
        order_amount >= 0
        AND order_amount <> 'NaN'::numeric
    ),
    CONSTRAINT order_min_total CHECK (total_amount >= 1000),
    CONSTRAINT order_delivered_time CHECK (
        status <> 'доставлен'
        OR delivery_timestamp IS NOT NULL
    ),
    CONSTRAINT order_time_sequence CHECK (
        delivery_timestamp IS NULL
        OR delivery_timestamp >= order_timestamp
    )
);

CREATE TABLE order_structure (
    order_id uuid NOT NULL REFERENCES "order" ON DELETE CASCADE,
    product_id uuid NOT NULL REFERENCES product,
    quantity numeric(6, 3) NOT NULL,
    unit_price numeric(7, 2) NOT NULL,

    PRIMARY KEY (order_id, product_id),
    CONSTRAINT order_quantity_positive CHECK (
        quantity > 0
        AND quantity <> 'NaN'::numeric
    ),
    CONSTRAINT order_unit_price_nonnegative CHECK (
        unit_price >= 0
        AND unit_price <> 'NaN'::numeric
    )
);

CREATE TABLE payment (
    payment_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    order_id uuid NOT NULL,
    type payment_type NOT NULL,
    amount numeric(9, 2) NOT NULL,
    transaction_id uuid UNIQUE,
    transaction_timestamp timestamp NOT NULL DEFAULT localtimestamp,
    status payment_status NOT NULL,

    CONSTRAINT payment_order_total_fk FOREIGN KEY (order_id, amount)
        REFERENCES "order" (order_id, total_amount)
        ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
    CONSTRAINT payment_transaction_required CHECK (
        (type = 'наличные' AND transaction_id IS NULL)
        OR (type <> 'наличные' AND transaction_id IS NOT NULL)
    )
);

CREATE UNIQUE INDEX payment_one_success
    ON payment (order_id)
    WHERE status = 'успех';

CREATE TABLE review (
    review_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    review_timestamp timestamp NOT NULL DEFAULT localtimestamp,
    entity_id uuid NOT NULL,
    entity_type review_entity_type NOT NULL,
    order_id uuid NOT NULL REFERENCES "order" ON DELETE CASCADE,
    description text NOT NULL,
    photo_url text,
    rating numeric(3, 2) NOT NULL,
    -- Проекции полиморфной ссылки позволяют проверить её обычными FK.
    product_id uuid GENERATED ALWAYS AS (
        CASE WHEN entity_type = 'блюдо' THEN entity_id END
    ) STORED,
    restaurant_id uuid GENERATED ALWAYS AS (
        CASE WHEN entity_type = 'ресторан' THEN entity_id END
    ) STORED,

    CONSTRAINT review_unique_entity UNIQUE (order_id, entity_type, entity_id),
    CONSTRAINT review_target_unique UNIQUE NULLS NOT DISTINCT
        (order_id, product_id, restaurant_id),
    CONSTRAINT review_rating_range CHECK (rating BETWEEN 1 AND 5),
    CONSTRAINT review_description_not_empty CHECK (length(btrim(description)) > 0),
    CONSTRAINT review_photo_not_empty CHECK (
        photo_url IS NULL
        OR length(btrim(photo_url)) > 0
    ),
    CONSTRAINT review_order_entity CHECK (
        entity_type <> 'заказ'
        OR entity_id = order_id
    ),
    CONSTRAINT review_bought_product_fk
        FOREIGN KEY (order_id, product_id)
        REFERENCES order_structure (order_id, product_id),
    CONSTRAINT review_restaurant_fk
        FOREIGN KEY (order_id, restaurant_id)
        REFERENCES "order" (order_id, restaurant_id)
);

CREATE INDEX product_restaurant_idx ON product (restaurant_id);

CREATE INDEX order_courier_date_idx
    ON "order" (courier_id, order_timestamp)
    WHERE status = 'доставлен';

CREATE INDEX order_restaurant_idx ON "order" (restaurant_id);

CREATE INDEX order_client_address_idx ON "order" (client_id, address_id);

CREATE INDEX payment_order_idx ON payment (order_id);

CREATE INDEX order_structure_product_idx ON order_structure (product_id);

CREATE INDEX review_entity_idx ON review (entity_type, entity_id);

COMMIT;
