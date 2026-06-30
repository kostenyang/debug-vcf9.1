# 00 — 分診 (Triage) + 登入各元件 + 黃金守則

> 任何故障先看這篇。目標：**先搞清楚壞在哪一層、怎麼進去查，再動手**。VCF 是疊起來的（外層實體 → nested ESXi → inner vCenter → vSAN → supervisor K8s → VCFA app），症狀常常出現在上層、根因在下層。

---

## 1. 分診決策樹（由上層症狀往下追根因）

```
vCenter / SDDC / VCFA 連不上 或 bringup 卡住
│
├─ 先確認「網路 vs 服務 vs 儲存」
│
├─ A. nested host ping 不通？
│     └─ 剛 deploy / 改 vmk0 MAC / vMotion 之後 → 外層 swsec stale → 篇章 02
│     └─ host 443 通但 22 不通 → SSH 服務閒置自停（正常），用 PowerCLI 443 或重開 TSM-SSH
│
├─ B. nested host 都活，但 inner vCenter / SDDC 443 不通？
│     └─ 查 inner vSAN object：disk「In CMMDS: false」→ 物件 inaccessible → VM 被迫關機 → 篇章 03 §B
│     └─ vSAN「每台 Member Count=1」→ unicast peer list 空 → 篇章 03 §A
│
├─ C. vCenter API 起來但一票服務 STOPPED、host reconnect / wcp / license 卡？
│     └─ service-control --start --all → 篇章 05 §8（連鎖恢復鏈）
│
├─ D. VSP supervisor K8s API（VIP :6443）不通？
│     └─ kube-vip/scheduler/controller-manager crashloop → etcd fsync 太慢 → 篇章 05 §3 leader-election
│     └─ bootstrap 卡 / supervisor 啟用報錯（dcli / wcp cache / 外部 VIP / CLS）→ 篇章 05 §6–§7
│
├─ E. VCFA gateway 404/503、pod CrashLoop / FailedMount、region quota 失敗？
│     └─ 先量 K8s node `uptime` load → ≫24 = 底層 overload，別硬戳 pod → 篇章 07 + 06
│     └─ FailedMount globalmount input/output error → CSI 死掛載 → 篇章 06 §2b
│     └─ .77 / provider 不通 → appliance NIC 斷線救活 → 篇章 06 §1
│
└─ F. bringup 任務失敗（不是卡住）？
      └─ 看失敗的 task 名稱 → 篇章 04 對症（fleetFqdn / VSP bundle / timeout）
```

**通則：症狀在 K8s/應用層，根因九成在儲存或 CPU（篇章 07）。** 先量底層健康度再修上層。

---

## 2. 怎麼登入每個元件（access techniques）

各元件登入限制不同，這是實際打通的方法。密碼用 `<pw>` 代表，預設 `VMware1!VMware1!`。

### nested ESXi host
- `root` / lab 預設密碼。**SSH 預設關**（閒置會自動停），443 一直可用。
- 開 SSH：PowerCLI 直連 host → `Start-VMHostService TSM-SSH`（或從 inner vCenter）。
- **不開 SSH 也能跑 esxcli**：PowerCLI `Get-EsxCli -V2`（走 443）—— 但**久跑操作會撞 300s HttpClient timeout**（例如 diskgroup mount），那種要走 SSH。
- 從 Windows 用 plink/Posh-SSH 進去（範例見 [reference/commands.md](reference/commands.md)）。

### VCF Installer / SDDC Manager appliance
- `root` **不可**直接 SSH；`vcf` 帳號可 SSH，但 `sudo` 只允許 `/opt/vmware/sddc-support/sos`。
- `su -` 需要 controlling terminal，非互動 SSH 會報 `su: must be run from a terminal`。
- **解法**：`vcf` 登入後用 `script` 建 pseudo-tty 跑 `su - root`，延遲餵 root 密碼：
  ```bash
  (sleep 2; echo '<root-pw>') | script -qec "su - root -c '<command>'" /dev/null
  ```

### inner vCenter (VCSA)
- appliancesh 不能直接跑 bash、會吃掉引號/pipe。**解法**：`shell chsh -s /bin/bash root` 換預設 shell；回復 `chsh -s /bin/appliancesh root`。
- VCSA **內建 pyVmomi**（含 PBM storage policy 模組）：`PYTHONPATH=/usr/lib/vmware/site-packages python3 ...`
- 服務管理：`service-control --status` / `--start --all` / `--stop --all`。

### VSP Supervisor / VCFA 控制平面節點（K8s）
- SSH 帳號**只有** `vmware-system-user` / lab 預設密碼；`root`/`admin` 的 SSH 被拒。登入後 `sudo` 拿 root。
- `sudo` 非互動無 tty，要用 `echo '<pw>' | sudo -S ...`。
- kubectl 在 `/usr/local/bin/kubectl`，**必須明確指定 kubeconfig**：
  ```bash
  echo '<pw>' | sudo -S kubectl --kubeconfig=/etc/kubernetes/admin.conf get pods -A
  ```
- **只有控制平面節點**的 `/etc/kubernetes/admin.conf` 有效，worker 上是空的。先從 inner vCenter VM 清單找出哪台是 control-plane（持 VIP 的那台）。
- ⚠️ 控制節點 SSH/root 密碼**會定期輪替**（vSphere with Tanzu 行為）；失效時從 vCenter 重新取得：`/usr/lib/vmware/wcp/decryptK8Pwd.py`（**僅限 WCP supervisor**；VCFA 內嵌 VSP 沒有這支）。
- VCFA app 跑在 `prelude` namespace；平台層在 `vmsp-platform` / `vmsp-platform`。

### 外層 vCenter（實體）
- rtolab：`172.16.10.100`，SSO domain **不是** vsphere.local → `administrator@vmwaresso.taiwan` / 真實密碼（不是 lab 預設）。
- home lab：`10.0.0.101`（labvc.lab.com），SSO 同樣**不是** vsphere.local / 預設密碼（會回 401）→ 用真實 lab 帳密。

### 實體 ESXi（若 lab 有）
- 常只接受 `publickey` / `keyboard-interactive`，**密碼登入會失敗**。要查底層改從可密碼登入的那台跑 esxcli。

---

## 3. 黃金守則（破壞性操作前必讀 —— 二次災難都來自違反這些）

1. **vCenter/SDDC VM `inaccessible` 時，不要亂 reboot / reset / power-cycle。**
   會把它弄成 unregistered、或留下孤兒 lock，更難救。**先查 inner vSAN object / CMMDS 是不是 disk 沒收齊**（篇章 03 §B）。

2. **lab 一律 FTT=0，不要「修」回 FTT=1。**
   nested + 外層消費級 SSD，容量/IO 比冗餘重要。FTT=1 會讓每筆寫入翻倍、撐爆外層 vSAN → nested host 卡 no-space 凍結（2026-06-19 就是這樣引爆二次災難）。FTT=0 也順帶緩解 supervisor etcd fsync 延遲。spec 已內建 FTT=0，post-bringup 什麼都不用做。

3. **inner cluster 的 vSphere HA Admission Control 一律 Disabled。**
   FTT=0 容量吃緊，admission control 會擋住 VM/pod 開機 → conductor 任務孤兒化。

4. **不要在外層 vSAN 快滿時做「加空間」動作**（FTT 調高、resync、consolidate running VM）。先騰空間再說。

5. **慢速 lab 一定先調 domainmanager timeout 再送 bringup**（篇章 04），不是等 timeout 了才補。

6. **卡關優先用 installer 原生 retry/resume**，少手動刪 VM / 改 spec / 重啟服務。破壞性操作前先確認。

7. **GuestOps（VMware Tools StartProgramInGuest）是 sandbox，不是 full root。**
   `esxcli` 可以，但 `touch /etc/*`、`auto-backup.sh`、`/etc/init.d/SSH`、raw socket（ping/nc）會被 vmkernel 擋（`Operation not permitted`）。需要持久化的步驟一律走真 SSH（篇章 01）。

8. **nested ESXi PSOD / guest halt 後，graceful 重啟無效**，要外層 `Restart-VM`（硬 reset）。但**別對跑 k8s 的 nested host 做 live vMotion**（churn 會再 PSOD）。

9. **看到 `RequestCanceled` 不要去查「誰按了取消」** —— 那是 Fleet LCM 服務自己 timeout 放棄，根因在 supervisor etcd / 儲存（篇章 04/05）。

10. **load ≫ 24 / etcd fsync ≫ 100ms 時，別硬戳 pod。** `CreateContainerConfigError`/`ImagePullBackOff`/CrashLoop 多半是 overload 下游症狀，修完底層 load 降下來會自癒。

---

來源：rtolab vcf-m02 實戰（2026-05 ~ 06）；彙整自 lab-info runbooks、rtolab docs、各 layer troubleshooting。
