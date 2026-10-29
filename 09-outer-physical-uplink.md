# 09 — 外層實體網路：交換器 / 上行故障（「nested 全部變慢」先查這層）

> 2026-10-28 home lab 實戰。表面症狀是「**VCF Automation 突然很慢**」，真正的根因在最底層：外層實體主機 `.95` 接的那台 **Cisco 2960S 交換器埠在壞**，整台主機的網路一直斷斷續續，連帶 `.95` 上所有 VM 和 nested VCF（m08）都掉包。
> 這篇的重點是**怎麼不被表面症狀帶著走**：先把「慢」切成段，再用「依實體 host 分組」的 ping 矩陣定位。
> 時間：`Z` = UTC，括號內為台北時間。腳本在 [scripts/outer-uplink-triage](scripts/outer-uplink-triage/)。

---

## 1. 症狀

- VCF Automation（`vcf-m08-auto.home.lab`）每個 API 要 **15–24 秒**（前一天同樣的 API 都在 1 秒內）：`/iaas/api/about` 6–21 秒、`/cloudapi/versions` 11–18 秒。
- `ping vcf-m08-auto` 掉 4/5、`ping vcf-m08-vc01` 也掉。
- 外層 `.95` CPU 83%；m08 內 CPU 最高的是 VCFA 節點（24 vCPU 約 24 GHz）→ **很容易誤判成「VCFA 吃 CPU / 剛改的設定在跑迴圈」**。

> ⚠️ **Photon OS（VSP / VCF Automation / Supervisor 節點）預設擋 ICMP**。ping VCFA 不通本來就不能當證據，要 ping **同一台實體 host 上的其他 VM**。

---

## 2. 分診：把「慢」切成段（10 分鐘內定位到實體層）

### 2.1 叢集內打 vs 叢集外打

在 VCFA 節點上（`ssh vmware-system-user@<runtime 節點 IP>`，`sudo` 後用 `/etc/kubernetes/admin.conf`）直接打後端 Service 和 ingress VIP：

```bash
K="kubectl --kubeconfig /etc/kubernetes/admin.conf --server https://<節點IP>:6443"
TM=$($K -n prelude get svc tenant-manager -o jsonpath='{.spec.clusterIP}')
curl -sk -o /dev/null -w "後端 tenant-manager %{http_code} %{time_total}s\n" https://$TM/cloudapi/versions
curl -sk -o /dev/null -w "ingress VIP        %{http_code} %{time_total}s\n" -H "Host: vcf-m08-auto.home.lab" https://<VIP>/cloudapi/versions
```

| 叢集內 | 叢集外 | 判讀 |
|---|---|---|
| **0.1 秒** | **15–24 秒** | VCFA 本身沒事 → 問題在 **client 到 VIP 這段網路**（本案） |
| 慢 | 慢 | VCFA 自己的問題 → 看 [06-vcfa.md](06-vcfa.md)、[05-vsp-supervisor.md](05-vsp-supervisor.md) |

順手確認 VCFA 沒有失控的 pod（本案全部 process 合計只有約 5 core / 24 vCPU，provisioning-service 不在前 18 名 → 剛改的自訂命名無關）：
```bash
$K top pods -A --sort-by=cpu | head -20
$K get pods -A | awk '$5+0>0'          # 有重啟的 pod
```

### 2.2 用 curl 把一次請求拆開看

```bash
curl -sk -o /dev/null -w "dns=%{time_namelookup} connect=%{time_connect} tls=%{time_appconnect} ttfb=%{time_starttransfer} total=%{time_total}\n" https://vcf-m08-auto.home.lab/api/versions
```
本案：`dns=0.01 connect=3.3–6.0 tls=9–18 ttfb=15–24`。
**DNS 快、但 TCP connect 3 秒 / 6 秒（Windows SYN 重傳間隔）、TLS 又加 6 秒** = 每個來回都在等重傳 = **掉包**，不是伺服器慢。

### 2.3 依「外層實體 host」分組的 ping 矩陣

```powershell
$env:VIPASS = '<外層 vCenter 密碼>'
./scripts/outer-uplink-triage/Test-HostPingMatrix.ps1 -VCenter 10.0.0.101 -Extra 10.0.1.141,10.0.1.144
```
本案結果（一眼就看出來）：

| 目標 | 掉包 |
|---|---|
| `.95` 主機自己的 vmk0（10.0.0.95） | **100%** |
| `.95` 上一般 VM（vcd-nfs01 / vcf9dltool / vcf-m08-inst01） | **90–100%** |
| `.95` 上的 m08 nested（esx01–03、vc01、sddcm01、nsx01a） | **95–100%** |
| `.97` / `.98` 主機與上面的 VM（outer vCenter、winjump01、depot、harbor01） | 0% |
| router 10.0.1.254 | 0% |

→ **共同點 = 實體主機 `.95`**。VCFA 只是剛好跑在它上面。

### 2.4 看那台 host 的上行

```powershell
./scripts/outer-uplink-triage/Get-HostUplinkHealth.ps1 -VCenter 10.0.0.101 -HostName 10.0.0.95 -Hours 24
```
本案看到的：
- 外層 vCenter 事件：`00:40Z`（08:40）起 **vmnic0 反覆 down/up**（「Lost network connectivity on DVPorts … Physical NIC vmnic0 is down」），`01:04Z` vmnic2 也 down → `Network uplink redundancy lost`，`02:09Z` vmnic0 再斷一次。
- 即時流量：vmnic0 **收 ≈ 10 KB/s、送 ≈ 18.7 MB/s** → 送得出去、幾乎收不到。
- 主機端計數器**全乾淨**（CRC 0 / drop 0 / errors 0、1000 全雙工）→ **主機端計數器乾淨 ≠ 網路沒問題**，問題可能在線材 / 交換器那一端。

### 2.5 vmkernel.log 實證（SSH 關著也拿得到）

ESXi 的 host client 可以直接下載 log：`https://<host>/host/vmkernel.log`（root 帳密，`curl -k -u root:<密碼> …`；另有 `vobd.log`、`shell.log`）。
```text
igbn_ServiceTimer: vmnic0: Rx hang detected: reset it
```
- `10-27 23:31:34Z`（10-28 07:31）起，**每 37.3–37.4 秒**驅動自己 reset 一次 vmnic0；每次 link 斷約 4 秒、netsched 佇列丟 500+ 封包；到 `02:03Z` 共約 **140 次**。前面還有約 4000 筆 `igbn_CheckRxHang false hang`（vmnic0 幾乎收不到東西）。
- 7 分鐘後（07:38）外層 vCenter 判 `.95` not responding。
- 同一時段 `.97` / `.98` **零**網卡事件。
- 37 秒循環的推測：reset → 交換器埠走 STP（非 portfast）重收斂約 30 秒不轉送 → 主機又收不到 → 再判 Rx hang（交換器端沒帳密，**未證實**）。

---

## 3. 根因

1. **Cisco 2960S（舊交換器）在壞**：`.95` vmnic0 所接的 Gi0/20 先出狀況（只有這一埠），交換器整台硬體在走下坡；使用者 13:45 重開 2960 後**整台開不起來**，三台實體 host 一起斷 → 確認 2960 壞了，改用 Dell N4032。
2. 網卡本身沒壞：改接 Dell 之後、主機重開之後，vmnic0 都是 **0 次 reset / 0 錯誤**。
3. **放大因素**：VDS7 的 MGMT（當時 `.95` vmk0 在這）與 VLAN3–9 portgroup 的 teaming **只有 active Uplink 1、沒有 standby**。vmnic0 一出事不會切到還活著的 vmnic1（Uplink 2）。若 Uplink 2 設成 standby，早上 `.95` 大概不會失聯。

---

## 4. 修法（實際做的順序）

### 4.1 換交換器、重新接線

舊 2960 → **Dell N4032**（10G，DNOS 6.5）：
- `.95` vmnic0/1（VDS7）→ Te1/0/13 / 14（1G trunk，native VLAN 1）；vmnic2（10G）→ Te1/0/4（access VLAN 1）
- `.97` VDS7 Uplink 1 改成 vmnic2（Te1/0/19，10G）；原本的 vmnic1 移出
- ⚠️ Dell 上的**埠描述是別的環境留下的舊標籤**，別信；以 FDB / CDP 實查為準。

### 4.2 `.95` 管理網路：vSwitch0 的上行是空的（第二個坑）

把 `.95` vmk0 搬到標準 vSwitch0 + vmnic2 後**還是不通**：
- 主機 console 上 `esxcli network ip neighbor list` 學得到 `.200` / `.97` / `.101`（**收得到**），但 ping `.200` 100% loss；
- Dell Te1/0/4 的 **In 計數凍結、Out 一直增加** → **主機那端沒送出去**；
- 換交換器、換線都一樣，使用者決定重開 `.95`；重開後還是不通。

最後 `esxcfg-vswitch -l` 才看到 **vSwitch0 的 Uplinks 是空的**（shell.log 證實當時只建了 vSwitch0、portgroup 和 vmk0，**沒有加上行**）。從 DCUI / ESXi Shell 補上：
```bash
esxcfg-vswitch -l                                                   # 看 Uplinks 欄
esxcli network vswitch standard uplink add -u vmnic2 -v vSwitch0
esxcli network vswitch standard policy failover set -v vSwitch0 -a vmnic2
esxcli network vswitch standard portgroup policy failover get -p "Management Network"   # portgroup 沒 override 成空的
vmkping -I vmk0 10.0.0.1
```
補完 Te1/0/4 立刻開始收包、學到 vmk0 的 MAC，ping 0 ms，外層 vCenter 重新 connected。

> 🔑 **判讀法**：交換器埠「In 凍結 + Out 在增」= 主機那端沒送 → **先查 vSwitch 上行 / failover order**，不是先懷疑線。

### 4.3 VDS7 MGMT portgroup 的 VLAN 2 → 0

Dell 上管理網段 10.0.0.0/23 是 **VLAN 1 untagged**；但 VDS7「MGMT」dvportgroup 設的是 VLAN 2 → 從 Dell trunk 出去會落到 Dell 的 VLAN 2（舊環境 192.168.2.0/24）孤島。`.95` 上接 MGMT 的 VM（vcd-nfs01 / vcf9dltool / esx911-demo / hpa-*）因此不通，**重開也不會好**。
修：MGMT dvportgroup VLAN 2 → **0**（三台都接 Dell，mgmt = untagged）。
> nested 部署別再設 `guestinfo.vlan=2`。

### 4.4 `.97` VDS outOfSync：`Failed to update port persistence location`

`.97` 換上行後推 VDS 失敗，`.97` 長期 outOfSync。原因是有些 port 的 persistence location 在**已經不存在的 vsanDatastore**（`vsan:52af9b09…`，07-10 被重格），`.97` 沒掛它 → hostd「Skip saving dvport … vsan:…/.dvsData」→ **整批 applyDVPort 一起失敗**（SSD 上 VM 的 port 也沒套用）。vpxa 重啟、單純 Rectify 都沒用。

**當下繞法**：`ReconfigureDVPort_Task` **只推開機中 VM 的 port** → `.97` 上 winjump01 / lichub01 / vrops / vcf9depot / sftp-server 全通（但 `.97` 仍顯示 outOfSync）。

**根治（10-29）**：把擋住的 port 一個一個清掉。`.97` 上共 3 個：
| port | portgroup | 是什麼 | 處理 |
|---|---|---|---|
| 1504 | MGMT（earlyBinding） | 死 template `Win2019-Tools` 的網卡（vmtx 在已不存在的 vsanDatastore） | 先把 vCenter 裡的設定匯出成 JSON，再 `UnregisterVM`（檔案早就不在，移除後無法再註冊 → 要先問擁有者） |
| 3880 | VLAN35-pf（ephemeral） | **幽靈 port**：connectee = vmVnic nic 4001，但那台 VM 已不存在 | Refresh → remove |
| 2098 | VLAN8-K8S（ephemeral） | 同上，另一個幽靈 port | Refresh → remove |

找幽靈 port：列出綁在該 host 的所有 port，挑「有 Connectee、但 ConnectedEntity 是 null 或查不到」的：
```powershell
$dvs = Get-View -ViewType VmwareDistributedVirtualSwitch -Filter @{Name='^VDS7$'}
$h   = Get-View -ViewType HostSystem -Filter @{Name='^10\.0\.0\.97$'}
$c = New-Object VMware.Vim.DistributedVirtualSwitchPortCriteria; $c.Host = @($h.MoRef)
$dvs.FetchDVPorts($c) | ? { $_.Connectee -and (-not $_.Connectee.ConnectedEntity -or -not (Get-View $_.Connectee.ConnectedEntity -EA 0)) } |
  % { '{0} pg={1} nic={2}' -f $_.Key, $_.PortgroupKey, $_.Connectee.NicKey }
```
清掉（直接 remove 會報 **`The resource '<port>' is in use.`**，要先 `RefreshDVPortState` 讓 vCenter 跟 host 對帳、清掉 connectee）：
```powershell
$dvs.RefreshDVPortState(@('2098'))                                   # 之後 Connectee 變 null
$s = New-Object VMware.Vim.DVPortConfigSpec; $s.Key = '2098'; $s.Operation = 'remove'
$dvs.ReconfigureDVPort_Task(@($s))
$mgr = Get-View $global:DefaultVIServer.ExtensionData.Content.DvSwitchManager
$mgr.RectifyDvsOnHost_Task(@($h.MoRef))                              # Rectify 在 DistributedVirtualSwitchManager 上，不在 VDS 物件上
```
三個都清掉後 Rectify → `.97` **up**（`.95` / `.98` / `.97` 三台都 up），`.97` 上 VM 全通。
> ⚠️ 只要清單裡還有一個壞 port，`RefreshDVPortState` 一次刷多個也會報 `Cannot complete a vSphere Distributed Switch operation for one or more host members`，但通常還是會把能清的清掉；**一次處理一個 port** 比較好判讀。

**同一招第二次（10-29，`.98`）**：刪掉 6 個沒用的 portgroup（VLAN31–36-pf）觸發 vCenter 重推，`.98` 變 outOfSync。
- `vpxa.log` 的 `DvsApplyOperationFault` 列了 **13 個 port**（連開機中的 router VM 都在裡面）——那是**整批連坐**，不是 13 個都壞。
- 真正的元兇看 `hostd.log`：`Skip saving dvport VDS7-1508 to /vmfs/volumes/vsan:52af…` → 只有 port 1508（死 template `VM-016`）。
  ```bash
  curl -sk -u root:<host 密碼> https://<host>/host/hostd.log | grep -E "Skip saving +dvport|port persistence location" | tail
  ```
- 匯出設定 → `UnregisterVM` → Rectify：主機端 21:21 套用成功，但 **vCenter 的 host member 狀態到 21:27 才翻 up（約 6 分鐘）**——Rectify 回 success 而狀態沒變時，先等幾分鐘再判斷，別急著做下一步。
- 刪 portgroup 前先查「沒有 VM / template / vmk 指到它」並 `Export-VDPortGroup` 備份（還原：`New-VDPortgroup -VDSwitch <vds> -BackupPath <zip>`）。

### 4.5 驗證

- VDS VLAN / MTU health check（實跑後已關回）：`.95` vmnic0/1、`.98` vmnic0 → Dell trunk 通 untagged + VLAN 2–200，MTU 9000 OK。
- m08 三台 nested `vmkping` 管理 / vMotion / vSAN / TEP（TEP 用 `-d -s 1672`）全 3/3。
- `Test-HostPingMatrix.ps1`：三台實體 host 與上面的 VM 全部 0% 掉包。

---

## 5. 復原：重開後只開回「出事前在跑的」

外層 host 重開後 **VM 不會自己開**（沒設 autostart）。**不要盲開全部**：本案 `.95` 上原本就關著的有 `route-bak`（備援 router）、`rhel-depot` + `rhel-depot-old`（同一台 depot 的新舊版）、pve01–03 等，硬開會撞 IP / 路由。

順序：
1. **NFS server VM 先開**（`vcd-nfs01`，nested 的 NFS datastore 在它上面）
2. nested ESXi（m08 三台）
3. nested 管理元件，照依賴順序：vCenter → SDDC Manager / NSX → License → VCF Operations → collector → VSP control plane → VSP worker（home lab m08 = `Resize-M08.ps1 -Step Start`；vCenter 可能被 DRS 搬過，要三台都找）
4. **VCF Automation runtime 節點**（不在 VSP 管理叢集的開機清單裡，要另外開）
5. 工作負載 VM（放 NFS 的要等 datastore 掛回來才開得起來）

工具：平時就存一份開機清單，出事時照清單開：
```powershell
./scripts/outer-uplink-triage/Save-Restore-PoweredOnBaseline.ps1 -VCenter 10.0.0.101 -Save -Path .\poweredon-baseline.json
# 重開後（預設 DryRun）
./scripts/outer-uplink-triage/Save-Restore-PoweredOnBaseline.ps1 -VCenter 10.0.0.101 -Restore -Path .\poweredon-baseline.json -HostName 10.0.0.95 -First vcd-nfs01
# 確認無誤再加 -Execute
```
本案沒有現成清單，是用當天早上（03:25Z）診斷時查到的開機中清單當依據。

**VCF Automation 恢復時間**（runtime 節點 `14:31Z` 開機後，每分鐘打一次）：

| 時間 | 恢復的 API |
|---|---|
| +17 分（14:48Z） | tenant 登入（`/cloudapi/1.0.0/sessions`）、`/iaas/api/*` |
| +20 分（14:51Z） | `/catalog/api/items`、`/deployment/api/deployments`（5 個部署都在） |
| +24 分（14:55Z） | `/blueprint/api/blueprints` |
| **+27 分（14:57Z）** | `/vco/api`（embedded orchestrator，vCenter plugin 登記還在）→ 全部恢復 |

中間的 `503 upstream connect error or disconnect/reset before headers` 是服務還在起，**等就好，不要重啟 pod**。

---

## 6. 這次學到的（檢查清單）

1. **「nested 全部變慢 / ping 掉」先看外層實體 host 的上行事件**，別先懷疑上層元件。
2. 慢的時候先**切段**：叢集內 vs 叢集外、curl 的 dns / connect / tls 各花多少。
3. ping 一定要**依實體 host 分組**比對；Photon 節點擋 ICMP，要 ping 同 host 的其他 VM。
4. 主機端網卡計數器乾淨 ≠ 沒事；`vmkernel.log` 的 `Rx hang detected: reset it` 間隔很規律就是驅動在自救。
5. 交換器埠 **In 凍結 + Out 在增** = 主機沒送 → 查 vSwitch 上行 / failover，不是線。
6. **VDS teaming 要有 standby 上行**（尤其 MGMT），單上行一出事整台失聯。
7. 平時存**開機清單**；重開後照清單開，不盲開。考慮對 NFS server VM、nested ESXi 設 autostart。
8. 告警別手動清掉就算了（本案 09:07 有人手動清了 `Network uplink redundancy lost`，等於把最早的線索消掉）。

---

## 7. 換交換器後的連帶問題：DC 第二張網卡撞 IP（已修）

**症狀**：`.200`（home.lab 的 AD DC / 跳板機 `KADDNS`）的 Ethernet1 掛在 trunk portgroup `DPG-802.1Q` 上。換交換器前它一直是 169.254 的 APIPA（等於沒在用）；換到 Dell 後 trunk 的 native VLAN 1 通了，Ethernet1 就從家用路由器 `10.0.0.1` 的 DHCP 拿到 **10.0.0.18 = sftp-server 的固定 IP**。副作用比撞 IP 更大：
- DC 把 10.0.0.18 **註冊進 AD DNS**：`home.lab`（@）、`DomainDnsZones`、`ForestDnsZones`、`kaddns`、`_msdcs` 的 `gc` 都多一筆 → 查網域名稱時有一半機率被導到 sftp-server。
- Ethernet1 的 DHCP 預設路由 metric 比較小 → DC 連外的流量全走 Ethernet1、來源是 10.0.0.18。

**查法**：
```powershell
ipconfig /all                                                   # 看哪張卡 DHCP Enabled、DHCP Server、Lease
Get-NetRoute -DestinationPrefix 0.0.0.0/0 | ft InterfaceAlias,NextHop,RouteMetric,InterfaceMetric
Get-DnsServerResourceRecord -ZoneName home.lab -RRType A | ? { $_.RecordData.IPv4Address.IPAddressToString -eq '10.0.0.18' }
Get-DnsServerResourceRecord -ZoneName _msdcs.home.lab -RRType A | ? { $_.RecordData.IPv4Address.IPAddressToString -eq '10.0.0.18' }
```

**修法（可逆）**：先備份 ipconfig / 路由 / 相關 DNS 紀錄，再處理 Ethernet1：
```powershell
Set-DnsClient -InterfaceAlias Ethernet1 -RegisterThisConnectionsAddress $false
ipconfig /release Ethernet1
Disable-NetAdapter -Name Ethernet1 -Confirm:$false
nltest /dsregdns; Clear-DnsServerCache -Force; Clear-DnsClientCache
```
- 這樣做之後，那 5 筆 10.0.0.18 的 A 紀錄被 Windows **自動反註冊**；若還在，再用 `Remove-DnsServerResourceRecord` 逐筆刪。
- ⚠️ `Get-DnsServerResourceRecord -Name '@'` 會把整個 zone 的 A 都撈回來，要再用 `HostName -eq '@'` 精確比對，不然會刪錯。
- 不綁網卡的 persistent route（例 `172.16.10.0/24 → 10.0.1.254`，ifIndex 0）會自動改走 Ethernet0。
- 驗證：`home.lab` / `kaddns` / `gc._msdcs` 只解析到 10.0.0.200；預設路由走 Ethernet0；10.0.0.18 的 ARP 對到 sftp-server 自己的 MAC、SSH 通；連外來源 10.0.0.200。
- 還原：`Enable-NetAdapter Ethernet1`。
- ⚠️ 根因還在：家用路由器的 DHCP pool 包含 .18，sftp-server 離線時這個位址可能再被發出去 → 要在路由器做保留或排除，或把 sftp-server 改到 pool 外。另外，DC 不要讓第二張網卡停在同一個網段上跑 DHCP。

---

## 8. 仍待處理（截至 2026-10-29 09:20）

- 家用路由器 DHCP pool 對 10.0.0.18 的保留 / 排除（見 §7）。
- 2960 的 37 秒循環原因（STP 非 portfast 的推測）沒驗證：交換器已壞、也沒帳密。

---

來源 / 實證：2026-10-28 home lab（外層 `.95` / `.97` / `.98`，nested m08 VCF 9.1.1 + VCF Automation 9.1.1）。診斷、vmkernel.log 對時、換交換器與 vSwitch0 修復由三個平行 session 與使用者共同完成，本篇彙整。
