"""Add non-blank integrity constraints for core text fields.

Revision ID: 20260329_0005
Revises: 20260329_0004
Create Date: 2026-03-29
"""

from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

# revision identifiers, used by Alembic.
revision: str = "20260329_0005"
down_revision: Union[str, Sequence[str], None] = "20260329_0004"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def _check_names(inspector: sa.Inspector, table_name: str) -> set[str]:
    return {ck["name"] for ck in inspector.get_check_constraints(table_name) if ck.get("name")}


def upgrade() -> None:
    bind = op.get_bind()
    inspector = sa.inspect(bind)

    checks_by_table = {
        "users": [
            ("ck_users_display_name_not_blank", "char_length(btrim(display_name)) > 0"),
        ],
        "videos": [
            ("ck_videos_title_not_blank", "char_length(btrim(title)) > 0"),
            ("ck_videos_file_path_not_blank", "char_length(btrim(file_path)) > 0"),
        ],
        "comments": [
            ("ck_comments_author_not_blank", "char_length(btrim(author)) > 0"),
            ("ck_comments_content_not_blank", "char_length(btrim(content)) > 0"),
        ],
        "user_identities": [
            ("ck_user_identities_provider_not_blank", "char_length(btrim(provider)) > 0"),
            (
                "ck_user_identities_provider_subject_not_blank",
                "char_length(btrim(provider_subject)) > 0",
            ),
        ],
    }

    for table_name, constraints in checks_by_table.items():
        existing_checks = _check_names(inspector, table_name)
        for constraint_name, condition in constraints:
            if constraint_name not in existing_checks:
                op.create_check_constraint(constraint_name, table_name, condition)


def downgrade() -> None:
    bind = op.get_bind()
    inspector = sa.inspect(bind)

    drops = {
        "users": ["ck_users_display_name_not_blank"],
        "videos": ["ck_videos_title_not_blank", "ck_videos_file_path_not_blank"],
        "comments": ["ck_comments_author_not_blank", "ck_comments_content_not_blank"],
        "user_identities": [
            "ck_user_identities_provider_not_blank",
            "ck_user_identities_provider_subject_not_blank",
        ],
    }

    for table_name, constraint_names in drops.items():
        existing_checks = _check_names(inspector, table_name)
        for constraint_name in constraint_names:
            if constraint_name in existing_checks:
                op.drop_constraint(constraint_name, table_name, type_="check")
