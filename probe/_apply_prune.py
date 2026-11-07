# -*- coding: utf-8 -*-
"""按 probe/_prune_plan.txt 把 DROP 的文件移到 backup/probe-pruned/（可恢复），不硬删。

backup/ 已在 .gitignore 中，所以移动后这些文件不会进 git，但本机仍可查。
"""
import os
import shutil

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROBE = os.path.join(ROOT, "probe")
BACKUP = os.path.join(ROOT, "backup", "probe-pruned")

keep, drop = [], []
with open(os.path.join(PROBE, "_prune_plan.txt"), encoding="utf-8") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if line.startswith("KEEP\t"):
            keep.append(line[5:])
        elif line.startswith("DROP\t"):
            drop.append(line[5:])

print("plan: keep=%d drop=%d" % (len(keep), len(drop)))

moved = 0
skipped = 0
for rel in drop:
    src = os.path.join(PROBE, rel)
    if not os.path.isfile(src):
        skipped += 1
        continue
    dst = os.path.join(BACKUP, rel)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    if os.path.exists(dst):
        os.remove(dst)
    shutil.move(src, dst)
    moved += 1

print("moved=%d skipped=%d" % (moved, skipped))

# 清理 probe 下因移动而空掉的目录（只删空目录，不删有内容的）
removed_dirs = 0
for dirpath, dirnames, filenames in os.walk(PROBE, topdown=False):
    if dirpath == PROBE:
        continue
    try:
        if not os.listdir(dirpath):
            os.rmdir(dirpath)
            removed_dirs += 1
    except OSError:
        pass
print("removed empty dirs=%d" % removed_dirs)

# 校验：保留下来的都还在
missing = [k for k in keep if not os.path.exists(os.path.join(PROBE, k))]
print("keep files missing after move: %d" % len(missing))
for m in missing[:10]:
    print("  MISSING " + m)
