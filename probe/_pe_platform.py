# -*- coding: utf-8 -*-
"""准确判定 .NET 程序集的目标平台：读 COR20 header 的 Flags。"""
import struct, os, sys

ILONLY = 0x1
BIT32_REQUIRED = 0x2
BIT32_PREFERRED = 0x10000


def analyse(path):
    with open(path, "rb") as f:
        d = f.read()
    if d[:2] != b"MZ":
        return None
    pe = struct.unpack_from("<I", d, 0x3C)[0]
    if d[pe:pe + 4] != b"PE\0\0":
        return None
    machine = struct.unpack_from("<H", d, pe + 4)[0]
    opt = pe + 24
    magic = struct.unpack_from("<H", d, opt)[0]
    is_pe32plus = (magic == 0x20B)
    nd_off = opt + (92 if not is_pe32plus else 108)
    nd = struct.unpack_from("<I", d, nd_off)[0]
    if nd <= 14:
        return dict(machine=machine, fmt="PE32+" if is_pe32plus else "PE32", managed=False)
    dd = opt + (96 if not is_pe32plus else 112)
    cor_rva, cor_size = struct.unpack_from("<II", d, dd + 14 * 8)
    if cor_size == 0:
        return dict(machine=machine, fmt="PE32+" if is_pe32plus else "PE32", managed=False)

    # RVA -> file offset：遍历 section headers
    nsec = struct.unpack_from("<H", d, pe + 6)[0]
    size_opt = struct.unpack_from("<H", d, pe + 20)[0]
    sec = pe + 24 + size_opt
    off = None
    for i in range(nsec):
        s = sec + i * 40
        vsize, vaddr, rsize, rptr = struct.unpack_from("<IIII", d, s + 8)
        if vaddr <= cor_rva < vaddr + max(vsize, rsize):
            off = rptr + (cor_rva - vaddr)
            break
    if off is None:
        return dict(machine=machine, fmt="PE32+" if is_pe32plus else "PE32", managed=True)

    flags = struct.unpack_from("<I", d, off + 16)[0]
    return dict(machine=machine, fmt="PE32+" if is_pe32plus else "PE32",
                managed=True, ilonly=bool(flags & ILONLY),
                bit32req=bool(flags & BIT32_REQUIRED),
                bit32pref=bool(flags & BIT32_PREFERRED), flags=flags)


def verdict(r):
    if r is None:
        return "NOT_PE"
    if not r["managed"]:
        return "native " + {0x14c: "x86", 0x8664: "x64"}.get(r["machine"], hex(r["machine"]))
    if r["bit32req"]:
        return "managed x86 (32BITREQUIRED)"
    if r["bit32pref"]:
        return "managed AnyCPU Prefer32Bit"
    return "managed AnyCPU (64-bit on x64 OS)"


for t in sys.argv[1:]:
    if not os.path.exists(t):
        print("  MISSING %s" % t)
        continue
    r = analyse(t)
    print("  %-38s %s" % (os.path.basename(t), verdict(r)))
