import random
import time

from redis import Redis
from redis.exceptions import RedisError
from rq import Queue

from app.async_jobs.contracts import ANALYTICS_QUEUE, VIDEO_PROCESSING_QUEUE, VideoProcessingJob
from app.async_jobs.jobs import process_video_upload
from app.core.settings import settings


class JobDispatcher:
    def __init__(self, redis_url: str):
        self.redis = Redis.from_url(redis_url)
        self.video_queue = Queue(VIDEO_PROCESSING_QUEUE, connection=self.redis)
        self.analytics_queue = Queue(ANALYTICS_QUEUE, connection=self.redis)

    def enqueue_video_processing(self, video_id: int) -> str:
        payload = VideoProcessingJob(video_id=video_id)
        job = self._enqueue_with_retry(self.video_queue, process_video_upload, payload.video_id)
        return job.id

    def queue_depths(self) -> dict[str, int]:
        return {
            VIDEO_PROCESSING_QUEUE: self.video_queue.count,
            ANALYTICS_QUEUE: self.analytics_queue.count,
        }

    def _enqueue_with_retry(self, queue: Queue, func, *args):
        attempts = max(1, settings.enqueue_retry_attempts)
        base_delay = max(0.0, settings.enqueue_retry_base_delay_seconds)
        last_error: RedisError | None = None

        for attempt in range(1, attempts + 1):
            try:
                return queue.enqueue(func, *args)
            except RedisError as exc:
                last_error = exc
                if attempt >= attempts:
                    break

                delay = base_delay * (2 ** (attempt - 1))
                jitter = random.uniform(0, base_delay) if base_delay > 0 else 0.0
                time.sleep(delay + jitter)

        if last_error is not None:
            raise last_error
        raise RuntimeError("enqueue failed without RedisError")


job_dispatcher = JobDispatcher(settings.redis_url)
