#!/usr/bin/env python3
"""检查本地化覆盖率：源码里用到的每条文案是否都有中英译文，以及有没有死条目。

用法： python3 Tools/check-localization.py
"""
import re, os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CJK = re.compile(r'[\u4e00-\u9fff]')
LIT = re.compile(r'"((?:[^"\\\n]|\\.)*)"')


def strip_interp(s):
    """把 \\( ... ) 按括号配对整体替换成 %d（含闭包里的括号）"""
    out, i = [], 0
    while i < len(s):
        if s[i] == '\\' and i + 1 < len(s) and s[i + 1] == '(':
            depth, j = 1, i + 2
            while j < len(s) and depth:
                if s[j] == '(':
                    depth += 1
                elif s[j] == ')':
                    depth -= 1
                j += 1
            out.append('%d')
            i = j
        else:
            out.append(s[i])
            i += 1
    return "".join(out)


def parse_strings(path):
    d = {}
    for line in open(path, encoding='utf-8'):
        line = line.strip()
        if not line or line.startswith('/*') or line.startswith('//'):
            continue
        m = re.match(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', line)
        if m:
            d[m.group(1).replace('\\"', '"')] = m.group(2)
    return d


def main():
    en = parse_strings(os.path.join(ROOT, 'Resources/en.lproj/Localizable.strings'))
    zh = parse_strings(os.path.join(ROOT, 'Resources/zh-Hans.lproj/Localizable.strings'))

    used = set()
    src = os.path.join(ROOT, 'Sources')
    for fn in sorted(os.listdir(src)):
        if not fn.endswith('.swift'):
            continue
        for line in open(os.path.join(src, fn), encoding='utf-8'):
            if line.strip().startswith('//'):
                continue
            for m in LIT.finditer(line.split('//')[0]):
                s = m.group(1)
                fmt = strip_interp(s)
                if CJK.search(s) or fmt in en:
                    used.add(fmt)

    missing_en = sorted(k for k in used if k not in en)
    missing_zh = sorted(k for k in used if k not in zh)
    unused = sorted(k for k in en if k not in used)
    leftover = [k for k, v in en.items() if CJK.search(v)]

    print(f"源码文案 {len(used)} 条 / en 表 {len(en)} 条 / zh 表 {len(zh)} 条")
    ok = True
    for label, bad in (("缺英文译文", missing_en), ("缺中文条目", missing_zh),
                       ("未被引用的死条目", unused), ("英文译文里残留中文", leftover)):
        print(f"  {label}: {len(bad)}" + ("" if not bad else "  " + str(bad)))
        if bad:
            ok = False
    if set(en) != set(zh):
        print(f"  ❌ zh/en 键集合不一致: {set(en) ^ set(zh)}")
        ok = False
    else:
        print("  zh/en 键集合一致 ✅")
    print("✅ 全部通过" if ok else "❌ 存在问题")
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
