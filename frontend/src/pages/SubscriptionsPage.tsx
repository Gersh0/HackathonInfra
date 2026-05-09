import { useMemo } from 'react';
import { useInfiniteQuery } from '@tanstack/react-query';

import { fetchSubscriptionFeed } from '../api/client';
import { VideoCard } from '../components/VideoCard';
import { useUserContext } from '../context/UserContext';

const PAGE_SIZE = 20;

export function SubscriptionsPage() {
  const { currentUser } = useUserContext();

  const feedQuery = useInfiniteQuery({
    queryKey: ['subscription-feed', currentUser?.id],
    initialPageParam: 0,
    queryFn: ({ pageParam, signal }) =>
      fetchSubscriptionFeed(currentUser!.id, { limit: PAGE_SIZE, offset: pageParam, signal }),
    getNextPageParam: (lastPage, allPages) =>
      lastPage.length < PAGE_SIZE ? undefined : allPages.length * PAGE_SIZE,
    enabled: !!currentUser,
  });

  const videos = useMemo(
    () => feedQuery.data?.pages.flatMap((page) => page) ?? [],
    [feedQuery.data?.pages]
  );

  if (!currentUser) {
    return (
      <div className="section">
        <div className="empty">
          <div className="empty-title">No user selected</div>
          Choose a user in the header to see your subscription feed.
        </div>
      </div>
    );
  }

  if (feedQuery.isLoading) {
    return <p className="status-text">Loading subscriptions feed...</p>;
  }

  if (videos.length === 0) {
    return (
      <div className="section">
        <div className="empty">
          <div className="empty-title">Nothing here yet</div>
          Subscribe to channels and upload videos to populate your feed.
        </div>
      </div>
    );
  }

  return (
    <div className="section">
      <h2 className="section-title">
        Latest from your subscriptions
        <span className="section-title-rail" />
      </h2>

      <div className="video-grid" style={{ padding: 0 }}>
        {videos.map((video) => (
          <VideoCard key={video.id} video={video} />
        ))}
      </div>

      <div style={{ display: 'flex', justifyContent: 'center', marginTop: 32 }}>
        {feedQuery.hasNextPage ? (
          <button className="btn-pill" onClick={() => void feedQuery.fetchNextPage()}>
            {feedQuery.isFetchingNextPage ? 'Loading more...' : 'Load more'}
          </button>
        ) : (
          <p className="status-text">All caught up.</p>
        )}
      </div>
    </div>
  );
}
