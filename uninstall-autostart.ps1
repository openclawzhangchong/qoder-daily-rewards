param([string]$ValueName = 'QoderDailyRewardsClaim')

$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$p = Get-ItemProperty -Path $runKey -Name $ValueName -ErrorAction SilentlyContinue
if ($p) {
  Remove-ItemProperty -Path $runKey -Name $ValueName
  Write-Host "removed autostart value $ValueName"
} else {
  Write-Host "autostart value $ValueName not present"
}

$procs = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object { $_.CommandLine -like '*claim-watch.ps1*' })
foreach ($x in $procs) {
  Stop-Process -Id $x.ProcessId -Force
  Write-Host "stopped watcher pid $($x.ProcessId)"
}
if ($procs.Count -eq 0) { Write-Host "no watcher process running" }
