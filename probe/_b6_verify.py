# -*- coding: utf-8 -*-
"""验证 QuickDrawer.exe 内嵌图标的全部尺寸。

ExtractIconEx 只按系统大/小尺寸返回 HICON，看不出资源组里到底有几帧，
所以要直接解析 PE 资源目录里的 RT_GROUP_ICON（类型 14），
它的 GRPICONDIR 头部第 5、6 字节就是帧数。
"""
import struct
import sys

path = sys.argv[1] if len(sys.argv) > 1 else \
    'src/QuickDrawer/bin/Release/net10.0-windows/win-x64/QuickDrawer.exe'

d = open(path, 'rb').read()

pe_off = struct.unpack_from('<I', d, 0x3C)[0]
assert d[pe_off:pe_off + 4] == b'PE\0\0'
num_sections = struct.unpack_from('<H', d, pe_off + 6)[0]
opt_size = struct.unpack_from('<H', d, pe_off + 20)[0]
opt_off = pe_off + 24
magic = struct.unpack_from('<H', d, opt_off)[0]
assert magic == 0x20B, hex(magic)  # PE32+

# 资源目录 RVA 在数据目录第 2 项（索引 2）
dd_off = opt_off + 112
res_rva, res_size = struct.unpack_from('<II', d, dd_off + 2 * 8)
assert res_rva, 'no resource directory'

sec_off = opt_off + opt_size
sections = []
for i in range(num_sections):
    o = sec_off + i * 40
    name = d[o:o + 8].rstrip(b'\0').decode('ascii', 'replace')
    vsize, vaddr, rawsize, rawptr = struct.unpack_from('<IIII', d, o + 8)
    sections.append((name, vaddr, vsize, rawptr, rawsize))


def rva_to_off(rva):
    for _name, vaddr, vsize, rawptr, rawsize in sections:
        if vaddr <= rva < vaddr + max(vsize, rawsize):
            return rawptr + (rva - vaddr)
    raise ValueError(f'rva {rva:#x} not mapped')


def walk(off, level, path_names):
    n_named, n_id = struct.unpack_from('<HH', d, off + 12)
    total = n_named + n_id
    for i in range(total):
        e = off + 16 + i * 8
        name_field, data_field = struct.unpack_from('<II', d, e)
        ident = name_field if name_field & 0x80000000 else name_field
        if data_field & 0x80000000:
            walk(rva_to_off(res_rva) + (data_field & 0x7FFFFFFF), level + 1,
                 path_names + [ident])
        else:
            if level == 2 and path_names and path_names[0] == 14:  # RT_GROUP_ICON
                data_rva, data_len = struct.unpack_from('<II', d,
                                                        rva_to_off(res_rva) + data_field)
                blk = d[rva_to_off(data_rva):rva_to_off(data_rva) + data_len]
                res, typ, cnt = struct.unpack_from('<HHH', blk, 0)
                print(f'RT_GROUP_ICON id={path_names[1]} '
                      f'frames={cnt} type={typ} bytes={data_len}')
                for k in range(cnt):
                    o2 = 6 + k * 14
                    w, h, cc, _r, planes, bpp, size, rid = struct.unpack_from(
                        '<BBBBHHIH', blk, o2)
                    print(f'   frame {k}: {w or 256}x{h or 256} '
                          f'bpp={bpp} resource-id={rid} {size} bytes')


walk(rva_to_off(res_rva), 0, [])
