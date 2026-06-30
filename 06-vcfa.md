# 06 — VCFA (VCF Automation) 除錯

> VCFA = VCF Automation，VCF 9.1 的自助式雲端消費層。它**跑在一台 Photon appliance** 上（單節點 K8s），對外透過 path-based gateway。這篇專講 VCFA 應用層：搞清楚它到底是什麼、災後怎麼救活、gateway 404/503、region quota 失敗、provider 啟用。
>
> 它底下的 VSP supervisor 除錯在 [05-vsp-supervisor.md](05-vsp-supervisor.md)；外層資源根因在 [07-outer-resources.md](07-outer-resources.md)。

---

## 0. VCFA 到底是什麼（先破除三個誤判）

1. **VCFA 是「一台 appliance」，不是 supervisor 上的 pod。**
   它是一般 Photon OS appliance（`*-vcfa-platform-*`，例 `kosten-vcf91-vcfa-platform-56s85`），`ManagedBy=none`，**本來就該有 mgmt IP**，內部跑單節點 K8s 承載 VCFA 服務。早期誤判「它沒 IP 正常 / 它沒部署」都是錯的 —— 在 vspp supervisor 上查不到它，是因為它不在 supervisor 上。

2. **端點（別測錯，否則誤判「全掛」）**：
   | 用途 | 位置 |
   |---|---|
   | Provider portal | `https://<...>-auto.rtolab.local/provider/home`（`.77:443`；org `system` / user `admin`）|
   | appliance VAMI | `<...>.80:5480`（`com.vmware.vcfms.api`）|
   | platform gateway（對外 LB） | vmsp-gateway LoadBalancer `.43/.44/.45/.86:443` |
   - **path-based gateway**：`/` 與 `/provider/`（尾斜線）回 **404 是正常**，要用 mapped path 驗：
     `curl --resolve <...>-vspp.rtolab.local:443:192.168.114.43 https://<...>-vspp.rtolab.local/certificate-management/certificate-bundle` 回 **200** = 後端 serving。
   - `vcfms.broadcom.com` 是 LB 憑證 SAN，**不是路由 host**。
   - `/provider/bootstrap-failure`「Failed to Start / unsupported public URL」是服務還沒起完的**暫態**，按 RETRY 即進登入頁，不是 IP 問題。

3. **登入 appliance**：SSH **只有 `vmware-system-user`**（root/admin SSH 被拒），`sudo` 拿 root；kubectl=`/etc/kubernetes/admin.conf`（單節點 k8s）。provider admin 與 appliance OS 密碼**是不同組**，且非 lab 標準（向使用者取得；登入框密碼依規則不由 Claude 代填）。

---

## 1. 災後 appliance 救活（NIC 斷線 → 服務全停）

**症狀**：大 outage（vSAN/vCenter 凍結）後，VCFA 整個服務停掉（`/provider/home` 連線被拒、`.77` 不通）。

**根因**：appliance 的**網卡被斷線**（`connected=False` 但 `startConnected=True`）→ 沒 IP → 服務停。**不是要重部**。

**救活步驟（實證成功）**：
```powershell
# 1. 把網卡接回 → 立刻拿到 mgmt IP（VAMI .80:5480 回 401 = 服務活著但 app 沒起）
Get-NetworkAdapter -VM <vcfa-platform-vm> | Set-NetworkAdapter -Connected:$true -Confirm:$false
# 2. tools 也停了 → 硬重開
(Get-VM <vcfa-platform-vm>).ExtensionData.ResetVM_Task()
# 3. 等約 14 分鐘 → .77:443 起來、/provider/home 回 200
```
> 若 guest hang（tools 不跑 / bootTime 不更新 / vCenter 顯示 stale）：vCenter Reset/PowerOff 會「communicating with remote host」失敗 → 進 host SSH `esxcli vm process kill -t hard -w <wid>` + `vim-cmd vmsvc/power.on <vmid>`；若之後 vCenter view 跟 host 不同步（NIC connected 反值 / Reload 被禁）→ host 上 `/etc/init.d/vpxa restart` 強制 resync。

---

## 2. gateway 404 / pod 卡掛載（CSI → CNS → SPS 連鎖）

VCFA gateway 全 404 = 應用 pod 沒 serving。最常見根因鏈是 **vSphere CSI**。

### 2a. 先量 load —— overload 別硬戳
```bash
K="echo <pw> | sudo -S kubectl --kubeconfig=/etc/kubernetes/admin.conf"
eval $K get pods -A | awk '{print $4}' | sort | uniq -c       # 相位統計
eval $K get pods -A | grep -vE "Running|Completed"
uptime ; iostat -x 1 2                                        # load >24 / write await >10ms = 底層太慢
```
> load ~300+ 時 SSH/kubectl 直接 timeout。`CreateContainerConfigError`/`ImagePullBackOff`/CrashLoop **多半是 overload 下游症狀**，修完底層 load 降會自癒（provider 回 302）。先去 [07-outer-resources.md](07-outer-resources.md) 查外層 CPU/vSAN，別硬戳 pod。
> `Init:CreateContainerConfigError`（等 per-service DB 密鑰）若 `RESTARTS=0` 會自解；`prelude` namespace 空 = 平台層（`vmsp-platform`）還沒建完，屬正常順序。真正警戒：新 `CrashLoopBackOff`、RESTARTS 累加。

### 2b. CSI globalmount 死掛載（nested host PSOD 後）
nested ESXi PSOD/掉線後，CSI 磁碟掛載變**死掛載**（node 回來仍 `input/output error`），有 PVC 的 pod（kafka/rabbitmq/postgres）卡住**不會自癒**。

**判斷**：`kubectl describe pod` 看到 `FailedMount ... csi.vsphere.vmware.com/<hash>/globalmount: input/output error`（關鍵字 **globalmount**）。`kubectl get pvc` 通常還 Bound。

**修（外科，免重開整台）**：
```bash
for m in $(mount | grep csi.vsphere.vmware.com | grep globalmount | awk '{print $3}'); do
  timeout 5 stat "$m" >/dev/null 2>&1 || { echo wedged:$m; echo <pw> | sudo -S umount -f -l "$m"; }
done
```
（2026-06-29 esx04 PSOD 後：22 個 globalmount 全 wedge，清完 kafka/rabbitmq/resource-manager 全自己 Running，Event Broker 復活。）頑固的再 `kubectl delete pod` 踢出 backoff。

### 2c. CSI provision/attach 全失敗（SPS 卡 START_PENDING）
`kubectl -n kube-system logs -l app=vsphere-csi-controller`：
- provision 失敗 `PBM error PreProvisionProcess: No version for /pbm/sdk`
- attach 失敗 `CNS ResourceInUse`

修序：
1. `kubectl -n kube-system rollout restart deploy vsphere-csi-controller`（新 vCenter session）
2. vc 重啟 `vmware-vsan-health`（CNS resync 清 stale attach）
3. `vmware-sps` —— 但 **sps 卡 RunState START_PENDING 達 ~12h**（sps.log 連下游 503）；`service-control --restart vmware-sps` 回「Operation not allowed in current service state」→ **正解 = 整台 vCenter `service-control --stop --all && --start --all`（~10–15 分）** → SPS STARTED/HEALTHY。
4. SPS 好後 PVC 自動 provision；卡 attach 的（如 seaweedfs-volume-2）`kubectl delete pod` 強制乾淨重 attach → `volumeattachment` false 歸零 → 應用 serving。

---

## 3. region quota 失敗 = appliance 過載（不是 config bug）

**症狀**：Organization 精靈 Step 2「Assign a Region Quota」持續失敗，後端錯 `There must be a default no argument constructor for class ...UpdateRegionQuotaActivity$FinalPhase / CreateRegionQuotaActivity`，Recent Tasks「Created Region Quota — Failed」，重試多次無進展。

**根因（實證）**：**不是 VCFA config bug，是 appliance 嚴重過載** → valc activity 反序列化壞掉（下游症狀）。進 appliance 確診：
```bash
uptime          # load average 276/359/330（24 核，健康應 ≤24）
iostat -x       # 各核 iowait 40-56%（nested vSAN 太慢、disk thrash）
echo <pw> | sudo -S kubectl --kubeconfig=/etc/kubernetes/admin.conf get pods -A | grep -vE 'Running|Completed'
# etcd/apiserver/kube-vip 重啟數爆（9 天 773/785/916）+ prelude/vksm 多個 CrashLoopBackOff
```

**真根因在外層**（appliance .80 iostat 寫延遲 122–442ms，etcd 要 <10ms）：**外層 SELAB-Cluster CPU 被灌爆**（多組 nested lab 同時跑 → 4.3x 超賣 → nested ESXi CPU ready 33% → 處理不了 vSAN I/O → etcd 死亡螺旋）。

**解法（只動自己 4 台 nested ESXi，不碰別人 / 共用 default policy）**——詳見 [07-outer-resources.md](07-outer-resources.md)：
1. CPU shares → High
2. disk shares → High
3. 建專屬 `vcf-m02-nested-FTT0` policy（FTT=0）套 home + disks → 外層寫入砍半

實證：下完三招 appliance load **456 → 74 並續降**，region quota 才能過。

> 教訓：**region quota / VCFA 不穩，先查外層 host CPU 超賣 + nested ESXi CPU ready + 外層 FTT，不要只盯 inner appliance。** 另外 HA VM Monitoring 必須關（心跳 lag 會讓 HA 重啟 appliance，越救越亂 —— 見 07 §HA）。

---

## 4. Provider 啟用流程（救活後手動 Manual Setup）

DTGW 環境 Quick Start 灰掉不可用 → 走 Manual Setup。Provider portal `/provider/home`（admin / org `system`）的 Get Started 五步：

1. **Create Region** — NSX + supervisor + storage policy（FTT=0「Management Storage Policy - Single Node」）
2. **Create External IP Block** — ⚠️ **VCFA 的「External IP Block」是它自管的**（NSX 那塊不會自動匯入），且 **CIDR + IP-Range 不能互相包含**（會報 overlapping internal scopes）→ 解法 = **只填 IP-Range**（例 `192.168.114.160-190`，給 VKS 用的 .129/.135 留空子段），**不填 CIDR**。
3. **Create External Connection**
4. **Create Organization**
5. **Regional Networking**

> Step 2「Assign a Region Quota」失敗看 §3（過載問題）。

---

## 5. 快速判讀

| 症狀 | 多半是 | 去 |
|---|---|---|
| `.77`/`/provider/home` 完全不通 | appliance NIC 斷線 / 服務停 | §1 救活 |
| gateway 404 但 mapped path 也 404 | pod 沒 serving（CSI/SPS） | §2 |
| pod `FailedMount globalmount` | CSI 死掛載（PSOD 後） | §2b |
| pod 大量 CrashLoop + load 爆高 | appliance 過載（外層 CPU） | §3 + [07](07-outer-resources.md) |
| region quota task Failed | 同上（過載下游） | §3 |
| `/` 回 404 | **正常**（path-based gateway） | 用 mapped path 驗 |

---

來源：rtolab `layer3-postbringup/vcf-operations-automation-deploy-troubleshooting.md`、`k8s-access-and-checks.md`、`docs/recovery-2026-06-vsan-cmmds-to-vks-rebuild.md`、`docs/debug-vcfa-nested-cheatsheet.md`、memory `project_vsp_outage_recovery`（2026-05 ~ 06 vcf-m02 實證）。
