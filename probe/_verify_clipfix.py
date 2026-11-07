"""Verify the clipboard fixes end-to-end against the real running app.

Tests, in order:
  1. two DIFFERENT images -> both must appear (previously the 2nd was silently
     dropped as a "duplicate" because every image hashed to the same key)
  2. an HTML-Format payload that also carries CF_UNICODETEXT (exactly what Word
     does for a table) -> must be captured as Kind=Html, not Kind=Text
     (previously plain text won the priority race and the table was lost)
  3. plain text -> must still be captured as Kind=Text (no regression)

Reads clipboard.json directly; Kind is stored in plaintext.
"""
import ctypes
import ctypes.wintypes as wt
import json
import os
import struct
import subprocess
import sys
import time

user32 = ctypes.WinDLL("user32", use_last_error=True)
kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)

CF_UNICODETEXT = 13
CF_DIB = 8
GMEM_MOVEABLE = 0x0002

CLIP_JSON = os.path.join(
    os.environ["APPDATA"], "QuickDrawer", "clipboard.json")

user32.OpenClipboard.argtypes = [wt.HWND]
user32.OpenClipboard.restype = wt.BOOL
user32.EmptyClipboard.restype = wt.BOOL
user32.CloseClipboard.restype = wt.BOOL
user32.SetClipboardData.argtypes = [wt.UINT, wt.HANDLE]
user32.SetClipboardData.restype = wt.HANDLE
user32.RegisterClipboardFormatW.argtypes = [wt.LPCWSTR]
user32.RegisterClipboardFormatW.restype = wt.UINT
kernel32.GlobalAlloc.argtypes = [wt.UINT, ctypes.c_size_t]
kernel32.GlobalAlloc.restype = wt.HGLOBAL
kernel32.GlobalLock.argtypes = [wt.HGLOBAL]
kernel32.GlobalLock.restype = ctypes.c_void_p
kernel32.GlobalUnlock.argtypes = [wt.HGLOBAL]


def counts():
    if not os.path.exists(CLIP_JSON):
        return {}
    # ConfigStore writes with a BOM (File.WriteAllText + Encoding.UTF8), so read
    # with utf-8-sig rather than utf-8.
    with open(CLIP_JSON, encoding="utf-8-sig") as f:
        data = json.load(f)
    out = {}
    for guess in ("Entries", "entries"):
        if guess in data:
            for e in data[guess]:
                k = e.get("Kind", "?")
                out[k] = out.get(k, 0) + 1
            return out
    return out


def make_dib(w, h, r, g, b):
    """32bpp top-down DIB: 40-byte BITMAPINFOHEADER + BGRA rows."""
    header = struct.pack("<IiiHHIIiiII", 40, w, -h, 1, 32, 0, w * h * 4, 0, 0, 0, 0)
    px = bytes((b, g, r, 255)) * (w * h)
    return header + px


def set_clip_dib(dib, label):
    if not user32.OpenClipboard(None):
        print("  !! OpenClipboard failed for", label)
        return False
    try:
        user32.EmptyClipboard()
        h = kernel32.GlobalAlloc(GMEM_MOVEABLE, len(dib))
        if not h:
            return False
        p = kernel32.GlobalLock(h)
        ctypes.memmove(p, dib, len(dib))
        kernel32.GlobalUnlock(h)
        ok = user32.SetClipboardData(CF_DIB, h) != 0
        return ok
    finally:
        user32.CloseClipboard()


def set_clip_html_and_text(fragment, plain):
    """Mimic Word: the same copy offers BOTH HTML Format and CF_UNICODETEXT."""
    html_id = user32.RegisterClipboardFormatW("HTML Format")
    start_marker = "<!--StartFragment-->"
    end_marker = "<!--EndFragment-->"
    body = start_marker + fragment + end_marker
    head_fmt = (
        "Version:0.9\r\n"
        "StartHTML:{0:0000000000}\r\n"
        "EndHTML:{1:0000000000}\r\n"
        "StartFragment:{2:0000000000}\r\n"
        "EndFragment:{3:0000000000}\r\n"
        "\r\n"
    )
    head_len = len(head_fmt.format(0, 0, 0, 0).encode("utf-8"))
    frag_start = head_len + len(start_marker)
    frag_end = frag_start + len(fragment.encode("utf-8"))
    html_end = head_len + len(body.encode("utf-8"))
    full = head_fmt.format(head_len, html_end, frag_start, frag_end) + body

    if not user32.OpenClipboard(None):
        print("  !! OpenClipboard failed for html")
        return False
    try:
        user32.EmptyClipboard()

        payload = full.encode("utf-8") + b"\0"
        h1 = kernel32.GlobalAlloc(GMEM_MOVEABLE, len(payload))
        p1 = kernel32.GlobalLock(h1)
        ctypes.memmove(p1, payload, len(payload))
        kernel32.GlobalUnlock(h1)
        r1 = user32.SetClipboardData(html_id, h1) != 0

        txt = plain.encode("utf-16-le") + b"\0\0"
        h2 = kernel32.GlobalAlloc(GMEM_MOVEABLE, len(txt))
        p2 = kernel32.GlobalLock(h2)
        ctypes.memmove(p2, txt, len(txt))
        kernel32.GlobalUnlock(h2)
        r2 = user32.SetClipboardData(CF_UNICODETEXT, h2) != 0
        return r1 and r2
    finally:
        user32.CloseClipboard()


def wait(seconds):
    time.sleep(seconds)


def main():
    before = counts()
    print("BEFORE:", before)

    # --- test 1: two different images ------------------------------------
    print("\n[1] two different images")
    ok_a = set_clip_dib(make_dib(320, 200, 200, 120, 40), "imgA")
    wait(2.5)
    mid = counts()
    print("  after imgA:", mid, "(set ok=%s)" % ok_a)

    ok_b = set_clip_dib(make_dib(180, 140, 30, 160, 220), "imgB")
    wait(2.5)
    after = counts()
    print("  after imgB:", after, "(set ok=%s)" % ok_b)

    got_img_a = mid.get("Image", 0) > before.get("Image", 0)
    got_img_b = after.get("Image", 0) > mid.get("Image", 0)

    # --- test 2: HTML + plain text together (Word table) -----------------
    print("\n[2] HTML Format + CF_UNICODETEXT together (simulates Word table)")
    table_html = (
        "<table border=1><tr><td>A1</td><td>B1</td></tr>"
        "<tr><td>A2</td><td>B2</td></tr></table>"
    )
    before_html = counts()
    ok_h = set_clip_html_and_text(table_html, "A1 B1 A2 B2")
    wait(2.5)
    after_html = counts()
    print("  set ok=%s" % ok_h)
    print("  before:", before_html)
    print("  after :", after_html)

    html_gained = after_html.get("Html", 0) > before_html.get("Html", 0)
    text_gained = after_html.get("Text", 0) > before_html.get("Text", 0)

    # --- test 3: plain text only (regression check) ----------------------
    print("\n[3] plain text only")
    before_txt = counts()
    user32.OpenClipboard(None)
    user32.EmptyClipboard()
    txt = ("qd-plain-%d" % int(time.time())).encode("utf-16-le") + b"\0\0"
    h = kernel32.GlobalAlloc(GMEM_MOVEABLE, len(txt))
    p = kernel32.GlobalLock(h)
    ctypes.memmove(p, txt, len(txt))
    kernel32.GlobalUnlock(h)
    user32.SetClipboardData(CF_UNICODETEXT, h)
    user32.CloseClipboard()
    wait(2.5)
    after_txt = counts()
    print("  before:", before_txt)
    print("  after :", after_txt)
    plain_gained = after_txt.get("Text", 0) > before_txt.get("Text", 0)

    # --- verdict ---------------------------------------------------------
    print("\n" + "=" * 52)
    results = [
        ("image #1 captured", got_img_a),
        ("image #2 captured (different content)", got_img_b),
        ("table captured as Html", html_gained),
        ("table NOT downgraded to Text", not text_gained),
        ("plain text still captured", plain_gained),
    ]
    all_ok = True
    for name, ok in results:
        print("%-42s %s" % (name, "PASS" if ok else "FAIL"))
        all_ok = all_ok and ok
    print("=" * 52)
    print("RESULT:", "PASS" if all_ok else "FAIL")
    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
