[CmdletBinding()]
param(
  [string]$At = '11:01',
  [string]$TaskName = 'QoderDailyRewardsClaim',
  [switch]$RunNow,
  [switch]$Remove
)

# Registering a scheduled task needs a full admin token, but this shell starts UAC-filtered.
# Elevation here is silent (ConsentPromptBehaviorAdmin=0), so push the real work into an
# elevated child and pass results back through a file: stdout does not cross the elevation
# boundary.
$ErrorActionPreference = 'Stop'
[void][datetime]::ParseExact($At, 'HH:mm', $null)

$dir = $PSScriptRoot
$claim = Join-Path $dir 'claim-rewards.ps1'
if (-not (Test-Path $claim)) { throw "missing $claim" }

$payload = @'
param([string]$ResultFile, [string]$Dir, [string]$TaskName, [string]$At, [switch]$RunNow, [switch]$Remove)
$ErrorActionPreference = 'Stop'
$lines = New-Object System.Collections.ArrayList
function Add-Line([string]$s) { [void]$lines.Add((Get-Date -Format 'HH:mm:ss') + '  ' + $s) }

try {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $isAdmin = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  Add-Line ("token elevated=" + $isAdmin + " user=" + $id.Name)
  if (-not $isAdmin) { Add-Line 'ABORT: child was not elevated' ; return }

  if ($Remove) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Add-Line ('unregistered ' + $TaskName)
    return
  }

  $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $script = Join-Path $Dir 'claim-rewards.ps1'
  $arg = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $script + '"'

  $action = New-ScheduledTaskAction -Execute $psExe -Argument $arg -WorkingDirectory $Dir
  $trigger = New-ScheduledTaskTrigger -Daily -At $At
  $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -Hidden -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 20)
  # Interactive token, not StoredPassword: UI Automation only sees the on-screen desktop,
  # so a headless "run whether user is logged on or not" session could never click anything.
  $principal = New-ScheduledTaskPrincipal -UserId $id.Name -LogonType Interactive -RunLevel Limited

  Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Settings $settings -Principal $principal -Force `
    -Description ('Daily Qoder rewards claim at ' + $At + '. UI Automation clicks the claim button in the Qoder desktop app; runs only in an interactive session.') | Out-Null
  Add-Line ("registered " + $TaskName + " daily at " + $At)

  $t = Get-ScheduledTask -TaskName $TaskName
  $i = $t | Get-ScheduledTaskInfo
  Add-Line ("state=" + $t.State + " nextRun=" + $i.NextRunTime + " lastResult=" + $i.LastTaskResult)

  if ($RunNow) {
    Start-ScheduledTask -TaskName $TaskName
    Add-Line 'requested immediate run'
  }

  $xml = Export-ScheduledTask -TaskName $TaskName
  Add-Line '----- task definition -----'
  foreach ($l in ($xml -split "`r?`n")) { Add-Line $l }
}
catch {
  Add-Line ('ERROR: ' + $_.Exception.Message)
}
finally {
  $lines | Set-Content -Path $ResultFile -Encoding UTF8
}
'@

$tmp = Join-Path $env:TEMP ('qoder-task-elevate-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.ps1')
$result = [System.IO.Path]::ChangeExtension($tmp, '.result.txt')
$payload | Set-Content -Path $tmp -Encoding ASCII

$childArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$tmp`"",
               '-ResultFile', "`"$result`"", '-Dir', "`"$dir`"",
               '-TaskName', "`"$TaskName`"", '-At', $At)
if ($RunNow) { $childArgs += '-RunNow' }
if ($Remove) { $childArgs += '-Remove' }

$child = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
  -Verb RunAs -WindowStyle Hidden -Wait -PassThru -ArgumentList $childArgs

Write-Host ("elevated child pid " + $child.Id + " exit " + $child.ExitCode)
if (Test-Path $result) {
  Get-Content $result -Encoding UTF8
  Remove-Item $tmp, $result -Force
} else {
  Write-Host 'no result file written - elevation was probably blocked'
  Write-Host ("payload kept for inspection: $tmp")
}
