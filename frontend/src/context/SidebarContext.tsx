import { createContext, ReactNode, useContext, useState } from 'react';

type SidebarMode = 'full' | 'mini' | 'hidden';

type SidebarContextValue = {
  mode: SidebarMode;
  setMode: (m: SidebarMode) => void;
  toggle: () => void;
};

const SidebarContext = createContext<SidebarContextValue>({
  mode: 'full',
  setMode: () => {},
  toggle: () => {},
});

export function SidebarProvider({ children }: { children: ReactNode }) {
  const [mode, setMode] = useState<SidebarMode>('full');

  function toggle() {
    setMode((m) => (m === 'full' ? 'mini' : m === 'mini' ? 'hidden' : 'full'));
  }

  return (
    <SidebarContext.Provider value={{ mode, setMode, toggle }}>
      {children}
    </SidebarContext.Provider>
  );
}

export function useSidebar() {
  return useContext(SidebarContext);
}
