# 匯入 precheck 實測摘要（2026-11-18，SDDC Manager 9.1.1.0 build 25713929）

每次都是 `POST /v1/sddcs/imports/validations` 對同一個 vCenter（3 台 nested ESXi 的 vSAN OSA cluster）。
下表只列 `Cluster common datastore check.` 這一列；`not successful` 中的其他項目都是與本題無關的已知項目
（API 最小 spec 沒帶 NSX 造成的 `NSX Manager host scale` INTERNAL_ERROR、vCenter VM dvPG Warning、ESXi upgrade policy Warning）。

| # | 情境 | 檢查總數 | not successful | validationStatus | importanceLevel | severity |
|---|---|---|---|---|---|---|
| A | vMotion 兩項 green（advcfgsync 修正後） | 70 | 3 | `VALIDATION_SUCCESSFUL` | `WARNING` | `INFO` |
| B | vMotion vmk MTU 9000 / VDS 1500 → 只有 MTU check 紅 | 70 | 4 | `VALIDATION_FAILED` | `CRITICAL` | `ERROR` |
| C | B + KB 314607（domainmanager property=true + restart） | 70 | 4 | `VALIDATION_FAILED` | `CRITICAL` | `ERROR` |
| D | B + guardrail validationImportanceLevel=WARNING（未重啟） | 70 | 4 | `VALIDATION_FAILED` | `WARNING` | `WARNING` |
| E | B + Skyline Health silence vmotionpinglarge | 70 | 3 | `VALIDATION_SUCCESSFUL` | `WARNING` | `INFO` |

## 訊息原文

- **A**：`Cluster has valid shared datastore`
- **B**：`No common datastore (vSAN, NFS, or FC) matches import criteria. VSAN storage cannot be used as primary datastore for cluster <cluster> because of failure in [vsanVmotionMtuConnectivityCheckStatus]`
- **C**：`No common datastore (vSAN, NFS, or FC) matches import criteria. VSAN storage cannot be used as primary datastore for cluster <cluster> because of failure in [vsanVmotionMtuConnectivityCheckStatus]`
- **D**：`No common datastore (vSAN, NFS, or FC) matches import criteria. VSAN storage cannot be used as primary datastore for cluster <cluster> because of failure in [vsanVmotionMtuConnectivityCheckStatus]`
- **E**：`Cluster has valid shared datastore`

## A0（第一次基準，nested 環境 vSAN 進階設定不一致）

`No common datastore (vSAN, NFS, or FC) matches import criteria. VSAN storage cannot be used as primary datastore for cluster <cluster> because of failure in [clusterAdvancedVsanConfigInSyncStatus]`

原因是 `LSOM.lsomSlowDeviceUnmount` 在 3 台主機上不一致（vSAN health「Advanced vSAN configuration in sync」紅）；統一後即為 A。

## vSAN health（B 狀態，RETEST 後）

| Test | 狀態 |
|---|---|
| vMotion: Basic (unicast) connectivity check（`vmotionpingsmall`） | green |
| vMotion: MTU check (ping with large packet size)（`vmotionpinglarge`） | red — 6 組主機配對、Packet Size 8972 全部 red |

Silence 後（E）：`vmotionpinglarge` testHealth = `skipped`，cluster overall 由 red 變 yellow。

## SDDC Manager 端的修改與還原

- C：`/etc/vmware/vcf/domainmanager/application.properties` 加 `validation.disable.vmotion.connectivity.check=true` → `systemctl restart domainmanager`；測完刪除該行，`cmp` 與備份相同。
- D：`.../guardrails/common/targetstates/esx-upgrade-shared.json` 的 `primary-data-store-pre-import-validator.extraArgs` 加 `"validationImportanceLevel": "WARNING"`；測完還原，`cmp` 與原檔相同。
