# 正常移除 VCF Automation 9.x（官方程序，KB 441333 `cleanup_component.py`）

- 實測 ①：2026-09-15，home.lab m02，VCF Automation 9.1.1（由 vRA 8.18.1 升級而來）→ 全部清乾淨
- 實測 ②：**2026-10-07，home.lab m03，全新 greenfield 部署的 VCF 9.1.1 含 VCFA → 三步全過、VM 實際刪除**。21 頁 docx 就在本資料夾([`KB441333-VCF-Automation-正常移除-StepByStep.docx`](KB441333-VCF-Automation-正常移除-StepByStep.docx));逐條指令輸出與截圖原檔在 private repo `vra-lifecycle`
- 腳本：`cleanup_component.py` 是 KB 441333 的附件（檔頭標示 Broadcom Confidential），**不收錄在這個 public repo**，請從 KB 441333 下載
- 相關：方案 B `vcf911-vcfa-fleet-record-manual-fix-optionB.md`（帳面假失敗時的另一條路，在 private repo `vra-lifecycle`）
- 輔助腳本（取 root、③ 包裝、卸載監看）：[`../../scripts/kb441333-vcfa-removal/`](../../scripts/kb441333-vcfa-removal/)

---

## 0. 先搞清楚 KB 441333 的兩句話

KB 標題是「Failed component cleanup」，裡面有一句常被誤讀：

> VCF Automation **Upgrade Failure** cleanup is not supported → 開 support case

這句講的是「升級**失敗**卡在半路」的殘局。**不是**說 VCFA 不能移除。
同一個 KB 附的 `cleanup_component.py` 就是移除 VCFA 元件的官方工具，對**已正常部署好**的 9.1.1 完全適用。

所以先判斷你的情況：

| 情況 | 走法 |
|---|---|
| VCFA 9.1.1 正常在跑，想整套拿掉 | **本文**（官方） |
| 升級任務 FAILED、fleet 帳面停 `8.0.0`、但底層其實已成功 | 先照方案 B(private repo `vra-lifecycle` 的 `vcf911-vcfa-fleet-record-manual-fix-optionB.md`)把帳面對齊成 9.1.1，再走本文（帳面是 `8.0.0` 時腳本只清帳面、不刪 VM，見 §4） |
| 升級真的失敗、底層也沒起來 | 官方 = support case；lab 可以硬走本文，但 `should_skip_infra_deletion` 會讓它只清帳面，VM 要自己刪 |

---

## 1. 它會做什麼（**三步**，順序不能反）

> 🔴 2026-10-07 更正：原本寫「兩步」。全新部署的 VCFA 會一起裝 **Migration service engine**
> （`list` 裡的 Type 叫 `VCD_MIGRATOR`），它和 VCFA 住在**同一個 VCFA runtime** 上，
> 必須在刪 runtime 之前單獨刪掉。m02 那次的 VCFA 是由 vRA 8 升級而來，沒有這個元件，所以只看到兩步。

| 步 | 命令 | 動作 | 動不動 VM | m03 實測耗時 |
|---|---|---|---|---|
| ① | `delete vsp-component -c <VCFA>` | Fleet → 管理 VSP（不在就 404 跳過）→ **VCFA runtime**（卸 `prelude` namespace 約 70 pod） | **不動** | 23m03s |
| ② | `delete vsp-component -c <VCD_MIGRATOR>` | 同上，卸 `vcd-migrator` pd + 2 pod | **不動** | 12m02s |
| ③ | `delete vsp-cluster -c <runtime>` | fleet 任務 → **關機並刪除 runtime VM** → 清 platform DB（`vsp_cluster`）。**必須 root** | **刪** | 3m10s |

① ② 都要同時給 `-vsrf <管理 VSP>` 與 `-varf <VCFA runtime>`（及各自的 `admin` 帳密）；③ 給 `-vu/-vp` vCenter。

🔴 **① 進行中跑 `list vsp-component` 會暫時看不到 `VCD_MIGRATOR`，但它沒有被刪** —— ② 仍在 Fleet 找到並刪除。
腳本**不檢查** runtime 上還有沒有元件就會刪 runtime，所以 ③ 之前務必再 `list` 一次，確認只剩管理 VSP 上的元件（Identity broker）。

實測 ③（m02）：fleet 刪除任務 61 秒 SUCCEEDED，runtime VM `vcf-m02-auto-platform-*` 關機並刪除，10.0.0.168 / .171 / .242 全部斷線。
實測 ③（m03）：fleet 60 秒 SUCCEEDED，vm-43 `vcf-m03-auto-platform-lmh4w` 關機並刪除，platform DB 只剩管理 VSP 那筆。
兩次 Identity broker（VIDB）都不受影響。DNS 記錄（auto-vip / auto-platform）**不會**被刪，要自己清。

---

## 2. 前置

```bash
# 腳本傳到 SDDC Manager（KB 說明要在 SDDC Manager 上跑）
pscp -pw '<vcf 密碼>' '<從 KB 441333 下載的 cleanup_component.py>' vcf@<sddc-manager>:/home/vcf/
```

### 🔑 VSP 的認證帳號是 `admin`，不是 `administrator@vsphere.local`

這是本文最重要的一行。用 `-vsru administrator@vsphere.local` 會得到：

```
HTTP 401 access_denied / invalid credentials
```

看起來像「腳本需要 VSP 認證但拿不到 → 死結」，其實只是帳號用錯。
可以先用 `POST https://<vsp-fqdn>/api/v1/identity/token` 驗：只有 `admin` 拿得到 token。

### 步驟 ② 要 root

SDDC Manager 上 `vcf` 不在 sudoers，`su` 又要 tty。用 python 的 pty 餵密碼：

```python
# asroot.py — 在 SDDC Manager 上以 root 跑一個命令
import os, pty, sys, select
cmd = sys.argv[1]
pid, fd = pty.fork()
if pid == 0:
    os.execvp('su', ['su', '-', 'root', '-c', cmd])
buf = b''
while True:
    r, _, _ = select.select([fd], [], [], 600)
    if not r: break
    try: data = os.read(fd, 4096)
    except OSError: break
    if not data: break
    buf += data
    if b'assword' in buf and b'\n' not in buf.split(b'assword')[-1]:
        os.write(fd, b'<root 密碼>\n'); buf = b''
    sys.stdout.write(data.decode(errors='replace')); sys.stdout.flush()
```

腳本自己會驗 `os.geteuid()==0` 和 `http://localhost/commonsvcs/about` 回 `name=COMMON_SERVICES`。

---

## 3. 執行

### 3.1 先 list（唯讀、安全）拿 id

```bash
python3 cleanup_component.py list vsp-component \
  -ff <fleet-fqdn> -vsrf <mgmt-vsp-fqdn> -vsru admin -vsrp '<vsp 密碼>'

python3 cleanup_component.py list vsp-cluster \
  -ff <fleet-fqdn> -vsrf <mgmt-vsp-fqdn> -vsru admin -vsrp '<vsp 密碼>'
```

記下 VCFA 的 component id 與 vsp-cluster 的 id。

### 3.2 ① 移除元件

```bash
python3 cleanup_component.py delete vsp-component -c <VCFA component id> \
  -ff <fleet-fqdn> \
  -vsrf <mgmt-vsp-fqdn>          -vsru admin -vsrp '<vsp 密碼>' \
  -varf <vcfa-runtime-fqdn>      -varu admin -varp '<vcfa 密碼>' \
  -fd
```

- `-varf` 是 VCFA 自己的 runtime FQDN（例：`vcf-m02-auto-platform.home.lab`），不是使用者存取的 FQDN
- `-fd` 跳過互動確認

### 3.3 ② 移除 runtime 叢集（root）

```bash
python3 cleanup_component.py delete vsp-cluster -c <vsp-cluster id> \
  -ff <fleet-fqdn> \
  -vsrf <mgmt-vsp-fqdn>          -vsru admin -vsrp '<vsp 密碼>' \
  -vu administrator@vsphere.local -vp '<vCenter 密碼>' \
  -fd
```

`-vu/-vp` 是 vCenter（刪 VM 用）。

---

## 4. 🔴 版本決定刪除範圍

腳本裡的 `should_skip_infra_deletion()`：**元件版本 < 9.1 就跳過** VSP / vCenter / SDDC 的實體刪除，只清 fleet 帳面。

所以：
- fleet 帳面停在匯入時的佔位版本 `8.0.0`（升級假失敗的典型狀態）→ 只清帳面，runtime VM 留著
- 帳面是真的 `9.1.1.x` → 連 VM 一起刪

要整套乾淨拿掉，帳面必須先是 9.1.1（方案 B 的 ②③④ 可以做到），或者事後自己刪 VM。

---

## 5. 驗證

| 位置 | 期望 |
|---|---|
| fleet `GET /v1/components` | 沒有 VCFA 那列（實測從 10 個元件剩 9 個） |
| sddc-lcm DB `component` 表 | 同步移除 |
| fleet DB `upgrade_plan_component` | 空 |
| 管理 VSP 叢集 `kubectl get comp -A` | 沒有 `vcfa` |
| vCenter | runtime VM 已刪 |
| VCFA 的 FQDN / VIP / runtime IP | 全部不通 |
| VIDB（identity broker） | 不受影響，其他元件登入正常 |

---

## 6. 移除後想再加回來 —— 先看 KB 441127

VCFA 元件移除後再 import，會因 infrastructure properties 為 NULL 而 **import 失敗**（KB 441127）。
如果目的是「拆掉重來」，要有心理準備：不是移除→再匯入就好，可能需要照 KB 處理或開 case。

---

## 7. 跟「方案 B」的關係

| | 本文（官方移除） | 方案 B（帳面補完，非官方） |
|---|---|---|
| 目的 | 把 VCFA **拿掉** | 把跑起來的 9.1.1 **留著**、只修 fleet 帳面 |
| 官方支援 | ✅ KB 441333 附件 | ❌ lab-only |
| 什麼時候用 | 不要這套 VCFA 了 | 升級其實成功、只是 fleet 記錯 |

當初以為「腳本要 VSP 認證拿不到 → 死結 → 只能手改 DB」，後來發現是帳號用錯；
所以方案 B 現在只剩「想保留 9.1.1 又要帳面對」這一種用途。
