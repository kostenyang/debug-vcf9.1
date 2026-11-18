# i05: 3 nested ESXi 8.0U3b on outer labvc8 host .95 / vmfs-wdblue4t for the vSAN vMotion-health import precheck test.
#   esx01 also hosts the i05 vCenter VM (co-located): createvmfs=true -> datastore1 on scsi0:2, plus 2 extra SSD disks for vSAN.
#   esx02/03: template cache (scsi0:1) + capacity (scsi0:2) disks go to vSAN.
#   Needs $env:VIPASS (outer vCenter) and $env:ESXPASS (nested root).   .\Deploy-I05-NestedESXi.ps1 -DryRun
param([switch]$DryRun)
$ErrorActionPreference = 'Stop'
$PCLI = '13.5.1.25718932'; 'Sdk', 'Core' | ForEach-Object { Import-Module "VMware.VimAutomation.$_" -RequiredVersion $PCLI | Out-Null }
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -ParticipateInCEIP $false -DefaultVIServerMode Single -Confirm:$false -Scope Session | Out-Null
$VIPass = $env:VIPASS; $ESXPass = $env:ESXPASS
if (-not $VIPass -or -not $ESXPass) { throw 'set $env:VIPASS and $env:ESXPASS' }
$OVA = 'C:\Users\Administrator\OneDrive\桌面\VCF\Nested_ESXi8.0u3b_Appliance_Template_v1.ova'
$Net = 'Trunk-Nobinding'; $Folder = 'VCF'; $TargetHost = '10.0.0.95'; $dsName = 'vmfs-wdblue4t'
$Mask = '255.255.254.0'; $GW = '10.0.0.1'; $DNS = '10.0.0.200'; $NTP = '10.0.1.254'; $Domain = 'home.lab'
$Hosts = [ordered]@{
    'vcf-i05-esx01' = @{ ip = '10.0.1.183'; cpu = 6; mem = 32; vmfs = $true }
    'vcf-i05-esx02' = @{ ip = '10.0.1.184'; cpu = 4; mem = 12; vmfs = $false }
    'vcf-i05-esx03' = @{ ip = '10.0.1.185'; cpu = 4; mem = 12; vmfs = $false }
}
$LogFile = Join-Path $PSScriptRoot 'deploy-esx.log'
function Log($m) { "[{0}] {1}" -f (Get-Date -Format 'MM-dd HH:mm:ss'), $m | Tee-Object -Append $LogFile }

if (-not (Test-Path -LiteralPath $OVA)) { throw "OVA not found: $OVA" }
$vi = Connect-VIServer 10.0.0.101 -User 'administrator@vsphere.local' -Password $VIPass -Force -WarningAction SilentlyContinue
try {
    $vmhost = Get-VMHost -Name $TargetHost
    $fld = Get-Folder -Name $Folder -Type VM | Select-Object -First 1
    $ds = Get-Datastore -Name $dsName -VMHost $vmhost
    $pg = Get-VirtualPortGroup -VMHost $vmhost -Name $Net -ErrorAction SilentlyContinue
    Log ("host {0} free mem {1:N0} GB; {2} free {3:N0} GB; portgroup {4}: {5}" -f $vmhost.Name, ($vmhost.MemoryTotalGB - $vmhost.MemoryUsageGB), $ds.Name, $ds.FreeSpaceGB, $Net, [bool]$pg)
    if (-not $pg) { throw "portgroup $Net not visible on $TargetHost" }
    foreach ($name in $Hosts.Keys) {
        $c = $Hosts[$name]
        if (Get-VM -Name $name -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $name }) { Log "$name exists, skip"; continue }
        if ($DryRun) { Log "DRYRUN would import $name ($($c.ip)) $($c.cpu) vCPU / $($c.mem) GB createvmfs=$($c.vmfs)"; continue }
        Log "=== $name ($($c.ip)) ==="
        $ovf = Get-OvfConfiguration $OVA
        $ovf.NetworkMapping.VM_Network.value = $Net
        $ovf.Common.guestinfo.hostname.value = "$name.$Domain"
        $ovf.Common.guestinfo.ipaddress.value = $c.ip
        $ovf.Common.guestinfo.netmask.value = $Mask
        $ovf.Common.guestinfo.gateway.value = $GW
        $ovf.Common.guestinfo.dns.value = $DNS
        $ovf.Common.guestinfo.domain.value = $Domain
        $ovf.Common.guestinfo.ntp.value = $NTP
        $ovf.Common.guestinfo.password.value = $ESXPass
        $ovf.Common.guestinfo.ssh.value = $true
        $ovf.Common.guestinfo.createvmfs.value = $c.vmfs
        $vm = Import-VApp -Source $OVA -OvfConfiguration $ovf -Name $name -VMHost $vmhost -Datastore $ds -InventoryLocation $fld -DiskStorageFormat thin
        Set-VM -VM $vm -NumCpu $c.cpu -MemoryGB $c.mem -Confirm:$false | Out-Null
        $disks = Get-HardDisk -VM $vm
        if ($c.vmfs) {
            # scsi0:2 becomes datastore1 for the VCSA; vSAN gets two new SSD-flagged disks (scsi0:3 cache, scsi0:4 capacity)
            Set-HardDisk -HardDisk $disks[2] -CapacityGB 200 -Confirm:$false | Out-Null
            New-HardDisk -VM $vm -CapacityGB 8 -StorageFormat Thin -Controller (Get-ScsiController -VM $vm | Select-Object -First 1) | Out-Null
            New-HardDisk -VM $vm -CapacityGB 60 -StorageFormat Thin -Controller (Get-ScsiController -VM $vm | Select-Object -First 1) | Out-Null
            foreach ($k in 'scsi0:3.virtualSSD', 'scsi0:4.virtualSSD') { New-AdvancedSetting -Entity $vm -Name $k -Value 'true' -Confirm:$false -Force | Out-Null }
            Log "  datastore1 disk 200 GB + vSAN cache 8 / cap 60 (new disks); $($c.cpu) vCPU / $($c.mem) GB"
        }
        else {
            Set-HardDisk -HardDisk $disks[1] -CapacityGB 8 -Confirm:$false | Out-Null
            Set-HardDisk -HardDisk $disks[2] -CapacityGB 60 -Confirm:$false | Out-Null
            Log "  vSAN cache 8 / cap 60 (template disks); $($c.cpu) vCPU / $($c.mem) GB"
        }
        Start-VM -VM $vm -Confirm:$false | Out-Null
        Log "  powered on"
    }
}
finally { Disconnect-VIServer $vi -Confirm:$false | Out-Null }
Log 'esx deploy done'
