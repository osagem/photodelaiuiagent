#!/usr/bin/env python3
# Copyright (C) 2026 OSAGEM
#
# This file is part of 照片删除 (Photo Delete), a Rokid Glasses AIUI agent.
# Licensed under the GNU Affero General Public License v3.0 or later.
# SPDX-License-Identifier: AGPL-3.0-only
# See the LICENSE file in the project root, or https://www.gnu.org/licenses/

"""AIX 打包 + 自检（单一模式，不注入任何 agentId）。

约定
----
* 包内 `VERSION` **由 `aix pack` 随机生成**，就是该包归档安装时的 agentId；
* 仓库源码 / 文档 / 本脚本都**不写死 agentId 的值**；
* `aix install <工程目录>` 走另一条路径：复用本机 `.aix/agent-id`（不入库，见 `.gitignore`）。

官方依据（AIUI `documentation/7-tools/cli.md` / `0-guide/bundle/aix.md`）
-----------------------------------------------------------------------
* 目录安装 `aix install <目录>` → 复用工程 `.aix/agent-id`
* 归档安装 `aix install <包>`   → 使用包内 `VERSION`（打包器生成的随机 UUID）
* `aix pack` 没有 agentId 选项；`aix install --definition` 也不能覆盖 agentId
* 云端 agentId 由 Studio 独立生成，**与包内 `VERSION` 无关**（2026-10-16 实测）

本脚本做四件事：打包 → 复核不变式（包内 VERSION == `aix show` 的 agentId 尾段）
→ 离线编译校验（`aix preview`）→ 条目清单体检（防止仓库元文件混进包）。

用法
----
    python tools/pack-aix.py                    # → dist/photodelaiuiagent.aix
    python tools/pack-aix.py -o dist/x.aix      # 自定义输出
    python tools/pack-aix.py --optimize         # 透传 `aix pack -O`
    python tools/pack-aix.py --dry-run          # 只跑流程与复核，不落盘

注意：`aix` CLI 仅在 AI 会话环境可用；本脚本离线运行（不碰设备）。
"""

import argparse
import hashlib
import re
import shutil
import subprocess
import sys
import tempfile
import uuid
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parent                      # photodelaiuiagent/
REPO_ROOT = PROJECT.parent                 # 工作区根
ID_FILE = PROJECT / ".aix" / "agent-id"    # 本机身份（.gitignore 已排除，不入库）
VERSION_ENTRY = "VERSION"

# 包内应当出现的条目（13 项）：内容文件 + 打包器生成的元数据
EXPECTED_ENTRIES = {
    "AGENTS.md",
    "LICENSE",
    "VERSION",
    "META-INF/aix/manifest.json",
    "app.js",
    "app.json",
    "app.wxss",
    "lib/bridge.js",
    "lib/format.js",
    "lib/intent.js",
    "lib/media-store.js",
    "lib/voice.js",
    "pages/index/index.ink",
}

# 绝不允许出现在包内的仓库/本机文件（`.aixignore` 已排除，这里是最后一道闸）
FORBIDDEN_PREFIXES = (".git/", ".aix/", "tools/", "docs/")
FORBIDDEN_NAMES = {".gitignore", ".gitattributes", ".aixignore", "README.md"}


# --------------------------------------------------------------------------- #
# 基础工具
# --------------------------------------------------------------------------- #
def run_aix(args: list[str]) -> subprocess.CompletedProcess:
    exe = shutil.which("aix")
    if not exe:
        sys.exit("✗ PATH 中找不到 `aix`（该 CLI 仅在 AI 会话环境可用）")
    return subprocess.run(
        [exe, *args], cwd=REPO_ROOT, capture_output=True, text=True,
        encoding="utf-8", errors="replace",
    )


def read_zip_entries(path: Path) -> list[tuple[zipfile.ZipInfo, bytes]]:
    with zipfile.ZipFile(path) as z:
        return [(i, z.read(i.filename)) for i in z.infolist()]


def read_packaged_version(pkg: Path) -> str:
    return next((d for i, d in read_zip_entries(pkg) if i.filename == VERSION_ENTRY), b"").decode()


def show_agent_id(pkg: Path) -> str:
    """用 `aix show` 读取该包生效的 agentId（与 install 同一套解析逻辑）。"""
    proc = run_aix(["show", str(pkg)])
    if proc.returncode != 0:
        sys.exit(f"✗ aix show 失败（exit {proc.returncode}）\n{proc.stdout}\n{proc.stderr}")
    m = re.search(r'"agentId"\s*:\s*"([^"]+)"', proc.stdout)
    if not m:
        sys.exit(f"✗ 无法从 aix show 输出解析 agentId\n{proc.stdout[:400]}")
    return m.group(1)


def verify_renderable(pkg: Path) -> bool:
    """离线编译校验（exit 0 = .ink 模板可编译）。"""
    with tempfile.TemporaryDirectory() as td:
        proc = run_aix(["preview", str(pkg), "--html-out", str(Path(td) / "p.html")])
    return proc.returncode == 0


def rel(p: Path) -> str:
    try:
        return str(p.relative_to(REPO_ROOT))
    except ValueError:
        return str(p)


def local_id() -> str | None:
    """本机 `.aix/agent-id`（目录安装用的身份）；不存在返回 None。"""
    if not ID_FILE.is_file():
        return None
    return ID_FILE.read_text(encoding="utf-8").strip()


# --------------------------------------------------------------------------- #
# main
# --------------------------------------------------------------------------- #
def main() -> int:
    ap = argparse.ArgumentParser(description="AIX 打包 + 自检（包内 VERSION 随机生成）")
    ap.add_argument("-o", "--out", help="输出路径（默认 dist/photodelaiuiagent.aix）")
    ap.add_argument("--optimize", action="store_true", help="透传 `aix pack -O`")
    ap.add_argument("--dry-run", action="store_true", help="只跑流程与复核，不落盘")
    a = ap.parse_args()

    out = Path(a.out).resolve() if a.out else (REPO_ROOT / "dist" / "photodelaiuiagent.aix")

    print("═══ AIX 打包 + 自检 ═══")
    print(f"  工程      {PROJECT}")
    print(f"  输出      {rel(out)}")
    print("  模式      单一模式：包内 VERSION 由 aix pack 随机生成（不注入 agentId）")
    if a.dry_run:
        print("  dry-run   → 产物不落盘")

    # ① 打包到临时路径（先复核，后落盘）
    tmpdir = Path(tempfile.mkdtemp(prefix="pack-aix-"))
    packed = tmpdir / "packed.aix"
    argv = ["pack", str(PROJECT), "-o", str(packed)]
    if a.optimize:
        argv += ["-O"]
    proc = run_aix(argv)
    if proc.returncode != 0:
        shutil.rmtree(tmpdir, ignore_errors=True)
        sys.exit(f"✗ aix pack 失败（exit {proc.returncode}）\n{proc.stdout}\n{proc.stderr}")
    print(f"  ✔ aix pack 完成（{packed.stat().st_size:,} B）")

    # ② 复核不变式：包内 VERSION 是合法 UUID，且 == `aix show` 报出的 agentId 尾段
    version = read_packaged_version(packed)
    actual = show_agent_id(packed)
    try:
        uuid.UUID(version)
        uuid_ok = True
    except ValueError:
        uuid_ok = False
    id_ok = actual == f"develop.rokid.agent.{version}"
    print(f"  {'✔' if uuid_ok else '✗'} 包内 VERSION = {version}"
          f"{'' if uuid_ok else '（不是合法 UUID）'}")
    print(f"  {'✔' if id_ok else '✗'} aix show agentId = {actual}")
    if not id_ok:
        print("    ⚠ 包内 VERSION 与 show 报出的 agentId 脱节（异常，需排查）")

    # ③ 离线编译校验
    renderable = verify_renderable(packed)
    print(f"  {'✔' if renderable else '✗'} aix preview 编译校验 = {'通过' if renderable else '失败'}")

    # ④ 条目清单体检：数量 + 是否混入仓库元文件
    names = [i.filename for i, _ in read_zip_entries(packed)]
    leaked = [n for n in names
              if n.startswith(FORBIDDEN_PREFIXES) or n in FORBIDDEN_NAMES]
    count_ok = len(names) == len(EXPECTED_ENTRIES)
    unexpected = sorted(set(names) - EXPECTED_ENTRIES)
    missing = sorted(EXPECTED_ENTRIES - set(names))
    print(f"  {'✔' if count_ok else '✗'} 条目 {len(names)} 个（预期 {len(EXPECTED_ENTRIES)} 个）")
    if missing:
        print(f"    ⚠ 缺少：{', '.join(missing)}")
    if unexpected:
        print(f"    ⚠ 多出：{', '.join(unexpected)}")
    print(f"  {'✔' if not leaked else '✗'} 无仓库/本机文件混入"
          f"{'' if not leaked else '：' + ', '.join(leaked)}")
    if leaked:
        print("    → 请检查 `.aixignore` 是否遗漏了这些路径")

    # ⑤ 落盘 + 摘要
    if not a.dry_run:
        out.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(packed, out)
        digest = hashlib.sha256(out.read_bytes()).hexdigest()
        print(f"  ✔ 产物 {rel(out)}  {out.stat().st_size:,} B")
        print(f"    sha256 {digest}")

    # ⑥ 身份提示（非致命）：目录安装与归档安装的 agentId 来源不同
    lid = local_id()
    if lid and lid != version:
        print(f"  · 提示：归档安装（`aix install <包>`）的 agentId = 上面的 VERSION；")
        print(f"    目录安装（`aix install <工程目录>`）复用 .aix/agent-id = {lid[:8]}…（两者不同身份）")

    shutil.rmtree(tmpdir, ignore_errors=True)
    return 0 if (uuid_ok and id_ok and renderable and count_ok and not leaked) else 1


if __name__ == "__main__":
    raise SystemExit(main())
