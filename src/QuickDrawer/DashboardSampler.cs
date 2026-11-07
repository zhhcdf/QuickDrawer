using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Net.NetworkInformation;
using System.Runtime.InteropServices;
using System.Threading;

using QuickDrawer.Native;

namespace QuickDrawer;

/// <summary>
/// 面板底部仪表盘（2026-11-03 用户需求："在面板的最底下我想要一行仪表盘，
/// 显示 cpu/内存/网速/温度，点击 cpu 打开任务管理器"）的采样器。
///
/// 为什么不用 PerformanceCounter：
///   · PerformanceCounter 首次实例化要加载计数器库，实测 200–800 ms，
///     放在 UI 线程上会把每次滑出面板都卡一下；
/// GetSystemTimes / GlobalMemoryStatusEx 都是无状态轻量 P/Invoke，单次耗时微秒级。
///
/// 2026-11-04 用户要求去掉温度显示（本机 ACPI 不向系统提供热区温度，
/// 那一格永远显示「—」，占位没有意义），采样器里已不再有温度路径。
/// 温度取证过程见 docs/修正记录.md「底部仪表盘」一节的 6 条实测路径。
/// </summary>
internal sealed class DashboardSampler
{
    private readonly Stopwatch _clock = Stopwatch.StartNew();

    private ulong _prevIdle;
    private ulong _prevKernel;
    private ulong _prevUser;
    private TimeSpan _prevStamp;
    private bool _hasCpuBaseline;

    private List<NetworkInterface> _nics = new();
    private int _nicAge = int.MaxValue;
    private long _prevNetIn;
    private long _prevNetOut;
    private bool _hasNetBaseline;

    public double? CpuPercent { get; private set; }

    public int MemoryPercent { get; private set; }

    public double MemoryUsedGb { get; private set; }

    public double MemoryTotalGb { get; private set; }

    public double NetDownBytesPerSec { get; private set; }

    public double NetUpBytesPerSec { get; private set; }

    /// <summary>
    /// 采一帧。CPU / 网速是差分指标，第一帧只建基线、不出数（返回后对应属性为 null / 0）。
    /// </summary>
    public void Sample()
    {
        TimeSpan now = _clock.Elapsed;
        double seconds = (now - _prevStamp).TotalSeconds;
        if (seconds <= 0)
        {
            seconds = 1;
        }

        SampleCpu();
        SampleMemory();
        SampleNetwork(seconds);

        _prevStamp = now;
    }

    private void SampleCpu()
    {
        if (!NativeMethods.GetSystemTimes(out ulong idle, out ulong kernel, out ulong user))
        {
            return;
        }

        if (!_hasCpuBaseline)
        {
            _prevIdle = idle;
            _prevKernel = kernel;
            _prevUser = user;
            _hasCpuBaseline = true;
            return;
        }

        // kernel 时间**包含** idle 时间（Win32 文档明确说明），所以总时间不能
        // 简单用 idle + kernel + user，否则 idle 被算两遍、CPU 永远偏低。
        ulong kernelDelta = kernel - _prevKernel;
        ulong userDelta = user - _prevUser;
        ulong idleDelta = idle - _prevIdle;

        _prevIdle = idle;
        _prevKernel = kernel;
        _prevUser = user;

        ulong total = kernelDelta + userDelta;
        if (total == 0)
        {
            return;
        }

        ulong busy = total > idleDelta ? total - idleDelta : 0;
        double percent = busy * 100.0 / total;
        CpuPercent = Math.Max(0, Math.Min(100, percent));
    }

    private void SampleMemory()
    {
        if (!NativeMethods.TryGetMemoryStatus(out NativeMethods.MEMORYSTATUSEX status))
        {
            return;
        }

        double total = status.ullTotalPhys / 1024.0 / 1024.0;
        double avail = status.ullAvailPhys / 1024.0 / 1024.0;
        MemoryTotalGb = total / 1024.0;
        MemoryUsedGb = (total - avail) / 1024.0;
        MemoryPercent = (int)Math.Max(0, Math.Min(100, status.dwMemoryLoad));
    }

    private void SampleNetwork(double seconds)
    {
        // 每秒枚举一次网卡列表没必要（枚举比读计数器贵得多），10 秒刷新一次足够
        // 跟上插拔网线 / 连断 Wi-Fi 这类变化。
        if (_nicAge >= 10)
        {
            try
            {
                _nics = NetworkInterface.GetAllNetworkInterfaces()
                    .Where(n => n.NetworkInterfaceType != NetworkInterfaceType.Loopback
                                && n.NetworkInterfaceType != NetworkInterfaceType.Tunnel
                                && n.OperationalStatus == OperationalStatus.Up)
                    .ToList();
            }
            catch
            {
                _nics = new List<NetworkInterface>();
            }

            _nicAge = 0;
        }

        _nicAge++;

        long inBytes = 0;
        long outBytes = 0;
        foreach (NetworkInterface nic in _nics)
        {
            try
            {
                IPv4InterfaceStatistics stats = nic.GetIPv4Statistics();
                inBytes += stats.BytesReceived;
                outBytes += stats.BytesSent;
            }
            catch
            {
                // 网卡刚好断开时这里会抛，跳过它继续统计别的网卡
            }
        }

        if (!_hasNetBaseline)
        {
            _prevNetIn = inBytes;
            _prevNetOut = outBytes;
            _hasNetBaseline = true;
            return;
        }

        long inDelta = inBytes - _prevNetIn;
        long outDelta = outBytes - _prevNetOut;

        _prevNetIn = inBytes;
        _prevNetOut = outBytes;

        // 计数器倒退 = 网卡重连后从 0 重算，别把负数当流量
        NetDownBytesPerSec = inDelta > 0 ? inDelta / seconds : 0;
        NetUpBytesPerSec = outDelta > 0 ? outDelta / seconds : 0;
    }
}
