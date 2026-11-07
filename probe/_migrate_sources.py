# -*- coding: utf-8 -*-
"""把主工程 src/QuickDrawer 的 13 个文件迁到 net48 适配版。

策略：不做逐处文本替换（易漏、易错），而是直接取变体里已适配好的同名文件，
覆盖主工程。核对已确认变体在内容上只有 net48 适配，没有落后于主工程。

同时修掉 Compat.cs / FolderPicker.cs 里"仅评估用"这类临时注释。
"""
import os
import shutil

SRC = r"D:\Documents\DeepSeek\快捷桌面项目\src\QuickDrawer"
VAR = r"D:\QuickDrawer-net48-src"

FILES = [
    "App.xaml.cs", "AutoStart.cs", "ClipboardService.cs", "ClipboardStore.cs",
    "DrawerWindow.xaml.cs", "DropPosition.cs", "NoteStore.cs",
    "PromptEditorDialog.xaml.cs", "Selection/MouseHook.cs",
    "Selection/ScreenshotOverlay.cs", "Selection/SelectionWatcher.cs",
    "ShortcutStore.cs", "WindowPushOut.cs",
]

for rel in FILES:
    a = os.path.join(SRC, rel.replace("/", os.sep))
    b = os.path.join(VAR, rel.replace("/", os.sep))
    shutil.copyfile(b, a)
    print("copied %-36s %d bytes" % (rel, os.path.getsize(a)))

print("DONE")
