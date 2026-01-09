<#
.SYNOPSIS
    Configures Windows as a Router with NAT for Ethernet LAN and Wi-Fi Hotspot.
    
.DESCRIPTION
    This script performs the following:
    1. Reads configuration from config.json.
    2. Configures Static IP for specified LAN Ethernet interfaces.
    3. Creates a NAT object using New-NetNat for the LAN subnet.
    4. Attempts to start the built-in Windows Mobile Hotspot for Wi-Fi sharing.
    
.NOTES
    Run as Administrator.
#>

$ScriptPath = $PSScriptRoot
$ConfigPath = Join-Path $ScriptPath "config.json"

if (-not (Test-Path $ConfigPath)) {
    Write-Error "Config file not found at $ConfigPath"
    exit 1
}

$Config = Get-Content $ConfigPath | ConvertFrom-Json

# --- 1. Configure Wired LAN Interfaces ---
Write-Host "Configuring Wired LAN Interfaces..." -ForegroundColor Cyan

foreach ($InterfaceName in $Config.LanInterfaces) {
    $Adapter = Get-NetAdapter -Name $InterfaceName -ErrorAction SilentlyContinue
    if ($Adapter) {
        Write-Host "Found adapter: $($Adapter.Name)"
        
        # Check if IP is already set
        $CurrentIP = Get-NetIPAddress -InterfaceAlias $InterfaceName -AddressFamily IPv4 -ErrorAction SilentlyContinue
        
        if ($CurrentIP.IPAddress -eq $Config.LanGatewayIP) {
            Write-Host "IP Address already set to $($Config.LanGatewayIP)"
        }
        else {
            Write-Host "Setting IP Address to $($Config.LanGatewayIP)..."
            # Remove existing IPs to avoid conflict
            Remove-NetIPAddress -InterfaceAlias $InterfaceName -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
            
            # New IP
            New-NetIPAddress -InterfaceAlias $InterfaceName `
                -IPAddress $Config.LanGatewayIP `
                -PrefixLength $Config.LanSubnetPrefixLength `
                -AddressFamily IPv4 | Out-Null
        }
        
        # Enable IP Forwarding on this interface
        try {
            Set-NetIPInterface -InterfaceAlias $InterfaceName -AddressFamily IPv4 -Forwarding Enabled | Out-Null
            Write-Host "Enabled IP Forwarding on $InterfaceName"
        }
        catch {
            Write-Warning "Failed to enable forwarding on $InterfaceName"
        }
    }
    else {
        # Only warn if list is not empty
        if (-not [string]::IsNullOrEmpty($InterfaceName)) {
            Write-Warning "Interface '$InterfaceName' not found. Skipping."
        }
    }
}

# --- 2. Configure NAT (Network Address Translation) ---
Write-Host "Configuring NAT..." -ForegroundColor Cyan

# Remove existing NAT if exists to ensure clean state or update
$ExistingNat = Get-NetNat -Name $Config.NatName -ErrorAction SilentlyContinue
if ($ExistingNat) {
    Write-Host "Removing existing NAT: $($ExistingNat.Name)"
    $ExistingNat | Remove-NetNat -Confirm:$false
}

# Calculate Subnet (Simple assumption based on /24 for now, can be improved)
# If Gateway is 192.168.50.1/24, Network is 192.168.50.0/24
$IPParts = $Config.LanGatewayIP.Split('.')
$NetworkID = "$($IPParts[0]).$($IPParts[1]).$($IPParts[2]).0/$($Config.LanSubnetPrefixLength)"

Write-Host "Creating NAT '$($Config.NatName)' for Subnet $NetworkID"
try {
    New-NetNat -Name $Config.NatName -InternalIPInterfaceAddressPrefix $NetworkID | Out-Null
    Write-Host "NAT Configured Successfully." -ForegroundColor Green
}
catch {
    Write-Error "Failed to create NAT. Error: $_"
}

# Helper to await WinRT Async Operations
function Await-WinRT {
    param($AsyncObj)
    
    if ($null -eq $AsyncObj) { return $null }
    
    # Wait loop
    while ($AsyncObj.Status -eq "Started") {
        Start-Sleep -Milliseconds 100
    }
    
    if ($AsyncObj.Status -eq "Completed") {
        # Try to get results if available (IAsyncOperation)
        # Note: GetResults might not exist on all IAsyncAction types, need careful check
        # But for StartTetheringAsync it returns TetheringOperationResult
        
        # Use reflection to avoid "Method not found" on ComObject if direct call fails
        try {
            return $AsyncObj.GetResults()
        }
        catch {
            return $null # Void return or error accessing result
        }
    }
    elseif ($AsyncObj.Status -eq "Error") {
        throw "Async Operation Failed. ErrorCode: $($AsyncObj.ErrorCode)"
    }
    
    return $null
}

# --- 3. Enable Mobile Hotspot (Wi-Fi) ---
Write-Host "Attempting to start Mobile Hotspot (WinRT via PowerShell)..." -ForegroundColor Cyan

try {
    # Load WinRT Types directly using Type.GetType
    $NetworkInfoType = [Type]::GetType("Windows.Networking.Connectivity.NetworkInformation, Windows.Networking.Connectivity, ContentType=WindowsRuntime")
    $TetheringManagerType = [Type]::GetType("Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager, Windows.Networking.NetworkOperators, ContentType=WindowsRuntime")
    $AccessPointConfigType = [Type]::GetType("Windows.Networking.NetworkOperators.NetworkOperatorTetheringAccessPointConfiguration, Windows.Networking.NetworkOperators, ContentType=WindowsRuntime")
    
    if (-not $TetheringManagerType) {
        throw "Could not load WinRT Tethering Types. This feature requires Windows 10/11."
    }

    # Get Connection Profile
    $ConnectionProfile = $NetworkInfoType::GetInternetConnectionProfile()
    if (-not $ConnectionProfile) {
        throw "No Internet Connection Profile found to share."
    }

    # Create Tethering Manager
    $TetheringManager = $TetheringManagerType::CreateFromConnectionProfile($ConnectionProfile)
    
    # Configure SSID/Pass if needed
    if (-not [string]::IsNullOrEmpty($Config.WifiSsid)) {
        $CurrentConfig = $TetheringManager.GetCurrentAccessPointConfiguration()
        $ConfigChanged = $false

        if ($CurrentConfig.Ssid -ne $Config.WifiSsid -or (-not [string]::IsNullOrEmpty($Config.WifiPassword))) {
            $ConfigChanged = $true
            Write-Host "Applying new Hotspot Configuration: SSID=$($Config.WifiSsid)"
        }

        if ($ConfigChanged) {
            # Stop first if running
            if ($TetheringManager.TetheringOperationalState -eq "On") {
                $AsyncOp = $TetheringManager.StopTetheringAsync()
                Await-WinRT $AsyncOp | Out-Null
                Start-Sleep -Seconds 2
            }

            $NewConfig = [Activator]::CreateInstance($AccessPointConfigType)
            $NewConfig.Ssid = $Config.WifiSsid
            $NewConfig.Passphrase = $Config.WifiPassword
             
            # Apply Config
            $AsyncOp = $TetheringManager.ConfigureAccessPointAsync($NewConfig)
            Await-WinRT $AsyncOp | Out-Null
        }
    }

    # Start Tethering
    if ($TetheringManager.TetheringOperationalState -eq "Off") {
        Write-Host "Starting Hotspot..."
        $AsyncOp = $TetheringManager.StartTetheringAsync()
        $Result = Await-WinRT $AsyncOp
        
        if ($Result) {
            Write-Host "Hotspot Start Result: $($Result.Status)" -ForegroundColor Yellow
            if ($Result.Status -ne "Success") {
                Write-Warning "Error Message: $($Result.AdditionalErrorMessage)"
            }
        }
        else {
            Write-Host "Hotspot signal sent (Async completed)." -ForegroundColor Yellow
        }
    }
    else {
        Write-Host "Hotspot is already ON." -ForegroundColor Green
    }

}
catch {
    Write-Warning "Failed to manage Hotspot via WinRT Interop."
    Write-Warning "Error details: $_"
}

Write-Host "PC Router Configuration Cycle Completed." -ForegroundColor Green
