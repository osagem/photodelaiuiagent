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
 * 媒体库状态层（DCIM 桥版）
 *
 * 与旧版（OPFS 私有库）对外 API 完全一致：
 *   init / current / total / breadcrumb / next / prev / toNewestOfType / deleteCurrent
 *
 * 差别在于数据源：不再读智能体私有 OPFS，而是通过本机 DCIM 桥读取
 * 系统相机拍摄目录（DCIM/Camera 照片 + Movies/Camera 视频的文件系统枚举），
 * 删除走桥的 /delete/<id>，是**对系统相册文件的真实删除**。
 */

import { discoverBase, getJson, report, baseUrl, lastErrorText } from './bridge';

let items = []; // 有效清单（最新在前）
let cursor = 0; // 当前游标
let ready = false;
let scope = 'standard'; // standard | all
let diagText = '';

function normalize(raw) {
  const b = baseUrl() || '';
  const isVideo = raw.type === 'video';
  return {
    id: raw.id,
    type: isVideo ? 'video' : 'photo',
    title: raw.name || raw.path || '未命名',
    path: raw.path || '',
    size: raw.size || 0,
    capturedAt: raw.mtime || 0,
    durationSec: raw.durationSec || (raw.durationMs ? Math.round(raw.durationMs / 1000) : 0),
    // ↑ 桥的 /list 目前**不返回**时长字段，故常为 0；若将来补上 durationSec/durationMs
    //   这里会自动采用（前向兼容）。拿不到时由页面侧回填：优先能力探测
    //   VideoContext.getDuration()（规范未记载，故 typeof 探测后再调），
    //   再退到 <video> timeupdate 递增最大值估计。
    src: b + (raw.url || `/media/${raw.id}`),
    poster: isVideo ? '' : `${b}/thumb/${raw.id}?w=720`,
  };
}

/* ---------------- 初始化 ---------------- */

export async function init() {
  ready = false;
  items = [];
  cursor = 0;
  diagText = '';

  const base = await discoverBase();
  if (!base) {
    diagText = `桥不可达：${lastErrorText()}`;
    await report(`init 失败 ${diagText}`);
    return { opfsReady: false, opfsFileCount: 0, error: diagText };
  }

  try {
    const list = await getJson('/list');
    scope = list.scope || 'standard';
    items = (list.items || []).map(normalize);
    cursor = 0;
    ready = true;
    diagText = `桥已连接 ${base.replace('http://', '')} · ${items.length} 项`;
    await report(
      `init 成功 total=${list.total} 首项=${items.length ? items[0].path : '无'}`
    );
    return { opfsReady: true, opfsFileCount: items.length, total: list.total };
  } catch (err) {
    diagText = `清单获取失败：${(err && err.message) || err}`;
    await report(`init 异常 ${diagText}`);
    return { opfsReady: false, opfsFileCount: 0, error: diagText };
  }
}

export function isReady() {
  return ready;
}

export function scopeText() {
  return scope === 'all' ? '全盘' : '拍摄目录';
}

export function statusText() {
  return diagText;
}

/* ---------------- 浏览 ---------------- */

export function total() {
  return items.length;
}

export function current() {
  if (!items.length) return null;
  const i = Math.min(Math.max(cursor, 0), items.length - 1);
  return items[i];
}

export function breadcrumb() {
  return `${items.length ? cursor + 1 : 0}/${items.length}`;
}

export function next() {
  if (!items.length) return;
  cursor = (cursor + 1) % items.length;
}

export function prev() {
  if (!items.length) return;
  cursor = (cursor - 1 + items.length) % items.length;
}

/** 跳到指定类型的第一项（即"最新的一张照片/视频"）；找不到返回 false */
export function toNewestOfType(type) {
  const idx = items.findIndex((it) => it.type === type);
  if (idx < 0) return false;
  cursor = idx;
  return true;
}

/* ---------------- 删除（真实删除系统相册文件） ---------------- */

export async function deleteCurrent() {
  const item = current();
  if (!item) return { ok: false, remaining: 0, reason: 'empty' };

  let res = null;
  try {
    res = await getJson(`/delete/${item.id}`);
  } catch (err) {
    await report(`删除请求异常 ${item.path} ${(err && err.message) || err}`);
    return { ok: false, remaining: items.length, reason: String((err && err.message) || err) };
  }

  if (!res || !res.ok) {
    await report(`删除失败 ${item.path} ${JSON.stringify(res || {})}`);
    return { ok: false, remaining: items.length, reason: (res && res.error) || 'bridge refused' };
  }

  const removedPath = item.path;
  items.splice(cursor, 1);
  if (cursor >= items.length) cursor = Math.max(0, items.length - 1);

  await report(`已删除 ${removedPath} 剩余${items.length}`);
  return { ok: true, remaining: items.length, path: removedPath, txtDeleted: !!res.txtDeleted };
}
