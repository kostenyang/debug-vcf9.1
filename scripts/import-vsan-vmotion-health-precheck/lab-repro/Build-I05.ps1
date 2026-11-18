# i05: 3-host vSAN OSA (all-flash) cluster inside vcf-i05-vc01, for the vSAN vMotion-health import precheck test.
#   DC/cluster (DRS FullyAutomated, HA off) -> add 3 hosts -> VDS 8.0.3 (uplink vmnic1) + pg-mgmt / pg-vmotion / pg-vsan
#   -> vmk0 to pg-mgmt, vmk1 vMotion (192.168.250.5x), vmk2 vSAN (192.168.251.5x) -> enable vSAN -> 1 disk group per host.
#   vmnic0 stays on vSwitch0 so 'VM Network' (the co-located vCenter VM on esx01) keeps its uplink.
#   Adapted from imp-nsxloc\Build-I04.ps1. Needs $env:VCPASS and $env:ESXPASS.   .\Build-I05.ps1 -DryRun
param([switch]$DryRun)
$ErrorActionPreference = 'Stop'
$PCLI = '13.5.1.25718932'
'Sdk', 'Core', 'Vds', 'Storage' | ForEach-Object { Import-Module "VMware.VimAutomation.$_" -RequiredVersion $PCLI | Out-Null }
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -ParticipateInCEIP $false `
    -DefaultVIServerMode Single -Confirm:$false -Scope Session | Out-Null

$VC = 'vcf-i05-vc01.home.lab'; $VcPass = $env:VCPASS; $EsxPass = $env:ESXPASS
if (-not $VcPass -or -not $EsxPass) { throw 'set $env:VCPASS and $env:ESXPASS' }
$DcName = 'i05-dc01'; $ClusterN = 'i05-cl01'
$Hosts = [ordered]@{   # vMotion vmk IP, vSAN vmk IP (non-routed /24s, all nested hosts sit on outer .95 / Trunk-Nobinding)
    'vcf-i05-esx01.home.lab' = @('192.168.250.51', '192.168.251.51')
    'vcf-i05-esx02.home.lab' = @('192.168.250.52', '192.168.251.52')
    'vcf-i05-esx03.home.lab' = @('192.168.250.53', '192.168.251.53')
}
$VdsName = 'i05-vds01'; $PgMgmt = 'i05-pg-mgmt'; $PgVmot = 'i05-pg-vmotion'; $PgVsan = 'i05-pg-vsan'
$LogFile = Join-Path $PSScriptRoot 'build-i05.log'
function Log($m) { "[{0}] {1}" -f (Get-Date -Format 'MM-dd HH:mm:ss'), $m | Tee-Object -Append $LogFile }
function Do-Step([string]$what, [scriptblock]$sb) { if ($DryRun) { Log "  DRYRUN would: $what" } else { & $sb; Log "  $what" } }

Log "connecting $VC (DryRun=$DryRun)"
$srv = Connect-VIServer $VC -User 'administrator@vsphere.local' -Password $VcPass -Force
try {
    $dc = Get-Datacenter -Name $DcName -ErrorAction SilentlyContinue
    if (-not $dc) { Do-Step "create datacenter $DcName" { $script:dc = New-Datacenter -Name $DcName -Location (Get-Folder -NoRecursion) } }
    $cl = Get-Cluster -Name $ClusterN -ErrorAction SilentlyContinue
    if (-not $cl) { Do-Step "create cluster $ClusterN (DRS FullyAutomated, HA off)" { $script:cl = New-Cluster -Name $ClusterN -Location $script:dc -DrsEnabled -DrsAutomationLevel FullyAutomated } }
    foreach ($hn in $Hosts.Keys) {
        if (-not (Get-VMHost -Name $hn -ErrorAction SilentlyContinue)) { Do-Step "add host $hn" { Add-VMHost -Name $hn -Location $script:cl -User root -Password $EsxPass -Force | Out-Null } }
    }
    if ($DryRun -and -not $cl) { Log 'DRYRUN stops here (cluster not created yet)'; return }

    $vds = Get-VDSwitch -Name $VdsName -ErrorAction SilentlyContinue
    if (-not $vds) { Do-Step "create VDS $VdsName (8.0.3)" { $script:vds = New-VDSwitch -Name $VdsName -Location $script:dc -Version '8.0.3' -NumUplinkPorts 1 -Mtu 1500 } }
    if ($DryRun -and -not $vds) { Log 'DRYRUN stops here (VDS not created yet)'; return }
    foreach ($pgn in @($PgMgmt, $PgVmot, $PgVsan)) {
        if (-not (Get-VDPortgroup -VDSwitch $vds -Name $pgn -ErrorAction SilentlyContinue)) { Do-Step "portgroup $pgn (Static)" { New-VDPortgroup -VDSwitch $script:vds -Name $pgn -PortBinding Static | Out-Null } }
    }
    $pgM = Get-VDPortgroup -VDSwitch $vds -Name $PgMgmt
    foreach ($hn in $Hosts.Keys) {
        $h = Get-VMHost -Name $hn
        if (-not (Get-VDSwitch -VMHost $h -Name $VdsName -ErrorAction SilentlyContinue)) {
            Do-Step "$hn join VDS (uplink vmnic1)" {
                Add-VDSwitchVMHost -VDSwitch $vds -VMHost $h | Out-Null
                Add-VDSwitchPhysicalNetworkAdapter -DistributedSwitch $vds -VMHostPhysicalNic (Get-VMHostNetworkAdapter -VMHost $h -Physical -Name vmnic1) -Confirm:$false
            }
        }
        $vmk0 = Get-VMHostNetworkAdapter -VMHost $h -Name vmk0
        if (-not $vmk0.ExtensionData.Spec.DistributedVirtualPort) {
            Do-Step "$hn vmk0 -> $PgMgmt" { Set-VMHostNetworkAdapter -VirtualNic $vmk0 -PortGroup $pgM -Confirm:$false | Out-Null; Start-Sleep 8 }
        }
        # the nested template tags vmk0 for vSAN on some hosts -> keep vMotion and vSAN only on vmk1 / vmk2
        if (-not $DryRun) { Get-VMHostNetworkAdapter -VMHost $h -Name vmk0 | Set-VMHostNetworkAdapter -VMotionEnabled $false -VsanTrafficEnabled $false -Confirm:$false | Out-Null }
        if (-not (Get-VMHostNetworkAdapter -VMHost $h -VMKernel | Where-Object { $_.PortGroupName -eq $PgVmot })) {
            Do-Step "$hn vMotion vmk $($Hosts[$hn][0])" { New-VMHostNetworkAdapter -VMHost $h -VirtualSwitch $vds -PortGroup $PgVmot -IP $Hosts[$hn][0] -SubnetMask 255.255.255.0 -VMotionEnabled $true | Out-Null }
        }
        if (-not (Get-VMHostNetworkAdapter -VMHost $h -VMKernel | Where-Object { $_.PortGroupName -eq $PgVsan })) {
            Do-Step "$hn vSAN vmk $($Hosts[$hn][1])" { New-VMHostNetworkAdapter -VMHost $h -VirtualSwitch $vds -PortGroup $PgVsan -IP $Hosts[$hn][1] -SubnetMask 255.255.255.0 -VsanTrafficEnabled $true | Out-Null }
        }
    }

    # vSAN OSA all-flash: enable on the cluster, tag the 60 GB disk capacityFlash, 8 GB disk = cache
    $vc = Get-VsanClusterConfiguration -Cluster $ClusterN
    if (-not $vc.VsanEnabled) { Do-Step "enable vSAN on $ClusterN (OSA, manual claim)" { Set-Cluster -Cluster $ClusterN -VsanEnabled:$true -VsanDiskClaimMode Manual -Confirm:$false | Out-Null } }
    foreach ($hn in $Hosts.Keys) {
        $h = Get-VMHost -Name $hn
        if (Get-VsanDiskGroup -VMHost $h -ErrorAction SilentlyContinue) { Log "  $hn already has a disk group"; continue }
        $luns = Get-ScsiLun -VmHost $h -LunType disk
        $cache = $luns | Where-Object { [math]::Round($_.CapacityGB) -eq 8 } | Select-Object -First 1
        $capd = $luns | Where-Object { [math]::Round($_.CapacityGB) -eq 60 } | Select-Object -First 1
        if (-not $cache -or -not $capd) { throw "$hn : cannot find 8 GB cache / 60 GB capacity disk (" + (($luns | ForEach-Object { "$($_.CanonicalName)=$([math]::Round($_.CapacityGB))G" }) -join ' ') + ')' }
        Do-Step "$hn disk group cache=$($cache.CanonicalName) cap=$($capd.CanonicalName) (capacityFlash)" {
            $esxcli = Get-EsxCli -VMHost $h -V2
            try { $esxcli.vsan.storage.tag.add.Invoke(@{ disk = $capd.CanonicalName; tag = 'capacityFlash' }) | Out-Null } catch { Log "  tag note: $($_.Exception.Message)" }
            New-VsanDiskGroup -VMHost $h -SsdCanonicalName $cache.CanonicalName -DataDiskCanonicalName $capd.CanonicalName | Out-Null
        }
    }

    # nested hosts came up with different LSOM.lsomSlowDeviceUnmount (esx01=1, esx02/03=0) -> vSAN health
    # 'Advanced vSAN configuration in sync' goes red and blocks the import precheck on its own. Align to 0.
    foreach ($hn in $Hosts.Keys) {
        $a = Get-AdvancedSetting -Entity (Get-VMHost -Name $hn) -Name 'LSOM.lsomSlowDeviceUnmount'
        if ($a.Value -ne 0) { Do-Step "$hn LSOM.lsomSlowDeviceUnmount $($a.Value) -> 0" { $a | Set-AdvancedSetting -Value 0 -Confirm:$false | Out-Null } }
    }

    Log '=== summary ==='
    $cl = Get-Cluster -Name $ClusterN
    Log ("  cluster {0}: DRS={1} {2} HA={3} vSAN={4}" -f $cl.Name, $cl.DrsEnabled, $cl.DrsAutomationLevel, $cl.HAEnabled, (Get-VsanClusterConfiguration -Cluster $cl).VsanEnabled)
    foreach ($hn in $Hosts.Keys) {
        $h = Get-VMHost -Name $hn
        Get-VMHostNetworkAdapter -VMHost $h -VMKernel | ForEach-Object { Log ("  {0} {1} pg={2} ip={3} mgmt={4} vmotion={5} vsan={6}" -f $hn, $_.Name, $_.PortGroupName, $_.IP, $_.ManagementTrafficEnabled, $_.VMotionEnabled, $_.VsanTrafficEnabled) }
        Log ("  {0} datastores: {1} ; state={2}" -f $hn, ((Get-Datastore -VMHost $h).Name -join ','), $h.ConnectionState)
    }
    Log ("  VMs: " + ((Get-VM | Select-Object -ExpandProperty Name) -join ','))
}
finally { Disconnect-VIServer $srv -Confirm:$false | Out-Null }
