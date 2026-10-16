"""Load the nine Olist CSV files into the raw schema of PostgreSQL.

Raw layer rule: load everything as TEXT, exactly as in the source.
Types are applied later, in the staging layer.
The load is all-or-nothing: if any row count does not match the source
file, the whole load is rolled back.
"""
import csv
import logging
import os
import time
from pathlib import Path

import psycopg
from dotenv import load_dotenv

load_dotenv()

RAW_DIR = Path("data/raw")
SCHEMA = "raw"

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    handlers=[logging.FileHandler("pipeline/load_raw.log"), logging.StreamHandler()],
)
log = logging.getLogger("load_raw")


def table_name(path: Path) -> str:
    name = path.stem
    if name.startswith("olist_"):
        name = name[len("olist_"):]
    if name.endswith("_dataset"):
        name = name[: -len("_dataset")]
    return name


def read_header(path: Path) -> list[str]:
    with path.open(encoding="utf-8-sig", newline="") as f:
        return next(csv.reader(f))


def count_source_rows(path: Path) -> int:
    """Count data rows with a real CSV parser (handles multi-line fields)."""
    with path.open(encoding="utf-8-sig", newline="") as f:
        reader = csv.reader(f)
        next(reader)  # skip header
        return sum(1 for _ in reader)


def load_file(conn, path: Path) -> int:
    table = table_name(path)
    col_defs = ", ".join(f'"{c}" TEXT' for c in read_header(path))
    with conn.cursor() as cur:
        cur.execute(f'DROP TABLE IF EXISTS {SCHEMA}."{table}"')
        cur.execute(f'CREATE TABLE {SCHEMA}."{table}" ({col_defs})')
        copy_sql = f'COPY {SCHEMA}."{table}" FROM STDIN WITH (FORMAT csv, HEADER true)'
        with path.open("rb") as f, cur.copy(copy_sql) as copy:
            while chunk := f.read(1024 * 1024):
                copy.write(chunk)
        cur.execute(f'SELECT COUNT(*) FROM {SCHEMA}."{table}"')
        return cur.fetchone()[0]


def main() -> None:
    files = sorted(RAW_DIR.glob("*.csv"))
    if not files:
        raise SystemExit(f"No CSV files found in {RAW_DIR.resolve()}")

    conn_kwargs = dict(
        host=os.environ["PGHOST"],
        port=os.environ["PGPORT"],
        dbname=os.environ["PGDATABASE"],
        user=os.environ["PGUSER"],
        password=os.environ["PGPASSWORD"],
        client_encoding="UTF8",
    )

    mismatches = []
    with psycopg.connect(**conn_kwargs) as conn:
        conn.execute(f"CREATE SCHEMA IF NOT EXISTS {SCHEMA}")
        for path in files:
            start = time.time()
            db_rows = load_file(conn, path)
            src_rows = count_source_rows(path)
            status = "MATCH" if db_rows == src_rows else "MISMATCH"
            if status == "MISMATCH":
                mismatches.append(path.name)
            log.info(
                "%-40s -> %s.%-32s db=%s source=%s %s (%.1fs)",
                path.name, SCHEMA, table_name(path),
                f"{db_rows:,}", f"{src_rows:,}", status, time.time() - start,
            )
        if mismatches:
            raise RuntimeError(f"Row count mismatch, load rolled back: {mismatches}")
    log.info("Done: %d files loaded and reconciled", len(files))


if __name__ == "__main__":
    main()