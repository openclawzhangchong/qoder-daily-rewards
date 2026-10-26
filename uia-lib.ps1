# UIA helpers for driving the Qoder desktop app. ASCII-only source.
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

Add-Type -Namespace QoderUia -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern void mouse_event(uint f, uint d, uint e, uint t, IntPtr extra);
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
public const uint LEFTDOWN = 0x0002, LEFTUP = 0x0004;
public static void Click(int x, int y) {
  SetCursorPos(x, y);
  System.Threading.Thread.Sleep(120);
  mouse_event(LEFTDOWN, 0, 0, 0, IntPtr.Zero);
  System.Threading.Thread.Sleep(60);
  mouse_event(LEFTUP, 0, 0, 0, IntPtr.Zero);
}
'@

$AE = [System.Windows.Automation.AutomationElement]
$TS = [System.Windows.Automation.TreeScope]
$COND_TRUE = [System.Windows.Automation.Condition]::TrueCondition
$PATTERNS = @{
  Invoke   = [System.Windows.Automation.InvokePattern]
  Toggle   = [System.Windows.Automation.TogglePattern]
  Expand   = [System.Windows.Automation.ExpandCollapsePattern]
  Selection = [System.Windows.Automation.SelectionItemPattern]
}

function Read-Utf8File([string]$path) {
  return [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
}

function Get-QoderWindow {
  $proc = Get-Process -Name Qoder -ErrorAction SilentlyContinue |
    Where-Object { $_.MainWindowHandle -ne 0 } |
    Select-Object -First 1
  if (-not $proc) { return $null }
  $cond = New-Object System.Windows.Automation.PropertyCondition(
    $AE::ProcessIdProperty, $proc.Id)
  return $AE::RootElement.FindFirst($TS::Children, $cond)
}

function Get-NodeInfo($el) {
  $x = 0; $y = 0; $w = 0; $h = 0
  try {
    $r = $el.Current.BoundingRectangle
    if (-not $r.IsEmpty) {
      $x = [int]$r.X; $y = [int]$r.Y; $w = [int]$r.Width; $h = [int]$r.Height
    }
  } catch { }
  return [pscustomobject]@{
    Name     = $el.Current.Name
    Type     = ($el.Current.ControlType.ProgrammaticName -split '\.')[-1]
    Class    = $el.Current.ClassName
    Enabled  = $el.Current.IsEnabled
    Offscreen= $el.Current.IsOffscreen
    X = $x; Y = $y; W = $w; H = $h
    El = $el
  }
}

function Find-AllByName {
  param($root, [string]$needle, [int]$maxDepth = 60, [switch]$Exact)
  $found = New-Object System.Collections.ArrayList
  $stack = New-Object System.Collections.Stack
  $stack.Push(@{ el = $root; d = 0 })
  while ($stack.Count -gt 0) {
    $item = $stack.Pop()
    $el = $item.el; $d = $item.d
    $nm = ''
    try { $nm = $el.Current.Name } catch { }
    $hit = if ($Exact) { $nm -eq $needle } else { $nm -like "*$needle*" }
    if ($hit -and $nm -ne '') { [void]$found.Add((Get-NodeInfo $el)) }
    if ($d -ge $maxDepth) { continue }
    try {
      foreach ($c in $el.FindAll($TS::Children, $COND_TRUE)) {
        $stack.Push(@{ el = $c; d = $d + 1 })
      }
    } catch { }
  }
  return $found
}

function Invoke-Node($info) {
  $el = $info.El
  foreach ($k in @('Invoke','Toggle','Expand','Selection')) {
    $pt = $PATTERNS[$k]
    try {
      $src = $el.GetCurrentPattern($pt::Pattern)
      if ($src) {
        switch ($k) {
          'Invoke'    { $src.Invoke() }
          'Toggle'    { $src.Toggle() }
          'Expand'    { $src.Expand() }
          'Selection' { $src.Select() }
        }
        return "pattern:$k"
      }
    } catch { }
  }
  if ($info.W -le 0 -or $info.H -le 0) { return $null }
  $hwnd = $el.Current.NativeWindowHandle
  if ($hwnd) { [void][QoderUia.Native]::SetForegroundWindow([IntPtr]$hwnd) }
  [QoderUia.Native]::Click(($info.X + [int]($info.W / 2)), ($info.Y + [int]($info.H / 2)))
  return 'mouse'
}

function Wait-ForNode {
  param($root, [string]$needle, [int]$timeoutSec = 10, [switch]$Exact)
  $deadline = (Get-Date).AddSeconds($timeoutSec)
  while ((Get-Date) -lt $deadline) {
    $w = Get-QoderWindow
    if ($w) {
      $hits = @(Find-AllByName -root $w -needle $needle -Exact:$Exact)
      $ok = $hits | Where-Object { $_.Enabled -and -not $_.Offscreen } | Select-Object -First 1
      if ($ok) { return $ok }
    }
    Start-Sleep -Milliseconds 400
  }
  return $null
}

function Get-QoderWindows {
  $pids = @(Get-Process -Name Qoder -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
  $out = @()
  foreach ($p in $pids) {
    $cond = New-Object System.Windows.Automation.PropertyCondition($AE::ProcessIdProperty, $p)
    foreach ($w in $AE::RootElement.FindAll($TS::Children, $cond)) { $out += $w }
  }
  return $out
}

function Find-AllByNameAll {
  param([string]$needle, [int]$maxDepth = 60, [switch]$Exact)
  $acc = New-Object System.Collections.ArrayList
  foreach ($w in Get-QoderWindows) {
    foreach ($h in @(Find-AllByName -root $w -needle $needle -maxDepth $maxDepth -Exact:$Exact)) {
      [void]$acc.Add($h)
    }
  }
  return $acc
}

Add-Type -Namespace QoderUia -Name Key -MemberDefinition @'
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte sc, uint f, IntPtr e);
public static void Tap(byte vk) { keybd_event(vk,0,0,IntPtr.Zero); System.Threading.Thread.Sleep(70); keybd_event(vk,0,2,IntPtr.Zero); }
'@

Add-Type -Namespace QoderUia -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
'@

function Set-ScreenReaderFlag([bool]$on) {
  if (-not ('QoderUia.SP' -as [type])) {
    Add-Type -Namespace QoderUia -Name SP -MemberDefinition @'
[DllImport("user32.dll",SetLastError=true)] public static extern bool SystemParametersInfo(uint a, uint b, ref bool c, uint d);
'@
  }
  $SPI_SET = 0x0047; $SPI_GET = 0x0049; $FLAGS = 0x03
  if ($on) {
    $v = $true
    return [QoderUia.SP]::SystemParametersInfo($SPI_SET, 0, [ref]$v, $FLAGS)
  } else {
    $v = $false
    [void][QoderUia.SP]::SystemParametersInfo($SPI_GET, 0, [ref]$v, 0)
    return $v
  }
}

function Get-ScreenReaderFlag { return Set-ScreenReaderFlag -on $false }

function Test-QoderA11y {
  foreach ($w in Get-QoderWindows) {
    try {
      $d = $w.FindFirst($TS::Descendants,
        (New-Object System.Windows.Automation.PropertyCondition(
          [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
          [System.Windows.Automation.ControlType]::Document)))
      if ($d) { return $true }
    } catch { }
  }
  return $false
}

function Get-MainQoderHwnd {
  $p = Get-Process -Name Qoder -ErrorAction SilentlyContinue |
       Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
  if ($p) { return $p.MainWindowHandle }
  return [IntPtr]::Zero
}

function Restore-QoderWindow {
  $h = Get-MainQoderHwnd
  if ($h -eq [IntPtr]::Zero) { return $false }
  if ([QoderUia.Win]::IsIconic($h)) {
    [void][QoderUia.Win]::ShowWindow($h, 9)   # SW_RESTORE
    Start-Sleep -Milliseconds 800
  }
  [void][QoderUia.Win]::SetForegroundWindow($h)
  return $true
}

# Web-content nodes only: skip native caption buttons so we never hit window "close".
function Find-WebNode {
  param([string]$needle, [switch]$Exact)
  $res = New-Object System.Collections.ArrayList
  foreach ($h in @(Find-AllByNameAll -needle $needle -Exact:$Exact)) {
    if ($h.Class -eq 'WinCaptionButton') { continue }
    [void]$res.Add($h)
  }
  return $res
}
