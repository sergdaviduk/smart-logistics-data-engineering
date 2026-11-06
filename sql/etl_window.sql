-- Requires bound parameters :start_date and :end_date (inclusive).
-- Run in ONE transaction; delete+reload window is atomic and strictly idempotent.
-- A staged candidate set avoids duplicate DQ checks and prohibits silent drops.
CREATE TEMP TABLE batch_source ON COMMIT DROP AS
SELECT p.*,
  CASE WHEN p.currency_code = '643' THEN 1.0 ELSE er.value END AS exchange_rate,
  (cl.gc_id IS NOT NULL AND cu.gc_id IS NOT NULL) AS cities_exist
FROM public.prices p
LEFT JOIN core.dim_cities cl ON cl.gc_id = p.loading_city_gcid
LEFT JOIN core.dim_cities cu ON cu.gc_id = p.unloading_city_gcid
LEFT JOIN LATERAL (
 SELECT e.value FROM public.exchange_rates e
 WHERE e.num_code = p.currency_code AND e.setting_date = p.nearest_rate_date
 ORDER BY e.id ASC LIMIT 1
) er ON p.currency_code <> '643'
WHERE p.loading_date BETWEEN :start_date AND :end_date;

CREATE TEMP TABLE batch_validated ON COMMIT DROP AS
SELECT b.*,
 array_remove(ARRAY[
  CASE WHEN b.price <= 0 THEN 'NON_POSITIVE_PRICE' END,
  CASE WHEN b.currency_code = '643' AND b.price <= 1000 THEN 'RUB_PRICE_TOO_LOW' END,
  CASE WHEN b.distance <= 0 OR b.distance > 1e308 THEN 'INVALID_DISTANCE' END,
  CASE WHEN b.total_weight < 0 OR b.total_weight > 1e308 THEN 'NEGATIVE_WEIGHT' END,
  CASE WHEN b.total_volume < 0 OR b.total_volume > 1e308 THEN 'NEGATIVE_VOLUME' END,
  CASE WHEN NOT b.cities_exist THEN 'UNKNOWN_CITY' END,
  CASE WHEN b.currency_code NOT IN ('643','840','978') THEN 'UNKNOWN_CURRENCY' END,
  CASE WHEN b.exchange_rate IS NULL OR b.exchange_rate <= 0 OR b.exchange_rate > 1e308 THEN 'MISSING_EXCHANGE_RATE' END,
  CASE WHEN b.price > 1e308 THEN 'INVALID_PRICE' END
 ], NULL)::text[] AS dq_reasons
FROM batch_source b;

DELETE FROM core.deals WHERE loading_date BETWEEN :start_date AND :end_date;
DELETE FROM core.dq_quarantine_prices WHERE loading_date BETWEEN :start_date AND :end_date;

INSERT INTO core.dq_quarantine_prices(price_id,loading_date,reasons)
SELECT id, loading_date, dq_reasons FROM batch_validated WHERE cardinality(dq_reasons) > 0;

INSERT INTO core.deals (
price_id,created_at,loading_date,loading_city_gcid,unloading_city_gcid,
distance,total_weight,total_volume,price_rub,currency_code,
is_fact,price_type,complex,organization_id,outlier_mark,weight_category,volume_category)
SELECT id,created_at,loading_date,loading_city_gcid,unloading_city_gcid,
distance,total_weight,total_volume,price * exchange_rate,currency_code,
is_fact,price_type,complex,organization_id,outlier_mark,
COALESCE(NULLIF(weight_category,''), CASE
 WHEN round(total_weight::numeric,1)>=30 THEN 'G20T'
 WHEN round(total_weight::numeric,1)>=10 THEN 'FTL'
 WHEN round(total_weight::numeric,1)>=5 THEN '10T'
 WHEN round(total_weight::numeric,1)>=2.5 THEN '5T'
 WHEN round(total_weight::numeric,1)>=0.5 THEN 'L5T' ELSE 'OTH' END),
COALESCE(NULLIF(volume_category,''), CASE WHEN total_volume>0 AND total_volume<=120 THEN 'FTL' ELSE 'OTH' END)
FROM batch_validated WHERE cardinality(dq_reasons)=0;

-- Keep all *distinct standardized* groups represented by 1C types. NULL -> 'Не указан'.
INSERT INTO core.deal_body_groups(price_id, body_group)
SELECT DISTINCT d.price_id,
CASE
 WHEN bt.std_id=56 OR t.body_type_id IN (56,57,58,59,60,61) THEN 'Тент'
 WHEN bt.std_id=4 OR t.body_type_id IN (4,46,47,48) THEN 'Рефрижератор'
 WHEN bt.std_id=2 OR t.body_type_id=2 THEN 'Изотерм'
 WHEN bt.std_id=15 OR t.body_type_id IN (1,15) THEN 'Борт'
 WHEN t.body_type_id IS NULL THEN 'Не указан' ELSE 'Прочие' END
FROM core.deals d
LEFT JOIN LATERAL (
 SELECT pbt.body_type_id FROM public.price_body_types pbt WHERE pbt.price_id=d.price_id
 UNION ALL
 SELECT p.body_type FROM public.prices p
 WHERE p.id=d.price_id AND p.body_type IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM public.price_body_types x WHERE x.price_id=p.id)
) t ON true
LEFT JOIN public.body_types bt ON bt.id=t.body_type_id
WHERE d.loading_date BETWEEN :start_date AND :end_date
ON CONFLICT DO NOTHING;
