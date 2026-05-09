import { useState } from 'react';
import { NavLink, useNavigate } from 'react-router-dom';

import {
  IconChevronDown, IconChevronUp, IconFire, IconFlag, IconGaming,
  IconHelp, IconHistory, IconHome, IconLater, IconLearning, IconLibrary,
  IconLiked, IconMusic, IconNews, IconPlaylist, IconSettings, IconShorts,
  IconSports, IconSubs,
} from './Icons';
import { useSidebar } from '../context/SidebarContext';
import { avatarColor } from '../utils/format';

function NavItem({ to, label, icon, exact = false }: { to: string; label: string; icon: React.ReactNode; exact?: boolean }) {
  return (
    <NavLink
      to={to}
      end={exact}
      className={({ isActive }) =>
        isActive ? 'nav-item' : 'nav-item'
      }
      style={({ isActive }) =>
        isActive ? { background: 'var(--bg-active)', fontWeight: 500 } : undefined
      }
    >
      <span className="nav-icon">{icon}</span>
      <span>{label}</span>
    </NavLink>
  );
}

function NavMini({ to, label, icon, exact = false }: { to: string; label: string; icon: React.ReactNode; exact?: boolean }) {
  return (
    <NavLink
      to={to}
      end={exact}
      className="nav-mini"
      style={({ isActive }) =>
        isActive ? { background: 'var(--bg-active)', fontWeight: 500 } : undefined
      }
    >
      {icon}
      <span className="nav-mini-label">{label}</span>
    </NavLink>
  );
}

export function Sidebar() {
  const { mode } = useSidebar();
  const navigate = useNavigate();
  const [showAllSubs, setShowAllSubs] = useState(false);

  if (mode === 'hidden') return null;

  if (mode === 'mini') {
    return (
      <aside className="sidebar sidebar-mini">
        <NavMini to="/" label="Home" icon={<IconHome size={22} />} exact />
        <NavMini to="/subscriptions" label="Subs" icon={<IconSubs size={22} />} />
        <NavMini to="/upload" label="Upload" icon={<IconShorts size={22} />} />
        <NavMini to="/users" label="Users" icon={<IconLibrary size={22} />} />
      </aside>
    );
  }

  return (
    <aside className="sidebar">
      <div className="nav-group">
        <NavItem to="/" label="Home" icon={<IconHome size={22} />} exact />
        <NavItem to="/subscriptions" label="Subscriptions" icon={<IconSubs size={22} />} />
      </div>

      <div className="nav-group">
        <div className="nav-group-title">You</div>
        <NavItem to="/users" label="Users" icon={<IconHistory size={22} />} />
        <button className="nav-item" onClick={() => navigate('/subscriptions')}>
          <span className="nav-icon"><IconPlaylist size={22} /></span>
          <span>Playlists</span>
        </button>
        <button className="nav-item" onClick={() => navigate('/subscriptions')}>
          <span className="nav-icon"><IconLater size={22} /></span>
          <span>Watch later</span>
        </button>
        <button className="nav-item" onClick={() => navigate('/subscriptions')}>
          <span className="nav-icon"><IconLiked size={22} /></span>
          <span>Liked videos</span>
        </button>
      </div>

      <div className="nav-group">
        <div className="nav-group-title">Explore</div>
        <button className="nav-item" onClick={() => navigate('/')}><span className="nav-icon"><IconFire size={22} /></span><span>Trending</span></button>
        <button className="nav-item" onClick={() => navigate('/')}><span className="nav-icon"><IconMusic size={22} /></span><span>Music</span></button>
        <button className="nav-item" onClick={() => navigate('/')}><span className="nav-icon"><IconGaming size={22} /></span><span>Gaming</span></button>
        <button className="nav-item" onClick={() => navigate('/')}><span className="nav-icon"><IconNews size={22} /></span><span>News</span></button>
        <button className="nav-item" onClick={() => navigate('/')}><span className="nav-icon"><IconSports size={22} /></span><span>Sports</span></button>
        <button className="nav-item" onClick={() => navigate('/')}><span className="nav-icon"><IconLearning size={22} /></span><span>Learning</span></button>
      </div>

      <div className="nav-group">
        <button className="nav-item"><span className="nav-icon"><IconSettings size={22} /></span><span>Settings</span></button>
        <button className="nav-item"><span className="nav-icon"><IconFlag size={22} /></span><span>Report history</span></button>
        <button className="nav-item"><span className="nav-icon"><IconHelp size={22} /></span><span>Help</span></button>
      </div>

      <div className="sidebar-footer">
        <div style={{ display: 'flex', flexWrap: 'wrap', gap: '4px 10px', marginBottom: 12 }}>
          <a href="#">About</a>
          <a href="#">Press</a>
          <a href="#">Terms</a>
          <a href="#">Privacy</a>
        </div>
        © 2026 Streamly Clone
      </div>
    </aside>
  );
}
