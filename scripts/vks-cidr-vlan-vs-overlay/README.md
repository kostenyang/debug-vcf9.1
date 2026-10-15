# vks-cidr-vlan-vs-overlay — 測試用腳本與 manifest

對應交付文件：[`../../deliverables/vks-cidr-vlan-vs-overlay/`](../../deliverables/vks-cidr-vlan-vs-overlay/)

| 檔案 | 用途 |
|---|---|
| `vks-cidr-vlan.yaml` | VLAN-backed VPC 測試叢集（Service 100.64.0.0/13 / Pod 100.96.0.0/18，primary = SubnetSet public） |
| `vks-cidr-overlay-nonet.yaml` | overlay 測試叢集（同 CIDR；不帶 `networks` 變數，走 namespace 預設 vm-default Private subnet） |
| `demo.yaml` | 驗證用：nginx ×2 + LoadBalancer + busybox nettest（image 來自內部 Harbor） |
| `subnetset-private.yaml` | 探針：在 VLAN-backed Supervisor 建 Private SubnetSet 會被 webhook 擋（證明 networkStack） |
| `overlay_sv.py` | Playwright over CDP（Chrome `--remote-debugging-port=9222` 已登入 vSphere Client）跑 Supervisor 啟用精靈，逐頁截圖、印出 Workload Network 頁欄位；加 `--finish` 才按 FINISH |

VLAN-backed → overlay 的 NSX API 切換步驟（TGW span / VNA ha_over_management_interface / profile private block + Auto SNAT / 主機 TEP）見交付文件 §5.1。
