[CmdletBinding()]
param(
  [string]$At = '10:01',
  [int]$TickSeconds = 30
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$script = Join-Path $here 'claim-rewards.ps1'
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$script:WatchLog = Join-Path $here 'watch.log'

function WLog([string]$m) {
  $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $m
  Add-Content -Path $script:WatchLog -Value $line -Encoding UTF8
}

$mutex = New-Object System.Threading.Mutex($false, 'Local\QoderDailyRewardsClaimWatch')
if (-not $mutex.WaitOne(0)) {
  WLog 'another watcher is already running - exiting'
  exit 0
}

$target = [datetime]::ParseExact($At, 'HH:mm', $null).TimeOfDay
WLog "watcher started, daily target $At, pid $PID"
$lastRunDate = $null

try {
  while ($true) {
    $now = Get-Date
    $due = $now.Date.Add($target)
    if ($now -ge $due -and $lastRunDate -ne $due.Date) {
      $lastRunDate = $due.Date
      WLog "firing claim run for $($due.Date.ToString('yyyy-MM-dd'))"
      try {
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
                     '-File', "`"$script`"")
        $p = Start-Process -FilePath $ps -ArgumentList $argList -WorkingDirectory $here `
                           -WindowStyle Hidden -Wait -PassThru
        WLog "claim exit code = $($p.ExitCode)"
      } catch {
        WLog "claim threw: $($_.Exception.Message)"
      }
    }
    Start-Sleep -Seconds $TickSeconds
  }
} finally {
  [void]$mutex.ReleaseMutex()
  $mutex.Dispose()
  WLog 'watcher stopped'
}
