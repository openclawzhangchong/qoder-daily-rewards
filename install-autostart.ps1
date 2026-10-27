[CmdletBinding()]
param(
  [string]$ValueName = 'QoderDailyRewardsClaim',
  [string]$At = '11:01',
  [switch]$StartNow
)

$ErrorActionPreference = 'Stop'
# Fail here rather than at the next logon: a bad time silently leaves no watcher.
[void][datetime]::ParseExact($At, 'HH:mm', $null)
$here = $PSScriptRoot
$watch = Join-Path $here 'claim-watch.ps1'
if (-not (Test-Path $watch)) { throw "missing $watch" }

$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$cmd = "`"$ps`" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$watch`" -At $At"
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'

New-ItemProperty -Path $runKey -Name $ValueName -PropertyType String -Value $cmd -Force | Out-Null
Write-Host "autostart registered: HKCU\...\Run\$ValueName"
Write-Host "  $cmd"

if ($StartNow) {
  $existing = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*claim-watch.ps1*' })
  if ($existing.Count -gt 0) {
    Write-Host "watcher already running (pid $($existing[0].ProcessId))"
  } else {
    $p = Start-Process -FilePath $ps -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',"`"$watch`"",'-At',$At) -WindowStyle Hidden -PassThru
    Write-Host "watcher started, pid $($p.Id), daily target $At"
  }
}

Write-Host ""
Write-Host "logs : $here\watch.log  (schedule)  /  claim.log  (each run)"
Write-Host "undo : powershell -File `"$(Join-Path $here 'uninstall-autostart.ps1')`""
