# i05 teardown: delete the outer VMs that make up i05 (exact names only) + DNS A/PTR.
#   vcf-i05-vc01 lives INSIDE vcf-i05-esx01 (datastore1), so deleting the nested host removes it too.
#   Needs $env:VIPASS.  .\Teardown-I05.ps1 -DryRun   # list what would be deleted
#   Only the API precheck was used (no VCF Ops adapter / credential to clean).
param([switch]$DryRun)
$ErrorActionPreference = 'Stop'
$VIPass = $env:VIPASS
if (-not $VIPass) { throw 'set $env:VIPASS' }
$PCLI = '13.5.1.25718932'; 'Sdk', 'Core' | ForEach-Object { Import-Module "VMware.VimAutomation.$_" -RequiredVersion $PCLI | Out-Null }
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -ParticipateInCEIP $false -DefaultVIServerMode Single -Confirm:$false -Scope Session | Out-Null
$Names = @('vcf-i05-esx01', 'vcf-i05-esx02', 'vcf-i05-esx03')
$LogFile = Join-Path $PSScriptRoot 'teardown.log'
function Log($m) { "[{0}] {1}" -f (Get-Date -Format 'MM-dd HH:mm:ss'), $m | Tee-Object -Append $LogFile }

$vi = Connect-VIServer 10.0.0.101 -User 'administrator@vsphere.local' -Password $VIPass -Force -WarningAction SilentlyContinue
try {
    foreach ($n in $Names) {
        $vm = Get-VM -Name $n -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $n }
        if (-not $vm) { Log "$n not on outer - skip"; continue }
        Log ("{0}: power={1} host={2} ds={3}" -f $n, $vm.PowerState, $vm.VMHost.Name, (($vm | Get-Datastore).Name -join ','))
        if ($DryRun) { Log "  DRYRUN would stop + Remove-VM -DeletePermanently $n"; continue }
        if ($vm.PowerState -eq 'PoweredOn') { Stop-VM -VM $vm -Confirm:$false | Out-Null }
        Remove-VM -VM $vm -DeletePermanently -Confirm:$false
        Log "  $n deleted"
    }
}
finally { Disconnect-VIServer $vi -Confirm:$false | Out-Null }
& (Join-Path $PSScriptRoot 'Set-I05Dns.ps1') -Action Remove -DryRun:$DryRun
