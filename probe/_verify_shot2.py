import ctypes, time, subprocess

user32 = ctypes.windll.user32
KEYUP = 0x0002
VK_MENU, VK_LWIN, VK_N = 0x12, 0x5B, 0x4E

# 1) 鼠标先移动到抽屉将出现的区域（右边缘面板 1520..1920），避免 auto-hide
user32.SetCursorPos(1700, 600)
time.sleep(0.4)

# 2) 唤出抽屉
user32.keybd_event(VK_MENU, 0, 0, 0)
user32.keybd_event(VK_LWIN, 0, 0, 0)
user32.keybd_event(VK_N, 0, 0, 0)
time.sleep(0.06)
user32.keybd_event(VK_N, 0, KEYUP, 0)
user32.keybd_event(VK_LWIN, 0, KEYUP, 0)
user32.keybd_event(VK_MENU, 0, KEYUP, 0)
time.sleep(1.2)

# 3) 鼠标保持在面板内，截图
user32.SetCursorPos(1700, 600)
time.sleep(0.2)
out = "probe\\_verify_addnote.png"
ps = (
    "Add-Type -AssemblyName System.Windows.Forms,System.Drawing;"
    "$b=[System.Windows.Forms.SystemInformation]::VirtualScreen;"
    "$bmp=New-Object System.Drawing.Bitmap $b.Width,$b.Height;"
    "$g=[System.Drawing.Graphics]::FromImage($bmp);"
    "$g.CopyFromScreen($b.Location,[System.Drawing.Point]::Empty,$b.Size);"
    "$bmp.Save('%s',[System.Drawing.Imaging.ImageFormat]::Png);"
    "$g.Dispose();$bmp.Dispose();" % out
)
r = subprocess.run(["powershell", "-NoProfile", "-Command", ps],
                   capture_output=True, text=True, timeout=120)
print("rc =", r.returncode, "err =", r.stderr.strip()[:300])

from PIL import Image
im = Image.open("probe/_verify_addnote.png")
# 便签页在底部标签左侧，先看整体右侧
drawer = im.crop((1520, 0, 1920, 1080))
drawer.save("probe/_verify_drawer.png")
print("drawer saved", drawer.size)

# 统计抽屉区域是否有深色像素（面板已展开的标志）
px = drawer.convert("RGB").load()
dark = sum(1 for y in range(0, 1080, 10) for x in range(0, 400, 10)
           if sum(px[x, y]) < 200)
print("dark samples in drawer:", dark)
