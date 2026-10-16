# 照片删除 · Rokid Glasses AIUI 智能体

在 Rokid Glasses 上通过**语音 + 镜腿手势**浏览、播放、删除系统相册（DCIM）中的照片与视频。

> 这是**AIUI 智能体（Ink）端**源码。它本身没有系统相册读写能力 —— 所有相册访问都经由
> 本机回环 HTTP 桥 **照片删除智能体服务**（DCIM Bridge，独立侧载 App）完成。
> 桥的源码与安装包：https://github.com/osagem/photodelaiuibridge

## 功能

- **浏览**：语音「下一个 / 上一个」，或镜腿前滑 / 后滑
- **视频**：进入即自动播放并循环；HEVC 源由桥端自动转码为 H.264 后播放（带进度、有缓存、二次播放秒开）
- **删除**：语音「删除」→ 二次确认（语音「确认」/「取消」，或删除确认态下镜腿单击 / 双击取消）
- **退出**：语音「退出」或镜腿双击 → 一次关到底（不残留卡片态）
- **服务门禁页**：启动时若检测不到本机桥服务，显示全屏引导页（含 APK 下载地址），
  服务就绪后自动进入主界面，无需重新唤醒

## 目录结构

```
app.json                        智能体元信息（名称、页面、权限、engine 版本）
app.js / app.wxss               应用入口与全局样式（单色绿设计 token）
AGENTS.md                       智能体说明与行为约定（开发用系统文档）
lib/bridge.js                   DCIM 桥 HTTP 客户端（基址发现 / JSON GET / 结果回读）
lib/media-store.js              媒体库状态层（清单 / 游标 / 真实删除）
lib/intent.js                   语音意图路由（命令词典 + 待确认态安全词典）
lib/voice.js                    语音识别与播报封装（免唤醒连续识别 / 四态相位 / 自听防护）
lib/format.js                   时间与文案格式化
pages/index/index.ink           单页智能体全部逻辑与界面（模板 + 脚本 + 样式）
```

## 依赖

| 项 | 要求 |
|---|---|
| 运行时 | AIUI Ink `>=0.17.0`（`<video>` 组件自 v0.17.0 起提供） |
| 伴生 App | `com.osagem.photodelaiuibridge`（DCIM 桥），需先安装并授权「所有文件访问」 |
| 通信 | 本机回环 `http://127.0.0.1:38999`（不访问任何外部服务器） |

## 构建与安装

```bash
# 打包
aix pack ./photodelaiuiagent -o dist/photodelaiuiagent.aix

# 安装到设备（-s 指定序列号）
aix install ./photodelaiuiagent -s <serial>
```

> 工程内的 `.aix/agent-id` 保存本机智能体 UUID，**不入库**（见 `.gitignore`）：
> 它决定安装后的 agentId 稳定性，请勿删除本地文件。

## 设计约束（AIUI v0.18 单色绿）

- 显示硬件是**单绿透明面板**，只有一个绿色通道 → 界面只用 `#40ff5e` 一个色相，
  层级靠亮度档（100 / 72 / 48 / 24 / 12 / 6%）、线宽与留白表达。
- 画布 **480×352**，安全内边距 16px（横）/ 12px（纵）。
- 语义状态**冗余编码**（文字标签 + 线型），颜色不单独承担语义。
