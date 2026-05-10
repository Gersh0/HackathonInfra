from pathlib import Path

from fastapi import APIRouter, Depends, File, Form, HTTPException, Query, UploadFile

from app.auth.jwt import require_current_user_id
from app.api.response_mappers import to_user_response, to_video_response
from app.core.settings import settings
from app.dependencies import get_subscription_service, get_user_service
from app.schemas.pagination import PaginatedResponse
from app.schemas.subscription import SubscriptionListResponse, SubscriptionResponse
from app.schemas.user import ProviderListResponse, UserResponse
from app.schemas.video import VideoResponse
from app.services.interfaces import SubscriptionServicePort, UserServicePort

router = APIRouter(prefix="/users", tags=["users"])

UPLOAD_DIR = Path("uploads")


def _page_meta(items: list, offset: int, total_count: int) -> tuple[int, int | None]:
    page_count = len(items)
    next_offset = offset + page_count if offset + page_count < total_count else None
    return page_count, next_offset


@router.get("", response_model=PaginatedResponse[UserResponse], response_model_exclude_unset=True)
async def list_users(
    limit: int = Query(settings.default_page_size, ge=1, le=settings.max_page_size),
    offset: int = Query(0, ge=0),
    q: str | None = Query(None),
    user_service: UserServicePort = Depends(get_user_service),
):
    users = await user_service.list_users(limit=limit, offset=offset, query=q)
    total_count = await user_service.count_users(query=q)
    items = [to_user_response(user) for user in users]
    page_count, next_offset = _page_meta(items, offset, total_count)
    return PaginatedResponse[UserResponse](
        items=items, limit=limit, offset=offset,
        page_count=page_count, total_count=total_count, next_offset=next_offset,
    )


@router.post("", response_model=UserResponse)
async def create_user(
    provider: str = Form("local"),
    display_name: str = Form(...),
    provider_subject: str = Form(""),
    email: str | None = Form(None),
    avatar: UploadFile | None = File(None),
    user_service: UserServicePort = Depends(get_user_service),
):
    user = await user_service.create_user(
        provider_name=provider,
        display_name=display_name,
        provider_subject=provider_subject,
        email=email,
        avatar=avatar,
        upload_dir=UPLOAD_DIR,
    )
    return to_user_response(user)


@router.get("/providers", response_model=ProviderListResponse)
async def list_providers(user_service: UserServicePort = Depends(get_user_service)):
    providers = await user_service.list_providers()
    return ProviderListResponse(providers=providers)


@router.post("/{user_id}/subscriptions/{creator_id}", response_model=SubscriptionResponse)
async def subscribe(
    user_id: int,
    creator_id: int,
    current_user_id: int = Depends(require_current_user_id),
    subscription_service: SubscriptionServicePort = Depends(get_subscription_service),
):
    if current_user_id != user_id:
        raise HTTPException(status_code=403, detail="Token user mismatch")
    return await subscription_service.subscribe(follower_id=user_id, creator_id=creator_id)


@router.delete("/{user_id}/subscriptions/{creator_id}")
async def unsubscribe(
    user_id: int,
    creator_id: int,
    current_user_id: int = Depends(require_current_user_id),
    subscription_service: SubscriptionServicePort = Depends(get_subscription_service),
):
    if current_user_id != user_id:
        raise HTTPException(status_code=403, detail="Token user mismatch")
    await subscription_service.unsubscribe(follower_id=user_id, creator_id=creator_id)
    return {"status": "ok"}


@router.get("/{user_id}/subscriptions", response_model=SubscriptionListResponse)
async def get_subscriptions(
    user_id: int,
    limit: int = Query(settings.default_page_size, ge=1, le=settings.max_page_size),
    offset: int = Query(0, ge=0),
    subscription_service: SubscriptionServicePort = Depends(get_subscription_service),
):
    creator_ids = await subscription_service.list_subscription_creator_ids(
        follower_id=user_id, limit=limit, offset=offset
    )
    return SubscriptionListResponse(creator_ids=creator_ids)


@router.get("/{user_id}/feed", response_model=PaginatedResponse[VideoResponse], response_model_exclude_unset=True)
async def get_subscription_feed(
    user_id: int,
    limit: int = Query(settings.default_page_size, ge=1, le=settings.max_page_size),
    offset: int = Query(0, ge=0),
    q: str | None = Query(None),
    subscription_service: SubscriptionServicePort = Depends(get_subscription_service),
):
    videos = await subscription_service.get_subscription_feed(
        follower_id=user_id, limit=limit, offset=offset, query=q
    )
    total_count = await subscription_service.count_subscription_feed(follower_id=user_id, query=q)
    items = [to_video_response(video) for video in videos]
    page_count, next_offset = _page_meta(items, offset, total_count)
    return PaginatedResponse[VideoResponse](
        items=items, limit=limit, offset=offset,
        page_count=page_count, total_count=total_count, next_offset=next_offset,
    )
