# -*- coding: utf-8 -*-
"""单组复验：只跑一次，逐步打印每阶段状态。"""
import os
import subprocess
import time

LOG = os.path.join(os.environ["APPDATA"], "QuickDrawer", "logs", "diag.log")


def ps(cmd):
    p = subprocess.run(["powershell", "-NoProfile", "-Command", cmd],
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    return (p.stdout or "").strip()


def logsize():
    try:
        return os.path.getsize(LOG)
    except Exception:
        return -1


def clean():
    ps("Get-Process QuickDrawer,msedgewebview2 -ErrorAction SilentlyContinue | Stop-Process -Force")
    for _ in range(30):
        if ps("(Get-Process QuickDrawer,msedgewebview2 -ErrorAction SilentlyContinue | Measure-Object).Count") == "0":
            return True
        time.sleep(0.5)
    return False


def wv():
    n = ps("(Get-Process msedgewebview2 -ErrorAction SilentlyContinue | Measure-Object).Count")
    return int(n) if n.isdigit() else -1


def sel():
    return ps(
        "Add-Type -AssemblyName UIAutomationClient;"
        "Add-Type -AssemblyName UIAutomationTypes;"
        "$root=[System.Windows.Automation.AutomationElement]::RootElement;"
        "$c=New-Object System.Windows.Automation.PropertyCondition("
        "[System.Windows.Automation.AutomationElement]::NameProperty,'TabAssistant');"
        "$e=$root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,$c);"
        "if($e -eq $null){'NOTFOUND'}else{"
        "$p=$e.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern);"
        "$p.Select();'SELECTED'}"
    )


def run(label, exe, cwd=None):
    print("----", label)
    if not clean():
        print("  clean TIMEOUT")
        return
    s0 = logsize()
    args = "@{ CommandLine = '%s'" % exe
    if cwd:
        args += "; CurrentDirectory = '%s'" % cwd
    args += " }"
    out = ps("Invoke-CimMethod -ClassName Win32_Process -MethodName Create "
             "-Arguments %s | Select-Object -ExpandProperty ReturnValue" % args)
    print("  cim return   :", out)
    time.sleep(8)
    print("  process      :", ps("(Get-Process QuickDrawer -ErrorAction SilentlyContinue | Measure-Object).Count"))
    print("  log delta    :", logsize() - s0)
    print("  select       :", sel())
    time.sleep(12)
    print("  wv2          :", wv())
    print("  log delta2   :", logsize() - s0)


OUT = r"D:\QuickDrawer-publish-net48\QuickDrawer.exe"
IN = r"D:\Documents\DeepSeek\快捷桌面项目\publish\QuickDrawer.exe"

run("in-exe (workspace publish)", IN)
run("out-exe (baseline again)", OUT)
clean()
print("done")
