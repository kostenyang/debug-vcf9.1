# 05 — Supervisor / VSP / VCFA / vCenter 服務恢復鏈

> VCFA（VCF Automation）跑在內嵌的 VSP supervisor（K8s）上。nested vSAN 一慢，etcd 就拖垮控制平面，整條鏈往上崩。這篇是「從上層服務 404 一路追到 etcd」的恢復鏈。
>
> **先決：量底層健康度再修上層。** load ≫24 / etcd fsync ≫100ms 時別硬戳 pod（篇章 06）。

---

## 0. 兩種 supervisor 別搞混

| | VCFA 內嵌 VSP | 使用者 VKS (WCP) supervisor |
|---|---|---|
| 誰管 | VCFA 自帶（**非** vCenter WCP） | vCenter WCP |
| 取密碼 | **沒有** `decryptK8Pwd.py` | `/usr/lib/vmware/wcp/decryptK8Pwd.py` |
| 進法 | SSH `vmware-system-user` 到 CP 節點 | 同左 |
| API | CP 節點 VIP `:6443` | supervisor API |

本篇主要講 **VCFA 內嵌 VSP**。拓樸：單 CP 節點（持 VIP）+ 多 worker。**worker 的 6443 本來就不開，別誤判成掛**；關機的 worker 要開回來（否則 `vmsp-operator` 等 pod Pending 排不進去）。

---

## 1. 控制平面 leader-election crashloop（最常見根因）

**症狀**：supervisor API（VIP `:6443`）不通；`kube-controller-manager` / `kube-scheduler` / **`kube-vip`** CrashLoopBackOff（restart 數狂跳，曾 35/41/124 次）。

**根因**：nested vSAN etcd fdatasync 1–3s（double-nested 延遲），超過預設 lease：
- controller-manager/scheduler 預設 renew deadline **10s** → 更新不了 lease → 輸掉 election → exit(1) → crashloop
- kube-vip 預設 lease 15s / renew 10s / retry 2s → lost lease 就 panic（by design）→ **VIP (`.19`) flap/unbound → 整個 cluster 經 admin.conf「no route to host」**

log 特徵：
```
E leaderelection.go:441] Failed to update lock optimistically: ... Client.Timeout exceeded
E controllermanager.go:343] "leaderelection lost"
```

**修法（在 CP 節點，改 static pod manifest 加大逾時）**：

controller-manager / scheduler —— `/etc/kubernetes/manifests/kube-controller-manager.yaml` 與 `kube-scheduler.yaml`，在 `--leader-elect=true` 後加：
```yaml
    - --leader-elect-lease-duration=120s
    - --leader-elect-renew-deadline=100s
    - --leader-elect-retry-period=20s
```
（有腳本：`pwsh ./scripts/Fix-VspLeaderElection.ps1 -ControlPlaneIp <node-ip>`。）

kube-vip —— `/etc/kubernetes/manifests/kube-vip.yaml`：
```sh
sudo sed -i '/vip_leaseduration/{n;s/"15"/"120"/}; /vip_renewdeadline/{n;s/"10"/"100"/}; /vip_retryperiod/{n;s/"2"/"20"/}' /etc/kubernetes/manifests/kube-vip.yaml
```
kubelet 偵測 manifest 改變自動重啟 static pod。驗證：三者 restart 歸 0、`kube-vip` Running、`ip addr show eth0 | grep <VIP>` 有 /32。

> ⚠️ **補丁在 CP 節點 static manifest，supervisor 重建 / CP 節點 reprovision 會遺失，要重套。** bringup 前先套可免整條鏈崩。

---

## 2. etcd 健康度怎麼量（確認是不是儲存太慢）

在 CP 節點（crictl）：
```bash
# fsync / backend_commit：抓兩次 metrics 算差值平均（12 秒取樣）
curl -s http://127.0.0.1:2381/metrics | grep -E \
  'etcd_disk_wal_fsync_duration_seconds_(sum|count)|etcd_disk_backend_commit_duration_seconds_(sum|count)'
# avg = Δsum / Δcount；健康 < 10ms，> 100ms 即危險（本案曾 135ms ~ 4s）

C=$(crictl ps --name etcd -q | head -1)
crictl exec $C etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key endpoint health

crictl ps -a --name "etcd|kube-apiserver|kube-vip"   # 看 restart 次數
```
fsync 爆高 → 根因在儲存（篇章 06：等 outer vSAN resync 完、nested FTT=0、外層 CPU 解超賣）。修完底層 fsync 回 5–13ms，控制平面自然穩。

---

## 3. supervisor API 不通的另一招：guest reboot CP 節點

若 leader-election 補丁後 API（VIP `:6443`）仍不通：**guest reboot CP 節點**（`*-vspp-*`），kubelet 開機自動重拉 static pod（etcd/apiserver/kube-vip）→ VIP 回來、`/healthz`=200。重開後 SSH 也恢復（重置 sshd）。記得關機的 worker 要開回來。

---

## 4. VCFA gateway 404/503、pod 卡掛載

### 4a. 先量 load —— overload 別硬戳
```bash
K="echo <pw> | sudo -S kubectl --kubeconfig=/etc/kubernetes/admin.conf"
eval $K get pods -A | awk '{print $4}' | sort | uniq -c     # pod 相位統計
eval $K get pods -A | grep -vE "Running|Completed"          # 不健康的 pod
uptime                                                       # load >24 = 超賣（曾飆 456/584）
iostat -x 1 2                                                # write await >10ms = 儲存太慢
```
> load ~300+ 時 SSH/kubectl 會直接 timeout（apiserver 餵不動）。`CreateContainerConfigError`/`ImagePullBackOff`/CrashLoop **都是 overload 下游症狀**，等 load 降會自癒（provider 回 302 = 好了）。先去查/修 outer（篇章 06），別硬戳 pod。

### 4b. CSI globalmount 死掛載（nested host PSOD 後）
nested ESXi PSOD/掉線後，CSI 磁碟掛載變**死掛載**（node 回來後仍 `input/output error`），有 PVC 的 pod（kafka/rabbitmq/postgres）卡住**不會自癒**。

**判斷**：`kubectl describe pod` 看到 `FailedMount ... csi.vsphere.vmware.com/<hash>/globalmount: input/output error`（關鍵字 **globalmount** = node 層 staging 掛載死掉）。`kubectl get pvc` 通常還 Bound。

**修（外科，免重開整台）**：SSH 進 appliance，掃所有 csi globalmount，把 `stat` 卡住的 lazy 強制卸載，CSI 會自動重 stage 乾淨的：
```bash
for m in $(mount | grep csi.vsphere.vmware.com | grep globalmount | awk '{print $3}'); do
  timeout 5 stat "$m" >/dev/null 2>&1 || { echo "wedged: $m"; echo <pw> | sudo -S umount -f -l "$m"; }
done
```
（2026-06-29 esx04 PSOD 後實測：22 個 globalmount 全 wedge，清完 kafka/rabbitmq/resource-manager 全自己 Running，Event Broker 復活 → org/quota 才能建。）頑固的再 `kubectl delete pod` 踢出 backoff。

### 4c. CSI → CNS → SPS 連鎖（provision/attach 全失敗）
VCFA gateway 全 404 = 應用 pod 沒 serving。根因鏈與修序：
1. **殭屍 VCFA platform VM**（凍結後 guest hang，power op 報「communicating with remote host」）→ host 端 `esxcli vm process kill -t hard -w <wid>` + `vim-cmd vmsvc/power.on <vmid>`；vCenter view 與 host 不同步 → host `/etc/init.d/vpxa restart` 強制 resync。
2. **CSI 無法 provision/attach**（`kubectl -n kube-system logs -l app=vsphere-csi-controller`）：provision 失敗 `PBM error PreProvisionProcess: No version for /pbm/sdk`；attach 失敗 `CNS ResourceInUse`。
3. 修序：`rollout restart deploy vsphere-csi-controller` → vc 重啟 `vmware-vsan-health`（CNS resync）→ **`vmware-sps` 卡 START_PENDING（曾 ~12h）** → 正解 = 整台 vCenter `service-control --stop --all && --start --all` → SPS STARTED。
4. SPS 好後 PVC 自動 provision；卡 attach 的 `kubectl delete pod` 強制乾淨重 attach → `volumeattachment` false 歸零 → 應用 serving。

> **端點別測錯**：VCFA 是 path-based gateway，`/` 回 404 正常。用 mapped path 驗（例 `/certificate-management/certificate-bundle` 回 **200** = 後端 serving）。`vcfms.broadcom.com` 是 LB 憑證 SAN，不是路由 host；實際 host 是 `kosten-vcf91-{vspp,fleet,vidb,vsp}.rtolab.local`，平台對外是 LB `.43/.44/.45/.86:443`（**非 .87/.77**）。supervisor K8s API 在 **VIP `.19:6443`（非 443）**。

---

## 5. vCenter 服務沒全起（硬斷恢復後必做）

nested 管理叢集硬斷恢復後，vCenter **API 起來但一票服務 STOPPED**（`/api/vcenter/services` 或 `service-control --status`）：vpxd-svcs、trustmanagement、wcp、content-library、sps、certificatemanagement…

- **症狀連鎖**：host reconnect 報 `Cannot complete the license assignment operation`（其實是 `trustmanagement`/`vpxd-svcs` 沒起，不是 license）；CNS detach 報 `vim.fault.CnsFault`；wcp/VKS 全卡。
- **修法**：vCenter SSH → `shell` → `service-control --start --all`（15–30 分，不可取消）。會卡在 sps「Operation not allowed in current service state」但多數服務已起、sps 後來自行 STARTED。**trustmanagement 一起來，host ReconnectHost 立刻成功。**
- 剩 6 個非必要服務常態 STOPPED（imagebuilder/liagent/netdumper/rbd/vcha/vmcam），不影響。

> **教訓**：硬斷恢復後**先 `service-control --start --all` 補齊 vCenter 服務**，否則 host 重連、licensing、wcp/VKS 全卡。

---

## 6. host 對 inner vCenter NotResponding（網路其實正常）

vc 能 ping/curl 到 host，但 host 顯示 NotResponding = **vpxa hung**（復原時 churn 造成）。SSH 在 host 上常已關 → PowerCLI **直連 host hostd**（root / lab pw）`Restart-VMHostService` 重啟 `vpxa` → 再從 vCenter Reconnect（**需先做 §5 把 license 服務起來**）：
```powershell
$hv.ReconnectHost_Task($spec, $null)   # spec.userName=root, spec.force=$true
```

---

## 7. 完整恢復順序（VIP/API 多時 outage 後，照這個序）

1. **inner vCenter 服務半死** → `service-control --start --all`（§5）
2. **nested host NotResponding** → 直連 hostd 重啟 vpxa → Reconnect（§6）
3. **CSI VolumeAttachments 卡 DELETING**（舊 attach 沒 detach `HostNotConnected`、新 attach `ResourceInUse`）→ §1-2 恢復 detach path 後自解
4. **VSP 平台 pod**（seaweedfs → zot registry → ImagePullBackOff → Fleet Build 500）→ volume attach 後 bottom-up 自癒；Fleet LCM retry 要等 `vcf-fleet-*` / `vmsp-platform` namespace 乾淨

---

來源：lab-info `runbooks/incident-2026-06-18-vsan-cmmds-dropout.md`、`bringup.md`、rtolab `docs/recovery-2026-06-vsan-cmmds-to-vks-rebuild.md`、`docs/debug-vcfa-nested-cheatsheet.md`、`layer3-postbringup/vcf-operations-automation-deploy-troubleshooting.md`、memory `project_vsp_outage_recovery`。
