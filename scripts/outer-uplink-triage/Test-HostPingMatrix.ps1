<#
.SYNOPSIS
  依「外層實體 host」分組的 ping 矩陣 —— 唯讀。一眼看出掉包是不是集中在某一台實體 host。

.DESCRIPTION
  每台外層 host：先 ping host 自己的管理 IP，再挑最多 -PerHost 台開機中、VMware Tools 有回報 IPv4 的 VM 各 ping -Count 次。
  🔑 Photon OS（VSP / VCF Automation / Supervisor 節點）預設擋 ICMP → ping 不通不代表壞；預設用 -ExcludeName 跳過這類。
  2026-10-28 實例：.95 本身與其上所有 VM 掉 90–100%，.97 / .98 全 0% → 問題在 .95 的實體上行，不是 VCFA。

.EXAMPLE
  $env:VIPASS = '<外層 vCenter 密碼>'
  ./Test-HostPingMatrix.ps1 -VCenter 10.0.0.101
  ./Test-HostPingMatrix.ps1 -VCenter 10.0.0.101 -Extra 10.0.1.141,10.0.1.144   # 另外加 nested ESXi / vCenter（它們不在外層 VM 清單的 IP 裡）
#>
param(
    [Parameter(Mandatory)][string]$VCenter,
    [string]$User = 'administrator@vsphere.local',
    [int]$PerHost = 4, [int]$Count = 5,
    [string[]]$ExcludeName = @('*vsp*', '*auto-platform*', '*-cp-*', 'vCLS*', 'SupervisorControlPlaneVM*'),
    [string[]]$Extra = @()
)
$ErrorActionPreference = 'Stop'
# pwsh -File 呼叫時陣列參數會變成一個 'a,b' 字串 → 一律再切一次
$Extra = @($Extra | ForEach-Object { $_ -split ',' } | Where-Object { $_ }); $ExcludeName = @($ExcludeName | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
if (-not $env:VIPASS) { throw '先設定 $env:VIPASS（外層 vCenter 密碼）' }
Import-Module VMware.VimAutomation.Core -ErrorAction Stop | Out-Null
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -ParticipateInCEIP $false -Confirm:$false -Scope Session | Out-Null
$vc = Connect-VIServer $VCenter -User $User -Password $env:VIPASS -Force -WarningAction SilentlyContinue
function Test-Loss([string]$Ip) {
    $r = @(Test-Connection $Ip -Count $Count -TimeoutSeconds 1 -ErrorAction SilentlyContinue)
    $ok = @($r | Where-Object Status -eq 'Success')
    [pscustomobject]@{ LossPct = [int](($Count - $ok.Count) / $Count * 100); AvgMs = $(if ($ok.Count) { [int]($ok | Measure-Object Latency -Average).Average } else { $null }) }
}
$rows = [System.Collections.Generic.List[object]]::new()
foreach ($h in Get-VMHost -Server $vc | Sort-Object Name) {
    $mgmt = @($h.ExtensionData.Config.Network.Vnic | Where-Object { $_.Device -eq 'vmk0' } | ForEach-Object { $_.Spec.Ip.IpAddress })[0]
    if ($mgmt) { $t = Test-Loss $mgmt; $rows.Add([pscustomobject]@{ Host = $h.Name; Target = "(host vmk0)"; Ip = $mgmt; LossPct = $t.LossPct; AvgMs = $t.AvgMs }) }
    $cand = @(Get-VM -Server $vc -Location $h | Where-Object {
            $n = $_.Name; $_.PowerState -eq 'PoweredOn' -and -not ($ExcludeName | Where-Object { $n -like $_ }) } |
        ForEach-Object { $ip = @($_.Guest.IPAddress | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' -and $_ -notlike '169.254.*' })[0]; if ($ip) { [pscustomobject]@{ Name = $_.Name; Ip = $ip } } } |
        Select-Object -First $PerHost)
    foreach ($c in $cand) { $t = Test-Loss $c.Ip; $rows.Add([pscustomobject]@{ Host = $h.Name; Target = $c.Name; Ip = $c.Ip; LossPct = $t.LossPct; AvgMs = $t.AvgMs }) }
}
foreach ($ip in $Extra) { $t = Test-Loss $ip; $rows.Add([pscustomobject]@{ Host = '(extra)'; Target = $ip; Ip = $ip; LossPct = $t.LossPct; AvgMs = $t.AvgMs }) }
$rows | Format-Table -AutoSize | Out-String -Width 200
"== 依 host 彙總（平均掉包）"
$rows | Group-Object Host | ForEach-Object { '{0,-16} 平均掉包 {1,3}%（{2} 個目標）{3}' -f $_.Name, [int]($_.Group | Measure-Object LossPct -Average).Average, $_.Count, $(if (($_.Group | Measure-Object LossPct -Average).Average -ge 50) { '  🔴 先查這台的實體上行（Get-HostUplinkHealth.ps1）' } else { '' }) }
Disconnect-VIServer $vc -Confirm:$false
