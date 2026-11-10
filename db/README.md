# FoodExpress

Луковкин Аркадий Сергеевич, РИМ-160980к. Решение находится в схеме `lukovkin_food`.

## Установка

Нужен PostgreSQL 15 или новее. До установки администратор создаёт отдельную базу, схему `exts` и расширение `uuid-ossp` в соответствии с BR-13.3.

Из корня репозитория выполнить команды по порядку:

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

`00_types.sql` создаёт схему и ENUM-типы. Таблицы и представления совместимости описаны в `01_tables.sql`, функции, процедуры и денежный отчёт находятся в файлах с `02` по `08`. Последним создаётся набор триггеров из `09_triggers.sql`. Записывать данные можно после завершения установки.

Скрипты рассчитаны на новую схему. При повторном запуске первый файл завершится ошибкой, существующие данные сохранятся.

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

Генерация и очистка из FOOD-102/103 работают с одним набором таблиц, поэтому находятся в общем файле.

## Восстановление

В новой базе `foodexpress_restored` заранее должна быть доступна функция `exts.uuid_generate_v4()`.

```sh
pg_restore --exit-on-error --no-owner --no-acl -d foodexpress_restored db/foodexpress_lukovkin.backup
psql -X -v ON_ERROR_STOP=1 -d foodexpress_restored -f db/schema/grants.sql
```

После восстановления подключиться под inspector. Пароль указан в FOOD-109. Основные операции:

```sql
CALL insert_test_data(10);
SELECT * FROM get_statistic();
CALL courier_salary();
SELECT * FROM how_much_money;
CALL erase_test_data();
```

Заказ, позиции и успешная оплата создаются в одной транзакции. При COMMIT проверяется их согласованность. В `unit_price` передаётся цена позиции на момент заказа, а начальный рейтинг в `add_product` должен быть NULL.

Заказы хранятся в `order_core`, попытки оплаты хранятся в `payment_core`. Представления `"order"` и `payment` предоставляют поля из задания: комиссию, итог заказа и сумму оплаты они вычисляют при чтении. Рейтинги проверяются на COMMIT, в том числе после прямого UPDATE.

Обоснование 3НФ, ограничения интерфейсов, диапазоны типов и трактовки неоднозначных правил приведены в `constraints.md`. Результаты запусков записаны в `tests.md`, исходные требования находятся в `docs/`.
