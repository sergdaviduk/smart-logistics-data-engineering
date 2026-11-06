"""Price-independent, leakage-free features for each deal × standardized body group."""
import numpy as np
import pandas as pd

AS_OF = pd.Timestamp('2026-10-26')
TRAIN_START = pd.Timestamp('2026-07-26')
TEST_START = pd.Timestamp('2026-10-05')
CATEGORICAL = ['origin_region','destination_region','body_group','weight_category','volume_category']
NUMERIC = [
    'distance','total_weight','total_volume',
    'origin_lat','origin_lon','destination_lat','destination_lon',
    'year','month','weekday','dayofyear',
    'month_sin','month_cos','weekday_sin','weekday_cos','dayofyear_sin','dayofyear_cos',
]
FEATURES = CATEGORICAL + NUMERIC

# Explicit allowlist: future deal's source price, outlier mark, historical price aggregates,
# carrier organization_id, and group statistics are not predictors.
QUERY = '''
SELECT d.price_id,d.loading_date,d.loading_city_gcid,d.unloading_city_gcid,
 d.price_rub,d.is_fact,d.complex,d.outlier_mark,d.distance,d.total_weight,d.total_volume,
 d.weight_category,d.volume_category,bg.body_group,
 oc.region AS origin_region,dc.region AS destination_region,
 oc.latitude AS origin_lat,oc.longitude AS origin_lon,
 dc.latitude AS destination_lat,dc.longitude AS destination_lon
FROM core.deals d
JOIN core.deal_body_groups bg ON bg.price_id=d.price_id
JOIN core.dim_cities oc ON oc.gc_id=d.loading_city_gcid
JOIN core.dim_cities dc ON dc.gc_id=d.unloading_city_gcid
WHERE NOT d.complex AND NOT d.outlier_mark
  AND d.loading_date >= DATE '2026-07-26'
  AND (d.is_fact OR d.loading_date > DATE '2026-10-26')
'''


def engineer(frame: pd.DataFrame) -> pd.DataFrame:
    frame=frame.copy()
    t=pd.to_datetime(frame['loading_date'])
    frame['year']=t.dt.year
    frame['month']=t.dt.month
    frame['weekday']=t.dt.dayofweek
    frame['dayofyear']=t.dt.dayofyear
    for unit,period in [('month',12),('weekday',7),('dayofyear',365.25)]:
        angle=2*np.pi*frame[unit]/period
        frame[f'{unit}_sin']=np.sin(angle)
        frame[f'{unit}_cos']=np.cos(angle)
    for col in CATEGORICAL:
        frame[col]=frame[col].fillna('UNKNOWN').astype(str)
    for col in NUMERIC:
        frame[col]=pd.to_numeric(frame[col],errors='coerce')
    return frame


def split(frame: pd.DataFrame):
    dates=pd.to_datetime(frame['loading_date'])
    train=frame.loc[(dates>=TRAIN_START)&(dates<TEST_START)].copy()
    test=frame.loc[(dates>=TEST_START)&(dates<=AS_OF)].copy()
    future=frame.loc[dates>AS_OF].copy()
    assert train['loading_date'].max() < test['loading_date'].min(), 'Invalid temporal split'
    return train,test,future
