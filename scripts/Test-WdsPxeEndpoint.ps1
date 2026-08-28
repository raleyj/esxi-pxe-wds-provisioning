<#
.SYNOPSIS
Tests whether a Windows Server WDS endpoint is ready to answer relayed PXE requests.

.DESCRIPTION
Runs locally or through PowerShell remoting. Validates the WDS role, WDSServer service,
relay-only WDS configuration, and UDP listeners used by TFTP (69) and PXE proxy DHCP (4011).
This is a service-readiness test; only a real UEFI PXE boot from a test host can validate the
full DHCP relay, switch/firewall, boot-file, and ESXi installer path.

.PARAMETER ComputerName
The WDS server name. Defaults to the local server. Remote use requires PowerShell remoting
and administrator rights on the target.

.PARAMETER RequireUnattendedPxe
Fails the test unless WDS is configured to answer all clients without an F12 prompt.

.EXAMPLE
.\Test-WdsPxeEndpoint.ps1

.EXAMPLE
.\Test-WdsPxeEndpoint.ps1 -ComputerName pxe01.jtec.local -RequireUnattendedPxe
#>
[CmdletBinding()]
param(
    [string]$ComputerName = $env:COMPUTERNAME,

    [switch]$RequireUnattendedPxe
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$testScript = {
    param([bool]$RequireUnattendedPxe)

    $checks = [System.Collections.Generic.List[object]]::new()
    $addCheck = {
        param([string]$Name, [ValidateSet('Pass', 'Fail', 'Warning')][string]$Result, [string]$Detail)
        $checks.Add([pscustomobject]@{ Check = $Name; Result = $Result; Detail = $Detail })
    }

    $wdsFeature = Get-WindowsFeature -Name 'WDS-Deployment' -ErrorAction SilentlyContinue
    if ($wdsFeature -and $wdsFeature.Installed) {
        & $addCheck 'WDS deployment role' 'Pass' 'WDS-Deployment is installed.'
    }
    else {
        & $addCheck 'WDS deployment role' 'Fail' 'WDS-Deployment is not installed.'
    }

    $service = Get-Service -Name 'WDSServer' -ErrorAction SilentlyContinue
    if ($service -and $service.Status -eq 'Running') {
        & $addCheck 'WDS service' 'Pass' 'WDSServer is running.'
    }
    elseif ($service) {
        & $addCheck 'WDS service' 'Fail' "WDSServer is $($service.Status)."
    }
    else {
        & $addCheck 'WDS service' 'Fail' 'WDSServer was not found.'
    }

    $localDhcpService = Get-Service -Name 'DHCPServer' -ErrorAction SilentlyContinue
    if ($localDhcpService -and $localDhcpService.Status -eq 'Running') {
        & $addCheck 'Local DHCP conflict' 'Fail' 'DHCPServer is running locally. Stop/remove it because DHCP is hosted by the router and WDS must bind UDP 67.'
    }
    else {
        & $addCheck 'Local DHCP conflict' 'Pass' 'No local DHCP service is running on the WDS server.'
    }

    $wdsutil = Get-Command -Name 'wdsutil.exe' -ErrorAction SilentlyContinue
    if (-not $wdsutil) {
        & $addCheck 'WDS configuration query' 'Fail' 'wdsutil.exe is unavailable. Run this test on the WDS server or specify -ComputerName for a PowerShell-remoting endpoint.'
    }
    else {
        $wdsConfiguration = (& $wdsutil.Source /Get-Server /Show:Config 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 0) {
            & $addCheck 'WDS configuration query' 'Fail' $wdsConfiguration.Trim()
        }
        else {
        & $addCheck 'WDS configuration query' 'Pass' 'wdsutil returned configuration successfully.'

        if ($wdsConfiguration -match 'Use DHCP ports:\s+Yes') {
            & $addCheck 'Separate DHCP/WDS mode' 'Pass' 'WDS listens on UDP 67 because DHCP is hosted on another device.'
        }
        else {
            & $addCheck 'Separate DHCP/WDS mode' 'Fail' 'Expected "Use DHCP ports: Yes" because DHCP is hosted on a different device.'
        }

        $dhcpFeature = Get-WindowsFeature -Name 'DHCP' -ErrorAction SilentlyContinue
        if (-not $dhcpFeature -or -not $dhcpFeature.Installed) {
            # Option 60 is owned and served by Microsoft's DHCP role.  On this dedicated WDS
            # server the DHCP role is intentionally absent and the UDM is authoritative, so a
            # legacy WDS display value is neither configurable nor relevant to PXE readiness.
            & $addCheck 'DHCP option 60' 'Pass' 'Not applicable: DHCP is hosted by the UDM Pro, not this Windows server.'
        }
        elseif ($wdsConfiguration -match 'DHCP option 60 configured:\s+No') {
            & $addCheck 'DHCP option 60' 'Pass' 'Option 60 is disabled on the WDS server.'
        }
        else {
            & $addCheck 'DHCP option 60' 'Fail' 'Option 60 must be disabled when DHCP is not hosted locally.'
        }

        # WDS reports this policy with several labels across Server releases, including
        # "Answer clients: All" and "Respond to all client computers (known and unknown)".
        $answersAllClients = $wdsConfiguration -match '(?im)^\s*Answer clients:\s*(?:All|Yes)\s*$' -or
            $wdsConfiguration -match '(?im)^\s*Respond to all client computers\s*\(known and unknown\)\s*$'
        if ($answersAllClients) {
            & $addCheck 'PXE response policy' 'Pass' 'WDS responds to all PXE clients.'
        }
        elseif ($RequireUnattendedPxe) {
            & $addCheck 'PXE response policy' 'Fail' 'Unattended PXE requires "Answer clients: All".'
        }
        else {
            & $addCheck 'PXE response policy' 'Warning' 'WDS is not configured to answer all PXE clients.'
        }

        $noPrompt = $wdsConfiguration -match 'New client PXE prompt policy:\s+NoPrompt'
        if ($RequireUnattendedPxe -and -not $noPrompt) {
            & $addCheck 'Unattended PXE prompt' 'Fail' 'New clients still require a PXE/F12 prompt.'
        }
        elseif ($noPrompt) {
            & $addCheck 'Unattended PXE prompt' 'Pass' 'New clients have no PXE/F12 prompt.'
        }
        else {
            & $addCheck 'Unattended PXE prompt' 'Warning' 'New clients require a PXE/F12 prompt.'
        }
        }
    }

    $udpPorts = @(Get-NetUDPEndpoint -ErrorAction SilentlyContinue | Select-Object -ExpandProperty LocalPort -Unique)
    foreach ($port in 67, 69, 4011) {
        if ($udpPorts -contains $port) {
            & $addCheck "UDP $port listener" 'Pass' 'A local UDP listener is present.'
        }
        else {
            & $addCheck "UDP $port listener" 'Fail' 'No local UDP listener was detected.'
        }
    }

    [pscustomobject]@{
        ComputerName = $env:COMPUTERNAME
        Checks       = $checks
    }
}

$isLocal = $ComputerName -in @('.', 'localhost', $env:COMPUTERNAME, "$env:COMPUTERNAME.$env:USERDNSDOMAIN")
if ($isLocal) {
    $result = & $testScript $RequireUnattendedPxe.IsPresent
}
else {
    $result = Invoke-Command -ComputerName $ComputerName -ScriptBlock $testScript -ArgumentList $RequireUnattendedPxe.IsPresent
}

Write-Host "WDS PXE endpoint test: $($result.ComputerName)" -ForegroundColor Cyan
$result.Checks | Format-Table -AutoSize

# Materialize the collection before filtering.  This avoids a PowerShell 7 pipeline
# enumeration quirk that could report a failure even though every displayed row passed.
$completedChecks = @($result.Checks)
$failed = @($completedChecks | Where-Object { $_.Result -eq 'Fail' })
if ($failed.Count -gt 0) {
    Write-Error "WDS PXE endpoint test failed: $($failed.Count) required check(s) failed."
    exit 1
}

Write-Host 'WDS service-readiness checks passed. Validate the remaining network path with one physical UEFI PXE boot.' -ForegroundColor Green
