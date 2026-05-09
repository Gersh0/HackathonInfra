"""Add users.created_at index for list query performance.

Revision ID: 20260329_0004
Revises: 20260329_0003
Create Date: 2026-03-29
"""

from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

# revision identifiers, used by Alembic.
revision: str = "20260329_0004"
down_revision: Union[str, Sequence[str], None] = "20260329_0003"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def _index_names(inspector: sa.Inspector, table_name: str) -> set[str]:
    return {idx["name"] for idx in inspector.get_indexes(table_name)}


def upgrade() -> None:
    bind = op.get_bind()
    inspector = sa.inspect(bind)
    if "ix_users_created_at" not in _index_names(inspector, "users"):
        op.create_index("ix_users_created_at", "users", ["created_at"], unique=False)


def downgrade() -> None:
    bind = op.get_bind()
    inspector = sa.inspect(bind)
    if "ix_users_created_at" in _index_names(inspector, "users"):
        op.drop_index("ix_users_created_at", table_name="users")
