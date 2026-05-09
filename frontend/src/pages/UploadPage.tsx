import { FormEvent, useEffect, useMemo, useState } from 'react';
import { useNavigate } from 'react-router-dom';

import { uploadVideo } from '../api/client';
import { useUserContext } from '../context/UserContext';
import { useVideoCache } from '../context/VideoCacheContext';

type ThumbnailMode = 'none' | 'frame' | 'custom';

type FrameOption = {
  id: string;
  blob: Blob;
  previewUrl: string;
};

const FRAME_RATIOS = [0.15, 0.5, 0.85];

async function seekTo(video: HTMLVideoElement, time: number): Promise<void> {
  if (Math.abs(video.currentTime - time) < 0.01) return;

  await new Promise<void>((resolve, reject) => {
    const onSeeked = () => {
      video.removeEventListener('error', onError);
      resolve();
    };

    const onError = () => {
      video.removeEventListener('seeked', onSeeked);
      reject(new Error('Unable to seek video for frame extraction'));
    };

    video.addEventListener('seeked', onSeeked, { once: true });
    video.addEventListener('error', onError, { once: true });
    video.currentTime = time;
  });
}

async function generateFrameOptions(file: File): Promise<FrameOption[]> {
  const sourceUrl = URL.createObjectURL(file);
  const video = document.createElement('video');
  video.preload = 'metadata';
  video.muted = true;
  video.playsInline = true;
  video.src = sourceUrl;

  try {
    await new Promise<void>((resolve, reject) => {
      const onLoadedMetadata = () => {
        video.removeEventListener('error', onError);
        resolve();
      };

      const onError = () => {
        video.removeEventListener('loadedmetadata', onLoadedMetadata);
        reject(new Error('Unable to read video metadata'));
      };

      video.addEventListener('loadedmetadata', onLoadedMetadata, { once: true });
      video.addEventListener('error', onError, { once: true });
    });

    if (!Number.isFinite(video.duration) || video.duration <= 0) {
      return [];
    }

    const canvas = document.createElement('canvas');
    canvas.width = 320;
    canvas.height = 180;
    const context = canvas.getContext('2d');

    if (!context) {
      return [];
    }

    const frames: FrameOption[] = [];
    for (let index = 0; index < FRAME_RATIOS.length; index += 1) {
      const ratio = FRAME_RATIOS[index];
      const time = Math.max(0, Math.min(video.duration * ratio, Math.max(video.duration - 0.1, 0)));
      await seekTo(video, time);
      context.drawImage(video, 0, 0, canvas.width, canvas.height);

      const blob = await new Promise<Blob | null>((resolve) => {
        canvas.toBlob(resolve, 'image/jpeg', 0.88);
      });

      if (!blob) continue;

      frames.push({
        id: `frame-${index}`,
        blob,
        previewUrl: URL.createObjectURL(blob),
      });
    }

    return frames;
  } finally {
    URL.revokeObjectURL(sourceUrl);
    video.removeAttribute('src');
    video.load();
  }
}

export function UploadPage() {
  const navigate = useNavigate();
  const { refreshVideos } = useVideoCache();
  const { currentUser } = useUserContext();
  const [title, setTitle] = useState('');
  const [description, setDescription] = useState('');
  const [file, setFile] = useState<File | null>(null);
  const [thumbnailMode, setThumbnailMode] = useState<ThumbnailMode>('frame');
  const [generatedFrames, setGeneratedFrames] = useState<FrameOption[]>([]);
  const [selectedFrameId, setSelectedFrameId] = useState<string | null>(null);
  const [customThumbnail, setCustomThumbnail] = useState<File | null>(null);
  const [loading, setLoading] = useState(false);
  const [isGeneratingFrames, setIsGeneratingFrames] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [thumbnailError, setThumbnailError] = useState<string | null>(null);

  const selectedFrame = useMemo(
    () => generatedFrames.find((frame) => frame.id === selectedFrameId) ?? null,
    [generatedFrames, selectedFrameId]
  );

  useEffect(() => {
    return () => {
      generatedFrames.forEach((frame) => URL.revokeObjectURL(frame.previewUrl));
    };
  }, [generatedFrames]);

  useEffect(() => {
    if (!file) {
      setGeneratedFrames([]);
      setSelectedFrameId(null);
      return;
    }

    let cancelled = false;
    setIsGeneratingFrames(true);
    setThumbnailError(null);

    void generateFrameOptions(file)
      .then((frames) => {
        if (cancelled) {
          frames.forEach((frame) => URL.revokeObjectURL(frame.previewUrl));
          return;
        }

        setGeneratedFrames(frames);
        setSelectedFrameId(frames[0]?.id ?? null);
      })
      .catch(() => {
        if (!cancelled) {
          setGeneratedFrames([]);
          setSelectedFrameId(null);
          setThumbnailError('Could not generate frame thumbnails for this video.');
        }
      })
      .finally(() => {
        if (!cancelled) {
          setIsGeneratingFrames(false);
        }
      });

    return () => {
      cancelled = true;
    };
  }, [file]);

  const handleSubmit = async (event: FormEvent) => {
    event.preventDefault();
    if (!file || !title.trim()) return;

    setLoading(true);
    setError(null);

    const formData = new FormData();
    formData.append('title', title.trim());
    formData.append('description', description.trim());
    formData.append('file', file);

    if (thumbnailMode === 'custom') {
      if (!customThumbnail) {
        setError('Select a custom thumbnail or choose a different thumbnail option.');
        setLoading(false);
        return;
      }
      formData.append('thumbnail', customThumbnail);
    }

    if (thumbnailMode === 'frame') {
      if (!selectedFrame) {
        setError('Select a generated frame thumbnail or choose a different thumbnail option.');
        setLoading(false);
        return;
      }
      formData.append('thumbnail', new File([selectedFrame.blob], 'frame-thumbnail.jpg', { type: 'image/jpeg' }));
    }

    try {
      const uploaded = await uploadVideo(formData);
      setLoading(false);
      navigate(`/watch/${uploaded.id}`);
      void refreshVideos();
    } catch {
      setError('Upload failed. Please try again.');
      setLoading(false);
    }
  };

  return (
    <main className="upload-main">
      <section className="upload-panel">
        <div className="upload-topbar">
          <div>
            <h1>Upload videos</h1>
            <p>Add details to publish your video.</p>
            <p>Uploading as: {currentUser?.display_name ?? 'No user selected (video will be unattributed)'}</p>
          </div>
          <button type="submit" form="upload-form" disabled={loading || isGeneratingFrames} className="upload-publish-btn">
            {loading ? 'Uploading...' : 'Publish'}
          </button>
        </div>

        <form id="upload-form" onSubmit={handleSubmit} className="upload-form">
          <section className="upload-section">
            <h2>Video file</h2>
            <input
              type="file"
              accept="video/*"
              onChange={(e) => setFile(e.target.files?.[0] ?? null)}
              required
            />
          </section>

          <section className="upload-section">
            <h2>Details</h2>
            <input value={title} onChange={(e) => setTitle(e.target.value)} placeholder="Title" required />
            <textarea value={description} onChange={(e) => setDescription(e.target.value)} placeholder="Description" />
          </section>

          <section className="upload-section">
            <h2>Thumbnail</h2>
            <fieldset className="thumbnail-options">
              <legend>Choose thumbnail source</legend>
              <label>
                <input
                  type="radio"
                  name="thumbnail-mode"
                  value="frame"
                  checked={thumbnailMode === 'frame'}
                  onChange={() => setThumbnailMode('frame')}
                />
                Pick a frame from the video
              </label>
              <label>
                <input
                  type="radio"
                  name="thumbnail-mode"
                  value="custom"
                  checked={thumbnailMode === 'custom'}
                  onChange={() => setThumbnailMode('custom')}
                />
                Upload a custom thumbnail
              </label>
              <label>
                <input
                  type="radio"
                  name="thumbnail-mode"
                  value="none"
                  checked={thumbnailMode === 'none'}
                  onChange={() => setThumbnailMode('none')}
                />
                No thumbnail
              </label>
            </fieldset>

            {thumbnailMode === 'frame' ? (
              <div className="thumbnail-picker">
                {isGeneratingFrames ? <p>Generating frame thumbnails...</p> : null}
                {!isGeneratingFrames && generatedFrames.length > 0 ? (
                  <div className="thumbnail-grid">
                    {generatedFrames.map((frame) => (
                      <button
                        key={frame.id}
                        type="button"
                        onClick={() => setSelectedFrameId(frame.id)}
                        className={selectedFrameId === frame.id ? 'thumbnail-option thumbnail-option-active' : 'thumbnail-option'}
                      >
                        <img src={frame.previewUrl} alt="Generated frame thumbnail option" />
                      </button>
                    ))}
                  </div>
                ) : null}
                {!isGeneratingFrames && generatedFrames.length === 0 ? <p>No frame thumbnails available yet.</p> : null}
              </div>
            ) : null}

            {thumbnailMode === 'custom' ? (
              <input
                type="file"
                accept="image/*"
                onChange={(e) => setCustomThumbnail(e.target.files?.[0] ?? null)}
                required
              />
            ) : null}
          </section>
        </form>

        {thumbnailError ? <p className="error-text">{thumbnailError}</p> : null}
        {error ? <p className="error-text">{error}</p> : null}
      </section>
    </main>
  );
}
