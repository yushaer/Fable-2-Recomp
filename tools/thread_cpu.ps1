<#
.SYNOPSIS
Shows how much CPU each thread of a running fable_2.exe uses, by thread name.

.DESCRIPTION
Answers "where does the time go?" before reaching for a profiler: is a slow
frame spent emulating the GPU, or in the game's own (recompiled) code?

The SDK names its threads, so they can be told apart: "GPU Commands" is the
Xenos command processor (GPU emulation), "3D Engine" is the game's render
thread, "GameThread" and the other guest XThreads run recompiled game code.

How it works: Windows keeps a running total of CPU time per thread. The script
reads every thread's total, waits -Seconds, reads them again, and prints the
difference as a percentage of the wait: 100% = one CPU core busy the whole
time (a thread can't exceed 100%; the process total can). Thread names come
from GetThreadDescription, a Windows API PowerShell doesn't expose, so a small
C# helper (Add-Type below) calls it.

.PARAMETER ProcessId
The game's process id. Default: the first running fable_2.exe.

.PARAMETER Seconds
How long to measure. Default: 30.

.PARAMETER Top
How many of the busiest threads to list. Default: 15.

.EXAMPLE
powershell -File tools\thread_cpu.ps1 -Seconds 20
Measures for 20 seconds while you play, then lists the busiest threads.
#>
param([int]$ProcessId = 0, [int]$Seconds = 30, [int]$Top = 15)

# GetThreadDescription (kernel32) returns the name the program gave a thread.
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class ThreadNames {
  [DllImport("kernel32.dll")] static extern IntPtr OpenThread(uint access, bool inherit, uint id);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
  [DllImport("kernel32.dll")] static extern int GetThreadDescription(IntPtr thread, out IntPtr description);
  [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr memory);
  public static string Get(int id) {
    IntPtr thread = OpenThread(0x0800 /* QUERY_LIMITED_INFORMATION */, false, (uint)id);
    if (thread == IntPtr.Zero) return "";
    try {
      IntPtr text;
      if (GetThreadDescription(thread, out text) < 0 || text == IntPtr.Zero) return "";
      string name = Marshal.PtrToStringUni(text);
      LocalFree(text);
      return name;
    } finally { CloseHandle(thread); }
  }
}
"@

if ($ProcessId -eq 0) { $ProcessId = (Get-Process fable_2 -ErrorAction Stop | Select-Object -First 1).Id }
# Thread id -> total CPU time so far (ms). Threads can exit between the two
# snapshots, hence the try.
function Snapshot {
  $times = @{}
  foreach ($t in (Get-Process -Id $ProcessId).Threads) {
    try { $times[$t.Id] = $t.TotalProcessorTime.TotalMilliseconds } catch {}
  }
  $times
}
$before = Snapshot
$start = Get-Date
Start-Sleep -Seconds $Seconds
$after = Snapshot
$elapsedMs = ((Get-Date) - $start).TotalMilliseconds

# CPU time used during the window, as a percentage of the window (threads
# started during it count from 0).
$rows = foreach ($id in $after.Keys) {
  $base = if ($before.ContainsKey($id)) { $before[$id] } else { 0 }
  $name = [ThreadNames]::Get($id)
  [pscustomobject]@{ Thread = $id; Name = $(if ($name) { $name } else { '(unnamed)' });
                     CpuPct = [math]::Round(100 * ($after[$id] - $base) / $elapsedMs, 1) }
}
$rows | Sort-Object CpuPct -Descending | Select-Object -First $Top | Format-Table -AutoSize | Out-String -Width 120
"{0} threads, total {1:N0}% of one core over {2:N0} s" -f $rows.Count, (($rows | Measure-Object CpuPct -Sum).Sum), ($elapsedMs / 1000)
