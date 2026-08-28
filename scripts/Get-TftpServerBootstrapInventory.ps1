<#
.SYNOPSIS
Collects a read-only PXE/WDS readiness inventory from tftp.jtec.local.

.DESCRIPTION
Prompts locally for a credential, connects to the target over WinRM, and writes a JSON report.
The password is never saved or written to the report. Run this from the workstation where the
Codex workspace is located, not from the TFTP server.

.PARAMETER ComputerName
Target Windows Server. Defaults to tftp.jtec.local.

.PARAMETER OutputPath
Location of the JSON report. Defaults to tftp.jtec.local-inventory.json in the current directory.

.PARAMETER TrustHttpWinRM
Adds the target FQDN to this workstation's WinRM TrustedHosts list. Use only on a trusted LAN
when connecting with a local account over HTTP WinRM. The setting is not needed when HTTPS WinRM
is configured with a trusted certificate.

.EXAMPLE
.\Get-TftpServerBootstrapInventory.ps1

.EXAMPLE
.\Get-TftpServerBootstrapInventory.ps1 -TrustHttpWinRM
#>
[CmdletBinding()]
param(
    [string]$ComputerName = 'tftp.jtec.local',

    [string]$OutputPath = (Join-Path (Get-Location) 'tftp.jtec.local-inventory.json'),

    [switch]$TrustHttpWinRM
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$username = Read-Host 'Enter the local account as TFTP-SERVER-NETBIOS\username'
if ([string]::IsNullOrWhiteSpace($username)) {
    throw 'A local-account username is required.'
}

# A bare name is ambiguous from a non-domain client. Qualify it explicitly as a local account
# on the target server (for example, TFTP\administrator).
if ($username -notmatch '[\\@]') {
    $serverNetBiosName = $ComputerName.Split('.')[0]
    $username = "$serverNetBiosName\$username"
}
Write-Host "Using remote local account: $username" -ForegroundColor Cyan

$credential = Get-Credential -UserName $username -Message "Credential for $ComputerName"

if ($TrustHttpWinRM) {
    # Do not rely on WSMan: or winrm.exe: both can be unavailable when the local WinRM
    # service is disabled. This is the WinRM client's documented TrustedHosts registry value.
    $clientRegistryPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WSMAN\Client'
    if (-not (Test-Path -LiteralPath $clientRegistryPath)) {
        New-Item -Path $clientRegistryPath -Force | Out-Null
    }
    $clientRegistryValues = Get-ItemProperty -Path $clientRegistryPath -ErrorAction SilentlyContinue
    $trustedHostsProperty = $clientRegistryValues.PSObject.Properties['trusted_hosts']
    if ($null -ne $trustedHostsProperty) {
        $currentTrustedHosts = [string]$trustedHostsProperty.Value
    }
    else {
        $currentTrustedHosts = ''
    }
    $trustedHosts = @($currentTrustedHosts -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

    if ($trustedHosts -notcontains '*' -and $trustedHosts -notcontains $ComputerName) {
        $newTrustedHosts = ($trustedHosts + $ComputerName) -join ','
        Write-Warning "Adding $ComputerName to this workstation's WinRM TrustedHosts list for local-account authentication over HTTP."
        New-ItemProperty -Path $clientRegistryPath -Name trusted_hosts -PropertyType String -Value $newTrustedHosts -Force | Out-Null
    }
}

$inventory = Invoke-Command -ComputerName $ComputerName -Credential $credential -Authentication Negotiate -ScriptBlock {
    function Invoke-Optional {
        param([scriptblock]$Script)
        try { & $Script } catch { "ERROR: $($_.Exception.Message)" }
    }

    $udpListeners = Get-NetUDPEndpoint -ErrorAction SilentlyContinue |
        Where-Object { $_.LocalPort -in 67, 69, 4011 } |
        ForEach-Object {
            $process = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
            $processName = if ($process) { $process.ProcessName } else { 'Unknown' }
            [pscustomobject]@{
                LocalAddress = $_.LocalAddress
                LocalPort = $_.LocalPort
                OwningProcess = $_.OwningProcess
                ProcessName = $processName
            }
        }

    $websites = if (Get-Command Get-Website -ErrorAction SilentlyContinue) {
        Get-Website | Select-Object Name, State, PhysicalPath, Bindings
    }
    else {
        'IIS cmdlets are unavailable.'
    }

    [pscustomobject]@{
        CollectedAt = (Get-Date).ToString('o')
        ComputerName = $env:COMPUTERNAME
        OperatingSystem = Get-CimInstance Win32_OperatingSystem |
            Select-Object Caption, Version, BuildNumber, LastBootUpTime
        Features = Get-WindowsFeature -Name Hyper-V, WDS-Deployment, WDS-Transport, Web-Server, DHCP |
            Select-Object Name, DisplayName, Installed
        Services = Get-Service -Name WDSServer, DHCPServer, W3SVC -ErrorAction SilentlyContinue |
            Select-Object Name, Status, StartType
        PhysicalAdapters = Get-NetAdapter -Physical |
            Select-Object Name, InterfaceDescription, Status, LinkSpeed, MacAddress, ifIndex
        AllAdapters = Get-NetAdapter |
            Select-Object Name, InterfaceDescription, Status, LinkSpeed, MacAddress, ifIndex
        IPv4Addresses = Get-NetIPAddress -AddressFamily IPv4 |
            Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
            Select-Object InterfaceAlias, IPAddress, PrefixLength, AddressState
        DefaultRoutes = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' |
            Select-Object InterfaceAlias, NextHop, RouteMetric
        DnsServers = Get-DnsClientServerAddress -AddressFamily IPv4 |
            Where-Object { $_.ServerAddresses } |
            Select-Object InterfaceAlias, ServerAddresses
        HyperVSwitches = Invoke-Optional { Get-VMSwitch | Select-Object Name, SwitchType, NetAdapterInterfaceDescription }
        HyperVManagementVlans = Invoke-Optional {
            Get-VMNetworkAdapterVlan -ManagementOS |
                Select-Object VMNetworkAdapterName, OperationMode, AccessVlanId, NativeVlanId, AllowedVlanIdList
        }
        WdsConfiguration = Invoke-Optional { (& wdsutil.exe /Get-Server /Show:Config 2>&1 | Out-String).Trim() }
        UdpListeners = $udpListeners
        IISWebsites = $websites
        FirewallRules = Invoke-Optional {
            Get-NetFirewallRule -Enabled True |
                Where-Object { $_.DisplayName -match 'Windows Deployment|WDS|World Wide Web|IIS' } |
                Select-Object DisplayName, Direction, Action, Profile
        }
    }
}

$outputDirectory = Split-Path -Parent $OutputPath
if ($outputDirectory -and -not (Test-Path -LiteralPath $outputDirectory)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}

$inventory | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
Write-Host "Inventory saved to: $OutputPath" -ForegroundColor Green
Write-Host 'Attach this JSON file to the Codex task. It contains no password, but does contain internal network details.' -ForegroundColor Yellow
