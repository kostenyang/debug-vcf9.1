# 06 — 外層資源耗盡：CPU 超賣 / vSAN 容量 / PSOD / DRS

> nested lab 的「終極根因層」。上層 K8s/etcd/VCFA 的怪病，九成追到這裡：外層實體 CPU 超賣、外層 vSAN 撐爆、或 nested ESXi PSOD。**修上層前先確認這層健康。**

---

## 1. 外層 CPU 超賣 → nested ESXi 餓 CPU → etcd 死亡螺旋

因果鏈：
```
外層 SELAB-Cluster CPU 超賣  →  nested ESXi 搶不到實體 CPU（CPU ready 高）
   →  nested vSAN etcd fsync 暴增  →  控制平面 crashloop  →  VCFA 任務 timeout（RequestCanceled）
```

**量外層（連外層 vCenter，rtolab `172.16.10.100` / `administrator@vmwaresso.taiwan`）**：
```powershell
# 叢集 CPU 超賣率（>1 即超賣，本案曾 4.3x）
$cl=Get-Cluster 'SELAB-Cluster'; $on=Get-VM -Location $cl|?{$_.PowerState -eq 'PoweredOn'}
($on|measure NumCpu -Sum).Sum / (Get-VMHost -Location $cl|measure NumCpu -Sum).Sum
Get-VMHost -Location $cl | %{ '{0} {1:P0}' -f $_.Name,($_.CpuUsageMhz/$_.CpuTotalMhz) }

# nested ESXi CPU ready（>5~10% = 搶不到實體 CPU，本案曾 33%）
Get-VM 'vcf-m02-esx*-91' | %{ $r=Get-Stat $_ -Stat cpu.ready.summation -Realtime -MaxSamples 3
  '{0} ready~{1:N1}% host={2}' -f $_.Name,(($r|measure Value -Average).Average/200),$_.VMHost.Name }
```

**修**：對 4 台 nested ESXi 設 **CPU + disk shares = High**、nested FTT=0、**固定到專用 host**（MustRunOn）、給 CPU/Mem reservation（8GHz + 48GB 熱套）。修完底層 **別急著重啟 pod**，load 降後自癒。

---

## 2. 外層 vSAN 容量撐爆 → nested host 卡 no-space 凍結

外層 `vsanDatastore-RTO`（25.7TB）長期 90%+ 滿。任何加空間動作（FTT 調高、resync）會撐爆 → nested host 的 thin vmdk 卡「no more space」**凍結**。

```powershell
# 外層 vSAN 容量 + 預設 policy FTT（FTT=1 則每筆 nested 寫入翻倍）
Get-Datastore vsanDatastore-RTO | %{ '{0:P0} used' -f (1-$_.FreeSpaceGB/$_.CapacityGB) }
(Get-SpbmStoragePolicy 'vSAN Default Storage Policy').AnyOfRuleSets.AllOfRules  # hostFailuresToTolerate
```

**騰外層空間的安全做法**：
- 把不用的 lab（例 521）關機 + svMotion 到各 host **local datastore**。
- 其他 nested host **關機後逐台 consolidate**（running VM 一直寫會讓 consolidate 追不上）：
  ```powershell
  (Get-View -ViewType VirtualMachine -Filter @{Name='ESXi9-0X'}).ConsolidateVMDisks_Task()
  ```
  逐台做、確認 `ConsolidationNeeded=false` 再下一台。90%+ 滿盤 consolidate 極慢，但 VM 關機（無新寫入）不會撐爆。
- 等實體 vSAN resync 完：`esxcli vsan debug resync summary get`（`Total Bytes Left To Resync` 歸 0）。

> **鐵則：FTT=1 在這顆滿盤上不可行，永遠 FTT=0。** outer free 騰回 ~7–8TB（~68%）才安全。

---

## 3. nested ESXi PSOD / 掉線 → 硬 reset 救回

**判斷**：外層 VM `guestToolsNotRunning` + inner host `NotResponding`；VM 事件出現 `The CPU has been disabled by the guest operating system` = PSOD。

**修**：PSOD/guest halt 後 graceful 無效，外層 **硬 reset**：
```powershell
Restart-VM 'vcf-m02-esxXX-91' -Confirm:$false   # 硬 reset
```
等它 ping → 443 → inner Connected。host 回來後別忘了 CSI globalmount 可能死掛載（篇章 06 §2b）。

> ⚠️ **不要對跑 k8s 的 nested host 做 live vMotion**（churn 會再 PSOD）。要搬用 **cold-migrate**。落在 local datastore 的（如 esx01-521、vcf-installer-91）無法 compute-vMotion。

---

## 4. DRS：防無人看管時自動 vMotion 觸發連鎖災難

外層 DRS `fullyAutomated` 會自動 live-vMotion nested ESXi → 觸發 swsec stale（篇章 02）或直接 PSOD（見本篇 §3：nested ESXi 不要隨便 live-vMotion）。

**標準配置**：
- 外層 cluster DRS → **Manual**（待機防自動 vMotion）；要重建 VKS 時才臨時開 FullyAutomated。
- 各 nested VM **per-VM DRS = Manual**。
- 用 **VM-Host MustRunOn rule** 把 nested 釘到專用 host（rtolab：esx01/02→`172.16.10.4`、esx03/04→`172.16.10.6`）。

**⚠️ wipe 重建後 DRS VM group 成員會清空**（rule 和 host group 還在），要重填：
- `rtolab-vms-4` ← esx01,esx02；`rtolab-vms-6` ← esx03,esx04；`rtolab-nested-91` ← 全部 4 台。
- `MustNotRunOn` 類（`other-nested-keep-off-46`）會自己存活（引用的 VM 還在）。
- 也要擋其他 nested 進專用 host（撞 MAC）。

---

## 5. inner cluster HA：FTT=0 lab 必須關 Admission Control

FTT=0 容量吃緊，HA admission control 會擋住 VM/pod 開機 → conductor in-memory 任務孤兒化、pod 一直重啟。
**Define host failover capacity by = Disabled。**（supervisor 啟用要求 HA 開著時，仍要 admission control 關。）

---

## 6. 兩個獨立故障點別混淆（救 vc 時最大誤判）

救 inner vc 卡 inaccessible 時，最容易以為「只是外層空間不夠」。實際是**兩個獨立故障點**，空間夠了 vc 也不一定回來：

1. **外層 vSAN 滿**（本篇 §2）—— 加空間動作會撐爆 nested。
2. **inner vSAN disk 沒進 CMMDS**（篇章 03 §B）—— disk healthy 但沒 publish → 物件 inaccessible。

**正確順序：先騰外層空間 → 再修 inner CMMDS → 物件 accessible → 開 vc → 補服務 → 救上層。**

---

來源：rtolab `docs/debug-vcfa-nested-cheatsheet.md`、`docs/recovery-2026-06-vsan-cmmds-to-vks-rebuild.md`、lab-info `runbooks/golden-ova.md`、memory `project_outer_vsan_capacity_incident`、`feedback_nested_esxi_no_vmotion`、`feedback_inner_ha_admission_disabled`、`feedback_vsan_ftt0`、`project_vmx19_psod_fix`。
