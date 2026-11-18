# Break / restore vMotion on i05 so the vSAN Skyline Health vMotion checks go red.
#   Break      = esx03 vMotion vmk -> 192.168.99.53/24 (others on 192.168.250.0/24)  => unicast + MTU both red (customer screenshot 1)
#   Restore    = esx03 vMotion vmk back to 192.168.250.53
#   BreakMtu   = all vMotion vmks MTU 9000 while i05-vds01 stays 1500                 => only MTU red (customer screenshot 3)
#   RestoreMtu = all vMotion vmks back to MTU 1500
#   Show       = print vMotion vmk ip/mtu + VDS mtu
#   Needs $env:VCPASS.
param([Parameter(Mandatory)][ValidateSet('Break', 'Restore', 'BreakMtu', 'RestoreMtu', 'Show')][string]$Action)
$ErrorActionPreference = 'Stop'
$PCLI = '13.5.1.25718932'; 'Sdk', 'Core', 'Vds' | ForEach-Object { Import-Module "VMware.VimAutomation.$_" -RequiredVersion $PCLI | Out-Null }
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -ParticipateInCEIP $false -DefaultVIServerMode Single -Confirm:$false -Scope Session | Out-Null
$LogFile = Join-Path $PSScriptRoot 'vmotion-break.log'
function Log($m) { "[{0}] {1}" -f (Get-Date -Format 'MM-dd HH:mm:ss'), $m | Tee-Object -Append $LogFile }
$srv = Connect-VIServer 'vcf-i05-vc01.home.lab' -User 'administrator@vsphere.local' -Password $env:VCPASS -Force -WarningAction SilentlyContinue
try {
    Log ("i05-vds01 MTU={0}" -f (Get-VDSwitch -Name 'i05-vds01').Mtu)
    foreach ($h in (Get-Cluster 'i05-cl01' | Get-VMHost | Sort-Object Name)) {
        $vmk = Get-VMHostNetworkAdapter -VMHost $h -VMKernel | Where-Object { $_.PortGroupName -eq 'i05-pg-vmotion' }
        Log ("{0} {1} ip={2} mtu={3} vmotion={4}" -f $h.Name, $vmk.Name, $vmk.IP, $vmk.Mtu, $vmk.VMotionEnabled)
        switch ($Action) {
            'Break' { if ($h.Name -like 'vcf-i05-esx03*' -and $vmk.IP -ne '192.168.99.53') { Set-VMHostNetworkAdapter -VirtualNic $vmk -IP '192.168.99.53' -SubnetMask 255.255.255.0 -Confirm:$false | Out-Null; Log "  Break -> ip 192.168.99.53" } }
            'Restore' { if ($h.Name -like 'vcf-i05-esx03*' -and $vmk.IP -ne '192.168.250.53') { Set-VMHostNetworkAdapter -VirtualNic $vmk -IP '192.168.250.53' -SubnetMask 255.255.255.0 -Confirm:$false | Out-Null; Log "  Restore -> ip 192.168.250.53" } }
            'BreakMtu' {
                if ($vmk.Mtu -ne 9000) {
                    try { Set-VMHostNetworkAdapter -VirtualNic $vmk -Mtu 9000 -Confirm:$false | Out-Null; Log "  BreakMtu -> mtu 9000 (vCenter)" }
                    catch {
                        Log "  vCenter refused ($($_.Exception.Message)); trying esxcli"
                        (Get-EsxCli -VMHost $h -V2).network.ip.interface.set.Invoke(@{ interfacename = $vmk.Name; mtu = 9000 }) | Out-Null
                        Log "  BreakMtu -> mtu 9000 (esxcli)"
                    }
                }
            }
            'RestoreMtu' { if ($vmk.Mtu -ne 1500) { Set-VMHostNetworkAdapter -VirtualNic $vmk -Mtu 1500 -Confirm:$false | Out-Null; Log "  RestoreMtu -> mtu 1500" } }
        }
    }
}
finally { Disconnect-VIServer $srv -Confirm:$false | Out-Null }
