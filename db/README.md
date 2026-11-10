# FoodExpress

Луковкин Аркадий Сергеевич, РИМ-160980к. Решение находится в схеме `lukovkin_food`.

## Создание

Нужен PostgreSQL 15 или новее. Администратор заранее подготавливает отдельную базу со схемой `exts` и расширением `uuid-ossp`, как указано в BR-13.3. Скрипты решения используют это расширение.

Из корня репозитория выполнить:

```sh
psql -X -v ON_ERROR_STOP=1 -d foodexpress -f db/schema/00_types.sql
psql -X -v ON_ERROR_STOP=1 -d foodexpress -f db/schema/01_tables.sql
psql -X -v ON_ERROR_STOP=1 -d foodexpress -f db/schema/02_integrity.sql
psql -X -v ON_ERROR_STOP=1 -d foodexpress -f db/schema/03_test_data.sql
psql -X -v ON_ERROR_STOP=1 -d foodexpress -f db/schema/04_add_product.sql
psql -X -v ON_ERROR_STOP=1 -d foodexpress -f db/schema/05_rating.sql
psql -X -v ON_ERROR_STOP=1 -d foodexpress -f db/schema/06_statistics.sql
psql -X -v ON_ERROR_STOP=1 -d foodexpress -f db/schema/07_courier_salary.sql
psql -X -v ON_ERROR_STOP=1 -d foodexpress -f db/schema/08_money_report.sql
psql -X -v ON_ERROR_STOP=1 -d foodexpress -f db/schema/09_triggers.sql
psql -X -v ON_ERROR_STOP=1 -d foodexpress -f db/schema/grants.sql
```

`00_types.sql` создаёт схему и ENUM-типы, `01_tables.sql` — таблицы и представления совместимости, файлы `02`–`08` — функции, процедуры и денежный отчёт, `09_triggers.sql` — все триггеры. Установку нужно завершить до записи данных.

Первый скрипт создаёт новую схему. Повторный запуск поверх существующей схемы завершается ошибкой, сохраняя её данные.

## Тикеты и файлы

| Тикет | Реализация |
|---|---|
| FOOD-101 | `00_types.sql`, `01_tables.sql`, `02_integrity.sql`, `09_triggers.sql`, обоснования в `constraints.md` |
| FOOD-102 / FOOD-103 | `03_test_data.sql`: генерация нового пакета и очистка |
| FOOD-104 | `04_add_product.sql` |
| FOOD-105 | `05_rating.sql`, `09_triggers.sql` |
| FOOD-106 | `06_statistics.sql` |
| FOOD-107 | `07_courier_salary.sql` |
| FOOD-108 | `08_money_report.sql` |
| FOOD-109 | `grants.sql` |
| FOOD-110 | `foodexpress_lukovkin.backup`, восстановление и общий протокол `tests.md` |

FOOD-102/103 объединены: генерация и очистка работают с одним набором связанных таблиц.

## Восстановление

В новой подготовленной базе `foodexpress_restored` с `exts.uuid_generate_v4()`:

```sh
pg_restore --exit-on-error --no-owner --no-acl -d foodexpress_restored db/foodexpress_lukovkin.backup
psql -X -v ON_ERROR_STOP=1 -d foodexpress_restored -f db/schema/grants.sql
```

Пароль inspector указан в задании FOOD-109. После восстановления подключиться к базе под этой ролью.

После подключения inspector основные команды:

```sql
CALL insert_test_data(10);
SELECT * FROM get_statistic();
CALL courier_salary();
SELECT * FROM how_much_money;
CALL erase_test_data();
```

Заказ, его позиции и успешная оплата создаются одной транзакцией: отложенные ограничения проверяют готовый набор на COMMIT. Историческая цена каждой позиции передаётся в `unit_price`. Начальный рейтинг нового блюда в `add_product` — NULL.

Ядро хранит заказ в `order_core`, попытку оплаты — в `payment_core`. Совместимые представления `"order"` и `payment` сохраняют прежние поля; комиссия, итог и сумма оплаты вычисляются при чтении. Рейтинги проверяются на COMMIT, в том числе при прямом UPDATE. Подробности 3НФ и границы совместимости описаны в `constraints.md`.

Трактовки неоднозначных правил, технические диапазоны и нормализация описаны в `constraints.md`; фактические результаты запусков — в `tests.md`. Требования находятся в `docs/`.
