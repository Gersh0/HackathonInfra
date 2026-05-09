from dataclasses import dataclass


VIDEO_PROCESSING_QUEUE = "video_processing"
ANALYTICS_QUEUE = "analytics"


@dataclass(frozen=True)
class VideoProcessingJob:
    video_id: int


@dataclass(frozen=True)
class VideoViewAnalyticsJob:
    video_id: int
