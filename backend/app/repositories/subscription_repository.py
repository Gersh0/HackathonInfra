from sqlalchemy import desc, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.subscription import Subscription


class SubscriptionRepository:
    def __init__(self, db: AsyncSession):
        self.db = db

    async def get_by_pair(self, follower_id: int, creator_id: int) -> Subscription | None:
        stmt = select(Subscription).where(
            Subscription.follower_id == follower_id,
            Subscription.creator_id == creator_id,
        )
        result = await self.db.execute(stmt)
        return result.scalars().first()

    async def list_creator_ids(self, follower_id: int, limit: int, offset: int) -> list[int]:
        stmt = (
            select(Subscription)
            .where(Subscription.follower_id == follower_id)
            .order_by(desc(Subscription.created_at))
            .limit(limit)
            .offset(offset)
        )
        result = await self.db.execute(stmt)
        return [item.creator_id for item in result.scalars().all()]

    async def list_all_creator_ids(self, follower_id: int) -> list[int]:
        stmt = (
            select(Subscription)
            .where(Subscription.follower_id == follower_id)
            .order_by(desc(Subscription.created_at))
        )
        result = await self.db.execute(stmt)
        return [item.creator_id for item in result.scalars().all()]

    async def create(self, follower_id: int, creator_id: int) -> Subscription:
        subscription = Subscription(follower_id=follower_id, creator_id=creator_id)
        self.db.add(subscription)
        try:
            await self.db.commit()
            await self.db.refresh(subscription)
            return subscription
        except IntegrityError:
            await self.db.rollback()
            existing = await self.get_by_pair(follower_id=follower_id, creator_id=creator_id)
            if existing is not None:
                return existing
            raise

    async def delete(self, subscription: Subscription) -> None:
        await self.db.delete(subscription)
        await self.db.commit()
