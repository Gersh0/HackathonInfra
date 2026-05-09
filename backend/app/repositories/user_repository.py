from sqlalchemy import desc, func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.models.user import User
from app.models.user_identity import UserIdentity


class UserRepository:
    def __init__(self, db: AsyncSession):
        self.db = db

    async def list_users(self, limit: int, offset: int, query: str | None = None) -> list[User]:
        stmt = select(User)
        if query:
            term = query.strip()
            if term:
                stmt = stmt.where(User.display_name.ilike(f"%{term}%"))
        stmt = stmt.order_by(desc(User.created_at)).limit(limit).offset(offset)
        result = await self.db.execute(stmt)
        return list(result.scalars().all())

    async def count_users(self, query: str | None = None) -> int:
        stmt = select(func.count()).select_from(User)
        if query:
            term = query.strip()
            if term:
                stmt = stmt.where(User.display_name.ilike(f"%{term}%"))
        result = await self.db.execute(stmt)
        return result.scalar_one()

    async def get_by_id(self, user_id: int) -> User | None:
        stmt = select(User).where(User.id == user_id)
        result = await self.db.execute(stmt)
        return result.scalars().first()

    async def get_by_provider_subject(self, provider: str, provider_subject: str) -> User | None:
        stmt = (
            select(UserIdentity)
            .options(selectinload(UserIdentity.user))
            .where(
                UserIdentity.provider == provider,
                UserIdentity.provider_subject == provider_subject,
            )
        )
        result = await self.db.execute(stmt)
        identity = result.scalars().first()
        return identity.user if identity else None

    async def create_user(self, display_name: str, avatar_path: str | None = None) -> User:
        user = User(display_name=display_name, avatar_path=avatar_path)
        self.db.add(user)
        await self.db.flush()
        return user

    async def create_identity(
        self,
        user_id: int,
        provider: str,
        provider_subject: str,
        email: str | None = None,
    ) -> UserIdentity:
        identity = UserIdentity(
            user_id=user_id,
            provider=provider,
            provider_subject=provider_subject,
            email=email,
        )
        self.db.add(identity)
        return identity

    async def create_user_with_identity(
        self,
        display_name: str,
        provider: str,
        provider_subject: str,
        avatar_path: str | None = None,
        email: str | None = None,
    ) -> User:
        user = User(display_name=display_name, avatar_path=avatar_path)
        identity = UserIdentity(
            user=user,
            provider=provider,
            provider_subject=provider_subject,
            email=email,
        )
        self.db.add_all([user, identity])
        try:
            await self.db.commit()
        except IntegrityError:
            await self.db.rollback()
            raise
        await self.db.refresh(user)
        return user

    async def commit(self) -> None:
        await self.db.commit()

    async def refresh_user(self, user: User) -> None:
        await self.db.refresh(user)
