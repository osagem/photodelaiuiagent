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

export default {
  onLaunch() {
    console.log('[照片删除] App Launch');
  },
  onShow() {
    console.log('[照片删除] App Show');
  },
  onHide() {
    console.log('[照片删除] App Hide');
  },
  onError(err) {
    console.error('[照片删除] App Error', err);
  },
  globalData: {
    ready: false,
  },
};
