# 05 — VSP Supervisor 除錯

> VSP = VCF Services Platform，VCFA 跑在它上面的內嵌 Kubernetes supervisor。這篇專講「VSP supervisor 本身」：怎麼進去、bootstrap 階段卡住、leader-election crashloop、etcd 太慢、斷線後怎麼救、supervisor 啟用的雷。
>
> VCFA **應用層**的除錯（appliance、region quota、gateway 404）在 [06-vcfa.md](06-vcfa.md)。外層資源根因在 [07-outer-resources.md](07-outer-resources.md)。

---

## 0. 先分清楚兩種 supervisor（最常見誤判）

| | **VCFA 內嵌 VSP**（本篇） | **使用者 VKS 的 WCP supervisor** |
|---|---|---|
| 誰管 | VCFA 自帶，**不是** vCenter WCP | vCenter WCP |
| 取密碼 | **沒有** `decryptK8Pwd.py` | `/usr/lib/vmware/wcp/decryptK8Pwd.py` |
| `namespace-management/supervisors` API | **列不出**（別浪費時間走 WCP 路） | 列得出 |
| VM 名 | `*-vspp-*` | supervisor CP VM |

> 一開始最容易誤判：以為 VSP 是 WCP 管的，跑 `decryptK8Pwd.py` 查無、API 列不出 → 誤以為「沒部署」。其實它是 VCFA 內嵌，要走 SSH 進 CP 節點。

---

## 1. 動態找節點 IP（每次 bringup 都會變，不要照抄）

VSP supervisor / VCFA 的節點 IP **每次 bringup 從 IP pool 動態分配，會變**。先從 inner vCenter 撈當前 IP：

```powershell
$vc = Connect-VIServer <inner-vc-ip> -User administrator@vsphere.local -Password <pw>

# VSP supervisor 節點 + 各自 IP（持「兩個 IP」的那台 = 控制平面 / VIP holder）
Get-VM -Server $vc -Name '*vspp*' | ForEach-Object {
  $ips = ($_.ExtensionData.Guest.Net.IpAddress | ? { $_ -match '^\d+\.' }) -join ','
  "{0}: {1}" -f $_.Name, $ips
}
# 兩個 IP 的那台：較小的通常是 API VIP，較大的是節點 real IP；SSH 用 real IP
```
範例（某次 9.1 部署）：CP 節點 real IP `192.168.114.20`、**API VIP `.19`**。**拓樸 = 單 CP 節點（持 VIP）+ 多 worker**。

> ⚠️ **worker 的 6443 本來就不開**（不是 apiserver），別當成掛掉。**關機的 worker 要開回來**（否則 `vmsp-operator` 等 pod Pending 排不進去）。

---

## 2. 登入

```bash
ssh vmware-system-user@<vsp-cp-real-ip>     # 只有這個帳號能 SSH；root/admin 被拒
# 密碼預設 VMware1!VMware1!（⚠️ 會定期輪替）
echo '<pw>' | sudo -S kubectl --kubeconfig=/etc/kubernetes/admin.conf get pods -A
```
- **只有 CP 節點**的 `/etc/kubernetes/admin.conf` 有效，worker 上是空的。
- `sudo` 非互動無 tty → 一律 `echo '<pw>' | sudo -S ...`。
- 密碼輪替失效時：此 vc **非 WCP**，沒有 `decryptK8Pwd.py`。改用 **§5 的 guest reboot CP 節點**（fresh boot 會重置 sshd，SSH 又能進）。

**埠/IP 別測錯**（測錯會誤判成「全掛」）：
- supervisor K8s API 在 **API VIP `:6443`**（不是 443）。
- VCFA platform 對外是 **vmsp-platform 的 vmsp-gateway LoadBalancer `.43/.44/.45/.86:443`**（不是 .77/.87）。

---

## 3. Leader-election crashloop（nested vSAN 最常見的病）

**症狀**：API（VIP `:6443`）不通；`kube-controller-manager` / `kube-scheduler` / **`kube-vip`** CrashLoopBackOff，restart 數狂跳（曾 35/41/124 次，9 天累積 etcd 773 / apiserver 785 / kube-vip 916）。

**根因**：nested vSAN etcd fdatasync 1–4s（double-nested 延遲），超過預設 lease：
- controller-manager/scheduler 預設 renew deadline **10s** → 更新不了 lease → 輸掉 election → exit(1) → crashloop。
- kube-vip 預設 lease 15s / renew 10s / retry 2s → lost lease 就 panic（by design）→ **API VIP flap/unbound → 整個 cluster 經 admin.conf「no route to host」**。

log 特徵：
```
E leaderelection.go:441] Failed to update lock optimistically: ... Client.Timeout exceeded
E controllermanager.go:343] "leaderelection lost"
```

**修法（在 CP 節點改 static pod manifest 加大逾時）**：

controller-manager / scheduler — `/etc/kubernetes/manifests/kube-controller-manager.yaml` 與 `kube-scheduler.yaml`，在 `--leader-elect=true` 後加：
```yaml
    - --leader-elect-lease-duration=120s
    - --leader-elect-renew-deadline=100s
    - --leader-elect-retry-period=20s
```
（有腳本：`pwsh ./scripts/Fix-VspLeaderElection.ps1 -ControlPlaneIp <node-ip>`。）

kube-vip — `/etc/kubernetes/manifests/kube-vip.yaml`：
```sh
sudo sed -i '/vip_leaseduration/{n;s/"15"/"120"/}; /vip_renewdeadline/{n;s/"10"/"100"/}; /vip_retryperiod/{n;s/"2"/"20"/}' /etc/kubernetes/manifests/kube-vip.yaml
```
kubelet 偵測 manifest 改變自動重啟 static pod。驗證：三者 restart 歸 0、`kube-vip` Running、`ip addr show eth0 | grep <VIP>` 有 /32。

> ⚠️ **補丁在 CP 節點 static manifest，supervisor 重建 / CP 節點 reprovision 會遺失，要重套。bringup 前先套可免整條鏈崩。**

---

## 4. etcd 健康度怎麼量（確認是不是儲存太慢）

在 CP 節點（整段包一個 `sudo -S`）：
```bash
echo '<pw>' | sudo -S sh -c '
  C=$(crictl ps --name etcd -q | head -1)
  crictl exec $C etcdctl --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key endpoint health
  # wal_fsync / backend_commit：抓兩次算 12 秒平均
  A=$(curl -s http://127.0.0.1:2381/metrics | grep -E "etcd_disk_wal_fsync_duration_seconds_(sum|count)")
  sleep 12
  B=$(curl -s http://127.0.0.1:2381/metrics | grep -E "etcd_disk_wal_fsync_duration_seconds_(sum|count)")
  echo "A:"; echo "$A"; echo "B:"; echo "$B"
  crictl ps -a --name "etcd|kube-apiserver|kube-vip"    # ATTEMPT 欄 = restart 次數
  uptime
'
```
**判讀**：`avg = Δsum / Δcount`（B−A）。**wal_fsync 健康 < 10ms**，> 100ms 危險（故障時量到 135ms ~ 4s）。fsync 爆高 → 根因在儲存/CPU → 跳 [07-outer-resources.md](07-outer-resources.md)（等 resync 完、nested FTT=0、解外層 CPU 超賣）。修完底層 fsync 回 5–13ms，控制平面自然穩。

---

## 5. supervisor API 不通 → guest reboot CP 節點

leader-election 補丁後 API（VIP `:6443`）仍不通、或 SSH 進不去（密碼輪替/sshd 壞）：**從 vCenter guest reboot CP 節點**（`*-vspp-*`，`Restart-VMGuest` / `PowerOnVM`）。kubelet 開機自動重拉 static pod（etcd/apiserver/kube-vip）→ VIP 回來、`/healthz`=200。**重開後 SSH 也恢復**（fresh boot 重置 sshd）。記得關機的 worker 要一起開回來。

---

## 6. VSP Bootstrap VM（部署期間的臨時 CAPI/CAPV 管理叢集）

> 只在 bringup 跑到 **「Monitor VCF Management Services Deployment Task」** 階段存在；VSP supervisor 建好、pivot/handoff 完成後**自動刪除**，要看趁這個視窗。

**它是什麼**：inner vCenter 裡名為 `bootstrap-vm-*` 的 **Photon OS** VM，自帶單節點 K8s（etcd+apiserver+controller/scheduler 都在本機），上面跑 **Cluster API + CAPV**（`capv-controller-manager`、`capi-ipam`、`capi-kubeadm-control-plane`、`cert-manager`、`vmsp-operator`）+ `vmsp-agent -role=bootstrap`（API 在 `:5480`）+ 內建 image registry。它用 CAPV 去 vSphere 上 provision 真正的 VSP supervisor 節點（`*-vspp-*`），完成後 pivot 掉。

**找它的 IP**：通常是 VSP `ipv4Pool` 的**第一個 IP**（某次 = `192.168.114.18`）；或 inner vCenter `Get-VM '*bootstrap*'` 看 guest IP。

**登入 + 檢查 VSP 部署進度（關鍵除錯視角）**：
```bash
ssh vmware-system-user@<bootstrap-ip>      # 密碼 VMware1!VMware1!（Photon OS）
KC=/etc/kubernetes/admin.conf
# bootstrap agent 健康（apiReady / clusterHealthy）
echo 'VMware1!VMware1!' | sudo -S curl -sk https://127.0.0.1:5480/api/v1/status
# CAPI 正在生的 VSP supervisor cluster/節點（看 provisioning 卡在哪）
echo 'VMware1!VMware1!' | sudo -S kubectl --kubeconfig=$KC get clusters,machines,vspheremachines,vspherevms -A
echo 'VMware1!VMware1!' | sudo -S kubectl --kubeconfig=$KC get pods -A | grep -vE 'Running|Completed'
# CAPV controller log（vSphere 端錯誤：資源不足 / placement / OVA import 失敗）
echo 'VMware1!VMware1!' | sudo -S kubectl --kubeconfig=$KC logs -n capv-system deploy/capv-controller-manager --tail=50
echo 'VMware1!VMware1!' | sudo -S tail -50 /var/log/cloud-init-output.log
```
**判讀**：`vmsp-agent` 回 `{"apiReady":true,"clusterHealthy":true}` = bootstrap 本身 OK；VSP 卡住看 `machines`/`vspheremachines` 的 phase 卡在哪（Provisioning/Pending），以及 `capv-controller-manager` log 有沒有 vSphere 端錯誤。

---

## 7. Supervisor 啟用（user VKS 用 WCP supervisor）的雷

> 這段是**使用者 VKS** 的 WCP supervisor（不是 VCFA 內嵌 VSP），但啟用流程的雷很容易踩，一併收錄。

1. **REST `POST /api/vcenter/namespace-management/supervisors` 在 9.1 回 404（不可用）** → 正解走 **dcli**：
   `dcli com vmware vcenter namespacemanagement supervisors enableoncomputecluster`（`--cluster domain-cN --workloads-edge-provider NSX_VPC --workloads-network-network-type NSX_VPC` + nsx-vpc-project / vpc-connectivity-profile / default-private-cidrs；用 base64 bash 灌進 vCenter shell）。

2. **「Need 2 net devices, but found only 1」** = DTGW 的 **Distributed VLAN Connection (DVC) + service gateway 漏建**（災難前是 UI 點的）。補 NSX policy API：`PATCH /policy/api/v1/infra/distributed-vlan-connections/<dvc>`、`PATCH .../transit-gateways/default/attachments/<id>`（connection_path=DVC）、VPC profile 補 `service_gateway{enable, nat_config.enable_default_snat, auto_snat_ip_block, edge_cluster_paths:[VNA cluster path]}`。
   > Path A（DTGW+VNA 無 edge）external 走 service_gateway 的 VNA = 「Service Cluster」，GatewayConnection(tier0_path) 是 edge 模式才有 → `GatewayConnectionReady=False` 是正常。

3. **【關鍵雷】WCP cache 了 VPC profile 驗證**：supervisor 在 profile 還沒 service_gateway 時就啟用，之後補了也沒用 —— nsx-operator 讀 live NSX 看到 `ServiceClusterReady=True`，但 vCenter 一直報 `vcenter.wcp.nsxvpc.{gw.conn,service_cluster}.not.set`，master node `Did not find any cluster netif` + `Ingress IP Pool is empty`，卡死。
   **正解 = `/usr/lib/vmware-vmon/vmon-cli --restart wcp` 強制重讀 profile** → 立刻 `Processing service cluster <vna>`、找到 cluster netif、條件翻 TRUE、messages 清空。
   **症狀記法：profile 改對了（nsx-operator 認）但 vCenter 還報 not set → 一定是 wcp cache，restart wcp。** 診斷靠 `/var/log/vmware/wcp/wcpsvc.log`。

4. **外部 LB VIP（external block，例 `.135` / gw `.129`）不通**：supervisor RUNNING、CP 內部端點全通，但 external VIP + gateway ping/TCP 全不通。
   - **症狀**：同 VLAN 上「VM vNIC IP ARP 可達、NSX 邏輯 IP（gw/LB VIP）ARP FAILED」。
   - **已排除**：inner NSX policy 全 REALIZED/SUCCESS 無 alarm；outer trunk PG promisc/forged/mac 全 True、toggle 無效（非 swsec）；routing（native subnet 都不通）。
   - **真因 = VNA 沒實際 serve 這條 external VLAN connection**（沒有 data interface 在該 VLAN 上幫 external block 應答 ARP）= vCenter「Distributed Connectivity」精靈裡「select VNA cluster」沒做到位。vCenter External Connection 的 Edit dialog **沒有 VNA 欄位**（只有 Name/Type/VLAN/Gateway CIDR）→ 綁 VNA 只能走完整「ADD EXTERNAL CONNECTION」精靈（需先刪 API 建的 DVC 再 Re-Add 帶 VNA + external IP block + Default Outbound NAT，屬破壞性）。
   - **繞法（不修 external 也能建 guest cluster）**：supervisor 所有 LB virtual server（含 `kube-apiserver-lb-svc:6443`）都在**內部 service CIDR 172.29.x**，external VIP 不通**不擋** guest cluster 建立。kubectl 走內部 CP IP：`kubectl vsphere login --server=<cp-internal-ip>`，namespace context 會指向死的 external VIP → 改用 cluster-scoped context `kubectl --context=<cp-ip> -n <ns>`。

5. **CLS（content-library）連不到 `wp-content.vmware.com`**（supervisor image / TKr 庫拉不到，image items `cached=False`）：
   - 高層只報 `connection_to_vcsp_server_failed`（誤導）；真因在 `/var/log/vmware/content-library/cls.log` 的 `Caused by`：BouncyCastle FIPS JSSE 對 wp-content **建不出憑證鏈**（`CertPathBuilderException`，疑被 cross-signed root 卡）。OS curl 成功是 OpenSSL 會補鏈，BC 不會 —— **DNS/TLS信任/網路/proxy 全是好的，別再查那些**。
   - **解法 = 訂閱帶 `ssl_thumbprint`（SHA-1，冒號 hex）繞過建鏈**：現有 library `PATCH /api/content/subscribed-library/{id}` 補 thumbprint → `POST .../{id}?action=sync`。取 thumbprint：
     `echo | openssl s_client -connect wp-content.vmware.com:443 -servername wp-content.vmware.com | openssl x509 -noout -fingerprint -sha1`
   - **node image 庫別關錯**：supervisor image 用 v1 lib，**guest cluster node image 要 v2 TKr lib**。vCenter「Supervisor → Configure → Kubernetes Service」把 `tkg-tkr-library` 也關聯上 → `kubectl get kubernetesreleases` 才會冒出可用版本（UI 表格會 stale，以 kubectl 為準）。

---

## 8. 斷線後的連鎖損害恢復鏈（VIP/API 多時 outage 後，照這個序）

VSP API VIP 斷數小時，會往下打掛一整串。**照順序修**：

1. **inner vCenter 服務半死**（`service-control --status`：cis-license / sps / wcp / vpxd-svcs / trustmanagement / eam 停）
   → vCenter SSH `shell` → `service-control --start --all`（15–30 分，不可取消；會卡 sps 但多數服務已起，sps 後來自行 STARTED）。**trustmanagement 一起來，host reconnect 立刻成功。**
   > 症狀：host reconnect 報 `Cannot complete the license assignment operation`（其實是 trustmanagement/vpxd-svcs 沒起）；CNS detach 報 `vim.fault.CnsFault`。
2. **nested host 對 inner vCenter NotResponding**（vpxa hung，網路其實通）
   → host SSH 常被 bringup 關 → PowerCLI 直連 host hostd `Restart-VMHostService vpxa` → 從 vCenter Reconnect（**需先做步驟 1 把 license 服務起來**）。
3. **CSI VolumeAttachment 卡 DELETING**（舊 attach 沒 detach `HostNotConnected`、新 attach `ResourceInUse`）→ 步驟 1-2 恢復 detach path 後自解。
4. **VSP 平台 pod**（seaweedfs → zot registry → ImagePullBackOff everywhere → Fleet Build 500）→ volume attach 後 **bottom-up 自癒**；Fleet LCM retry 只在 `vcf-fleet-*` / `vmsp-platform` namespace 乾淨後才做。

> 教訓：**硬斷恢復後先 `service-control --start --all` 補齊 vCenter 服務**，否則 host 重連、licensing、wcp、CSI、VCFA 全卡。

---

來源：rtolab `layer3-postbringup/k8s-access-and-checks.md`、`vcf-operations-automation-deploy-troubleshooting.md`、`docs/recovery-2026-06-vsan-cmmds-to-vks-rebuild.md`、lab-info `runbooks/bringup.md`、`incident-2026-06-18-vsan-cmmds-dropout.md`、memory `project_vsp_outage_recovery`（2026-05 ~ 06 vcf-m02 實證）。
