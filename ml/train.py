"""Reproducible CatBoost time-split training + idempotent batch scoring."""
import logging
import os
from pathlib import Path

import numpy as np
import pandas as pd
from catboost import CatBoostRegressor
from sklearn.metrics import r2_score, mean_absolute_error, mean_squared_error, mean_absolute_percentage_error
from sqlalchemy import create_engine, text
from ml.features import QUERY, FEATURES, CATEGORICAL, engineer, split

LOG = logging.getLogger('smart_logistics.ml')
MODEL_NAME = 'CatBoostRegressor_v1'
MODEL_DIR = Path(os.environ.get('MODEL_DIR','/app/models'))


def _predict_rows(frame, predicted, truth_visible):
    records=[]
    for row, yhat in zip(frame.itertuples(index=False),predicted):
        actual=float(row.price_rub) if truth_visible else None
        error=abs(actual-float(yhat)) if actual is not None else None
        ape=error/actual*100 if actual is not None and actual>0 else None
        records.append((int(row.price_id),str(row.body_group),row.loading_date,
                        int(row.loading_city_gcid),int(row.unloading_city_gcid),
                        actual,float(yhat),error,ape,MODEL_NAME))
    return records


def run(engine):
    with engine.connect() as conn:
        frame=pd.read_sql_query(text(QUERY),conn)
    if frame.empty:
        raise RuntimeError('No ETL rows loaded')
    frame=engineer(frame)
    train,test,future=split(frame)
    if train.empty or test.empty:
        raise RuntimeError('Need non-empty train and test windows')
    model=CatBoostRegressor(iterations=350,depth=7,learning_rate=0.07,loss_function='RMSE',
                            random_seed=20261026,thread_count=2,verbose=False,allow_writing_files=False)
    model.fit(train[FEATURES],train['price_rub'].astype(float),cat_features=CATEGORICAL)
    test_pred=np.maximum(0,model.predict(test[FEATURES]))
    future_pred=np.maximum(0,model.predict(future[FEATURES])) if len(future) else np.array([])
    y=test['price_rub'].astype(float)
    metrics={
        'r2':float(r2_score(y,test_pred)),
        'mape_pct':float(mean_absolute_percentage_error(y,test_pred)*100),
        'rmse_rub':float(np.sqrt(mean_squared_error(y,test_pred))),
        'mae_rub':float(mean_absolute_error(y,test_pred)),
    }
    LOG.info('ml_test_metrics train=%d test=%d future=%d %s',len(train),len(test),len(future),metrics)
    MODEL_DIR.mkdir(exist_ok=True,parents=True)
    model.save_model(str(MODEL_DIR / 'catboost_tariffs.cbm'))
    records=_predict_rows(test,test_pred,True) + _predict_rows(future,future_pred,False)
    from psycopg.types.json import Jsonb
    import psycopg
    # psycopg COPY in a transaction; ON CONFLICT via staging table. No Python INSERT per record.
    with psycopg.connect(os.environ['PG_DSN']) as conn:
        with conn.cursor() as cur:
            cur.execute('''CREATE TEMP TABLE prediction_stage (
               price_id bigint, body_group text,loading_date date,
               loading_city_gcid int,unloading_city_gcid int,actual_price_rub float8,
               predicted_price_rub float8,abs_error_rub float8,ape_pct float8,model_name text
            ) ON COMMIT DROP''')
            with cur.copy('''COPY prediction_stage (price_id,body_group,loading_date,
               loading_city_gcid,unloading_city_gcid,actual_price_rub,
               predicted_price_rub,abs_error_rub,ape_pct,model_name) FROM STDIN''') as copy:
                for record in records:
                    copy.write_row(record)
            cur.execute('DELETE FROM mart.ml_price_predictions WHERE model_name=%s',(MODEL_NAME,))
            cur.execute('''INSERT INTO mart.ml_price_predictions
              (price_id,body_group,loading_date,loading_city_gcid,unloading_city_gcid,
               actual_price_rub,predicted_price_rub,abs_error_rub,ape_pct,model_name)
               SELECT * FROM prediction_stage ON CONFLICT (price_id,body_group,model_name)
               DO UPDATE SET actual_price_rub=EXCLUDED.actual_price_rub,
               predicted_price_rub=EXCLUDED.predicted_price_rub,
               abs_error_rub=EXCLUDED.abs_error_rub,ape_pct=EXCLUDED.ape_pct,scored_at=now()''')
            cur.execute('''INSERT INTO mart.ml_model_metrics
              (model_name,train_count,test_count,r2,mape_pct,rmse_rub,mae_rub)
              VALUES (%s,%s,%s,%s,%s,%s,%s)
              ON CONFLICT (model_name) DO UPDATE SET
              train_count=EXCLUDED.train_count,test_count=EXCLUDED.test_count,
              r2=EXCLUDED.r2,mape_pct=EXCLUDED.mape_pct,
              rmse_rub=EXCLUDED.rmse_rub,mae_rub=EXCLUDED.mae_rub,trained_at=now()''',
              (MODEL_NAME,len(train),len(test),metrics['r2'],metrics['mape_pct'],metrics['rmse_rub'],metrics['mae_rub']))
        conn.commit()
    return metrics

if __name__=='__main__':
    logging.basicConfig(level=os.environ.get('LOG_LEVEL','INFO'),format='%(asctime)s %(levelname)s %(message)s')
    engine=create_engine(os.environ['DATABASE_URL'])
    run(engine)
