<#
.SYNOPSIS
  外層 host 重開後「只開回出事前在跑的 VM」—— 平時 -Save 存一份開機清單，出事重開後 -Restore 照清單開。

.DESCRIPTION
  外層 ESXi 重開後 VM 不會自己開（沒設 autostart）。這時「全部開起來」很危險：
    - 備援 router（route-bak）、新舊兩台 depot（rhel-depot / rhel-depot-old）原本就是關的，開了會撞 IP / 路由
    - nested lab 有順序：NFS server VM → nested ESXi → nested vCenter / NSX / SDDC Manager → VSP → VCF Automation → 工作負載
  -Save    把每台外層 host 上 PoweredOn 的 VM 存成 JSON（唯讀；建議排程每天存一次）
  -Restore 讀 JSON，把清單裡現在是關機的開回來；-First 指定先開的 VM（例：NFS server），開完等 -FirstWaitSec 秒
           預設 DryRun，加 -Execute 才真的開機。清單外的 VM 一律不碰。
  nested 內部（nested vCenter 管的 VM）不在這支的範圍：用各 lab 的開機腳本（例 home lab m08 的 Resize-M08.ps1 -Step Start）。

.EXAMPLE
  $env:VIPASS = '<外層 vCenter 密碼>'
  ./Save-Restore-PoweredOnBaseline.ps1 -VCenter 10.0.0.101 -Save -Path .\poweredon-baseline.json
  ./Save-Restore-PoweredOnBaseline.ps1 -VCenter 10.0.0.101 -Restore -Path .\poweredon-baseline.json -HostName 10.0.0.95 -First vcd-nfs01            # DryRun
  ./Save-Restore-PoweredOnBaseline.ps1 -VCenter 10.0.0.101 -Restore -Path .\poweredon-baseline.json -HostName 10.0.0.95 -First vcd-nfs01 -Execute
#>
param(
    [Parameter(Mandatory)][string]$VCenter,
    [string]$User = 'administrator@vsphere.local',
    [Parameter(Mandatory, ParameterSetName = 'Save')][switch]$Save,
    [Parameter(Mandatory, ParameterSetName = 'Restore')][switch]$Restore,
    [string]$Path = '.\poweredon-baseline.json',
    [string[]]$HostName = @(),                       # 只處理這些 host（空 = 全部）
    [Parameter(ParameterSetName = 'Restore')][string[]]$First = @(),
    [Parameter(ParameterSetName = 'Restore')][int]$FirstWaitSec = 30,
    [Parameter(ParameterSetName = 'Restore')][switch]$Execute
)
$ErrorActionPreference = 'Stop'
# pwsh -File 呼叫時陣列參數會變成一個 'a,b' 字串 → 一律再切一次
$HostName = @($HostName | ForEach-Object { $_ -split ',' } | Where-Object { $_ }); $First = @($First | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
if (-not $env:VIPASS) { throw '先設定 $env:VIPASS（外層 vCenter 密碼）' }
Import-Module VMware.VimAutomation.Core -ErrorAction Stop | Out-Null
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -ParticipateInCEIP $false -Confirm:$false -Scope Session | Out-Null
$vc = Connect-VIServer $VCenter -User $User -Password $env:VIPASS -Force -WarningAction SilentlyContinue
$hosts = @(Get-VMHost -Server $vc | Where-Object { -not $HostName.Count -or $HostName -contains $_.Name })

if ($Save) {
    $data = [ordered]@{ SavedAt = (Get-Date).ToUniversalTime().ToString('o'); VCenter = $VCenter; Hosts = [ordered]@{} }
    foreach ($h in $hosts) { $data.Hosts[$h.Name] = @(Get-VM -Server $vc -Location $h | Where-Object PowerState -eq 'PoweredOn' | Sort-Object Name | ForEach-Object Name) }
    $data | ConvertTo-Json -Depth 5 | Set-Content -Path $Path -Encoding utf8
    foreach ($k in $data.Hosts.Keys) { '{0,-16} {1,3} 台開機中' -f $k, @($data.Hosts[$k]).Count }
    "→ $Path"
} else {
    $b = Get-Content -Path $Path -Raw -Encoding utf8 | ConvertFrom-Json
    "清單時間 $($b.SavedAt)$(if (-not $Execute) { '  [DryRun：加 -Execute 才開機]' })"
    foreach ($h in $hosts) {
        $want = @($b.Hosts.($h.Name))
        if (-not $want.Count) { "$($h.Name)：清單裡沒有這台 host 的資料，跳過"; continue }
        $vms = @(Get-VM -Server $vc -Location $h)
        $order = @($First | Where-Object { $want -contains $_ }) + @($want | Where-Object { $First -notcontains $_ })
        foreach ($n in $order) {
            $vm = $vms | Where-Object Name -eq $n | Select-Object -First 1
            if (-not $vm) { '  {0,-34} 不在這台 host 上（搬走了？）' -f $n; continue }
            if ($vm.PowerState -eq 'PoweredOn') { '  {0,-34} 已開' -f $n; continue }
            if ($Execute) {
                try { Start-VM -VM $vm -Confirm:$false | Out-Null; '  {0,-34} power on' -f $n } catch { '  {0,-34} 開機失敗：{1}' -f $n, $_.Exception.Message.Split("`n")[0] }
                if ($First -contains $n) { Start-Sleep -Seconds $FirstWaitSec }
            } else { '  {0,-34} would power on' -f $n }
        }
        $extra = @($vms | Where-Object { $_.PowerState -eq 'PoweredOff' -and $want -notcontains $_.Name } | ForEach-Object Name)
        if ($extra.Count) { "  （清單外、維持關機：$($extra -join ', ')）" }
    }
}
Disconnect-VIServer $vc -Confirm:$false
