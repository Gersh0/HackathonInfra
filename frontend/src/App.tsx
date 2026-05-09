import { Navigate, Route, Routes } from 'react-router-dom';

import { Header } from './components/Header';
import { Sidebar } from './components/Sidebar';
import { SidebarProvider, useSidebar } from './context/SidebarContext';
import { ThemeProvider } from './context/ThemeContext';
import { HomePage } from './pages/HomePage';
import { SubscriptionsPage } from './pages/SubscriptionsPage';
import { UploadPage } from './pages/UploadPage';
import { UsersPage } from './pages/UsersPage';
import { WatchPage } from './pages/WatchPage';

function Shell() {
  const { mode } = useSidebar();

  return (
    <div className="app">
      <Header />
      <div className="shell" data-sidebar={mode}>
        <Sidebar />
        <main className="content">
          <Routes>
            <Route path="/" element={<HomePage />} />
            <Route path="/subscriptions" element={<SubscriptionsPage />} />
            <Route path="/users" element={<UsersPage />} />
            <Route path="/upload" element={<UploadPage />} />
            <Route path="/watch/:id" element={<WatchPage />} />
            <Route path="*" element={<Navigate to="/" replace />} />
          </Routes>
        </main>
      </div>
    </div>
  );
}

export default function App() {
  return (
    <ThemeProvider>
      <SidebarProvider>
        <Shell />
      </SidebarProvider>
    </ThemeProvider>
  );
}
