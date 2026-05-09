import type { Comment, User, Video } from '../types';

type PaginatedResponse<T> = {
  items: T[];
  limit: number;
  offset: number;
  page_count: number;
  total_count: number;
  next_offset: number | null;
  count?: number;
};

type ListParams = {
  limit?: number;
  offset?: number;
  query?: string;
  signal?: AbortSignal;
};

let authToken: string | null = null;

export function setAuthToken(token: string | null) {
  authToken = token;
}

function withAuth(headers: HeadersInit = {}): HeadersInit {
  if (!authToken) return headers;
  return {
    ...headers,
    Authorization: `Bearer ${authToken}`,
  };
}

const RAW_API_BASE_URL = (import.meta.env.VITE_API_BASE_URL ?? '/api').trim();
const API_BASE_URL = /^https?:\/\//i.test(RAW_API_BASE_URL)
  ? RAW_API_BASE_URL.replace(/\/+$/, '')
  : `/${RAW_API_BASE_URL.replace(/^\/+/, '').replace(/\/+$/, '')}`;

let API_ORIGIN: string;

if (/^https?:\/\//i.test(API_BASE_URL)) {
  const apiBase = new URL(API_BASE_URL);
  API_ORIGIN = `${apiBase.protocol}//${apiBase.host}`;
} else if (typeof window !== 'undefined' && window.location?.origin) {
  API_ORIGIN = window.location.origin;
} else {
  API_ORIGIN = '';
}

export const toAbsoluteApiUrl = (relativeUrl: string) => {
  if (/^https?:\/\//i.test(relativeUrl)) return relativeUrl;

  const normalizedRelative = relativeUrl.startsWith('/') ? relativeUrl : `/${relativeUrl}`;

  if (normalizedRelative.startsWith('/uploads/')) {
    return `${API_ORIGIN}${normalizedRelative}`;
  }

  if (normalizedRelative.startsWith('/api/') && API_BASE_URL.endsWith('/api')) {
    return `${API_ORIGIN}${normalizedRelative}`;
  }

  return `${API_BASE_URL}${normalizedRelative}`;
};
export const toAbsoluteStreamUrl = (streamUrl: string) => toAbsoluteApiUrl(streamUrl);

async function parseListResponse<T>(response: Response): Promise<T[]> {
  const data = (await response.json()) as T[] | PaginatedResponse<T>;
  return Array.isArray(data) ? data : (data.items ?? []);
}

function listQuery(params?: ListParams): string {
  const search = new URLSearchParams();
  if (params?.limit !== undefined) search.set('limit', String(params.limit));
  if (params?.offset !== undefined) search.set('offset', String(params.offset));
  if (params?.query?.trim()) search.set('q', params.query.trim());

  const query = search.toString();
  return query ? `?${query}` : '';
}

export async function fetchVideos(params?: ListParams): Promise<Video[]> {
  const response = await fetch(`${API_BASE_URL}/videos${listQuery(params)}`, {
    signal: params?.signal,
  });
  if (!response.ok) throw new Error('Failed to fetch videos');
  return parseListResponse<Video>(response);
}

export async function fetchSubscriptionFeed(userId: number, params?: ListParams): Promise<Video[]> {
  const response = await fetch(`${API_BASE_URL}/users/${userId}/feed${listQuery(params)}`, {
    signal: params?.signal,
  });
  if (!response.ok) throw new Error('Failed to fetch subscriptions feed');
  return parseListResponse<Video>(response);
}

export async function fetchVideo(videoId: number): Promise<Video> {
  const response = await fetch(`${API_BASE_URL}/videos/${videoId}`);
  if (!response.ok) throw new Error('Failed to fetch video');
  return response.json();
}

export async function deleteVideo(videoId: number): Promise<void> {
  const response = await fetch(`${API_BASE_URL}/videos/${videoId}`, {
    method: 'DELETE',
    headers: withAuth(),
  });
  if (!response.ok) throw new Error('Failed to delete video');
}

export async function uploadVideo(formData: FormData): Promise<Video> {
  const response = await fetch(`${API_BASE_URL}/videos/upload`, {
    method: 'POST',
    headers: withAuth(),
    body: formData,
  });
  if (!response.ok) throw new Error('Failed to upload video');
  return response.json();
}

export async function fetchComments(videoId: number, params?: ListParams): Promise<Comment[]> {
  const response = await fetch(`${API_BASE_URL}/videos/${videoId}/comments${listQuery(params)}`, {
    signal: params?.signal,
  });
  if (!response.ok) throw new Error('Failed to fetch comments');
  return parseListResponse<Comment>(response);
}

export async function addComment(videoId: number, content: string): Promise<Comment> {
  const response = await fetch(`${API_BASE_URL}/videos/${videoId}/comments`, {
    method: 'POST',
    headers: withAuth({
      'Content-Type': 'application/json',
    }),
    body: JSON.stringify({ content }),
  });
  if (!response.ok) throw new Error('Failed to post comment');
  return response.json();
}

export async function fetchRecommended(videoId: number, params?: ListParams): Promise<Video[]> {
  const response = await fetch(`${API_BASE_URL}/videos/${videoId}/recommended${listQuery(params)}`, {
    signal: params?.signal,
  });
  if (!response.ok) throw new Error('Failed to fetch recommended videos');
  return parseListResponse<Video>(response);
}

export async function fetchUsers(params?: ListParams): Promise<User[]> {
  const response = await fetch(`${API_BASE_URL}/users${listQuery(params)}`, {
    signal: params?.signal,
  });
  if (!response.ok) throw new Error('Failed to fetch users');
  return parseListResponse<User>(response);
}

export async function fetchProviders(): Promise<string[]> {
  const response = await fetch(`${API_BASE_URL}/users/providers`);
  if (!response.ok) throw new Error('Failed to fetch providers');
  const data = (await response.json()) as { providers: string[] };
  return data.providers;
}

export async function createUser(formData: FormData): Promise<User> {
  const response = await fetch(`${API_BASE_URL}/users`, {
    method: 'POST',
    body: formData,
  });
  if (!response.ok) throw new Error('Failed to create user');
  return response.json();
}

export async function fetchSubscriptions(userId: number): Promise<number[]> {
  const response = await fetch(`${API_BASE_URL}/users/${userId}/subscriptions`);
  if (!response.ok) throw new Error('Failed to fetch subscriptions');
  const data = (await response.json()) as { creator_ids: number[] };
  return data.creator_ids;
}

export async function subscribeToUser(userId: number, creatorId: number): Promise<void> {
  const response = await fetch(`${API_BASE_URL}/users/${userId}/subscriptions/${creatorId}`, {
    method: 'POST',
    headers: withAuth(),
  });
  if (!response.ok) throw new Error('Failed to subscribe');
}

export async function unsubscribeFromUser(userId: number, creatorId: number): Promise<void> {
  const response = await fetch(`${API_BASE_URL}/users/${userId}/subscriptions/${creatorId}`, {
    method: 'DELETE',
    headers: withAuth(),
  });
  if (!response.ok) throw new Error('Failed to unsubscribe');
}

export async function createAuthToken(userId: number): Promise<string> {
  const response = await fetch(`${API_BASE_URL}/auth/token`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ user_id: userId }),
  });

  if (!response.ok) throw new Error('Failed to create auth token');
  const payload = (await response.json()) as { access_token: string };
  return payload.access_token;
}
