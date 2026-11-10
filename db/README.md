# FoodExpress

Луковкин Аркадий Сергеевич, РИМ-160980к. Решение находится в схеме `lukovkin_food`.

## Создание

Нужен PostgreSQL 15 или новее. Администратор заранее подготавливает отдельную базу со схемой `exts` и расширением `uuid-ossp`, как указано в BR-13.3. Скрипты решения используют это расширение.

Из корня репозитория выполнить:

```sh
psql -X -v ON_ERROR_STOP=1 -d foodexpress -f db/schema/01_tables.sql
psql -X -v ON_ERROR_STOP=1 -d foodexpress -f db/schema/02_integrity.sql
psql -X -v ON_ERROR_STOP=1 -d foodexpress -f db/schema/03_test_data.sql
psql -X -v ON_ERROR_STOP=1 -d foodexpress -f db/schema/04_add_product.sql
psql -X -v ON_ERROR_STOP=1 -d foodexpress -f db/schema/05_rating.sql
psql -X -v ON_ERROR_STOP=1 -d foodexpress -f db/schema/06_statistics.sql
psql -X -v ON_ERROR_STOP=1 -d foodexpress -f db/schema/07_courier_salary.sql
psql -X -v ON_ERROR_STOP=1 -d foodexpress -f db/schema/08_money_report.sql
psql -X -v ON_ERROR_STOP=1 -d foodexpress -f db/schema/grants.sql
```

Первый скрипт создаёт новую схему. Повторный запуск поверх существующей схемы завершается ошибкой, сохраняя её данные.

## Тикеты и файлы

| Тикет | Реализация |
|---|---|
| FOOD-101 | `01_tables.sql`, `02_integrity.sql`, обоснования в `constraints.md` |
| FOOD-102 / FOOD-103 | `03_test_data.sql`: генерация нового пакета и очистка |
| FOOD-104 | `04_add_product.sql` |
| FOOD-105 | `05_rating.sql` |
| FOOD-106 | `06_statistics.sql` |
| FOOD-107 | `07_courier_salary.sql` |
| FOOD-108 | `08_money_report.sql` |
| FOOD-109 | `grants.sql` |
| FOOD-110 | `foodexpress_lukovkin.backup`, восстановление и общий протокол `tests.md` |

История Git содержит отдельные коммиты по этим частям. FOOD-102/103 объединены, поскольку очистка нужна для повторяемой проверки генератора. Общие регрессионные сценарии входят в итоговый комплект проверки всех тикетов.

## Восстановление и проверка

В новой подготовленной базе `foodexpress_test` с `exts.uuid_generate_v4()`:

```sh
pg_restore --exit-on-error --no-owner --no-acl -d foodexpress_test db/foodexpress_lukovkin.backup
psql -X -v ON_ERROR_STOP=1 -d foodexpress_test -f db/schema/grants.sql
psql -X -h localhost -U inspector -d foodexpress_test -v foodexpress_test_database=foodexpress_test -f db/checks.sql
psql -X -h localhost -U inspector -d foodexpress_test -v foodexpress_test_database=foodexpress_test -f db/boundary_checks.sql
```

Пароль inspector указан в задании FOOD-109. Проверки удаляют учебные данные в `lukovkin_food` и требуют явно указать имя выделенной тестовой БД. `boundary_checks.sql` включает `regression_checks.sql`; отдельно повторять его для полного прогона не нужно.

После подключения inspector основные команды:

```sql
CALL insert_test_data(10);
SELECT * FROM get_statistic();
CALL courier_salary();
SELECT * FROM how_much_money;
CALL erase_test_data();
```

Заказ, его позиции и успешная оплата создаются одной транзакцией: отложенные ограничения проверяют готовый набор на COMMIT. Историческая цена каждой позиции передаётся в `unit_price`. Начальный рейтинг нового блюда в `add_product` — NULL.

Трактовки неоднозначных правил, технические диапазоны и нормализация описаны в `constraints.md`; фактические результаты запусков — в `tests.md`. Исходные требования хранятся в `docs/`; исправление проверки прав G.1 в `templates/tests.md` синхронизировано с upstream `94fad92` от 7 ноября 2026.
