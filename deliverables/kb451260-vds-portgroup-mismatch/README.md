# KB 451260 — Cluster 擴充失敗：`PortGroup configuration mismatch detected for VDS`

> Broadcom KB：<https://knowledge.broadcom.com/external/article/451260>
> 本資料夾把 KB 的修法做成 **在 SDDC Manager 上執行的 script**，並在 VCF 9.1.1 lab **實機重現錯誤 → 修復 → 還原**驗證過（2026-10-20）。

| 檔案 | 內容 |
|---|---|
| [`kb451260-vds-remediate.sh`](kb451260-vds-remediate.sh) | 主程式（bash + curl + jq，SDDC Manager 內建都有） |
| [`evidence/`](evidence/) | 實測 log：基準 → 重現 → 修復 → 還原 → 邊界測試 |

---

## 1. 症狀

SDDC Manager UI → Workload Domain → Cluster → **Add Hosts** → 第 4 步 Validation：

| Validation check | Status |
|---|---|
| Validate Platform Infrastructure State for Cluster Expansion workflow | Succeeded |
| Validate Platform Storage State for Cluster | Succeeded |
| **Validate Network Infrastructure State for Cluster operations.** | **Failed** |
| Perform set of validations for current workflow | PENDING |
| Validate Cluster Expansion Specification | PENDING |

```
Error Description : PortGroup configuration mismatch detected for VDS [<vds>] in cluster <cluster>[<cluster-id>]
Remediation       : Sync the VDS [<vds>]configuration between vCenter and SDDC Inventory by using the remediate API
                    /v1/clusters/<cluster-id>/remediations to ensure consistency for cluster <cluster>. ...
```

同一個檢查還可能丟出另外兩種錯誤，修法相同（同一支 remediation API）：
`VDS [..] found in Inventory but not in vCenter`、`LAG configuration mismatch detected for VDS [..]`。

## 2. 根因（拆 SDDC Manager 9.1.1 jar 確認）

- 檢查在 domainmanager 的 `ClusterNetworkDiscoveryValidationImpl.comparePortGroupValues()`。
- SDDC inventory（platform DB 的 `vds.port_groups`）對每個 VDS 記一張表：**流量類型 → portgroup moref**，例如
  `MANAGEMENT:dvportgroup-21  VMOTION:dvportgroup-22  VSAN:dvportgroup-23  VM_MANAGEMENT:dvportgroup-24`。
- 驗證時，SDDC Manager 會依各主機 **vmk 目前實際接在哪個 PG**，從 vCenter 重新 discovery 出同樣一張表，然後比：
  - 兩邊 PG 數量不同 → mismatch
  - vCenter 這邊的（流量類型, moref）在 inventory 找不到 → mismatch
- 所以**比的是 moref，不是名稱**。在 vCenter 直接（out-of-band）做了以下事情就會中：
  - 新建一個 PG，把 vMotion / vSAN / Mgmt vmk 搬過去 ✅ 實測
  - inventory 記的那個 PG 被刪掉（vmk 已搬走）✅ 實測
  - 刪掉重建同名 PG（moref 會變）、把 vmk 搬到另一個 VDS（依程式邏輯推斷，未實測）

## 3. 修法

KB 官方步驟：

1. VCF Operations → Inventory → 選 Workload Domain → **Actions → Sync Inventory**。
2. 沒好的話，呼叫 SDDC Manager API：
   ```
   GET  /v1/clusters                                   → 找 cluster id
   POST /v1/clusters/{clusterId}/remediations          → body 見下
   ```
3. 確認完成後重試 cluster expansion。

KB 沒寫 request body，拆 jar 得到正確寫法（實測可用）：

```json
POST /v1/clusters/{clusterId}/remediations
{"name": "SDDC_NETWORKING_DATA_REMEDIATION"}
```

它是**非同步**的：回 `{"id":"<remediationId>","status":"IN_PROGRESS"}`，再用
`GET /v1/clusters/{clusterId}/remediations/{remediationId}` 查到 `COMPLETED` / `FAILED`（lab 約 5–6 秒）。
**不會**在 SDDC Manager 的 Tasks 清單出現。

remediation 做的事 = 以 vCenter 現況為準，重新 discovery 這個 cluster 的 VDS，覆寫 inventory 的 VDS 記錄。

## 4. Script 用法

script 在 SDDC Manager 本機打 `https://localhost` API，**vcf 帳號就能跑**；用 root 跑會多備份 platform DB 的 `vds` 原始資料列。

```bash
# 從跳板機傳上去（/tmp 是 noexec，一律用 bash 執行）
scp kb451260-vds-remediate.sh vcf@<sddc-manager>:~/
ssh vcf@<sddc-manager>

bash kb451260-vds-remediate.sh --list                       # 列出 cluster
bash kb451260-vds-remediate.sh -c <cluster名稱或id>          # 只檢查（唯讀，預設）
bash kb451260-vds-remediate.sh -c <cluster名稱或id> --remediate   # 檢查 → 備份 → 修 → 再檢查
```

密碼：預設會互動詢問 `administrator@vsphere.local` 的密碼（不回顯）；也可以 `export SDDC_PASSWORD=...`。
其他 SSO 帳號用 `-u`。

| 選項 | 說明 |
|---|---|
| `--remediate` | 執行 remediation（會先問 y/N，`--yes` 跳過） |
| `--force` | 檢查 PASS 也照樣執行 remediation |
| `--skip-check` | 不跑預檢，直接 remediation |
| `--host-id UUID` | 預檢用的主機 id（預設是一個不存在的佔位 id，見下） |
| `--out DIR` | log / 備份目錄（預設 `/tmp/kb451260-<時間>`） |
| `--timeout SEC` | 每個非同步工作的輪詢上限（預設 900） |

Exit code：`0` 正常 / 已修好、`1` 參數或 API 錯誤、`2` 仍有 mismatch、`3` remediation FAILED。

### 預檢是怎麼做的（不用準備備用主機）

script 呼叫的是 UI「Add Hosts → Validation」背後同一支 API：

```
POST /v1/clusters/{id}/validations?useAsyncValidation=true
{"clusterExpansionSpec":{"deployWithoutLicenseKeys":true,"interRackExpansion":false,
  "hostSpecs":[{"id":"<佔位 id>","hostNetworkSpec":{"vmNics":[...]}}]}}
```

前 4 項檢查（含網路那項）都會正常跑完，**最後一項 `Validate Cluster Expansion Specification` 會因為
`ESXi Host ... not found` 失敗 —— 這是預期的**，script 只看網路那一項的結果。這是唯讀 validation，不會改任何東西。
（不加 `useAsyncValidation=true` 的話是另一條同步驗證路徑，只會回 host not found，不會跑網路檢查。）

### 輸出

（T3 實際輸出節錄）

```
02:17:40  network infrastructure state (before): FAIL
02:17:40  POST /v1/clusters/85d45473-.../remediations {"name":"SDDC_NETWORKING_DATA_REMEDIATION"}
02:17:41  remediationId=8cdb7546-0445-4452-ae1f-86cd0e13be62 status=IN_PROGRESS
02:17:46  remediation 8cdb7546-0445-4452-ae1f-86cd0e13be62 -> COMPLETED
02:17:46  port groups in SDDC inventory (API view)  VDS|traffic|portgroup:
    before: vcf-m02-cl01-vds01|VMOTION|kb451260-oob-vmotion|vlan=0
    after : vcf-m02-cl01-vds01|VMOTION|vcf-m02-cl01-vds01-pg-vmotion|vlan=0
02:17:46  port group morefs in platform DB  dvs|traffic|moref:
    before: dvs-19|VMOTION|dvportgroup-81
    after : dvs-19|VMOTION|dvportgroup-22
02:18:03  network infrastructure state (after): PASS
```

`--out` 目錄裡會留：`run.log`、`vdses-before/after.json`（API 視角）、`db-vds-before/after.json`（root 才有）、
`validation-before/after.json`、`remediation-start/result.json`、完整 diff。

## 5. 注意事項

- **以 vCenter 為準**：remediation 會把 vCenter 現況寫回 inventory。如果 vCenter 那邊的變更本身是錯的（vmk 接錯 PG、VLAN 錯），
  先在 vCenter 改對再跑，不然只是把錯的狀態「合法化」。
- **不只改 portgroup**：它會重寫整筆 VDS 記錄。lab 實測一起變動的有：NIOC shares（level 變成 `custom`，並多出 `backupNfc` / `nvmetcp` / `provisioning`）、
  VDS 名稱欄位補上、`nsxt_switch_config` 多了 `hostSwitchOperationalMode`、portgroup 的 inventory id 換新。之後的 validation 都正常，但交付時要讓客戶知道。
- 同一個 cluster 的 remediation 正在跑時再送會回 `CLUSTER_REMEDIATION_ONGOING`。
- 若回 `Cluster remediation is not supported.`：feature toggle `feature.vcf.vgl-43403.sddcmanager.splitbrain` 是關的（9.1.1 lab 預設是開的）。
- 失敗細節看 `/var/log/vmware/vcf/domainmanager/domainmanager.log`（`grep -i -E "remediat|Port Group mismatch"`）。
  mismatch 的明細行長這樣：`Port Group mismatch: vCenter PG not found in inventory. TransportType=VMOTION, SourceId=dvportgroup-81, ...`
- 回復：要「改回來」的正確做法是 **先把 vCenter 改回去，再跑一次 remediation**（本次還原就是這樣做的）。
  root 模式留下的 `db-vds-before.json` 是存證用，不建議手動寫回 DB。

## 6. 實測紀錄（2026-10-20，SDDC Manager 9.1.1.0 Build 25713928，3 主機管理網域 cluster）

| # | 動作 | 結果 |
|---|---|---|
| T0 | 基準 `--check`（vcf 帳號） | 網路檢查 PASS，exit 0 |
| — | vCenter 新建 PG `kb451260-oob-vmotion`（複製原 vMotion PG 設定，dvportgroup-81），3 台 vmk1 搬過去 | out-of-band 變更 |
| T1 | `--check`（root） | **重現**：`PortGroup configuration mismatch detected for VDS [vcf-m02-cl01-vds01]`，後兩項 PENDING —— 與客戶畫面一致；exit 2 |
| T2 | `--remediate --yes` | remediation 6 秒 COMPLETED；DB `VMOTION: dvportgroup-22 → dvportgroup-81`；再檢查 PASS；exit 0 |
| — | 3 台 vmk1 搬回原 PG，刪掉 `kb451260-oob-vmotion` | 還原 vCenter（反向 mismatch：inventory 指向已刪除的 PG） |
| T3 | `--remediate --yes`（用 cluster id） | 偵測 FAIL → remediation COMPLETED → DB 回到 `dvportgroup-22` → PASS；exit 0 |
| T4 | 已正常時 `--remediate` | `nothing to remediate`，不送 POST；exit 0 |
| T5–T7 | 密碼錯 / cluster 名稱錯 / 不帶參數 | 明確錯誤訊息 exit 1 / 列出 cluster |
| T9 | 互動模式（不設 `SDDC_PASSWORD`） | 密碼提示不回顯；確認提示回 `n` → aborted，exit 1 |

lab 環境最後狀態與測試前相同（vmk1 回到 `vcf-m02-cl01-vds01-pg-vmotion`，測試用 PG 已刪除，預檢 PASS）。
