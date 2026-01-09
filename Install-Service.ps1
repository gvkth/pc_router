<#
.SYNOPSIS
    Installs the Connect-PCRouter script as a System Scheduled Task.
.DESCRIPTION
    Creates a task named "PCRouterService" that runs on system startup with highest privileges.
#>

$TaskName = "PCRouterService"
$ScriptPath = Join-Path $PSScriptRoot "Connect-PCRouter.ps1"
$Trigger = New-ScheduledTaskTrigger -AtStartup
$Principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$Action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -File `"$ScriptPath`""

# Unregister if exists
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

# Register
Register-ScheduledTask -TaskName $TaskName -Trigger $Trigger -Action $Action -Principal $Principal -Description "Auto-starts PC Router NAT and Hotspot services."

Write-Host "Service '$TaskName' installed successfully." -ForegroundColor Green
Write-Host "You can check it in Task Scheduler library."
Write-Host "To start it immediately, run: Start-ScheduledTask -TaskName '$TaskName'"
