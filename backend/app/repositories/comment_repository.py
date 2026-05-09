from sqlalchemy import desc, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.comment import Comment


class CommentRepository:
    def __init__(self, db: AsyncSession):
        self.db = db

    async def get_by_video_id(self, video_id: int, limit: int, offset: int) -> list[Comment]:
        stmt = (
            select(Comment)
            .where(Comment.video_id == video_id)
            .order_by(desc(Comment.created_at))
            .limit(limit)
            .offset(offset)
        )
        result = await self.db.execute(stmt)
        return list(result.scalars().all())

    async def count_by_video_id(self, video_id: int) -> int:
        stmt = select(func.count()).select_from(Comment).where(Comment.video_id == video_id)
        result = await self.db.execute(stmt)
        return result.scalar_one()

    async def create(self, video_id: int, author: str, content: str) -> Comment:
        comment = Comment(video_id=video_id, author=author, content=content)
        self.db.add(comment)
        await self.db.commit()
        await self.db.refresh(comment)
        return comment
