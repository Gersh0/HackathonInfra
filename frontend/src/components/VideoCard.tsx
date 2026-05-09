import { memo } from 'react';
import { Link } from 'react-router-dom';

import { toAbsoluteApiUrl } from '../api/client';
import type { Video } from '../types';
import { IconVerified } from './Icons';
import { avatarColor, formatViews, thumbGradient, timeAgo } from '../utils/format';

type VideoCardProps = {
  video: Video;
};

function ThumbArt({ id, title }: { id: number; title: string }) {
  const bg = thumbGradient(id);
  const initials = title.slice(0, 2).toUpperCase();
  return (
    <div className="thumb-art" style={{ background: bg }}>
      <div className="thumb-art-glyph">{initials}</div>
    </div>
  );
}

export const VideoCard = memo(function VideoCard({ video }: VideoCardProps) {
  const thumbnailSrc = video.thumbnail_url ? toAbsoluteApiUrl(video.thumbnail_url) : null;
  const avatarSrc = video.uploader?.avatar_url ? toAbsoluteApiUrl(video.uploader.avatar_url) : null;
  const uploaderName = video.uploader?.display_name ?? 'Unknown';
  const color = avatarColor(uploaderName);

  return (
    <Link to={`/watch/${video.id}`} className="vcard">
      <div className="vcard-thumb">
        {thumbnailSrc ? (
          <img src={thumbnailSrc} alt={`${video.title} thumbnail`} loading="lazy" />
        ) : (
          <ThumbArt id={video.id} title={video.title} />
        )}
      </div>
      <div className="vcard-meta">
        <div
          className="vcard-avatar"
          style={{ background: color + '33', color }}
        >
          {avatarSrc ? (
            <img src={avatarSrc} alt={uploaderName} loading="lazy" />
          ) : (
            uploaderName.slice(0, 1).toUpperCase()
          )}
        </div>
        <div className="vcard-text">
          <h3 className="vcard-title">{video.title}</h3>
          <div className="vcard-channel">
            {uploaderName}
          </div>
          <div className="vcard-stats">
            {formatViews(video.views)}
            <span className="dot" />
            {timeAgo(video.created_at)}
          </div>
        </div>
      </div>
    </Link>
  );
});
