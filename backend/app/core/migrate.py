import subprocess

from sqlalchemy import inspect

from app.core.database import engine


BASELINE_REVISION = "20260327_0001"


def run_alembic(*args: str) -> None:
    subprocess.run(["uv", "run", "alembic", *args], check=True)


def main() -> None:
    inspector = inspect(engine)
    table_names = set(inspector.get_table_names())

    if not table_names:
        run_alembic("upgrade", "head")
        return

    if "alembic_version" in table_names:
        run_alembic("upgrade", "head")
        return

    # Legacy database detected (tables exist but no migration history).
    # Stamp baseline revision so incremental migrations can be applied.
    run_alembic("stamp", BASELINE_REVISION)
    run_alembic("upgrade", "head")


if __name__ == "__main__":
    main()