# VCF 9.1.1 匯入 vCenter：「Cluster common datastore check」被 vSAN vMotion 健康檢查擋住

> 適用：VCF 9.1.1，在 VCF Operations 執行 **Import a vCenter**（匯入成 VI workload domain）時的 Prechecks
> 實測版本：SDDC Manager 9.1.1.0 build 25713929、vCenter 9.1.1、ESXi 8.0U3b（2026-11-18 實驗室重現與驗證）
> 文件性質：客戶處理步驟。內含一個**非官方支援**的 SDDC Manager 調整（第 6 章），使用前請先評估。

## 1. 症狀

匯入精靈的 **Prechecks** 頁出現 1 個 Error，NEXT 按鈕是灰的：

| 欄位 | 內容 |
|---|---|
| Validation Name | `Cluster common datastore check.` |
| Error Description | `No common datastore (vSAN, NFS, or FC) matches import criteria. VSAN storage cannot be used as primary datastore for cluster <cluster> because of failure in [vsanVmotionUnicastConnectivityCheckStatus, vsanVmotionMtuConnectivityCheckStatus]` |
| Object Impact | `Dynamic` / `<cluster>` / `cluster` |
| Remediation | `Please check if the cluster has common datastore for all hosts.` |

方括號內可能只有其中一項，例如 unicast 修好之後只剩 `[vsanVmotionMtuConnectivityCheckStatus]`。

在 vCenter 的 **Cluster → Monitor → vSAN → Skyline Health → Network** 會看到對應的紅燈，例如 **vMotion: MTU check (ping with large packet size)**，Risk 欄寫著 `VMotion might fail, or run with degraded performance.`

> 訊息雖然寫「No common datastore」，**datastore 本身其實沒有問題**。真正的原因是 vSAN cluster 的 Skyline Health 有紅燈，所以匯入程式不讓 vSAN 當 primary datastore。

## 2. 原因

匯入 precheck 的 `Cluster common datastore check.`（validator 名稱 `primary-data-store-pre-import-validator`，等級 CRITICAL）在共用 datastore 是 vSAN 時，會向 vCenter 讀取該 cluster 的 **vSAN Skyline Health** 結果。只要清單裡有任何一項狀態不被接受，vSAN 就會被排除在 primary datastore 候選之外。如果 cluster 又沒有 NFS v3 或 FC 共用 datastore 可以替代，就會出現上面的 Error。

報錯欄位與 Skyline Health 檢查的對應：

| 報錯欄位 | Skyline Health 檢查（Network 類別） | test ID |
|---|---|---|
| `vsanVmotionUnicastConnectivityCheckStatus` | vMotion: Basic (unicast) connectivity check | `vmotionpingsmall` |
| `vsanVmotionMtuConnectivityCheckStatus` | vMotion: MTU check (ping with large packet size) | `vmotionpinglarge` |

匯入程式怎麼看 Skyline Health 的狀態：

| Skyline Health 狀態 | 匯入檢查 |
|---|---|
| green / info | 通過 |
| **yellow** | **通過**（只記 log，不擋） |
| **skipped**（該項被 Silence） | **通過** |
| red，或讀不到結果 | **失敗** |

補充說明：

- 同一份清單還包含 vSAN 網路、磁碟、HCL、進階設定同步（advcfgsync）、clomd 等檢查。**方括號裡列的就是紅燈的那幾項**，處理方式都一樣：讓它不再是紅燈。
- **vMotion MTU check** 會在所有 vMotion vmk 之間用 DF（不分片）送出「vmk MTU − 28」大小的 ping，例如 MTU 9000 時送 8972 bytes。**unicast 綠燈、MTU 紅燈 = 小封包通、大封包不通 = 整條路徑的 MTU 不一致。**
- 這道檢查在 VCF 端**沒有任何 skip property**。網路上找得到的 KB 314607 並不適用（見第 7 章）。

## 3. 處理方式總覽

| 順序 | 方法 | 在哪裡改 | 建議程度 |
|---|---|---|---|
| A | 修正 vMotion 網路（MTU、連通性） | ESXi vmk、VDS、實體網路 | ✅ **建議**，根本解決 |
| B | 在 Skyline Health 把該項 **Silence** | vCenter | 可以，匯入完成後解除 Silence，並排程做 A |
| C | 把這道 precheck 從 CRITICAL **降成 WARNING** | SDDC Manager（root） | ⚠ 最後手段，**非官方支援**，匯入完成後一定要還原 |
| ✗ | KB 314607（`validation.disable.vmotion.connectivity.check`） | SDDC Manager domainmanager | **無效**（實測確認） |

## 4. 方法 A：修正 vMotion 網路（建議）

### 4.1 找出失敗的主機配對

1. vSphere Client → 選取 cluster → **Monitor → vSAN → Skyline Health**。
2. 展開 **Network**，點 **vMotion: Basic (unicast) connectivity check** 和 **vMotion: MTU check (ping with large packet size)**。
3. 按右上角 **RETEST**，然後看 **Failed connections** 表：From Host / To Host / To Device / Packet Size / Connection Result。

> 結果上有「Occurred on」時間戳記，是**上次測試**的結果。任何修改之後都要先按 RETEST 再判讀。

### 4.2 在 ESXi 上確認設定（每台主機）

用 SSH 登入 ESXi：

```
# 每個 vmk 的 IP、MTU、TCP/IP stack
esxcli network ip interface list
esxcli network ip interface ipv4 get

# 確認哪個 vmk 是 vMotion
esxcli network ip interface tag get -i vmk1

# VDS 的 MTU
esxcli network vswitch dvs vmware list | grep -E "Name|MTU"
```

用 vmkping 測大小封包（`<peer>` 填另一台主機的 vMotion IP）：

```
# vMotion vmk 在「vMotion TCP/IP stack」上
vmkping -I vmk1 -S vmotion -d -s 8972 <peer>
vmkping -I vmk1 -S vmotion -d -s 1472 <peer>

# vMotion vmk 在 default TCP/IP stack 上（拿掉 -S vmotion）
vmkping -I vmk1 -d -s 8972 <peer>
vmkping -I vmk1 -d -s 1472 <peer>
```

### 4.3 判讀

| `-s 8972` | `-s 1472` | 判讀 |
|---|---|---|
| 不通 | 通 | **路徑不支援 jumbo frame**：vmk 是 9000，但中間某段（交換器 port、交換器之間的 trunk、防火牆）只有 1500 |
| 不通 | 不通 | **L2/L3 根本不通**：VLAN ID、子網、vMotion stack 的 gateway、teaming 的 active uplink 接到不同交換器、防火牆擋 ICMP、同一台主機有多個 vMotion vmk |
| 通 | 通 | 網路已正常，回 Skyline Health 按 RETEST |

### 4.4 修正 MTU（擇一）

**選項 1：整條路徑開 jumbo frame**（維持 vMotion 9000）

- 請網路組把 vMotion VLAN 經過的**每一段**都調到 ≥ 9000（交換器常見設定 9216），包括主機接的 port、交換器之間的 trunk 或 port-channel、經過的防火牆或路由介面。
- VDS MTU 要 ≥ 9000：Networking → 選取 VDS → **Configure → Settings → Properties → EDIT → Advanced → MTU (Bytes)**。

**選項 2：vMotion vmk 改回 1500**（不動實體網路，DMZ 環境通常最快）

- vSphere Client：Host → **Configure → Networking → VMkernel adapters** → 選 vMotion vmk → **EDIT** → **NIC settings → MTU = 1500**，每台主機都要改。
- 或用 PowerCLI 一次改整個 cluster：

```
Get-Cluster <cluster> | Get-VMHost | Get-VMHostNetworkAdapter -VMKernel |
  Where-Object { $_.VMotionEnabled } |
  Set-VMHostNetworkAdapter -Mtu 1500 -Confirm:$false
```

- VDS MTU 可以維持 9000。調整 vmk MTU 不會中斷 VM，vMotion 在 1500 下完全支援，只是大量搬遷時效率較低。

### 4.5 驗證

1. Skyline Health → **RETEST**，確認兩項 vMotion 檢查都變成綠燈（黃燈也可以）。
2. 回到匯入精靈按 **BACK → NEXT**，重新執行 Prechecks。

## 5. 方法 B：在 Skyline Health 把該項 Silence

適用情境：已確認 vMotion 實際可用（例如 1500 正常、只是 jumbo 沒通），但網路修正需要排時程，匯入不能等。

1. vSphere Client → cluster → **Monitor → vSAN → Skyline Health**。
2. 點紅燈的那一項（例如 **vMotion: MTU check (ping with large packet size)**）→ **SILENCE ALERT**。
3. 按 **RETEST**，該項會變成 silenced 狀態（API 回傳 `skipped`）。
4. 回匯入精靈按 **BACK → NEXT** 重跑 Prechecks。實驗室實測結果：`Cluster common datastore check.` = **VALIDATION_SUCCESSFUL**。
5. **匯入完成後**回到同一頁，對該項取消 Silence，並依第 4 章修正網路。

也可以用 PowerCLI 腳本處理：[scripts/import-vsan-vmotion-health-precheck](../../scripts/import-vsan-vmotion-health-precheck/) 的 `Set-VsanVmotionSilence.ps1`（`-Action Show|Retest|Silence|Unsilence`）。

> 用 API silence 時要給**短 ID**（`vmotionpinglarge`、`vmotionpingsmall`）；給完整 ID `com.vmware.vsan.health.test.vmotionpinglarge` 會回 `General vSAN error`。

> ⚠ Silence 只是讓匯入程式看不到紅燈，vMotion 大封包不通的事實還在：之後主機升級進 Maintenance Mode、DRS 搬遷時仍可能失敗或變慢。

## 6. 方法 C：在 SDDC Manager 把這道檢查降成 WARNING（最後手段）

> ⚠ **非官方支援的調整**，建議先開 SR 取得原廠同意。只在確認 datastore 本身沒問題、而且方法 A、B 都不可行時使用。**匯入完成後一定要還原。**

原理：匯入 precheck 的定義檔（guardrail）放在 SDDC Manager 磁碟上。validator 的嚴重等級由定義檔 `extraArgs` 中的 `validationImportanceLevel` 決定，沒寫時預設 CRITICAL。VMware 自己在 remove-cluster、remove-host 的 guardrail 裡也用 `"validationImportanceLevel": "WARNING"` 這個寫法。改成 WARNING 後，這道檢查失敗只會顯示 Warning，精靈的 NEXT 可以按。

檔案位置：

```
/opt/vmware/vcf/operationsmanager/scripts/assessment/guardrails/common/targetstates/esx-upgrade-shared.json
```

### 6.1 步驟

1. 先替 SDDC Manager 做快照或備份。
2. `ssh vcf@<sddc-manager>`，然後 `su -` 切成 root。
3. 備份原檔，並記下原本的權限（原廠預設是 555、owner `vcf_operationsmanager`）：

```
F=/opt/vmware/vcf/operationsmanager/scripts/assessment/guardrails/common/targetstates/esx-upgrade-shared.json
cp -p $F /root/esx-upgrade-shared.json.orig
stat -c '%a %U:%G' $F
```

4. 編輯：找到 `"id": "primary-data-store-pre-import-validator"` 那一段，在它的 `extraArgs` 加一行（注意上一行結尾要補逗號）：

```
修改前：
      "extraArgs": {
        "checkType": "${checkType}",
        "existingDatastoreName": "${existingDatastoreName}"
      },

修改後：
      "extraArgs": {
        "checkType": "${checkType}",
        "existingDatastoreName": "${existingDatastoreName}",
        "validationImportanceLevel": "WARNING"
      },
```

```
chmod u+w $F
vi $F
python3 -c "import json;json.load(open('$F'));print('JSON OK')"
chmod 555 $F
```

5. **不需要重啟任何服務**，實驗室實測改完立即生效。
6. 回匯入精靈按 **BACK → NEXT** 重跑 Prechecks。`Cluster common datastore check.` 會變成 **WARNING**，NEXT 可以按。
7. **匯入完成後還原**：

```
cp -p /root/esx-upgrade-shared.json.orig $F
cmp $F /root/esx-upgrade-shared.json.orig && echo RESTORED
```

也可以用腳本完成第 3 到第 7 步：[scripts/import-vsan-vmotion-health-precheck](../../scripts/import-vsan-vmotion-health-precheck/) 的 `guardrail-importance.sh show|apply|revert`（在 SDDC Manager 上以 root 執行，會自動備份、驗證 JSON、還原權限）。

### 6.2 注意事項

- 改的是**整道** `Cluster common datastore check.`。修改期間，「真的沒有共用 datastore」「vSAN 其他 health 紅燈」這類情況也只會顯示 Warning，所以操作前要自己確認 datastore 正常。
- 修改期間，**所有**透過這台 SDDC Manager 執行的匯入都會受影響。匯入完成後立刻還原。
- 實驗室驗證到 **precheck 結果改變**為止，**實際匯入流程跑完並未在實驗室驗證**。
- SDDC Manager 升級可能覆蓋這個檔案；不論是否升級，都應主動還原。

## 7. 為什麼 KB 314607 沒有用

KB 314607（*Skip vMotion validation for VMware Cloud Foundation workflows where vMotion connectivity is actually successful*）的做法是在 `/etc/vmware/vcf/domainmanager/application.properties` 加 `validation.disable.vmotion.connectivity.check=true`，再 `systemctl restart domainmanager`。

- 這個 property 只會被 **add host、create cluster、create workload domain、stretch cluster** 這些工作流程中的 vMotion 連線驗證步驟讀取，KB 本身列的也只有這幾種作業。
- 匯入 precheck 的 `Cluster common datastore check.` 是另一套 assessment 驗證（operationsmanager），程式裡**沒有讀這個 property**。
- **實驗室實測**：在 vMotion MTU 紅燈的狀態下套用 KB 314607 並重啟 domainmanager，precheck 結果仍是 `VALIDATION_FAILED / CRITICAL / ERROR`，訊息完全相同。

同一套程式裡另外兩個看起來像開關的 property 也都不適用：

| Property | 實際作用 |
|---|---|
| `assessment.validation.external.disable` | 只控制 Python 外部 validator 的執行器，不影響這道 native validator |
| `skip.assessment.external.validation.hostVmkTrafficTypeValidator` | 只跳過 vmk traffic type 那一道檢查 |

## 8. 附帶：Prechecks 頁出現「Something went wrong … Reference token」

精靈上方出現 `Something went wrong. Please retry or contact the service provider and provide the reference token. Reference token: XXXXXX`，表示精靈呼叫後端 API 時失敗，跟上面的 datastore 檢查是兩件事。

1. 先按 **BACK → NEXT** 重跑一次 Prechecks。
2. 如果還是出現，用 root 登入 SDDC Manager，用 token 找出真正的錯誤：

```
grep -r XXXXXX /var/log/vmware/vcf/
zgrep XXXXXX /var/log/vmware/vcf/*/*.gz
```

3. 找不到的話收集 SDDC Manager log bundle，連同 reference token 開 SR。

## 9. 實驗室驗證結果

環境：SDDC Manager 9.1.1.0（build 25713929）。被匯入端是另建的 vCenter 9.1.1 tiny（co-located）加上 3 台 nested ESXi 8.0U3b 組成的 vSAN OSA cluster，VDS MTU 1500。用 SDDC Manager API `POST /v1/sddcs/imports/validations`（與精靈相同的檢查，共 70 項）。

| # | 狀態 | `Cluster common datastore check.` 結果 |
|---|---|---|
| A0 | vSAN 進階設定不一致（advcfgsync 紅） | FAILED：`failure in [clusterAdvancedVsanConfigInSyncStatus]`，證明任一項 vSAN health 紅燈都會擋 |
| A | vMotion 兩項 green | **VALIDATION_SUCCESSFUL** |
| B | vMotion vmk MTU 9000、VDS 1500 → **只有 MTU check 紅**（所有主機配對 8972 bytes 失敗） | **FAILED / CRITICAL / ERROR**：`failure in [vsanVmotionMtuConnectivityCheckStatus]`（與客戶現象相同） |
| C | B + KB 314607（property=true + 重啟 domainmanager） | **仍為 FAILED / CRITICAL / ERROR** |
| D | B + 方法 C（guardrail 加 `validationImportanceLevel: WARNING`，未重啟） | **FAILED / WARNING / WARNING**，不再是 Error |
| E | B + 方法 B（Silence `vmotionpinglarge`，health API 回 `skipped`） | **VALIDATION_SUCCESSFUL** |
| 還原 | vMotion vmk 改回 1500、解除 Silence | 兩項 vMotion 檢查回到 green |

測試完成後，SDDC Manager 上被修改的兩個檔案都已還原，用 `cmp` 確認與原檔完全相同。完整摘要見 [evidence/precheck-summary.md](evidence/precheck-summary.md)，重現腳本見 [scripts/import-vsan-vmotion-health-precheck/lab-repro](../../scripts/import-vsan-vmotion-health-precheck/lab-repro/)。

## 10. 附錄

### 10.1 程式依據（SDDC Manager 9.1.1，operationsmanager）

| 元件 | 內容 |
|---|---|
| `ClusterPrimaryDataStorePreImportValidator` | validator ID `primary-data-store-pre-import-validator`。共用 datastore 為 vSAN 時呼叫 vSAN Skyline Health 檢查；失敗時組出 `VSAN storage cannot be used as primary datastore for cluster %s because of failure in %s`。等級由 `NativeValidatorUtil.getImportanceLevel` 讀 guardrail `extraArgs.validationImportanceLevel`，未設定則為 CRITICAL |
| `VsanSkylineHealthChecksUtil` | 允許狀態 = green / info / yellow / skipped（skipped 對應 silenced）；其餘一律失敗 |
| `VsanNetworkingHealthUpdater` | `vsanVmotionUnicastConnectivityCheckStatus` = health group `com.vmware.vsan.health.test.network` 的 `vmotionpingsmall`；`vsanVmotionMtuConnectivityCheckStatus` = `vmotionpinglarge` |
| guardrail 定義 | `.../guardrails/common/targetstates/esx-upgrade-shared.json`（由 `operations/import/import.json` 引用） |
| feature toggle `feature.vcf.vgl-36169.brownfield.import.storage` | 只控制 NFS/FC 的判斷分支；vSAN 的 health 檢查不受影響 |

### 10.2 參考資料

- Broadcom KB 314607：Skip vMotion validation for VMware Cloud Foundation workflows where vMotion connectivity is actually successful（適用 add host、create cluster/WLD、stretch cluster，不適用匯入 precheck）
- VMware Cloud Foundation 9.1 文件：Import a vCenter / Supported Import Configurations
- vSAN Skyline Health：vMotion: Basic (unicast) connectivity check、vMotion: MTU check (ping with large packet size)

### 10.3 文件版本

| 版本 | 日期 | 說明 |
|---|---|---|
| v1.0 | 2026-11-18 | 初版；含 SDDC Manager 9.1.1 實驗室重現與驗證 |
