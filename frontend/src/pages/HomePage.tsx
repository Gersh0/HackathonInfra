import { useMemo, useState } from 'react';
import { useSearchParams } from 'react-router-dom';
import { useInfiniteQuery } from '@tanstack/react-query';

import { fetchVideos } from '../api/client';
import { VideoCard } from '../components/VideoCard';
import { useDebouncedValue } from '../hooks/useDebouncedValue';

const PAGE_SIZE = 20;

const CHIPS = [
  'All', 'Music', 'Mixes', 'Live', 'Programming', 'Cooking',
  'News', 'Camping', 'DIY', 'Lo-fi', 'Gaming', 'Documentary',
  'Reviews', 'Podcasts', 'Comedy', 'Recently uploaded',
];

export function HomePage() {
  const [searchParams] = useSearchParams();
  const urlQuery = searchParams.get('q') ?? '';
  const [chip, setChip] = useState('All');
  const debouncedSearch = useDebouncedValue(urlQuery, 300);

  const videosQuery = useInfiniteQuery({
    queryKey: ['videos-list', debouncedSearch],
    initialPageParam: 0,
    queryFn: ({ pageParam, signal }) =>
      fetchVideos({ limit: PAGE_SIZE, offset: pageParam, query: debouncedSearch, signal }),
    getNextPageParam: (lastPage, allPages) =>
      lastPage.length < PAGE_SIZE ? undefined : allPages.length * PAGE_SIZE,
  });

  const videos = useMemo(
    () => videosQuery.data?.pages.flatMap((page) => page) ?? [],
    [videosQuery.data?.pages]
  );

  if (videosQuery.isLoading) {
    return <p className="status-text">Loading videos...</p>;
  }

  return (
    <div>
      <div className="chips">
        {CHIPS.map((c) => (
          <button key={c} className="chip" data-active={chip === c} onClick={() => setChip(c)}>
            {c}
          </button>
        ))}
      </div>

      <div className="video-grid">
        {videos.map((video) => (
          <VideoCard key={video.id} video={video} />
        ))}
      </div>

      <div style={{ display: 'flex', justifyContent: 'center', padding: '0 24px 40px' }}>
        {videosQuery.hasNextPage ? (
          <button
            type="button"
            className="btn-pill"
            onClick={() => void videosQuery.fetchNextPage()}
          >
            {videosQuery.isFetchingNextPage ? 'Loading more...' : 'Load more videos'}
          </button>
        ) : (
          <p className="status-text">No more videos.</p>
        )}
      </div>
    </div>
  );
}
