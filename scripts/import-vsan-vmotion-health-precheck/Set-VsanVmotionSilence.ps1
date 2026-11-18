<#
.SYNOPSIS
  Show / retest / silence / unsilence the vSAN Skyline Health vMotion checks that block the
  VCF 9.1.1 import precheck "Cluster common datastore check." (vsanVmotion*ConnectivityCheckStatus).

.DESCRIPTION
  -Action Show       read the network-group health from the vSAN health cache + silenced list (read-only)
  -Action Retest     run the health checks now (same as RETEST in the UI) and print the result (read-only)
  -Action Silence    silence the given checks (same API as 'SILENCE ALERT' in the UI) -> testHealth 'skipped'
  -Action Unsilence  remove them from the silenced list
  Non-green vMotion checks are printed with their 'Failed connections' rows (host names resolved).

  Use SHORT test IDs: vmotionpinglarge (MTU check), vmotionpingsmall (unicast check).
  The full ID 'com.vmware.vsan.health.test.vmotionpinglarge' is rejected with 'General vSAN error'.

.EXAMPLE
  .\Set-VsanVmotionSilence.ps1 -Server vc01.example.local -Cluster DMZ-Cluster -Action Retest
  .\Set-VsanVmotionSilence.ps1 -Server vc01.example.local -Cluster DMZ-Cluster -Action Silence -Checks vmotionpinglarge
  .\Set-VsanVmotionSilence.ps1 -Server vc01.example.local -Cluster DMZ-Cluster -Action Unsilence -Checks vmotionpinglarge
#>
param(
    [Parameter(Mandatory)][string]$Server,
    [Parameter(Mandatory)][string]$Cluster,
    [Parameter(Mandatory)][ValidateSet('Show', 'Retest', 'Silence', 'Unsilence')][string]$Action,
    [ValidateSet('vmotionpinglarge', 'vmotionpingsmall')][string[]]$Checks = @('vmotionpinglarge'),
    [pscredential]$Credential = (Get-Credential -Message "vCenter SSO user for $Server")
)
$ErrorActionPreference = 'Stop'
'VMware.VimAutomation.Core', 'VMware.VimAutomation.Storage' | ForEach-Object { Import-Module $_ | Out-Null }
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -ParticipateInCEIP $false -Confirm:$false -Scope Session | Out-Null

$srv = Connect-VIServer $Server -Credential $Credential -Force -WarningAction SilentlyContinue
try {
    $cl = Get-Cluster -Name $Cluster -Server $srv
    $mo = $cl.ExtensionData.MoRef
    $hostName = @{}
    Get-VMHost -Location $cl -Server $srv | ForEach-Object { $hostName[$_.ExtensionData.MoRef.Value] = $_.Name }
    $hs = Get-VsanView -Id 'VsanVcClusterHealthSystem-vsan-cluster-health-system' -Server $srv

    if ($Action -eq 'Silence') { "Silence $($Checks -join ',') -> " + $hs.VsanHealthSetVsanClusterSilentChecks($mo, [string[]]$Checks, $null) }
    if ($Action -eq 'Unsilence') { "Unsilence $($Checks -join ',') -> " + $hs.VsanHealthSetVsanClusterSilentChecks($mo, $null, [string[]]$Checks) }

    $silent = $hs.VsanHealthGetVsanClusterSilentChecks($mo)
    "Silenced checks: " + $(if ($silent) { $silent -join ', ' } else { '(none)' })

    # fetchFromCache: Show = cached result, everything else = run the tests now
    $fromCache = ($Action -eq 'Show')
    $sum = $hs.VsanQueryVcClusterHealthSummary($mo, $null, $null, $true, $null, $fromCache, 'defaultView')
    "Cluster $Cluster overall vSAN health: $($sum.OverallHealth)  (fetchFromCache=$fromCache)"

    $net = $sum.Groups | Where-Object { $_.GroupId -eq 'com.vmware.vsan.health.test.network' }
    $net.GroupTests | Select-Object @{n = 'Status'; e = { $_.TestHealth } }, @{n = 'Check'; e = { $_.TestName } },
        @{n = 'Id'; e = { $_.TestId -replace '^com\.vmware\.vsan\.health\.test\.', '' } } | Format-Table -AutoSize | Out-String -Width 200

    foreach ($t in ($net.GroupTests | Where-Object { $_.TestId -match 'vmotionping' -and $_.TestHealth -notin 'green', 'info', 'skipped' })) {
        "== $($t.TestName) [$($t.TestHealth)]"
        foreach ($d in $t.TestDetails) {
            "   " + (($d.Columns | ForEach-Object { $_.Label }) -join ' | ')
            foreach ($r in $d.Rows) {
                $vals = $r.Values | ForEach-Object { if ($_ -match 'HostSystem:(host-\d+)') { $hostName[$Matches[1]] } else { $_ } }
                "   " + ($vals -join ' | ')
            }
        }
    }
    "Import precheck accepts: green / info / yellow / skipped(silenced). red blocks the vSAN datastore."
}
finally { Disconnect-VIServer $srv -Confirm:$false | Out-Null }
