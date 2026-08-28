<#
.SYNOPSIS
Enables administrative WinRM remoting for a local administrator account on tftp.jtec.local.

.DESCRIPTION
Run this script locally on the TFTP server from an elevated PowerShell session. It verifies that
the supplied local account belongs to Administrators, then sets LocalAccountTokenFilterPolicy so
the account receives a full administrative token over WinRM. It does not create users or change
their passwords.

.PARAMETER LocalUserName
Local account to validate. Defaults to Administrator.

.EXAMPLE
.\Enable-TftpLocalAccountWinRm.ps1
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string]$LocalUserName = 'Administrator'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script in an elevated PowerShell session on the TFTP server.'
}

$computerName = $env:COMPUTERNAME
$qualifiedUser = "$computerName\$LocalUserName"
$administratorMembers = @(Get-LocalGroupMember -Group 'Administrators' -ErrorAction Stop)
$isAdministrator = $administratorMembers | Where-Object {
    $_.Name -ieq $qualifiedUser -or $_.Name -ieq $LocalUserName
}

if (-not $isAdministrator) {
    throw "$qualifiedUser is not a member of the local Administrators group. Use an existing local administrator account; this script will not add accounts to Administrators automatically."
}

$policyPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
if ($PSCmdlet.ShouldProcess($computerName, "Enable full WinRM administrative token for $qualifiedUser")) {
    New-ItemProperty -Path $policyPath -Name LocalAccountTokenFilterPolicy -PropertyType DWord -Value 1 -Force | Out-Null
    Set-Service -Name WinRM -StartupType Automatic
    Restart-Service -Name WinRM
}

Write-Host "WinRM local-administrator policy enabled for $qualifiedUser." -ForegroundColor Green
Write-Host 'Rerun Get-TftpServerBootstrapInventory.ps1 from the workstation to collect the read-only inventory.' -ForegroundColor Cyan
