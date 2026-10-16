/**
 * 意图路由
 *
 * 两条路径：
 *   1. 普通态：命令词典命中（低延迟、确定性）
 *   2. 待确认态：只接受"确认 / 取消"，其余一律视为取消（防误删）
 *
 * 词典顺序即优先级：越靠前的意图越优先命中。
 */

export const INTENT = {
  CONFIRM: 'confirm',
  CANCEL: 'cancel',
  DELETE: 'delete',
  VIEW_PHOTO: 'view_photo',
  VIEW_VIDEO: 'view_video',
  NEXT: 'next',
  PREV: 'prev',
  REPLAY: 'replay',
  EXIT: 'exit',
  EXPAND: 'expand',
  UNKNOWN: 'unknown',
};

/**
 * 待确认态的专属词典
 *
 * 顺序：**取反词优先**（安全优先）—— 先判否定，再判肯定。
 * 这样「不要删除」「别删」不会被 CONFIRM 里的「删除」误命中。
 *
 * CONFIRM 收录各种"同一个意思的不同说法"：确认 / 确认删除 / 删除 / 删掉（用户实测习惯说法），
 * 以及 ASR 可能只截到「删除」二字的情况。
 */
const PENDING_COMMANDS = [
  { intent: INTENT.CANCEL, words: ['取消', '不要', '不用', '算了', '别删', '否', '不'] },
  {
    intent: INTENT.CONFIRM,
    words: ['确认删除', '确认', '确定', '删除', '删掉', '是的', '没错', '删吧', '可以', '好的', '好'],
  },
];

/** 普通态词典（顺序 = 优先级） */
const COMMANDS = [
  // 破坏性操作优先识别，避免被"照片/视频"等泛词抢占
  { intent: INTENT.DELETE, words: ['删除', '删掉', '移除', '不要了', '删'] },

  { intent: INTENT.REPLAY, words: ['重播', '重新播放', '再播一遍', '从头播', '重新开始', '再放一遍'] },

  { intent: INTENT.VIEW_PHOTO, words: ['查看照片', '看照片', '打开照片', '显示照片', '查看图片', '看图片', '浏览照片', '照片', '图片'] },
  { intent: INTENT.VIEW_VIDEO, words: ['查看视频', '看视频', '打开视频', '播放视频', '浏览视频', '视频'] },

  { intent: INTENT.NEXT, words: ['下一个', '下一张', '后一张', '往后', '下一', '下张'] },
  { intent: INTENT.PREV, words: ['上一个', '上一张', '前一张', '往前', '上一', '上张'] },

  { intent: INTENT.EXIT, words: ['退出查看', '退出', '关闭', '返回', '结束', '不看了'] },

  // 窗口模式（卡片态）→ 全屏（用户 2026-10-16 需求）。注意：卡片态麦克风需先由
  // 唤醒词「乐奇」激活宿主交互后才能听到本指令；命中后见 expandToFullscreen()。
  { intent: INTENT.EXPAND, words: ['放大', '全屏', '全屏显示', '放大画面', '回到全屏', '放大照片'] },
];

/** 归一化：去空白与常见标点，统一小写 */
export function normalize(text) {
  return String(text || '')
    .replace(/[\s,，。！!？?、；;：:."'“”‘’()（）【】\[\]]/g, '')
    .toLowerCase();
}

/**
 * 路由
 * @param {string} text 识别文本
 * @param {{pending?: boolean}} options pending=true 表示处于删除待确认态
 * @returns {{intent: string, keyword: string, text: string}}
 */
export function route(text, options) {
  const raw = String(text || '');
  const norm = normalize(raw);
  const pending = !!(options && options.pending);

  if (!norm) return { intent: INTENT.UNKNOWN, keyword: '', text: raw };

  const table = pending ? PENDING_COMMANDS : COMMANDS;

  for (let i = 0; i < table.length; i += 1) {
    const entry = table[i];
    for (let j = 0; j < entry.words.length; j += 1) {
      const word = entry.words[j];
      if (norm.indexOf(normalize(word)) !== -1) {
        return { intent: entry.intent, keyword: word, text: raw };
      }
    }
  }

  // 待确认态下，未命中确认/取消 → 视为取消，防止误删
  if (pending) {
    return { intent: INTENT.CANCEL, keyword: '(未匹配，默认取消)', text: raw };
  }

  return { intent: INTENT.UNKNOWN, keyword: '', text: raw };
}

/** 导出词典，供 AGENTS.md 与调试面板展示 */
export function commandTable() {
  return {
    pending: PENDING_COMMANDS,
    normal: COMMANDS,
  };
}
