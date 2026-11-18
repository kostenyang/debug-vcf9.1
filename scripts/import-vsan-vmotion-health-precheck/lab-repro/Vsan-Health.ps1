# i05 vSAN Skyline Health helper (network group, vMotion checks) via the vSAN management API.
#   .\Vsan-Health.ps1 -Action Show        # RETEST (fetchFromCache=false) and print the network-group tests + silenced list
#   .\Vsan-Health.ps1 -Action Importer    # same call shape as the SDDC Manager importer (fetchFromCache=null, fields=null)
#   .\Vsan-Health.ps1 -Action Silence     # silence vmotionpingsmall + vmotionpinglarge (same API the UI 'Silence alert' uses)
#   .\Vsan-Health.ps1 -Action Unsilence
#   .\Vsan-Health.ps1 -Action Signature   # print the method signatures (debug)
#   Needs $env:VCPASS.
param([Parameter(Mandatory)][ValidateSet('Show', 'Importer', 'Silence', 'Unsilence', 'Signature')][string]$Action,
      [string[]]$Checks = @('com.vmware.vsan.health.test.vmotionpingsmall', 'com.vmware.vsan.health.test.vmotionpinglarge'))
$ErrorActionPreference = 'Stop'
$PCLI = '13.5.1.25718932'
'Sdk', 'Core', 'Storage' | ForEach-Object { Import-Module "VMware.VimAutomation.$_" -RequiredVersion $PCLI | Out-Null }
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -ParticipateInCEIP $false -DefaultVIServerMode Single -Confirm:$false -Scope Session | Out-Null
$VC = 'vcf-i05-vc01.home.lab'; $ClusterN = 'i05-cl01'
$LogFile = Join-Path $PSScriptRoot 'vsan-health.log'
function Log($m) { "[{0}] {1}" -f (Get-Date -Format 'MM-dd HH:mm:ss'), $m | Tee-Object -Append $LogFile }

$srv = Connect-VIServer $VC -User 'administrator@vsphere.local' -Password $env:VCPASS -Force -WarningAction SilentlyContinue
try {
    $cl = Get-Cluster -Name $ClusterN
    $mo = $cl.ExtensionData.MoRef
    $hs = Get-VsanView -Id 'VsanVcClusterHealthSystem-vsan-cluster-health-system'
    if ($Action -eq 'Signature') {
        $hs | Get-Member -MemberType Method | Where-Object { $_.Name -match 'QueryVcClusterHealthSummary$|SilentChecks' } | ForEach-Object { $_.Definition }
        return
    }
    if ($Action -in 'Silence', 'Unsilence') {
        $add = if ($Action -eq 'Silence') { [string[]]$Checks } else { $null }
        $rem = if ($Action -eq 'Unsilence') { [string[]]$Checks } else { $null }
        $r = $hs.VsanHealthSetVsanClusterSilentChecks($mo, $add, $rem)
        Log "$Action $($Checks -join ',') -> $r"
    }
    $silent = $hs.VsanHealthGetVsanClusterSilentChecks($mo)
    Log ("silenced checks now: " + ($(if ($silent) { $silent -join ', ' } else { '(none)' })))
    if ($Action -eq 'Importer') {
        # importer: queryClusterHealthSummary(cluster, null, null, null, HEALTH_SUMMARY_FIELDS, null, null, null, null, null)
        $sum = $hs.VsanQueryVcClusterHealthSummary($mo, $null, $null, $null, $null, $null, $null)
    }
    else {
        $sum = $hs.VsanQueryVcClusterHealthSummary($mo, $null, $null, $true, $null, $false, 'defaultView')
    }
    Log ("overall={0}  ({1})" -f $sum.OverallHealth, $Action)
    $net = $sum.Groups | Where-Object { $_.GroupId -eq 'com.vmware.vsan.health.test.network' }
    foreach ($t in $net.GroupTests) {
        $mark = if ($t.TestId -match 'vmotionping') { '<==' } else { '' }
        Log ("  {0,-55} {1,-8} {2} {3}" -f $t.TestId, $t.TestHealth, $t.TestName, $mark)
    }
    foreach ($t in ($net.GroupTests | Where-Object { $_.TestId -match 'vmotionping' -and $_.TestHealth -ne 'green' })) {
        foreach ($d in $t.TestDetails) {
            Log ("    detail [{0}] cols={1}" -f $d.Label, (($d.Columns | ForEach-Object { $_.Label }) -join '|'))
            foreach ($row in ($d.Rows | Select-Object -First 8)) { Log ("      " + (($row.Values) -join ' | ')) }
        }
    }
}
finally { Disconnect-VIServer $srv -Confirm:$false | Out-Null }
