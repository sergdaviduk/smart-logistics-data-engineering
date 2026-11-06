# Smart Logistics — Data Engineering & ML Take-Home

Инженерный прототип для тестового задания **«Умная Логистика» / Middle Data Engineer**. Покрывает обязательные вопросы 1–3: Core ETL, Data Quality, SQL mart, time-based CatBoost, batch predictions. Источник — оригинальные `sql/schema.sql` и `sql/synthetic.sql`, дата снимка **2026-10-26**.

> **Проверено 2026-11-06 на macOS с Docker Desktop (по логам запуска):** `docker compose up --build` завершился с кодом 0; исходных записей 300 000, принято 299 797, отклонено 203; SQL mart содержит 203 644 ячейки. Повторный запуск `docker compose run --rm pipeline` завершился успешно с теми же счётчиками ETL. `docker compose run --rm pipeline pytest -q`: 5 passed. Проверка БД: `COUNT(*) = COUNT(DISTINCT price_id) = 299797` для `core.deals` (PK на `price_id`). ML test по повторному запуску: R²=0.920923, MAPE=15.5636%, RMSE=53916.23 RUB, MAE=27989.96 RUB; train=27033, test=14305, future=6484. Результаты получены на **синтетических** данных; это не гарантия качества на реальном потоке. Все числа подтверждены скриншотами пользовательского запуска; CI пока не настроен.

## Быстрый старт

```bash
cp .env.example .env     # при необходимости поменять пароль и порт
# Требуется установленный Docker Engine + Compose plugin
docker compose up --build
# либо: docker-compose up --build
```

После первого запуска контейнер PostgreSQL 17 инициализируется оригинальным DDL и **300 000** сделок, Python выполнит загрузку и пересчёт витрин, обучит CatBoost, сохранит модель в volume `modeldata`, запишет метрики и скоринг. Последующие `docker compose up` с уже созданным volume не переинициализируют источник, но заново идемпотентно пересчитают ETL, витрины и модель.

Допустима первая загрузка меньшего набора для smoke-отладки: `N_PRICES=10000 docker compose up --build` на **новом** Docker volume. Для финальной проверки требуется значение 300000 (менять размер после инициализации существующего volume бесполезно).

## Архитектура

```text
public.prices/cities/exchange_rates/price_body_types/price_dates
              |
              v
    etl.run -- date range
      |                |
      v                v
core.deals       core.dq_quarantine_prices
      |
      +-- core.deal_body_groups  (unique price_id x normalized body_group)
      |
      +-- mart.market_corridor   (SQL p25/p50/p75, trust, MoM, YoY)
      |
      +-- ml.features -> CatBoostRegressor (chronological split)
                                  |
                                  +-- mart.ml_model_metrics
                                  +-- mart.ml_price_predictions
```

- `core.dim_cities`: `DISTINCT ON (gc_id) ORDER BY gc_id, id`, исключает размножение сделок.
- `core.deal_body_groups`: 1 строка для каждого **уникального** стандартизированного кузова сделки; сделки со смешанными кузовами попадают в несколько бизнес-групп осознанно; внутри группы не дублируются.
- `core.deals`: единичное зерно `price_id`, очищенная цена в RUB и нормализованные категории.
- `mart.market_corridor`: зерно `month × origin_gcid × destination_gcid × body_group × weight_category`; месяцы берутся из `price_dates.price_date`, только месяцы до `as_of` включительно.
- Сборка небольшого project-owned SQL split runner вместо внешнего оркестратора. Airflow, ClickHouse, Superset не входят в обязательную часть и намеренно не добавлены.

## DQ и курс валют

Отбраковываются `price<=0`, RUB `price<=1000`, невалидные `distance<=0`, отрицательные вес/объём, отсутствующие города, неизвестная валюта или отсутствие курса. Причины сохраняются в `core.dq_quarantine_prices` (массив кодов). Для USD/EUR требуется **точный** `exchange_rates(num_code, setting_date=nearest_rate_date)`, `loading_date` никогда не используется для поиска курса; для RUB коэффициент 1. `outlier_mark=true` сохраняется в Core, но исключается из BI и ML; дополнительного пересчёта аномалий нет. Пары с одинаковыми городами не отвергаются.

Категории берутся из исходной записи, если заполнены, иначе рассчитываются по регламенту: `G20T ≥30`, `FTL ≥10`, `10T ≥5`, `5T ≥2.5`, `L5T ≥0.5`, иначе `OTH` с округлением до 0.1 т; объём `FTL` при `0<V<=120`.

**Ограничение источника:** сделки, созданные 2026-10-26, ещё не прошли ночную разметку и могут иметь `outlier_mark=false` даже при аномальных ценах. Базовая реализация сохраняет это поведение, не изобретая новые правила выбросов.

## Надёжность, backfill и повторный запуск

В транзакции создаются временные таблицы, удаляются и повторно вставляются Core-записи **только заданного окна погрузки**, вместе с зависимыми кузовами (FK `ON DELETE CASCADE`) и карантином; при ошибке весь ETL откатывается. Затем полным детерминированным пересчётом обновляется mart (нужно для корректных месячных сравнений при backfill). Запуск ETL вручную после старта БД:

```bash
docker compose run --rm --entrypoint python pipeline -m etl.run --start-date 2026-09-01 --end-date 2026-10-26
```

*Важно:* отдельный запуск ETL пересчитывает Core/market mart, но не переобучает ML; для скоринга выполнить `docker compose run --rm --entrypoint python pipeline -m ml.train`. Команда `docker compose up` запускает полный конвейер.

## Метрики и семантика

- `p25_trip`, `median_trip`, `p75_trip`, `avg_trip` — RUB за рейс; отдельные квантили RUB/km, рассчитанные по `price_rub / distance`.
- `trips_count` — уникальные `price_id`, `carriers_count` — `COUNT(DISTINCT organization_id)` только для `price_type IN (3,9)`.
- `cv_rate` — выборочное стандартное отклонение / средняя ставка (NULL при 1 записи).
- `mom_pct`, `yoy_pct` — сравнения медиан с **точным** предыдущим календарным месяцем и прошлогодним месяцем; если месяца нет — NULL.
- `HIGH`: минимум 30 сделок, 5 перевозчиков и месяц в пределах 30-дневного горизонта от снимка; `MEDIUM`: минимум 10; иначе `LOW_DATA`. Свежесть определена по месяцу, а не фактической дате последней сделки: приближение ввиду зерна витрины.

## ML и предотвращение утечек

**Train:** 2026-07-26 — 2026-10-04, **test:** 2026-10-05 — 2026-10-26. Отбор исторических строк: факт + прямой рейс + отсутствие флага выброса. Прогнозы будущих заявок (`loading_date > 2026-10-26`) формируются для прямых маршрутов, в том числе заявок без `is_fact`, но будущие значения `actual_price_rub`, `abs_error_rub`, `ape_pct` всегда `NULL`.

Признаки — геокоординаты, **отдельные** регионы отправления/назначения (из канонических `full_name_local`), расстояние, вес, объём, группа кузова, весовая и объёмная категории, год, месяц, день недели/года, циклические sin/cos для месяца, недели и года. Модель CatBoostRegressor фиксирует `random_seed=20261026`. Запрещённые поля (`price`, `price_rub`, `price_with_vat`, тариф/км, `price_group_stats`, `price_group_id`, `outlier_mark`) **не входят в feature allowlist**. Используем нативную обработку категорий/пропусков CatBoost; train/test статистики не смешиваются. Конкретные значения качества (R², MAPE, RMSE, MAE) определяются только после запуска обучения и доступны в логах или `mart.ml_model_metrics`.

## Проверочные SQL-запросы

```sql
-- Счётчики нормализации и карантина
SELECT (SELECT count(*) FROM public.prices) AS source,
       (SELECT count(*) FROM core.deals) AS accepted,
       (SELECT count(*) FROM core.dq_quarantine_prices) AS rejected;

-- Какие отклонения встретились?
SELECT reason, count(*) FROM core.dq_quarantine_prices,
  unnest(reasons) AS reason GROUP BY reason ORDER BY count(*) DESC;

-- Топ маршрутов по доказательной базе
SELECT month, loading_city, unloading_city, body_group, weight_category,
       median_trip, p25_trip, p75_trip, trips_count, carriers_count, reliability_level
FROM mart.market_corridor ORDER BY trips_count DESC LIMIT 20;

-- Проверка зерна и недопущения дублей
SELECT price_id, body_group, count(*) FROM core.deal_body_groups
GROUP BY price_id, body_group HAVING count(*) > 1;

-- ML метрики
SELECT * FROM mart.ml_model_metrics;
SELECT loading_date, body_group, actual_price_rub, predicted_price_rub, ape_pct
FROM mart.ml_price_predictions ORDER BY loading_date DESC LIMIT 20;

-- Будущие заявки не содержат actuals
SELECT count(*) FROM mart.ml_price_predictions
WHERE loading_date > DATE '2026-10-26'
  AND (actual_price_rub IS NOT NULL OR abs_error_rub IS NOT NULL OR ape_pct IS NOT NULL);
```

## Проверки

```bash
# unit
python -m pytest -q
# end-to-end: выполнено на macOS с Docker Desktop 2026-11-06; при воспроизведении запускать локально
# 1. Запустить docker compose up --build
# 2. Проверить queries выше (source=accepted+rejected при полном окне)
# 3. Повторить docker compose up; сравнить count/median_trips и число прогнозов
```

## Ограничения прототипа

- Нет Airflow / Superset / ClickHouse (бонусная часть).
- Mart пересчитывается целиком, что упрощает корректный backfill и обеспечивает независимость MoM/YoY; на большом production dataset нужен incremental refresh с зависимостями дат.
- Регионы извлекаются упрощённо через первую запятую: работает для эталонного датасета, для произвольных реальных названий потребуется нормализованный региональный справочник.
- Один и тот же price_id может дать несколько обучающих строк из разных кузовных групп — это отражает вариант использования кузовов в тарифной витрине; при реальном ML evaluation лучше дополнительно провести ablation до одной бизнес-группы на сделку.
- Изменение входных справочников после загрузки требует повторной нормализации окна и пересчёта mart.

## Публикация в GitHub

Рекомендуется новый **приватный** репозиторий (если работодатель просит публичную ссылку — открыть доступ позднее). Загружайте содержимое корневой папки проекта, а не внешний ZIP. `.env`, локальные базы и веса модели `.cbm` не коммитить. После загрузки проверьте наличие `README.md`, `docker-compose.yml`, `sql/`, `etl/`, `ml/`, `tests/` в корне репозитория. Для отправки работодателю предоставьте ссылку на репозиторий и краткий отчёт по synthetic ETL/ML.
