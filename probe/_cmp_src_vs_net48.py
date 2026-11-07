# -*- coding: utf-8 -*-
"""对比主工程与 net48 变体的同名源文件，区分「只差行尾」与「真有内容差异」。"""
import os

SRC = r"D:\Documents\DeepSeek\快捷桌面项目\src\QuickDrawer"
VAR = r"D:\QuickDrawer-net48-src"

FILES = [
    "App.xaml.cs", "AutoStart.cs", "ClipboardService.cs", "ClipboardStore.cs",
    "DrawerWindow.xaml.cs", "DropPosition.cs", "NoteStore.cs",
    "PromptEditorDialog.xaml.cs", "Selection/MouseHook.cs",
    "Selection/ScreenshotOverlay.cs", "Selection/SelectionWatcher.cs",
    "ShortcutStore.cs", "WindowPushOut.cs",
]


def read(p):
    with open(p, "rb") as f:
        return f.read()


for rel in FILES:
    a = os.path.join(SRC, rel.replace("/", os.sep))
    b = os.path.join(VAR, rel.replace("/", os.sep))
    ra, rb = read(a), read(b)
    crlf_a = ra.count(b"\r\n")
    crlf_b = rb.count(b"\r\n")
    # 归一化行尾后比较
    na = ra.replace(b"\r\n", b"\n")
    nb = rb.replace(b"\r\n", b"\n")
    same_after_norm = (na == nb)
    print("%-38s src=%7d CRLF=%-5d | qd48=%7d CRLF=%-5d | %s" % (
        rel, len(ra), crlf_a, len(rb), crlf_b,
        "SAME-after-norm" if same_after_norm else "REAL-DIFF"))
