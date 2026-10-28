# outer-uplink-triage — 外層實體主機上行故障的分診 / 復原腳本

搭配 [09-outer-physical-uplink.md](../../09-outer-physical-uplink.md)。都只需要外層 vCenter 帳密（`$env:VIPASS`）與 VMware PowerCLI。

| 腳本 | 做什麼 | 會改東西嗎 |
|---|---|---|
| `Test-HostPingMatrix.ps1` | 依外層 host 分組 ping（host vmk0 + 每台 host 幾台 VM），一眼看出掉包是否集中在某台實體 host | 唯讀 |
| `Get-HostUplinkHealth.ps1` | 單台 host：vmnic link/duplex、esxcli 錯誤計數、上行 down/up 事件統計、vmnic 即時收送（自動標出「只送不收 / 只收不送」）、流量前 10 的 VM | 唯讀 |
| `Save-Restore-PoweredOnBaseline.ps1` | `-Save` 存每台 host 開機中的 VM 清單；host 重開後 `-Restore` 只開回清單裡的（預設 DryRun，`-Execute` 才開） | `-Restore -Execute` 會開機 |

```powershell
$env:VIPASS = '<外層 vCenter 密碼>'
./Test-HostPingMatrix.ps1 -VCenter 10.0.0.101 -Extra 10.0.1.141,10.0.1.144
./Get-HostUplinkHealth.ps1 -VCenter 10.0.0.101 -HostName 10.0.0.95 -Hours 24
./Save-Restore-PoweredOnBaseline.ps1 -VCenter 10.0.0.101 -Save -Path .\poweredon-baseline.json   # 平時就存
```

> Photon OS（VSP / VCF Automation 節點）擋 ICMP：ping 它們不通不代表壞，矩陣預設排除。
