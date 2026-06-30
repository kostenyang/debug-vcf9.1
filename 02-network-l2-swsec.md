# 02 — 網路 / L2 / 外層 dvSwitch swsec stale

> nested ESXi「剛剛還好、突然不通」十之八九是這篇。外層 dvSwitch 的 port-level security (swsec) filter 卡舊，是 rtolab 反覆出現的老毛病。

---

## 1. 症狀：nested host 突然 ping/SSH 不通、trunk 掉 ~75% 封包

**什麼時候會發作**（這幾個事件都會產生新 vmk0 MAC / 新 port）：
- 全新 deploy（新 vmk0 MAC）
- 跑完 `Fix-CloneNetwork`（vmk0 重綁 = 新 MAC）
- vMotion 到另一台外層 host
- bringup 失敗重試多次後

> **判斷捷徑**：上述事件之一發生後，nested host ping/SSH 突然 timeout，但你確定 IP / 網路設定沒改 → **先 flush swsec，再除其他錯**。不要先去查 IP/DNS。

**根因**：外層 trunk PG 雖設了 Promiscuous/Forge/MacChange/MacLearning=True，但 ESXi 7.0.x 的 per-port runtime enforcement 不可靠（port accepted flags 缺 promisc bit，swsec filter drop 70–80% 封包）。新建 port 會帶 stale state。

---

## 2. 修法：toggle trunk PG Promiscuous 強制重推 policy

### 最快（rtolab 慣用繞法）
外層 vCenter → trunk portgroup → 安全策略 → **Promiscuous mode 設 Reject→Accept（False→True→False→True 都行）**，立刻重推 policy 到 port + reset swsec filter。
```powershell
$pg = Get-VDPortgroup -Name 'trunk'
Get-VDSecurityPolicy -VDPortgroup $pg | Set-VDSecurityPolicy -AllowPromiscuous $false
Get-VDSecurityPolicy -VDPortgroup $pg | Set-VDSecurityPolicy -AllowPromiscuous $true
```
然後從 nested ESXi vmk0 主動 `ping <gateway>` 幾次，逼外層 dvSwitch 學到新 MAC。用 `vmkping` 跨 VLAN 驗證恢復。

### 推薦的正規設定（ESXi 7/8 native）
trunk PG 設 **MAC Learning=True + ForgedTransmit=True**，Promiscuous 可不開（William Lam：native MAC Learning 取代 promisc）。

### 治本（我們外層 7.0.3 沒裝）
外層 host 裝 `dvfilter-maclearn` VIB + nested VM `.vmx` 加：
```
ethernetN.filter4.name=dvfilter-maclearn
ethernetN.filter4.onFailure=failOpen
```

---

## 3. vmk0 換 MAC 後上游 switch MAC table 卡舊 → 強制 GARP

換 vmk0 MAC 後，上游實體 switch 的 MAC table 可能還記著舊 MAC，部分 VM 突然 unreachable。force vmk0 down/up 觸發 gratuitous ARP：
```sh
esxcli network ip interface set --interface-name=vmk0 --enabled=false
sleep 3
esxcli network ip interface set --interface-name=vmk0 --enabled=true
```

**MAC churn 是正常現象**：多台 clone 在同一 trunk PG，MAC 數超過小型 switch per-port limit → LRU eviction → 第一次 ping 失敗、過 10–20 秒突然通。某台「一直」不通才用上面的 down/up cycle。

---

## 4. inner vCenter Network Rollback 必須關閉

**卡點**：vmk0 migrate 到 vDS 一動就 host 失聯 → 自動 rollback → 任務失敗。

**根因**：vSphere `config.vpxd.network.rollback=true`（預設）偵測到 host 短暫失聯（nested L2 收斂慢）5 秒內就 revert，nested 撐不過這個窗口。

**修法**：在 **inner vCenter** 設 `config.vpxd.network.rollback = false`。
```powershell
$si = Get-View ServiceInstance
$asMgr = Get-View $si.Content.Setting
$opt = New-Object VMware.Vim.OptionValue
$opt.Key = 'config.vpxd.network.rollback'; $opt.Value = 'false'
$asMgr.UpdateOptions(@($opt))
```
> ⚠️ 每次 vCSA 重新部署（wipe→bringup）都會重置回 true，要重設。

---

## 5. 把 4 台 nested ESXi 釘在同一台外層 host

某些外層 host 上 swsec stale 沒清過 → vmk migration / VSP 在那台 L2 不通。用 cluster DRS rule `MustRunOn` 把 4 台 nested 釘在已驗證 OK 的一台外層 host，避免 DRS 把它們散到沒 toggle 過 swsec 的 host。

> ⚠️ wipe 重建後 **DRS VM group 的成員會清空**（rule 和 host group 還在），要重新填回（見篇章 07 §DRS）。

---

## 6. 「DCUI 開到了卻 ping/443 不通」= swsec stale 經典案例

host reboot 後 vmk0 拿到新 MAC，但外層 trunk PG swsec 還卡舊 → DCUI 正常、外面連不到。**解法就是 §2 的 Promiscuous toggle**，秒通。（2026-06-18 CMMDS 事件救 .17 時就是這樣：detach disk → 無碟開機進 DCUI → ping 不通 → toggle trunk promisc True→False→True → 立刻通。）

---

來源：rtolab `layer2-bringup/nested-bringup-fixes.md`、`scripts/clone-troubleshooting.md`、lab-info `runbooks/golden-ova.md`、memory `project_outer_swsec_stale`。
