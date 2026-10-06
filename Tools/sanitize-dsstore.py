#!/usr/bin/env python3
"""清除 .DS_Store 里遗留的构建机路径。

为什么需要：Finder 会把卷的别名信息写进 .DS_Store，其中包含**构建机上的
绝对路径**，形如：

    /Volumes/<盘名>/<用户名>/Documents/<...>/build/<中间镜像>.dmg
    g/:Volumes:<盘名>:<用户名>:Documents:<...>
    S/<用户名>/Documents/<...>

这会暴露构建者的用户名和目录结构，必须在上传前抹掉。
（本工具自己的文档里也不写具体路径 —— 那本身就是一次泄露。）

做法是**等长替换**：只把命中的子串换成同样长度的占位字符（ASCII 用 'x'，
UTF-16BE 用宽字符 'x'），其它字节一律不动 —— 这样二进制格式里的长度前缀
保持完好，文件的其余部分不受影响。

背景图的那条别名用的是**卷内相对路径**（`.background:background.png`），
不在这里的替换范围内，所以清理后背景图仍然有效。

用法： python3 Tools/sanitize-dsstore.py <文件> [额外要抹掉的子串...]
"""
import os
import sys


def scrub(path, secrets):
    data = bytearray(open(path, "rb").read())
    hits = {}
    for s in secrets:
        if not s:
            continue
        for enc, filler in (("ascii", b"x"), ("utf-16-be", "x".encode("utf-16-be"))):
            try:
                needle = s.encode(enc)
            except UnicodeEncodeError:
                continue
            if len(needle) < 3:
                continue
            # 关键：按**字符数**算填充。按字节长度算的话，UTF-16BE
            # 每字符 2 字节就会多插一倍，文件体积随之变化，
            # 长度前缀错位、整个文件损坏。
            repl = filler * (len(needle) // len(filler))
            n, start = 0, 0
            while True:
                i = data.find(needle, start)
                if i < 0:
                    break
                data[i:i + len(needle)] = repl
                n += 1
                start = i + len(needle)
            if n:
                hits[f"{s} [{enc}]"] = n
    open(path, "wb").write(data)
    return hits


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    path = sys.argv[1]
    extra = sys.argv[2:]

    home = os.path.expanduser("~")
    # 依次是：主目录全路径、路径各段，以及「主目录→本仓库」之间那几段
    # （Documents / deepseek-harness / default-workspace 之类）。
    # 仓库目录名本身不清 —— 那个是公开的项目名。
    secrets = [home]
    skip = {"Volumes", "Users", "home"}
    secrets += [p for p in home.strip("/").split("/") if p and p not in skip]

    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    try:
        rel = os.path.relpath(repo, home)
    except ValueError:
        rel = ""
    if rel and not rel.startswith(".."):
        mid = rel.split(os.sep)[:-1]          # 去掉最后的项目名
        secrets += [p for p in mid if len(p) >= 3]
        secrets.append(rel)

    secrets += extra

    if not os.path.exists(path):
        print(f"❌ 找不到 {path}")
        return 1

    before = os.path.getsize(path)
    hits = scrub(path, secrets)
    after = os.path.getsize(path)
    print(f"  体积: {before} → {after} 字节"
          + ("  ✅ 等长替换，结构未变" if before == after
             else "  ❌ 体积变了！二进制结构可能已损坏"))
    if hits:
        for k, v in sorted(hits.items()):
            print(f"    ✅ 抹掉 {k} × {v}")
    else:
        print("    （没有命中，文件本来就干净）")

    # 复查：确认敏感串真的没了
    data = open(path, "rb").read()
    left = [s for s in secrets
            if s and (s.encode() in data or s.encode("utf-16-be") in data)]
    if left:
        print(f"    ❌ 仍残留: {left}")
        return 1
    print("    ✅ 复查通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
