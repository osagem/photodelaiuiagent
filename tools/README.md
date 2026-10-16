# 打包规范 · agentId 注入

> 适用工程：本目录的上一级（`photodelaiuiagent/`）。
> 工具：`tools/pack-aix.py`。规范目标：**agentId 的「值」不入库，但每个包都带正确的 agentId。**

---

## 1. 为什么需要这条规范（官方依据）

AIUI 有**两条安装路径**，agentId 的来源不同：

| 安装方式 | agentId 来源 | 设备落点 |
|:--|:--|:--|
| `aix install <工程目录>` | **工程 `.aix/agent-id`** | `develop.rokid.agent.<该值>.aix` |
| `aix install <包.aix>` | **包内 `VERSION`** | `develop.rokid.agent.<该值>.aix` |
| 网页端 Studio 发布 | **云端系统生成** | 由手机「更新眼镜资源包」下发 |

【文档】`documentation/7-tools/cli.md` § `aix install`：

> 目录安装会复用 `.aix/agent-id`，归档安装会使用包内 `VERSION`。
> `--definition` 可用自己的 Agent Definition JSON 覆盖生成的元数据，**但不能覆盖 `agentId`**。

【文档】`documentation/0-guide/bundle/aix.md`：

> 每个 AIX 包在打包时都会自动生成一个唯一的 UUID `VERSION` 文件，用于版本校验和热更新。

`aix pack` **没有** agentId 选项（只有 `-o/-O/--opt-level/--engine/--log-time`）。于是：

* 想控制**目录安装**的 agentId → 打包前写好 `.aix/agent-id`
* 想控制**归档安装**的 agentId → 打包后改写包内 `VERSION`

`tools/pack-aix.py` 把这两步合成一条命令并复核。

---

## 2. 真源在哪 / 什么不入库

| | 位置 | 入库？ |
|:--|:--|:--|
| **agentId 真源** | `photodelaiuiagent/.aix/agent-id` | ❌ `.gitignore` 已排除 |
| 覆盖入口 | `--agent-id <uuid>`（会写回上表文件） | ❌ |
| 规范本身 | `tools/pack-aix.py` + 本文件 | ✅ 入库（**不含 id 值**） |

仓库里**任何地方都不写 agentId 的值** —— 源码、文档、README 都只描述"从真源读"。
`.aix/agent-id` 是**本机身份文件**：`aix install <目录>` 直接读它，**删掉会让下次装机生成新 agentId**。

---

## 3. 用法

```bash
PY=python                               # 需 Python 3.9+（仅用标准库）

# 本地安装包：VERSION 注入为 agentId（供 ADB 归档安装 / 真机联调）
$PY tools/pack-aix.py --mode local

# 发布包：默认同样注入；若要保留随机 VERSION 加 --keep-random-version
$PY tools/pack-aix.py --mode release
$PY tools/pack-aix.py --mode release --keep-random-version

# 其它
$PY tools/pack-aix.py --mode local --agent-id <uuid>   # 显式指定（同步写回 .aix/agent-id）
$PY tools/pack-aix.py --mode local -o /path/out.aix    # 自定义输出
$PY tools/pack-aix.py --mode local --optimize          # 透传 aix pack -O
$PY tools/pack-aix.py --mode local --dry-run           # 只跑流程复核，不落盘
```

输出示例（模式 local）：

```
═══ AIX 打包规范 · agentId 注入 ═══
  工程      …/photodelaiuiagent
  模式      local
  agentId   xxxxxxxx-…-xxxxxxxxxxxx
  来源      工程外来源 photodelaiuiagent\.aix\agent-id
  输出      …/dist/photodelaiuiagent-local.aix
  注入      是
  · .aix/agent-id 已是目标值，无需改动
  ✔ aix pack 完成（69,208 B）
  ✔ VERSION 改写：<随机> → <agentId>
    manifest 同步：version + entries[VERSION].sha256（已同步）
  ✔ aix show agentId = develop.rokid.agent.<agentId>
    包内 VERSION    = <agentId>
    ✔ 与配置 agentId 一致
  ✔ aix preview 编译校验 = 通过
  ✔ 产物 dist/photodelaiuiagent-local.aix  … B  sha256 …
    条目   13 个（AGENTS.md, LICENSE, META-INF/aix/manifest.json, VERSION …）
```

退出码：**0 = agentId 复核通过且编译通过**，非 0 表示不一致（脚本会打 ✗）。

---

## 4. 两种模式

| 模式 | 输出 | 注入 agentId | 用途 |
|:--|:--|:--|:--|
| `local` | `dist/photodelaiuiagent-local.aix` | ✅ 是 | 归档安装 / 真机联调（让 ADB 装进去的 agentId 与目标一致） |
| `release` | `dist/photodelaiuiagent.aix` | ✅ 是（默认） | 上传 Studio 提审（`--keep-random-version` 可关） |

> **注意**：`tools/` 已加进 `.aixignore`，脚本不会被打进包。
> 若在工程内新增任何目录/文件，打完包请 `unzip -l` 复查一次条目清单。

---

## 5. 边界与风险（★ 动手前先读完）

1. **`manifest.package_id` 无法重算。** 它是打包器对整包内容算的摘要，算法未公开
   （已试 sha256 的 6 种组合均不命中）。改写 `VERSION` 后该字段保持**改写前**的值，
   于是**包与 manifest 并非完全自洽**。已实测：`aix show` / `aix list` / `aix preview` 均**不校验**、照常工作。
   **未知**：真机 `aix install <包>` 是否校验 → 见 §6 待验证第 1 条。
   *（我们已同步了能正确计算的部分：`manifest.version` 与 `entries[VERSION].size/sha256`。）*
2. **`VERSION` 同时是"版本校验 / 热更新"标识。** 注入后同一智能体的所有包 VERSION 恒定 = agentId，
   前后两次构建无法靠 VERSION 区分。**从第二次发布起**建议对 `release` 用 `--keep-random-version`，
   除非你确认云端不依赖它判断新版本。
3. **云端 agentId 由 Studio 系统生成**（提审表字段说明「Agent ID 系统生成，妥善保留」），
   本地 agentId 与云端 agentId 从来不是同一个。**已实测：包内 `VERSION` 与云端分配出的 id 无关**
   （见 §6 第 2 条）⇒ 发布提审前**不必**为了"预定云端 id"去注入 VERSION；
   注入的意义只在**归档安装落点可控**（以及让本地身份与云端身份对齐）。
4. **不要随手 `aix install <包>`。** 传包会按包内 VERSION **另生成一条 agentId**，
   设备上会堆同名副本（历史踩过：一度累积 5 条）。日常装机一律 `aix install <工程目录>`。
   —— 而本规范注入 VERSION 的**唯一目的**，正是让"必须传包"的场景（归档/分发）也落在**预期**的 agentId 上。

---

## 6. 待验证清单（真机，尚未执行）

- [ ] `aix install <注入后的包>` 能否成功；装完 `aix device` 显示的 agentId 是否 == 注入值
- [x] 上传 Studio 后，页面显示的 **Agent ID** 是否 == 包内 `VERSION` → **否（实测 2026-10-16）**。
      上传包内 `VERSION` 与云端回填的 agentId 是两个不同的值 ⇒ **云端 id 独立生成、无法在打包阶段预定**，
      只能等云端回填后再把 id 写回 `.aix/agent-id`（于是"本地身份 = 云端身份"）。
- [ ] 同一 `VERSION` 的包重复执行手机端「更新眼镜资源包」，是否被判为「无更新」

> **实测记录**（不含 id 值）：发布包上传 Studio 后，云端分配的 agentId 与包内 `VERSION` **不同**。
> ⇒ 结论：`release` 模式是否注入 VERSION **不影响**云端分配结果；
> 云端 id 到手后再执行 `python tools/pack-aix.py --mode local --agent-id <云端id>` 完成本地对齐。

---

## 7. 命令速查

```bash
# 日常：本地包（注入）
python photodelaiuiagent/tools/pack-aix.py --mode local

# 提审：发布包（注入）
python photodelaiuiagent/tools/pack-aix.py --mode release

# 只复核不改写
python photodelaiuiagent/tools/pack-aix.py --mode local --keep-random-version --dry-run

# 手工核对任意包的 agentId（与 install 同一套解析）
aix show <path>.aix | grep agentId
unzip -p <path>.aix VERSION
```
