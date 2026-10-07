# KB 441333 — 把 VCF Automation 從 VCF fleet 正常移除（VCF 9.1.1 實測）

用 KB 441333 附的官方腳本 `cleanup_component.py`，在 SDDC Manager 上把 VCF Automation（VCFA）整套移除。
2026-10-07 在全新 greenfield 部署的 VCF 9.1.1（含 VCFA）上完整跑過一次：**是三步，不是兩步**。

| 步 | 指令 | 執行身分 | 實測耗時 |
|---|---|---|---|
| ① | `delete vsp-component -c <VCF Automation 元件 ID>` | vcf | 23 分 03 秒 |
| ② | `delete vsp-component -c <Migration service engine 元件 ID>`（list 裡叫 `VCD_MIGRATOR`） | vcf | 12 分 02 秒 |
| ③ | `delete vsp-cluster -c <VCFA services runtime ID>` | **root** | 3 分 10 秒 |

| 檔案 | 說明 |
|---|---|
| `KB441333-VCF-Automation-正常移除-StepByStep.docx` | 交付文件（21 頁，6 張圖，每條指令的完整輸出與前後截圖） |
| `build-kb441333.js` | 產生 docx 的腳本（docx-js）：`npm i docx` 後執行 `node build-kb441333.js`（路徑指向原始證據目錄，要自行調整） |
| `vcfa-official-removal-runbook.md` | Runbook：何時能用、三步的順序與參數、版本對刪除範圍的影響、移除後再加回的注意事項 |
| `m03-test-notes-20261007.md` | lab 實測紀錄（環境、步驟勾選、關鍵發現） |
| `diagrams/` | 三條指令各碰到哪裡的流程圖（HTML 原稿 + PNG） |
| 輔助腳本 | [`scripts/kb441333-vcfa-removal/`](../../scripts/kb441333-vcfa-removal/)（取 root、③ 的包裝） |

原始位置（仍保留）：private repo `vra-lifecycle` 的 `runbooks/vcfa-official-removal.md` 與 `runbooks/kb441333-vcfa-removal-20261007/`（含逐條 CLI 輸出與截圖原檔）。

`cleanup_component.py` 本身是 KB 附件（Broadcom Confidential），**不放在這個 public repo**，請從 KB 441333 下載。

重點坑：
- **VSP 認證帳號是 `admin`**；`administrator@vsphere.local` 對管理 VSP 與 VCFA runtime 都回 401。腳本會在刪除前先驗帳密。
- **Migration service engine 要單獨刪**：它和 VCFA 住在同一個 runtime 上。① 進行中 `list` 會暫時看不到它，但它沒被刪；腳本也不檢查 runtime 上還有沒有元件。③ 之前務必再 `list` 一次。
- **③ 要 root**：SDDC Manager 上 `vcf` 不在 sudoers，`su` 要 TTY → 用 `asroot.py`。
- **版本決定刪除範圍**：元件版本 ≥ 9.1 才會真的關機刪 VM、清 SDDC Manager platform DB；< 9.1（例如帳面停在 8.0.0）只清 Fleet 帳面。
- **DNS 不會被清**：VCFA 的 auto-vip / auto-platform 記錄要自己刪。
- 移除後再匯入 vRA 8：同一套 m03 實測照樣成功（沒有遇到 KB 441127 的 infrastructure properties NULL 問題）。
