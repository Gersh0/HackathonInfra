import { createContext, useCallback, useContext, useMemo } from 'react';
import { useQueryClient } from '@tanstack/react-query';

type VideoCacheContextValue = {
  refreshVideos: () => Promise<void>;
};

const VideoCacheContext = createContext<VideoCacheContextValue | undefined>(undefined);

export function VideoCacheProvider({ children }: { children: React.ReactNode }) {
  const queryClient = useQueryClient();

  const loadAll = useCallback(async () => {
    await queryClient.invalidateQueries({ queryKey: ['videos-list'] });
    await queryClient.invalidateQueries({ queryKey: ['subscription-feed'] });
    await queryClient.invalidateQueries({ queryKey: ['recommended'] });
  }, [queryClient]);

  const value = useMemo(() => ({ refreshVideos: loadAll }), [loadAll]);

  return <VideoCacheContext.Provider value={value}>{children}</VideoCacheContext.Provider>;
}

export function useVideoCache() {
  const context = useContext(VideoCacheContext);
  if (!context) {
    throw new Error('useVideoCache must be used within VideoCacheProvider');
  }
  return context;
}
