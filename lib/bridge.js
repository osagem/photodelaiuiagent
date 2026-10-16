/**
 * DCIM 桥客户端
 *
 * 智能体本身无法读取系统相册（平台无 MediaStore API，<image>/<video> 也不接受
 * file:// 或 content://）。唯一通道是 HTTP —— 由侧载的 DCIM 桥 App 在本机起一个
 * HTTP 服务，把 DCIM/Pictures/Movies 以文件系统枚举的方式暴露出来。
 *
 * 本模块负责：
 *   1. 基址发现（127.0.0.1 优先，localhost 兜底）
 *   2. 统一的 JSON GET（fetch 优先，wx.request 兜底）
 *   3. 结果回读通道（/log，供 PC 侧取证，绕开不可靠的截图）
 */

const PORT = 38999;
const PING_TIMEOUT_MS = 3000;
const REQ_TIMEOUT_MS = 8000;

const CANDIDATES = [`http://127.0.0.1:${PORT}`, `http://localhost:${PORT}`];

let base = null;
let lastError = '';
let transport = 'unknown'; // fetch | wx.request

function log(...args) {
  try {
    console.log('[bridge]', ...args);
  } catch (err) {
    /* 忽略 */
  }
}

export function baseUrl() {
  return base;
}

export function lastErrorText() {
  return lastError;
}

export function transportName() {
  return transport;
}

/* ---------------- 底层传输 ---------------- */

function viaWxRequest(url, timeoutMs) {
  return new Promise((resolve, reject) => {
    let wxObj = null;
    try {
      wxObj = typeof wx !== 'undefined' ? wx : null;
    } catch (err) {
      wxObj = null;
    }
    if (!wxObj || typeof wxObj.request !== 'function') {
      reject(new Error('wx.request 不可用'));
      return;
    }
    let settled = false;
    const timer = setTimeout(() => {
      if (!settled) {
        settled = true;
        reject(new Error('wx.request timeout'));
      }
    }, timeoutMs);
    try {
      wxObj.request({
        url,
        method: 'GET',
        timeout: timeoutMs,
        responseType: 'text',
        success: (res) => {
          if (settled) return;
          settled = true;
          clearTimeout(timer);
          let body = res && res.data;
          if (body && typeof body !== 'string') {
            try {
              body = JSON.stringify(body);
            } catch (err) {
              body = String(body);
            }
          }
          resolve({ status: (res && res.statusCode) || 0, text: String(body == null ? '' : body) });
        },
        fail: (err) => {
          if (settled) return;
          settled = true;
          clearTimeout(timer);
          reject(new Error('wx.request fail: ' + JSON.stringify(err || {})));
        },
      });
    } catch (err) {
      if (!settled) {
        settled = true;
        clearTimeout(timer);
        reject(err);
      }
    }
  });
}

async function viaFetch(url, timeoutMs) {
  let ctrl = null;
  let timer = null;
  try {
    if (typeof AbortController !== 'undefined') {
      ctrl = new AbortController();
      timer = setTimeout(() => {
        try {
          ctrl.abort();
        } catch (err) {
          /* 忽略 */
        }
      }, timeoutMs);
    }
    const res = await fetch(url, ctrl ? { signal: ctrl.signal } : undefined);
    const text = await res.text();
    return { status: res.status, text };
  } finally {
    if (timer) clearTimeout(timer);
  }
}

async function fetchText(url, timeoutMs) {
  if (typeof fetch === 'function') {
    transport = 'fetch';
    return viaFetch(url, timeoutMs || REQ_TIMEOUT_MS);
  }
  transport = 'wx.request';
  return viaWxRequest(url, timeoutMs || REQ_TIMEOUT_MS);
}

async function fetchJson(url, timeoutMs) {
  const { status, text } = await fetchText(url, timeoutMs);
  try {
    return JSON.parse(text);
  } catch (err) {
    throw new Error(`非 JSON 响应(${status}): ${String(text).slice(0, 80)}`);
  }
}

/** 依次尝试候选基址，返回可用的那个；全部失败返回 null */
export async function discoverBase() {
  if (base) return base;
  log('开始基址发现, fetch 可用=', typeof fetch !== 'undefined', ', wx 可用=', typeof wx !== 'undefined');
  const tried = [];
  for (const c of CANDIDATES) {
    try {
      const pong = await fetchJson(`${c}/ping`, PING_TIMEOUT_MS);
      if (pong && pong.ok) {
        base = c;
        lastError = '';
        log('基址命中', c, 'transport=', transport);
        await report(`基址命中 ${c} via ${transport}`);
        return base;
      }
      tried.push(`${c}:ok=false`);
      log('基址应答异常', c, JSON.stringify(pong));
    } catch (err) {
      const msg = (err && err.message) || String(err);
      tried.push(`${c}:${msg}`);
      log('基址失败', c, msg);
    }
  }
  lastError = tried.join(' | ');
  log('基址全部失败', lastError);
  return null;
}

export async function getJson(path) {
  const b = base || (await discoverBase());
  if (!b) throw new Error('DCIM 桥不可达');
  return fetchJson(b + path);
}

/** 把智能体侧的关键结果回传给 PC（桥会存进环形缓冲，PC 通过 adb forward 读取） */
export async function report(msg) {
  const b = base;
  if (!b) return; // 无基址时无处可报，仅靠 console
  try {
    await fetchText(`${b}/log?m=${encodeURIComponent(String(msg).slice(0, 400))}`, 3000);
  } catch (err) {
    /* 回读失败不影响主流程 */
  }
}
