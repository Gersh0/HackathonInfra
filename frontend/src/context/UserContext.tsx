import { createContext, useCallback, useContext, useEffect, useMemo, useState } from 'react';

import {
  createAuthToken,
  createUser,
  fetchProviders,
  fetchSubscriptions,
  fetchUsers,
  setAuthToken,
  subscribeToUser,
  unsubscribeFromUser,
} from '../api/client';
import type { User } from '../types';

type CreateUserInput = {
  displayName: string;
  provider: string;
  providerSubject?: string;
  email?: string;
  avatar?: File | null;
};

type UserContextValue = {
  users: User[];
  providers: string[];
  currentUserId: number | null;
  currentUser: User | null;
  subscriptions: number[];
  loading: boolean;
  setCurrentUserId: (userId: number | null) => void;
  refreshUsers: () => Promise<void>;
  createNewUser: (input: CreateUserInput) => Promise<void>;
  isSubscribedTo: (creatorId: number | null | undefined) => boolean;
  subscribe: (creatorId: number) => Promise<void>;
  unsubscribe: (creatorId: number) => Promise<void>;
};

const UserContext = createContext<UserContextValue | undefined>(undefined);

const STORAGE_KEY = 'yt-clone-current-user-id';
const AUTH_STORAGE_KEY = 'yt-clone-auth-token';

export function UserProvider({ children }: { children: React.ReactNode }) {
  const [users, setUsers] = useState<User[]>([]);
  const [providers, setProviders] = useState<string[]>([]);
  const [subscriptions, setSubscriptions] = useState<number[]>([]);
  const [currentUserId, setCurrentUserIdState] = useState<number | null>(() => {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (!raw) return null;
    const parsed = Number(raw);
    return Number.isFinite(parsed) ? parsed : null;
  });
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const existingToken = localStorage.getItem(AUTH_STORAGE_KEY);
    setAuthToken(existingToken);
  }, []);

  const refreshUsers = useCallback(async () => {
    const [fetchedUsers, fetchedProviders] = await Promise.all([
      fetchUsers({ limit: 100, offset: 0 }),
      fetchProviders(),
    ]);
    setUsers(fetchedUsers);
    setProviders(fetchedProviders);

    setCurrentUserIdState((previous) => {
      if (previous !== null && fetchedUsers.some((item) => item.id === previous)) {
        return previous;
      }
      return fetchedUsers[0]?.id ?? null;
    });
  }, []);

  const refreshSubscriptions = useCallback(async () => {
    if (!currentUserId) {
      setSubscriptions([]);
      return;
    }
    const creatorIds = await fetchSubscriptions(currentUserId);
    setSubscriptions(creatorIds);
  }, [currentUserId]);

  useEffect(() => {
    void (async () => {
      try {
        await refreshUsers();
      } finally {
        setLoading(false);
      }
    })();
  }, [refreshUsers]);

  useEffect(() => {
    if (currentUserId === null) {
      localStorage.removeItem(STORAGE_KEY);
      localStorage.removeItem(AUTH_STORAGE_KEY);
      setAuthToken(null);
      setSubscriptions([]);
      return;
    }
    localStorage.setItem(STORAGE_KEY, String(currentUserId));
    void (async () => {
      try {
        const token = await createAuthToken(currentUserId);
        localStorage.setItem(AUTH_STORAGE_KEY, token);
        setAuthToken(token);
      } catch {
        localStorage.removeItem(AUTH_STORAGE_KEY);
        setAuthToken(null);
      }
    })();
    void refreshSubscriptions();
  }, [currentUserId, refreshSubscriptions]);

  const setCurrentUserId = useCallback((userId: number | null) => {
    setCurrentUserIdState(userId);
  }, []);

  const createNewUser = useCallback(
    async (input: CreateUserInput) => {
      const form = new FormData();
      form.append('display_name', input.displayName);
      form.append('provider', input.provider);

      if (input.providerSubject?.trim()) {
        form.append('provider_subject', input.providerSubject.trim());
      }
      if (input.email?.trim()) {
        form.append('email', input.email.trim());
      }
      if (input.avatar) {
        form.append('avatar', input.avatar);
      }

      await createUser(form);
      await refreshUsers();
    },
    [refreshUsers]
  );

  const isSubscribedTo = useCallback(
    (creatorId: number | null | undefined) => {
      if (!creatorId) return false;
      return subscriptions.includes(creatorId);
    },
    [subscriptions]
  );

  const subscribe = useCallback(
    async (creatorId: number) => {
      if (!currentUserId) return;
      await subscribeToUser(currentUserId, creatorId);
      await refreshSubscriptions();
    },
    [currentUserId, refreshSubscriptions]
  );

  const unsubscribe = useCallback(
    async (creatorId: number) => {
      if (!currentUserId) return;
      await unsubscribeFromUser(currentUserId, creatorId);
      await refreshSubscriptions();
    },
    [currentUserId, refreshSubscriptions]
  );

  const currentUser = useMemo(
    () => users.find((user) => user.id === currentUserId) ?? null,
    [users, currentUserId]
  );

  const value = useMemo(
    () => ({
      users,
      providers,
      currentUserId,
      currentUser,
      subscriptions,
      loading,
      setCurrentUserId,
      refreshUsers,
      createNewUser,
      isSubscribedTo,
      subscribe,
      unsubscribe,
    }),
    [
      users,
      providers,
      currentUserId,
      currentUser,
      subscriptions,
      loading,
      setCurrentUserId,
      refreshUsers,
      createNewUser,
      isSubscribedTo,
      subscribe,
      unsubscribe,
    ]
  );

  return <UserContext.Provider value={value}>{children}</UserContext.Provider>;
}

export function useUserContext() {
  const context = useContext(UserContext);
  if (!context) {
    throw new Error('useUserContext must be used within UserProvider');
  }
  return context;
}
