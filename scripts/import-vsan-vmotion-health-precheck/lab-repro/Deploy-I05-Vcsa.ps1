# i05: deploy VCSA 9.1.1 tiny directly onto the nested host vcf-i05-esx01 (=> vCenter VM is co-located).
#   Needs $env:ESXPASS (nested root) and $env:VCPASS (new vCenter root / SSO admin).
#   VCSA ISO must be mounted (default G:\, from E:\9.1\VMware-VCSA-all-9.1.1.0.25712839.iso).
#   .\Deploy-I05-Vcsa.ps1 -DryRun   # find datastore on the nested host + vcsa-deploy --verify-template-only
param([switch]$DryRun, [string]$IsoDrive = 'G:')
$ErrorActionPreference = 'Stop'
$ESXPass = $env:ESXPASS; $VCPass = $env:VCPASS
if (-not $ESXPass -or -not $VCPass) { throw 'set $env:ESXPASS and $env:VCPASS' }
$Here = $PSScriptRoot
$Deploy = Join-Path $IsoDrive 'vcsa-cli-installer\win32\vcsa-deploy.exe'
$Manifest = Join-Path $IsoDrive 'iso-manifest.json'
$EsxHost = 'vcf-i05-esx01.home.lab'
$Scratch = Join-Path $env:TEMP 'i05-vcsa'
$LogFile = Join-Path $Here 'deploy-vcsa.log'
function Log($m) { "[{0}] {1}" -f (Get-Date -Format 'MM-dd HH:mm:ss'), $m | Tee-Object -Append $LogFile }

if (-not (Test-Path $Deploy)) { throw "vcsa-deploy not found at $Deploy (mount the VCSA 9.1.1 ISO)" }
if ((Get-Content $Manifest -Raw) -notmatch '9\.1\.1\.0\.25712839') { throw "ISO on $IsoDrive is not VCSA 9.1.1.0.25712839" }
$dns = Resolve-DnsName 'vcf-i05-vc01.home.lab' -Server 10.0.0.200 -ErrorAction SilentlyContinue
if (-not $dns -or $dns.IPAddress -ne '10.0.1.186') {
    if ($DryRun) { Log 'WARN DNS vcf-i05-vc01.home.lab not in place yet (ok for DryRun)' } else { throw 'DNS vcf-i05-vc01.home.lab must resolve to 10.0.1.186 first' }
}

# datastore name on the nested host (appliance OVA creates a local VMFS when createvmfs=true)
$PCLI = '13.5.1.25718932'; 'Sdk', 'Core' | ForEach-Object { Import-Module "VMware.VimAutomation.$_" -RequiredVersion $PCLI | Out-Null }
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -ParticipateInCEIP $false -DefaultVIServerMode Single -Confirm:$false -Scope Session | Out-Null
$dsName = $null
try {
    $esx = Connect-VIServer $EsxHost -User root -Password $ESXPass -Force -WarningAction SilentlyContinue -ErrorAction Stop
}
catch {
    if (-not $DryRun) { throw }
    Log "WARN nested host $EsxHost not reachable yet (ok for DryRun) - template check uses datastore1"
    $dsName = 'datastore1'
}
if ($esx) {
    try {
        $ds = Get-Datastore | Where-Object { $_.Type -eq 'VMFS' } | Sort-Object FreeSpaceGB -Descending | Select-Object -First 1
        $pg = Get-VirtualPortGroup -Standard -Name 'VM Network' -ErrorAction SilentlyContinue
        if (-not $ds) { throw 'no VMFS datastore on nested host' }
        Log ("nested datastore {0} free {1:N0} GB; 'VM Network' present: {2}" -f $ds.Name, $ds.FreeSpaceGB, [bool]$pg)
        $dsName = $ds.Name
        if (Get-VM -Name 'vcf-i05-vc01' -ErrorAction SilentlyContinue) { Log 'vcf-i05-vc01 already exists on the nested host, skip'; return }
    }
    finally { Disconnect-VIServer $esx -Confirm:$false | Out-Null }
}

New-Item -ItemType Directory -Force $Scratch | Out-Null
$tmp = Join-Path $Scratch 'vcsa-i05.json'
(Get-Content (Join-Path $Here 'vcsa-i05.template.json') -Raw).
    Replace('__ESXPASS__', $ESXPass).Replace('__VCPASS__', $VCPass).Replace('__DATASTORE__', $dsName) |
    Set-Content -LiteralPath $tmp -Encoding utf8
try {
    if ($DryRun) {
        Log 'DRYRUN vcsa-deploy install --verify-template-only'
        & $Deploy install --accept-eula --acknowledge-ceip --no-ssl-certificate-verification --verify-template-only $tmp 2>&1 | Tee-Object -Append $LogFile | Select-Object -Last 5
    }
    else {
        Log 'vcsa-deploy install (about 30-40 min) ...'
        & $Deploy install --accept-eula --acknowledge-ceip --no-ssl-certificate-verification --log-dir (Join-Path $Here 'vcsa-log') $tmp 2>&1 |
            Tee-Object -FilePath (Join-Path $Here 'vcsa-deploy.out') | Select-Object -Last 15
        Log "vcsa-deploy exit=$LASTEXITCODE"
    }
}
finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }   # temp copy holds passwords
