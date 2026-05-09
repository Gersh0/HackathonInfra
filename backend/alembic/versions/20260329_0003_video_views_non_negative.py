"""Enforce non-negative video view counts.

Revision ID: 20260329_0003
Revises: 20260329_0002
Create Date: 2026-03-29
"""

from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

# revision identifiers, used by Alembic.
revision: str = "20260329_0003"
down_revision: Union[str, Sequence[str], None] = "20260329_0002"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def _check_constraint_names(inspector: sa.Inspector, table_name: str) -> set[str]:
    return {ck["name"] for ck in inspector.get_check_constraints(table_name) if ck.get("name")}


def upgrade() -> None:
    bind = op.get_bind()
    inspector = sa.inspect(bind)

    # Normalize legacy drift before enforcing constraint.
    op.execute(sa.text("UPDATE videos SET views = 0 WHERE views IS NULL OR views < 0"))

    check_constraints = _check_constraint_names(inspector, "videos")
    if "ck_videos_views_non_negative" not in check_constraints:
        op.create_check_constraint(
            "ck_videos_views_non_negative",
            "videos",
            "views >= 0",
        )


def downgrade() -> None:
    bind = op.get_bind()
    inspector = sa.inspect(bind)
    check_constraints = _check_constraint_names(inspector, "videos")
    if "ck_videos_views_non_negative" in check_constraints:
        op.drop_constraint("ck_videos_views_non_negative", "videos", type_="check")
