export function formatViews(views: number): string {
  if (views >= 1_000_000) return `${(views / 1_000_000).toFixed(1)}M views`;
  if (views >= 1_000) return `${Math.floor(views / 1_000)}K views`;
  return `${views} view${views !== 1 ? 's' : ''}`;
}

export function timeAgo(dateString: string): string {
  const diff = Date.now() - new Date(dateString).getTime();
  const s = Math.floor(diff / 1000);
  if (s < 60) return 'just now';
  const m = Math.floor(s / 60);
  if (m < 60) return `${m} minute${m !== 1 ? 's' : ''} ago`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h} hour${h !== 1 ? 's' : ''} ago`;
  const d = Math.floor(h / 24);
  if (d < 7) return `${d} day${d !== 1 ? 's' : ''} ago`;
  const w = Math.floor(d / 7);
  if (w < 4) return `${w} week${w !== 1 ? 's' : ''} ago`;
  const mo = Math.floor(d / 30);
  if (mo < 12) return `${mo} month${mo !== 1 ? 's' : ''} ago`;
  const y = Math.floor(d / 365);
  return `${y} year${y !== 1 ? 's' : ''} ago`;
}

const GRADIENTS = [
  'linear-gradient(135deg, #ed2e3a 0%, #5e60ce 100%)',
  'linear-gradient(135deg, #00b4d8 0%, #0077b6 100%)',
  'linear-gradient(135deg, #f4a261 0%, #e76f51 100%)',
  'linear-gradient(135deg, #2a9d8f 0%, #264653 100%)',
  'linear-gradient(135deg, #ffb627 0%, #ff7b00 100%)',
  'linear-gradient(135deg, #6a4c93 0%, #1982c4 100%)',
  'linear-gradient(135deg, #390099 0%, #ff5400 100%)',
  'linear-gradient(135deg, #06d6a0 0%, #118ab2 100%)',
  'linear-gradient(135deg, #ff006e 0%, #8338ec 100%)',
  'linear-gradient(135deg, #14213d 0%, #fca311 100%)',
];

export function thumbGradient(id: number): string {
  return GRADIENTS[id % GRADIENTS.length];
}

export function avatarColor(name: string): string {
  const COLORS = ['#ed2e3a', '#5e60ce', '#2a9d8f', '#f4a261', '#ffb627', '#06d6a0', '#ff006e', '#8338ec', '#14213d', '#003049'];
  let hash = 0;
  for (let i = 0; i < name.length; i++) hash = (hash * 31 + name.charCodeAt(i)) & 0xffffffff;
  return COLORS[Math.abs(hash) % COLORS.length];
}
