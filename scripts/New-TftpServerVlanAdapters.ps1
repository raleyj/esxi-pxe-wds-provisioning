<#
.SYNOPSIS
Creates VLAN 105 management and VLAN 1001 PXE/TFTP adapters on a physical Windows Server 2022 host.

.DESCRIPTION
Creates an external Hyper-V switch on one physical NIC, then creates management-OS adapters
tagged for VLAN 105 and VLAN 1001. It prompts for static IP settings and restarts WDS when
present. Run only from the physical console, iDRAC/iLO, or another out-of-band session: creating
the external switch temporarily disconnects the selected physical NIC.

The upstream UniFi port must be a trunk allowing tagged VLANs 105 and 1001.

.PARAMETER PhysicalAdapterName
The physical NIC to convert to the Hyper-V external switch uplink. If omitted, the script lists
eligible adapters and prompts for one.

.PARAMETER InstallHyperV
Installs the Hyper-V role if absent. A restart may be required; rerun the script after restarting.

.PARAMETER ConfigPath
Optional JSON server profile. When supplied, its adapter and addressing values are used as the
defaults for the interactive prompts.

.EXAMPLE
.\New-TftpServerVlanAdapters.ps1

.EXAMPLE
.\New-TftpServerVlanAdapters.ps1 -PhysicalAdapterName 'NIC 1' -InstallHyperV

.EXAMPLE
.\New-TftpServerVlanAdapters.ps1 -ConfigPath .\tftp.jtec.local-network.json -InstallHyperV
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string]$PhysicalAdapterName,

    [switch]$InstallHyperV,

    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$switchName = 'TFTP-Trunk'
$managementAdapterName = 'Management-VLAN105'
$pxeAdapterName = 'PXE-TFTP-VLAN1001'

$serverProfile = $null
if ($ConfigPath) {
    $serverProfile = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json
    if (-not $PhysicalAdapterName) { $PhysicalAdapterName = $serverProfile.PhysicalAdapterName }
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Read-RequiredValue {
    param([Parameter(Mandatory)][string]$Prompt, [string]$Default)
    do {
        $message = if ($Default) { "$Prompt [$Default]" } else { $Prompt }
        $value = Read-Host $message
        if ([string]::IsNullOrWhiteSpace($value)) { $value = $Default }
        if ([string]::IsNullOrWhiteSpace($value)) { Write-Warning 'A value is required.' }
    } while ([string]::IsNullOrWhiteSpace($value))
    $value.Trim()
}

function Read-IPv4Address {
    param([Parameter(Mandatory)][string]$Prompt, [string]$Default)
    do {
        $value = Read-RequiredValue -Prompt $Prompt -Default $Default
        $address = $null
        $valid = [System.Net.IPAddress]::TryParse($value, [ref]$address) -and
            $address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork
        if (-not $valid) { Write-Warning 'Enter a valid IPv4 address.' }
    } while (-not $valid)
    $value
}

function Read-PrefixLength {
    param([Parameter(Mandatory)][string]$Prompt, [int]$Default = 24)
    $prefix = 0
    do {
        $value = Read-RequiredValue -Prompt $Prompt -Default $Default
        $valid = [int]::TryParse($value, [ref]$prefix) -and $prefix -ge 1 -and $prefix -le 32
        if (-not $valid) { Write-Warning 'Enter a prefix length from 1 through 32.' }
    } while (-not $valid)
    $prefix
}

function Read-DnsServers {
    param([Parameter(Mandatory)][string]$Prompt, [string]$Default)
    $servers = @((Read-RequiredValue -Prompt $Prompt -Default $Default).Split(',').Trim() | Where-Object { $_ })
    foreach ($server in $servers) {
        $address = $null
        if (-not ([System.Net.IPAddress]::TryParse($server, [ref]$address) -and $address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork)) {
            throw "Invalid DNS IPv4 address: $server"
        }
    }
    $servers
}

function Set-StaticAdapterIPv4 {
    param(
        [Parameter(Mandatory)][string]$InterfaceAlias,
        [Parameter(Mandatory)][string]$IPAddress,
        [Parameter(Mandatory)][int]$PrefixLength,
        [string]$Gateway,
        [Parameter(Mandatory)][string[]]$DnsServers
    )

    $existing = @(Get-NetIPAddress -InterfaceAlias $InterfaceAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '169.254.*' })
    $matchesTarget = $existing | Where-Object { $_.IPAddress -eq $IPAddress -and $_.PrefixLength -eq $PrefixLength }
    if ($existing.Count -gt 0 -and -not $matchesTarget) {
        Write-Warning "Existing IPv4 configuration on '$InterfaceAlias' will be replaced: $($existing.IPAddress -join ', ')."
        $confirm = Read-Host "Type REPLACE to continue configuring $InterfaceAlias"
        if ($confirm -ne 'REPLACE') { throw "Network configuration cancelled for $InterfaceAlias." }
        $existing | Remove-NetIPAddress -Confirm:$false
    }

    Set-NetIPInterface -InterfaceAlias $InterfaceAlias -AddressFamily IPv4 -Dhcp Disabled
    if (-not $matchesTarget) {
        New-NetIPAddress -InterfaceAlias $InterfaceAlias -IPAddress $IPAddress -PrefixLength $PrefixLength | Out-Null
    }

    Get-NetRoute -InterfaceAlias $InterfaceAlias -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
    if ($Gateway) {
        New-NetRoute -InterfaceAlias $InterfaceAlias -DestinationPrefix '0.0.0.0/0' -NextHop $Gateway | Out-Null
    }
    Set-DnsClientServerAddress -InterfaceAlias $InterfaceAlias -ServerAddresses $DnsServers
}

if (-not (Test-IsAdministrator)) {
    throw 'Run this script from an elevated PowerShell session.'
}

Write-Warning 'Use a physical console or out-of-band session. This operation briefly disrupts the selected NIC and can disconnect a remote PowerShell/RDP session.'

$localDhcp = Get-Service -Name DHCPServer -ErrorAction SilentlyContinue
if ($localDhcp -and $localDhcp.Status -eq 'Running') {
    Write-Warning 'DHCPServer is running locally. DHCP is hosted by the UDM Pro, so this service must be stopped for WDS to bind the PXE/DHCP port correctly.'
    $disableDhcp = Read-Host 'Type DISABLE to stop and disable the local Windows DHCP service'
    if ($disableDhcp -ne 'DISABLE') { throw 'Local DHCP service is still running; no VLAN changes were made.' }
    Stop-Service -Name DHCPServer
    Set-Service -Name DHCPServer -StartupType Disabled
}

$hyperV = Get-WindowsFeature -Name Hyper-V
if (-not $hyperV.Installed) {
    if (-not $InstallHyperV) {
        throw 'The Hyper-V role is not installed. Rerun with -InstallHyperV, restart if requested, and then rerun this script.'
    }
    if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, 'Install Hyper-V role and management tools')) {
        $result = Install-WindowsFeature -Name Hyper-V -IncludeManagementTools
        if ($result.RestartNeeded -eq 'Yes') {
            Write-Warning 'Hyper-V requires a restart. Restart the server, then rerun this script from the physical console.'
            return
        }
    }
}

if (-not $PhysicalAdapterName) {
    Write-Host "`nEligible physical adapters:" -ForegroundColor Cyan
    Get-NetAdapter -Physical | Where-Object Status -eq 'Up' |
        Select-Object Name, InterfaceDescription, LinkSpeed, MacAddress | Format-Table -AutoSize
    $PhysicalAdapterName = Read-RequiredValue -Prompt 'Exact physical adapter name to use as the trunk uplink'
}

$physicalAdapter = Get-NetAdapter -Name $PhysicalAdapterName -Physical -ErrorAction Stop
if ($physicalAdapter.Status -ne 'Up') {
    throw "Physical adapter '$PhysicalAdapterName' is not Up. Connect it to the UniFi trunk port first."
}

$managementIpDefault = if ($serverProfile) { $serverProfile.Management.IPv4Address } else { '' }
$managementPrefixDefault = if ($serverProfile) { [int]$serverProfile.Management.PrefixLength } else { 24 }
$managementGatewayDefault = if ($serverProfile) { $serverProfile.Management.GatewayIPv4 } else { '' }
$managementDnsDefault = if ($serverProfile) { $serverProfile.Management.DnsServers -join ',' } else { '' }
$pxeIpDefault = if ($serverProfile) { $serverProfile.PxeTftp.IPv4Address } else { '' }
$pxePrefixDefault = if ($serverProfile) { [int]$serverProfile.PxeTftp.PrefixLength } else { 24 }
$pxeDnsDefault = if ($serverProfile) { $serverProfile.PxeTftp.DnsServers -join ',' } else { '' }

$managementIp = Read-IPv4Address -Prompt 'Management VLAN 105 IPv4 address' -Default $managementIpDefault
$managementPrefix = Read-PrefixLength -Prompt 'Management VLAN 105 prefix length' -Default $managementPrefixDefault
$managementGateway = Read-IPv4Address -Prompt 'Management VLAN 105 default gateway' -Default $managementGatewayDefault
$managementDns = Read-DnsServers -Prompt 'Management DNS IPv4 addresses, comma-separated' -Default $managementDnsDefault

$pxeIp = Read-IPv4Address -Prompt 'PXE/TFTP VLAN 1001 IPv4 address' -Default $pxeIpDefault
$pxePrefix = Read-PrefixLength -Prompt 'PXE/TFTP VLAN 1001 prefix length' -Default $pxePrefixDefault
$pxeDns = Read-DnsServers -Prompt 'PXE/TFTP DNS IPv4 addresses, comma-separated' -Default $pxeDnsDefault

Write-Host @"

Planned configuration
  Physical uplink: $PhysicalAdapterName
  Hyper-V switch:  $switchName
  Management:      VLAN 105, $managementIp/$managementPrefix, gateway $managementGateway
  PXE/TFTP:        VLAN 1001, $pxeIp/$pxePrefix, no default gateway
"@ -ForegroundColor Cyan

$approval = Read-Host 'Type APPLY to create the VLAN adapters and set addressing'
if ($approval -ne 'APPLY') {
    throw 'No changes were made.'
}

$existingSwitch = Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue
if (-not $existingSwitch) {
    if ($PSCmdlet.ShouldProcess($PhysicalAdapterName, "Create external Hyper-V switch '$switchName'")) {
        New-VMSwitch -Name $switchName -NetAdapterName $PhysicalAdapterName -AllowManagementOS $true | Out-Null
    }
}
elseif ($existingSwitch.SwitchType -ne 'External') {
    throw "A non-external switch named '$switchName' already exists. Rename it or modify the script before continuing."
}

$managementAdapter = Get-VMNetworkAdapter -ManagementOS -Name $switchName -ErrorAction SilentlyContinue
if ($managementAdapter -and $managementAdapter.Name -ne $managementAdapterName) {
    Rename-VMNetworkAdapter -ManagementOS -Name $managementAdapter.Name -NewName $managementAdapterName
}
elseif (-not (Get-VMNetworkAdapter -ManagementOS -Name $managementAdapterName -ErrorAction SilentlyContinue)) {
    throw "The management adapter for '$switchName' was not found. Verify the external switch creation before rerunning."
}

if (-not (Get-VMNetworkAdapter -ManagementOS -Name $pxeAdapterName -ErrorAction SilentlyContinue)) {
    Add-VMNetworkAdapter -ManagementOS -SwitchName $switchName -Name $pxeAdapterName | Out-Null
}

Set-VMNetworkAdapterVlan -ManagementOS -VMNetworkAdapterName $managementAdapterName -Access -VlanId 105
Set-VMNetworkAdapterVlan -ManagementOS -VMNetworkAdapterName $pxeAdapterName -Access -VlanId 1001

Set-StaticAdapterIPv4 -InterfaceAlias "vEthernet ($managementAdapterName)" -IPAddress $managementIp -PrefixLength $managementPrefix -Gateway $managementGateway -DnsServers $managementDns
Set-StaticAdapterIPv4 -InterfaceAlias "vEthernet ($pxeAdapterName)" -IPAddress $pxeIp -PrefixLength $pxePrefix -DnsServers $pxeDns

$wdsService = Get-Service -Name WDSServer -ErrorAction SilentlyContinue
if ($wdsService) {
    Restart-Service -Name WDSServer
}

Write-Host "`nVLAN adapter configuration complete:" -ForegroundColor Green
Get-NetIPAddress -InterfaceAlias "vEthernet ($managementAdapterName)", "vEthernet ($pxeAdapterName)" -AddressFamily IPv4 |
    Select-Object InterfaceAlias, IPAddress, PrefixLength | Format-Table -AutoSize
Get-VMNetworkAdapterVlan -ManagementOS -VMNetworkAdapterName $managementAdapterName, $pxeAdapterName |
    Format-Table -AutoSize
