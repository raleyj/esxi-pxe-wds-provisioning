<#
.SYNOPSIS
Installs the Windows Server roles and features required to host an ESXi PXE/Kickstart provisioning service.

.DESCRIPTION
Installs Windows Deployment Services (PXE/TFTP), IIS static-content hosting, and their
management tools. This server is a PXE and web-content server only: it does not install the
DHCP Server role and never creates, manages, or authorizes DHCP scopes. DHCP must be served
by an existing DHCP service and relayed by the routed interface for the provisioning VLAN.

Run from an elevated PowerShell session on a dedicated provisioning server.

.PARAMETER Source
Optional path to a Windows Server feature source (for example, D:\sources\sxs) when the
server cannot retrieve feature payloads from Windows Update or a configured WSUS server.

.PARAMETER IncludeWds
Installs the Windows Deployment Services deployment and transport components.  Leave this
enabled for a Windows-native PXE/TFTP service.  Set to $false only when another PXE/TFTP
server will serve the initial iPXE bootloader.

.PARAMETER Restart
Restarts the server if Windows reports that a restart is required after role installation.

.PARAMETER Configure
Prompts for, and optionally configures, the IIS content directory and WDS initialization.
Each change is separately confirmed. It also prints the PXE relay targets for the network team.
This switch is intended for a dedicated provisioning server; do not use it on a WDS server
that is already in production.

.EXAMPLE
.\Install-EsxiPxeProvisioningPrereqs.ps1

.EXAMPLE
.\Install-EsxiPxeProvisioningPrereqs.ps1 -Source 'D:\sources\sxs' -Restart

.EXAMPLE
.\Install-EsxiPxeProvisioningPrereqs.ps1 -Configure
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$Source,

    [bool]$IncludeWds = $true,

    [switch]$Configure,

    [switch]$Restart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Install-RequiredFeature {
    param(
        [Parameter(Mandatory)]
        [string[]]$Name
    )

    $missing = Get-WindowsFeature -Name $Name | Where-Object { -not $_.Installed }
    if (-not $missing) {
        Write-Host "Already installed: $($Name -join ', ')" -ForegroundColor DarkGray
        return $null
    }

    $featureNames = @($missing.Name)
    if (-not $PSCmdlet.ShouldProcess(($featureNames -join ', '), 'Install Windows feature(s)')) {
        return $null
    }

    $parameters = @{
        Name                  = $featureNames
        IncludeManagementTools = $true
    }
    if ($Source) {
        $parameters.Source = $Source
    }

    Install-WindowsFeature @parameters
}

function Read-YesNo {
    param(
        [Parameter(Mandatory)]
        [string]$Prompt,

        [bool]$Default = $false
    )

    $suffix = if ($Default) { '[Y/n]' } else { '[y/N]' }
    do {
        $answer = Read-Host "$Prompt $suffix"
        if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    } while ($answer -notmatch '^(?i:y|yes|n|no)$')

    return $answer -match '^(?i:y|yes)$'
}

function Write-WdsDiagnostics {
    Write-Host "`nWDS diagnostic summary (most recent events)" -ForegroundColor Yellow

    Get-Service -Name 'WDSServer', 'WDSTransport' -ErrorAction SilentlyContinue |
        Select-Object Name, Status, StartType |
        Format-Table -AutoSize

    $startTime = (Get-Date).AddMinutes(-15)
    $events = @()
    $events += Get-WinEvent -FilterHashtable @{
        LogName   = 'System'
        StartTime = $startTime
    } -ErrorAction SilentlyContinue | Where-Object {
        $_.ProviderName -match 'WDS|Deployment'
    }

    $wdsLogs = Get-WinEvent -ListLog '*Deployment*' -ErrorAction SilentlyContinue |
        Where-Object { $_.IsEnabled }
    foreach ($log in $wdsLogs) {
        $events += Get-WinEvent -FilterHashtable @{
            LogName   = $log.LogName
            StartTime = $startTime
        } -MaxEvents 25 -ErrorAction SilentlyContinue
    }

    if ($events) {
        $events |
            Sort-Object TimeCreated -Descending |
            Select-Object -First 25 TimeCreated, Id, ProviderName, LevelDisplayName, Message |
            Format-List
    }
    else {
        Write-Warning 'No recent WDS event details were found. Check Event Viewer: Applications and Services Logs > Microsoft > Windows > Deployment-Services-*.'
    }
}

function Configure-ProvisioningServices {
    Write-Host "`nInteractive configuration" -ForegroundColor Cyan
    Write-Warning 'Only continue on a dedicated provisioning server. This script never configures DHCP scopes.'

    if (Read-YesNo -Prompt 'Create an IIS virtual directory for ESXi installer files and Kickstarts?' -Default $true) {
        Import-Module WebAdministration
        $contentRoot = Read-Host 'Physical content path (for example, D:\EsxiProvisioning)'
        if ([string]::IsNullOrWhiteSpace($contentRoot)) { throw 'An IIS content path is required.' }
        if (-not (Test-Path -LiteralPath $contentRoot)) {
            New-Item -ItemType Directory -Path $contentRoot -Force | Out-Null
        }

        $virtualDirectoryName = Read-Host 'IIS virtual directory name [esxi]'
        if ([string]::IsNullOrWhiteSpace($virtualDirectoryName)) { $virtualDirectoryName = 'esxi' }
        $site = 'Default Web Site'
        $existingVirtualDirectory = Get-WebVirtualDirectory -Site $site -Name $virtualDirectoryName -ErrorAction SilentlyContinue
        if ($existingVirtualDirectory) {
            Write-Warning "IIS virtual directory '$virtualDirectoryName' already exists. It was not changed."
        }
        elseif ($PSCmdlet.ShouldProcess("$site/$virtualDirectoryName", "Create IIS virtual directory pointing to $contentRoot")) {
            New-WebVirtualDirectory -Site $site -Name $virtualDirectoryName -PhysicalPath $contentRoot | Out-Null
            Write-Host "IIS path created: http://$env:COMPUTERNAME/$virtualDirectoryName/"
        }
    }

    if ($IncludeWds -and (Read-YesNo -Prompt 'Initialize WDS for PXE/TFTP on this server?' -Default $false)) {
        $remoteInstallPath = Read-Host 'WDS RemoteInstall path [D:\RemoteInstall]'
        if ([string]::IsNullOrWhiteSpace($remoteInstallPath)) { $remoteInstallPath = 'D:\RemoteInstall' }
        if (-not (Test-Path -LiteralPath $remoteInstallPath)) {
            New-Item -ItemType Directory -Path $remoteInstallPath -Force | Out-Null
        }
        if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, "Initialize WDS with RemoteInstall path $remoteInstallPath")) {
            & wdsutil.exe /Initialize-Server "/RemInst:$remoteInstallPath"
            if ($LASTEXITCODE -ne 0) {
                # 0xC1030105 (signed -1056767739) means WDS initial setup was completed earlier.
                # This is expected when the script is re-run after a prior initialization attempt.
                if ($LASTEXITCODE -eq -1056767739) {
                    Write-Warning 'WDS was already initialized; no reinitialization was performed.'
                    Write-WdsDiagnostics
                }
                else {
                    Write-Warning "WDS initialization failed with exit code $LASTEXITCODE. The event details below identify the actual WDS provider/configuration failure."
                    Write-WdsDiagnostics
                    throw "WDS initialization failed with exit code $LASTEXITCODE."
                }
            }
            else {
                Write-Host 'WDS initialized. Configure its PXE response policy and boot program next.'
            }
        }
    }

    if ($IncludeWds -and (Read-YesNo -Prompt 'Configure WDS for router-hosted DHCP and unattended PXE responses?' -Default $true)) {
        Write-Warning 'This makes WDS answer all PXE clients on VLANs that relay to it, without an F12 prompt. Use only on an isolated provisioning VLAN.'
        if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, 'Configure WDS for separate router DHCP and all PXE clients')) {
            # DHCP and WDS are on different computers. WDS must listen on UDP 67. Do not pass
            # /DhcpOption60 at all: that setting belongs to the Microsoft DHCP role and fails
            # on this deliberately DHCP-free PXE server (0xC103012B).
            & wdsutil.exe /Set-Server /UseDhcpPorts:Yes /AnswerClients:All /ResponseDelay:0
            if ($LASTEXITCODE -ne 0) { throw "Unable to set separate-DHCP WDS configuration. Exit code: $LASTEXITCODE" }
            & wdsutil.exe /Set-Server /PXEPromptPolicy /Known:NoPrompt /New:NoPrompt
            if ($LASTEXITCODE -ne 0) { throw "Unable to set unattended PXE prompt policy. Exit code: $LASTEXITCODE" }
            Write-Host 'WDS is configured for separate router DHCP and unattended PXE responses.'
        }
    }

    Write-Host @"

Router-hosted DHCP design:
  * DHCP leases, reservations, gateway, and DNS remain on your existing DHCP service.
  * For the dedicated UEFI x64 provisioning VLAN, configure the router's Network Boot settings:
      option 66 = this WDS/TFTP server IP; option 67 = Boot\x64\ipxe.efi.
  * Do not configure options 66/67 globally in a mixed UEFI/BIOS environment.
"@
}

if (-not (Test-IsAdministrator)) {
    throw 'Run this script from an elevated PowerShell session (Run as administrator).'
}

if (-not (Get-Command -Name Get-WindowsFeature -ErrorAction SilentlyContinue)) {
    throw 'Get-WindowsFeature is unavailable. Run this on Windows Server, not a Windows client OS.'
}

$os = Get-CimInstance -ClassName Win32_OperatingSystem
if ($os.Caption -notmatch 'Windows Server') {
    throw "This script supports Windows Server only. Detected: $($os.Caption)"
}

Write-Host "Installing ESXi PXE/Kickstart provisioning prerequisites on $env:COMPUTERNAME ($($os.Caption))." -ForegroundColor Cyan

$results = @()

# IIS serves the extracted ESXi installer tree, iPXE scripts, and Kickstart files over HTTP/HTTPS.
$results += Install-RequiredFeature -Name @(
    'Web-Server',
    'Web-Default-Doc',
    'Web-Static-Content',
    'Web-Http-Errors',
    'Web-Http-Logging',
    'Web-Request-Monitor',
    'Web-Filtering',
    'Web-Mgmt-Console'
)

if ($IncludeWds) {
    # WDS provides the initial PXE/TFTP service. Its PXE policy is intentionally not configured here.
    $results += Install-RequiredFeature -Name @('WDS-Deployment', 'WDS-Transport')
}

$installed = Get-WindowsFeature -Name @(
    'Web-Server', 'Web-Default-Doc', 'Web-Static-Content',
    'Web-Http-Errors', 'Web-Http-Logging', 'Web-Request-Monitor', 'Web-Filtering',
    'Web-Mgmt-Console', 'WDS-Deployment', 'WDS-Transport'
) -ErrorAction SilentlyContinue |
    Select-Object Name, DisplayName, Installed

Write-Host "`nInstalled feature status:" -ForegroundColor Cyan
$installed | Format-Table -AutoSize

$restartNeeded = @($results | Where-Object { $_ -and $_.RestartNeeded -eq 'Yes' }).Count -gt 0

Write-Host @"

Prerequisites are installed. Next steps (not performed by this script):
  1. Configure the routed provisioning VLAN to relay DHCP/PXE traffic to the authoritative DHCP
     server and this WDS/PXE server. This server does not host or manage the DHCP scope.
  2. Initialize WDS and set its PXE response policy; ensure it does not conflict with another PXE service.
  3. Create an IIS content root for the validated ESXi image, iPXE scripts, and per-host Kickstarts.
  4. Configure architecture-aware boot handling (UEFI x64 versus legacy BIOS) and test one host.
  5. Restrict access to Kickstart files and use password hashes, never clear-text credentials.
"@

if ($Configure) {
    Configure-ProvisioningServices
}

if ($restartNeeded) {
    Write-Warning 'Windows reports that a restart is required before all role services are ready.'
    if ($Restart) {
        if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, 'Restart Windows Server')) {
            Restart-Computer -Force
        }
    }
    else {
        Write-Host 'Rerun with -Restart to restart automatically, or restart during your maintenance window.' -ForegroundColor Yellow
    }
}
