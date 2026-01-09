<#
.SYNOPSIS
    GUI Wrapper for PC Router (System Tray App)
#>
param([string]$BaseDir)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing


$ScriptPath = $PSScriptRoot
if (-not [string]::IsNullOrEmpty($BaseDir)) {
    $ConfigPath = Join-Path $BaseDir "config.json"
}
else {
    $ConfigPath = Join-Path $ScriptPath "config.json"
}

Import-Module (Join-Path $ScriptPath "Core-Router.psm1") -Force

# Helper to load icon (embedded or default)
function Get-Icon {
    # Simple trick: Use standard shell icons if custom not found
    return [System.Drawing.Icon]::ExtractAssociatedIcon($PSHOME + "\powershell.exe")
}

# --- GUI Setup ---
$NotifyIcon = New-Object System.Windows.Forms.NotifyIcon
$NotifyIcon.Icon = Get-Icon
$NotifyIcon.Text = "PC Router (Stopped)"
$NotifyIcon.Visible = $true

$ContextMenu = New-Object System.Windows.Forms.ContextMenu
$NotifyIcon.ContextMenu = $ContextMenu

# Menu Items
$MenuItemStart = $ContextMenu.MenuItems.Add("Start Router")
$MenuItemStop = $ContextMenu.MenuItems.Add("Stop Router")
$MenuItemStop.Enabled = $false
$ContextMenu.MenuItems.Add("-")
$MenuItemConfig = $ContextMenu.MenuItems.Add("Edit Config")
$MenuItemExit = $ContextMenu.MenuItems.Add("Exit")

# Logic
function Update-Status {
    param($Running, $Msg)
    if ($Running) {
        $NotifyIcon.Text = "PC Router: RUNNING"
        $MenuItemStart.Enabled = $false
        $MenuItemStop.Enabled = $true
        if ($Msg) { $NotifyIcon.ShowBalloonTip(3000, "Router Started", $Msg, [System.Windows.Forms.ToolTipIcon]::Info) }
    }
    else {
        $NotifyIcon.Text = "PC Router: STOPPED"
        $MenuItemStart.Enabled = $true
        $MenuItemStop.Enabled = $false
        if ($Msg) { $NotifyIcon.ShowBalloonTip(3000, "Router Stopped", $Msg, [System.Windows.Forms.ToolTipIcon]::Info) }
    }
}

$MenuItemStart.add_Click({
        try {
            $Msg = Start-PCRouter -ConfigPath $ConfigPath
            Update-Status -Running $true -Msg $Msg
        }
        catch {
            $NotifyIcon.ShowBalloonTip(5000, "Error", $_.Exception.Message, [System.Windows.Forms.ToolTipIcon]::Error)
        }
    })

$MenuItemStop.add_Click({
        try {
            $Msg = Stop-PCRouter -ConfigPath $ConfigPath
            Update-Status -Running $false -Msg $Msg
        }
        catch {
            $NotifyIcon.ShowBalloonTip(5000, "Error", $_.Exception.Message, [System.Windows.Forms.ToolTipIcon]::Error)
        }
    })

$MenuItemConfig.add_Click({
        Invoke-Item $ConfigPath
    })

$MenuItemExit.add_Click({
        # Cleanup
        Stop-PCRouter -ConfigPath $ConfigPath # Optional: Stop on exit?
        $NotifyIcon.Visible = $false
        $NotifyIcon.Dispose()
        [System.Windows.Forms.Application]::Exit()
    })

# Auto Start Logic (Optional)
# $MenuItemStart.PerformClick()

# Run Message Loop
[System.Windows.Forms.Application]::Run()
