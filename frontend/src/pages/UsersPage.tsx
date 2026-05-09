import { FormEvent, useMemo, useState } from 'react';
import { useInfiniteQuery, useQueryClient } from '@tanstack/react-query';

import { fetchUsers, toAbsoluteApiUrl } from '../api/client';
import { useDebouncedValue } from '../hooks/useDebouncedValue';
import { useUserContext } from '../context/UserContext';

const PAGE_SIZE = 20;

export function UsersPage() {
  const queryClient = useQueryClient();
  const {
    providers,
    currentUserId,
    setCurrentUserId,
    createNewUser,
    isSubscribedTo,
    subscribe,
    unsubscribe,
  } = useUserContext();

  const [displayName, setDisplayName] = useState('');
  const [provider, setProvider] = useState('local');
  const [providerSubject, setProviderSubject] = useState('');
  const [email, setEmail] = useState('');
  const [avatar, setAvatar] = useState<File | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const [search, setSearch] = useState('');
  const debouncedSearch = useDebouncedValue(search, 300);

  const usersQuery = useInfiniteQuery({
    queryKey: ['users-list', debouncedSearch],
    initialPageParam: 0,
    queryFn: ({ pageParam, signal }) =>
      fetchUsers({ limit: PAGE_SIZE, offset: pageParam, query: debouncedSearch, signal }),
    getNextPageParam: (lastPage, allPages) =>
      lastPage.length < PAGE_SIZE ? undefined : allPages.length * PAGE_SIZE,
  });

  const users = useMemo(
    () => usersQuery.data?.pages.flatMap((page) => page) ?? [],
    [usersQuery.data?.pages]
  );

  const handleSubmit = async (event: FormEvent) => {
    event.preventDefault();
    if (!displayName.trim()) return;

    setSaving(true);
    setError(null);
    try {
      await createNewUser({
        displayName: displayName.trim(),
        provider,
        providerSubject,
        email,
        avatar,
      });
      await queryClient.invalidateQueries({ queryKey: ['users-list'] });
      setDisplayName('');
      setProviderSubject('');
      setEmail('');
      setAvatar(null);
    } catch {
      setError('Could not create user. Check provider subject uniqueness and input values.');
    } finally {
      setSaving(false);
    }
  };

  return (
    <main className="users-main">
      <section className="upload-panel">
        <h1 style={{ margin: '0 0 16px', fontSize: '1.35rem', color: 'var(--fg)' }}>Create user</h1>
        <form onSubmit={handleSubmit} className="upload-form">
          <input value={displayName} onChange={(e) => setDisplayName(e.target.value)} placeholder="Display name" required />

          <select value={provider} onChange={(e) => setProvider(e.target.value)}>
            {providers.map((providerName) => (
              <option key={providerName} value={providerName}>{providerName}</option>
            ))}
          </select>

          <input
            value={providerSubject}
            onChange={(e) => setProviderSubject(e.target.value)}
            placeholder="Provider subject (optional for local)"
          />

          <input value={email} onChange={(e) => setEmail(e.target.value)} placeholder="Email (optional)" type="email" />

          <input type="file" accept="image/*" onChange={(e) => setAvatar(e.target.files?.[0] ?? null)} />

          <button type="submit" className="form-btn" disabled={saving}>
            {saving ? 'Creating...' : 'Create user'}
          </button>
        </form>
        {error ? <p className="error-text">{error}</p> : null}
      </section>

      <section className="upload-panel">
        <h2 style={{ margin: '0 0 16px', color: 'var(--fg)' }}>Users</h2>
        <input
          value={search}
          onChange={(event) => setSearch(event.target.value)}
          placeholder="Search users"
          style={{ marginBottom: 16 }}
        />
        <div className="user-list">
          {users.map((user) => {
            const avatarUrl = user.avatar_url ? toAbsoluteApiUrl(user.avatar_url) : null;
            const subscribed = isSubscribedTo(user.id);
            const canSubscribe = currentUserId !== null && currentUserId !== user.id;
            const isCurrent = currentUserId === user.id;

            return (
              <article key={user.id} className="user-row">
                <div className="user-row-left">
                  <div
                    className="vcard-avatar"
                    style={{ width: 40, height: 40, fontSize: 15, background: 'var(--bg-elev-2)', color: 'var(--fg)' }}
                  >
                    {avatarUrl ? (
                      <img src={avatarUrl} alt={user.display_name} style={{ width: '100%', height: '100%', objectFit: 'cover' }} />
                    ) : (
                      user.display_name.slice(0, 2).toUpperCase()
                    )}
                  </div>
                  <div>
                    <strong style={{ color: 'var(--fg)' }}>
                      {user.display_name}
                      {isCurrent && <span style={{ marginLeft: 8, fontSize: 12, color: 'var(--accent)', fontWeight: 500 }}>current</span>}
                    </strong>
                    <p>User #{user.id}</p>
                  </div>
                </div>
                <div className="user-row-actions">
                  <button type="button" className="btn-pill" onClick={() => setCurrentUserId(user.id)}>
                    Use
                  </button>
                  {canSubscribe && (
                    <button
                      type="button"
                      className="btn-subscribe"
                      data-subscribed={subscribed}
                      style={{ margin: 0 }}
                      onClick={() => void (subscribed ? unsubscribe(user.id) : subscribe(user.id))}
                    >
                      {subscribed ? 'Subscribed' : 'Subscribe'}
                    </button>
                  )}
                </div>
              </article>
            );
          })}
        </div>

        <div style={{ display: 'flex', justifyContent: 'center', marginTop: 24 }}>
          {usersQuery.hasNextPage ? (
            <button type="button" className="btn-pill" onClick={() => void usersQuery.fetchNextPage()}>
              {usersQuery.isFetchingNextPage ? 'Loading...' : 'Load more'}
            </button>
          ) : (
            <p className="status-text">No more users.</p>
          )}
        </div>
      </section>
    </main>
  );
}
