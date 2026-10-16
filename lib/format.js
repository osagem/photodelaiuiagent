/**
 * 时间与文案格式化工具
 */

/** 秒 → "M:SS"（如 232 → "3:52"、9 → "0:09"） */
export function formatDuration(totalSeconds) {
  const s = Math.max(0, Math.floor(Number(totalSeconds) || 0));
  const m = Math.floor(s / 60);
  const r = s % 60;
  return `${m}:${String(r).padStart(2, '0')}`;
}

/** 秒 → "0:09 / 3:52" 形式的两段式时间轴 */
export function formatTimeline(currentSeconds, totalSeconds) {
  return `${formatDuration(currentSeconds)} / ${formatDuration(totalSeconds)}`;
}

/** 时间戳 → "MM-DD HH:mm" */
export function formatCapturedAt(ts) {
  const d = new Date(Number(ts) || 0);
  const p = (n) => String(n).padStart(2, '0');
  return `${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`;
}

/** 媒体类型 → 中文标签 */
export function typeLabel(type) {
  return type === 'video' ? '视频' : '照片';
}
