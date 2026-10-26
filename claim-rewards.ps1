[CmdletBinding()]
param(
  [switch]$DryRun,
  [switch]$KeepA11y,
  [int]$BootTimeoutSec = 120,
  [int]$Attempts = 3
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
. "$PSScriptRoot\uia-lib.ps1"
$L = Read-Utf8File "$PSScriptRoot\labels.json" | ConvertFrom-Json

$script:LogFile = Join-Path $PSScriptRoot 'claim.log'
function Log([string]$m) {
  $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $m
  Add-Content -Path $script:LogFile -Value $line -Encoding UTF8
  Write-Host $line
}

function Wait-Node([string]$needle, [int]$sec, [switch]$Exact, [string]$type, [switch]$AnyState) {
  $deadline = (Get-Date).AddSeconds($sec)
  while ((Get-Date) -lt $deadline) {
    $hits = @(Find-WebNode -needle $needle -Exact:$Exact) |
      Where-Object { (-not $_.Offscreen) -and ($AnyState -or $_.Enabled) }
    if ($type) { $hits = @($hits | Where-Object { $_.Type -eq $type }) }
    if ($hits.Count -gt 0) { return $hits[0] }
    Start-Sleep -Milliseconds 400
  }
  return $null
}

function Test-DialogOpen {
  foreach ($m in $L.dialogMarkers) {
    $visible = @($(Find-WebNode -needle $m) | Where-Object { -not $_.Offscreen })
    if ($visible.Count -gt 0) { return $true }
  }
  return $false
}

function Close-Dialog {
  [void]([QoderUia.Key]::Tap(0x1B))
  Start-Sleep -Milliseconds 600
}

function Ensure-QoderRunning {
  if (Get-Process -Name Qoder -ErrorAction SilentlyContinue) { return $true }
  $exe = Join-Path $env:LOCALAPPDATA 'Programs\Qoder\Qoder.exe'
  if (-not (Test-Path $exe)) { Log "QODER EXE NOT FOUND: $exe"; return $false }
  Log "Qoder not running -> launching $exe"
  Start-Process $exe
  $deadline = (Get-Date).AddSeconds($BootTimeoutSec)
  while ((Get-Date) -lt $deadline) {
    if (@(Get-QoderWindows).Count -gt 0) { Start-Sleep -Seconds 3; return $true }
    Start-Sleep -Milliseconds 800
  }
  Log "TIMEOUT waiting for Qoder window"
  return $false
}

function Ensure-A11y {
  if (Test-QoderA11y) { return $false }
  Log "renderer a11y off -> enabling screen-reader flag"
  [void](Set-ScreenReaderFlag $true)
  $deadline = (Get-Date).AddSeconds(25)
  while ((Get-Date) -lt $deadline) {
    if (Test-QoderA11y) { return $true }
    Start-Sleep -Milliseconds 700
  }
  Log "WARN renderer a11y still off"
  return $true
}

function Open-RewardsDialog {
  if (Test-DialogOpen) { Log "rewards dialog already open"; return $true }
  $menuItem = @(Find-WebNode -needle $L.rewardsCenter -Exact) |
    Where-Object { $_.Type -eq 'MenuItem' -and $_.Enabled -and -not $_.Offscreen } |
    Select-Object -First 1
  if (-not $menuItem) {
    $menuBtn = @(Find-WebNode -needle $L.menuButton -Exact) |
      Where-Object { $_.Type -eq 'Button' -and $_.Enabled -and -not $_.Offscreen } |
      Select-Object -First 1
    if (-not $menuBtn) { Log "menu trigger not found"; return $false }
    Log ("open user menu via " + (Invoke-Node $menuBtn))
    $menuItem = Wait-Node -needle $L.rewardsCenter -sec 12 -Exact -type 'MenuItem'
    if (-not $menuItem) { Log "menu item not found"; return $false }
  }
  Log ("open rewards center via " + (Invoke-Node $menuItem))
  return $true
}

$result = 'FAILED'
$weEnabledA11y = $false
try {
  if (-not (Ensure-QoderRunning)) { throw 'qoder not available' }
  [void](Restore-QoderWindow)
  $weEnabledA11y = Ensure-A11y

  for ($a = 1; $a -le $Attempts; $a++) {
    Log "--- attempt $a/$Attempts ---"
    if (-not (Open-RewardsDialog)) { Close-Dialog; Start-Sleep -Seconds 2; continue }

    $claim = Wait-Node -needle $L.claim -sec 20 -type 'Button'
    if ($claim) {
      if ($DryRun) {
        $result = 'DRYRUN-CLAIMABLE'
        Log "DRY RUN: would click '$($L.claim)' at $($claim.X),$($claim.Y)"
      } else {
        Log ("click claim via " + (Invoke-Node $claim))
        $ok = Wait-Node -needle $L.claimed -sec 20 -type 'Button' -AnyState
        $result = if ($ok) { 'CLAIMED' } else { 'CLICKED-UNVERIFIED' }
      }
      break
    }

    if (Wait-Node -needle $L.claimed -sec 6 -type 'Button' -AnyState) {
      $result = 'ALREADY-CLAIMED'
      Log "today already claimed"
      break
    }

    Log "dialog showed neither '$($L.claim)' nor '$($L.claimed)'; resetting"
    Close-Dialog
    Start-Sleep -Seconds 2
  }

  Close-Dialog
}
catch {
  Log "ERROR: $($_.Exception.Message)"
  try { Close-Dialog } catch { }
}
finally {
  if ($weEnabledA11y -and -not $KeepA11y) {
    [void](Set-ScreenReaderFlag $false)
    Log "screen-reader flag restored to off"
  }
}

Log "=== $result ==="
exit $(if ($result -in @('CLAIMED','ALREADY-CLAIMED','DRYRUN-CLAIMABLE')) { 0 } else { 1 })
