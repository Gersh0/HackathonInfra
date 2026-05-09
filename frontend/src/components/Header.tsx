import { FormEvent, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';

import { toAbsoluteApiUrl } from '../api/client';
import { useUserContext } from '../context/UserContext';
import { useSidebar } from '../context/SidebarContext';
import { useTheme } from '../context/ThemeContext';
import { IconBell, IconMenu, IconMic, IconMoon, IconSearch, IconSun, IconUpload } from './Icons';

export function Header() {
  const { users, currentUserId, setCurrentUserId, currentUser } = useUserContext();
  const { toggle: toggleSidebar } = useSidebar();
  const { theme, toggle: toggleTheme } = useTheme();
  const navigate = useNavigate();
  const [query, setQuery] = useState('');

  const avatarSrc = currentUser?.avatar_url ? toAbsoluteApiUrl(currentUser.avatar_url) : null;
  const initials = currentUser?.display_name.slice(0, 2).toUpperCase() ?? 'YC';

  function handleSearch(e: FormEvent) {
    e.preventDefault();
    if (query.trim()) navigate(`/?q=${encodeURIComponent(query.trim())}`);
  }

  return (
    <header className="header">
      <div className="header-left">
        <button className="menu-btn" onClick={toggleSidebar} aria-label="Toggle sidebar">
          <IconMenu size={22} />
        </button>
        <button className="brand" onClick={() => navigate('/')} aria-label="Home">
          <span className="brand-mark">
            <svg width="14" height="14" viewBox="0 0 24 24" fill="white">
              <path d="M7 4l14 8-14 8z" />
            </svg>
          </span>
          <span className="brand-name">Streamly</span>
          <span className="brand-tld">CLONE</span>
        </button>
      </div>

      <div className="header-center">
        <form className="search" onSubmit={handleSearch} role="search">
          <input
            className="search-input"
            type="search"
            placeholder="Search for anything"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            aria-label="Search"
          />
          <button className="search-btn" type="submit" aria-label="Submit search">
            <IconSearch size={20} />
          </button>
        </form>
        <button className="icon-btn" style={{ marginLeft: 8 }} aria-label="Voice search">
          <IconMic size={20} />
        </button>
      </div>

      <div className="header-right">
        <div className="header-user-select">
          <span>User:</span>
          <select
            value={currentUserId ?? ''}
            onChange={(e) => {
              const next = Number(e.target.value);
              setCurrentUserId(Number.isFinite(next) && next > 0 ? next : null);
            }}
          >
            <option value="">None</option>
            {users.map((u) => (
              <option key={u.id} value={u.id}>{u.display_name}</option>
            ))}
          </select>
        </div>

        <Link to="/upload" className="upload-btn" aria-label="Upload">
          <IconUpload size={18} />
          <span>Upload</span>
        </Link>

        <button className="icon-btn" aria-label="Notifications">
          <IconBell size={20} />
        </button>

        <button className="theme-toggle" onClick={toggleTheme} aria-label="Toggle theme">
          {theme === 'dark' ? <IconSun size={20} /> : <IconMoon size={20} />}
        </button>

        <div className="avatar-btn" aria-label="Account">
          {avatarSrc ? (
            <img src={avatarSrc} alt={currentUser?.display_name} />
          ) : (
            initials
          )}
        </div>
      </div>
    </header>
  );
}
