# 01 — Nested ESXi / Golden OVA Clone 陷阱

> VCF 9.1 的 nested ESXi golden OVA **還沒完全 bake**，每次 clone 出來都要修才能用。這篇是「clone 完到能跑 bringup」之間所有會卡的硬傷，依處理順序排列。

---

## 0. 標準修復序列（從乾淨 OVA deploy 後一定要跑）

```powershell
# 0. Deploy（一定要帶 -NestedHV，且記得包含 esx01）
pwsh scripts/Deploy-FromGoldenOva.ps1 -Versions 9.1 -Hosts esx01,esx02,esx03,esx04 -NestedHV

# 1. 修 vmk0 MAC（透過 Guest Ops，不需網路）
pwsh -Command "& 'scripts/Fix-CloneNetwork.ps1' -Versions 9.1 -Hosts esx01,esx02,esx03,esx04"

# 2. 套 IP / gateway / hostname / DNS
pwsh -Command "& 'scripts/Apply-CloneIp.ps1' -Versions 9.1 -Hosts esx01,esx02,esx03,esx04"

# 3. Regen SSL cert（CN 改成正確 FQDN）
pwsh -Command "& 'scripts/Regen-EsxiCert.ps1' -EsxiHosts 192.168.114.14,192.168.114.15,192.168.114.16,192.168.114.17"

# 4. 持久化（auto-backup.sh 從 GuestOps 跑會失敗，要走 SSH）
for ip in .14 .15 .16 .17; do
  ssh root@192.168.114$ip 'touch /etc/rtolab-configured; /sbin/auto-backup.sh'
done
```

> ⚠️ **用 `pwsh -Command "& '...' -Hosts a,b,c,d"`，不要 `pwsh -File`** —— `-File` 會把 array 參數弄壞。

---

## 1. clone 的三個共用問題（為什麼非修不可）

OVA 是在 master 沒 `Bake-MasterFinalize`（沒設 `/Net/FollowHardwareMac=1`）就 export 的，所以每台 clone 共用：

| 共用的東西 | 後果 |
|---|---|
| **vmk0 MAC**（master 的，不是各自 vNIC HW MAC） | ARP 戰爭，4 台只有 1 台通網 |
| **SSL cert**（CN=localhost.localdomain） | VCF 驗證 `ESXI_HOST_CERTIFICATE_CN_NOT_VALID` |
| **IP / hostname**（master 的） | 4 台同 IP |
| **`/system/uuid`**（尾碼 `005056a58fa9`） | vSAN 拒絕成形 / partition（節點 UUID 重複） |

> `local.sh` first-boot 機制理論上會修，但 ESXi 9.1 拿掉了 `/usr/bin/vmware-rpctool`，`local.sh` 讀不到 guestinfo 就 `exit 0` 什麼都沒做 → 一定要手動修。

---

## 2. vmk0 MAC 規則（最容易害 bringup 失敗的雷）

**卡點**：bringup 卡在 `Migrate ESX Host Management vmknic to vSphere Distributed Switch` → `VSPHERE_CONFIGURE_HOST_DVS_FAILED` / `HostCommunication` / host NotResponding。

**vmk0 MAC 必須「每台唯一」且「≠ 該台 vmnic0 HW MAC」**，三種狀態都會壞：

| vmk0 MAC 狀態 | 結果 |
|---|---|
| 4 台共用 OVA baked MAC `…8f:a9` | MAC 衝突，只 1 台可達 ❌ |
| 綁成各自 vmnic0 HW MAC（`a5:xx`） | vmk0 migrate 到 inner vDS 後，teaming 走 vmnic1 出去時 source MAC = vmnic0 → 外層 dvSwitch 在 uplink port 和 vmk port 看到同一個 MAC → MAC learning 崩 → host 失聯 → rollback ❌ |
| **ESXi 自動產生**（`00:50:56:6x:xx:xx`，≠ `a5:xx`） | ✅ 正解 |

**正解**：移除 `--mac-address` 與 `/Net/FollowHardwareMac`，讓 ESXi 自動配：
```sh
esxcli network ip interface remove --interface-name=vmk0
esxcli network ip interface add  --interface-name=vmk0 --portgroup-name='Management Network'
#   ↑ 不帶 --mac-address，自動產生唯一 MAC
```
（已修進 `Fix-CloneNetwork.ps1` commit d843bbb；William Lam 的 nested 腳本也是 auto-gen MAC。）

---

## 3. `/system/uuid` 重複 → vSAN 不成形

每台 9.1 clone 開機都帶相同 uuid 尾碼。**bringup 前**逐台改（走 SSH）：
```sh
# esx0N → 尾碼 f0N（f01..f04）
sed -i 's|005056a58fa9|005056a58f0N|' /etc/vmware/esx.conf
/sbin/generate-certificates     # 要在 hostname 正確「之後」（cert CN 用 hostname）
/sbin/auto-backup.sh            # reboot 前持久化
reboot
```
驗證：reboot 後 `esxcli system uuid get` 結尾是 `f01..f04`。

> **不要**用 `echo $b64 | base64 -d` 上傳打包腳本（曾產生 0-byte 檔），**不要**在腳本中段塞 `hostd restart`（會斷 SSH）。逐條指令跑。
>
> **迷思破除**：4 台共用 OSDATA volume UUID（`OSDATA-…-005056a58fa9`）**不是** blocker。只要 `/system/uuid`（f01–f04）唯一，多節點 nested vSAN ESA 就能成形；OSDATA 是 VMFS-L 系統分割，只是裝飾性。「OSDATA 死結 → 必須用 kickstart ISO」的舊說法是錯的，不要因此放棄 OVA-clone 路線。（2026-06-17 實證 312/312 成功。）

---

## 4. NestedHV / vhv.enable 沒設 → vCenter OVF deploy 撞「does not support Intel VT-x」

**症狀**：bringup 卡 `Deploy vCenter Appliance`，retry 3+ 次，log：`OVF Tool: Error: This host does not support Intel VT-x.`

**根因**：OVA 沒記 `vhv.enable=TRUE` + `NestedHVEnabled=true`，clone 出的 nested ESXi 沒對 inside guest expose VT-x → inner vCenter VM 開不了機。

**修法**：deploy 時帶 `-NestedHV`（已 commit 進 `Deploy-FromGoldenOva.ps1`）。若已 deploy 忘了設，事後補：
power off VM → ReconfigVM `NestedHVEnabled=true` + extraConfig `vhv.enable=TRUE` → power on → 重跑 Fix-CloneNetwork + Apply-CloneIp + Regen-EsxiCert（reboot 會清掉 runtime）。

---

## 5. GuestOps vs SSH：哪些操作只能走 SSH

VMware Tools `StartProgramInGuest` 是 sandbox，很多 syscall 被擋：

| 操作 | GuestOps | SSH |
|---|---|---|
| `esxcli`（設 IP / 網路 / settings） | ✅ | ✅ |
| `ping` / `nc` / raw socket | ❌ `socket() Operation not permitted` | ✅ |
| `touch /etc/<任何檔>` | ❌ `Operation not permitted` | ✅ |
| `/sbin/auto-backup.sh`（持久化） | ❌ `Access denied by vmkernel access control policy` | ✅ |
| `/etc/init.d/SSH` restart | ❌ | ✅ |

**所以正確流程**：
1. clone 剛部好不通 → 只能 GuestOps 跑 `esxcli` 設一個暫時 IP，讓你能 SSH 進去。
2. IP 通了 → 改 SSH 做持久化（`auto-backup.sh`）與其他 privileged ops。

> ⚠️ 若沒走 SSH 持久化，硬 power-cycle 後 host 會 revert：IP→baked `.14`、`/system/uuid`→共用 `…8f:a9`。

---

## 6. esxcli vmk0 IP set 兩步驟（chicken-and-egg）

vmk0 剛 `add` 完、netstack 沒 default route 時，直接 `ipv4 set -g <gw>` 會炸：
`Cannot set an interface gateway when the default gateway for the netstack ... is not configured.`

兩階段：
```sh
esxcli network ip interface ipv4 set -i vmk0 -t static -I $IP -N $MASK        # 先設 IP/mask，不帶 -g
esxcli network ip route ipv4 add  --gateway $GW --network default             # vmk 有 IP 了才能加 route
esxcli network ip interface ipv4 set -i vmk0 -t static -I $IP -N $MASK -g $GW # 回頭寫 interface gateway 欄位
```

---

## 7. gateway 是 `.254` 不是 `.1`

rtolab SELAB underlay 的 gateway 是 **`.254`**（跟 `172.16.10.254` 同慣例），`.1` 根本不存在。早期 cheat sheet / inventory 寫 `.1` 是錯的。

判斷：clone 內部 `ping .200`（同 VLAN，不用 gateway）通、`ping .1` ARP incomplete、`ping .254` 通 → gateway 是 `.254`。改 `inventory/lab.yaml` 的 gateway 後要重跑 `Apply-CloneIp.ps1`（已存在的 host 不會自動套）。

---

## 8. hostname 被 reset 回 localhost

`/etc/init.d/hostd restart` 後若 hostname 沒透過 `auto-backup.sh` persist，會回 OVA 預設 `localhost`。**cert regen 用 hostname 當 CN，所以先確認 hostname 對才 regen**：
```sh
esxcli system hostname set --fqdn=kosten-vcf91-esx0N.rtolab.local
/sbin/generate-certificates
/etc/init.d/hostd restart
/etc/init.d/rhttpproxy restart
/sbin/auto-backup.sh
```
> `Fix-CloneNetwork.ps1` 會跳過 esx01（保留 baked .14），所以 esx01 的 hostname/cert CN 會留 `localhost`，要手動修。

---

## 9. SSH host keys 共用（warning，非阻斷）

4 台 SSH fingerprint 相同（從 OVA 來）。validator 不會 fail（thumbprint 對得上即可），但有 post-quantum warning。要分散就在 cert regen 後：
```sh
rm -f /etc/ssh/ssh_host_*
/etc/init.d/SSH restart   # 自動 regen
/sbin/auto-backup.sh
```

---

## 10. bringup spec 必須注入 sshThumbprint + sslThumbprint

否則 validator 的 SSH probe（GenerateTempKnownHosts）會撞 OVA-baked 共用 SSH key / cert。每個 `hostSpecs[]` 加：
```json
{
  "hostname": "kosten-vcf91-esx0N",
  "sshThumbprint": "SHA256:...",   // ssh-keyscan -t rsa <ip> | ssh-keygen -lf -
  "sslThumbprint": "XX:XX:..."      // openssl x509 -fingerprint -sha256 -in <cert>
}
```

---

## 11. 長期解（一勞永逸）

跑 `Bake-MasterFinalize.ps1` 把 `/Net/FollowHardwareMac=1` 烤進 master state.tgz **再** export OVA：
```powershell
pwsh scripts/Bake-MasterFinalize.ps1 -EsxiHost 192.168.114.14
pwsh scripts/Export-NestedEsxiOva.ps1 -VMName vcf-m02-esx01-91   # 蓋掉舊 OVA
```
之後 clone 的 vmk0 會自動用唯一 MAC，但 **SSL/SSH/uuid 共用問題仍在**，還是要 Regen-EsxiCert + SSH key regen + uuid sed。（9.1 OVA 還沒做這步，待排。）

---

來源：rtolab `layer1-nested/GOLDEN-OVA-RECOVERY.md`、`scripts/clone-troubleshooting.md`、lab-info `runbooks/golden-ova.md`（2026-05-27 ~ 06-28 實證）。
