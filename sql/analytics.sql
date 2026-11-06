CREATE SCHEMA IF NOT EXISTS core;
CREATE SCHEMA IF NOT EXISTS mart;

-- Canonical city: smallest surrogate id wins, NOT distinct full name.
CREATE OR REPLACE VIEW core.dim_cities AS
SELECT DISTINCT ON (gc_id) gc_id, id AS source_city_id, name,
       full_name_local, NULLIF(trim(split_part(full_name_local, ',', 2)), '') AS region,
       latitude, longitude
FROM public.cities ORDER BY gc_id, id;

CREATE TABLE IF NOT EXISTS core.deals (
 price_id bigint PRIMARY KEY,
 created_at timestamp, loading_date date NOT NULL,
 loading_city_gcid integer NOT NULL, unloading_city_gcid integer NOT NULL,
 distance double precision NOT NULL, total_weight double precision NOT NULL,
 total_volume double precision NOT NULL, price_rub double precision NOT NULL,
 currency_code varchar(3) NOT NULL, is_fact boolean NOT NULL,
 price_type smallint NOT NULL, complex boolean NOT NULL,
 organization_id integer, outlier_mark boolean NOT NULL,
 weight_category varchar(4) NOT NULL, volume_category varchar(4) NOT NULL
);
CREATE INDEX IF NOT EXISTS core_deals_date_idx ON core.deals (loading_date);
CREATE INDEX IF NOT EXISTS core_deals_direction_idx ON core.deals (loading_city_gcid, unloading_city_gcid);

CREATE TABLE IF NOT EXISTS core.deal_body_groups (
 price_id bigint NOT NULL REFERENCES core.deals(price_id) ON DELETE CASCADE,
 body_group text NOT NULL,
 PRIMARY KEY (price_id, body_group)
);
CREATE INDEX IF NOT EXISTS body_group_price_idx ON core.deal_body_groups (body_group, price_id);

CREATE TABLE IF NOT EXISTS core.dq_quarantine_prices (
 price_id bigint PRIMARY KEY,
 loading_date date NOT NULL,
 reasons text[] NOT NULL,
 detected_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS mart.market_corridor (
 month date NOT NULL,
 loading_city_gcid integer NOT NULL, unloading_city_gcid integer NOT NULL,
 loading_city text NOT NULL, unloading_city text NOT NULL,
 body_group text NOT NULL, weight_category varchar(4) NOT NULL,
 p25_trip double precision NOT NULL, median_trip double precision NOT NULL,
 p75_trip double precision NOT NULL, avg_trip double precision NOT NULL,
 p25_km double precision NOT NULL, median_km double precision NOT NULL, p75_km double precision NOT NULL,
 trips_count bigint NOT NULL, carriers_count bigint NOT NULL, cv_rate double precision,
 mom_pct double precision, yoy_pct double precision,
 reliability_level text NOT NULL, refreshed_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY (month, loading_city_gcid, unloading_city_gcid, body_group, weight_category)
);
CREATE INDEX IF NOT EXISTS mart_corridor_direction_idx ON mart.market_corridor
(loading_city_gcid, unloading_city_gcid, month DESC);

CREATE TABLE IF NOT EXISTS mart.ml_price_predictions (
 price_id bigint NOT NULL, body_group text NOT NULL,
 loading_date date NOT NULL, loading_city_gcid integer NOT NULL,
 unloading_city_gcid integer NOT NULL, actual_price_rub double precision,
 predicted_price_rub double precision NOT NULL,
 abs_error_rub double precision, ape_pct double precision,
 model_name text NOT NULL, scored_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(price_id, body_group, model_name)
);
CREATE TABLE IF NOT EXISTS mart.ml_model_metrics (
 model_name text PRIMARY KEY, train_count bigint NOT NULL, test_count bigint NOT NULL,
 r2 double precision, mape_pct double precision, rmse_rub double precision, mae_rub double precision,
 trained_at timestamptz NOT NULL DEFAULT now()
);
