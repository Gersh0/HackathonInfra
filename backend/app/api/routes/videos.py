from pathlib import Path
import mimetypes
from pathlib import PurePosixPath
import time

from fastapi import APIRouter, Depends, File, Form, HTTPException, Query, Response, UploadFile

from app.auth.jwt import require_current_user_id
from app.api.response_mappers import to_video_response
from app.core.settings import settings
from app.dependencies import get_comment_service, get_user_service, get_video_service
from app.schemas.comment import CommentCreate, CommentResponse
from app.schemas.pagination import PaginatedResponse
from app.schemas.video import VideoResponse
from app.services.interfaces import CommentServicePort, UserServicePort, VideoServicePort

router = APIRouter(prefix="/videos", tags=["videos"])

UPLOAD_DIR = Path("uploads")


def _page_meta(items: list, offset: int, total_count: int) -> tuple[int, int | None]:
    page_count = len(items)
    next_offset = offset + page_count if offset + page_count < total_count else None
    return page_count, next_offset


def _to_internal_upload_path(path_value: str) -> str:
    normalized = path_value.replace("\\", "/")
    marker = "uploads/"
    idx = normalized.rfind(marker)
    if idx != -1:
        relative = normalized[idx + len(marker):]
    else:
        relative = Path(normalized).name

    parts = [part for part in PurePosixPath(relative).parts if part not in ("", ".", "..")]
    if not parts:
        raise HTTPException(status_code=404, detail="Media path not found")

    return f"/_protected_uploads/{'/'.join(parts)}"


def _media_accel_response(path_value: str) -> Response:
    internal_path = _to_internal_upload_path(path_value)
    content_type = mimetypes.guess_type(path_value)[0] or "application/octet-stream"
    return Response(
        status_code=200,
        headers={
            "X-Accel-Redirect": internal_path,
            "Content-Type": content_type,
            "Cache-Control": "public, max-age=3600",
        },
    )


@router.get("", response_model=PaginatedResponse[VideoResponse], response_model_exclude_unset=True)
async def get_videos(
    limit: int = Query(settings.default_page_size, ge=1, le=settings.max_page_size),
    offset: int = Query(0, ge=0),
    q: str | None = Query(None),
    video_service: VideoServicePort = Depends(get_video_service),
):
    videos = await video_service.list_videos(limit=limit, offset=offset, query=q)
    total_count = await video_service.count_videos(query=q)
    items = [to_video_response(video) for video in videos]
    page_count, next_offset = _page_meta(items, offset, total_count)
    return PaginatedResponse[VideoResponse](
        items=items, limit=limit, offset=offset,
        page_count=page_count, total_count=total_count, next_offset=next_offset,
    )


@router.post("/upload", response_model=VideoResponse)
async def upload_video(
    title: str = Form(...),
    description: str = Form(""),
    file: UploadFile = File(...),
    thumbnail: UploadFile | None = File(None),
    current_user_id: int = Depends(require_current_user_id),
    video_service: VideoServicePort = Depends(get_video_service),
):
    video = await video_service.upload_video(
        title=title,
        description=description,
        file=file,
        upload_dir=UPLOAD_DIR,
        thumbnail=thumbnail,
        uploader_id=current_user_id,
    )
    return to_video_response(video)


@router.get("/{video_id}", response_model=VideoResponse, response_model_exclude_unset=True)
async def get_video(
    video_id: int,
    response: Response,
    perf: bool = Query(False, description="Include basic route timing headers for profiling"),
    video_service: VideoServicePort = Depends(get_video_service),
):
    t0 = time.perf_counter()
    video = await video_service.get_video_with_view_increment(video_id)
    t1 = time.perf_counter()
    dto = to_video_response(video)
    t2 = time.perf_counter()
    response.headers["Cache-Control"] = "public, max-age=2, stale-while-revalidate=5"
    if perf:
        response.headers["X-Perf-Service-Ms"] = f"{(t1 - t0) * 1000:.2f}"
        response.headers["X-Perf-Serialize-Ms"] = f"{(t2 - t1) * 1000:.2f}"
        response.headers["X-Perf-Total-Ms"] = f"{(t2 - t0) * 1000:.2f}"
    return dto


@router.get("/{video_id}/redis-probe")
async def redis_probe(
    video_id: int,
    response: Response,
    perf: bool = Query(False, description="Include Redis timing headers for profiling"),
    video_service: VideoServicePort = Depends(get_video_service),
):
    t0 = time.perf_counter()
    result = await video_service.probe_video_redis(video_id)
    t1 = time.perf_counter()
    if perf:
        response.headers["X-Perf-Route-Ms"] = f"{(t1 - t0) * 1000:.2f}"
        response.headers["X-Perf-Total-Ms"] = f"{result['total_ms']:.2f}"
        response.headers["X-Perf-View-Incr-Ms"] = f"{result['view_incr_ms']:.2f}"
        response.headers["X-Perf-View-Read-Ms"] = f"{result['view_read_ms']:.2f}"
        response.headers["X-Perf-Analytics-Ms"] = f"{result['analytics_ms']:.2f}"
    return result


@router.get("/{video_id}/stream")
async def stream_video(video_id: int, video_service: VideoServicePort = Depends(get_video_service)):
    video = await video_service.get_video(video_id)
    return _media_accel_response(video.file_path)


@router.get("/{video_id}/thumbnail")
async def stream_video_thumbnail(video_id: int, video_service: VideoServicePort = Depends(get_video_service)):
    video = await video_service.get_video(video_id)
    if not video.thumbnail_path:
        raise HTTPException(status_code=404, detail="Thumbnail not found")
    return _media_accel_response(video.thumbnail_path)


@router.delete("/{video_id}")
async def delete_video(
    video_id: int,
    current_user_id: int = Depends(require_current_user_id),
    video_service: VideoServicePort = Depends(get_video_service),
):
    await video_service.delete_video(video_id=video_id, requester_user_id=current_user_id)
    return {"status": "ok"}


@router.get("/{video_id}/comments", response_model=PaginatedResponse[CommentResponse], response_model_exclude_unset=True)
async def get_comments(
    video_id: int,
    limit: int = Query(settings.default_page_size, ge=1, le=settings.max_page_size),
    offset: int = Query(0, ge=0),
    comment_service: CommentServicePort = Depends(get_comment_service),
):
    items = await comment_service.list_comments(video_id=video_id, limit=limit, offset=offset)
    total_count = await comment_service.count_comments(video_id=video_id)
    page_count, next_offset = _page_meta(items, offset, total_count)
    return PaginatedResponse[CommentResponse](
        items=items, limit=limit, offset=offset,
        page_count=page_count, total_count=total_count, next_offset=next_offset,
    )


@router.post("/{video_id}/comments", response_model=CommentResponse, response_model_exclude_unset=True)
async def post_comment(
    video_id: int,
    payload: CommentCreate,
    current_user_id: int = Depends(require_current_user_id),
    user_service: UserServicePort = Depends(get_user_service),
    comment_service: CommentServicePort = Depends(get_comment_service),
):
    user = await user_service.get_user(current_user_id)
    return await comment_service.create_comment(video_id=video_id, author=user.display_name, content=payload.content)


@router.get("/{video_id}/recommended", response_model=PaginatedResponse[VideoResponse], response_model_exclude_unset=True)
async def get_recommended(
    video_id: int,
    limit: int = Query(8, ge=1, le=settings.max_page_size),
    video_service: VideoServicePort = Depends(get_video_service),
):
    videos = await video_service.get_recommended(video_id=video_id, limit=limit)
    items = [to_video_response(video) for video in videos]
    page_count = len(items)
    return PaginatedResponse[VideoResponse](
        items=items,
        limit=limit,
        offset=0,
        page_count=page_count,
        total_count=page_count,
        next_offset=None,
    )
