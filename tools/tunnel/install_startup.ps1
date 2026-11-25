# Run once on the Xeon as administrator (right click > Run with PowerShell, or
# from an admin PowerShell):  powershell -ExecutionPolicy Bypass -File C:\nots_batch\app\install_startup.ps1
#
# Makes the batch server, which is also the books tunnel's agent (it answers
# the public server's "fetch" requests), start with Windows even before anyone
# logs on, run with no time limit, and restart by itself if it stops.
# It keeps the same task names; the hardware and power tasks are left as they are.

$ErrorActionPreference = 'Stop'
$user = 'ammar'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\nots_batch\app\run_server.ps1'
$triggers = @(
    (New-ScheduledTaskTrigger -AtStartup),
    (New-ScheduledTaskTrigger -AtLogOn -User $user)
)
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartInterval (New-TimeSpan -Minutes 1) -RestartCount 9999 `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
    -MultipleInstances IgnoreNew
# S4U: runs whether the user is logged on or not, without storing a password.
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType S4U -RunLevel Highest
Register-ScheduledTask -TaskName 'NotsBatchServer' -Action $action -Trigger $triggers `
    -Settings $settings -Principal $principal -Force | Out-Null

# A watchdog every 5 minutes: starts the task again if it is not running.
$check = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -WindowStyle Hidden -Command ' +
    '"if ((Get-ScheduledTask NotsBatchServer).State -ne ''Running'') { Start-ScheduledTask NotsBatchServer }"')
$every = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5)
Register-ScheduledTask -TaskName 'NotsTunnelWatchdog' -Action $check -Trigger $every `
    -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -StartWhenAvailable) `
    -Principal (New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest) -Force | Out-Null

if ((Get-ScheduledTask NotsBatchServer).State -ne 'Running') { Start-ScheduledTask NotsBatchServer }
Get-ScheduledTask NotsBatchServer, NotsTunnelWatchdog | Format-Table TaskName, State
Write-Host 'Done: the tunnel agent now starts with Windows.'
