import React from 'react';
import ReactDOM from 'react-dom/client';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { BrowserRouter } from 'react-router-dom';

import App from './App';
import { UserProvider } from './context/UserContext';
import { VideoCacheProvider } from './context/VideoCacheContext';
import './styles.css';

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 30_000,
      gcTime: 5 * 60_000,
      refetchOnWindowFocus: false,
      refetchOnReconnect: true,
      retry: 1,
    },
  },
});

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <QueryClientProvider client={queryClient}>
      <UserProvider>
        <VideoCacheProvider>
          <BrowserRouter>
            <App />
          </BrowserRouter>
        </VideoCacheProvider>
      </UserProvider>
    </QueryClientProvider>
  </React.StrictMode>
);
