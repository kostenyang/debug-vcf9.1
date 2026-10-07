# KB 441333 VCF Automation 正常移除 — 輔助腳本

| 檔案 | 說明 |
|---|---|
| `asroot.py` | 在 SDDC Manager 上以 root 執行一條指令。`vcf` 不在 sudoers、`su` 又要 TTY，所以用 `pty.fork()` 開虛擬終端，看到 `assword` 才送密碼。用法：`ROOTPW='<root 密碼>' python3 asroot.py '<command>'` |
| `step3-delete-vsp-cluster.sh` | ③ `delete vsp-cluster` 的包裝（刪 VCFA services runtime，**必須 root**）。FQDN 是 m03 的範例，請改成你的 fleet / 管理 VSP。用法見檔頭。 |

## 執行前準備

- `cleanup_component.py` 是 **KB 441333** 的附件（Broadcom Confidential），**不放在這個 repo**，請自行從 KB 下載，放到 SDDC Manager 的 `/home/vcf/`。
- 三步的順序、參數與實測耗時見 [`deliverables/kb441333-vcfa-removal/`](../../deliverables/kb441333-vcfa-removal/)。

```bash
# ③ 以 vcf 帳號登入 SDDC Manager 後:
ROOTPW='<root 密碼>' python3 asroot.py 'LABPW="<VSP/vCenter 密碼>" bash /home/vcf/step3-delete-vsp-cluster.sh <vsp-cluster-id>'
```

## 重點

- VSP 的認證帳號是 `admin`（不是 `administrator@vsphere.local`，後者回 401）。
- ssh 進去跑 python 沒有 TTY 時輸出會緩衝，要加 `python3 -u` 才看得到進度。
