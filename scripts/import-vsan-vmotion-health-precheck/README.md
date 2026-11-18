# 匯入 precheck 被 vSAN vMotion health 擋住 — 腳本

處理步驟與原因說明請看 [deliverables/import-vsan-vmotion-health-precheck](../../deliverables/import-vsan-vmotion-health-precheck/README.md)。

## 給客戶環境用

| 腳本 | 在哪裡跑 | 做什麼 |
|---|---|---|
| `Set-VsanVmotionSilence.ps1` | 任何裝了 PowerCLI 的 Windows | `-Action Show`、`Retest`（唯讀）、`Silence`、`Unsilence`。印出 vSAN Network 類別每一項的狀態，紅燈的 vMotion 檢查會把 Failed connections 的主機名稱一起列出。silence 預設 `vmotionpinglarge` |
| `guardrail-importance.sh` | **SDDC Manager，root** | `show`、`apply`、`revert`。把匯入 precheck 的 `Cluster common datastore check.` 從 CRITICAL 降成 WARNING（加入 `validationImportanceLevel`），以及還原。會自動備份到 `/root/esx-upgrade-shared.json.orig`、驗證 JSON、保留原本權限 |

```
# PowerCLI
.\Set-VsanVmotionSilence.ps1 -Server <vcenter-fqdn> -Cluster <cluster> -Action Retest
.\Set-VsanVmotionSilence.ps1 -Server <vcenter-fqdn> -Cluster <cluster> -Action Silence -Checks vmotionpinglarge
.\Set-VsanVmotionSilence.ps1 -Server <vcenter-fqdn> -Cluster <cluster> -Action Unsilence -Checks vmotionpinglarge

# SDDC Manager（ssh vcf@<sddc-manager>，su -）
bash guardrail-importance.sh show
bash guardrail-importance.sh apply      # 匯入前
bash guardrail-importance.sh revert     # 匯入後，會比對備份並回報 IDENTICAL
```

兩支都在 VCF 9.1.1 實驗室實測過：guardrail 的 apply、重複 apply、revert 後與原檔完全相同；Show 和 Retest 在 vSAN cluster 上正常。silence 和 unsilence 用的是同一組 vSAN health API（`VsanHealthSetVsanClusterSilentChecks`），已在重現環境驗證過，precheck 會變成 SUCCESSFUL。

> `guardrail-importance.sh` 是非官方支援的調整，使用前請看處理文件第 6 章的注意事項。

## lab-repro/（實驗室重現用）

在 home lab 的外層 vCenter 上建一套拋棄式環境 i05，重現並驗證五種情境（第 9 章的 A 到 E）。

| 順序 | 腳本 | 說明 |
|---|---|---|
| 1 | `Set-I05Dns.ps1 -Action Add` | DNS A/PTR 10.0.1.183-186 |
| 2 | `Deploy-I05-NestedESXi.ps1` | 3 台 nested ESXi 8.0U3b（esx01 多兩顆 SSD 給 vSAN，另有 datastore1 放 VCSA） |
| 3 | `Deploy-I05-Vcsa.ps1` + `vcsa-i05.template.json` | VCSA 9.1.1 tiny 部到 esx01（co-located），約 40 分鐘 |
| 4 | `Build-I05.ps1` | DC、cluster（DRS FullyAutomated）、VDS 1500、mgmt/vMotion/vSAN vmk、vSAN OSA all-flash |
| 5 | `Vsan-Health.ps1 -Action Show\|Importer\|Silence\|Unsilence` | 看 vSAN health，以及做 silence/unsilence |
| 6 | `Set-I05VmotionBreak.ps1 -Action BreakMtu\|RestoreMtu\|Break\|Restore` | 製造「只有 MTU 紅」（vmk 9000 / VDS 1500）或「兩項都紅」（vmk 換子網） |
| 7 | `run_precheck.py <label>` | 對 SDDC Manager 打 `POST /v1/sddcs/imports/validations`，存結果並列出 datastore 檢查 |
| 8 | `kb314607-m08.sh show\|apply\|revert` | 在 SDDC Manager 套用或還原 KB 314607（驗證無效用） |
| 9 | `Teardown-I05.ps1` | 刪除 3 台外層 VM 和 DNS |

環境變數：`VIPASS`（外層 vCenter）、`ESXPASS`（nested root）、`VCPASS`（i05 vCenter SSO）、`LABPASS`（SDDC Manager）。

nested 環境要注意兩點，`Build-I05.ps1` 已經處理：
- 實測時 3 台主機的 `LSOM.lsomSlowDeviceUnmount` 不一致（esx01 是 1，esx02/03 是 0），vSAN「Advanced vSAN configuration in sync」變紅，單獨這一項就會擋住 precheck。腳本會統一設成 0。
- 範本會在部分主機的 vmk0 勾 vSAN，變成同一種流量有多個 vmk。腳本會把 vmk0 的 vMotion、vSAN tag 都取消。
