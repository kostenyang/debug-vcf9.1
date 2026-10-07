# KB 452458 — 更換 Imported Cluster 的 Principal Datastore（SDDC Manager 9.1.1）

在 SDDC Manager 的 inventory 裡，把 imported cluster 的 principal datastore 改到新的 datastore。官方 UI 不支援，只能走 SDDC Manager 本機的 `http://localhost/inventory/extensions/vi` API。

| 檔案 | 說明 |
|---|---|
| `VCF91-Imported-Cluster-Principal-Datastore-Change.docx` | 交付文件（16 頁，純文字＋表格＋指令，沒有截圖） |
| `gen-principal-ds-doc.js` | 產生 docx 的腳本（docx-js）：`npm i docx` 後執行 `node gen-principal-ds-doc.js` |

相關：
- 腳本（export / update / verify / rollback）：[kostenyang/evs `kb452458-primary-datastore/`](https://github.com/kostenyang/evs/tree/main/kb452458-primary-datastore)
- 實測紀錄：[kostenyang/lab-info `runbooks/kb452458-principal-datastore-api-test.md`](https://github.com/kostenyang/lab-info/blob/main/runbooks/kb452458-principal-datastore-api-test.md)

重點坑：
- `PUT` 是**整筆覆寫**，要先用 `GET /domainInventory?domainIds=<id>` 匯出整筆再改。
- enum 打錯（例如 `VMFS_FC`）時 API 仍回 200，但欄位會被寫成 null；用原本的 JSON 再 PUT 一次就能還原。
- 9.x 真正有作用的欄位是 `primaryDatastoreSourceId`（vCenter MoRef）和 `primaryDatastoreType`。
- 適用範圍：lab 驗證的是 **imported cluster**。Management Domain 是否適用，請先跟原廠確認。
