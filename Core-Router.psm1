<#
.SYNOPSIS
    Core Logic for PC Router (NAT & Hotspot) as a reusable Module.
#>

$ScriptPath = $PSScriptRoot

function Await-WinRT {
    param($AsyncObj)
    if ($null -eq $AsyncObj) { return $null }
    while ($AsyncObj.Status -eq "Started") { Start-Sleep -Milliseconds 100 }
    if ($AsyncObj.Status -eq "Completed") {
        try { return $AsyncObj.GetResults() } catch { return $null }
    }
    elseif ($AsyncObj.Status -eq "Error") { throw "WinRT Async Error: $($AsyncObj.ErrorCode)" }
    return $null
}

function Start-PCRouter {
    param([string]$ConfigPath)
    
    if (-not (Test-Path $ConfigPath)) { throw "Config not found: $ConfigPath" }
    $Config = Get-Content $ConfigPath | ConvertFrom-Json
    
    # 1. LAN IP
    foreach ($InterfaceName in $Config.LanInterfaces) {
        $Adapter = Get-NetAdapter -Name $InterfaceName -ErrorAction SilentlyContinue
        if ($Adapter) {
            $CurrentIP = Get-NetIPAddress -InterfaceAlias $InterfaceName -AddressFamily IPv4 -ErrorAction SilentlyContinue
            if ($CurrentIP.IPAddress -ne $Config.LanGatewayIP) {
                Remove-NetIPAddress -InterfaceAlias $InterfaceName -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
                New-NetIPAddress -InterfaceAlias $InterfaceName -IPAddress $Config.LanGatewayIP -PrefixLength $Config.LanSubnetPrefixLength -AddressFamily IPv4 | Out-Null
            }
            try { Set-NetIPInterface -InterfaceAlias $InterfaceName -AddressFamily IPv4 -Forwarding Enabled | Out-Null } catch {}
        }
    }

    # 2. NAT
    $ExistingNat = Get-NetNat -Name $Config.NatName -ErrorAction SilentlyContinue
    if ($ExistingNat) { $ExistingNat | Remove-NetNat -Confirm:$false }
    
    $IPParts = $Config.LanGatewayIP.Split('.')
    $NetworkID = "$($IPParts[0]).$($IPParts[1]).$($IPParts[2]).0/$($Config.LanSubnetPrefixLength)"
    New-NetNat -Name $Config.NatName -InternalIPInterfaceAddressPrefix $NetworkID | Out-Null

    # 3. Hotspot
    return Start-HotspotWinRT -Config $Config
}

function Start-HotspotWinRT {
    param($Config)
    try {
        $NetworkInfoType = [Type]::GetType("Windows.Networking.Connectivity.NetworkInformation, Windows.Networking.Connectivity, ContentType=WindowsRuntime")
        $TetheringManagerType = [Type]::GetType("Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager, Windows.Networking.NetworkOperators, ContentType=WindowsRuntime")
        $AccessPointConfigType = [Type]::GetType("Windows.Networking.NetworkOperators.NetworkOperatorTetheringAccessPointConfiguration, Windows.Networking.NetworkOperators, ContentType=WindowsRuntime")

        $ConnectionProfile = $NetworkInfoType::GetInternetConnectionProfile()
        if (-not $ConnectionProfile) { return "No Internet to share." }

        $TetheringManager = $TetheringManagerType::CreateFromConnectionProfile($ConnectionProfile)

        if (-not [string]::IsNullOrEmpty($Config.WifiSsid)) {
            $CurrentConfig = $TetheringManager.GetCurrentAccessPointConfiguration()
            if ($CurrentConfig.Ssid -ne $Config.WifiSsid -or (-not [string]::IsNullOrEmpty($Config.WifiPassword))) {
                if ($TetheringManager.TetheringOperationalState -eq "On") {
                    Await-WinRT $TetheringManager.StopTetheringAsync()
                    Start-Sleep -Seconds 1
                }
                $NewConfig = [Activator]::CreateInstance($AccessPointConfigType)
                $NewConfig.Ssid = $Config.WifiSsid
                $NewConfig.Passphrase = $Config.WifiPassword
                Await-WinRT $TetheringManager.ConfigureAccessPointAsync($NewConfig) | Out-Null
            }
        }

        if ($TetheringManager.TetheringOperationalState -eq "Off") {
            $Result = Await-WinRT $TetheringManager.StartTetheringAsync()
            return "Hotspot Started: $($Result.Status)"
        }
        return "Hotspot already Running."
    }
    catch {
        return "Hotspot Error: $_"
    }
}

function Stop-PCRouter {
    param($ConfigPath)
    if (-not (Test-Path $ConfigPath)) { return }
    $Config = Get-Content $ConfigPath | ConvertFrom-Json
    
    # Remove NAT
    Get-NetNat -Name $Config.NatName -ErrorAction SilentlyContinue | Remove-NetNat -Confirm:$false
    
    # Stop Hotspot
    try {
        $NetworkInfoType = [Type]::GetType("Windows.Networking.Connectivity.NetworkInformation, Windows.Networking.Connectivity, ContentType=WindowsRuntime")
        $TetheringManagerType = [Type]::GetType("Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager, Windows.Networking.NetworkOperators, ContentType=WindowsRuntime")
        $ConnectionProfile = $NetworkInfoType::GetInternetConnectionProfile()
        if ($ConnectionProfile) {
            $TetheringManager = $TetheringManagerType::CreateFromConnectionProfile($ConnectionProfile)
            Await-WinRT $TetheringManager.StopTetheringAsync() | Out-Null
        }
    }
    catch {}
    
    return "Router Stopped."
}

Export-ModuleMember -Function Start-PCRouter, Stop-PCRouter
