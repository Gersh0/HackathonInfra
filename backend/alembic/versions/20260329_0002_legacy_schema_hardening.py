"""Legacy schema hardening for startup-era drift.

Revision ID: 20260329_0002
Revises: 20260327_0001
Create Date: 2026-03-29
"""

from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

# revision identifiers, used by Alembic.
revision: str = "20260329_0002"
down_revision: Union[str, Sequence[str], None] = "20260327_0001"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def _index_names(inspector: sa.Inspector, table_name: str) -> set[str]:
    return {idx["name"] for idx in inspector.get_indexes(table_name)}


def _column_names(inspector: sa.Inspector, table_name: str) -> set[str]:
    return {col["name"] for col in inspector.get_columns(table_name)}


def upgrade() -> None:
    bind = op.get_bind()
    inspector = sa.inspect(bind)

    video_columns = _column_names(inspector, "videos")
    if "uploader_id" not in video_columns:
        op.add_column("videos", sa.Column("uploader_id", sa.Integer(), nullable=True))

    if "views" not in video_columns:
        op.add_column(
            "videos",
            sa.Column("views", sa.Integer(), nullable=False, server_default=sa.text("0")),
        )
        op.alter_column("videos", "views", server_default=None)
    else:
        op.execute(sa.text("UPDATE videos SET views = 0 WHERE views IS NULL"))
        op.alter_column("videos", "views", nullable=False, existing_type=sa.Integer())

    inspector = sa.inspect(bind)
    video_fks = inspector.get_foreign_keys("videos")
    has_uploader_fk = any(
        fk.get("referred_table") == "users" and fk.get("constrained_columns") == ["uploader_id"]
        for fk in video_fks
    )
    if "uploader_id" in _column_names(inspector, "videos") and not has_uploader_fk:
        op.create_foreign_key(
            "fk_videos_uploader_id_users",
            "videos",
            "users",
            ["uploader_id"],
            ["id"],
        )

    video_indexes = _index_names(inspector, "videos")
    if "ix_videos_created_at" not in video_indexes:
        op.create_index("ix_videos_created_at", "videos", ["created_at"], unique=False)
    if "ix_videos_uploader_created" not in video_indexes:
        op.create_index("ix_videos_uploader_created", "videos", ["uploader_id", "created_at"], unique=False)
    if "ix_videos_views" not in video_indexes:
        op.create_index("ix_videos_views", "videos", ["views"], unique=False)

    comment_indexes = _index_names(inspector, "comments")
    if "ix_comments_video_created" not in comment_indexes:
        op.create_index("ix_comments_video_created", "comments", ["video_id", "created_at"], unique=False)

    subscription_indexes = _index_names(inspector, "subscriptions")
    if "ix_subscriptions_follower_created" not in subscription_indexes:
        op.create_index(
            "ix_subscriptions_follower_created",
            "subscriptions",
            ["follower_id", "created_at"],
            unique=False,
        )
    if "ix_subscriptions_creator_id" not in subscription_indexes:
        op.create_index("ix_subscriptions_creator_id", "subscriptions", ["creator_id"], unique=False)

    unique_constraints = {
        uc["name"] for uc in inspector.get_unique_constraints("subscriptions") if uc.get("name")
    }
    if "uq_subscription_pair" not in unique_constraints:
        op.create_unique_constraint(
            "uq_subscription_pair",
            "subscriptions",
            ["follower_id", "creator_id"],
        )

    check_constraints = {ck["name"] for ck in inspector.get_check_constraints("subscriptions") if ck.get("name")}
    if "ck_subscription_no_self" not in check_constraints:
        op.create_check_constraint(
            "ck_subscription_no_self",
            "subscriptions",
            "follower_id != creator_id",
        )


def downgrade() -> None:
    # Intentionally no-op: this migration is a safety hardening layer for legacy schemas.
    pass
