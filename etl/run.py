"""Atomic date-window ETL with quarantined rejects and reproducible SQL marts."""
import argparse
import logging
import os
from datetime import date
from pathlib import Path

import psycopg
from sqlalchemy import create_engine, text

ROOT = Path(__file__).resolve().parents[1]
LOG = logging.getLogger('smart_logistics.etl')


def parse_args():
    parser = argparse.ArgumentParser(description='Repeatable DWH backfill')
    parser.add_argument('--start-date', type=date.fromisoformat, default=date(2023, 1, 1))
    parser.add_argument('--end-date', type=date.fromisoformat, default=date(2027, 12, 31))
    return parser.parse_args()


def etl_window(engine, start_date: date, end_date: date):
    if start_date > end_date:
        raise ValueError('start-date must not exceed end-date')
    with engine.begin() as conn:
        # SQLAlchemy textual query supports named binds; SQL splitter avoids psycopg multi-statement bind restrictions.
        sql = (ROOT / 'sql' / 'etl_window.sql').read_text()
        # Use driver SQL execution with safe parameter binding at each SQL statement.
        from etl.sqlrunner import statements
        for statement in statements(sql):
            conn.execute(text(statement), {'start_date': start_date, 'end_date': end_date})
        stats = conn.execute(text('''SELECT
           (SELECT count(*) FROM core.deals WHERE loading_date BETWEEN :start_date AND :end_date) AS valid,
           (SELECT count(*) FROM core.dq_quarantine_prices WHERE loading_date BETWEEN :start_date AND :end_date) AS rejected'''),
           {'start_date': start_date, 'end_date': end_date}).one()
    LOG.info('etl_complete start=%s end=%s accepted=%d rejected=%d', start_date,end_date,*stats)
    return tuple(stats)


def refresh_mart(engine):
    from etl.sqlrunner import statements
    with engine.begin() as conn:
        for statement in statements((ROOT / 'sql' / 'mart_refresh.sql').read_text()):
            conn.execute(text(statement))
        count=conn.execute(text('SELECT count(*) FROM mart.market_corridor')).scalar_one()
    LOG.info('mart_refreshed cells=%s', count)
    return count


def main():
    logging.basicConfig(level=os.environ.get('LOG_LEVEL', 'INFO'), format='%(asctime)s %(levelname)s %(name)s %(message)s')
    args=parse_args()
    engine=create_engine(os.environ['DATABASE_URL'], pool_pre_ping=True)
    with engine.begin() as conn:
        for sql in __import__('etl.sqlrunner', fromlist=['statements']).statements((ROOT / 'sql' / 'analytics.sql').read_text()):
            conn.execute(text(sql))
    etl_window(engine, args.start_date, args.end_date)
    refresh_mart(engine)

if __name__=='__main__':
    main()
