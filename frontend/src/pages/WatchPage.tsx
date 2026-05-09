import { FormEvent, useEffect, useMemo, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';

import { addComment, deleteVideo, fetchComments, fetchRecommended, fetchVideo, toAbsoluteApiUrl, toAbsoluteStreamUrl } from '../api/client';
import { useUserContext } from '../context/UserContext';
import { useVideoCache } from '../context/VideoCacheContext';
import { IconBookmark, IconDislike, IconDownload, IconLike, IconMore, IconRemix, IconScissor, IconShare, IconVerified } from '../components/Icons';
import { avatarColor, formatViews, thumbGradient, timeAgo } from '../utils/format';

export function WatchPage() {
  const { id } = useParams();
  const videoId = Number(id);
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const { refreshVideos } = useVideoCache();
  const { currentUser, isSubscribedTo, subscribe, unsubscribe } = useUserContext();
  const [content, setContent] = useState('');
  const [composeFocus, setComposeFocus] = useState(false);
  const [liked, setLiked] = useState(false);
  const [disliked, setDisliked] = useState(false);
  const [descExpanded, setDescExpanded] = useState(false);
  const [suggestTab, setSuggestTab] = useState('All');

  const videoQuery = useQuery({
    queryKey: ['video', videoId],
    queryFn: () => fetchVideo(videoId),
    enabled: Number.isFinite(videoId),
  });

  const commentsQuery = useQuery({
    queryKey: ['comments', videoId],
    queryFn: () => fetchComments(videoId),
    enabled: Number.isFinite(videoId),
  });

  const recommendedQuery = useQuery({
    queryKey: ['recommended', videoId],
    queryFn: () => fetchRecommended(videoId),
    enabled: Number.isFinite(videoId),
  });

  const commentMutation = useMutation({
    mutationFn: () => addComment(videoId, content),
    onSuccess: async () => {
      setContent('');
      setComposeFocus(false);
      await queryClient.invalidateQueries({ queryKey: ['comments', videoId] });
    },
  });

  const deleteMutation = useMutation({
    mutationFn: async () => {
      if (!currentUser) throw new Error('Current user required');
      await deleteVideo(videoId);
    },
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: ['video', videoId] });
      await refreshVideos();
      navigate('/');
    },
  });

  const streamSrc = useMemo(() => {
    if (!videoQuery.data) return '';
    return toAbsoluteStreamUrl(videoQuery.data.stream_url);
  }, [videoQuery.data]);

  const uploaderId = videoQuery.data?.uploader?.id ?? null;
  const showSubscribeButton = !!currentUser && uploaderId !== null && uploaderId !== currentUser.id;
  const isOwner = !!currentUser && uploaderId !== null && uploaderId === currentUser.id;
  const subscribed = isSubscribedTo(uploaderId);
  const uploaderName = videoQuery.data?.uploader?.display_name ?? 'Unknown';
  const uploaderColor = avatarColor(uploaderName);
  const userColor = avatarColor(currentUser?.display_name ?? 'User');

  if (videoQuery.isLoading) return <p className="status-text">Loading video...</p>;
  if (!videoQuery.data) return <p className="status-text">Video not found.</p>;

  const video = videoQuery.data;

  const handleSubmit = async (event: FormEvent) => {
    event.preventDefault();
    if (!content.trim()) return;
    await commentMutation.mutateAsync();
  };

  return (
    <div className="watch">
      <div className="watch-main">
        <div className="player-wrap">
          <video src={streamSrc} controls />
        </div>

        <h1 className="watch-title">{video.title}</h1>

        <div className="watch-meta-row">
          <div className="watch-channel">
            <div
              className="vcard-avatar"
              style={{ width: 40, height: 40, fontSize: 16, background: uploaderColor + '33', color: uploaderColor, flexShrink: 0 }}
            >
              {uploaderName.slice(0, 1).toUpperCase()}
            </div>
            <div className="watch-channel-info">
              <span className="watch-channel-name">{uploaderName}</span>
              <span className="watch-channel-subs">{formatViews(video.views).replace(' views', '')} subscribers</span>
            </div>
            {showSubscribeButton && (
              <button
                className="btn-subscribe"
                data-subscribed={subscribed}
                onClick={() => void (subscribed ? unsubscribe(uploaderId!) : subscribe(uploaderId!))}
              >
                {subscribed ? 'Subscribed' : 'Subscribe'}
              </button>
            )}
          </div>

          <div className="watch-actions">
            <div className="like-group">
              <button
                className="watch-action"
                onClick={() => { setLiked((l) => !l); if (disliked) setDisliked(false); }}
                style={liked ? { color: 'var(--accent)' } : undefined}
              >
                <IconLike size={18} /> {liked ? 'Liked' : 'Like'}
              </button>
              <button
                className="watch-action"
                onClick={() => { setDisliked((d) => !d); if (liked) setLiked(false); }}
                style={disliked ? { color: 'var(--accent)' } : undefined}
              >
                <IconDislike size={18} />
              </button>
            </div>
            <button className="watch-action"><IconShare size={18} /> Share</button>
            <button className="watch-action"><IconDownload size={18} /> Download</button>
            <button className="watch-action"><IconBookmark size={18} /> Save</button>
            {isOwner && (
              <button
                className="watch-action"
                style={{ background: '#b3261e22', color: '#b3261e' }}
                onClick={() => void deleteMutation.mutateAsync()}
              >
                {deleteMutation.isPending ? 'Deleting...' : 'Delete'}
              </button>
            )}
            <button className="watch-action" style={{ padding: '0 10px' }}><IconMore size={18} /></button>
          </div>
        </div>

        <div
          className="watch-description"
          data-expanded={descExpanded}
          onClick={() => setDescExpanded((e) => !e)}
        >
          <div className="watch-description-stats">
            {video.views.toLocaleString()} views · {timeAgo(video.created_at)}
          </div>
          <div className="watch-description-body">
            {video.description || 'No description provided.'}
          </div>
          <div className="watch-description-toggle">
            {descExpanded ? 'Show less' : '...more'}
          </div>
        </div>

        <div className="comments-header">
          <span className="comments-count">
            {(commentsQuery.data?.length ?? 0).toLocaleString()} Comments
          </span>
          <span className="comments-sort"><IconScissor size={16} /> Sort by</span>
        </div>

        <div className="comment-compose">
          <div
            className="comment-avatar"
            style={{ background: userColor + '33', color: userColor }}
          >
            {currentUser?.display_name.slice(0, 1).toUpperCase() ?? 'G'}
          </div>
          <div style={{ flex: 1 }}>
            <input
              className="comment-compose-input"
              placeholder={currentUser ? 'Add a comment...' : 'Select a user to comment'}
              value={content}
              disabled={!currentUser}
              onChange={(e) => { setContent(e.target.value); setComposeFocus(true); }}
              onFocus={() => setComposeFocus(true)}
            />
            {composeFocus && (
              <div className="comment-compose-actions">
                <button className="btn-pill" onClick={() => { setContent(''); setComposeFocus(false); }}>Cancel</button>
                <button
                  className="btn-pill"
                  data-primary="true"
                  disabled={!content.trim() || commentMutation.isPending}
                  onClick={handleSubmit}
                >
                  {commentMutation.isPending ? 'Posting...' : 'Comment'}
                </button>
              </div>
            )}
          </div>
        </div>

        {commentsQuery.data?.map((comment) => {
          const cColor = avatarColor(comment.author);
          return (
            <div key={comment.id} className="comment">
              <div className="comment-avatar" style={{ background: cColor + '33', color: cColor }}>
                {comment.author.slice(0, 1).toUpperCase()}
              </div>
              <div>
                <div className="comment-head">
                  <span className="comment-author">@{comment.author}</span>
                  <span className="comment-time">{timeAgo(comment.created_at)}</span>
                </div>
                <div className="comment-body">{comment.content}</div>
                <div className="comment-actions">
                  <button><IconLike size={14} /></button>
                  <button><IconDislike size={14} /></button>
                  <button>Reply</button>
                </div>
              </div>
            </div>
          );
        })}
      </div>

      <aside className="suggestions">
        <div className="suggest-tabs">
          {['All', 'From channel', 'Related', 'For you'].map((t) => (
            <button
              key={t}
              className="suggest-tab"
              data-active={suggestTab === t}
              onClick={() => setSuggestTab(t)}
            >
              {t}
            </button>
          ))}
        </div>
        {recommendedQuery.data?.map((rec) => {
          const thumbSrc = rec.thumbnail_url ? toAbsoluteApiUrl(rec.thumbnail_url) : null;
          const bg = thumbGradient(rec.id);
          return (
            <Link key={rec.id} to={`/watch/${rec.id}`} className="suggest-card">
              <div className="suggest-thumb">
                {thumbSrc ? (
                  <img src={thumbSrc} alt={rec.title} loading="lazy" />
                ) : (
                  <div style={{ position: 'absolute', inset: 0, background: bg }} />
                )}
              </div>
              <div>
                <h4 className="suggest-title">{rec.title}</h4>
                <div className="suggest-channel">{rec.uploader?.display_name ?? 'Unknown'}</div>
                <div className="suggest-stats">{formatViews(rec.views)} · {timeAgo(rec.created_at)}</div>
              </div>
            </Link>
          );
        })}
      </aside>
    </div>
  );
}
