<#
.SYNOPSIS
A simple sampling profiler: which functions a running fable_2.exe's threads
spend their time in.

.DESCRIPTION
Use it after tools\thread_cpu.ps1 has shown which threads are busy, to see
what they are doing. No admin rights or Windows performance tools needed.

How it works:
1. Sampling. About 1000 times a second the script pauses each chosen thread
   for a moment (SuspendThread), reads where it is executing - its
   instruction pointer, the RIP register (GetThreadContext) - and lets it run
   again (ResumeThread). PowerShell can't call these Windows APIs directly, so
   a small C# class (Add-Type below) does the sampling loop.
2. Symbolizing. Each address is matched to the module (exe or DLL) it is in,
   and llvm-symbolizer turns it into a function name using the module's
   debug symbols (PDB). For the game exe use the profiling build
   (build.cmd -release fable_2_profiler), which keeps its PDB: recompiled
   game code then shows as its guest function name (sub_XXXXXXXX, or the name
   from the manifest). Modules without symbols fall back to the nearest
   exported function (llvm-readobj lists the exports), e.g.
   ntdll!NtDelayExecution+0x14.
3. Report. Per thread, the share of samples in each module and in each
   function - the more samples, the more time spent there.

Needs LLVM's llvm-symbolizer and llvm-readobj on PATH (LLVM for Windows
installs them; it's the compiler the build uses anyway), or pass their paths.

.PARAMETER ProcessId
The game's process id. Default: the first running fable_2.exe.

.PARAMETER Seconds
How long to sample. Default: 20.

.PARAMETER Threads
Which threads to sample, by name (prefix match). Default: the render thread
("3D Engine"), the game thread ("GameThread") and the GPU emulation
("GPU Commands").

.PARAMETER Top
How many functions to list per thread. Default: 25.

.PARAMETER Symbolizer
llvm-symbolizer: a path, or a name looked up on PATH.

.PARAMETER ReadObj
llvm-readobj: a path, or a name looked up on PATH.

.EXAMPLE
powershell -File tools\sample_threads.ps1 -Seconds 10 -Threads "GPU Commands"
Samples the GPU emulation thread for 10 seconds.
#>
param([int]$ProcessId = 0, [int]$Seconds = 20,
      [string[]]$Threads = @('3D Engine', 'GameThread', 'GPU Commands'),
      [int]$Top = 25,
      [string]$Symbolizer = 'llvm-symbolizer',
      [string]$ReadObj = 'llvm-readobj')

# Resolve the LLVM tools (a path, or a name on PATH) once.
foreach ($tool in 'Symbolizer', 'ReadObj') {
  $command = Get-Command (Get-Variable $tool -ValueOnly) -ErrorAction SilentlyContinue
  if (-not $command) {
    throw "$(Get-Variable $tool -ValueOnly) not found: put LLVM's bin folder on PATH or pass -$tool"
  }
  Set-Variable $tool $command.Source
}

# The sampler, in C#: thread names (GetThreadDescription) and the
# suspend - read RIP - resume loop.
Add-Type @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class IpSampler {
  [DllImport("kernel32.dll")] static extern IntPtr OpenThread(uint access, bool inherit, uint id);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
  [DllImport("kernel32.dll")] static extern uint SuspendThread(IntPtr thread);
  [DllImport("kernel32.dll")] static extern uint ResumeThread(IntPtr thread);
  [DllImport("kernel32.dll")] static extern bool GetThreadContext(IntPtr thread, IntPtr context);
  [DllImport("kernel32.dll")] static extern int GetThreadDescription(IntPtr thread, out IntPtr description);
  [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr memory);
  [DllImport("winmm.dll")] static extern uint timeBeginPeriod(uint period);

  public static string Name(int id) {
    IntPtr t = OpenThread(0x0800, false, (uint)id);
    if (t == IntPtr.Zero) return "";
    try {
      IntPtr text;
      if (GetThreadDescription(t, out text) < 0 || text == IntPtr.Zero) return "";
      string s = Marshal.PtrToStringUni(text); LocalFree(text); return s;
    } finally { CloseHandle(t); }
  }

  // Returns, per thread id, the list of sampled instruction pointers.
  public static Dictionary<int, List<ulong>> Sample(int[] ids, int milliseconds) {
    timeBeginPeriod(1);
    var handles = new IntPtr[ids.Length];
    var result = new Dictionary<int, List<ulong>>();
    for (int i = 0; i < ids.Length; ++i) {
      // SUSPEND_RESUME | GET_CONTEXT | QUERY_INFORMATION
      handles[i] = OpenThread(0x0002 | 0x0008 | 0x0040, false, (uint)ids[i]);
      result[ids[i]] = new List<ulong>();
    }
    // x64 CONTEXT: 1232 bytes, 16-byte aligned; ContextFlags at 0x30, Rip at 0xF8.
    IntPtr raw = Marshal.AllocHGlobal(1232 + 16);
    IntPtr ctx = new IntPtr((raw.ToInt64() + 15) & ~15L);
    var end = DateTime.UtcNow.AddMilliseconds(milliseconds);
    while (DateTime.UtcNow < end) {
      for (int i = 0; i < ids.Length; ++i) {
        if (handles[i] == IntPtr.Zero || SuspendThread(handles[i]) == 0xFFFFFFFF) continue;
        Marshal.WriteInt32(ctx, 0x30, 0x00100001);  // CONTEXT_CONTROL
        if (GetThreadContext(handles[i], ctx))
          result[ids[i]].Add((ulong)Marshal.ReadInt64(ctx, 0xF8));
        ResumeThread(handles[i]);
      }
      System.Threading.Thread.Sleep(1);
    }
    Marshal.FreeHGlobal(raw);
    foreach (var h in handles) if (h != IntPtr.Zero) CloseHandle(h);
    return result;
  }
}
"@

if ($ProcessId -eq 0) { $ProcessId = (Get-Process fable_2 -ErrorAction Stop | Select-Object -First 1).Id }
# 1. Sample the threads whose names start with one of -Threads.
# powershell -File passes "A,B" as one string; accept both forms.
$Threads = @($Threads | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$process = Get-Process -Id $ProcessId
$targets = @{}
foreach ($t in $process.Threads) {
  $name = [IpSampler]::Name($t.Id)
  foreach ($wanted in $Threads) { if ($name -like "$wanted*") { $targets[$t.Id] = $name } }
}
if ($targets.Count -eq 0) { throw "no threads named $($Threads -join ', ')" }
$samples = [IpSampler]::Sample([int[]]@($targets.Keys), $Seconds * 1000)

# 2. Symbolize: map each address to its module and the offset in it (RVA),
# then turn addresses into names, one llvm-symbolizer run per module.
$modules = $process.Modules | ForEach-Object {
  [pscustomobject]@{ Name = $_.ModuleName; Path = $_.FileName;
                     Base = [uint64]$_.BaseAddress.ToInt64(); Size = [uint64]$_.ModuleMemorySize }
}
function Find-Module([uint64]$ip) {
  foreach ($m in $modules) { if ($ip -ge $m.Base -and $ip -lt $m.Base + $m.Size) { return $m } }
  $null
}
$symbolCache = @{}
$exportCache = @{}
# Nearest preceding export (e.g. ntdll!NtDelayExecution) for modules
# llvm-symbolizer has no symbols for.
function Find-Export($module, [uint64]$rva) {
  if (-not $exportCache.ContainsKey($module.Name)) {
    $list = New-Object System.Collections.Generic.List[object]
    $name = $null
    foreach ($line in (& $ReadObj --coff-exports $module.Path 2>$null)) {
      if ($line -match '^\s*Name: (\S+)') { $name = $Matches[1] }
      elseif ($line -match '^\s*RVA: 0x([0-9A-Fa-f]+)' -and $name) {
        $list.Add([pscustomobject]@{ Rva = [Convert]::ToUInt64($Matches[1], 16); Name = $name })
        $name = $null
      }
    }
    $exportCache[$module.Name] = @($list | Sort-Object Rva)
  }
  $best = $null
  foreach ($e in $exportCache[$module.Name]) { if ($e.Rva -le $rva) { $best = $e } else { break } }
  if ($best) { return '{0}!{1}+0x{2:X}' -f $module.Name, $best.Name, ($rva - $best.Rva) }
  '{0}+0x{1:X}' -f $module.Name, $rva
}
function Resolve-Symbols($module, [uint64[]]$ips) {
  # llvm-symbolizer wants addresses at the image's preferred base.
  $headers = & $ReadObj --file-headers $module.Path 2>$null
  $imageBase = [uint64]0
  foreach ($line in $headers) { if ($line -match 'ImageBase: 0x([0-9A-Fa-f]+)') { $imageBase = [Convert]::ToUInt64($Matches[1], 16) } }
  $input = $ips | ForEach-Object { '0x{0:X}' -f ($_ - $module.Base + $imageBase) }
  $output = $input | & $Symbolizer --obj="$($module.Path)" --no-inlines --functions=linkage --output-style=JSON 2>$null
  $i = 0
  foreach ($line in $output) {
    $name = $null
    try { $json = $line | ConvertFrom-Json; $name = $json.Symbol[0].FunctionName } catch {}
    # Without symbols llvm-symbolizer can return '', '??' or the module's one
    # export (e.g. rex_gpu_create for the whole GPU plugin): use exports.
    if (-not $name -or $name -eq '??' -or $name -eq 'rex_gpu_create') {
      $name = Find-Export $module ($ips[$i] - $module.Base)
    }
    $symbolCache[$ips[$i]] = $name
    $i++
  }
  # Without a PDB llvm-symbolizer prints one error line, not one per address.
  foreach ($ip in $ips) {
    if (-not $symbolCache[$ip]) { $symbolCache[$ip] = Find-Export $module ($ip - $module.Base) }
  }
}
$all = $samples.Values | ForEach-Object { $_ } | Sort-Object -Unique
foreach ($group in ($all | Group-Object { $m = Find-Module $_; if ($m) { $m.Name } else { '?' } })) {
  $m = $modules | Where-Object Name -eq $group.Name | Select-Object -First 1
  if ($m) { Resolve-Symbols $m ([uint64[]]$group.Group) }
}

# 3. Report: per thread, the busiest modules and functions.
foreach ($id in $samples.Keys) {
  $ips = $samples[$id]
  "== $($targets[$id]) (thread $id): $($ips.Count) samples"
  $byModule = $ips | Group-Object { $m = Find-Module $_; if ($m) { $m.Name } else { '?' } } |
      Sort-Object Count -Descending
  "   by module: " + (($byModule | Select-Object -First 6 | ForEach-Object {
      '{0} {1:N0}%' -f $_.Name, (100 * $_.Count / $ips.Count) }) -join ', ')
  $ips | Group-Object { $symbolCache[$_] } | Sort-Object Count -Descending | Select-Object -First $Top |
      ForEach-Object { '   {0,5:N1}%  {1}' -f (100 * $_.Count / $ips.Count), $_.Name }
  ''
}
