"""add trigram index on videos.title

Revision ID: 20260509_0007
Revises: 20260507_0006
Create Date: 2026-05-09
"""
from alembic import op

revision = "20260509_0007"
down_revision = "20260507_0006"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute("CREATE EXTENSION IF NOT EXISTS pg_trgm")
    op.execute(
        "CREATE INDEX ix_videos_title_trgm ON videos USING GIN (title gin_trgm_ops)"
    )


def downgrade() -> None:
    op.execute("DROP INDEX IF EXISTS ix_videos_title_trgm")
    op.execute(
        """
        DO $$
        BEGIN
            IF NOT EXISTS (
                SELECT 1
                FROM pg_indexes
                WHERE indexdef ILIKE '%gin_trgm_ops%'
            ) THEN
                DROP EXTENSION IF EXISTS pg_trgm;
            END IF;
        END
        $$;
        """
    )
