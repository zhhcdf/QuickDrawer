# -*- coding: utf-8 -*-
"""分离变量：exe 位置 vs 进程工作目录（cwd）。

四组交叉，每次清干净。
"""
import subprocess
import time


def ps(cmd):
    p = subprocess.run(["powershell", "-NoProfile", "-Command", cmd],
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    return (p.stdout or "").strip()


def clean():
    ps("Get-Process QuickDrawer,msedgewebview2 -ErrorAction SilentlyContinue | Stop-Process -Force")
    for _ in range(30):
        if ps("(Get-Process QuickDrawer,msedgewebview2 -ErrorAction SilentlyContinue | Measure-Object).Count") == "0":
            return True
        time.sleep(0.5)
    return False


def wv():
    n = ps("(Get-Process msedgewebview2 -ErrorAction SilentlyContinue | Measure-Object).Count")
    try:
        return int(n)
    except Exception:
        return -1


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


def run(label, exe, cwd):
    if not clean():
        print("%-34s !! clean timeout" % label)
        return
    time.sleep(1)
    cmd = "Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = '%s'"
    if cwd:
        cmd += "; CurrentDirectory = '%s'" % cwd
    cmd += " } | Out-Null"
    ps(cmd)
    time.sleep(8)
    s = sel()
    time.sleep(12)
    print("%-34s sel=%-9s wv2=%s" % (label, s, wv()))


IN = r"D:\Documents\DeepSeek\快捷桌面项目\publish\QuickDrawer.exe"
OUT = r"D:\QuickDrawer-publish-net48\QuickDrawer.exe"
WS = r"D:\Documents\DeepSeek\快捷桌面项目"
WSOUT = "D:\\"

run("1 in-exe  + in-cwd",  IN,  WS)
run("2 in-exe  + out-cwd", IN,  WSOUT)
run("3 out-exe + in-cwd",  OUT, WS)
run("4 out-exe + out-cwd", OUT, WSOUT)
clean()
print("done")
