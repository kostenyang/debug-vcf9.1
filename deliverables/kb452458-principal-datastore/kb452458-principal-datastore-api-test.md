# KB 452458 換 imported cluster principal datastore — SDDC Manager 9.1.1 API 實測（2026-09-13/14）

> 交付文件：`E:\9.1\VCF91-Imported-Cluster-Principal-Datastore-Change.docx`（generator `E:\9.1\tools\docx-build\gen-principal-ds-doc.js`）
> 腳本：`kostenyang/evs` → `kb452458-primary-datastore/`（endpoint 行為與 enum 表寫在那邊的 README）

- 環境：vcf-m02-sddcm01.home.lab / 10.0.1.18，SDDC Manager 9.1.1.0.25713928；vCenter vcf-m02-vc01 / 10.0.1.19
- 對象：網域 m01 `a53df574-d2d5-4906-a9a8-80d15608f501`，叢集 m01-cl01 `6a898ac1-0cff-4189-8631-8c7213a16363`（`domain-c9`）
- datastore MoRef：`datastore-15` = m01-cl01-ds-vsan01（VSAN）、`datastore-1048` = vcd-ds01（VMFS，拿來當「新 datastore」測）
- lab 沒有 imported cluster，只能驗 API 行為，不能驗真實換儲存後的 Add Host 檢核

## 背景

R&D 確認 UI 不支援改 imported cluster 的 principal datastore；KB 452458 的 REST 只更新 SDDC Manager 控制面 DB，
底層（Storage vMotion / FCD / vCLS / CL / Supervisor policy）全部手動。

## 拆 jar 手法

- `vcf` 使用者可讀 `/opt/vmware/vcf/commonsvcs/lib/vcf-commonsvcs.jar`（350 MB Spring Boot fat jar）
- appliance 沒 `unzip`，用 `python3 zipfile` 抽 nested jar，再 `jar xf` + `javap -p -c`（JDK 21 有）
- 相關 nested jar：`inventory-extensions-vi-controller`、`inventory-service-model`、`inventory-sql-dal-client`、`inventory-sql-dal-model`
- `psql` 走不通：postgres 要密碼、`vcf` sudo 只有 `/opt/vmware/sddc-support/sos`、root SSH 拒絕

## 測試紀錄

| # | 請求 | 結果 |
|---|---|---|
| A | `PUT /clusters/{id}` 只改 `primaryDatastoreName` | 200；重讀可見；`/v1/clusters/{id}` 的 `primaryDatastoreName` 仍是 vCenter 名稱 → 公開 API 名稱來自 vCenter |
| B | `PUT /clusters` body=原始 `{clusters, esxis}` | 200；記錄還原 → 整筆覆寫、round-trip 安全 |
| C | `PUT /clusters` 只有 clusters | 500 `VCF_RUNTIME_ERROR`（esxis 必填） |
| D | `primaryDatastoreType=VMFS_FC` | 🔴 200 但欄位變 null；`/v1/clusters/{id}` name/primaryDatastoreName/type/isDefault 全 null。用原 JSON PUT 回去立刻恢復 |
| 腳本 | `export → update(datastore-1048/VMFS) → verify → rollback`，再 `--kb-style` 一輪 | 全部 200，最後 v1 API = m01-cl01 / m01-cl01-ds-vsan01 / VSAN |

## 誤判提醒

- 內部 GET 匯出的 cluster **沒有 `name` / `primaryDatastoreName`** 是正常的（9.1 已 deprecated、DB 是 NULL），不是匯出壞掉
- `/v1/clusters/{id}` 整筆 null ≠ 叢集不見了，是 `primaryDatastoreType` 被寫成 null，還原記錄就好
- SDDC Manager 上的 `/tmp/invx`（拆 jar 暫存）已清
