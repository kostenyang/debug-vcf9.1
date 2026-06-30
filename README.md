# debug-vcf9.1 — VCF 9.1 巢狀實驗室除錯手冊

> **這個 repo 是給「沒有 Claude 在旁邊時，你自己也能照著修」用的。**
> 每一篇都是實戰打通過的故障 → 根因 → 可直接複製貼上的指令。先看下面的「症狀路由表」找到對應篇章，再進去照做。

---

## 適用環境與 IP 慣例（很重要，先讀）

這些故障與指令來自 **rtolab 的巢狀 VCF 9.1（`vcf-m02`）**，所以範例 IP 多半是 rtolab 的：

- **rtolab**：管理網段 `192.168.114.x`、vMotion `192.168.115.x`、vSAN `192.168.116.x`、NSX TEP `192.168.117.x`；外層 vCenter `172.16.10.100`；DNS `192.168.114.200`；domain `rtolab.local`。
- **home lab**：是另一個環境，網段是 `10.0.0.x`（mgmt）/ `10.0.1.x`（nested）；外層 vCenter `10.0.0.101`；DNS `10.0.0.200`；domain `home.lab`。

> **除錯「手法」兩邊完全通用**，只是 IP / FQDN 不同。看到範例裡的 `192.168.114.x` 就換成你目標環境的對應位址。元件對照（vc / sddc / nsx / vsp / vcfa 各自 IP）查 lab-info：`topology/rtolab.md`、`topology/home-lab.md`。

預設密碼慣例：`VMware1!VMware1!`（外層 vCenter 不吃這組，要用真實帳密）。實際機密在各 lab repo 的 `inventory/secrets/lab.yaml`（sops+age 加密）。

---

## 🚦 症狀路由表 — 「我看到 X，該讀哪篇」

| 你看到的症狀 | 讀這篇 |
|---|---|
| **任何故障，不知從何下手** | [00-triage-and-access.md](00-triage-and-access.md) — 分診流程 + 怎麼登入每個元件 + 黃金守則 |
| clone 出的 nested ESXi 只有一台通、ARP 打架；憑證 CN 錯；`/system/uuid` 重複；OVF deploy 報 `does not support Intel VT-x` | [01-nested-esxi-and-clone.md](01-nested-esxi-and-clone.md) |
| nested host 突然 ping/SSH 不通（剛 deploy / 剛改 vmk0 MAC / 剛 vMotion 之後）；trunk 掉 ~75% 封包；vmk migrate to vDS 就失聯 | [02-network-l2-swsec.md](02-network-l2-swsec.md) |
| vSAN「每台 host `Member Count = 1`」、`No vSAN Master`、datastore inaccessible | [03-vsan.md](03-vsan.md) §A（unicast partition） |
| vCenter/SDDC 突然連不上、VM 自動關機+inaccessible、disk `In CMMDS: false` | [03-vsan.md](03-vsan.md) §B（CMMDS dropout） |
| bringup 卡 `Save VCF Management Components` / `FAILED_TO_SAVE_OR_UPDATE_VCF_MGMT_COMPONENTS` | [04-bringup-failures.md](04-bringup-failures.md) §fleetFqdn |
| bringup 卡 VSP bootstrap `StringIndexOutOfBoundsException` / `PUBLIC_VSP_CLUSTER_BOOTSTRAP_FAILED` | [04-bringup-failures.md](04-bringup-failures.md) §VSP bundle |
| bringup 一直 timeout、OVA import 被取消、`RequestCanceled` | [04-bringup-failures.md](04-bringup-failures.md) §timeout + [05](05-vsp-supervisor.md) §etcd |
| **VSP** Supervisor API（VIP `:6443`）不通、kube-vip/scheduler/controller-manager crashloop | [05-vsp-supervisor.md](05-vsp-supervisor.md) §leader-election |
| **VSP** bootstrap 卡住、supervisor 啟用報錯（dcli / wcp cache / 外部 VIP 不通 / CLS） | [05-vsp-supervisor.md](05-vsp-supervisor.md) §6–§7 |
| vCenter 服務一票 STOPPED、host reconnect 報 license 失敗、SPS 卡 START_PENDING | [05-vsp-supervisor.md](05-vsp-supervisor.md) §8（連鎖恢復鏈）|
| **VCFA** `.77`/`/provider/home` 不通、災後 appliance 救活 | [06-vcfa.md](06-vcfa.md) §1 |
| **VCFA** gateway 404/503、pod `FailedMount globalmount` / CrashLoop、region quota 失敗 | [06-vcfa.md](06-vcfa.md) §2–§3 |
| nested ESXi PSOD、外層 CPU 超賣、outer vSAN 撐爆、host `NotResponding` | [07-outer-resources.md](07-outer-resources.md) |
| 只想找指令 | [reference/commands.md](reference/commands.md) |

---

## 篇章總覽

0. [triage-and-access](00-triage-and-access.md) — 分診決策樹、各元件登入法、破壞性操作前的黃金守則
1. [nested-esxi-and-clone](01-nested-esxi-and-clone.md) — golden OVA clone 的 MAC/IP/cert/uuid/NestedHV/GuestOps 陷阱
2. [network-l2-swsec](02-network-l2-swsec.md) — 外層 dvSwitch swsec stale、vmk0 MAC 規則、network rollback、gateway
3. [vsan](03-vsan.md) — vSAN partition（unicast peer）與 CMMDS dropout（disk 沒收進 CMMDS）全鏈復原
4. [bringup-failures](04-bringup-failures.md) — fleetFqdn、VSP bundle、timeout tuning、lab-mode skip、retry/resume
5. [vsp-supervisor](05-vsp-supervisor.md) — VSP supervisor：兩種 supervisor 之分、動態找節點 IP、leader-election/etcd、bootstrap VM(CAPV)、supervisor 啟用雷、斷線連鎖恢復鏈
6. [vcfa](06-vcfa.md) — VCFA 應用層：appliance 本質與端點、災後救活、gateway 404/CSI/SPS、region quota 過載、provider 啟用
7. [outer-resources](07-outer-resources.md) — 外層 CPU 超賣、vSAN 容量、PSOD、DRS
- [reference/commands](reference/commands.md) — esxcli / PowerCLI / REST 速查

---

## 怎麼用這份手冊（沒有 Claude 時）

1. **先別動手**。讀 [00-triage-and-access.md](00-triage-and-access.md) 的分診流程，確認你在哪一層（外層實體？inner vCenter？vSAN？supervisor K8s？）。
2. **照症狀路由表**找到對應篇章。
3. **每篇都有「症狀 / 根因 / 修法 / 驗證」四段**，照順序做。指令可直接複製，記得把範例 IP 換成你的環境。
4. **破壞性操作（reboot host、detach disk、kill VM、改 spec、刪 pod）前**，先看 00 的黃金守則 —— 很多坑就是急著重啟/亂改造成的二次災難。

> 這份是「實戰筆記」不是官方文件。每篇結尾標了「來源/實證日期」。官方 workaround 來源大多是 William Lam 的 VCF 9.1 lab 部落格（連結在各篇）。
