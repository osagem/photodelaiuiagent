#!/usr/bin/env python3
# Copyright (C) 2026 OSAGEM
#
# This file is part of 照片删除 (Photo Delete), a Rokid Glasses AIUI agent.
# Licensed under the GNU Affero General Public License v3.0 or later.
# SPDX-License-Identifier: AGPL-3.0-only
# See the LICENSE file in the project root, or https://www.gnu.org/licenses/

"""AIX 打包规范 —— 打包时注入 agentId（agentId 的「值」不入库）。

规范依据（AIUI 官方文档 `7-tools/cli.md` / `0-guide/bundle/aix.md`）
------------------------------------------------------------------
* 目录安装 `aix install <目录>` → **复用工程 `.aix/agent-id`**
* 归档安装 `aix install <包>`   → **使用包内 `VERSION`**
* `aix pack` **没有** agentId 选项：打包时自动生成随机 UUID 写入 `VERSION`
* `aix install --definition` 可覆盖元数据，但**不能覆盖 agentId**

于是"让两个安装路径都落在同一个 agentId"的办法只有两条：
1. 打包前写好 `.aix/agent-id`（管**目录安装**）
2. 打包后改写包内 `VERSION`（管**归档安装**）

本脚本把两步合成一条命令，并做复核。agentId 的**值**只从仓库外的来源读取
（默认 `.aix/agent-id`，已被 `.gitignore` 排除），源码与文档里不写死。

用法
----
    python tools/pack-aix.py --mode local        # 本地安装包（VERSION = agentId）
    python tools/pack-aix.py --mode release      # 发布包（默认同样注入，见 --keep-random-version）
    python tools/pack-aix.py --mode release --keep-random-version

    --agent-id <uuid>     显式指定（会同步写回 .aix/agent-id）
    -o, --out <path>      自定义输出路径
    --optimize            透传 `aix pack -O`
    --keep-random-version 归档 VERSION 保持 aix pack 生成的随机值（不注入）
    --dry-run             只跑流程与复核，不写任何产物

注意：`aix` CLI 仅在 AI 会话环境可用；本脚本离线运行（不碰设备）。
"""

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
import uuid
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parent                      # photodelaiuiagent/
REPO_ROOT = PROJECT.parent                 # 工作区根
ID_FILE = PROJECT / ".aix" / "agent-id"    # 仓库外来源（.gitignore 已排除）
VERSION_ENTRY = "VERSION"
MANIFEST_ENTRY = "META-INF/aix/manifest.json"


# --------------------------------------------------------------------------- #
# agentId 来源
# --------------------------------------------------------------------------- #
def read_id_file() -> str | None:
    """读 `.aix/agent-id`（可能不存在）。"""
    if not ID_FILE.is_file():
        return None
    return ID_FILE.read_text(encoding="utf-8").strip()


def is_uuid(text: str) -> bool:
    try:
        uuid.UUID(text)
        return True
    except (ValueError, AttributeError, TypeError):
        return False


def resolve_agent_id(cli_value: str | None) -> tuple[str, str]:
    """返回 (agentId, 来源说明)。优先级：命令行 > .aix/agent-id。"""
    if cli_value:
        if not is_uuid(cli_value):
            sys.exit(f"✗ --agent-id 不是合法 UUID：{cli_value!r}")
        return cli_value.lower(), "命令行 --agent-id"
    stored = read_id_file()
    if not stored:
        sys.exit(
            f"✗ 找不到 agentId：{ID_FILE} 不存在，且未传 --agent-id。\n"
            "  该文件属本机身份、不入库；首次使用请先用 --agent-id 指定一次。"
        )
    if not is_uuid(stored):
        sys.exit(f"✗ {ID_FILE} 内容不是合法 UUID：{stored!r}")
    return stored.lower(), f"工程外来源 {ID_FILE.relative_to(REPO_ROOT)}"


def persist_agent_id(agent_id: str, current: str | None) -> bool:
    """把 agentId 写回 `.aix/agent-id`（目录安装依赖它）。返回是否发生改动。"""
    if current == agent_id:
        return False
    ID_FILE.parent.mkdir(parents=True, exist_ok=True)
    ID_FILE.write_text(agent_id + "\n", encoding="utf-8")
    return True


# --------------------------------------------------------------------------- #
# 打包与改写
# --------------------------------------------------------------------------- #
def run_aix(args: list[str]) -> subprocess.CompletedProcess:
    exe = shutil.which("aix")
    if not exe:
        sys.exit("✗ PATH 中找不到 `aix`（该 CLI 仅在 AI 会话环境可用）")
    return subprocess.run(
        [exe, *args], cwd=REPO_ROOT, capture_output=True, text=True, encoding="utf-8", errors="replace"
    )


def pack(project: Path, out: Path, optimize: bool) -> None:
    out.parent.mkdir(parents=True, exist_ok=True)
    argv = ["pack", str(project), "-o", str(out)]
    if optimize:
        argv += ["-O"]
    proc = run_aix(argv)
    if proc.returncode != 0:
        sys.exit(f"✗ aix pack 失败（exit {proc.returncode}）\n{proc.stdout}\n{proc.stderr}")


def read_zip_entries(path: Path) -> list[tuple[zipfile.ZipInfo, bytes]]:
    with zipfile.ZipFile(path) as z:
        return [(i, z.read(i.filename)) for i in z.infolist()]


def stamp(src: Path, dst: Path, agent_id: str, sync_manifest: bool = True) -> dict:
    """把包内 VERSION 改写为 agentId；可选同步 manifest 中可计算的部分。

    ★ `manifest.package_id` 是打包器对整包内容算的摘要，算法未公开
      （已试 sha256 的 6 种组合均不命中）→ **无法重算**，保持原值。
      因此改写后的包与 manifest 并非完全自洽：离线命令（show/list/preview）
      不校验，真机 `aix install <包>` 是否校验**尚未验证**（见规范文档）。
    """
    entries = read_zip_entries(src)
    # ★ 先取 src 的 zip comment：src == dst 时就地改写时，dst 一旦以 "w" 打开即被截断
    with zipfile.ZipFile(src) as _z:
        src_comment = _z.comment
    version_before = next((d for i, d in entries if i.filename == VERSION_ENTRY), b"").decode()

    new_version = agent_id.encode()
    out: list[tuple[zipfile.ZipInfo, bytes]] = []
    for info, data in entries:
        if info.filename == VERSION_ENTRY:
            data = new_version
        elif info.filename == MANIFEST_ENTRY and sync_manifest:
            m = json.loads(data.decode())
            m["version"] = agent_id
            for e in m.get("entries", []):
                if e.get("path") == VERSION_ENTRY:
                    e["sha256"] = hashlib.sha256(new_version).hexdigest()
                    e["size"] = len(new_version)
            data = json.dumps(m, separators=(",", ":"), ensure_ascii=False).encode()
        out.append((info, data))

    dst.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(dst, "w") as zout:
        zout.comment = src_comment
        for info, data in out:
            zi = zipfile.ZipInfo(info.filename, date_time=info.date_time)
            zi.compress_type = info.compress_type
            zi.external_attr = info.external_attr
            zi.create_system = info.create_system
            zout.writestr(zi, data)

    return {"version_before": version_before, "sync_manifest": sync_manifest}


def show_agent_id(pkg: Path) -> str:
    """用 `aix show` 复核包内生效的 agentId（与 install 同一套解析逻辑）。"""
    proc = run_aix(["show", str(pkg)])
    if proc.returncode != 0:
        sys.exit(f"✗ aix show 失败（exit {proc.returncode}）\n{proc.stdout}\n{proc.stderr}")
    m = re.search(r'"agentId"\s*:\s*"([^"]+)"', proc.stdout)
    if not m:
        sys.exit(f"✗ 无法从 aix show 输出解析 agentId\n{proc.stdout[:400]}")
    return m.group(1)


def read_packaged_version(pkg: Path) -> str:
    return next((d for i, d in read_zip_entries(pkg) if i.filename == VERSION_ENTRY), b"").decode()


def rel(p: Path) -> str:
    """尽量显示为仓库相对路径（越界时原样返回）。"""
    try:
        return str(p.relative_to(REPO_ROOT))
    except ValueError:
        return str(p)


def verify_renderable(pkg: Path) -> bool:
    """离线编译校验（exit 0 = .ink 模板可编译）。"""
    import tempfile

    with tempfile.TemporaryDirectory() as td:
        proc = run_aix(["preview", str(pkg), "--html-out", str(Path(td) / "p.html")])
    return proc.returncode == 0


# --------------------------------------------------------------------------- #
# main
# --------------------------------------------------------------------------- #
def main() -> int:
    ap = argparse.ArgumentParser(description="AIX 打包规范：打包时注入 agentId")
    ap.add_argument("--mode", choices=["local", "release"], required=True,
                    help="local=本地安装包（VERSION 注入）；release=发布包")
    ap.add_argument("--agent-id", help="显式指定 agentId（会写回 .aix/agent-id）")
    ap.add_argument("-o", "--out", help="自定义输出路径")
    ap.add_argument("--optimize", action="store_true", help="透传 aix pack -O")
    ap.add_argument("--keep-random-version", action="store_true",
                    help="不注入 agentId，保留 aix pack 生成的随机 VERSION")
    ap.add_argument("--dry-run", action="store_true", help="只跑流程与复核，不写产物")
    a = ap.parse_args()

    current = read_id_file()
    agent_id, source = resolve_agent_id(a.agent_id)
    default_name = "photodelaiuiagent-local.aix" if a.mode == "local" else "photodelaiuiagent.aix"
    out = Path(a.out).resolve() if a.out else (REPO_ROOT / "dist" / default_name)
    stamp_it = not a.keep_random_version

    print("═══ AIX 打包规范 · agentId 注入 ═══")
    print(f"  工程      {PROJECT}")
    print(f"  模式      {a.mode}")
    print(f"  agentId   {agent_id}")
    print(f"  来源      {source}")
    print(f"  输出      {out}")
    print(f"  注入      {'否（保留随机 VERSION）' if not stamp_it else '是'}")

    if a.dry_run:
        print("  dry-run   → 改写与复核将写入临时路径，产物不落盘")

    # ① 同步 .aix/agent-id（目录安装依赖）
    if not a.dry_run:
        if persist_agent_id(agent_id, current):
            print(f"  ✔ 已同步 {ID_FILE.relative_to(REPO_ROOT)}（目录安装路径对齐）")
        else:
            print(f"  · {ID_FILE.relative_to(REPO_ROOT)} 已是目标值，无需改动")

    # ② 打包
    import tempfile

    tmpdir = Path(tempfile.mkdtemp(prefix="pack-aix-"))
    packed = tmpdir / "packed.aix"
    pack(PROJECT, packed, a.optimize)
    print(f"  ✔ aix pack 完成（{packed.stat().st_size:,} B）")

    # ③ 注入
    info = None
    final_pkg = out if (stamp_it and not a.dry_run) else packed
    if stamp_it:
        target = packed if a.dry_run else out
        info = stamp(packed, target, agent_id)
        final_pkg = target
        print(f"  ✔ VERSION 改写：{info['version_before']} → {agent_id}")
        print(f"    manifest 同步：version + entries[VERSION].sha256"
              f"{'（已同步）' if info['sync_manifest'] else '（未同步）'}")
    else:
        if not a.dry_run:
            shutil.copy2(packed, out)
        print(f"  · VERSION 保持随机：{read_packaged_version(packed)}（未注入 agentId）")

    # ④ 复核：不变式 = 包内 VERSION == aix show 报出的 agentId 尾段
    actual = show_agent_id(final_pkg)
    packaged_version = read_packaged_version(final_pkg)
    ok_id = actual == f"develop.rokid.agent.{packaged_version}"
    print(f"  {'✔' if ok_id else '✗'} aix show agentId = {actual}")
    print(f"    包内 VERSION    = {packaged_version}")
    if not ok_id:
        print("    ⚠ 不一致：包内 VERSION 与 show 报出的 agentId 脱节")
    aligned = packaged_version == agent_id
    print(f"    {'✔' if aligned else '·'} 与配置 agentId {'一致' if aligned else '不一致（保留随机 VERSION 模式）'}")
    renderable = verify_renderable(final_pkg)
    print(f"  {'✔' if renderable else '✗'} aix preview 编译校验 = {'通过' if renderable else '失败'}")

    if not a.dry_run:
        digest = hashlib.sha256(out.read_bytes()).hexdigest()
        names = [i.filename for i, _ in read_zip_entries(out)]
        print(f"  ✔ 产物 {rel(out)}  {out.stat().st_size:,} B")
        print(f"    sha256 {digest}")
        print(f"    条目   {len(names)} 个（{', '.join(names[:4])} …）")
        if stamp_it:
            print("    ⚠ manifest.package_id 无法重算（打包器摘要算法未公开）→ 保持原值；")
            print("      真机 `aix install <包>` 是否校验该字段**待验证**（见规范文档 §边界）。")

    shutil.rmtree(tmpdir, ignore_errors=True)
    return 0 if (ok_id and renderable) else 1


if __name__ == "__main__":
    raise SystemExit(main())
