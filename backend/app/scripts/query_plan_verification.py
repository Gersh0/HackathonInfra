import argparse
from datetime import UTC, datetime
from pathlib import Path

from sqlalchemy import text

from app.core.database import SessionLocal


def _collect_plan_lines(sql: str, params: dict[str, int]) -> list[str]:
    with SessionLocal() as db:
        rows = db.execute(text(f"EXPLAIN (ANALYZE, BUFFERS) {sql}"), params).fetchall()
    return [str(row[0]) for row in rows]


def _collect_index_capability_lines(sql: str, params: dict[str, int]) -> list[str]:
    with SessionLocal() as db:
        db.execute(text("SET LOCAL enable_seqscan = off"))
        rows = db.execute(text(f"EXPLAIN (ANALYZE, BUFFERS) {sql}"), params).fetchall()
    return [str(row[0]) for row in rows]


def _uses_index(plan_lines: list[str]) -> bool:
    markers = ("Index Scan", "Bitmap Index Scan", "Bitmap Heap Scan", "Index Only Scan")
    return any(marker in line for line in plan_lines for marker in markers)


def _resolve_context_ids() -> tuple[int, int]:
    with SessionLocal() as db:
        video_row = db.execute(text("SELECT id FROM videos ORDER BY created_at DESC LIMIT 1")).first()
        user_row = db.execute(text("SELECT id FROM users ORDER BY created_at DESC LIMIT 1")).first()

    video_id = int(video_row[0]) if video_row else 1
    user_id = int(user_row[0]) if user_row else 1
    return video_id, user_id


def _format_block(lines: list[str]) -> str:
    return "\n".join(f"    {line}" for line in lines)


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate EXPLAIN verification report for hot list/feed queries")
    parser.add_argument(
        "--output",
        default="docs/query_plan_report.md",
        help="Path (relative to backend/) for markdown report output",
    )
    args = parser.parse_args()

    video_id, user_id = _resolve_context_ids()

    queries: list[tuple[str, str, dict[str, int]]] = [
        (
            "videos_list",
            "SELECT id, title, created_at FROM videos ORDER BY created_at DESC LIMIT 20 OFFSET 0",
            {},
        ),
        (
            "users_list",
            "SELECT id, display_name, created_at FROM users ORDER BY created_at DESC LIMIT 20 OFFSET 0",
            {},
        ),
        (
            "comments_by_video",
            "SELECT id, video_id, created_at FROM comments WHERE video_id = :video_id ORDER BY created_at DESC LIMIT 20 OFFSET 0",
            {"video_id": video_id},
        ),
        (
            "feed_by_subscriptions",
            """
            SELECT v.id, v.uploader_id, v.created_at
            FROM videos AS v
            WHERE v.uploader_id IN (
                SELECT s.creator_id
                FROM subscriptions AS s
                WHERE s.follower_id = :follower_id
                ORDER BY s.created_at DESC
                LIMIT 200
            )
            ORDER BY v.created_at DESC
            LIMIT 20 OFFSET 0
            """,
            {"follower_id": user_id},
        ),
    ]

    generated_at = datetime.now(UTC).isoformat()
    report_lines: list[str] = [
        "# Query Plan Verification Report",
        "",
        f"Generated at: {generated_at}",
        "",
        "Purpose: verify hot list/feed queries with EXPLAIN (ANALYZE, BUFFERS) and confirm index-capable plans.",
        "",
    ]

    index_capable_count = 0

    for name, sql, params in queries:
        default_plan = _collect_plan_lines(sql, params)
        index_capability_plan = _collect_index_capability_lines(sql, params)
        index_capable = _uses_index(index_capability_plan)
        if index_capable:
            index_capable_count += 1

        report_lines.extend(
            [
                f"## {name}",
                "",
                "SQL:",
                "",
                "```sql",
                sql.strip(),
                "```",
                "",
                f"Index-capable plan observed (seqscan disabled): {'yes' if index_capable else 'no'}",
                "",
                "Default plan:",
                "",
                "```text",
                _format_block(default_plan),
                "```",
                "",
                "Index-capability verification plan (SET LOCAL enable_seqscan = off):",
                "",
                "```text",
                _format_block(index_capability_plan),
                "```",
                "",
            ]
        )

    report_lines.extend(
        [
            "## Summary",
            "",
            f"Index-capable queries: {index_capable_count}/{len(queries)}",
            "",
            "Interpretation:",
            "- A query is considered index-capable when its verification plan references index-based operators.",
            "- Default plans remain the source of truth for runtime behavior.",
        ]
    )

    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text("\n".join(report_lines) + "\n", encoding="utf-8")
    print(f"Wrote query plan report to: {output_path}")


if __name__ == "__main__":
    main()
