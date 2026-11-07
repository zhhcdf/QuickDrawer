# -*- coding: utf-8 -*-
"""修正 net48 下新增的 6 处可空引用警告。

根因：.NET Framework 4.8 的引用程序集不带可空引用类型注解，
string.IsNullOrWhiteSpace / IsNullOrEmpty 上没有 [NotNullWhen(false)]，
编译器的流分析学不到"此处已排除 null"，于是把原本安全的代码报成
CS8602 / CS8604 / CS8601。net10 的 BCL 带这些注解，所以那边 0 警告。

修法：在每个 null 守卫之后的解引用处加 `!` 断言。运行时行为完全不变，
只是把编译器缺的那条信息补上。**不是 NoWarn 掩盖。**
"""
import os

ROOT = r"D:\Documents\DeepSeek\快捷桌面项目"

# (相对路径, 原文, 新文, 说明)
EDITS = [
    (
        r"src\QuickDrawer\IconService.cs",
        "SHGetFileInfo(\n                    path,",
        "SHGetFileInfo(\n                    path!,",
        "IconService:75 守卫后已排除 null",
    ),
    (
        r"src\QuickDrawer\IconService.cs",
        'bool isUnc = path.StartsWith(@"\\\\", StringComparison.Ordinal)',
        'bool isUnc = path!.StartsWith(@"\\\\", StringComparison.Ordinal)',
        "IconService:94 UNC 判断",
    ),
    (
        r"src\QuickDrawer\Selection\SelectionWatcher.cs",
        "if (string.IsNullOrWhiteSpace(text) || text.Trim().Length < 2)",
        "if (string.IsNullOrWhiteSpace(text) || text!.Trim().Length < 2)",
        "SelectionWatcher:161 空判定后解引用",
    ),
    (
        r"src\QuickDrawer\Selection\SelectionCapture.cs",
        "            return copied.Trim();",
        "            return copied!.Trim();",
        "SelectionCapture:195 空判定后解引用",
    ),
    (
        r"src\QuickDrawer\ShortcutStore.cs",
        "                    Target = real\n",
        "                    Target = real!\n",
        "ShortcutStore:290 real 已被 IsNullOrWhiteSpace 排除",
    ),
    (
        r"src\QuickDrawer\DrawerWindow.xaml.cs",
        "           && source.IndexOf(query, StringComparison.OrdinalIgnoreCase) >= 0;",
        "           && source!.IndexOf(query, StringComparison.OrdinalIgnoreCase) >= 0;",
        "DrawerWindow:2947 Contains 空判定后解引用",
    ),
]

for rel, old, new, note in EDITS:
    path = os.path.join(ROOT, rel)
    with open(path, "r", encoding="utf-8") as f:
        src = f.read()
    n = src.count(old)
    assert n == 1, "%s: expected 1 occurrence, found %d" % (rel, n)
    src = src.replace(old, new, 1)
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(src)
    print("PATCHED %-46s %s" % (rel, note))

print("DONE")
