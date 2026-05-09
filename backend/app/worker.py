from datetime import timedelta

from redis import Redis
from rq import Queue, Worker

from app.async_jobs.contracts import ANALYTICS_QUEUE, VIDEO_PROCESSING_QUEUE
from app.async_jobs.jobs import flush_view_counts_to_db, process_analytics_batch
from app.core.settings import settings


def main() -> None:
    redis_connection = Redis.from_url(settings.redis_url)
    queues = [
        Queue(VIDEO_PROCESSING_QUEUE, connection=redis_connection),
        Queue(ANALYTICS_QUEUE, connection=redis_connection),
        Queue("default", connection=redis_connection),
    ]

    # Schedule initial jobs (unique job IDs prevent duplicates from multiple workers/restarts)
    default_queue = Queue("default", connection=redis_connection)

    # Try to schedule view count flush job (will fail silently if already scheduled)
    try:
        default_queue.enqueue_in(
            timedelta(seconds=30),  # Start first flush in 30 seconds
            flush_view_counts_to_db,
            job_timeout=120,  # 2 minute timeout
            job_id="periodic_flush_view_counts"  # Same ID as self-scheduling
        )
    except Exception:
        pass  # Job already scheduled, continue

    # Try to schedule analytics batch processing job
    try:
        default_queue.enqueue_in(
            timedelta(seconds=15),  # Start first batch processing in 15 seconds (offset from view flush)
            process_analytics_batch,
            job_timeout=120,  # 2 minute timeout
            job_id="periodic_process_analytics_batch"  # Same ID as self-scheduling
        )
    except Exception:
        pass  # Job already scheduled, continue

    worker = Worker(queues, connection=redis_connection)
    worker.work(with_scheduler=True)


if __name__ == "__main__":
    main()
