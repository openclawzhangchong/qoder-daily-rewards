[CmdletBinding()]
param(
  [switch]$DryRun,
  [switch]$KeepA11y,
  [int]$BootTimeoutSec = 120,
  [int]$Attempts = 3,
  [int]$ClaimTimeoutSec = 75
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
  $visible = @(Find-AnyWebNode -needles @($L.dialogMarkers)) | Where-Object { -not $_.Offscreen }
  return $visible.Count -gt 0
}

# Claim labels drift between campaigns ("领取" today, "立即领取" before) and one is a
# substring of the other, so candidates must be matched exactly rather than contained.
function Wait-AnyNode([string[]]$needles, [string]$type, [int]$sec, [switch]$AnyState, [switch]$Contain) {
  $deadline = (Get-Date).AddSeconds($sec)
  while ($true) {
    foreach ($h in @(Find-AnyWebNode -needles $needles)) {
      if ($h.Offscreen) { continue }
      if ($type -and $h.Type -ne $type) { continue }
      if (-not $AnyState -and -not $h.Enabled) { continue }
      if (-not $Contain -and ($needles -notcontains $h.Name)) { continue }
      return $h
    }
    if ((Get-Date) -ge $deadline) { return $null }
    Start-Sleep -Milliseconds 400
  }
}

# Claimable and already-claimed are resolved in one pass on purpose: checking them in
# sequence would make an already-claimed day wait out the whole claim timeout first.
function Wait-ClaimState([int]$sec) {
  $deadline = (Get-Date).AddSeconds($sec)
  $all = @($L.claim) + @($L.claimed)
  while ($true) {
    $buttons = @(Find-AnyWebNode -needles $all) |
      Where-Object { $_.Type -eq 'Button' -and -not $_.Offscreen }
    $claimable = @($buttons | Where-Object { (@($L.claim) -contains $_.Name) -and $_.Enabled } | Select-Object -First 1)
    if ($claimable.Count -gt 0) { return [pscustomobject]@{ Kind = 'claimable'; Node = $claimable[0] } }
    $done = @($buttons | Where-Object { @($L.claimed) -contains $_.Name } | Select-Object -First 1)
    if ($done.Count -gt 0) { return [pscustomobject]@{ Kind = 'claimed'; Node = $done[0] } }
    if ((Get-Date) -ge $deadline) { return $null }
    Start-Sleep -Milliseconds 400
  }
}

# Esc alone leaves the campaign modal open, so fall back to the modal's own 关闭 button.
# Caption buttons are filtered out upstream, so this can never close the app itself.
function Close-Dialog {
  [void]([QoderUia.Key]::Tap(0x1B))
  Start-Sleep -Milliseconds 600
  if (-not (Test-DialogOpen)) { return }
  $x = @(Find-AnyWebNode -needles @($L.closeButton)) |
    Where-Object { $_.Type -eq 'Button' -and $_.Name -eq $L.closeButton -and $_.Enabled -and -not $_.Offscreen } |
    Select-Object -First 1
  if ($x) { Log ("close dialog via " + (Invoke-Node $x)) }
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
  $menuItem = @(Find-WebNode -needle $L.rewardsCenter) |
    Where-Object { $_.Type -eq 'MenuItem' -and $_.Enabled -and -not $_.Offscreen } |
    Select-Object -First 1
  if (-not $menuItem) {
    $menuBtn = @(Find-WebNode -needle $L.menuButton -Exact) |
      Where-Object { $_.Type -eq 'Button' -and $_.Enabled -and -not $_.Offscreen } |
      Select-Object -First 1
    if (-not $menuBtn) { Log "menu trigger not found"; return $false }
    Log ("open user menu via " + (Invoke-Node $menuBtn))
    $menuItem = Wait-Node -needle $L.rewardsCenter -sec 12 -type 'MenuItem'
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

    # The dialog body is a server-rendered nested document ("Qoder Campaign"); rows paint
    # first and the action buttons arrive seconds later, so wait for the header before racing.
    $ready = Wait-AnyNode -needles @($L.dialogMarkers) -sec 45 -Contain
    if (-not $ready) { Log "campaign document never rendered"; Close-Dialog; Start-Sleep -Seconds 2; continue }

    $state = Wait-ClaimState -sec $ClaimTimeoutSec
    if (-not $state) {
      Log "dialog showed no claim or claimed button; resetting"
      Close-Dialog
      Start-Sleep -Seconds 2
      continue
    }

    if ($state.Kind -eq 'claimed') {
      $result = 'ALREADY-CLAIMED'
      Log "today already claimed"
      break
    }

    $claim = $state.Node
    if ($DryRun) {
      $result = 'DRYRUN-CLAIMABLE'
      Log "DRY RUN: would click '$($claim.Name)' at $($claim.X),$($claim.Y)"
    } else {
      Log ("click claim '$($claim.Name)' via " + (Invoke-Node $claim))
      $ok = Wait-AnyNode -needles @($L.claimed) -type 'Button' -sec 20 -AnyState
      $result = if ($ok) { 'CLAIMED' } else { 'CLICKED-UNVERIFIED' }
    }
    break
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
