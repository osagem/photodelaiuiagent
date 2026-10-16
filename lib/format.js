/**
 * Photo Delete - Rokid Glasses AIUI agent for viewing / playing / deleting DCIM media
 * Copyright (C) 2026 OSAGEM
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as published by
 * the Free Software Foundation, version 3 of the License.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU Affero General Public License for more details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with this program. If not, see https://www.gnu.org/licenses/
 *
 * SPDX-License-Identifier: AGPL-3.0-only
 */

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
