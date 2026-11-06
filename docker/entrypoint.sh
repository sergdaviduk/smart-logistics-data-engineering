#!/bin/sh
set -eu
export PGPASSWORD="${POSTGRES_PASSWORD}"
DB="${POSTGRES_DB:-deals_bigdata}"
HOST="${POSTGRES_HOST:-db}"
USER="${POSTGRES_USER:-postgres}"

echo 'Waiting for PostgreSQL...'
until pg_isready -h "$HOST" -U "$USER" -d "$DB" >/dev/null 2>&1; do sleep 2; done
if [ "$(psql -h "$HOST" -U "$USER" -d "$DB" -Atqc "SELECT to_regclass('public.prices') IS NOT NULL")" = 'f' ]; then
 echo 'Initializing source schema and 300000 synthetic rows...'
 psql -v ON_ERROR_STOP=1 -h "$HOST" -U "$USER" -d "$DB" -f sql/schema.sql
 psql -v ON_ERROR_STOP=1 -h "$HOST" -U "$USER" -d "$DB" -v n_prices="${N_PRICES:-300000}" -f sql/synthetic.sql
fi
python -m etl.run --start-date "${START_DATE:-2023-01-01}" --end-date "${END_DATE:-2027-12-31}"
python -m ml.train
echo 'Complete: mart.market_corridor, mart.ml_price_predictions, mart.ml_model_metrics.'
