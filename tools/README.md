# 打包与自检规范

> 适用工程：本目录的上一级（`photodelaiuiagent/`）。
> 工具：`tools/pack-aix.py`。
> **约定（单一模式）：包内 `VERSION` 由 `aix pack` 随机生成，打包流程不注入任何 agentId。**
> agentId 的「值」不入库，也不写死在源码与文档里。

---

## 1. 为什么是"随机"就够了（官方依据）

AIUI 有**多条安装路径**，agentId 的来源不同：

| 安装方式 | agentId 来源 | 设备落点 |
|:--|:--|:--|
| `aix install <工程目录>` | **工程 `.aix/agent-id`** | `develop.rokid.agent.<该值>.aix` |
| `aix install <包.aix>` | **包内 `VERSION`**（打包器随机 UUID） | `develop.rokid.agent.<该值>.aix` |
| 网页端 AIUI Studio 发布 | **云端系统生成** | 由手机「更新眼镜资源包」下发 |

【文档】`documentation/7-tools/cli.md` § `aix install`：

> 目录安装会复用 `.aix/agent-id`，归档安装会使用包内 `VERSION`。
> `--definition` 可用自己的 Agent Definition JSON 覆盖生成的元数据，**但不能覆盖 `agentId`**。

【文档】`documentation/0-guide/bundle/aix.md`：

> 每个 AIX 包在打包时都会自动生成一个唯一的 UUID `VERSION` 文件，用于版本校验和热更新。

`aix pack` **没有** agentId 选项（只有 `-o/-O/--opt-level/--engine/--log-time`）。因此本规范**不干预**
`VERSION`：跑一次 `aix pack` 得到一个随机 UUID，它就是该包归档安装时的 agentId，**自洽、可预期、无需改写**。

> **为什么不改写 `VERSION`（历史方案已弃用）**：改写 `VERSION` 会让包与
> `META-INF/aix/manifest.json` **不自洽** —— 其中的 `package_id` 是打包器对整包内容算的摘要，
> 算法未公开（试过 6 种 sha256 组合均不命中），**无法重算**。虽然实测离线命令
> （`aix show` / `list` / `preview`）不校验、照常工作，但真机 `aix install <包>` 是否校验一直未知。
> 取消注入后这条风险**自然消失**，包与 manifest 始终由打包器一次生成、完全一致。

---

## 2. 真源在哪 / 什么不入库

| | 位置 | 入库？ |
|:--|:--|:--|
| 本机身份（目录安装用） | `photodelaiuiagent/.aix/agent-id` | ❌ `.gitignore` 已排除 |
| 云端身份（Studio 发布用） | `aiui.rokid.com` 平台页面 | — |
| 规范本身 | `tools/pack-aix.py` + 本文件 | ✅ 入库（**不含 id 值**） |

`.aix/agent-id` 是**本机身份文件**：`aix install <目录>` 直接读它，**删掉会让下次装机生成新 agentId**。
仓库源码、文档、README 都只描述来源，不写值。

---

## 3. 用法

```bash
PY=python                                  # 需 Python 3.9+（仅用标准库）

$PY tools/pack-aix.py                      # → dist/photodelaiuiagent.aix
$PY tools/pack-aix.py -o dist/x.aix        # 自定义输出
$PY tools/pack-aix.py --optimize           # 透传 `aix pack -O`
$PY tools/pack-aix.py --dry-run            # 只跑流程与复核，不落盘
```

输出示例：

```
═══ AIX 打包 + 自检 ═══
  工程      …/photodelaiuiagent
  输出      dist/photodelaiuiagent.aix
  模式      单一模式：包内 VERSION 由 aix pack 随机生成（不注入 agentId）
  ✔ aix pack 完成（69,210 B）
  ✔ 包内 VERSION = <随机 UUID>
  ✔ aix show agentId = develop.rokid.agent.<随机 UUID>
  ✔ aix preview 编译校验 = 通过
  ✔ 条目 13 个（预期 13 个）
  ✔ 无仓库/本机文件混入
  ✔ 产物 dist/photodelaiuiagent.aix  … B   sha256 …
  · 提示：归档安装的 agentId = 上面的 VERSION；目录安装复用 .aix/agent-id = …（两者不同身份）
```

退出码：**0 = 全部复核通过**（UUID 合法、agentId 一致、编译通过、条目数正确、无元文件混入）。

---

## 4. 脚本做了哪五件事

1. `aix pack` 到**临时路径**（先复核，后落盘）；
2. 复核不变式：包内 `VERSION` 是合法 UUID，且 `aix show` 报出的 `agentId` == `develop.rokid.agent.<VERSION>`；
3. `aix preview` 离线编译校验（.ink 模板语法）；
4. 条目体检：**数量是否为 13**、是否混入 `docs/` `tools/` `.git/` `.aix/` 或仓库元文件；
5. 打印产物大小与 `sha256`，并提示"目录安装 / 归档安装是两种身份"。

> `.aixignore` 已排除 `.git`、`README.md`、`.gitignore`、`.gitattributes`、`tools/`、`docs/`
> （`LICENSE` **不排除** —— AGPL-3.0 要求随包分发）。
> 在工程内新增任何目录后，脚本第 4 步会替你发现"多出来的条目"。

---

## 5. 边界与风险

1. **不要随手 `aix install <包>`。** 传包会按包内 `VERSION` 生成一条**新的** agentId，
   设备上会堆同名副本（历史上曾累积 5 条）。日常装机一律 `aix install <工程目录>`；
   传包只用于分发/归档，且明知其身份 = 包内 `VERSION`。
2. **`VERSION` 兼作"版本校验 / 热更新"标识。** 每次打包都是新随机值 → 天然唯一，
   不存在"两次构建无法区分"的问题；反过来，**同一次构建的产物要复用**（别再重打一次当同一版）。
3. **云端 agentId 独立生成**（提审字段说明「Agent ID 系统生成，妥善保留」）。
   仓库源码与包都**无法预定**它 —— 本规范也不再尝试干预，发布走 Studio 上传，
   设备侧身份以云端下发为准。
4. **本地身份与云端身份可以不同**：这是预期现象（前者管 ADB 目录安装，后者管云端下发）。

---

## 6. 待验证清单（真机）

- [ ] `aix install <包>` 装完 `aix device` 显示的 agentId 是否 == 包内 `VERSION`
- [x] 上传 Studio 后页面显示的 **Agent ID** 是否 == 包内 `VERSION` → **否（实测 2026-10-16）**
- [ ] 同一 `VERSION` 的包重复执行手机端「更新眼镜资源包」，是否被判为「无更新」

---

## 7. 命令速查

```bash
# 打包 + 自检（唯一入口）
python photodelaiuiagent/tools/pack-aix.py

# 只复核不落盘
python photodelaiuiagent/tools/pack-aix.py --dry-run

# 手工核对任意包的 agentId（与 install 同一套解析）
aix show <path>.aix | grep agentId
unzip -p <path>.aix VERSION
```
