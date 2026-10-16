# 照片删除 · Rokid Glasses AIUI 智能体

在 Rokid Glasses 上通过**语音 + 镜腿手势**浏览、播放、删除系统相册（DCIM）中的照片与视频。

> 这是**AIUI 智能体（Ink）端**源码。它本身没有系统相册读写能力 —— 所有相册访问都经由
> 本机回环 HTTP 桥 **照片删除智能体服务**（DCIM Bridge，独立侧载 App）完成。
> 桥的源码与签名安装包：[**osagem/photodelaiuibridge**](https://github.com/osagem/photodelaiuibridge)
> （AGPL-3.0）。**智能体需先装桥并授权「所有文件访问」才可用**，安装步骤见该仓库 README。
>
> 安装智能体本身：见本仓库 [Releases](https://github.com/osagem/photodelaiuiagent/releases)
> （`.aix` 包，经 AIUI Studio 上传 / 真机调试下发）。

## 功能

- **浏览**：语音「下一个 / 上一个」，或镜腿前滑 / 后滑
- **视频**：进入即自动播放并循环；HEVC 源由桥端自动转码为 H.264 后播放（带进度、有缓存、二次播放秒开）
- **删除**：语音「删除」→ 二次确认（语音「确认」/「取消」，或删除确认态下镜腿单击 / 双击取消）
- **退出**：语音「退出」或镜腿双击 → 一次关到底（不残留卡片态）
- **服务门禁页**：启动时若检测不到本机桥服务，显示全屏引导页（含 APK 下载地址），
  服务就绪后自动进入主界面，无需重新唤醒

## 演示视频

<p align="center">
  <video src="docs/agent-demo-01.mp4" poster="docs/agent-demo-01-poster.jpg" controls width="62%"></video>
</p>

70 秒真机实录（眼镜屏幕直录，480×640）：语音唤醒 → 照片浏览 → 视频播放（HEVC 源自动转码）→ 删除与二次确认 → 退出。
若上方播放器未加载，可[直接打开视频文件](docs/agent-demo-01.mp4)（MP4 / 4.1 MB）。

## 目录结构

```
app.json                        智能体元信息（名称、页面、权限、engine 版本）
app.js / app.wxss               应用入口与全局样式（单色绿设计 token）
AGENTS.md                       智能体描述层（OAF 规范文件：身份 / 系统指令 / 能力边界），随包分发
LICENSE                         AGPL-3.0 许可证全文，随包分发
lib/bridge.js                   DCIM 桥 HTTP 客户端（基址发现 / JSON GET / 结果回读）
lib/media-store.js              媒体库状态层（清单 / 游标 / 真实删除）
lib/intent.js                   语音意图路由（命令词典 + 待确认态安全词典）
lib/voice.js                    语音识别与播报封装（免唤醒连续识别 / 四态相位 / 自听防护）
lib/format.js                   时间与文案格式化
pages/index/index.ink           单页智能体全部逻辑与界面（模板 + 脚本 + 样式）
tools/pack-aix.py               打包规范脚本：打包时注入 agentId（不随包分发）
tools/README.md                 打包规范说明（agentId 来源 / 两种模式 / 边界与风险）
docs/agent-demo-01.mp4          演示视频（仓库素材，不随包分发）
docs/agent-demo-01-poster.jpg   演示视频封面帧
```

## 依赖

| 项 | 要求 |
|---|---|
| 运行时 | AIUI Ink `>=0.17.0`（`<video>` 组件自 v0.17.0 起提供） |
| 伴生 App | `com.osagem.photodelaiuibridge`（DCIM 桥），需先安装并授权「所有文件访问」 |
| 通信 | 本机回环 `http://127.0.0.1:38999`（不访问任何外部服务器） |

## 构建与安装

**用打包规范脚本**（推荐）—— 它会从仓库外的真源读 agentId 并注入到包内 `VERSION`，然后复核：

```bash
# 本地安装包（VERSION 注入为 agentId，供归档安装 / 真机联调）
python photodelaiuiagent/tools/pack-aix.py --mode local

# 发布包（默认同样注入；保留随机 VERSION 加 --keep-random-version）
python photodelaiuiagent/tools/pack-aix.py --mode release
```

> 规范全文见 [`tools/README.md`](tools/README.md)。

裸命令等价形式（**不注入 agentId**，包内 `VERSION` 为随机值）：

```bash
# 打包
aix pack ./photodelaiuiagent -o dist/photodelaiuiagent.aix

# 安装到设备（-s 指定序列号）
aix install ./photodelaiuiagent -s <serial>
```

> **为什么 agentId 要走打包注入**：AIUI 两条安装路径的 agentId 来源不同 ——
> 目录安装复用工程 `.aix/agent-id`，归档安装用**包内 `VERSION`**（`aix pack` 生成的随机 UUID）。
> 工程内的 `.aix/agent-id` 存本机智能体 UUID，**不入库**（见 `.gitignore`），
> 它决定安装后的 agentId 稳定性，**请勿删除本地文件**；agentId 的「值」在仓库任何位置都不出现。

## 设计约束（AIUI v0.18 单色绿）

- 显示硬件是**单绿透明面板**，只有一个绿色通道 → 界面只用 `#40ff5e` 一个色相，
  层级靠亮度档（100 / 72 / 48 / 24 / 12 / 6%）、线宽与留白表达。
- 画布 **480×352**，安全内边距 16px（横）/ 12px（纵）。
- 语义状态**冗余编码**（文字标签 + 线型），颜色不单独承担语义。

## 许可证 License

本项目以 **GNU Affero General Public License v3.0（AGPL-3.0）** 发布，与伴生 DCIM 桥
[photodelaiuibridge](https://github.com/osagem/photodelaiuibridge) 采用同一协议。

- 许可证全文：[LICENSE](LICENSE)
- 官方页面：https://www.gnu.org/licenses/agpl-3.0.html
- 中文参考译文：https://www.gnu.org/licenses/agpl-3.0.zh-cn.html

> AGPL-3.0 是强著佐权（copyleft）许可：分发本软件、分发其修改版，或以网络服务形式向用户提供本软件时，
> 都必须以 AGPL-3.0 开放相应源代码。若需在闭源项目中使用，请先联系作者获取另行授权。

除 `app.json`（JSON 格式不支持注释）外，所有源码文件头部均带 AGPL-3.0 版权与免责声明，
并标注 `SPDX-License-Identifier: AGPL-3.0-only`。

> **发布包（`.aix`）内含文件**：`AGENTS.md`（智能体描述层，AIUI OAF 规范要求）、
> `LICENSE`（AGPL-3.0 全文，分发时随附）、`app.json` / `app.js` / `app.wxss`、
> `lib/*`、`pages/index/index.ink`，以及打包器自动生成的 `VERSION` 与 `META-INF/aix/manifest.json`。
> `README.md` / `docs/`（演示视频）/ `.gitignore` / `.gitattributes` / `.aixignore` / `.aix/`（本机 agentId）/
> `tools/`（打包脚本）/ `.git/` 属仓库与构建元文件，已由 `.aixignore` 排除，不随安装包分发。

**License:** AGPL-3.0 — see [LICENSE](LICENSE).
