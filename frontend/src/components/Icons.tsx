import { SVGProps } from 'react';

type IconProps = SVGProps<SVGSVGElement> & { size?: number };

function Icon({ size = 24, children, fill = 'none', stroke = 'currentColor', ...rest }: IconProps & { children: React.ReactNode }) {
  return (
    <svg
      xmlns="http://www.w3.org/2000/svg"
      width={size} height={size}
      viewBox="0 0 24 24"
      fill={fill}
      stroke={stroke}
      strokeWidth={2}
      strokeLinecap="round"
      strokeLinejoin="round"
      {...rest}
    >
      {children}
    </svg>
  );
}

export const IconMenu = (p: IconProps) => <Icon {...p}><line x1="3" y1="6" x2="21" y2="6"/><line x1="3" y1="12" x2="21" y2="12"/><line x1="3" y1="18" x2="21" y2="18"/></Icon>;
export const IconSearch = (p: IconProps) => <Icon {...p}><circle cx="11" cy="11" r="7"/><line x1="21" y1="21" x2="16.65" y2="16.65"/></Icon>;
export const IconMic = (p: IconProps) => <Icon {...p}><rect x="9" y="3" width="6" height="12" rx="3"/><path d="M5 11a7 7 0 0 0 14 0"/><line x1="12" y1="18" x2="12" y2="22"/></Icon>;
export const IconUpload = (p: IconProps) => <Icon {...p}><path d="M12 4v12"/><path d="M6 10l6-6 6 6"/><path d="M4 20h16"/></Icon>;
export const IconBell = (p: IconProps) => <Icon {...p}><path d="M6 8a6 6 0 0 1 12 0c0 7 3 9 3 9H3s3-2 3-9"/><path d="M10.3 21a1.94 1.94 0 0 0 3.4 0"/></Icon>;
export const IconSun = (p: IconProps) => <Icon {...p}><circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.93 4.93l1.41 1.41M17.66 17.66l1.41 1.41M2 12h2M20 12h2M4.93 19.07l1.41-1.41M17.66 6.34l1.41-1.41"/></Icon>;
export const IconMoon = (p: IconProps) => <Icon {...p}><path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z"/></Icon>;
export const IconHome = (p: IconProps) => <Icon {...p}><path d="M3 11l9-8 9 8"/><path d="M5 10v10h14V10"/></Icon>;
export const IconShorts = (p: IconProps) => <Icon {...p}><rect x="6" y="3" width="12" height="18" rx="3"/><path d="M10 9l5 3-5 3z" fill="currentColor" stroke="none"/></Icon>;
export const IconSubs = (p: IconProps) => <Icon {...p}><rect x="3" y="6" width="18" height="14" rx="2"/><path d="M7 3l5 3 5-3"/></Icon>;
export const IconLibrary = (p: IconProps) => <Icon {...p}><rect x="3" y="4" width="4" height="16" rx="1"/><rect x="10" y="4" width="4" height="16" rx="1"/><path d="M17 5l4 14"/></Icon>;
export const IconHistory = (p: IconProps) => <Icon {...p}><circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/></Icon>;
export const IconLater = (p: IconProps) => <Icon {...p}><circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/><path d="M3 12h2"/></Icon>;
export const IconLiked = (p: IconProps) => <Icon {...p}><path d="M7 11V21H4a1 1 0 0 1-1-1v-8a1 1 0 0 1 1-1h3z"/><path d="M7 11l4-7a2 2 0 0 1 4 0v5h5a2 2 0 0 1 2 2l-2 8a2 2 0 0 1-2 2H7"/></Icon>;
export const IconPlaylist = (p: IconProps) => <Icon {...p}><line x1="3" y1="6" x2="14" y2="6"/><line x1="3" y1="12" x2="14" y2="12"/><line x1="3" y1="18" x2="10" y2="18"/><path d="M16 14l6 4-6 4z" fill="currentColor" stroke="none"/></Icon>;
export const IconFire = (p: IconProps) => <Icon {...p}><path d="M12 22a7 7 0 0 0 7-7c0-3-2-5-3-7-2 2-4 1-4-2 0-2 1-4 1-4S6 7 6 14a6 6 0 0 0 6 8z"/></Icon>;
export const IconMusic = (p: IconProps) => <Icon {...p}><path d="M9 18V5l12-2v13"/><circle cx="6" cy="18" r="3"/><circle cx="18" cy="16" r="3"/></Icon>;
export const IconGaming = (p: IconProps) => <Icon {...p}><rect x="2" y="8" width="20" height="10" rx="3"/><line x1="7" y1="13" x2="9" y2="13"/><line x1="8" y1="12" x2="8" y2="14"/><circle cx="15" cy="12" r="1" fill="currentColor" stroke="none"/><circle cx="17" cy="14" r="1" fill="currentColor" stroke="none"/></Icon>;
export const IconNews = (p: IconProps) => <Icon {...p}><rect x="3" y="4" width="18" height="16" rx="2"/><line x1="7" y1="9" x2="17" y2="9"/><line x1="7" y1="13" x2="17" y2="13"/><line x1="7" y1="17" x2="13" y2="17"/></Icon>;
export const IconSports = (p: IconProps) => <Icon {...p}><circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3a14 14 0 0 1 0 18M12 3a14 14 0 0 0 0 18"/></Icon>;
export const IconLearning = (p: IconProps) => <Icon {...p}><path d="M2 8l10-5 10 5-10 5z"/><path d="M6 10v6a6 6 0 0 0 12 0v-6"/></Icon>;
export const IconSettings = (p: IconProps) => <Icon {...p}><circle cx="12" cy="12" r="3"/><path d="M19 12a7 7 0 0 0-.1-1.2l2-1.5-2-3.5-2.4.8a7 7 0 0 0-2.1-1.2L14 3h-4l-.4 2.4a7 7 0 0 0-2.1 1.2L5.1 5.8l-2 3.5 2 1.5A7 7 0 0 0 5 12a7 7 0 0 0 .1 1.2l-2 1.5 2 3.5 2.4-.8a7 7 0 0 0 2.1 1.2L10 21h4l.4-2.4a7 7 0 0 0 2.1-1.2l2.4.8 2-3.5-2-1.5A7 7 0 0 0 19 12z"/></Icon>;
export const IconFlag = (p: IconProps) => <Icon {...p}><path d="M4 21V4h12l-2 4 2 4H4"/></Icon>;
export const IconHelp = (p: IconProps) => <Icon {...p}><circle cx="12" cy="12" r="9"/><path d="M9.5 9a2.5 2.5 0 0 1 5 0c0 1.5-2.5 2-2.5 4"/><line x1="12" y1="17" x2="12.01" y2="17"/></Icon>;
export const IconLike = (p: IconProps) => <Icon {...p}><path d="M7 11V21H4a1 1 0 0 1-1-1v-8a1 1 0 0 1 1-1h3z"/><path d="M7 11l4-7a2 2 0 0 1 4 0v5h5a2 2 0 0 1 2 2l-2 8a2 2 0 0 1-2 2H7"/></Icon>;
export const IconDislike = (p: IconProps) => <Icon {...p} style={{ transform: 'rotate(180deg)', ...p.style }}><path d="M7 11V21H4a1 1 0 0 1-1-1v-8a1 1 0 0 1 1-1h3z"/><path d="M7 11l4-7a2 2 0 0 1 4 0v5h5a2 2 0 0 1 2 2l-2 8a2 2 0 0 1-2 2H7"/></Icon>;
export const IconShare = (p: IconProps) => <Icon {...p}><path d="M4 12v8a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-8"/><polyline points="16 6 12 2 8 6"/><line x1="12" y1="2" x2="12" y2="15"/></Icon>;
export const IconDownload = (p: IconProps) => <Icon {...p}><path d="M4 12v8a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-8"/><polyline points="8 12 12 16 16 12"/><line x1="12" y1="2" x2="12" y2="16"/></Icon>;
export const IconBookmark = (p: IconProps) => <Icon {...p}><path d="M5 3h14v18l-7-5-7 5z"/></Icon>;
export const IconMore = (p: IconProps) => <Icon {...p}><circle cx="5" cy="12" r="1.5" fill="currentColor" stroke="none"/><circle cx="12" cy="12" r="1.5" fill="currentColor" stroke="none"/><circle cx="19" cy="12" r="1.5" fill="currentColor" stroke="none"/></Icon>;
export const IconChevronDown = (p: IconProps) => <Icon {...p}><polyline points="6 9 12 15 18 9"/></Icon>;
export const IconChevronUp = (p: IconProps) => <Icon {...p}><polyline points="18 15 12 9 6 15"/></Icon>;
export const IconChevronRight = (p: IconProps) => <Icon {...p}><polyline points="9 18 15 12 9 6"/></Icon>;
export const IconVerified = (p: IconProps) => (
  <svg xmlns="http://www.w3.org/2000/svg" width={p.size ?? 14} height={p.size ?? 14} viewBox="0 0 24 24" fill="currentColor" stroke="none">
    <path d="M12 2l2.4 2 3.1-.4.4 3.1L20 9l-2 2.5L20 14l-2.1 2.3-.4 3.1-3.1-.4L12 21l-2.4-2-3.1.4-.4-3.1L4 14l2-2.5L4 9l2.1-2.3.4-3.1 3.1.4z"/>
    <polyline points="9 12 11 14 15 10" stroke="white" strokeWidth="2" fill="none"/>
  </svg>
);
export const IconScissor = (p: IconProps) => <Icon {...p}><circle cx="6" cy="6" r="3"/><circle cx="6" cy="18" r="3"/><line x1="20" y1="4" x2="8.12" y2="15.88"/><line x1="14.47" y1="14.48" x2="20" y2="20"/><line x1="8.12" y1="8.12" x2="12" y2="12"/></Icon>;
export const IconRemix = (p: IconProps) => <Icon {...p}><path d="M16 3l5 5-5 5M21 8H10a5 5 0 0 0-5 5v8"/></Icon>;
