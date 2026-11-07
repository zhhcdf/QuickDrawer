import io

P = "README.md"
s = io.open(P, encoding="utf-8").read()

reps = [
    (u"单个 exe，不装运行时，不写注册表（除了可选的开机自启），数据全部留在本机。",
     u"**2.84 MB，不装运行时**（目标 .NET Framework 4.8，是 Windows 系统组件）。不写注册表（除了可选的开机自启），数据全部留在本机。"),

    (u"要求是\"其他 Windows 电脑无需特殊依赖直接运行\"。满足这一条有两条路：",
     u"要求是\"其他 Windows 电脑无需特殊依赖直接运行\"。满足这一条有三条路，都是同一份源码在本机实测的结果："),
]

for old, new in reps:
    assert s.count(old) == 1, "NOT FOUND: " + old[:40]
    s = s.replace(old, new)

io.open(P, "w", encoding="utf-8", newline="\n").write(s)
print("OK fixed, %d bytes" % len(s.encode("utf-8")))
