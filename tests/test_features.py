import pandas as pd
import numpy as np
from ml.features import FEATURES, engineer, split, TRAIN_START, TEST_START, AS_OF


def test_split_boundary_and_future():
    data=pd.DataFrame({'loading_date':['2026-07-25','2026-07-26','2026-10-04','2026-10-05','2026-10-26','2026-10-27'],
                       'price_rub':[1,2,3,4,5,6]})
    train,test,future=split(data)
    assert train.price_rub.tolist()==[2,3]
    assert test.price_rub.tolist()==[4,5]
    assert future.price_rub.tolist()==[6]


def test_feature_allowlist_no_target_or_leakage():
    assert not {'price_rub','price','price_with_vat','price_group_id','outlier_mark','avg_price','organization_id','price_km'} & set(FEATURES)
    row={'loading_date':['2026-10-05'],'origin_region':['A'],'destination_region':['B'],
         'body_group':['Тент'],'weight_category':['FTL'],'volume_category':['FTL'],
         'distance':[100.],'total_weight':[20.],'total_volume':[100.],
         'origin_lat':[1.], 'origin_lon':[2.], 'destination_lat':[3.], 'destination_lon':[4.]}
    result=engineer(pd.DataFrame(row))
    assert np.isclose(result['month_sin'].iloc[0],np.sin(2*np.pi*10/12))
    assert all(c in result.columns for c in FEATURES)


def test_empty_region_encoded():
    row={'loading_date':['2026-09-01'],'origin_region':[None],'destination_region':['R'],
         'body_group':['Борт'],'weight_category':['FTL'],'volume_category':['OTH'],
         'distance':[1.], 'total_weight':[10.], 'total_volume':[0.],
         'origin_lat':[None], 'origin_lon':[0.], 'destination_lat':[0.], 'destination_lon':[0.]}
    x=engineer(pd.DataFrame(row))
    assert x['origin_region'].iloc[0]=='UNKNOWN'
