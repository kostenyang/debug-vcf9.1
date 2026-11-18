# i05 DNS records (A + PTR) on the local DNS server (this machine = 10.0.0.200)
#   .\Set-I04Dns.ps1 -Action Add -DryRun     # show what would change
#   .\Set-I04Dns.ps1 -Action Add             # create A+PTR
#   .\Set-I04Dns.ps1 -Action Remove          # delete A+PTR (exact names/IPs only)
param(
    [Parameter(Mandatory)][ValidateSet('Add', 'Remove', 'Show')][string]$Action,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$Zone = 'home.lab'; $RevZone = '1.0.10.in-addr.arpa'
$Records = [ordered]@{
    'vcf-i05-esx01' = '10.0.1.183'
    'vcf-i05-esx02' = '10.0.1.184'
    'vcf-i05-esx03' = '10.0.1.185'
    'vcf-i05-vc01'  = '10.0.1.186'
}
$Log = Join-Path $PSScriptRoot 'dns.log'
function Log($m) { "[{0}] {1}" -f (Get-Date -Format 'MM-dd HH:mm:ss'), $m | Tee-Object -Append $Log }

foreach ($name in $Records.Keys) {
    $ip = $Records[$name]; $last = $ip.Split('.')[-1]
    $a = Get-DnsServerResourceRecord -ZoneName $Zone -Name $name -RRType A -ErrorAction SilentlyContinue
    $p = Get-DnsServerResourceRecord -ZoneName $RevZone -Name $last -RRType Ptr -ErrorAction SilentlyContinue
    $aTxt = if ($a) { ($a.RecordData.IPv4Address.IPAddressToString) -join ',' } else { '-' }
    $pTxt = if ($p) { ($p.RecordData.PtrDomainName) -join ',' } else { '-' }
    Log ("{0,-14} {1,-11} now A={2} PTR={3}" -f $name, $ip, $aTxt, $pTxt)
    if ($Action -eq 'Show') { continue }

    if ($Action -eq 'Add') {
        # refuse to touch an IP/name that is already used by something else
        $other = Get-DnsServerResourceRecord -ZoneName $Zone -RRType A | Where-Object { $_.RecordData.IPv4Address.IPAddressToString -eq $ip -and $_.HostName -ne $name }
        if ($other) { throw "IP $ip already used by A record $($other.HostName) - stop" }
        if ($p -and ($p.RecordData.PtrDomainName -notcontains "$name.$Zone.")) { throw "PTR $ip already points to $pTxt - stop" }
        if ($a) { Log "  A exists, skip" } elseif ($DryRun) { Log "  DRYRUN would add A $name -> $ip" } else { Add-DnsServerResourceRecordA -ZoneName $Zone -Name $name -IPv4Address $ip; Log "  A added" }
        if ($p) { Log "  PTR exists, skip" } elseif ($DryRun) { Log "  DRYRUN would add PTR $last -> $name.$Zone." } else { Add-DnsServerResourceRecordPtr -ZoneName $RevZone -Name $last -PtrDomainName "$name.$Zone."; Log "  PTR added" }
    }
    else {
        if ($a) {
            $match = $a | Where-Object { $_.RecordData.IPv4Address.IPAddressToString -eq $ip }
            if ($DryRun) { Log "  DRYRUN would remove A $name ($ip)" } else { $match | Remove-DnsServerResourceRecord -ZoneName $Zone -Force; Log "  A removed" }
        }
        if ($p) {
            $match = $p | Where-Object { $_.RecordData.PtrDomainName -eq "$name.$Zone." }
            if (-not $match) { Log "  PTR $last points elsewhere ($pTxt) - leave it" }
            elseif ($DryRun) { Log "  DRYRUN would remove PTR $last" } else { $match | Remove-DnsServerResourceRecord -ZoneName $RevZone -Force; Log "  PTR removed" }
        }
    }
}
