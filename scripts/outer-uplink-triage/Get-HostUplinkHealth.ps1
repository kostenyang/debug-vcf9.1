<#
.SYNOPSIS
  外層實體 ESXi 主機的上行（vmnic）健康檢查 —— 唯讀。
  「nested 全部變慢 / 某台 host 上的 VM 全部 ping 掉」時第一支要跑的。

.DESCRIPTION
  1. 每張 vmnic 的 link / speed / duplex / driver
  2. esxcli network nic stats（CRC / FIFO / missed / dropped）—— 主機端計數器乾淨 ≠ 網路沒問題
  3. 最近 N 小時的上行事件：vmnicX down/up 次數、第一次 / 最後一次、uplink redundancy lost、告警被手動清除
  4. 即時（realtime，20 秒一點）每張 vmnic 的收 / 送 KBps
     🔑 收（rx）幾乎 0、送（tx）正常 = 交換器送不進來 / 主機收不到；反過來 = 主機送不出去（先查 vSwitch 上行）
  5. 這台 host 上送收最多的 VM（找誰在灌流量）

.EXAMPLE
  $env:VIPASS = '<外層 vCenter 密碼>'
  ./Get-HostUplinkHealth.ps1 -VCenter 10.0.0.101 -HostName 10.0.0.95 -Hours 24

.NOTES
  2026-10-28 home lab .95 實戰：vmnic0 從 07:31（本地）起每 37 秒被 igbn 驅動 reset（Rx hang），
  本工具的第 3 段會看到大量「vmnic0 is down / up」、第 4 段 rx≈10 KBps / tx≈18 MBps。詳見 09-outer-physical-uplink.md。
#>
param(
    [Parameter(Mandatory)][string]$VCenter,
    [Parameter(Mandatory)][string]$HostName,
    [string]$User = 'administrator@vsphere.local',
    [int]$Hours = 24
)
$ErrorActionPreference = 'Stop'
if (-not $env:VIPASS) { throw '先設定 $env:VIPASS（外層 vCenter 密碼）' }
Import-Module VMware.VimAutomation.Core -ErrorAction Stop | Out-Null
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -ParticipateInCEIP $false -Confirm:$false -Scope Session | Out-Null
$vc = Connect-VIServer $VCenter -User $User -Password $env:VIPASS -Force -WarningAction SilentlyContinue
$h = Get-VMHost -Server $vc -Name $HostName
"== $($h.Name)  connection=$($h.ConnectionState)  boot=$($h.ExtensionData.Runtime.BootTime.ToUniversalTime().ToString('yyyy-MM-dd HH:mm'))Z"

"`n== 1. vmnic link"
foreach ($p in $h.ExtensionData.Config.Network.Pnic) {
    $ls = $p.LinkSpeed
    '{0,-8} {1,-10} {2,-6} driver={3,-8} mac={4}' -f $p.Device, $(if ($ls) { "$($ls.SpeedMb)Mb" } else { 'DOWN' }), $(if (-not $ls) { '' } elseif ($ls.Duplex) { 'full' } else { 'HALF' }), $p.Driver, $p.Mac
}

"`n== 2. esxcli nic stats（只列非 0 的錯誤欄）"
$e = Get-EsxCli -VMHost $h -V2
foreach ($p in $h.ExtensionData.Config.Network.Pnic | Where-Object { $_.LinkSpeed }) {
    try {
        $s = $e.network.nic.stats.get.Invoke(@{ nicname = $p.Device })
        $err = $s.PSObject.Properties | Where-Object { $_.Name -match 'error|dropped' -and [long]$_.Value -gt 0 } | ForEach-Object { "$($_.Name)=$($_.Value)" }
        '{0,-8} rx={1:N0} pkts tx={2:N0} pkts  {3}' -f $p.Device, [long]$s.Packetsreceived, [long]$s.Packetssent, $(if ($err) { $err -join ' ' } else { '錯誤計數全 0' })
    } catch { "$($p.Device) stats 取不到：$($_.Exception.Message.Split("`n")[0])" }
}

"`n== 3. 最近 $Hours 小時的上行事件"
$ev = @(Get-VIEvent -Server $vc -Entity $h -Start (Get-Date).AddHours(-$Hours) -MaxSamples 50000 -ErrorAction SilentlyContinue |
        Where-Object { $_.FullFormattedMessage -match 'vmnic\d+ is (down|up)|linkstate is|uplink redundancy|onnectivity lost|Manually cleared' })
if (-not $ev.Count) { '（沒有上行事件）' }
foreach ($g in ($ev | ForEach-Object { foreach ($m in [regex]::Matches($_.FullFormattedMessage, '(vmnic\d+) (?:is|linkstate is) (down|up)')) {
            [pscustomobject]@{ Nic = $m.Groups[1].Value; State = $m.Groups[2].Value; T = $_.CreatedTime.ToUniversalTime() } } } |
        Sort-Object T -Unique | Group-Object Nic, State)) {
    '{0,-14} {1,4} 次  第一次 {2:MM-dd HH:mm:ss}Z  最後 {3:MM-dd HH:mm:ss}Z' -f $g.Name, $g.Count, ($g.Group | Measure-Object T -Minimum).Minimum, ($g.Group | Measure-Object T -Maximum).Maximum
}
$ev | Where-Object { $_.FullFormattedMessage -match 'redundancy|Manually cleared|onnectivity lost' -and $_.FullFormattedMessage -notmatch 'changed from (Red|Green) to (Green|Red)' } |
    Sort-Object CreatedTime | Select-Object -Last 10 | ForEach-Object { '{0:MM-dd HH:mm:ss}Z {1}' -f $_.CreatedTime.ToUniversalTime(), $_.FullFormattedMessage }

"`n== 4. 即時收送（最近 2 分鐘平均，KBps）"
$st = Get-Stat -Entity $h -Stat 'net.received.average', 'net.transmitted.average' -Realtime -MaxSamples 6 -ErrorAction SilentlyContinue | Where-Object { $_.Instance -like 'vmnic*' }
foreach ($g in ($st | Group-Object Instance | Sort-Object Name)) {
    $rx = ($g.Group | Where-Object MetricId -like '*received*' | Measure-Object Value -Average).Average
    $tx = ($g.Group | Where-Object MetricId -like '*transmitted*' | Measure-Object Value -Average).Average
    $hint = if ($tx -gt 1000 -and $rx -lt 50) { '  ⚠ 送很多、幾乎收不到 → 交換器端 / 線路' } elseif ($rx -gt 1000 -and $tx -lt 50) { '  ⚠ 收很多、幾乎送不出 → 先查 vSwitch 上行 / failover' } else { '' }
    '{0,-8} rx {1,10:N0}  tx {2,10:N0}{3}' -f $g.Name, $rx, $tx, $hint
}

"`n== 5. 這台 host 上流量前 10 的 VM（KBps）"
$vms = @(Get-VM -Server $vc -Location $h | Where-Object PowerState -eq 'PoweredOn')
if ($vms.Count) {
    Get-Stat -Entity $vms -Stat 'net.received.average', 'net.transmitted.average' -Realtime -MaxSamples 6 -ErrorAction SilentlyContinue | Where-Object Instance -eq '' |
        Group-Object { $_.Entity.Name } | ForEach-Object {
            [pscustomobject]@{ VM = $_.Name
                               RxKBps = [int](($_.Group | Where-Object MetricId -like '*received*' | Measure-Object Value -Average).Average)
                               TxKBps = [int](($_.Group | Where-Object MetricId -like '*transmitted*' | Measure-Object Value -Average).Average) }
        } | Sort-Object { $_.RxKBps + $_.TxKBps } -Descending | Select-Object -First 10 | Format-Table -AutoSize | Out-String
}
Disconnect-VIServer $vc -Confirm:$false
