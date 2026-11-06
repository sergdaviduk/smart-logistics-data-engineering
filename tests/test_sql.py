from pathlib import Path
from etl.sqlrunner import statements

BASE=Path(__file__).resolve().parents[1] / 'sql'

def test_query_files_have_valid_chunks():
    for sqlfile in ['analytics.sql','etl_window.sql','mart_refresh.sql']:
        chunks=statements((BASE/sqlfile).read_text())
        assert len(chunks)>2
        assert all(c.endswith(';') for c in chunks)

def test_expected_guards_exist():
    etl=(BASE/'etl_window.sql').read_text()
    mart=(BASE/'mart_refresh.sql').read_text()
    assert 'nearest_rate_date' in etl
    assert 'cardinality(dq_reasons)' in etl
    assert 'ON CONFLICT DO NOTHING' in etl
    assert "DATE '2026-10-26'" in mart
    assert 'count(DISTINCT organization_id)' in mart
