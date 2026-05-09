from datetime import datetime

from sqlalchemy import CheckConstraint, DateTime, ForeignKey, Integer, String, Text
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.core.database import Base


class Video(Base):
    __tablename__ = "videos"
    __table_args__ = (
        CheckConstraint("views >= 0", name="ck_videos_views_non_negative"),
        CheckConstraint("char_length(btrim(title)) > 0", name="ck_videos_title_not_blank"),
        CheckConstraint("char_length(btrim(file_path)) > 0", name="ck_videos_file_path_not_blank"),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True, index=True)
    title: Mapped[str] = mapped_column(String(255), nullable=False)
    description: Mapped[str] = mapped_column(Text, default="", nullable=False)
    file_path: Mapped[str] = mapped_column(String(500), nullable=False)
    thumbnail_path: Mapped[str | None] = mapped_column(String(500), nullable=True)
    uploader_id: Mapped[int | None] = mapped_column(ForeignKey("users.id"), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow, nullable=False)
    views: Mapped[int] = mapped_column(Integer, default=0, nullable=False)

    comments = relationship("Comment", back_populates="video", cascade="all, delete-orphan")
    uploader = relationship("User", back_populates="uploaded_videos")
