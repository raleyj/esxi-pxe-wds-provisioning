<#
.SYNOPSIS
Validates every installer module referenced by a host-specific ESXi boot.cfg.

.DESCRIPTION
Run on the IIS/WDS server.  The script reads the prefix, kernel, and modules
entries from the selected host's boot.cfg and checks the corresponding HTTP URL
for each file.  It makes no changes.
#>
[CmdletBinding()]
param(
    [ValidateSet('mgmt1','mgmt2','mgmt3','mgmt4','wkld1','wkld2','wkld3')]
    [string]$HostName = 'mgmt1',

    [string]$ContentRoot = 'D:\ESXiProvisioning'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$bootCfgPath = Join-Path $ContentRoot "hosts\$HostName\boot.cfg"
if (-not (Test-Path -LiteralPath $bootCfgPath)) {
    throw "Host boot configuration not found: $bootCfgPath"
}

$lines = Get-Content -LiteralPath $bootCfgPath
$prefix = (($lines | Where-Object { $_ -match '^prefix=' } | Select-Object -First 1) -replace '^prefix=', '').Trim()
if ([string]::IsNullOrWhiteSpace($prefix)) {
    throw "No prefix= line found in $bootCfgPath"
}
if (-not $prefix.EndsWith('/')) {
    throw "The prefix must end in '/': $prefix"
}

$files = [System.Collections.Generic.List[string]]::new()
foreach ($line in $lines) {
    if ($line -match '^(kernel|modules)=(.*)$') {
        foreach ($token in ($matches[2] -split '\s+')) {
            if ($token -and $token -ne '---' -and $token -match '^/?[A-Za-z0-9_.-]+$') {
                $files.Add($token.TrimStart('/'))
            }
        }
    }
}

$uniqueFiles = @($files | Select-Object -Unique)
if ($uniqueFiles.Count -eq 0) {
    throw "No kernel= or modules= entries were found in $bootCfgPath. Copy the complete boot.cfg from the extracted ESXi image, then change only prefix= and kernelopt=."
}

$results = $uniqueFiles | ForEach-Object {
    $uri = "$($prefix)$_"
    try {
        $response = Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec 20
        [pscustomobject]@{ Result = 'Pass'; StatusCode = $response.StatusCode; File = $_; Uri = $uri }
    }
    catch {
        $statusCode = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { $null }
        [pscustomobject]@{ Result = 'Fail'; StatusCode = $statusCode; File = $_; Uri = $uri }
    }
}

$results
