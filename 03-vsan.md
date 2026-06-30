# 03 — vSAN 故障：Partition (unicast) 與 CMMDS Dropout

> 兩個**不同**的 vSAN 故障，症狀像但根因與修法完全不同：
> - **§A Partition**：每台 host `Member Count = 1`、`No vSAN Master`。control plane 互相看不到 → unicast peer list 沒推。
> - **§B CMMDS dropout**：cluster 成員齊全（Member Count=4）但某些 **disk「In CMMDS: false」**，FTT=0 下物件 inaccessible → VM 被迫關機。
>
> **先用這個分辨**：`esxcli vsan cluster get` 看 Member Count。=1 → §A；=4 但 vCenter/VM inaccessible → §B。

---

# §A — vSAN Partition（unicast peer list 空）

## 症狀
- 每台 host `Sub-Cluster Member Count = 1`、`Sub-Cluster Member UUIDs = 只有自己`
- vSphere UI：`No vSAN Master found in the cluster`、`vSAN datastore inaccessible`
- 4 台 cluster UUID 相同，但 partition 數 = 4

## 根因
ESXi 9.x 預設 **unicast CMMDS**（不再 multicast）。vCenter 在建 vSAN cluster 時要把 peer 清單推給每台 host；**bringup 中途被中斷**（例如 VCF Installer VM 被關機）→ 清單沒推完 → 互相看不到 → 各自一個 partition。

## 診斷
```bash
# 每台 host：
esxcli vsan cluster get                 # Unicast Mode Enabled: true、Member Count: 1
esxcli vsan cluster unicastagent list   # 空 = bingo（就是這個原因）
```
> 底層網路（trunk swsec / mac learning / dvfilter）是紅鯡魚，但要走過排除：確認 trunk PG `MacChanges/ForgedTransmits=True`、nested VM 有 `dvfilter-maclearn`、等 3 分鐘 partition 沒變 → 不是網路，回 unicast 路線。

## 修法：對每台 host 把「其他 3 台」加成 unicast peer

先蒐集每台的 Node UUID + vSAN VMK IP（**vSAN IP 是 vmk2，不是 mgmt IP**）：
```bash
esxcli vsan cluster get | grep 'Local Node UUID'
esxcli network ip interface ipv4 get -i vmk2
```

逐台加 peer（每台跑 3 次，加另外 3 台）：
```bash
esxcli vsan cluster unicastagent add -a <peer-vsan-ip> -u <peer-node-uuid> -t node -U true
```

| Flag | 意義 |
|---|---|
| `-a` | peer 的 **vSAN VMK IP（vmk2，不是 mgmt）** |
| `-u` | peer 的 Local Node UUID |
| `-t node` | type=node（**不是預設的 witness**） |
| `-U true` | supports-unicast=true |

> `-t node -U true` 不能省 —— 預設會加成 witness，互通不起來。

批次（plink 範例，先 `echo ok` 接受 fingerprint 再 add）見 [reference/commands.md](reference/commands.md)。

## 驗證
```bash
esxcli vsan cluster get
# 期望：Sub-Cluster Member Count: 4，UUIDs 列出 4 台
```
實測收斂約 **45 秒**。剩餘 RED（object health / config consistency / vCenter authoritative）是 bringup 沒完成造成的，不是 partition。

---

# §B — vSAN CMMDS Dropout（disk 沒收進 CMMDS → 物件 inaccessible）

> 這是 2026-06-18 的大事件：inner vSAN disk 短暫 L2 斷後被踢出 CMMDS，FTT=0 下凡 component 落該 disk 的物件全 inaccessible → vCenter/SDDC 掛。**端到端救回零資料遺失**。

## 症狀
- inner vCenter / SDDC ping+443 不通；NSX、DNS、4 台 nested host 都活。
- VM 在 vCenter 顯示 **poweredOff + inaccessible**（不是有人手動關 —— 物件 inaccessible 後 host 無法承載 VM）。
- 但 `esxcli vsan cluster get` **Member Count = 4**（成員齊全），vmkping vSAN 網段 0% loss（L2 已恢復）。

## 根因
某些 host 的 vSAN disk `Is Mounted: true` **但 `In CMMDS: false`**（disk 健康、checksum OK，只是沒被重新 publish 進 cluster directory）→ 該 disk 不貢獻儲存 → FTT=0 下單副本物件落在那 disk 上就 inaccessible。

觸發：一次短暫 L2 斷（外層 trunk swsec stale，篇章 02）把 disk 踢出 CMMDS；網路自行恢復了但 disk 沒自動 rejoin。

## 診斷
```bash
esxcli vsan storage list | grep -E "Is Mounted|In CMMDS|Is Capacity Tier"
# 找「Is Mounted: true 但 In CMMDS: false」的 disk
esxcli vsan debug object health summary get   # 看 inaccessible 物件數
```

## 修法（非破壞性，優先）：逐台 diskgroup unmount → mount

對 `In CMMDS: false` 的 disk，**逐台**強制重新加入 CMMDS：
```bash
# diskgroupUUID = 同組 cache disk 的 VSAN UUID（esxcli vsan storage list 看 capacity disk 的 "VSAN Disk Group UUID"）
esxcli vsan storage diskgroup unmount -u <diskgroupUUID>   # 會跑很久，SSH 可能 timeout 但操作會完成
esxcli vsan storage diskgroup mount   -u <diskgroupUUID>
esxcli vsan storage list | grep -E "Is Capacity Tier|In CMMDS"   # 驗證變 In CMMDS:true
```
- **SSH 關著的 host 走 host API（不必開 SSH）**：
  ```powershell
  Connect-VIServer <hostIP> -Credential <root>
  $esx = Get-EsxCli -V2
  $esx.vsan.storage.diskgroup.unmount.Invoke(@{uuid=$dg})
  $esx.vsan.storage.diskgroup.mount.Invoke(@{uuid=$dg})
  ```
  > ⚠️ 但 EsxCli-over-443 久跑操作會撞 **300s timeout**；mount 大碟可能要分鐘級，那種改走 SSH（無 300s 限制），背景 `nohup` + 輪詢。

## 修法（disk group 收編卡死時）：reboot host

`mount` 對某些狀態是 no-op（前景 120s 不返回、背景輪詢 InCMMDS 全程 0）。此時 **逐台 reboot**（資料碟健康，FTT=0 下逐台 reboot 風險可控，**不要兩台同時**）：
```sh
reboot -f   # 或從外層硬 reset
```
reboot 後 vSAN 通常重新初始化、收編 disk group → 物件 accessible。（.14 reboot 即收回。）

## 修法（reboot 卡在「activating: vsan」開機卡死）：detach-無碟開機-swsec-reattach

最棘手的狀況：host reboot 後 **vSAN 啟用在開機卡死**（console 卡「vsan loaded / activating: vsan」進度條滿、bootTime 不變 20+ 分，ping 通但 443/hostd 起不來）—— 它在收編那個 CMMDS-out 的 disk group 時 hang。成功路徑（救 .17 的關鍵手法）：

1. 外層 vCenter 把該 host 的兩顆 vSAN 磁碟（cache `_1.vmdk` + capacity `_2.vmdk`）**detach（保留檔）** → 開機（只剩開機碟，不卡）→ 進 DCUI。
2. **進 DCUI 卻 ping/443 不通 = 外層 trunk swsec stale**（reboot 後 vmk0 新 MAC）→ **toggle trunk PG Promiscuous True→False→True**（篇章 02）→ 立刻通。
3. 開 SSH → 用 API 把兩顆 vmdk **掛回 NVMe 控制器**（key 31000，unit 0/1，operation=add，無 fileOperation）→ `esxcli storage core adapter rescan --all` → cache 自動 `In CMMDS: true`。
4. `esxcli vsan storage diskgroup mount -u <dg>`（背景）→ 約 3.5 分 capacity 也 InCMMDS=true（**叢集穩定後 mount 就成功**，之前卡是因另一台同時 out + 在開機期）。
5. `esxcli vsan debug object health summary get` → 全 healthy / 0 inaccessible，資料零遺失。

## 收尾：開回 VM + 破孤兒 lock

物件 accessible 後依序 power on `sddc` → `vc`（再 vcfa-platform / ops / lic / vna）。

**vc 開不起來**（`.vmx was not found / Device or resource busy`）= **孤兒 exclusive lock**：持鎖 host reboot 後 MAC 變了，lock owner MAC 不屬任何現役 vmk0（heartbeat 已死）。**解法：unregister → 重新 register → power on**，孤兒鎖被破。

## 黃金守則（再強調）
- **vc inaccessible 時不要亂 reboot/reset**（會弄成 unregistered，更糟）；先查是不是 disk 沒收進 CMMDS。
- **不要為了保護 vc 而把它改 FTT=1** —— 2026-06-19 這麼做觸發第二次災難：鏡像 resync 撐爆已 94% 滿的外層 vSAN → nested host thin vmdk 卡 no-space 凍結。**永遠維持 FTT=0**。

---

## §C — Nested vSAN 必跑的 6 個 advanced settings（預防 / data path）

跟 partition / CMMDS 是**不同層次**的問題（那兩個是 control plane，這 6 個是 data path），但 lab 兩個都要做才完整。開機後馬上套（idempotent）：

```sh
esxcli system settings advanced set -o /LSOM/VSANDeviceMonitoring       -i 0   # nested vmdk IO pattern 異於真碟，開著會誤判壞碟
esxcli system settings advanced set -o /LSOM/lsomSlowDeviceUnmount      -i 0   # nested 天生慢，別自動踢碟
esxcli system settings advanced set -o /VSAN/SwapThickProvisionDisabled -i 1   # nested 沒空間 thick 預配 swap
esxcli system settings advanced set -o /VSAN/Vsan2ZdomCompZstd          -i 0   # 回退 LZ4，Zstd 太吃被擠壓的 CPU
esxcli system settings advanced set -o /VSAN/FakeSCSIReservations       -i 1   # 關鍵：nested 穿不透 SCSI reservation，不開拿不到 lock 起不來
esxcli system settings advanced set -o /VSAN/GuestUnmap                 -i 1   # TRIM/UNMAP 全程傳遞，省底層空間
```
驗證順序值：`0,0,1,0,1,1`。腳本：`layer1-nested/Prepare-NestedESXi.ps1`（`-DryRun` 只看不改）。

---

## 快速分辨表

| | §A Partition | §B CMMDS dropout |
|---|---|---|
| `vsan cluster get` Member Count | **1**（各自一群） | **4**（齊全） |
| `unicastagent list` | **空** | 有 |
| disk `In CMMDS` | — | **false** |
| 修法 | 補 unicast peer | diskgroup mount / reboot / detach-reattach |

---

來源：lab-info `runbooks/incident-2026-06-18-vsan-cmmds-dropout.md`、rtolab `docs/recovery-2026-06-vsan-cmmds-to-vks-rebuild.md`、`layer4-day2/Troubleshoot-VsanPartition.md`（2026-06-18 全鏈零資料遺失實證）。
