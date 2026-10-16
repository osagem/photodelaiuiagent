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
 * 语音层封装
 *
 * 交互模型：**一次唤醒 → 连续识别（免唤醒连续对话）**
 *   宿主语音唤醒（或在界面轻触）→ 开启一个 continuous 会话 → 用户此后直接说
 *   「下一个」「删除」「退出」即可，**无需每次重复唤醒词**。
 *
 * 为什么可行（官方规范 documentation/3-api/ai/speech-recognition.md）：
 *   `recognition.continuous` = 「是否在一条结果后继续识别」，默认 false；
 *   置 true 后一条结果不会再结束会话 —— 这正是"免唤醒"所需的语义。
 *   `start()` 要求"在用户交互中调用"，因此会话的**首次**启动由唤醒/轻触触发，
 *   会话意外结束时按 RESTART_DELAY_MS 自动续听（连续失败 RESTART_MAX_FAIL 次即
 *   退化回"每次都要唤醒"的老行为，不会卡死）。
 *
 * 自听防护：播报（TTS）期间麦克风会听到智能体自己的声音，
 *   故 speak() 会按文本长度估算播报时长并静音这段时间内的识别结果。
 */

const RECOGNITION_TIMEOUT_MS = 6000;
/** 会话意外结束后的自动续听延迟 */
const RESTART_DELAY_MS = 260;
/** 连续自动续听失败上限（超过则退化回唤醒驱动） */
const RESTART_MAX_FAIL = 3;
/** 播报静音估算：基数 + 每字 + 尾巴（防止把自己念的内容当成命令） */
const TTS_MUTE_BASE_MS = 500;
const TTS_MUTE_PER_CHAR_MS = 110;
const TTS_MUTE_TAIL_MS = 350;

let recognition = null;
let recognitionActive = false;
let timeoutTimer = null;
let handlers = { onResult: null, onError: null, onEnd: null, onPhase: null };
/** 连续识别模式（免唤醒） */
let continuousMode = false;
/**
 * 是否收到过「会话生命周期事件」（start/audiostart/soundstart/speechstart）。
 * 界面据此判断能否信任事件驱动的四态；若宿主一个都不派发，则退回轮询兜底。
 */
let sawLifecycle = false;
/** 自动续听连续失败计数 */
let restartFailures = 0;
/** 已释放：阻止挂起的续听定时器再次启动 */
let disposed = false;
/** 播报静音截止时间戳 */
let muteUntil = 0;

/**
 * 会话相位 —— 供界面展示「正在聆听 / 识别中 / 识别完成 / 识别失败」。
 *
 * | phase         | 触发事件                        | 界面含义                     |
 * | ------------- | ------------------------------- | ---------------------------- |
 * | `listening`   | `start` / `audiostart`          | 会话就绪，麦克风开着等你说话 |
 * | `speech`      | `soundstart` / `speechstart`    | 检测到声音/语音，正在识别    |
 * | `done`        | `result`                        | 拿到最终识别结果             |
 * | `fail`        | `error`（真实错误）             | 识别失败，附错误码           |
 * | `idle`        | `end`（会话真正终止）           | 已停止聆听                   |
 *
 * ★ 连续模式下的 `end` **不对外发 `idle`**：voice 层会在 260ms 后续听，
 *   若发了 `idle` 界面会每轮闪一下。只有真正停下来才发。
 * ★ 连续模式下 `no-speech` / `nomatch` / `aborted` **不发 `fail`**：
 *   那是"没人说话"的常态，若报成失败界面会一直闪错。
 */
export const PHASE = {
  LISTENING: 'listening',
  SPEECH: 'speech',
  DONE: 'done',
  FAIL: 'fail',
  IDLE: 'idle',
};

/** 内部：向界面广播相位变化（回调异常不影响识别主流程） */
function emitPhase(phase, detail) {
  if (phase === PHASE.LISTENING || phase === PHASE.SPEECH) sawLifecycle = true;
  if (!handlers.onPhase) return;
  try {
    handlers.onPhase(Object.assign({ phase }, detail || {}));
  } catch (err) {
    console.warn('[voice] onPhase 回调异常：', err);
  }
}

/**
 * 宿主是否派发过会话生命周期事件。
 * 为 false 时界面应退回"轮询 isListening()"的兜底表达（仍能显示「正在聆听」）。
 */
export function hasLifecycleEvents() {
  return sawLifecycle;
}

/** 语音识别是否可用 */
export function isRecognitionAvailable() {
  try {
    return typeof SpeechRecognition !== 'undefined';
  } catch (err) {
    return false;
  }
}

/** 语音播报是否可用 */
export function isSynthesisAvailable() {
  try {
    return typeof speechSynthesis !== 'undefined' && typeof SpeechSynthesisUtterance !== 'undefined';
  } catch (err) {
    return false;
  }
}

/**
 * 开始识别。
 *
 * @param {{onResult: Function, onError?: Function, onEnd?: Function, onPhase?: Function, continuous?: boolean}} opts
 *        `continuous: true` → 一次启动后持续识别，用户不必每次唤醒（免唤醒连续对话）。
 *        `onPhase({phase, ...})` → 会话相位变化（见 PHASE），供界面显示识别状态。
 * @returns {boolean} 是否成功启动
 */
export function startListening(opts) {
  handlers = {
    onResult: (opts && opts.onResult) || null,
    onError: (opts && opts.onError) || null,
    onEnd: (opts && opts.onEnd) || null,
    onPhase: (opts && opts.onPhase) || null,
  };

  if (!isRecognitionAvailable()) {
    if (handlers.onError) handlers.onError({ error: 'unsupported', message: '当前环境不支持语音识别' });
    return false;
  }

  if (recognitionActive) {
    stopListening();
  }

  continuousMode = !!(opts && opts.continuous);
  restartFailures = 0;
  disposed = false;
  sawLifecycle = false;
  return launchSession();
}

/**
 * 给识别对象绑定一个事件处理（内部）。
 *
 * 生命周期事件（onstart / onsoundstart / …）在规范里是"可通过同名 on... 属性监听"，
 * 但宿主实现未必齐全 —— 单独 try 住，保证任何一个事件不可用都不会拖垮会话启动。
 */
function bindEvent(target, name, fn) {
  try {
    target[name] = fn;
  } catch (err) {
    console.log('[voice] 事件不可用：', name);
  }
}

/**
 * 启动一次底层识别会话（内部）。
 * 单轮模式：结果/错误即结束；连续模式：结束即自动续听。
 */
function launchSession() {
  if (disposed) return false;

  try {
    const rec = new SpeechRecognition();
    recognition = rec;
    rec.lang = 'zh-CN';
    rec.continuous = continuousMode;
    rec.interimResults = false;
    rec.maxAlternatives = 1;

    let settled = false;

    // ★ 会话生命周期事件 → 界面四态（官方 documentation/3-api/ai/speech-recognition.md
    //   「start / audiostart / soundstart / speechstart 事件」：可通过同名 on... 属性或
    //   addEventListener() 监听）。由事件驱动而非轮询，"正在聆听 / 识别中"更准。
    //   逐个 bindEvent：宿主若未实现某个事件，赋值失败也不影响会话启动。
    bindEvent(rec, 'onstart', () => emitPhase(PHASE.LISTENING));
    bindEvent(rec, 'onaudiostart', () => emitPhase(PHASE.LISTENING));
    bindEvent(rec, 'onsoundstart', () => emitPhase(PHASE.SPEECH, { level: 'sound' }));
    bindEvent(rec, 'onspeechstart', () => emitPhase(PHASE.SPEECH, { level: 'voice' }));
    // speechend / soundend / audioend 期间仍在"识别中"（正在出结果），不改变界面相位

    rec.onresult = (event) => {
      const list = event && event.results;
      let result = null;
      if (list) {
        const idx = typeof event.resultIndex === 'number' ? event.resultIndex : 0;
        result = list[idx] || list[0];
      }
      const best = result && result[0];
      const transcript = best && best.transcript ? String(best.transcript) : '';
      if (!transcript) return;

      // 自听防护：播报期间忽略（否则会把智能体自己念的内容当成命令）
      if (isMuted()) {
        console.log('[voice] 播报期间忽略识别结果：', transcript);
        return;
      }

      restartFailures = 0;
      if (!continuousMode) settled = true;
      emitPhase(PHASE.DONE, { transcript });
      if (handlers.onResult) {
        handlers.onResult({ transcript, confidence: best ? best.confidence : 0 });
      }
    };

    rec.onerror = (event) => {
      const code = (event && event.error) || 'unknown';
      // 连续模式下没听到语音是常态，不作为错误上报（否则会不断弹提示）
      if (continuousMode && (code === 'no-speech' || code === 'nomatch' || code === 'aborted')) {
        return;
      }
      if (!continuousMode) settled = true;
      emitPhase(PHASE.FAIL, { code, message: (event && event.message) || '' });
      if (handlers.onError) {
        handlers.onError({ error: code, message: (event && event.message) || '' });
      }
    };

    rec.onend = () => {
      clearTimer();
      recognitionActive = false;

      if (!disposed && continuousMode) {
        // ★ 免唤醒的关键：会话结束立即续听，用户无需再次唤醒。
        //   这里**不对外发 idle** —— 260ms 后就会续听，发了界面会每轮闪一下。
        setTimeout(() => {
          if (disposed || !continuousMode) return;
          const ok = launchSession();
          if (ok) return;
          restartFailures += 1;
          if (restartFailures >= RESTART_MAX_FAIL) {
            continuousMode = false;
            emitPhase(PHASE.IDLE);
            if (handlers.onError) {
              handlers.onError({
                error: 'continuous-failed',
                message: '连续识别无法维持，已退回唤醒驱动',
              });
            }
          }
        }, RESTART_DELAY_MS);
        return;
      }

      if (!settled) {
        settled = true;
        // ★ 与 timeout 同理：完全没听到不发 FAIL 相位，静默（页面 onError 侧同样静默）。
        if (handlers.onError) handlers.onError({ error: 'no-speech', message: '未识别到语音' });
      }
      emitPhase(PHASE.IDLE);
      if (handlers.onEnd) handlers.onEnd();
    };

    rec.start();
    recognitionActive = true;
    if (!continuousMode) startTimer();
    return true;
  } catch (err) {
    console.warn('[voice] 启动识别失败：', err);
    recognitionActive = false;
    return false;
  }
}

/** 当前是否处于「免唤醒连续识别」状态 */
export function isContinuous() {
  return continuousMode && recognitionActive;
}

/**
 * 播报期间静音识别结果。
 * @param {number} ms 静音时长（毫秒）
 */
export function muteFor(ms) {
  const ms2 = Number(ms);
  if (!Number.isFinite(ms2) || ms2 <= 0) return;
  const until = Date.now() + ms2;
  if (until > muteUntil) muteUntil = until;
}

/** 是否处于静音窗口 */
export function isMuted() {
  return Date.now() < muteUntil;
}

/** 按文本长度估算播报时长（用于静音窗口） */
export function estimateSpeechMs(text) {
  const n = String(text || '').length;
  return TTS_MUTE_BASE_MS + n * TTS_MUTE_PER_CHAR_MS + TTS_MUTE_TAIL_MS;
}

/** 主动结束识别（含关闭连续模式，不再自动续听） */
export function stopListening() {
  continuousMode = false;
  restartFailures = 0;
  clearTimer();
  if (recognition && recognitionActive) {
    try {
      recognition.stop();
    } catch (err) {
      /* ignore */
    }
  }
  recognitionActive = false;
  emitPhase(PHASE.IDLE);
}

/** 立即中止（不等待最终结果）并关闭连续模式 */
export function abortListening() {
  continuousMode = false;
  restartFailures = 0;
  clearTimer();
  if (recognition && recognitionActive) {
    try {
      recognition.abort();
    } catch (err) {
      /* ignore */
    }
  }
  recognitionActive = false;
  // abort() 不派发 onend（官方：立即中止、不等最终结果）→ 这里必须自己广播 idle
  emitPhase(PHASE.IDLE);
}

export function isListening() {
  return recognitionActive;
}

/**
 * 超时保护：一段时间内没有结果就主动结束，避免识别会话长挂
 */
function startTimer() {
  clearTimer();
  timeoutTimer = setTimeout(() => {
    timeoutTimer = null;
    if (recognitionActive) {
      // ★ 完全没听到 = 常态，不发 FAIL 相位（界面状态条不闪「识别失败」，
      //   用户 2026-10-16 定稿：该状态静默不响应）；onError 仍回调，页面侧静默。
      if (handlers.onError) handlers.onError({ error: 'timeout', message: '识别超时' });
      stopListening();
    }
  }, RECOGNITION_TIMEOUT_MS);
}

function clearTimer() {
  if (timeoutTimer) {
    clearTimeout(timeoutTimer);
    timeoutTimer = null;
  }
}

/**
 * 语音播报
 * @param {string} text
 * @param {{interrupt?: boolean}} options interrupt=true 时打断当前播报
 */
export function speak(text, options) {
  const content = String(text || '').trim();
  if (!content) return false;

  if (!isSynthesisAvailable()) {
    console.log('[voice][tts-fallback]', content);
    return false;
  }

  try {
    const utterance = new SpeechSynthesisUtterance(content);
    // ★ v0.18 规范（apis/ai.md）：`lang` 目前不生效（不改变生成语言），
    //   保留只为语义标注；`volume` 取值是 0–10 的整数（默认 1），不是 0–1。
    utterance.lang = 'zh-CN';
    // ★ 移除 `rate` / `pitch`：规范中 SpeechSynthesisUtterance 只暴露
    //   text / lang / voice / volume，rate 与 pitch 未记载（不可假设存在）。
    //
    // ★ 打断语义：规范的 speak() 只有两种 mode —— 'enqueue'（默认）与 'immediate'。
    //   原先传的 'interrupt' 不在枚举内，等于"打断"没生效。
    const mode = options && options.interrupt ? 'immediate' : 'enqueue';
    // ★ 自听防护：连续识别（免唤醒）下麦克风一直开着，播报期间必须静音识别结果，
    //   否则智能体自己念的「已删除这张照片」可能被识别成命令。
    muteFor(estimateSpeechMs(content));
    speechSynthesis.speak(utterance, mode);
    return true;
  } catch (err) {
    console.warn('[voice] 播报失败：', err);
    return false;
  }
}

/**
 * 停止播报。
 *
 * ★ v0.18 规范（apis/ai.md）明确：`cancel()` / `pause()` / `resume()` /
 *   `getVoices()` 与 utterance 生命周期事件**均未暴露** → 唯一可靠的"停止"手段
 *   是下一次 speak(..., 'immediate') 抢占。
 *   这里保留一次特性探测式调用（有则用、无则跳过），避免功能回退；
 *   真正的打断依赖上面的 'immediate'。
 */
export function stopSpeaking() {
  try {
    if (isSynthesisAvailable() && typeof speechSynthesis.cancel === 'function') {
      speechSynthesis.cancel();
    }
  } catch (err) {
    /* ignore */
  }
}

/** 热词建议（供 SpeechRecognitionSession.phrases 使用） */
export const HOT_WORDS = [
  { phrase: '删除', boost: 8 },
  { phrase: '确认', boost: 8 },
  { phrase: '取消', boost: 8 },
  { phrase: '下一个', boost: 5 },
  { phrase: '上一个', boost: 5 },
  { phrase: '重播', boost: 5 },
  { phrase: '退出', boost: 5 },
  { phrase: '查看照片', boost: 5 },
  { phrase: '查看视频', boost: 5 },
];

/** 释放资源 */
export function dispose() {
  disposed = true;
  abortListening();
  stopSpeaking();
  recognition = null;
  handlers = { onResult: null, onError: null, onEnd: null, onPhase: null };
  sawLifecycle = false;
}
