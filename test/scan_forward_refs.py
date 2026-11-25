#!/usr/bin/env python3
"""Fail if a Lua file calls a `local function` defined below the call site.

Lua reads a file top to bottom, so such a call compiles to a global that is
never set and raises only when that branch runs. It has bitten this driver
four times; the suite catches it only where a test reaches the branch.
"""
import re, sys, io

def scan(path):
    src = io.open(path, encoding="utf-8").read().split("\n")
    defs, forward = {}, set()
    for i, line in enumerate(src, 1):
        m = re.match(r"\s*local function ([A-Za-z_]\w*)", line)
        if m and m.group(1) not in defs:
            defs[m.group(1)] = i
        m2 = re.match(r"\s*local ([A-Za-z_]\w*)\s*$", line)
        if m2:
            forward.add(m2.group(1))
    bad = []
    for i, line in enumerate(src, 1):
        code = line.split("--")[0]
        for name, defline in defs.items():
            if name in forward or i >= defline:
                continue
            if re.search(r"(?<![\w.:])" + name + r"\s*\(", code):
                bad.append((i, name, defline, line.strip()[:70]))
    return sorted(bad)

fails = 0
for path in sys.argv[1:]:
    for i, name, d, text in scan(path):
        fails += 1
        print(f"{path}:{i}: calls '{name}', a local defined at line {d}")
        print(f"    {text}")
        print(f"    fix: move the definition above the call, or add "
              f"'local {name}' before it")
if fails:
    print(f"\n{fails} forward reference(s)")
    sys.exit(1)
print("no forward references in " + ", ".join(sys.argv[1:]))
