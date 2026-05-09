import logging

from sqlalchemy import case, desc, func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.models.video import Video

logger = logging.getLogger(__name__)


class VideoRepository:
    def __init__(self, db: AsyncSession):
        self.db = db

    async def get_all(self, limit: int, offset: int, query: str | None = None) -> list[Video]:
        stmt = select(Video).options(selectinload(Video.uploader))
        if query:
            term = query.strip()
            if term:
                stmt = stmt.where(
                    or_(
                        Video.title.ilike(f"%{term}%"),
                        Video.description.ilike(f"%{term}%"),
                    )
                )
        stmt = stmt.order_by(desc(Video.created_at)).limit(limit).offset(offset)
        result = await self.db.execute(stmt)
        return list(result.scalars().all())

    async def count_all(self, query: str | None = None) -> int:
        stmt = select(func.count()).select_from(Video)
        if query:
            term = query.strip()
            if term:
                stmt = stmt.where(
                    or_(
                        Video.title.ilike(f"%{term}%"),
                        Video.description.ilike(f"%{term}%"),
                    )
                )
        result = await self.db.execute(stmt)
        return result.scalar_one()

    async def get_by_id(self, video_id: int) -> Video | None:
        stmt = select(Video).options(selectinload(Video.uploader)).where(Video.id == video_id)
        result = await self.db.execute(stmt)
        return result.scalars().first()

    async def get_by_uploader_ids(
        self,
        uploader_ids: list[int],
        limit: int,
        offset: int,
        query: str | None = None,
    ) -> list[Video]:
        if not uploader_ids:
            return []
        stmt = (
            select(Video)
            .options(selectinload(Video.uploader))
            .where(Video.uploader_id.in_(uploader_ids))
        )
        if query:
            term = query.strip()
            if term:
                stmt = stmt.where(
                    or_(
                        Video.title.ilike(f"%{term}%"),
                        Video.description.ilike(f"%{term}%"),
                    )
                )
        stmt = stmt.order_by(desc(Video.created_at)).limit(limit).offset(offset)
        result = await self.db.execute(stmt)
        return list(result.scalars().all())

    async def count_by_uploader_ids(self, uploader_ids: list[int], query: str | None = None) -> int:
        if not uploader_ids:
            return 0
        stmt = select(func.count()).select_from(Video).where(Video.uploader_id.in_(uploader_ids))
        if query:
            term = query.strip()
            if term:
                stmt = stmt.where(
                    or_(
                        Video.title.ilike(f"%{term}%"),
                        Video.description.ilike(f"%{term}%"),
                    )
                )
        result = await self.db.execute(stmt)
        return result.scalar_one()

    async def get_recommended_by_title_terms(
        self, exclude_video_id: int, terms: list[str], limit: int
    ) -> list[Video]:
        stmt = (
            select(Video)
            .options(selectinload(Video.uploader))
            .where(Video.id != exclude_video_id)
        )

        if terms:
            conditions = [Video.title.ilike(f"%{term}%") for term in terms]
            relevance_score = sum(
                case((condition, 1), else_=0) for condition in conditions
            )
            stmt = stmt.where(or_(*conditions)).order_by(
                desc(relevance_score), desc(Video.views), desc(Video.created_at)
            )
        else:
            stmt = stmt.order_by(desc(Video.views), desc(Video.created_at))

        stmt = stmt.limit(limit)
        result = await self.db.execute(stmt)
        return list(result.scalars().all())

    async def create(
        self,
        title: str,
        description: str,
        file_path: str,
        thumbnail_path: str | None = None,
        uploader_id: int | None = None,
    ) -> Video:
        video = Video(
            title=title,
            description=description,
            file_path=file_path,
            thumbnail_path=thumbnail_path,
            uploader_id=uploader_id,
        )
        self.db.add(video)
        await self.db.commit()
        # Reload with uploader eagerly to avoid async lazy-load MissingGreenlet in response mapper.
        stmt = select(Video).options(selectinload(Video.uploader)).where(Video.id == video.id)
        result = await self.db.execute(stmt)
        return result.scalars().one()

    async def increment_views(self, video: Video) -> Video:
        """Legacy method - kept for fallback compatibility."""
        video.views += 1
        await self.db.commit()
        await self.db.refresh(video)
        return video

    async def delete(self, video: Video) -> None:
        await self.db.delete(video)
        await self.db.commit()
