<script type="application/json" def>
{
  "navigationBarTitleText": "照片删除",
  "description": "逐张浏览并删除 Rokid Glasses 系统相册（DCIM）中的照片与视频。当用户想查看、翻看或删除眼镜相册里的照片或视频时打开本页。打开后自动呈现一张媒体：照片直接显示，视频自动开始并循环播放（H.264 直接播；HEVC 源由本机 DCIM 桥自动转码为 H.264 后播放，转码等待期显示「正在生成预览视频，请稍后 N%」并语音提醒，转码结果有缓存、二次播放秒开）。可用语音下达 查看照片 / 查看视频 / 下一个 / 上一个 / 重播 / 删除 / 确认删除 / 取消 / 退出；界面左下角常驻三行（自下而上：可用语音命令「下一个，上一个，删除，确认删除，取消，退出」；其上一行 = 序号「1/7」与语音识别状态「正在聆听/识别中/识别完成/识别失败」同行；视频时最上一行 = 播放时间「0:09 / 3:52」，不放进度条），均为半透明黑底高亮绿字。镜腿手势：往前滑 = 下一个、往后滑 = 上一个；单击 = 视频暂停/继续播放（照片无效果）、删除确认时 = 取消；双击 = 退出智能体（一次关到底），删除确认时双击 = 取消。轻触屏幕可唤醒语音。删除不可逆，会先出现虚线确认条做二次确认；相册为空时显示空库提示。启动时若未检测到本机照片删除服务（DCIM 桥），显示全屏服务未检测页（含最新版apk安装包下载地址），该页仅支持退出（语音「退出」或镜腿双击），服务就绪后自动进入主界面。",
  "disableScroll": true
}
</script>

<script setup>
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

import wx from 'wx';
import * as store from '../../lib/media-store';
import {
  report as bridgeReport,
  getJson as bridgeGetJson,
  baseUrl as bridgeBaseUrl,
} from '../../lib/bridge';
import { route, INTENT } from '../../lib/intent';
import * as voice from '../../lib/voice';
import { formatTimeline, formatDuration, typeLabel } from '../../lib/format';

const VIDEO_ID = 'mainVideo';
/** 删除确认窗口。原本 5s 太短：用户重新唤醒 + 说话 + ASR 出结果常需 5-10s，会看到"确认无效" */
const DELETE_TIMEOUT_MS = 12000;
/** 进入确认态后自动开始聆听的延迟（先让 TTS 提示出声，避免被麦克风拾取） */
const PENDING_LISTEN_DELAY = 1400;
const CONTEXT_RETRY = 5;
const CONTEXT_RETRY_DELAY = 80;
// 居中加载指示：兜底自动关闭（防止事件丢失导致一直转圈）—— 视频
const LOADING_TIMEOUT_MS = 6000;
// 居中加载指示：兜底自动关闭 —— 图片
// ★ 为什么图片要单独给一个很短的兜底（官方 2-components/image.md 的属性表只有 src/mode，
//   **没有 load/error 事件**，全仓 samples 也没有任何 <image> 绑定 bindload）：
//   即 `<image>` 的「已解码」事件很可能根本不派发 → 上方的 onImageLoad 不会被调用，
//   于是它只能靠兜底计时退出。若沿用视频的 6s，用户每翻一张照片都要看 6 秒转圈。
//   本页是回环 HTTP + 本地解码，900ms 足够覆盖；若宿主其实支持 load 事件，会提前收起，无副作用。
const LOADING_TIMEOUT_IMAGE_MS = 900;
// 视频加载超过此时长仍未就绪 → 文案升级为「处理中」（较慢的源可能是转码/封装较重）
const LOADING_SLOW_MS = 2500;
// 桥端 HEVC→H.264 转码：进度轮询间隔（方案 docs/AIUI-视频转码-落地方案.md §4.6）
const TRANSCODE_POLL_MS = 500;
// 转码等待期 loading 的兜底时长：长视频转码可能要几分钟，轮询/失败分支负责正常收起，
// 这个超大兜底只防"轮询彻底失联"。收到 done/failed 时立即 clearLoading。
const TRANSCODE_LOADING_TIMEOUT_MS = 600000;
/**
 * 残留 `timeupdate` 的判定余量（秒）：已知本条总时长时，上报的播放进度若超出
 * `总时长 + 本值`，就必然是**换源前那一条**的旧媒体在继续上报（真机取证见
 * `onVideoLoadedMetadata` 的注释）。留 1.5s 余量吸收四舍五入与解码抖动。
 */
const STALE_PROGRESS_SLACK_S = 1.5;
/**
 * 一次镜腿操作的**事件归并窗口**（毫秒）：窗口内只认第一个方向码，其余事件全部丢弃。
 *
 * ★ 真机实测（2026-10-16，桥日志 `key …` 逐条取证）：宿主对**一次物理手势**派发的是
 *   **一串**按键事件，而不是单个 ——
 *     往前滑 → `GlobalHook` …(+100~170ms)… `ArrowRight` ×2 …(+35ms)… `ArrowDown`
 *     往后滑 → `GlobalHook` …(+110~135ms)… `ArrowLeft`  ×2 …(+35ms)… `ArrowUp`
 *   整串约 190ms 内完成。若不归并，一次滑动会翻两页、还会被当成一次单击。
 *   → 第一个方向码触发动作后，KEY_GESTURE_LOCK_MS 内其余方向码一律忽略。
 */
const KEY_GESTURE_LOCK_MS = 320;
/**
 * 单击的**判定延迟**（毫秒）。
 *
 * `GlobalHook` = "镜腿被触摸"，**每次手势都会来**（滑动也会），所以不能立刻当单击：
 * 先等 KEY_TAP_DEFER_MS，期间若来了方向码 → 判为滑动（取消单击），否则才是单击。
 * 真机实测方向码在 +100~170ms 到达 → 260ms 足够留出余量（单击判定也就 260ms，手感可接受）。
 *
 * 宿主随后（+530~660ms）还会补一个 `Enter` 真单击 → 由 KEY_TAP_LOCK_MS 归并掉，不会双击。
 */
const KEY_TAP_DEFER_MS = 260;
/**
 * 单击动作的**抑制窗口**（毫秒）：刚做过一次单击动作后，这么久的
 * `GlobalHook` / `Enter` 一律丢弃 —— 它们只是**同一次**单击的前后两个编码。
 * 真机实测两者相隔 530~660ms，故取 900ms；连续两次真实单击间隔远大于此。
 */
const KEY_TAP_LOCK_MS = 900;
/**
 * **双击**判定窗口（毫秒）：两次"点击起点"（`GlobalHook` down）间隔 ≤ 此值 → 判为双击。
 *
 * ★ 真机实测（2026-10-16 11:12:47 桥日志，用户双击）：
 *   `GlobalHook down @11:12:47.767` → `GlobalHook down @11:12:47.922`（**间隔 155ms**），
 *   页面**只收到两次 GlobalHook，没有 Enter**；而旧逻辑把第一次触摸判成单击 → 收起卡片，
 *   于是用户看到的"双击"实际是**我方单击逻辑把他收进了卡片**（不是宿主行为）。
 *   → 因此双击可以、也只能在页面内识别。
 * ★ 窗口取 **220ms**（用户 2026-10-16 11:29 要求"更密集"，原为 300ms）：
 *   · **下界**：实测 155ms 的 1.4 倍 —— 手略慢的正常双击仍落在窗内；
 *   · **上界**：必须 **< KEY_TAP_DEFER_MS(260)** —— 于是双击**总是**在"第一次点击
 *     被判定成单击"**之前**落地，`cancelTapDefer()` 才能真正撤掉那一次单击动作；
 *     间隔 260ms 以上的两次点按**结构上再也不可能**被判成双击
 *     （那正是"多次单击被误识别为双击"的来源，用户实测反馈的问题）。
 *   · 失效方向是安全的：太紧时双击退化成"两次单击"（视频暂停又继续、照片态无动作），
 *     而不是"两次单击变成意外退出"。
 * ★ 三重防线（缺一不可，见 handleHardwareKey ②-a）：
 *   ① **窗口很紧**（220ms，且小于单击判定延迟）；
 *   ② **只认 `GlobalHook`**（`Enter` 是单击的补发码，+530~660ms；若也算点击，
 *      每次单击都会变成"双击退出"）；
 *   ③ **单击一旦落定即断配对**：`fireTempleTap()` 里清掉配对起点，
 *      已生效的单击绝不会再与后面某次点按配成双击。
 * ★ 双击动作 = **一退到底**（与语音「退出」同一条 hardExit 链路，见 handleHardwareKey ②-a）。
 */
const KEY_DOUBLE_TAP_MS = 220;
/**
 * `Backspace` 的**邻近点击归类窗口**（毫秒）：距最近一次"镜腿点击"（`GlobalHook`/`Enter` down）
 * 不超过此值的 `Backspace`，归类为**宿主为一次"手慢双击"发的返回**。
 *
 * ★ 真机取证（2026-10-16 11:33:56 / 11:34:04 桥日志；用户双击，两次间隔 300ms / 287ms）：
 *   `GlobalHook down` ×2 → 我们自己的 220ms 窗口没认出来 → 第二次点击又被 KEY_TAP_LOCK_MS 归并丢掉
 *   → **240~290ms 后宿主补发 `Backspace`** → 其默认行为（返回上一级）把页面收成 **AIUI 卡片态**
 *   —— 就是用户报的"双击出现了非预期的显示卡片状态"。
 *   ★ 由此确认宿主的编码规则：**单击 → `Enter`（确认）、双击 → `Backspace`（返回）**，
 *     `GlobalHook` 只是"触摸"（官方 events.md：区分返回/确认要用 Backspace/Enter，别用 GlobalHook）。
 * ★ 取 1500ms：实测 `Backspace` 落在第二次点击后 240~800ms（11:28:54 那次 797ms），留足余量；
 *   而两次**有意分开**的单击会各收到一个 `Enter`（实测间隔 1.2s 的两下都拿到 Enter）→ 不会误判。
 *
 * ★★ **本窗口只用于日志归类，不再决定"是否接管"**（2026-10-16 11:41 用户要求：
 *   "我不想要见到卡片状态，宿主的双击是不是就是返回到卡片状态，我们能接管就接管掉"）：
 *   全屏智能体里 `Backspace` 的默认行为**只有一种结果 —— 收成卡片态**（它的"上一级"就是卡片），
 *   而页面没有多级导航、不存在需要"返回上一级"的场景 → 因此 `Backspace` **全量接管**（见 ③ 分支）。
 *   ★ "卡片该不该关"由 `onTargetChanged` 的**兜底抢关**独立判定（判据 = 承载位 `_blank -> _current`，
 *     与点击时间无关）；本窗口此后只用于在日志里区分"快双击 / 慢双击"。
 */
const KEY_BACK_TAP_MS = 1500;
/**
 * 镜腿手势 / 硬件键编码 → 翻页方向（**真机实测映射，2026-10-16**）。
 *
 * · `ArrowRight` / `ArrowDown` = **往前滑** → 下一个（用户预期）
 * · `ArrowLeft`  / `ArrowUp`   = **往后滑** → 上一个
 *
 * ★ 一次滑动里两个码指向**同一方向**（右+下 / 左+上），所以无论宿主先报哪个、
 *   或只报其中一个（纯纵向手势），结果都一致 —— 比"只认某一个码"稳。
 * ★ 用户要求「往前滑 = 下一个」→ 本表已按实测调转（旧实现是 ArrowDown→上一个）。
 *   日后若要再调转，只改本表的 ±1 即可。
 */
const KEY_STEP_MAP = {
  ArrowRight: 1,
  ArrowDown: 1,
  ArrowLeft: -1,
  ArrowUp: -1,
};
/**
 * 免唤醒连续识别的空闲自动暂停（省电）。
 *
 * ★ 当前为 **0 = 不自动暂停**：用户要求"智能体使用期间语音识别持续可用"——
 *   长时间不说话也不需要重新喊唤醒词，随时开口说「下一个」即可。
 *   代价是麦克风保持开启（耗电）。若日后要恢复省电行为，改成正整数毫秒即可
 *   （例如 90000 = 空闲 90s 后放开麦克风，轻触或唤醒词恢复）。
 */
const CONTINUOUS_IDLE_MS = 0;
/**
 * 左下角语音状态**行**的点数循环周期（与命令提示行同组，见 .hud-bottom）。
 * 用省略号 1→2→3 个来回循环表达"正在进行"（用户指定：用最后三点的变化表达）。
 */
const VOICE_HUD_TICK_MS = 450;
const VOICE_HUD_DOTS = ['…', '……', '………'];
/**
 * 判定"识别真的停了"的容错次数（**仅兜底路径使用**）。
 * 宿主若不派发会话生命周期事件，就用 isListening() 轮询兜底；此时连续模式下
 * voice.js 的 onend 会把会话标为停止、260ms 后才续听 → 轮询会撞空档，
 * 故必须**连续多次**探测不到才算停止，否则状态条会闪。
 */
const VOICE_HUD_MISS_MAX = 3;
/** 「识别完成」提示的停留时长（显示识别到的文字，随后回到「正在聆听」） */
const VOICE_HUD_DONE_MS = 900;
/** 「识别失败」提示的停留时长（略长，让用户看清失败原因） */
const VOICE_HUD_FAIL_MS = 1400;
/** 「未识别正确指令」底部提示的停留时长 */
const ASR_HINT_MS = 3000;
/** 未识别指令的统一提示文案（原「没听懂，请再说一次」，用户 2026-10-16 定稿：
 *  文案改为引导看命令清单，位置从顶部 toast 移到底部「正在聆听」行上方） */
const ASR_HINT_TEXT = '未识别正确指令，请参考下方指令提示';
/**
 * 窗口模式（卡片态）常驻提示。★ 真机取证（2026-10-16）：收起到卡片态后 InkView
 * non-interactive → getUserMedia 不可用，语音识别**必然**停止，唤醒词「乐奇」/单击镜腿
 * 回到全屏后由 onShow 恢复。提示常驻（不自动消隐），语音真正恢复后清除。
 */
const CARD_MODE_HINT = '语音识别已停止，说"乐奇"重新激活';
/**
 * 服务门禁页（2026-10-16 新增）：启动时桥不可达 → 全屏引导页。
 * 背景：ROM 拦截第三方 BOOT_COMPLETED，重启眼镜后桥**不会自启**，必须由用户手动
 * 打开「照片删除智能体服务」App。门禁页把「桥不可达」从一句 TTS 升级为可停留的
 * 界面（含下载地址），并在桥就绪后**自动恢复**主界面（轮询 /ping），无需重新唤醒。
 * 门禁页唯一可用指令 = 退出（真关闭实例 —— 收起到卡片没有意义：卡片态同样不可用）。
 */
const GATE_POLL_MS = 3000;
/**
 * 门禁页重试的退避上限。
 * 正常路径（桥不可达 → 用户去装/开服务）永远是 GATE_POLL_MS 的节奏，不受影响；
 * 只有"/ping 通了但初始化仍失败"（如权限被撤、索引不可用）这种异常才退避，避免每 3s 无脑重试刷满日志。
 */
const GATE_POLL_MAX_MS = 20000;
const GATE_SPEAK_TEXT = '未检测到照片删除服务，请安装并启动照片删除智能体服务后继续';
const GATE_BLOCK_TEXT = '服务未就绪，请先启动照片删除智能体服务';
/**
 * 退出（门禁页 / 主界面全屏 / 卡片态 —— 统一「一退到底」）的两段式时序（真机取证 2026-10-16，宿主 A2UI 日志）：
 *   · 全屏态 `wx.exitMiniProgram()` 的语义是**退回卡片**，不是关闭
 *     （`card_return_commit_observed desired_surface=card`）；
 *   · 而 `window.close()` **只在卡片态被宿主接手**（全屏态调用被忽略）。
 *   所以必须先收起成卡片，等宿主落定承载位（`fullscreen_return_animation_complete`
 *   实测在请求后约 200~500ms）再请求真关闭。
 *   ★ 卡片态下宿主会禁用交互与语音拦截（`interaction_enabled=false`
 *     `voice_interceptor_registered=false`），用户**不可能**再喊第二次「退出」，
 *   这两步必须自动串起来。
 */
const EXIT_CLOSE_STAGE_MS = 700;
/** 真关闭未生效时的重试间隔与总轮数（1 = 首轮 + 1 次重试，封顶防死循环） */
const EXIT_CLOSE_RETRY_MS = 1200;
const EXIT_CLOSE_MAX_PASS = 1;
/** 两轮仍存活时的兜底提示（卡片态语音已被宿主禁用，只能靠唤醒词回来） */
const EXIT_CLOSE_STUCK_TEXT = '退出未生效，请说"乐奇"唤醒后重试';
/**
 * 退出前铺黑色遮罩、到发出收起请求之间的等待（毫秒）。
 * ★ 存在意义（消闪）：宿主把全屏收成卡片时会**抓取当前页面渲染**当缩略图，于是用户会看到
 *   "内容缩成一张小卡片闪一下"。先让整页渲染成纯黑再请求收起，卡片缩略图就是黑场，
 *   观感从"画面缩小闪动"变成"暗下去 → 消失"。
 *   ★ 实测取值：140ms 仍偶有一丝（宿主抓的是**已合成帧**，从 setData 到合成上屏要跨
 *     渲染 + 合成两级管线）→ 提到 260ms（约两帧以上的余量）。这段时间是全黑屏，
 *     主观上就是"眨眼"，不会让人觉得退出变慢。
 */
const EXIT_VEIL_MS = 260;
/**
 * 抢跑试关的间隔与次数（毫秒 / 次）：见 hardExit ③。
 * ★ 卡片态的"对话框外框"是**宿主容器装饰**，画在页面渲染区之外 —— 页面内的黑场遮罩
 *   **物理上盖不住它**（真机实测：内容已不可见，但外框仍闪现）。所以对这圈外框唯一的手段
 *   就是**把卡片态存在的时间压到最短**：每 40ms（≈2 帧）试一次 `window.close()`，
 *   宿主一切到卡片态语义就立刻命中，外框可见时长 ≈ 一个抢跑间隔。
 *   40 次 × 40ms ≈ 1.6s，覆盖收起动画（实测 200~500ms 落定）+ 宿主处理余量。
 * ★ 未切到卡片态时这些调用被宿主忽略，无副作用（全屏态 window.close() 本就不被接手）。
 */
const EXIT_RACE_MS = 40;
const EXIT_RACE_MAX = 40;
/**
 * 识别失败原因的中文映射（`error` 事件的 `error` 字段是稳定英文类别）。
 * 未收录的类别直接原样显示，便于真机排障时一眼看出是哪一类。
 */
const VOICE_FAIL_TEXT = {
  'no-speech': '没听到声音',
  nomatch: '没听懂',
  aborted: '已中止',
  'audio-capture': '麦克风不可用',
  'not-allowed': '麦克风未授权',
  network: '网络异常',
  timeout: '识别超时',
  unsupported: '环境不支持',
};
/**
 * 退出请求的延迟（官方 close 示例做法：延后一拍再发关闭请求）。
 * 在语音回调链路里同步调用关闭，容易被当前事件流吞掉 → 页面仍然可见。
 */
/**
 *
 * v0.18 规范核查结论（documentation/3-api/weixin-compatible-apis.md 的
 * 「微信小程序兼容 API」清单）：官方只兼容
 *   wx.canIUse / arrayBufferToBase64 / request / connectSocket / createSocket /
 *   createEventSource / storage 四件套(+Sync) / createCanvasContext /
 *   navigateTo / redirectTo / navigateBack / speech.playTTS /
 *   speech.startRecognition / media.createCameraContext / media.getRecorderManager /
 *   createVideoContext / getWindowInfo / exitMiniProgram / setBackgroundColor
 * —— **不包含 `wx.showToast`**（它只出现在文档示例里，不在兼容清单与 API 参考中）。
 * 因此移除原先的 `USE_NATIVE_TOAST` 实验开关与 `wx.showToast` 分支，
 */

export default {
  data: {
    ready: false,
    // 服务门禁页（启动时桥不可达 → 全屏引导；桥就绪后自动恢复，见 bootstrap/enterGate）
    gate: false,
    // 退出流程中的纯黑遮罩（消闪，见 EXIT_VEIL_MS）
    exiting: false,
    empty: false,

    // 底部居中信息条：面包屑 + 视频时间
    breadcrumb: '0/0',
    title: '',

    // 媒体
    src: '',
    // ★★ 视频专用地址（与照片的 `src` **分离**，2026-10-16 真机 bug 修复）：
    //   切到照片时必须把它清空。否则宿主"A2UI 补丁先改属性、后摘元素"的顺序下，
    //   图片地址会被赋给 <video> 的视频桥 → 报 `queueAccessUnit failed: Java exception was thrown`，
    //   页面误判"这个视频不能播"，在照片上错误弹出「视频无法播放」（用户实测复现）。
    //   <video> 只绑这个字段；它是空串时元素（即使是残留的一帧）也拿不到媒体地址。
    videoSrc: '',
    poster: '',
    isVideo: false,
    // 视频播放失败（如 H.265 编码不受支持）→ 卸载 <video>，显示占位界面
    // （不卸载的话宿主会在 video 画面区持续绘制 ASCII 错误占位符）
    videoBroken: false,
    // ★ 可播性决策门控：false = <video> 不挂载（HEVC 源未判定前不能喂给宿主）
    videoReady: false,

    // 视频时间轴（`0:00 / 0:00`；进度线已按用户要求移除，故不再保留进度百分比状态）
    timeline: '0:00 / 0:00',
    totalText: '0:00',
    playing: false,

    // 交互状态
    pendingDelete: false,


    // 居中加载指示（照片/视频就绪前显示；视频可能是较慢的源，如 H.265 需转码）
    loading: false,
    loadingText: '加载中',

    // 语音识别状态条：四态（正在聆听 / 识别中 / 识别完成 / 识别失败）
    voiceHudVisible: false,
    voiceHudText: '',

    // 命令提示行文案（空库时收缩为「可用语音命令：退出」）
    cmdHint: '可用语音命令：下一个，上一个，删除，确认删除，取消，退出',

    // 底部提示行（底部信息组内、正在聆听行上方；自动消隐）：
    // 承担**所有错误反馈** + 未识别指令引导（用户 2026-10-16 定稿，顶部 toast 只留中性/成功类）
    asrHint: '',
  },

  /* ---------------- 生命周期 ---------------- */

  async onLoad() {
    this.hostTarget = ''; // 宿主承载位（_current=卡片态/_blank=全屏），见 onTargetChanged
    this.exitPending = false; // 退出流程进行中（onTargetChanged 的消闪分支据此接管）
    this.hardExitStarted = false; // 「一退到底」是否已发起（防重入，见 hardExit）
    this.exitTimer = null; // 退出流程的兜底定时器
    this.exitRaceLeft = 0; // 抢跑试关的剩余次数（见 raceClose）
    this.exitRaceTimer = null; // 抢跑试关的链式定时器
    this.videoCtx = null;
    this.videoDurationSec = 0; // 当前视频总时长缓存（桥 /probe 确认 / 递增兜底回填）
    // ★ 该时长**归属的条目 id**（2026-10-16 时长串位 bug 的修复件）：
    //   总时长只认"条目绑定"的来源，见 resolveDurationSec / applyDuration。
    //   '' = 当前无有效归属（切条即清）。
    this.videoDurationItemId = '';
    this.pendingTimer = null;
    this.pendingListenTimer = null;
    this.pendingTargetId = null;
    // 左下角语音状态行：点循环定时器（recursive setTimeout，见 scheduleVoiceHudTick）
    this.voiceHudTimer = null;
    // 「识别完成 / 识别失败」提示的停留计时器
    this.voiceHudHoldTimer = null;
    // 「未识别正确指令」底部提示的停留计时器（见 showAsrHint）
    this.asrHintTimer = null;
    this.voiceHudTick = 0;
    this.voiceHudMiss = 0;
    this.voiceHudPhase = 'idle';
    this.voiceHudDetail = '';
    // 镜腿/硬件键：动作归并窗口（见 KEY_GESTURE_LOCK_MS / KEY_TAP_LOCK_MS）
    this.gestureLockUntil = 0;
    this.tapLockUntil = 0;
    // 单击判定延迟计时器（`GlobalHook` 后等待"是否其实是滑动"，见 KEY_TAP_DEFER_MS）
    this.tapDeferTimer = null;
    // 最近一次"点击起点"（GlobalHook down）的时间戳，0=无待配对点击（见 KEY_DOUBLE_TAP_MS）
    this.lastTapDownAt = 0;
    // 该"点击起点"落下时**是否处于删除二次确认态**（快照）：确认态里单击/双击**都算取消**，
    // 不能因为第一次单击已把确认态取消掉（pendingDelete 变假）就把慢双击升级成"退出"。
    this.lastTapWasPending = false;
    // 最近一次"镜腿触摸"（GlobalHook / Enter 的 down）时间戳，0=从未。
    // ★ 与 lastTapDownAt 不同：那个是"待配对起点"（用过即清），这个是**只读时间参考**，
    //   现仅用于在日志里区分 `Backspace` 是"快双击"还是"慢双击"（见 KEY_BACK_TAP_MS —— 接管已是全量）。
    this.lastKeyTouchAt = 0;
    // 服务门禁页的 /ping 轮询计时器（见 GATE_POLL_MS）
    this.gateTimer = null;
    // 门禁页"/ping 通但初始化失败"的连续次数（用于指数退避，见 gateTick）
    this.gateReattempts = 0;

    await this.bootstrap(true);
  },

  /**
   * 启动引导：桥探测 → 就绪走正常初始化渲染；不可达进服务门禁页。
   * 门禁页轮询到 /ping 恢复后也会重走这里（first=false），完成自动进入主界面。
   */
  async bootstrap(first) {
    let info = null;
    let initErr = '';
    try {
      info = await store.init();
    } catch (err) {
      initErr = String((err && err.message) || err);
      console.warn('[page] 初始化失败：', err);
    }
    if (!info || !info.opfsReady) {
      this.enterGate(initErr || (info && info.error) || '');
      return;
    }

    // 门禁页恢复：先撤门禁页并报「服务已就绪」，随后的正常播报排队接上
    if (this.data.gate) {
      this.exitGate();
      voice.speak('服务已就绪', { interrupt: true });
    }

    const parts = [];
    parts.push('桥已就绪');
    if (info.opfsFileCount != null) parts.push(`系统相册 ${info.opfsFileCount} 项`);
    if (store.statusText && store.statusText()) parts.push(store.statusText());
    // 诊断信息不再上屏（需求 4：界面只留媒体 + 必要信息），改由桥日志回传 PC
    try {
      bridgeReport(
        `init ${parts.join(' | ')} | voice rec=${voice.isRecognitionAvailable()} tts=${voice.isSynthesisAvailable()}`
      );
      // 退出能力体检：宿主是否暴露了 window.close / wx.exitMiniProgram
      let envText = 'env ';
      try {
        envText += `window=${typeof window !== 'undefined'} `;
        envText += `window.close=${typeof window !== 'undefined' && typeof window.close === 'function'} `;
      } catch (err) {
        envText += 'window=err ';
      }
      try {
        envText += `wx.exitMiniProgram=${typeof wx.exitMiniProgram === 'function'}`;
      } catch (err) {
        envText += 'wx=err';
      }
      bridgeReport(envText);
    } catch (err) {
      /* 忽略 */
    }
    voice.speak(
      info.opfsFileCount > 0 ? `已连接系统相册，共 ${info.opfsFileCount} 项` : '系统相册为空',
      { interrupt: false }
    );

    this.setData({ ready: true });
    this.renderCurrent({ announce: false });
    // 免唤醒：页面起来就先尝试开一个连续识别会话（若宿主要求"必须由用户交互启动"，
    // 这次会失败并被唤醒词/轻触补上，不影响功能）
    this.ensureListening('ready');
  },

  /* ---------------- 服务门禁页 ---------------- */

  /** 进入门禁页：全屏接管 + TTS 引导 + 开始轮询 /ping（桥就绪即自动恢复） */
  enterGate(reason) {
    try {
      bridgeReport(`gate enter 桥不可达 ${String(reason || '').slice(0, 120)}`);
    } catch (err) {
      /* 忽略 */
    }
    if (!this.data.gate) {
      this.setData({
        gate: true,
        ready: true,
        empty: false,
        loading: false,
        pendingDelete: false,
        videoBroken: false,
        videoReady: false,
        // 门禁页唯一可用指令=退出；序号/时间行隐藏（见模板的 !gate 判定）
        cmdHint: '可用语音命令：退出',
      });
      voice.speak(GATE_SPEAK_TEXT, { interrupt: true });
    }
    // 门禁页同样保持免唤醒识别（用户随时可以说「退出」或被唤醒词叫回）
    this.ensureListening('gate');
    this.startGatePolling();
  },

  exitGate() {
    this.stopGatePolling();
    if (this.data.gate) this.setData({ gate: false });
    try {
      bridgeReport('gate exit 桥已就绪，恢复主界面');
    } catch (err) {
      /* 忽略 */
    }
  },

  /**
   * 门禁页轮询：每 GATE_POLL_MS 探一次 /ping；getJson 内部会自动重做基址发现。
   * 探测逻辑抽成 gateTick()，供两条入口复用：
   *   ① 定时轮询（页面存活期间的自愈，覆盖"桥被 LMK 杀 → START_STICKY 自己回来"的窗口）；
   *   ② onShow 回到前台的**立即补探**（见 probeGateNow）。
   */
  startGatePolling() {
    this.stopGatePolling();
    this.gateTimer = setTimeout(() => this.gateTick(), GATE_POLL_MS);
  },

  /**
   * ★ 加固：立即补探一次，由 onShow（回到前台）调用。
   * 为什么需要：页面退到后台期间宿主可能挂起 setTimeout，只靠轮询会漏掉"桥已就绪"的那一刻，
   * 表现为「桥早就起来了、页面还停在门禁页」的假死；回前台立刻重查可保证状态永远是最新的。
   * 先清掉在途定时器再探 —— 每拍都会续约，若不清会叠出两条并行轮询链。
   */
  probeGateNow() {
    if (!this.data.gate) return;
    this.stopGatePolling();
    this.gateTick();
  },

  /** 门禁页单次探测：桥就绪 → 重走 bootstrap（内部撤门禁页）；否则按节奏续约下一次 */
  async gateTick() {
    if (!this.data.gate) return;
    let pingOk = false;
    try {
      const pong = await bridgeGetJson('/ping');
      pingOk = !!(pong && pong.ok);
    } catch (err) {
      /* 仍不可达，按常规节奏重试 */
    }
    if (!this.data.gate) return; // 等待期间被撤（用户退出 / bootstrap 已恢复），不再续约
    if (!pingOk) {
      this.gateReattempts = 0;
      this.gateTimer = setTimeout(() => this.gateTick(), GATE_POLL_MS);
      return;
    }
    // /ping 通 → 重走初始化；若仍失败（端口通了但索引/授权异常）则指数退避，
    // 正常恢复路径不受影响（一次成功即撤页并把计数清零）。
    await this.bootstrap(false);
    if (this.data.gate) {
      this.gateReattempts = (this.gateReattempts || 0) + 1;
      this.gateTimer = setTimeout(
        () => this.gateTick(),
        Math.min(GATE_POLL_MS * Math.pow(2, this.gateReattempts), GATE_POLL_MAX_MS)
      );
    } else {
      this.gateReattempts = 0;
    }
  },

  stopGatePolling() {
    if (this.gateTimer) {
      clearTimeout(this.gateTimer);
      this.gateTimer = null;
    }
  },

  /**
   * 「一退到底」退出：**一次指令走完整条真关闭链路**（用户 2026-10-16 10:25 定稿）。
   * 门禁页退出、主界面**全屏**退出、主界面**卡片态**退出 —— 三者统一走这一条链路，
   * 不再有旧的"全屏只收起到卡片"两级语义（用户实测：全屏态说「退出」只回到卡片，不可接受）。
   *
   * ★ 实现上是两步（见 EXIT_CLOSE_STAGE_MS 处的取证说明）：
   *   ① `wx.exitMiniProgram()` 收起成卡片（若已在卡片态，语义为退出当前实例）；
   *   ② 等承载位落定后，在**卡片态**请求 `window.close()` + `wx.exitMiniProgram()` 兜底
   *      —— 这才是宿主真正接手的关闭通道（旧版只做了 ② 里的 window.close()，
   *      在全屏态被忽略，于是「退出」表现为退回卡片）。
   * 两步之间不能等用户再喊一次：卡片态宿主已禁用语音拦截。
   *
   * @param {string} src 触发来源（gate / fullscreen / card），仅用于桥日志取证。
   */
  hardExit(src) {
    // ★ 防重入：同一次退出只跑一次。全屏态语音仍在识别，用户可能连说两遍「退出」，
    //   第二次进来会再发一次收起请求 → 又一轮抖动（且黑场会先撤再铺）。
    if (this.hardExitStarted) return;
    this.hardExitStarted = true;
    if (this.data.gate) this.stopGatePolling();
    try {
      voice.stopSpeaking();
    } catch (err) {
      /* 忽略 */
    }
    try {
      bridgeReport(`exit src=${src} 一退到底（黑场 + 两段式真关闭 + 密集抢跑）`);
    } catch (err) {
      /* 忽略 */
    }
    this.showAsrHint('正在退出…');
    // ① 先铺黑场：宿主收起时**抓取当前渲染**当卡片缩略图，黑场 → 卡片不显内容，
    //    观感从"画面缩小闪一下"变成"暗下去 → 消失"（见 EXIT_VEIL_MS）
    this.setData({ exiting: true });
    // ② 黑场上屏后再请求收起（全屏 → 卡片）
    setTimeout(() => {
      this.exitPending = true;
      try {
        wx.exitMiniProgram({ complete: () => {} });
      } catch (err) {
        /* 忽略 */
      }
      // ③ **密集抢跑**：卡片态的"对话框外框"是宿主容器装饰，画在**页面渲染区之外**，
      //    页面内的黑场遮罩物理上盖不住它 —— 所以对这圈外框唯一的手段就是**把卡片态存在的时间
      //    压到最短**：宿主一把它当作卡片态处理，最近一次 window.close() 就立刻命中（页面销毁，
      //    后续定时器随之消失）。间隔 EXIT_RACE_MS（≈2 帧），比等 onTargetChanged 往返回合快。
      //    ★ 只调 close、**绝不重复调 exitMiniProgram**：后者在全屏态会再触发一次收起动画，
      //      重复收起本身就是新的抖动源。
      //    ★ 全屏态/未就绪态的 close 被宿主忽略，失败无副作用（真机多次验证）。
      this.exitRaceLeft = EXIT_RACE_MAX;
      this.raceClose();
      // ④ 兜底：宿主若不上报承载位变化，仍按固定时长续上第二步（功能不回归）
      this.exitTimer = setTimeout(() => {
        if (!this.exitPending) return; // 事件分支已接手
        this.exitPending = false;
        this.requestRealClose(0);
      }, EXIT_CLOSE_STAGE_MS);
    }, EXIT_VEIL_MS);
  },

  /**
   * 卡片态请求真关闭；未生效则再收再关一轮（EXIT_CLOSE_MAX_PASS 封顶）。
   * 页面若真的被关闭，后面的定时器随实例一起消失，不会有多余动作。
   */
  requestRealClose(pass) {
    try {
      window.close();
      bridgeReport(`exit window.close() 已调用 pass=${pass}`);
    } catch (err) {
      /* 忽略 */
    }
    setTimeout(() => {
      try {
        wx.exitMiniProgram({ complete: () => {} });
      } catch (err) {
        /* 忽略 */
      }
    }, 80);
    if (pass >= EXIT_CLOSE_MAX_PASS) {
      // 两轮都没关掉 → 撤黑场，让用户看得见提示并靠唤醒词回来（否则面对黑屏无从下手）
      setTimeout(() => {
        this.setData({ exiting: false });
        this.hardExitStarted = false; // 允许唤醒回来后重试「退出」
        this.showAsrHint(EXIT_CLOSE_STUCK_TEXT, 0);
      }, EXIT_CLOSE_RETRY_MS);
      return;
    }
    setTimeout(() => this.requestRealClose(pass + 1), EXIT_CLOSE_RETRY_MS);
  },

  /**
   * 抢跑关闭（见 hardExit ③）：密集试 `window.close()`，宿主一切到卡片态语义即命中，
   * 把"卡片外框可见时长"压到一个抢跑间隔（≈2 帧）。
   * 页面被销毁后本链不再执行；始终未命中则跑满 EXIT_RACE_MAX 次后自动停（不无限重试）。
   */
  raceClose() {
    if (this.exitRaceLeft <= 0) return;
    this.exitRaceLeft -= 1;
    try {
      window.close();
    } catch (err) {
      /* 忽略 */
    }
    this.exitRaceTimer = setTimeout(() => this.raceClose(), EXIT_RACE_MS);
  },

  onReady() {
    if (this.data.isVideo) this.playVideo(true);
  },

  onShow() {
    // 从后台回到前台时，视频根据可见性由宿主自动恢复。
    // 若是被唤醒词/系统重新带回前台，确保免唤醒会话在跑。
    this.ensureListening('show');
    // ★ 加固：门禁页期间回到前台 → 立刻补探一次桥。
    //   后台定时器可能被挂起，缺这一步会出现「桥已就绪、页面仍停在门禁页」的假死
    //   （用户觉得要退出重进，其实一次探测就能恢复）。非门禁态此调用直接返回，零开销。
    this.probeGateNow();
  },

  /**
   * 宿主承载位变化（卡片态 _current ↔ 全屏 _blank）。
   * 用于窗口/全屏模式判定（isCardMode）；同时把事件写桥日志作真机取证。
   */
  onTargetChanged(target, previousTarget) {
    // ★ 先抓"上一态"（previousTarget 未必被宿主传入，用本地记录的承载位兜底）
    const prev = previousTarget || this.hostTarget || '';
    this.hostTarget = target || '';
    try {
      bridgeReport(`target ${prev || '?'} -> ${target || '?'}`);
    } catch (err) {
      /* 忽略 */
    }
    // ★ 退出消闪：收起动作落定在卡片态的**那一瞬**就请求关闭，不再死等 EXIT_CLOSE_STAGE_MS
    //   —— 卡片态（此时已是黑场）只存在几十毫秒，用户几乎看不到中间态。
    //   用 exitPending 严格门控：**只有「一退到底」链路（hardExit）会把 exitPending 置真**，
    //   镜腿单击那种"只想收起到卡片"的路径不要动这个标志，否则会连卡片一起被关掉。
    if (this.exitPending && target === '_current') {
      this.exitPending = false;
      if (this.exitTimer) {
        clearTimeout(this.exitTimer);
        this.exitTimer = null;
      }
      this.requestRealClose(0);
      return;
    }
    // ★★ 兜底抢关（用户 2026-10-16 11:41 / 11:46："我不想要见到卡片状态 …… 能接管就接管掉"）：
    //   本智能体**只有语音唤醒一条入口**（用户确认：没有桌面图标、不存在"点卡片启动"），
    //   正常使用时承载位应当是 `_blank`（全屏）→ 因此
    //   **「从全屏被收成 `_current`（卡片）」= 不该出现的状态**，来源只有两种，来意都是"结束浏览"：
    //     · 宿主的"返回"默认行为（双击的 `Backspace` 通道）没被 `preventDefault()` 拦住；
    //     · 宿主其它把页面收起的动作。
    //   两者一律在卡片态请求真关闭，把卡片存在时长压到几十毫秒（用户看不到"停留"的卡片）。
    //   ★ 唯一判据 `prev === '_blank'`：只关"**从全屏收起**"的卡片。页面首帧若本就落在卡片态
    //     （承载位未知/非全屏来源）**不动作** —— 防止把启动路径误伤成"一开就自杀"。
    if (target === '_current' && prev === '_blank') {
      const sinceTouch = this.lastKeyTouchAt ? Date.now() - this.lastKeyTouchAt : -1;
      bridgeReport(
        `target _blank -> _current（全屏被收起，距最近镜腿点击 ${sinceTouch}ms）→ 兜底抢关，不在卡片态停留`
      );
      this.exitPending = true;
      this.requestRealClose(0);
    }
  },

  onHide() {
    this.exitPendingDelete('pause');
    this.clearAsrHint();
    this.clearIdleTimer();
    this.stopVoiceHud();
    this.cancelTapDefer();
    voice.abortListening();
  },

  onUnload() {
    this.exitPendingDelete('pause');
    this.clearAsrHint();
    this.clearIdleTimer();
    this.stopVoiceHud();
    this.cancelTapDefer();
    this.stopTranscodePolling();
    this.stopGatePolling();
    if (this.exitTimer) {
      clearTimeout(this.exitTimer);
      this.exitTimer = null;
    }
    if (this.exitRaceTimer) {
      clearTimeout(this.exitRaceTimer);
      this.exitRaceTimer = null;
    }
    this.exitPending = false;
    voice.dispose();
    this.videoCtx = null;
  },

  /* ---------------- 语音唤醒（宿主原生） ---------------- */

  onVoiceWakeup(event) {
    // 留痕：唤醒来源（`乐奇`/`Hi Rokid` = 语音；`clickAiAssist` = 触控唤醒）
    // —— 排查镜腿单击是否也会触发触控唤醒时，这行日志是直接证据。
    try {
      const kw = event && event.keyword ? event.keyword : 'screen-tap';
      bridgeReport(`voicewakeup keyword=${kw} listening=${voice.isListening()}`);
    } catch (err) {
      /* 忽略 */
    }
    if (voice.isListening()) {
      // 免唤醒会话已在跑：唤醒词此时只是"叫醒界面"，无需重开会话
      this.showAsrHint(this.data.pendingDelete ? '请说「确认」或「取消」' : '请说命令…');
      this.markListeningActive();
      return;
    }
    this.showAsrHint(this.data.pendingDelete ? '请说「确认」或「取消」' : '请说命令…');
    this.listenOnce('wakeup');
  },

  /** 确保免唤醒会话处于运行状态（轻触/回到前台时调用；已在跑则只刷新计时） */
  ensureListening(source) {
    if (voice.isListening()) {
      this.markListeningActive();
      return;
    }
    this.listenOnce(source);
  },

  /**
   * 开启（或维持）**免唤醒连续识别**会话。
   *
   * 关键改进（用户需求）：一次唤醒/轻触之后，用户直接说「下一个」「删除」即可，
   * 不需要每次都先说唤醒词。实现见 lib/voice.js 的 `continuous` 分支
   * （官方 `recognition.continuous` = 「是否在一条结果后继续识别」）。
   *
   * 删除确认态等"必须听清"的场景同样直接复用这一个常驻会话，不再反复重启。
   *
   * @param {string} source 触发来源，仅用于日志
   */
  listenOnce(source) {
    if (voice.isListening()) return;

    const started = voice.startListening({
      continuous: true,
      onResult: ({ transcript }) => this.handleTranscript(transcript),
      // 会话相位（正在聆听 / 检测到语音 / 出结果 / 出错）→ 驱动底部四态状态条
      onPhase: (evt) => this.onVoicePhase(evt),
      onError: (err) => {
        const code = err && err.error;
        try {
          bridgeReport(`voice error code=${code} msg=${(err && err.message) || ''} src=${source}`);
        } catch (e) {
          /* 忽略 */
        }
        // 连续识别维持不住 → 退回"每次都要唤醒"的老行为，界面给一次提示
        if (code === 'continuous-failed') {
          this.showAsrHint('已暂停聆听，说唤醒词继续');
          return;
        }
        // 删除确认态内：没听清就继续听，不要打断用户
        if (code === 'timeout' && this.data.pendingDelete) {
          setTimeout(() => {
            if (this.data.pendingDelete) this.listenOnce('pending-retry');
          }, 260);
          return;
        }
        // 完全没听到声音（timeout / no-speech）= 常态，**静默不响应**（用户 2026-10-16 定稿）：
        // 不弹 toast、不播报；删除确认态内仍需静默续听（见上方 timeout 分支）。
        if (code === 'timeout' || code === 'no-speech') return;
        // 窗口模式（卡片态）：麦克风被宿主禁用，识别错误必然发生 → 统一显示常驻引导
        if (this.isCardMode()) {
          this.showAsrHint(CARD_MODE_HINT, 0);
          return;
        }
        // 真实识别错误（麦克风不可用/未授权/网络等）→ 底部提示行，带具体原因
        this.showAsrHint(`识别失败（${VOICE_FAIL_TEXT[code] || code}）`);
      },
      onEnd: () => {
        // 连续模式由 voice 层自动续听；单轮模式才需要外部再触发
      },
    });

    if (started) this.markListeningActive();

    try {
      bridgeReport(
        `listen started=${started} continuous=${voice.isContinuous()} src=${source} pending=${this.data.pendingDelete}`
      );
    } catch (err) {
      /* 忽略 */
    }
  },

  /**
   * 记录"聆听已开启"的时刻，用于空闲自动暂停（省电）。
   * 每次拿到识别结果都会刷新，所以只有真正长时间没人说话才会暂停。
   */
  markListeningActive() {
    this.lastVoiceAt = Date.now();
    // 会话活跃 → 点亮底部状态条（幂等；不会打断"识别完成/失败"提示）
    this.ensureVoiceHud();
    if (this.idleTimer) {
      clearTimeout(this.idleTimer);
      this.idleTimer = null;
    }
    // ★ 持续可用：CONTINUOUS_IDLE_MS 为 0 时不设空闲暂停计时器（麦克风保持可用）
    if (CONTINUOUS_IDLE_MS > 0) {
      this.idleTimer = setTimeout(() => {
        this.idleTimer = null;
        this.pauseListeningForIdle();
      }, CONTINUOUS_IDLE_MS);
    }
  },

  /** 空闲过久 → 停掉常驻麦克风（省电），轻触或唤醒即可恢复（默认关闭，见 CONTINUOUS_IDLE_MS） */
  pauseListeningForIdle() {
    if (CONTINUOUS_IDLE_MS <= 0) return;
    if (!voice.isContinuous()) return;
    voice.abortListening();
    this.stopVoiceHud();
    try {
      bridgeReport(`listen idle-pause 已暂停聆听（空闲 ${CONTINUOUS_IDLE_MS}ms）`);
    } catch (err) {
      /* 忽略 */
    }
    this.showAsrHint('已暂停聆听，轻触屏幕或说唤醒词继续');
  },

  clearIdleTimer() {
    if (this.idleTimer) {
      clearTimeout(this.idleTimer);
      this.idleTimer = null;
    }
  },

  /* ---------------- 左下角：语音识别状态（四态） ---------------- */
  //
  // 四态文案由**会话生命周期事件**驱动（`lib/voice.js` 的 `onPhase`），而不是靠轮询猜测：
  //   正在聆听 ← start / audiostart        （会话就绪、麦克风开着，等你说话）
  //   识别中   ← soundstart / speechstart  （检测到声音 / 检测到语音）
  //   识别完成 ← result                    （拿到最终结果，短暂停留后回到"正在聆听"）
  //   识别失败 ← error                     （真实识别错误；"没听到"是常态，不算失败）
  //
  // 呈现（用户定稿）：屏幕左下角、与命令提示行同一左边界上下相邻 + 半透明黑底(50%)胶囊
  //   + 16px 单色高亮字（与「视频无法播放」标题同档）。
  //   单绿屏只有一个绿色通道 → 四态**不靠色相区分**，语义由完整文案承担
  //   （如「识别完成：下一个」「识别失败（网络异常）」）。
  //
  // 容错：宿主若一个生命周期事件都不派发（`voice.hasLifecycleEvents()` 为 false），
  //   自动退回"轮询 isListening()"兜底 —— 此时仍会显示「正在聆听…」，不会出现空白。

  /** 语音层上报的相位变化（事件驱动入口） */
  onVoicePhase(evt) {
    const phase = evt && evt.phase;
    if (!phase) return;

    if (phase === 'listening') {
      this.setVoiceHud('listening');
      // 识别在跑（含卡片态——实测 collapse 后语音常能继续）→ 清掉「语音识别已停止」提示
      if (this.data.asrHint === CARD_MODE_HINT) this.clearAsrHint();
      // 会话新起一轮 → 刷新"有人在用"的时刻（空闲暂停默认关闭，此处仍保留语义）
      this.markListeningActive();
      return;
    }
    if (phase === 'speech') {
      this.setVoiceHud('recognizing');
      return;
    }
    if (phase === 'done') {
      this.setVoiceHud('done', evt.transcript);
      return;
    }
    if (phase === 'fail') {
      // 连续识别维持不住 → 会话已停，状态条收起（提示由 onError 走底部提示行）
      if (evt.code === 'continuous-failed') {
        this.stopVoiceHud();
        return;
      }
      // ★ 其余 fail 相位不再上状态条（用户 2026-10-16 定稿：反馈提示只留一处）——
      //   真实错误的「识别失败（原因）」由 onError 统一走底部提示行，
      //   状态条静默，等下一轮 listening / idle 自然刷新。
      return;
    }
    if (phase === 'idle') {
      // "完成/失败"提示期内不立即收起，等提示走完（届时会自行判断会话是否还活着）
      if (this.voiceHudPhase === 'done' || this.voiceHudPhase === 'fail') return;
      this.stopVoiceHud();
    }
  },

  /**
   * 设置状态条相位并重绘（幂等）。
   *
   * `done` / `fail` 是"提示态"：停留 VOICE_HUD_DONE_MS / VOICE_HUD_FAIL_MS 后
   * 自动回到「正在聆听」（会话还活着）或收起（会话已停）。
   *
   * @param {'listening'|'recognizing'|'done'|'fail'} phase
   * @param {string} [detail] done=识别到的文字；fail=错误码
   */
  setVoiceHud(phase, detail) {
    this.voiceHudPhase = phase;
    this.voiceHudDetail = detail == null ? '' : String(detail);
    if (this.voiceHudHoldTimer) {
      clearTimeout(this.voiceHudHoldTimer);
      this.voiceHudHoldTimer = null;
    }
    this.voiceHudTick = 0;
    this.renderVoiceHud();

    if (phase === 'done' || phase === 'fail') {
      const hold = phase === 'done' ? VOICE_HUD_DONE_MS : VOICE_HUD_FAIL_MS;
      this.voiceHudHoldTimer = setTimeout(() => {
        this.voiceHudHoldTimer = null;
        if (voice.isListening()) {
          this.setVoiceHud('listening');
        } else {
          this.stopVoiceHud();
        }
      }, hold);
    }
    if (!this.voiceHudTimer) this.scheduleVoiceHudTick();
  },

  /** 幂等点亮：不在"完成/失败"提示期时，保证状态条处于聆听态 */
  ensureVoiceHud() {
    if (!this.data.voiceHudVisible) {
      this.setVoiceHud('listening');
      return;
    }
    const p = this.voiceHudPhase;
    if (p === 'done' || p === 'fail') return; // 让提示显示完
    if (p !== 'listening') this.setVoiceHud('listening');
  },

  /** 按当前相位 + 点数重绘文案 */
  renderVoiceHud() {
    const phase = this.voiceHudPhase || 'listening';
    this.setData({
      voiceHudVisible: true,
      voiceHudText: voiceHudLabel(phase, this.voiceHudTick, this.voiceHudDetail),
    });
  },

  /** 点循环定时器（recursive setTimeout，与本文件其它计时器同一套可用性假设） */
  scheduleVoiceHudTick() {
    this.voiceHudTimer = setTimeout(() => {
      this.voiceHudTimer = null;
      this.tickVoiceHud();
    }, VOICE_HUD_TICK_MS);
  },

  /**
   * 心跳：推进省略号点数。
   *
   * 仅在**从未收到生命周期事件**时才做存活轮询（兜底），
   * 连续多次探测不到才认为已停止 —— 躲开续听的 ~260ms 空档。
   */
  tickVoiceHud() {
    if (!voice.hasLifecycleEvents()) {
      if (voice.isListening()) {
        this.voiceHudMiss = 0;
      } else {
        this.voiceHudMiss = (this.voiceHudMiss || 0) + 1;
        if (this.voiceHudMiss >= VOICE_HUD_MISS_MAX) {
          this.stopVoiceHud();
          return;
        }
      }
    }
    const p = this.voiceHudPhase;
    // 只有"进行中"的两态需要点数动效；完成/失败是静态提示
    if (p === 'listening' || p === 'recognizing') {
      this.voiceHudTick = (this.voiceHudTick || 0) + 1;
      this.renderVoiceHud();
    }
    this.scheduleVoiceHudTick();
  },

  /** 收起状态条（幂等） */
  stopVoiceHud() {
    if (this.voiceHudTimer) {
      clearTimeout(this.voiceHudTimer);
      this.voiceHudTimer = null;
    }
    if (this.voiceHudHoldTimer) {
      clearTimeout(this.voiceHudHoldTimer);
      this.voiceHudHoldTimer = null;
    }
    this.voiceHudMiss = 0;
    this.voiceHudPhase = 'idle';
    if (this.data.voiceHudVisible) this.setData({ voiceHudVisible: false });
  },

  /* ---------------- 命令处理 ---------------- */

  handleTranscript(transcript) {
    const text = String(transcript || '').trim();
    // 听到语音即刷新空闲计时（免唤醒会话在"有人在用"时应一直保持）
    if (voice.isContinuous()) this.markListeningActive();
    if (!text) {
      this.showAsrHint(ASR_HINT_TEXT);
      return;
    }

    const result = route(text, { pending: this.data.pendingDelete });
    try {
      bridgeReport(`cmd「${text}」→ ${result.intent}`);
    } catch (err) {
      /* 忽略 */
    }
    this.handleIntent(result);
  },

  handleIntent(result) {
    const intent = result.intent;

    // 服务门禁页：唯一可用指令 = 退出（用户 2026-10-16 定稿）；其余指令温和拒绝
    if (this.data.gate && intent !== INTENT.EXIT) {
      this.showAsrHint(GATE_BLOCK_TEXT);
      voice.speak(GATE_BLOCK_TEXT, { interrupt: true });
      return;
    }

    const pending = this.data.pendingDelete;

    switch (intent) {
      case INTENT.CONFIRM:
        if (pending) this.doDelete();
        else this.sayHint('当前没有待确认的删除');
        return;

      case INTENT.CANCEL:
        if (pending) this.exitPendingDelete('speak');
        else this.sayHint('已取消');
        return;

      case INTENT.DELETE:
        this.enterPendingDelete();
        return;

      case INTENT.VIEW_PHOTO:
        this.showNewestOfType('photo');
        return;

      case INTENT.VIEW_VIDEO:
        this.showNewestOfType('video');
        return;

      case INTENT.NEXT:
        this.step(1);
        return;

      case INTENT.PREV:
        this.step(-1);
        return;

      case INTENT.REPLAY:
        // 需求 2：重播已是视频默认行为（循环播放），此处仅为「立刻回到开头」的显式入口
        this.replay();
        return;

      case INTENT.EXIT:
        // 门禁页 / 主界面全屏 / 卡片态：统一「一退到底」（见 doExit / hardExit）
        this.doExit();
        return;

      case INTENT.EXPAND:
        this.expandToFullscreen();
        return;

      default:
        // 未识别指令（用户 2026-10-16 定稿）：底部「正在聆听」行上方显示引导提示，
        // 不再用顶部 toast「没听懂，请再说一次」；TTS 同步播报同文案。
        this.showAsrHint(ASR_HINT_TEXT);
        voice.speak(ASR_HINT_TEXT, { interrupt: true });
    }
  },

  /* ---------------- 渲染 ---------------- */

  renderCurrent(options) {
    const announce = !options || options.announce !== false;
    const item = store.current();
    // ★ 视频总时长缓存**换条目即失效**（含它的条目归属）：新条目必须重新由桥 /probe 确认，
    //   否则上一条的时长会"粘"到本条上（真机 bug：7:18 的时长显示在 25.2s 的视频上）。
    this.videoDurationSec = 0;
    this.videoDurationItemId = '';

    if (!item) {
      this.setData({
        empty: true,
        cmdHint: '可用语音命令：退出',
        breadcrumb: '0/0',
        title: '',
        src: '',
        videoSrc: '',
        poster: '',
        isVideo: false,
        videoBroken: false,
        videoReady: false,
        timeline: '0:00 / 0:00',
        playing: false,
      });
      this.clearLoading();
      if (announce) voice.speak('已无媒体', { interrupt: true });
      return;
    }

    const isVideo = item.type === 'video';
    this.setData({
      empty: false,
      cmdHint: '可用语音命令：下一个，上一个，删除，确认删除，取消，退出',
      breadcrumb: store.breadcrumb(),
      title: item.title,
      src: item.src,
      // ★ 视频地址一律先清空：只有 prepareVideo 判定完成（直接播 / 播转码缓存）才写入；
      //   照片条目永远保持空串 → 杜绝"照片地址被喂进视频桥"（见 data.videoSrc 注释）
      videoSrc: '',
      poster: item.poster || '',
      isVideo,
      videoBroken: false,
      videoReady: false, // 决策（直接播/播缓存/等转码）完成后才挂载 <video>
      timeline: isVideo ? formatTimeline(0, item.durationSec || 0) : '0:00 / 0:00',
      totalText: isVideo ? formatDuration(item.durationSec || 0) : '0:00',
      playing: false,
    });

    // 切条取证（桥 /log 搜 `render`）：排查"切条残留事件"类问题时，需要知道每一拍到底切到了谁。
    try {
      bridgeReport(`render ${store.breadcrumb()} type=${isVideo ? 'video' : 'photo'}`);
    } catch (err) {
      /* 忽略 */
    }

    // 居中加载指示：切条后立即出现，等媒体就绪事件再收起
    // （照片 = bindload（若宿主支持）；视频 = loadedmetadata / play；失败 = error）
    // ★ 类型与兜底时长**显式传入**，不依赖 this.data.isVideo —— setData 的落地时机不保证同步，
    //   否则「视频→图片」切条时可能按上一条的类型去计时（照片被套上视频的长兜底）。
    this.showLoading(
      isVideo ? '视频加载中' : '图片加载中',
      isVideo ? LOADING_TIMEOUT_MS : LOADING_TIMEOUT_IMAGE_MS,
      isVideo
    );

    if (isVideo) {
      // 可播性保障：HEVC 源需先由桥端转码（prepareVideo 内部会决定"直接播 / 播缓存 / 等转码"）
      this.prepareVideo(item);
    }
    // 用户 2026-10-16 定稿：翻页**不播报文件名**（静默浏览，序号/文件名界面可见）
  },

  /* ---------------- toast（叠放浮层） ---------------- */

  

  /* ---------------- 未识别指令提示（底部信息组内，正在聆听行上方） ---------------- */

  /**
   * 显示底部提示行内容（错误反馈 / 未识别指令引导），ASR_HINT_MS 后自动消隐。
   * 与顶部 toast 的分工（用户 2026-10-16 定稿）：**所有错误反馈走本行**；
   * 顶部不再有任何提示（2026-10-16 定稿：全部反馈走底部提示行一处）。
   * 位置在命令清单/正在聆听附近，视线不用跳。
   */
  showAsrHint(text, durationMs) {
    if (this.asrHintTimer) {
      clearTimeout(this.asrHintTimer);
      this.asrHintTimer = null;
    }
    this.setData({ asrHint: text });
    if (durationMs === 0) return; // 常驻：不自动消隐（窗口模式引导），由恢复流程显式清除
    this.asrHintTimer = setTimeout(() => {
      this.asrHintTimer = null;
      this.setData({ asrHint: '' });
    }, durationMs || ASR_HINT_MS);
  },

  clearAsrHint() {
    if (this.asrHintTimer) {
      clearTimeout(this.asrHintTimer);
      this.asrHintTimer = null;
    }
    if (this.data.asrHint) this.setData({ asrHint: '' });
  },

  /* ---------------- 居中加载指示 ---------------- */

  /**
   * 显示屏幕正中的加载指示（转圈 + 文案）。
   *
 * 使用场景：切到新条目、图片解码、视频首次加载/缓冲、**桥端转码等待**。
 * 「视频处理中，请稍候」的慢源升级文案保留给普通加载；转码等待走 startTranscode 的
 * 专用入口（显示「正在转码视频 N%」进度，桥侧已具备 /transcode/status 能力）。
   *
   * ★ 为什么升级只对视频开：`<image>` 没有就绪事件（官方 image.md 只有 src/mode），
   *   照片天生只能等兜底计时退出，必然跨过升级点 → 会对着照片错报「视频处理中」（真机已复现）。
   *
   * @param {string} [text] 初始文案，默认按类型给「图片加载中/视频加载中」
   * @param {number} [timeoutMs] 兜底自动关闭时长（默认按类型：视频 6s / 图片 0.9s）
   * @param {boolean} [video] 本条是否为视频（决定兜底默认值与是否启用慢源升级）。
   *        显式传入，避免依赖尚未落地的 this.data.isVideo。
   */
  showLoading(text, timeoutMs, video) {
    const isVideo = typeof video === 'boolean' ? video : !!this.data.isVideo;
    const initial =
      String(text || '').trim() || (isVideo ? '视频加载中' : '图片加载中');
    // 默认兜底时长按媒体类型区分：图片短（无 load 事件可依赖）、视频长（含解码/缓冲）
    const ms =
      typeof timeoutMs === 'number'
        ? timeoutMs
        : isVideo
          ? LOADING_TIMEOUT_MS
          : LOADING_TIMEOUT_IMAGE_MS;
    const seq = (this.loadingSeq || 0) + 1;
    this.loadingSeq = seq;

    if (this.loadingTimer) {
      clearTimeout(this.loadingTimer);
      this.loadingTimer = null;
    }
    if (this.loadingSlowTimer) {
      clearTimeout(this.loadingSlowTimer);
      this.loadingSlowTimer = null;
    }

    this.setData({ loading: true, loadingText: initial });

    // 慢源升级文案：**仅视频**（照片没有就绪事件，等兜底即可，升级文案对它是错的）
    if (isVideo) {
      this.loadingSlowTimer = setTimeout(() => {
        this.loadingSlowTimer = null;
        if (this.loadingSeq !== seq || !this.data.loading) return;
        this.setData({ loadingText: '视频处理中，请稍候' });
      }, LOADING_SLOW_MS);
    }

    // 兜底：事件可能因异常丢失（编码不支持等），到时自动收起，避免一直转圈
    this.loadingTimer = setTimeout(() => {
      this.loadingTimer = null;
      if (this.loadingSeq !== seq) return;
      this.clearLoading();
    }, ms);
  },

  /** 收起居中加载指示（幂等） */
  clearLoading() {
    this.loadingSeq = (this.loadingSeq || 0) + 1;
    if (this.loadingTimer) {
      clearTimeout(this.loadingTimer);
      this.loadingTimer = null;
    }
    if (this.loadingSlowTimer) {
      clearTimeout(this.loadingSlowTimer);
      this.loadingSlowTimer = null;
    }
    if (this.data.loading) this.setData({ loading: false });
  },

  /** 语音播报 + 叠放 toast 同步 */
  /**
   * 负向反馈（错误/拒绝/无结果）：**底部提示行**（正在聆听行上方）显示 + TTS 播报。
   * 用户 2026-10-16 定稿：所有错误反馈不再走顶部 toast，统一移到底部信息组。
   */
  sayHint(text) {
    this.showAsrHint(text);
    voice.speak(text, { interrupt: true });
  },

  /* ---------------- 导航 ---------------- */

  step(delta) {
    const count = store.total();
    if (count <= 0) {
      this.sayHint('已无媒体');
      return;
    }
    if (delta > 0) store.next();
    else store.prev();
    this.renderCurrent({ announce: true });
  },

  showNewestOfType(type) {
    const found = store.toNewestOfType(type);
    if (!found) {
      this.sayHint(`没有${typeLabel(type)}`);
      return;
    }
    this.renderCurrent({ announce: true });
  },

  /* ---------------- 视频控制 ---------------- */

  /* ---- 可播性保障（HEVC → H.264 转码，方案 docs/AIUI-视频转码-落地方案.md §4.6） ----
   *
   * 背景：AIUI 运行时的自研 MP4 管线只认 H.264/AVC + AAC-LC 的 progressive MP4
   * （so 字符串 `MP4 has no H.264 video track`），而眼镜实拍视频是 HEVC。
   * 唯一出路是桥端硬解→缩放→硬编（Surface 直连 + GL），转完落缓存、HTTP 供给 <video>。
   *
   * 决策树：
   *   probe（桥 /probe/<id>，毫秒级）
   *     ├─ playable（源就是 H.264+AAC-LC） → 直接播原文件（零开销）
   *     ├─ 已有转码缓存                    → 播 /media/<id>?fmt=avc（秒开）
   *     └─ 都没有                          → 提交 /transcode + 轮询进度 → done 后自动播
   *
   * 兜底：probe 不可用（旧版桥 / 单次请求失败）→ 退回"直接播"的老行为，
   *       失败由 onVideoError 的占位界面接住 —— 永远不会比改造前更差。
   *
   * 生命周期：轮询用「序号 + 当前条目」双校验，切走/换条/删除都会让回调静默退出；
   *           转码任务本体在桥的前台服务里继续跑，回来看同一条视频时已缓存、秒开。
   */

  /** 切到视频后的第一站：探测 → 分流 */
  async prepareVideo(item) {
    // ★ probe 不可达（桥被 LMK 杀掉重启中 / 端口未就绪）时**绝不能**走"直接播原片"兜底：
    //   眼镜相机源是 HEVC，喂给 <video> 必报「编码不支持」。改为短暂重试，仍不通则明确告知。
    for (let i = 0; i < 3; i++) {
      let probe = null;
      try {
        probe = await bridgeGetJson(`/probe/${item.id}`);
      } catch (err) {
        console.warn(`[page] probe 失败（第 ${i + 1} 次）：`, err);
      }
      if (!item || store.current() !== item) return; // 等待期间已切走
      if (probe && probe.ok && probe.type === 'video') {
        // probe 自带源时长（MediaExtractor 元数据，转码开始前已可知）→ 立刻把
        // 时间行总时长刷出来，转码等待期用户就能看到真实时长而非 0:00。
        // ★ 带上 item.id：这是**权威且条目绑定**的总时长来源（挂载 <video> 之前就写入），
        //   也是 2026-10-16「时长串位」bug 的正面修复 —— 不再依赖 VideoContext 那个
        //   "反映当前视频桥已加载的源、切条瞬间还是上一条"的读数（见 onVideoLoadedMetadata）。
        if (probe.durationMs > 0) this.applyDuration(probe.durationMs / 1000, item.id);
        if (probe.playable) {
          // 直接播原文件：此刻才把地址交给 <video>（视频专用字段，见 data.videoSrc）
          this.setData({ videoSrc: item.src, videoReady: true });
          this.playVideo(true);
          return;
        }
        if (probe.transcoded) {
          this.playTranscoded(item);
          return;
        }
        this.startTranscode(item, probe);
        return;
      }
      if (probe && probe.ok) {
        // 桥可达但探测不到视频轨（如文件损坏）→ 提示后收起加载态
        this.clearLoading();
        this.setData({ videoBroken: true });
        this.showAsrHint('视频无法播放（文件无法识别）');
        voice.speak('视频无法播放，说下一个跳过', { interrupt: true });
        return;
      }
      if (i < 2) {
        await new Promise((resolve) => setTimeout(resolve, 800));
        if (!item || store.current() !== item) return;
      }
    }
    // 桥持续不可达：明确提示（服务被系统回收后通常几秒内会自动重启并续转）
    this.clearLoading();
    this.setData({ videoBroken: true });
    this.showAsrHint('媒体服务暂不可用，请稍后再试');
    voice.speak('媒体服务暂不可用，请稍后再试', { interrupt: true });
  },

  /** 把 <video> 的 src 换成桥端转码缓存并开播 */
  playTranscoded(item) {
    const b = bridgeBaseUrl() || '';
    // ★ 只写 videoSrc，不再覆写照片用的 `src`（两个字段分离，见 data.videoSrc 注释）
    this.setData({ videoSrc: `${b}/media/${item.id}?fmt=avc`, videoBroken: false, videoReady: true });
    this.playVideo(true);
  },

  /** 提交转码并轮询进度；等待期用居中指示显示百分比（D4 的"进度可见"要求） */
  async startTranscode(item, probe) {
    const seq = (this.transcodeSeq || 0) + 1;
    this.transcodeSeq = seq;
    // 用户 2026-10-16 定稿：等待期统一文案「正在生成预览视频，请稍后」+ TTS 提醒一次
    // （同一条视频再进来若已转完直接秒开，不会再走到这里）
    this.showLoading('正在生成预览视频，请稍后', TRANSCODE_LOADING_TIMEOUT_MS, true);
    try {
      voice.speak('正在生成预览视频，请稍后', { interrupt: true });
    } catch (err) {
      /* 忽略 */ 
    }
    try {
      const sub = await bridgeGetJson(`/transcode/${item.id}`);
      if (!sub || !sub.ok) throw new Error((sub && sub.error) || '提交失败');
    } catch (err) {
      console.warn('[page] 转码提交失败：', err);
      bridgeReport(`transcode submit 失败 ${item.path} ${(err && err.message) || err}`);
      this.clearLoading();
      this.setData({ videoBroken: true });
      this.showAsrHint('视频无法播放（转码不可用）');
      voice.speak('视频无法播放，说下一个跳过', { interrupt: true });
      return;
    }

    let pollFails = 0; // 连续查询失败计数（桥可能又被系统杀了）
    const poll = async () => {
      if (seq !== this.transcodeSeq || store.current() !== item) return; // 已切走/换条
      let st = null;
      try {
        st = await bridgeGetJson(`/transcode/status/${item.id}`);
        pollFails = 0;
      } catch (err) {
        pollFails++;
        // 桥失联（被杀重启中）：重试几次，仍不通则放弃等待 —— 服务重启后会自动续转（桥侧持久化）
        if (pollFails >= 5) {
          this.clearLoading();
          this.setData({ videoBroken: true });
          this.showAsrHint('媒体服务暂不可用，请稍后再试');
          voice.speak('媒体服务暂不可用，请稍后再试', { interrupt: true });
          return;
        }
      }
      if (seq !== this.transcodeSeq || store.current() !== item) return;
      const state = st && st.state;
      if (state === 'done' || (st && st.cacheBytes > 0)) {
        this.playTranscoded(item);
        return;
      }
      if (state === 'failed' || state === 'canceled') {
        bridgeReport(`transcode ${state} ${item.path} err=${(st && st.error) || ''}`);
        this.clearLoading();
        this.setData({ videoBroken: true });
        this.showAsrHint('视频无法播放（转码失败）');
        voice.speak('视频无法播放，说下一个跳过', { interrupt: true });
        return;
      }
      if (st && typeof st.progress === 'number' && this.data.loading) {
        const pct = Math.round(st.progress * 100);
        this.setData({ loadingText: pct > 0 ? `正在生成预览视频，请稍后 ${pct}%` : '正在生成预览视频，请稍后' });
      }
      this.transcodeTimer = setTimeout(poll, TRANSCODE_POLL_MS);
    };
    this.transcodeTimer = setTimeout(poll, TRANSCODE_POLL_MS);
  },

  /** 停掉本页的转码轮询（onUnload / 退出时调用；桥侧任务不受影响，会继续跑完落缓存） */
  stopTranscodePolling() {
    this.transcodeSeq = (this.transcodeSeq || 0) + 1;
    if (this.transcodeTimer) {
      clearTimeout(this.transcodeTimer);
      this.transcodeTimer = null;
    }
  },

  /** 取得 VideoContext（组件挂载可能有延迟，带重试） */
  withVideoContext(callback, attempt) {
    const tries = typeof attempt === 'number' ? attempt : 0;
    const ctx = wx.createVideoContext(VIDEO_ID);
    if (ctx) {
      this.videoCtx = ctx;
      callback(ctx);
      return;
    }
    if (tries < CONTEXT_RETRY) {
      setTimeout(() => this.withVideoContext(callback, tries + 1), CONTEXT_RETRY_DELAY);
    }
  },

  /** 从头播放当前视频 */
  playVideo(fromStart) {
    if (!this.data.isVideo) return;
    this.withVideoContext((ctx) => {
      try {
        ctx.load();
      } catch (err) {
        /* load 失败不阻断 */
      }
      setTimeout(() => {
        try {
          if (fromStart) ctx.seek(0);
          ctx.play();
        } catch (err) {
          console.warn('[page] 播放失败：', err);
        }
      }, CONTEXT_RETRY_DELAY);
    });
  },

  replay() {
    if (!this.data.isVideo) {
      this.showAsrHint('当前是照片');
      return;
    }
    this.withVideoContext((ctx) => {
      try {
        ctx.seek(0);
        ctx.play();
      } catch (err) {
        console.warn('[page] 重播失败：', err);
      }
    });
    this.setData({
      timeline: formatTimeline(0, this.resolveDurationSec()),
      playing: true,
    });
  },

  /* 视频事件 */

  /**
   * ★★ 残留视频事件闸门（2026-10-16 真机 bug 修复，用户实测复现）。
   *
   * 现象：视频（第 1 项）正常播放中说「下一个」→ 正确切到第 2 项**照片**，
   *   但屏幕上同时弹出「视频无法播放」提示 + TTS 播报。桥日志铁证：
   *   `cmd「下一个。」→ next` 之后 1.2s 出现
   *   `video error src=…/DCIM/Camera/img-….jpg msg=Video playback bridge queueAccessUnit failed`
   *   —— 宿主在卸载旧 <video> 元素的过程中补发了一次 error，而它带的是**新条目（照片）的地址**。
   *
   * 处理：所有视频事件回调进门先过这道闸 —— 当前展示的不是视频条目（照片/空库）就丢弃，
   *   只写一条日志，**不改变任何状态**（不置 videoBroken、不弹提示、不播 TTS）。
   *   配合 `data.videoSrc` 字段分离（照片地址永不喂给视频桥），从两头堵住这个 bug。
   *
   * @param {string} what 事件名，仅用于日志取证。
   * @return {boolean} true = 残留事件，调用方必须立即 return。
   */
  isStaleVideoEvent(what) {
    if (this.data.isVideo) return false;
    try {
      bridgeReport(`video ${what} 丢弃（残留事件：当前不是视频）`);
    } catch (err) {
      /* 忽略 */
    }
    return true;
  },

  /**
   * 视频元数据就绪 → 确定**本条目的**总时长。
   *
   * ★★ 真机 bug（2026-10-16 11:51 桥日志，用户实测）：
   *   两个**已转码**的视频用「下一个」连续切换时，7:18（438.168s）那条的时长
   *   显示到了 25.2s 那条上；回头再看 7:18 那条又显示成 0:25 —— 两边互串。日志铁证：
   *     render 4/9 type=video（d5, 25.2s）→ `metadata ok duration=438.168s src=…d5.mp4`
   *   根因：旧实现的总时长优先级是 `store.current().durationSec`（桥 `/list` **并不返回**
   *   该字段，恒为 0）→ 落到 `VideoContext.getDuration()` 兜底，而**这个读数不绑定条目**：
   *   它反映的是视频桥「当前已加载的源」，连续切条的那一瞬间读到的仍是**上一条**的媒体
   *   → 上一条的时长被当成新条目的时长写进界面，且此后再无事件来纠正它。
   *
   * 现在总时长**只认条目绑定的来源**：
   *   ① `store.current().durationSec`（桥 /list 元数据；当前桥不返回，属前向兼容）
   *   ② `this.videoDurationSec`，**且 `videoDurationItemId === 当前条目 id`**
   *      —— 由 `prepareVideo` 的桥 `/probe`（MediaExtractor 元数据）在挂载 `<video>`
   *      **之前**写入，天然属于本条；切条时清零（见 renderCurrent）
   *   ③ 都没有 → 异步补一次 `/probe`（同样条目绑定，见 fetchDurationFromBridge）
   *   ★ 明确**不再使用 `VideoContext.getDuration()`** 作总时长来源（真机取证见上）。
   *
   * 另：loadedmetadata 的 payload 规范未定义，故不读 event.detail。
   */
  onVideoLoadedMetadata() {
    if (this.isStaleVideoEvent('loadedmetadata')) return;
    // 元数据就绪 = 首帧可解 → 收起居中加载指示
    this.clearLoading();
    const item = store.current();
    const id = item ? item.id : '';
    // ★ 关键：**保留**已经为该条目确认过的时长，绝不用"当前视频桥的读数"去覆盖它 ——
    //   那正是串位 bug 的入口（旧实现在这里无条件 probeVideoDuration() 覆盖）。
    const total = this.resolveDurationSec(item);
    if (total > 0) this.applyDuration(total, id);
    else if (item) this.fetchDurationFromBridge(item); // 桥没给出（首次探测失败）→ 补一次
    try {
      bridgeReport(`metadata ok duration=${total}s src=${item ? item.path : '?'}`);
    } catch (err) {
      /* 忽略 */
    }
  },

  /**
   * 解析「当前条目的」总时长（秒），0 = 未知。
   * 来源全部**条目绑定**，理由见 onVideoLoadedMetadata 的真机取证。
   * @param {object} [itemArg] 可显式传入条目（异步回调里避免重复查 store）
   * @return {number} 秒；0 表示尚不可知（调用方按需降级）
   */
  resolveDurationSec(itemArg) {
    const item = itemArg || store.current();
    if (!item) return 0;
    // ① 桥 /list 元数据（当前桥不返回 durationSec，属前向兼容）
    if (item.durationSec > 0) return item.durationSec;
    // ② 本条已由桥 /probe 确认过的时长；归属不符 = 上一条的残留 → 视为未知
    if (this.videoDurationSec > 0 && this.videoDurationItemId === item.id) {
      return this.videoDurationSec;
    }
    return 0;
  },

  /**
   * 总时长兜底补齐：条目已上屏、但桥没给出时长（首次 /probe 失败等）时补一次。
   * 全程条目绑定 —— 返回时已切条直接丢弃（applyDuration 里还会再校验一次）。
   * 仍拿不到就保持 0，交给 onVideoTimeUpdate 的递增最大值估计。
   */
  async fetchDurationFromBridge(item) {
    if (!item) return;
    try {
      const probe = await bridgeGetJson(`/probe/${item.id}`);
      if (!probe || !probe.ok || !(probe.durationMs > 0)) return;
      if (store.current() !== item) return; // 等待期间已切走
      this.applyDuration(probe.durationMs / 1000, item.id);
    } catch (err) {
      /* 忽略：拿不到就保持 0 */
    }
  },

  /**
   * 记录并渲染总时长（时间轴用）。
   * ★ 条目绑定：异步来源（/probe、兜底补探）返回时可能已经切条 —— 那时绝不能把
   *   上一条的时长写进界面（这正是真机 bug 的形态），直接丢弃并留痕。
   * @param {number} total 总时长（秒）
   * @param {string} itemId 该时长归属的条目 id
   */
  applyDuration(total, itemId) {
    if (!(total > 0)) return;
    const item = store.current();
    const id = itemId || (item ? item.id : '');
    if (!item || !id) return;
    if (item.id !== id) {
      try {
        bridgeReport(`duration ${total}s 丢弃（异步返回时已切条）`);
      } catch (err) {
        /* 忽略 */
      }
      return;
    }
    this.videoDurationSec = total;
    this.videoDurationItemId = id;
    this.setData({
      totalText: formatDuration(total),
      timeline: formatTimeline(0, total),
    });
  },

  /**
   * 播放进度 → 时间轴 `当前 / 总长`。
   * ★ 只更新时间文字：原先还要算 `progressPercent` 喂给画面下方的细进度线，
   *   该进度线已按用户要求移除（2026-10-16），故不再保留百分比状态。
   * ★ 两道条目防护（配合 onVideoLoadedMetadata 的真机取证）：
   *   ① 进度超出"本条已知总长 + 余量" → 必然是换源前的旧媒体残留上报 → 丢弃；
   *   ② 只有**本条总长仍未知**时才允许用递增最大值估计，绝不让残留进度把已知总长改坏。
   */
  onVideoTimeUpdate(event) {
    if (this.isStaleVideoEvent('timeupdate')) return;
    const item = store.current();
    const detail = event && event.detail ? event.detail : {};
    const currentTime = Number(detail.currentTime) || 0;
    let total = this.resolveDurationSec(item);
    if (total > 0 && currentTime > total + STALE_PROGRESS_SLACK_S) {
      try {
        bridgeReport(
          `video timeupdate 丢弃（残留：进度 ${currentTime.toFixed(1)}s > 本条总长 ${total}s）`
        );
      } catch (err) {
        /* 忽略 */
      }
      return;
    }
    if (total <= 0) total = parseDurationToSeconds(this.data.totalText);
    // ③ 兜底：总时长仍未知时，用递增的最大播放位置作估计（循环播放会很快收敛）
    if (total <= 0 && currentTime > 0) {
      total = currentTime;
      this.videoDurationSec = total;
      this.videoDurationItemId = item ? item.id : '';
      this.setData({ totalText: formatDuration(total) });
    }
    this.setData({ timeline: formatTimeline(currentTime, total) });
  },

  onVideoPlay() {
    if (this.isStaleVideoEvent('play')) return;
    this.clearLoading();
    this.setData({ playing: true });
  },

  /** 播放中缓冲/准备（如源编码较重需重封装）→ 重新亮起居中指示 */
  onVideoWaiting() {
    if (this.isStaleVideoEvent('waiting')) return;
    if (this.data.videoBroken) return;
    this.showLoading('视频缓冲中', LOADING_TIMEOUT_MS, true);
  },

  onVideoPause() {
    if (this.isStaleVideoEvent('pause')) return;
    this.setData({ playing: false });
  },

  /**
   * 需求 2：重播为视频默认行为。
   * 首选组件原生 `loop`；此处兜底，覆盖 loop 未生效的机型。
   */
  onVideoEnded() {
    if (this.isStaleVideoEvent('ended')) return;
    const total = this.resolveDurationSec();
    this.setData({
      playing: true,
      timeline: formatTimeline(0, total),
    });
    this.withVideoContext((ctx) => {
      try {
        ctx.seek(0);
        ctx.play();
      } catch (err) {
        console.warn('[page] 自动重播失败：', err);
      }
    });
  },

  onVideoError(event) {
    if (this.isStaleVideoEvent('error')) return;
    const msg = event && event.detail && event.detail.message ? event.detail.message : '未知错误';
    const item = store.current();
    console.warn('[page] 视频错误：', msg);
    // ★ 卸载 <video>：宿主会在报错的 video 画面区持续绘制 ASCII 占位符（形如「=====-->」），
    //   必须 ink:if 置假把元素摘掉，换成自绘的占位界面。
    this.clearLoading();
    this.setData({ videoBroken: true });
    const fromTranscode = !!this.data.videoSrc && this.data.videoSrc.indexOf('fmt=avc') >= 0;
    this.showAsrHint(fromTranscode ? '视频无法播放（转码产物异常）' : '视频播放失败（编码不支持）');
    voice.speak('视频无法播放，说下一个跳过', { interrupt: true });
    try {
      // 取证：同时记下**出错元素报的地址**（event.detail.src，若宿主提供）与当前条目 ——
      // 两者不一致即说明是残留事件（本 bug 的成因），下次真机可直接分辨。
      const evSrc = (event && event.detail && (event.detail.src || event.detail.url)) || '?';
      bridgeReport(`video error item=${item ? item.path : '?'} evSrc=${evSrc} src=${this.data.videoSrc || '?'} msg=${msg}`);
    } catch (err) {
      /* 忽略 */
    }
  },

  /* 图片事件 */

  /**
   * 图片事件的对称闸门（与 isStaleVideoEvent 配对）：当前是视频条目时，图片事件必为残留。
   * 典型场景：照片 → 视频 快速翻页，上一张照片的 load/error 在视频已挂载后才到达，
   * 会误收起「视频加载中」指示、甚至弹出「图片加载失败」。
   */
  isStaleImageEvent(what) {
    if (!this.data.isVideo) return false;
    try {
      bridgeReport(`image ${what} 丢弃（残留事件：当前不是照片）`);
    } catch (err) {
      /* 忽略 */
    }
    return true;
  },

  /**
   * 图片解码完成 → 收起居中加载指示。
   *
   * ⚠️ 官方 `2-components/image.md` 只声明了 `src`/`mode`，**没有 load 事件**，
   * 全仓官方样例也没有任何 `<image>` 绑定 bindload —— 即本回调**很可能根本不会被触发**，
   * 照片的 loading 实际靠 showLoading 的兜底计时退出（图片专门用 0.9s 的短兜底）。
   * 这里上报一条日志，用于真机取证该事件到底有没有派发（桥 `/log` 搜 `image load`）。
   */
  onImageLoad() {
    if (this.isStaleImageEvent('load')) return;
    this.clearLoading();
    try {
      const item = store.current();
      bridgeReport(`image load src=${item ? item.path : '?'}`);
    } catch (err) {
      /* 忽略 */
    }
  },

  onImageError(event) {
    if (this.isStaleImageEvent('error')) return;
    this.clearLoading();
    const msg =
      event && event.detail && event.detail.errMsg ? event.detail.errMsg : '未知错误';
    console.warn('[page] 图片错误：', msg);
    this.showAsrHint('图片加载失败');
    voice.speak('图片加载失败', { interrupt: true });
    try {
      const item = store.current();
      bridgeReport(`image error src=${item ? item.path : '?'} msg=${msg}`);
    } catch (err) {
      /* 忽略 */
    }
  },

  /* ---------------- 删除（二次确认 · 真实删除） ---------------- */

  enterPendingDelete() {
    const item = store.current();
    if (!item) {
      this.sayHint('已无媒体');
      return;
    }

    this.pendingTargetId = item.id;
    this.clearPendingTimer();
    this.pendingTimer = setTimeout(() => {
      if (this.data.pendingDelete) this.exitPendingDelete('timeout');
    }, DELETE_TIMEOUT_MS);

    this.setData({ pendingDelete: true });
    // 引导不再走顶部 toast：确认态期间底部确认条常驻显示（见模板 confirm-bar）
    voice.speak(`确定删除这张${typeLabel(item.type)}吗？请说确认或取消`, { interrupt: true });

    // 不再要求用户重新唤醒：稍后自动进入聆听，用户直接说「确认」/「确认删除」/「删除」即可
    if (this.pendingListenTimer) {
      clearTimeout(this.pendingListenTimer);
    }
    this.pendingListenTimer = setTimeout(() => {
      this.pendingListenTimer = null;
      if (this.data.pendingDelete) this.listenOnce('pending-auto');
    }, PENDING_LISTEN_DELAY);
  },

  async doDelete() {
    this.clearPendingTimer();
    // ★ 不再 abortListening：免唤醒下这是同一个常驻会话，若在此掐断，
    //   用户就得重新唤醒才能说下一句。播报自听由 voice.js 的静音窗口挡住。

    const target = store.current();
    const targetLabel = target ? typeLabel(target.type) : '媒体';

    // 若这条视频正在桥端转码，先取消（桥的 /delete 也会联动清掉它的转码缓存）
    if (target && target.type === 'video') {
      try {
        await bridgeGetJson(`/transcode/cancel/${target.id}`);
      } catch (err) {
        /* 无任务/旧版桥都会失败，忽略 */
      }
    }

    const result = await store.deleteCurrent();

    this.setData({ pendingDelete: false });
    this.pendingTargetId = null;

    if (!result.ok) {
      this.sayHint('删除失败');
      return;
    }

    // 需求 6：删除成功以 toast 方式告知
    this.showAsrHint(`已删除${targetLabel}`);

    if (result.remaining <= 0) {
      this.renderCurrent({ announce: false });
      setTimeout(() => this.showAsrHint('媒体库已空'), 1200);
      voice.speak(`已删除这张${targetLabel}，媒体库已空`, { interrupt: true });
      return;
    }

    this.renderCurrent({ announce: false });
    voice.speak(`已删除这张${targetLabel}`, { interrupt: true });
  },

  exitPendingDelete(reason) {
    if (!this.data.pendingDelete) return;
    this.clearPendingTimer();
    this.pendingTargetId = null;
    this.setData({ pendingDelete: false });
    // 确认态结束：**不再**掐断识别 —— 免唤醒会话要继续留给「下一个」「退出」等指令。
    // （旧实现这里 abortListening，会导致用户必须重新唤醒才能继续操作。）
    if (reason === 'speak' || reason === 'timeout') {
      const msg = reason === 'timeout' ? '已超时，取消删除' : '已取消';
      this.showAsrHint(msg);
      voice.speak(msg, { interrupt: true });
    }
  },

  clearPendingTimer() {
    if (this.pendingTimer) {
      clearTimeout(this.pendingTimer);
      this.pendingTimer = null;
    }
    if (this.pendingListenTimer) {
      clearTimeout(this.pendingListenTimer);
      this.pendingListenTimer = null;
    }
  },

  /* ---------------- 退出 ---------------- */

  /**
   * ★ 官方文档口径（documentation/3-api/window.md + samples/capabilities/pages/close/index.ink）：
   *   · 真正「关闭当前智能体」的入口是 `window.close()`（向宿主发一个关闭实例的请求）；
   *     `wx.exitMiniProgram()` 是微信小程序兼容 API，语义是「请求退出当前实例」；
   *     两者**都只是请求**，实际关闭时机由宿主决定（实测：全屏态只有 exitMiniProgram 生效）。
   *   · close 示例另提示「延迟一拍再发关闭请求」（示例用 80ms），否则请求可能被当前事件流吞掉。
   *   → 落到本页：`requestRealClose` 用 window.close() + 80ms 后 exitMiniProgram 双通道兜底，
   *     每一跳都上报桥日志（真机上没日志就完全不可观测）。
   *
   * 退出链路总览（2026-10-16 定稿）：语音「退出」→ `doExit()`（统一入口，不分全屏/卡片）
   *   → `hardExit(src)` 一退到底（黑场遮罩 → 收起 → 卡片态真关闭 → 密集抢跑压卡片外框时长）。
   */

  /**
   * 是否处于 AIUI 窗口模式（卡片态 _current）。
   * onTargetChanged 未触发/未上报的宿主上按视口宽度兜底；仍判不出时**按全屏处理**
   * （宁可少干预，避免卡片态单击与宿主展开行为打架）。
   */
  isCardMode() {
    if (this.hostTarget === '_current') return true;
    if (this.hostTarget === '_blank') return false;
    try {
      return window.innerWidth > 0 && window.innerWidth < 400;
    } catch (err) {
      return false;
    }
  },

  /**
   * 收起到 AIUI 窗口模式（卡片态）。★ 真机取证（2026-10-16 桥日志）：
   * - wx.exitMiniProgram() 会把页面收起到卡片态，**页面实例存活**（JS/日志继续跑）；
   *   window.close() 宿主不接手（「exit 1.2s 后页面仍在」实测）→ 只走 exitMiniProgram；
   * - 卡片态 InkView non-interactive → getUserMedia 不可用，语音识别必然停止；
   * - 回全屏（单击镜腿 / 唤醒词「乐奇」）触发 onShow → ensureListening 自动恢复识别。
   * 因此收起前挂上**常驻**引导提示（CARD_MODE_HINT），回到全屏恢复识别后清除
   * （见 onVoicePhase listening 分支）；卡片态内的识别错误也统一改显这条提示。
   *
   * ⚠️ **当前无页面调用点**（2026-10-16 11:15 起）：唯一的调用方是"照片态镜腿单击"，
   * 已按用户要求改为无动作；退出链路一律走 hardExit。方法保留备用（语音「缩小」等未来入口），
   * 卡片态**回到全屏**仍有路：宿主原生单击镜腿 / 唤醒词。
   */
  collapseToWindowMode(src) {
    if (this.isCardMode()) return; // 已在窗口模式：展开交给宿主，这里不干预
    try {
      voice.abortListening();
    } catch (err) {
      /* 忽略 */
    }
    try {
      voice.stopSpeaking();
    } catch (err) {
      /* 忽略 */
    }
    this.showAsrHint(CARD_MODE_HINT, 0);
    // 实测卡片态语音识别常能继续跑（getUserMedia 只在部分时刻被禁）→ 2s 后仍在听就撤提示
    setTimeout(() => {
      if (voice.isListening() && this.data.asrHint === CARD_MODE_HINT) {
        this.clearAsrHint();
        try {
          bridgeReport(`collapse src=${src} 语音仍在识别，撤回「已停止」提示`);
        } catch (err) {
          /* 忽略 */
        }
      }
    }, 2000);
    bridgeReport(`collapse src=${src} 请求宿主收起到窗口模式`);
    try {
      wx.exitMiniProgram({
        success: () => bridgeReport(`collapse src=${src} exitMiniProgram success`),
        fail: () => bridgeReport(`collapse src=${src} exitMiniProgram fail`),
        complete: () => bridgeReport(`collapse src=${src} exitMiniProgram complete`),
      });
    } catch (err) {
      bridgeReport(`collapse src=${src} 异常 ${(err && err.message) || err}`);
    }
  },

  /**
   * 窗口模式（卡片态）→ 展开回全屏。语音指令「放大 / 全屏」。
   * ★ 结论（2026-10-16 实测定稿）：页面**无法**自己展开回全屏——
   *   文档无此 API；window.open(页, '_blank') 实测被宿主无视（只支持 Widget）；
   *   卡片态页面收不到按键事件副本，也无法注入按键，「模拟镜腿点击」不可行。
   *   唯一路径 = 宿主原生行为：用户单击镜腿。本方法只做即时引导。
   */
  expandToFullscreen() {
    if (!this.isCardMode()) {
      this.showAsrHint('已是全屏模式');
      return;
    }
    const tip = '单击镜腿回到全屏';
    this.showAsrHint(tip);
    try {
      voice.speak(tip, { interrupt: true });
    } catch (err) {
      bridgeReport(`expand TTS 异常 ${(err && err.message) || err}`);
    }
    bridgeReport('expand 卡片态收到展开指令 → 引导单击镜腿（页面无自展开 API）');
  },

  /**
   * 语音指令「退出」：**一退到底**（用户 2026-10-16 10:25 定稿）。
   *
   * ★ 语义变更（旧版是两级）：
   *   · 旧版：全屏态 → 只收起到卡片态（页面存活，等用户再喊一次才真关）；
   *     卡片态 → 真关闭实例。
   *   · 新版：全屏态与卡片态**都真关闭实例**，统一走 hardExit（黑场 + 两段式 + 密集抢跑）。
   *   原因：用户实测"全屏播放中喊退出只回到卡片"，而卡片态下宿主会禁用交互与语音拦截
   *   （`interaction_enabled=false` `voice_interceptor_registered=false`），用户**不可能**
   *   再补喊一次 —— 两级语义在真机上就等于"退不干净"。
   *   ★ 2026-10-16 11:15 起：**镜腿双击** = 同一条 hardExit 链路（handleHardwareKey ②-a）；
   *     "只收起到卡片"这一动作**已无页面入口**（照片态单击改为无动作，见 onTempleTap）。
   */
  doExit() {
    this.clearPendingTimer();
    this.hardExit(this.isCardMode() ? 'card' : 'fullscreen');
  },

  /* ---------------- 触屏兜底入口 ---------------- */

  // 说明：底部三按钮删除后，翻页/删除/退出**只剩语音与镜腿手势**两个入口
  // （见 handleHardwareKey / swipeStep / onTempleTap），因此原 onTapDelete / onTapNext /
  // onTapPrev / onTapExit 四个包装方法已无绑定方，一并移除，避免与手势语义重复漂移。
  // 2026-10-16：确认条按钮也移除（用户定稿：确认态底部只留引导文案），
  // 原 onTapConfirmDelete / onTapCancelDelete 一并删除；保留下来的只有轻触唤醒。

  onTapStage() {
    // 轻触属于"用户交互"：既唤醒语音（legacy 行为），也确保免唤醒会话在跑
    this.onVoiceWakeup();
    this.ensureListening('tap');
  },

  onKeyDown(event) {
    this.handleHardwareKey(event, 'down');
  },

  onKeyUp(event) {
    this.handleHardwareKey(event, 'up');
  },

  /**
   * 镜腿 / 硬件键统一入口（`onKeyDown` 与 `onKeyUp` 都汇到这里）。
   *
   * Rokid Glasses 镜腿操作的按键编码（官方 `open-agent-format/page-events.md` +
   * **真机桥日志逐条取证**，见 KEY_STEP_MAP 注释）：
   *   · `ArrowRight` / `ArrowDown` —— **往前滑**（一次滑动里两个码成对出现）→ 下一个
   *   · `ArrowLeft`  / `ArrowUp`   —— **往后滑** → 上一个
   *   · `GlobalHook` —— 镜腿触摸（每次手势都会来，**不能立刻当单击**）
   *   · `Enter`      —— 宿主补发的"真单击"（约 +530~660ms）
   *   · `Backspace`  —— 宿主的**"返回"**（只在双击时发）→ 它的默认行为会把页面收成**卡片态**
   *      → **全量接管**，见 ③（这是"不想要见到卡片状态"的关键一处）
   *
   * ★ 五条硬规则（都是真机踩出来的）：
   *   ① **一次手势 = 一串事件** → 第一个方向码动作，其余在 KEY_GESTURE_LOCK_MS 内丢弃；
   *   ② **`GlobalHook` 只是"触摸"** → 延迟 KEY_TAP_DEFER_MS 判定；期间来了方向码就判为滑动；
   *   ③ **同一次单击的两个编码**（`GlobalHook` + `Enter`）→ 由 KEY_TAP_LOCK_MS 归并成一次；
   *   ④ **双击 = 两次 `GlobalHook` down、间隔 ~155ms**（真机取证见 KEY_DOUBLE_TAP_MS）
   *      → 间隔 ≤ KEY_DOUBLE_TAP_MS(220ms，**紧于单击判定延迟 260ms**) 即判双击
   *      → **一退到底**（不再收成卡片）。
   *      down/up 成对到达，故只认 down；滑动（有方向码）会清掉点击起点，不参与双击配对；
   *      单击一旦落定（`fireTempleTap`）也立刻清掉点击起点 → 间隔的多次单击不会被合成双击。
   *      ★ **例外：删除二次确认态下，单击 / 双击都 = 取消删除**（用户 2026-10-16 11:25 定稿），
   *        判定用"点击起点时的确认态快照"`lastTapWasPending`，见 ②-a。
   *   ⑤ **宿主的双击另有一条信号 `Backspace`**（单击是 `Enter`）：页面自己的 220ms 窗口认不出的
   *      "手慢双击"（实测 287~300ms），宿主照样会发 `Backspace` —— 但它的默认行为（"返回上一级"）
   *      在全屏智能体里**只会收成卡片态**，用户明确不要这个中间态 → `Backspace` **全量接管**
   *      （吞掉 + 一退到底，见 ③），并由 `onTargetChanged` 的兜底抢关补上最后一道。
   * ★ 每个事件都写桥日志（**未知编码照样记**）——镜腿若还有别的手势，日志里能直接看到它的 code。
   */
  handleHardwareKey(event, phase) {
    const code = event && event.code;
    if (!code) return;

    const now = Date.now();

    // ---------- ① 方向码：滑动 → 翻页 ----------
    if (KEY_STEP_MAP[code] != null) {
      this.consumeKey(event);
      // 来了方向码 → 这次是"滑动"，取消那个待判定的单击（否则滑动会顺带暂停视频）
      this.cancelTapDefer();
      // 滑动不是点击：清掉"待配对点击起点"，避免连续两次滑动被误判成双击退出
      this.lastTapDownAt = 0;
      this.lastTapWasPending = false;

      if (now < this.gestureLockUntil) {
        bridgeReport(
          `key ${phase} code=${code} ↺归并（同一次滑动，锁内剩 ${this.gestureLockUntil - now}ms）`
        );
        return;
      }
      this.gestureLockUntil = now + KEY_GESTURE_LOCK_MS;

      const delta = KEY_STEP_MAP[code];
      bridgeReport(`key ${phase} code=${code} → ${delta > 0 ? '下一个' : '上一个'}`);
      this.swipeStep(delta);
      return;
    }

    // ---------- ② 单击 / 双击：GlobalHook（触摸）/ Enter（宿主确认） ----------
    if (code === 'Enter' || code === 'GlobalHook') {
      this.consumeKey(event);
      // ★ 抬起事件不参与点击判定：每次触摸都是 down+up 成对到达（真机日志），
      //   若把 up 也当一次点击，"双击"会被数成四次。
      if (phase === 'up') {
        bridgeReport(`key up code=${code}（抬起，不计点击）`);
        return;
      }
      // ★ 记录"最近一次镜腿触摸"（只认 down）：`Backspace` 靠它判断
      //   "这次返回是不是宿主为一次双击发的"（见 KEY_BACK_TAP_MS）
      this.lastKeyTouchAt = now;
      // ---------- ②-a 双击：普通态 → 一退到底；删除确认态 → 取消删除（见 KEY_DOUBLE_TAP_MS） ----------
      // ★ 放在 tapLock 判定**之前**：双击窗口(220ms)小于单击判定延迟(260ms)，
      //   所以配对判定必定发生在"这一次点击被判成单击、tapLock 上锁"之前；
      //   放在前面同时保证不会被**上一次**单击留下的 tapLock 误吞。
      // ★ 只认 `GlobalHook`：宿主在单击后补发的是 `Enter`（+530~660ms），
      //   若也算点击，**每次单击都会变成"双击退出"**——这条区分是安全底线。
      const gap = this.lastTapDownAt ? now - this.lastTapDownAt : -1;
      if (code === 'GlobalHook' && gap >= 0 && gap <= KEY_DOUBLE_TAP_MS) {
        const wasPending = this.lastTapWasPending;
        this.lastTapDownAt = 0;
        this.lastTapWasPending = false;
        this.cancelTapDefer(); // 撤掉第一次点击还挂着的单击动作（避免"先暂停，再退出"）
        this.tapLockUntil = now + KEY_TAP_LOCK_MS; // 抑制宿主随后可能补发的 Enter
        // ★ 删除二次确认态：**单击 / 双击都 = 取消删除**（用户 2026-10-16 11:25 定稿）。
        //   这里用起点快照 `wasPending`（而非当前的 pendingDelete）：慢双击时第一次单击
        //   已经把确认态取消掉了，若只看当前值，双击就会掉进"退出"分支 —— 那是 bug。
        if (this.data.pendingDelete || wasPending) {
          bridgeReport(
            `key double(间隔 ${gap}ms ≤ ${KEY_DOUBLE_TAP_MS}ms) 删除确认态 → 取消删除（与单击同语义）`
          );
          this.exitPendingDelete('speak');
          return;
        }
        bridgeReport(
          `key double(code=GlobalHook, 间隔 ${gap}ms ≤ ${KEY_DOUBLE_TAP_MS}ms) → 镜腿双击：一退到底`
        );
        this.hardExit('gesture-double');
        return;
      }
      if (now < this.tapLockUntil) {
        bridgeReport(
          `key ${phase} code=${code} ↺归并（同一次单击，锁内剩 ${this.tapLockUntil - now}ms）`
        );
        return;
      }
      this.lastTapDownAt = now;
      this.lastTapWasPending = !!this.data.pendingDelete;

      if (code === 'Enter') {
        // 宿主确认的"真单击"：立即响应（若 GlobalHook 的延迟判定还没触发，就取消它）
        this.cancelTapDefer();
        this.fireTempleTap(now, 'Enter');
        return;
      }
      // GlobalHook：先等一会儿，看是不是滑动的开头
      if (this.tapDeferTimer) {
        // 诊断留痕：这里多半是"手慢了的双击"（间隔 > KEY_DOUBLE_TAP_MS，够不上双击）
        // 或又一次快点击；下次真机复现时可按 gap 判断是窗太紧还是用户真点了两下。
        bridgeReport(
          `key ${phase} code=GlobalHook ↺已有待判定单击（间隔 ${gap}ms，双击窗 ${KEY_DOUBLE_TAP_MS}ms）`
        );
        return;
      }
      this.tapDeferTimer = setTimeout(() => {
        this.tapDeferTimer = null;
        this.fireTempleTap(Date.now(), `GlobalHook+${KEY_TAP_DEFER_MS}ms`);
      }, KEY_TAP_DEFER_MS);
      bridgeReport(
        `key ${phase} code=GlobalHook …待判定（${KEY_TAP_DEFER_MS}ms 内无方向码 = 单击；${KEY_DOUBLE_TAP_MS}ms 内再来一次 = 双击退出）`
      );
      return;
    }

    // ---------- ③ `Backspace`（宿主的"返回"）—— **全量接管**，绝不让它改承载位 ----------
    // ★ 官方文档（documentation/3-api/framework/page.md「Focus and Default Actions」）：
    //   `Backspace` 的默认行为在 **keyUp 之后**执行（"返回上一级 / 无上级可返回则请求关闭智能体"），
    //   页面要接管就必须 `preventDefault()` —— 所以 down/up **两个阶段都吞**。
    // ★ 它就是"双击却出现卡片状态"的来源：宿主的**双击**编码成 `Backspace`，而全屏智能体的
    //   "上一级"就是宿主自己的 **AIUI 卡片态** → 默认行为把页面收成卡片（真机日志 11:33:56 / 11:34:04）。
    //   宿主编码规则：**单击 `Enter`（确认）、双击 `Backspace`（返回）**。
    // ★★ 因此这里**已无"交给宿主默认行为"这条路径**（用户 2026-10-16 11:41：
    //   "我不想要见到卡片状态 …… 能接管就接管掉"）—— 本智能体没有多级页面，
    //   `Backspace` 唯一合法语义就是"离开当前智能体"，我们把它从"宿主收卡片"改成"自己一退到底"：
    //     · 已在退出流程中（hardExitStarted / exitPending）→ **只吞**，不重复触发；
    //     · 页面已在卡片态 → 走卡片态真关闭（这个状态本来就该消失）；
    //     · 其余（全屏态）→ 吞掉 + `hardExit` 一退到底，与语音「退出」同一条链路。
    //   `KEY_BACK_TAP_MS` 在此**仅用于日志归类**（快/慢双击），不再决定是否接管。
    if (code === 'Backspace') {
      const sinceTouch = this.lastKeyTouchAt ? now - this.lastKeyTouchAt : -1;
      const near = sinceTouch >= 0 && sinceTouch <= KEY_BACK_TAP_MS;
      this.consumeKey(event); // ★ 必须在 keyUp 阶段也吞：宿主默认动作在 keyUp 之后执行
      if (phase === 'up') {
        bridgeReport('key up code=Backspace 已接管（宿主的"返回上一级"不执行）');
        return;
      }
      if (this.hardExitStarted || this.exitPending) {
        bridgeReport(`key down code=Backspace（距点击 ${sinceTouch}ms）退出流程中 → 仅吞掉`);
        return;
      }
      if (this.isCardMode()) {
        bridgeReport(`key down code=Backspace（距点击 ${sinceTouch}ms）卡片态 → 直接真关闭`);
        this.exitPending = true;
        this.requestRealClose(0);
        return;
      }
      bridgeReport(
        `key down code=Backspace（距点击 ${sinceTouch}ms，${near ? '邻近点击=宿主判定的双击' : '无邻近点击'}）` +
          ' → 接管：一退到底（不再交给宿主收成卡片）'
      );
      this.hardExit('host-backspace');
      return;
    }

    // ⚠️ 未知编码照样留痕（镜腿其它手势的发现通道）
    bridgeReport(`key ⚠未知 ${phase} code=${code}`);
  },

  /**
   * 单击动作的唯一出口。
   * 在这里上锁（KEY_TAP_LOCK_MS），把同一次单击的 `GlobalHook` 与 `Enter` 归并成一次动作 ——
   * 否则会"暂停后立刻恢复"，看起来像单击完全没反应。
   *
   * ★ 同时**断掉双击配对**（用户 2026-10-16 11:29 要求）：一次单击已经落定生效，
   *   就绝不能再和后面某次点按配成"双击退出" —— 否则"间隔的多次单击"会被误判成双击。
   *   配对只在一次点击**尚未判定完成**的窗口内（≤ KEY_DOUBLE_TAP_MS）有效。
   */
  fireTempleTap(now, src) {
    this.tapLockUntil = (now || Date.now()) + KEY_TAP_LOCK_MS;
    this.lastTapDownAt = 0;
    this.lastTapWasPending = false;
    bridgeReport(`key tap(${src}) → 镜腿单击`);
    this.onTempleTap();
  },

  /** 取消"待判定的单击"（方向码到达 = 这次其实是一次滑动） */
  cancelTapDefer() {
    if (this.tapDeferTimer) {
      clearTimeout(this.tapDeferTimer);
      this.tapDeferTimer = null;
    }
  },

  /** 拦截宿主默认行为（滚动根视图 / 进入导航模式）——失败也不影响业务 */
  consumeKey(event) {
    try {
      if (event && event.preventDefault) event.preventDefault();
    } catch (err) {
      /* 忽略 */
    }
  },

  /**
   * 镜腿滑动 → 翻页（真机映射见 KEY_STEP_MAP：往前滑=下一个、往后滑=上一个）。
   * 与语音「下一个 / 上一个」走**同一条路径**（`step()`），保证两种入口行为一致。
   */
  swipeStep(delta) {
    // 删除二次确认态不翻页（该态下"单击 = 取消"，见 onTempleTap），避免确认中把条目翻走
    if (this.data.pendingDelete) {
      this.showAsrHint('请先说「确认」或「取消」');
      return;
    }
    this.step(delta);
  },

  /**
   * 镜腿单击（`GlobalHook` 触摸 / `Enter` 宿主确认）——按用户定稿的**场景化语义**：
   *   · 删除二次确认中 → **取消**（等价说「取消」，带 toast + 播报反馈）
   *   · 视频播放中     → **暂停 / 继续播放**
   *   · 照片显示中     → **无效果**（不做任何事，也不弹提示打扰）
   *   · 双击（两次点击 ≤ KEY_DOUBLE_TAP_MS）→ 在 handleHardwareKey ②-a 就分流走了，
   *     **不会**进到这里：**普通态 = 一退到底**（2026-10-16 11:15 需求）；
   *     **删除确认态 = 取消删除**，与单击同语义（11:25 需求）——即确认态里"点一下就取消、
   *     连点两下也取消"，绝不会因为手快点成双击就把整个智能体退掉。
   *
   * ★ 只在 `fireTempleTap()` 里被调用 —— 那里已经做了"同一次单击只算一次"的抑制，
   *   并且把"滑动开头那下触摸"排除掉了（见 handleHardwareKey）。
   *
   * 说明：`playing` 的权威来源是 `<video>` 的 `bindplay` / `bindpause` 回调，
   * 这里只读它决定该 pause 还是 play，并给一个即时提示（视频多为几秒短片，
   * 没有提示用户难以判断单击是否生效）。
   */
  onTempleTap() {
    if (this.data.pendingDelete) {
      this.exitPendingDelete('speak');
      return;
    }
    // ★ 照片（及不可播放占位）态单击镜腿 → **无动作**（用户 2026-10-16 11:15 定稿）：
    //   旧版这里是 `collapseToWindowMode('tap')`（收起到卡片），但真机日志显示用户在**双击**
    //   时被这行收进了卡片（双击 = 两次 GlobalHook，见 KEY_DOUBLE_TAP_MS），
    //   观感成了"双击只退到卡片"。既然双击已接管为"一退到底"，单击在此态就无需任何动作
    //   —— 也不弹提示打扰（翻页/退出都有各自的入口）。
    if (!this.data.isVideo || this.data.videoBroken) {
      bridgeReport('key tap 照片/占位态：无动作（单击不再收起卡片）');
      return;
    }

    const wasPlaying = !!this.data.playing;
    this.withVideoContext((ctx) => {
      try {
        if (wasPlaying) ctx.pause();
        else ctx.play();
      } catch (err) {
        console.warn('[page] 单击暂停/播放失败：', err);
      }
    });
    this.showAsrHint(wasPlaying ? '已暂停' : '继续播放');
  },
};

/* "M:SS" → 秒 */
function parseDurationToSeconds(text) {
  const parts = String(text || '').split(':');
  if (parts.length !== 2) return 0;
  const m = Number(parts[0]) || 0;
  const s = Number(parts[1]) || 0;
  return m * 60 + s;
}

/**
 * 底部状态条文案（用户指定的四态）。
 *
 * @param {'listening'|'recognizing'|'done'|'fail'} phase 当前相位
 * @param {number} tick 用于"进行中"两态尾部的省略号 1→2→3 循环
 * @param {string} [detail] done=识别到的文字；fail=错误码（会翻成中文）
 * @returns {string}
 */
function voiceHudLabel(phase, tick, detail) {
  const dots = VOICE_HUD_DOTS[Math.abs(Number(tick) || 0) % VOICE_HUD_DOTS.length];
  const raw = String(detail || '').trim();
  if (phase === 'recognizing') return `识别中${dots}`;
  if (phase === 'done') return raw ? `识别完成：${raw}` : '识别完成';
  if (phase === 'fail') {
    const reason = VOICE_FAIL_TEXT[raw] || raw;
    return reason ? `识别失败（${reason}）` : '识别失败';
  }
  return `正在聆听${dots}`;
}
</script>

<page>
  <view class="screen">
    <!-- ============ Z0 媒体层：铺满整个容器（需求 4/5） ============ -->
    <image
      ink:if="{{ !empty && !isVideo }}"
      class="media-layer"
      src="{{ src }}"
      mode="aspectFit"
      bindload="onImageLoad"
      binderror="onImageError"
    />
    <!-- ★ videoReady 门控：切到视频时 src 还是"未经可播性判定的原始地址"（HEVC 源必然加载失败），
         若此刻就挂载 video 元素，宿主立刻报错 → onVideoError 会抢先播报「视频无法播放」、
         与转码等待流程打架（真机时序）。因此只有 prepareVideo 决策完成（直接播/播转码缓存）才挂载。
         ★★ 且视频地址绑**独立字段 videoSrc**（不是照片用的 src）：切到照片时 videoSrc 为空串，
         残留一帧的 video 元素也拿不到图片地址 → 杜绝宿主视频桥把 jpg 当视频解导致的误报错。 -->
    <video
      ink:if="{{ !empty && isVideo && !videoBroken && videoReady }}"
      id="mainVideo"
      class="media-layer"
      src="{{ videoSrc }}"
      poster="{{ poster }}"
      autoplay
      loop
      object-fit="contain"
      start-time="0"
      bindloadedmetadata="onVideoLoadedMetadata"
      bindtimeupdate="onVideoTimeUpdate"
      bindplay="onVideoPlay"
      bindpause="onVideoPause"
      bindwaiting="onVideoWaiting"
      bindended="onVideoEnded"
      binderror="onVideoError"
    />
    <!-- 视频播放失败占位：卸载视频元素后由这里接管画面（否则宿主会持续画等号箭头样式的 ASCII 错误占位）。注意：模板注释里禁止出现形如"尖括号+标签名"的字面量，也不能出现注释结束符 —— 运行时解析器会把它们当真，注释后半段会泄漏成屏幕文字（真机已复现） -->
    <view
      class="hud hud-broken"
      ink:if="{{ !empty && isVideo && videoBroken }}"
      bindtap="onTapStage"
    >
      <text class="broken-title">视频无法播放</text>
      <text class="broken-note">该视频编码不受支持（仅支持 H.264）</text>
      <text class="broken-note">说「下一个」跳过 · 说「删除」清理</text>
    </view>

    <!-- ============ Z10 点击唤醒层（独立于按钮，避免冒泡误触发语音） ============ -->
    <view class="tap-layer" bindtap="onTapStage"></view>

    <!-- ============ Z15 居中加载指示（媒体就绪前：转圈 + 文案） ============ -->
    <view class="hud hud-loading" ink:if="{{ loading }}" bindtap="onTapStage">
      <!-- 压暗仅视频用（缓冲时压在定格画面上更清晰）；照片不压暗，免得每翻一张都闪一次黑屏 -->
      <view class="loading-dim" ink:if="{{ isVideo }}"></view>
      <view class="spinner"></view>
      <text class="loading-text">{{ loadingText }}</text>
    </view>

    <!-- ============ 服务门禁页：启动时桥不可达 → 全屏接管，唯一指令=退出 ============
         版式（用户 2026-10-16 定稿）：无标题行，标题与全部内容**垂直水平居中**成一列；
         不放二维码 —— 眼镜屏幕只适合人眼阅读，扫码交互不成立，下载地址给纯文本 URL。
         桥就绪后本页自动关闭（轮询见 startGatePolling），无需重新唤醒智能体。 -->
    <view class="hud hud-gate" ink:if="{{ gate }}" bindtap="onTapStage">
      <view class="gate-panel">
        <text class="gate-title">未检测到照片删除服务</text>
        <text class="gate-line">请下载安装「照片删除智能体服务」App，</text>
        <text class="gate-line">并授权启动后，才能正常使用本智能体</text>
        <view class="gate-url-block">
          <text class="gate-url-label">最新版apk安装包下载地址</text>
          <text class="gate-url">https://github.com/osagem/photodelaiuibridge/releases</text>
        </view>
        <!-- 安装引导：字号/字体与上方 URL 完全一致（用户定稿），压在地址框之下 -->
        <text class="gate-tip">apk下载到手机后，使用RokidAPP-工具箱-眼镜应用管理安装</text>
      </view>
    </view>

    <!-- ============ 空库态：用规范内置组件 error-state ============ -->
    <view class="hud hud-empty" ink:if="{{ empty }}" bindtap="onTapStage">
      <error-state text="媒体库已空"></error-state>
      <text class="empty-note">说「退出」结束</text>
    </view>

    <!-- ============ Z20/Z25 屏幕左下角信息组（自下而上：命令提示 → 序号+语音状态 → 视频时间） ============
         四块内容放**同一个 flex 列**里，保证：① 各行文字左边界永远对齐；
         ② 删除二次确认时确认条**原位替换**命令提示行，不会与上面那行状态条压在一起
           （列高由内容决定，组的底部固定 12px，向上生长）。 -->
    <view class="hud hud-bottom" bindtap="onTapStage">
      <!-- 视频播放时间（仅视频；独立成行，位于「序号」行**上方**）。
           说明：原「序号 + 时间」同行 + 其下细进度线，已按用户要求拆分并去掉进度线。 -->
      <view class="time-line" ink:if="{{ !empty && !gate && isVideo }}">
        <text class="time-text">{{ timeline }}</text>
      </view>

      <!-- 底部提示行：所有错误反馈 + 未识别指令引导（用户 2026-10-16 定稿：位于
           「序号+语音状态」行**上方**，替代原顶部 toast；ASR_HINT_MS 后自动消隐） -->
      <view class="asr-hint" ink:if="{{ asrHint }}">
        <text class="asr-hint-text">{{ asrHint }}</text>
      </view>

      <!-- 当前序号 + 语音识别状态：**同一行**、垂直居中（用户 2026-10-16 定稿）。
           序号常驻（随时知道看到第几张）；语音状态为四态，"进行中"用尾部点数循环表达。 -->
      <!-- 常驻（空库也显示，保证「正在聆听」状态可见）；空库/门禁页只藏序号（0/0 无意义） -->
      <view class="status-line">
        <text class="crumb-text" ink:if="{{ !empty && !gate }}">{{ breadcrumb }}</text>
        <text class="voice-hud-text" ink:if="{{ voiceHudVisible }}">{{ voiceHudText }}</text>
      </view>

      <!-- 删除二次确认引导（原位替换命令提示行；不可逆动作必须留可视确认）。
           ★ 无按钮（用户 2026-10-16 定稿）：语音是主入口（说「确认」/「取消」）、
           镜腿单击 = 取消；点本行会冒泡到外面这层的 onTapStage = 轻触唤醒，无副作用。
           原「说「确认」删除，或说「取消」」的顶部 toast 引导已并入本行。 -->
      <view class="confirm-bar" ink:if="{{ pendingDelete }}">
        <text class="confirm-warn">删除不可恢复</text>
        <text class="confirm-text">说「确认」删除，或说「取消」</text>
      </view>

      <!-- 可用语音命令提示（语音是主入口、触屏是兜底 → 底部不摆按钮，改为常驻命令清单） -->
      <view class="cmd-pill" ink:if="{{ !pendingDelete }}">
        <text class="cmd-text">{{ cmdHint }}</text>
      </view>
    </view>

    <!-- ============ 退出期黑场遮罩（消闪，见 EXIT_VEIL_MS） ============
         退出流程先铺满这块纯黑，宿主收起时抓取到的卡片缩略图即为黑场 →
         用户看到的是"暗下去 → 消失"，而不是"内容缩小成小卡片闪一下"。
         ★ 必须放在 .screen 内部：.screen 才是 position:relative 的定位上下文，
           放在它外面（兄弟节点）会相对外层包含块定位，覆盖范围与画布不严格一致，边缘可能露出内容。
         z-index 高于所有 HUD 层（.hud 最高 20），故取 90。 -->
    <view class="exit-veil" ink:if="{{ exiting }}"></view>

  </view>
</page>

<style>
/* ============================================================================
 * 样式对齐 AIUI v0.18「Monochrome-Green Scientific Interface」设计系统
 * （design/monochrome-green.md §11 兼容映射表）：
 *   · 12px 通用圆角     → 4px 控件 / 6px 面板
 *   · 2px 常态边框      → 1px 结构线（2px 只留给强焦点）
 *   · 40%+ 大面积高亮   → ≤12% 局部 tint
 *   · 700 粗体          → 500（不用粗体做层级）
 *   · 第二色相（红）    → 单绿 + 线型冗余编码（§1.4：颜色不能单独编码语义）
 * 色相全部收敛到 #40ff5e 一个通道；所有 token 来自 app.wxss。
 *
 * ★ 刻意保留项：压在全屏媒体之上的 HUD 仍用低透明度黑底 —— §1.3「可读性优先于
 *   氛围」：照片/视频背景不可预测，纯描边文字在亮画面上不可读。
 * ========================================================================= */

/* ================= 容器 ================= */
/* 画布严格对齐官方全屏视口 480×352（设计系统 §4 Reference canvas；真机日志实测一致） */
.screen {
  position: relative;
  width: 480px;
  height: 352px;
  overflow: hidden;
  background-color: #000000;
}

/* ================= 媒体层：铺满整个显示区域 ================= */
.media-layer {
  position: absolute;
  top: 0;
  left: 0;
  width: 100%;
  height: 100%;
  z-index: 0;
}

/* ================= 点击唤醒层 ================= */
.tap-layer {
  position: absolute;
  top: 0;
  left: 0;
  width: 100%;
  height: 100%;
  z-index: 10;
}

/* ================= 退出期黑场遮罩（消闪） ================= */
/* 退出流程专用：铺满纯黑 → 宿主收起时抓取的卡片缩略图为黑场，不显示页面内容。
   z-index 必须高于 .hud（20）与 .tap-layer（10），见 EXIT_VEIL_MS。 */
.exit-veil {
  position: absolute;
  top: 0;
  left: 0;
  width: 100%;
  height: 100%;
  z-index: 90;
  background-color: #000000;
}

/* ================= HUD 叠放基类 ================= */
.hud {
  position: absolute;
  left: 0;
  right: 0;
  display: flex;
  justify-content: center;
  z-index: 20;
}

/* ---------- 左下角信息组的各行（视频时间 / 序号+语音状态） ---------- */
/* ★ 屏幕左下角自下而上堆叠（改位置前先算高度，别相互压住；组底固定 `bottom: 12px`，向上生长）：
     命令提示行（或删除确认条）  高 ≈ 24 / 34
     序号 + 语音状态行           高 ≈ 26
     视频时间行（仅视频）        高 ≈ 22
   三行 + 2×4px 间距 ≈ 66~88px → 最高占到距底 12+88 = 100px。

/* 视频播放时间：独立成行，位于「序号」行**上方**（用户 2026-10-16 定稿）。
   原实现是「序号 · 时间」同行 + 其下 1px 进度线，进度线已按用户要求移除。 */
.time-line {
  display: flex;
  flex-direction: row;
  align-items: center;
  padding: 3px 12px;
  border-radius: var(--radius-sm, 4px);
  background-color: var(--color-scrim-50, rgba(0, 0, 0, 0.5));
}

/* 时间轴是数值 → 规范 data 字体（monospace / 400），普通可读文本档亮度 72% */
.time-text {
  font-family: monospace;
  font-size: 13px;
  font-weight: 400;
  letter-spacing: 0.04em;
  color: var(--color-ink-primary, rgba(64, 255, 94, 0.72));
}

/* 序号 + 语音状态**同一行**：row + `align-items: center` 保证两段文字垂直居中；
   底色与命令提示行一致（半透明黑 50%），整行读作一条信息。 */
.status-line {
  display: flex;
  flex-direction: row;
  align-items: center;
  gap: 10px;
  padding: 4px 12px;
  border-radius: var(--radius-sm, 4px);
  background-color: var(--color-scrim-50, rgba(0, 0, 0, 0.5));
}

/* 序号（`1/7`）同属数值 → monospace；取最高强调亮度 100%（一眼可辨"看到第几张"） */
.crumb-text {
  font-family: monospace;
  font-size: 13px;
  font-weight: 500;
  letter-spacing: 0.03em;
  color: var(--color-ink, #40ff5e);
}

/* ---------- 屏幕左下角信息组（视频时间 / 序号+语音状态 / 命令提示 或 删除确认，同一列） ---------- */
/* 用户 2026-10-16 定稿：各组文字**靠屏幕底部居左对齐**。
   左右 16px / 底部 12px = 设计系统安全内边距；列内间距 4px。
   ★ 列高随内容变化（确认条比命令提示行高 22px、视频多一行时间），故它整体是"向上生长"——
     底部锚点固定 12px，新增行只会往上长，不会压到别的东西（上方已无 `.hud-info`）。 */
.hud-bottom {
  bottom: 12px;
  left: 16px;
  right: 16px;
  flex-direction: column;
  /* 居左（.hud 基类默认 center） */
  align-items: flex-start;
  gap: 4px;
  z-index: 25;
}

/* 半透明黑底衬托：与上方「正在聆听…」状态条同一手法（用户定稿：不透明度 50%）。 */
.cmd-pill {
  display: flex;
  flex-direction: row;
  align-items: center;
  padding: 4px 12px;
  border-radius: var(--radius-sm, 4px);
  background-color: var(--color-scrim-50, rgba(0, 0, 0, 0.5));
}

.cmd-text {
  /* 14px：命令清单共 28 个全角字（含「上一个」）→ 28×14 + 内边距 24 + 左边距 16 ≈ 432px < 480px 画布宽；
     若用 15px 会到 ~468px（只剩约 12px 余量），一旦字体度量略宽就会被裁。宁可小 1px 也不冒险。 */
  font-size: 14px;
  font-weight: 500;
  /* 必须单行：命令清单折行会与上方状态条/信息条挤在一起（官方 wxss/property.md 支持 nowrap） */
  white-space: nowrap;
  letter-spacing: 0.02em;
  /* 与「视频无法播放」占位标题、「正在聆听…」同一档：100% 亮度单色高亮 */
  color: var(--color-ink, #40ff5e);
}

/* ---------- 删除确认条 → 规范 error-state（虚线强边框 + 深底衬） ---------- */
/* 在信息组内**原位替换**命令提示行，故宽度撑满整组（align-self: stretch）。
   2026-10-16 定稿：无按钮，仅两段文案 —— 高亮警示「删除不可恢复」+ 操作引导。 */
.confirm-bar {
  align-self: stretch;
  display: flex;
  flex-direction: row;
  align-items: center;
  gap: 8px;
  height: 34px;
  padding: 0 10px;
  box-sizing: border-box;
  border: 1px dashed var(--color-line-strong, rgba(64, 255, 94, 0.72));
  border-radius: var(--radius-sm, 4px);
  background-color: rgba(0, 0, 0, 0.72);
}

/* 警示段：100% 亮度（与语音状态同级），承担"不可逆"的最强提醒 */
.confirm-warn {
  font-size: 12px;
  font-weight: 500;
  color: var(--color-ink, #40ff5e);
}

/* 引导段：常规可读亮度 */
.confirm-text {
  flex: 1;
  font-size: 12px;
  font-weight: 400;
  color: var(--color-ink-primary, rgba(64, 255, 94, 0.72));
}


/* ---------- 空库态（容器；文案由 <error-state> 组件呈现） ---------- */
.hud-empty {
  top: 0;
  bottom: 0;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 10px;
}

.empty-note {
  font-size: 12px;
  color: var(--color-ink-secondary, rgba(64, 255, 94, 0.48));
}

/* ---- 视频播放失败占位（与空库态同族） ---- */
.hud-broken {
  top: 0;
  bottom: 0;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 8px;
}

.broken-title {
  font-size: 16px;
  color: var(--color-ink, #40ff5e);
}

/* ================= 服务门禁页（桥不可达，2026-10-16 新增） ================= */
/* 全屏不透明黑底接管：门禁期没有任何媒体可显示，纯文本信息页。
   版式：无标题行，标题与全部内容**垂直水平居中**成一列（用户定稿）。
   z-index 30：压过 tap-layer(10) 与底部信息组(20)，门禁期屏蔽一切主界面元素。 */
.hud-gate {
  top: 0;
  bottom: 0;
  z-index: 30;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  background-color: #000000;
}

.gate-panel {
  display: flex;
  flex-direction: column;
  align-items: center;
  max-width: 448px;
}

/* 标题：页面最亮档，居于整列顶部（整列居中 → 标题落在屏幕中部区域） */
.gate-title {
  font-size: 22px;
  font-weight: 500;
  color: var(--color-ink, #40ff5e);
  margin-bottom: 14px;
}

/* 正文行：普通可读文本档（72% 亮度） */
.gate-line {
  font-size: 16px;
  line-height: 1.5;
  color: var(--color-ink-primary, rgba(64, 255, 94, 0.72));
}

/* 下载地址块：描边面板（结构线 48%），URL 用规范 data 字体（monospace） */
.gate-url-block {
  display: flex;
  flex-direction: column;
  align-items: center;
  margin: 14px 0 10px;
  padding: 8px 12px;
  border: var(--border-hairline, 1px) solid var(--color-line-default, rgba(64, 255, 94, 0.48));
  border-radius: var(--radius-md, 6px);
}

.gate-url-label {
  font-size: 13px;
  color: var(--color-ink-secondary, rgba(64, 255, 94, 0.48));
  margin-bottom: 2px;
}

/* URL 53 字符：13px monospace ≈ 415px，可放进 448px 面板（480 画布 - 两侧安全边距） */
.gate-url {
  font-family: monospace;
  font-size: 13px;
  color: var(--color-ink, #40ff5e);
}

/* 安装引导行：字号与字体**与上方 URL 完全一致**（用户 2026-10-16 定稿）；
   32 字符 13px monospace ≈ 350px，单行可容纳；亮度取正文档（72%），不与 URL 抢注意力。 */
.gate-tip {
  font-family: monospace;
  font-size: 13px;
  line-height: 1.4;
  text-align: center;
  color: var(--color-ink-primary, rgba(64, 255, 94, 0.72));
}


.broken-note {
  font-size: 12px;
  color: var(--color-ink-secondary, rgba(64, 255, 94, 0.48));
}

/* ---------- 未识别指令引导 → 位于「序号+语音状态」行上方 ---------- */
/* 同一信息组成员：50% 半透明黑底 + 100% 高亮，视觉层级与语音状态一致；
   `white-space: nowrap` 防止两行撑高把组顶上去。 */
.asr-hint {
  display: flex;
  flex-direction: row;
  align-items: center;
  padding: 4px 12px;
  border-radius: var(--radius-sm, 4px);
  background-color: var(--color-scrim-50, rgba(0, 0, 0, 0.5));
}

.asr-hint-text {
  font-size: 14px;
  font-weight: 500;
  white-space: nowrap;
  color: var(--color-ink, #40ff5e);
}

/* ---------- 语音识别状态（四态）→ 与「序号」**同一行**（.status-line 内） ---------- */
/* 位置：屏幕左下角信息组的自下而上第二行（用户 2026-10-16 定稿）——
   左上角（视野上缘易被遮挡）→ 底部居中 → 与命令提示行同列 → 现与「1/7」序号同行、
   垂直居中。定位与底色由父级 `.status-line` 统一负责（媒体画面普遍偏亮，
   只有高亮字会被淹没 → 整行共用半透明黑 50% 底衬，压在实拍照片上依然一眼可见）。 */

.voice-hud-text {
  font-size: 16px;
  font-weight: 500;
  /* 与「视频无法播放」占位标题同一档：100% 亮度单色高亮（单绿屏上的最强档） */
  color: var(--color-ink, #40ff5e);
}

/* ---- 居中加载指示（转圈 + 文案；转圈写法见官方 wxss/function.md §4） ---- */
.hud-loading {
  top: 0;
  bottom: 0;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 12px;
}

/* 视频专用压暗层（照片不加：避免每翻一张闪一次黑）；先于转圈/文案绘制，故自在其下 */
.loading-dim {
  position: absolute;
  top: 0;
  left: 0;
  right: 0;
  bottom: 0;
  background-color: rgba(0, 0, 0, 0.55);
}

.spinner {
  width: 28px;
  height: 28px;
  border-radius: 50%;
  border: 2px solid var(--color-line-muted, rgba(64, 255, 94, 0.24));
  border-top-color: var(--color-ink, #40ff5e);
  animation: spin 1s linear infinite;
}

@keyframes spin {
  from {
    transform: rotate(0deg);
  }
  to {
    transform: rotate(360deg);
  }
}

.loading-text {
  font-size: 13px;
  color: var(--color-ink-primary, rgba(64, 255, 94, 0.72));
}

</style>
