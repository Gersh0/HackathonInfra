from fastapi import HTTPException

from app.repositories.interfaces import CommentRepositoryPort, VideoRepositoryPort


class CommentService:
    def __init__(self, comment_repo: CommentRepositoryPort, video_repo: VideoRepositoryPort):
        self.comment_repo = comment_repo
        self.video_repo = video_repo

    async def list_comments(self, video_id: int, limit: int, offset: int):
        video = await self.video_repo.get_by_id(video_id)
        if not video:
            raise HTTPException(status_code=404, detail="Video not found")
        return await self.comment_repo.get_by_video_id(video_id=video_id, limit=limit, offset=offset)

    async def count_comments(self, video_id: int) -> int:
        video = await self.video_repo.get_by_id(video_id)
        if not video:
            raise HTTPException(status_code=404, detail="Video not found")
        return await self.comment_repo.count_by_video_id(video_id=video_id)

    async def create_comment(self, video_id: int, author: str, content: str):
        video = await self.video_repo.get_by_id(video_id)
        if not video:
            raise HTTPException(status_code=404, detail="Video not found")
        return await self.comment_repo.create(video_id=video_id, author=author, content=content)
