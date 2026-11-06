-- Full refresh: correct calendar MoM/YoY and long-running price_dates.
-- DATE boundaries are tied to fixed dataset snapshot, NOT wall clock.
TRUNCATE TABLE mart.market_corridor;
CREATE TEMP TABLE corridor_base ON COMMIT DROP AS
SELECT date_trunc('month', pd.price_date)::date AS month,
 d.price_id, d.loading_city_gcid, d.unloading_city_gcid,
 lc.name AS loading_city, uc.name AS unloading_city,
 bg.body_group, d.weight_category, d.price_rub, d.distance,
 d.price_type, d.organization_id
FROM core.deals d
JOIN public.price_dates pd ON pd.price_id=d.price_id
JOIN core.dim_cities lc ON lc.gc_id=d.loading_city_gcid
JOIN core.dim_cities uc ON uc.gc_id=d.unloading_city_gcid
JOIN core.deal_body_groups bg ON bg.price_id=d.price_id
WHERE d.is_fact AND d.price_type IN (1,2,3,4,5,9)
 AND NOT d.complex AND NOT d.outlier_mark
 AND d.price_rub>0 AND d.distance>0 AND pd.price_date<=DATE '2026-10-26';

-- The explicit distinct prevents one price duplicated by redundant price_dates / body mappings.
CREATE TEMP TABLE corridor_agg ON COMMIT DROP AS
SELECT month, loading_city_gcid, unloading_city_gcid, loading_city, unloading_city,
 body_group, weight_category,
 percentile_cont(0.25) WITHIN GROUP (ORDER BY price_rub) AS p25_trip,
 percentile_cont(0.50) WITHIN GROUP (ORDER BY price_rub) AS median_trip,
 percentile_cont(0.75) WITHIN GROUP (ORDER BY price_rub) AS p75_trip,
 avg(price_rub) AS avg_trip,
 percentile_cont(0.25) WITHIN GROUP (ORDER BY price_rub / distance) AS p25_km,
 percentile_cont(0.50) WITHIN GROUP (ORDER BY price_rub / distance) AS median_km,
 percentile_cont(0.75) WITHIN GROUP (ORDER BY price_rub / distance) AS p75_km,
 count(DISTINCT price_id) AS trips_count,
 count(DISTINCT organization_id) FILTER (WHERE price_type IN (3,9)) AS carriers_count,
 stddev_samp(price_rub)/NULLIF(avg(price_rub),0) AS cv_rate
FROM (SELECT DISTINCT * FROM corridor_base) x
GROUP BY month,loading_city_gcid,unloading_city_gcid,loading_city,unloading_city,body_group,weight_category;

INSERT INTO mart.market_corridor (
month, loading_city_gcid,unloading_city_gcid,loading_city,unloading_city,
body_group,weight_category,p25_trip,median_trip,p75_trip,avg_trip,p25_km,median_km,p75_km,
trips_count,carriers_count,cv_rate,mom_pct,yoy_pct,reliability_level)
SELECT a.month,a.loading_city_gcid,a.unloading_city_gcid,a.loading_city,a.unloading_city,
a.body_group,a.weight_category,a.p25_trip,a.median_trip,a.p75_trip,a.avg_trip,
a.p25_km,a.median_km,a.p75_km,a.trips_count,a.carriers_count,a.cv_rate,
100*(a.median_trip-prev.median_trip)/NULLIF(prev.median_trip,0),
100*(a.median_trip/NULLIF(yearago.median_trip,0)-1),
CASE WHEN a.trips_count>=30 AND a.carriers_count>=5
 AND a.month >= date_trunc('month', DATE '2026-10-26' - INTERVAL '30 days')::date
 THEN 'HIGH' WHEN a.trips_count>=10 THEN 'MEDIUM' ELSE 'LOW_DATA' END
FROM corridor_agg a
LEFT JOIN corridor_agg prev ON prev.month=(a.month-INTERVAL '1 month')::date
 AND prev.loading_city_gcid=a.loading_city_gcid AND prev.unloading_city_gcid=a.unloading_city_gcid
 AND prev.body_group=a.body_group AND prev.weight_category=a.weight_category
LEFT JOIN corridor_agg yearago ON yearago.month=(a.month-INTERVAL '1 year')::date
 AND yearago.loading_city_gcid=a.loading_city_gcid AND yearago.unloading_city_gcid=a.unloading_city_gcid
 AND yearago.body_group=a.body_group AND yearago.weight_category=a.weight_category;
