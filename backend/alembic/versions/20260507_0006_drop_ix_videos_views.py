"""drop ix_videos_views index to reduce hot-row contention

Revision ID: 20260507_0006
Revises: 20260329_0005
Create Date: 2026-05-07
"""

from alembic import op

revision = "20260507_0006"
down_revision = "20260329_0005"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.drop_index("ix_videos_views", table_name="videos", if_exists=True)


def downgrade() -> None:
    op.create_index("ix_videos_views", "videos", ["views"], unique=False)
