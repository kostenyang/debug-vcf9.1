# Reference — 指令速查

> 可直接複製。範例 IP 是 rtolab vcf-m02（`192.168.114.x`）；home lab 換 `10.0.0.x`/`10.0.1.x`。密碼 `<pw>` 預設 `VMware1!VMware1!`。

---

## 登入 / 取得 shell

```powershell
# nested ESXi：PowerCLI 直連 host（不必開 SSH，走 443）
Connect-VIServer 192.168.114.14 -User root -Password '<pw>'
$esx = Get-EsxCli -V2
Start-VMHostService -HostService (Get-VMHostService | ? Key -eq 'TSM-SSH')   # 開 SSH

# nested ESXi：plink（Windows）
& 'C:\Program Files\PuTTY\plink.exe' -ssh -batch -pw '<pw>' root@192.168.114.14 'esxcli vsan cluster get'

# Posh-SSH（VCFA/VSP 節點，只有 vmware-system-user）
$cred = New-Object PSCredential('vmware-system-user',(ConvertTo-SecureString '<pw>' -AsPlainText -Force))
$s = New-SSHSession -ComputerName 192.168.114.20 -Credential $cred -AcceptKey -Force
```

```bash
# SDDC Manager / Installer：vcf 登入後拿 root（pty + su）
(sleep 2; echo '<root-pw>') | script -qec "su - root -c '<command>'" /dev/null

# vCenter：換 root 預設 shell 成 bash
shell chsh -s /bin/bash root          # 回復：chsh -s /bin/appliancesh root

# vCenter 內建 pyVmomi
PYTHONPATH=/usr/lib/vmware/site-packages python3 ...

# VSP/VCFA CP 節點：kubectl（必帶 kubeconfig，sudo 非互動）
echo '<pw>' | sudo -S kubectl --kubeconfig=/etc/kubernetes/admin.conf get pods -A
# WCP supervisor 取密碼（VCFA 內嵌 VSP 沒這支）
/usr/lib/vmware/wcp/decryptK8Pwd.py
```

---

## vSAN

```bash
esxcli vsan cluster get                       # Member Count / Master / Local Node UUID / Unicast Mode
esxcli vsan cluster unicastagent list         # peer 清單（空 = partition 根因）
esxcli vsan cluster unicastagent add -a <peer-vsan-ip> -u <peer-uuid> -t node -U true
esxcli vsan cluster unicastagent remove -u <peer-uuid>
esxcli network ip interface ipv4 get -i vmk2  # vSAN VMK IP（unicast peer 用這個，不是 mgmt）

esxcli vsan storage list | grep -E "Is Mounted|In CMMDS|Is Capacity Tier"   # 找 In CMMDS:false
esxcli vsan storage diskgroup unmount -u <diskgroupUUID>     # 久跑，SSH 可能 timeout 但會完成
esxcli vsan storage diskgroup mount   -u <diskgroupUUID>
esxcli vsan debug object health summary get
esxcli vsan debug resync summary get          # Total Bytes Left To Resync 要歸 0
esxcli storage core adapter rescan --all
```

```powershell
# host API 跑 diskgroup mount（不開 SSH；注意 443 有 300s timeout）
$esx.vsan.storage.diskgroup.unmount.Invoke(@{uuid=$dg})
$esx.vsan.storage.diskgroup.mount.Invoke(@{uuid=$dg})

# vSAN health 一覽
$vchs = Get-VsanView -Id 'VsanVcClusterHealthSystem-vsan-cluster-health-system'
$vchs.VsanQueryVcClusterHealthSummary((Get-Cluster vcf-m02-cl01).ExtensionData.MoRef,
  $null,$null,$true,$null,$false,'defaultView').ClusterStatus.TrackedHostsStatus | Format-Table -AutoSize
```

unicast peer 批次（plink）：
```powershell
$pwd='<pw>'
$peers=@{ '192.168.114.14'=@(
  'esxcli vsan cluster unicastagent add -a <esx02-vsan-ip> -u <esx02-uuid> -t node -U true'
  'esxcli vsan cluster unicastagent add -a <esx03-vsan-ip> -u <esx03-uuid> -t node -U true'
  'esxcli vsan cluster unicastagent add -a <esx04-vsan-ip> -u <esx04-uuid> -t node -U true') }
foreach($h in $peers.Keys){ foreach($c in $peers[$h]){
  & 'C:\Program Files\PuTTY\plink.exe' -ssh -batch -pw $pwd "root@$h" $c } }
```

---

## nested ESXi clone 修復

```sh
esxcli network nic list | grep vmnic0                 # 看 vmnic0 HW MAC
esxcli network ip interface list                      # 看 vmk0 MAC
esxcli network ip interface remove -i vmk0
esxcli network ip interface add -i vmk0 -p 'Management Network'   # 不帶 --mac-address = 自動唯一 MAC
# vmk0 IP 兩步
esxcli network ip interface ipv4 set -i vmk0 -t static -I $IP -N $MASK
esxcli network ip route ipv4 add --gateway $GW --network default
esxcli network ip interface ipv4 set -i vmk0 -t static -I $IP -N $MASK -g $GW
# 強制 GARP
esxcli network ip interface set -i vmk0 --enabled=false; sleep 3; esxcli network ip interface set -i vmk0 --enabled=true

sed -i 's|005056a58fa9|005056a58f0N|' /etc/vmware/esx.conf   # /system/uuid 去重
esxcli system uuid get
esxcli system hostname set --fqdn=kosten-vcf91-esx0N.rtolab.local
/sbin/generate-certificates ; /etc/init.d/hostd restart ; /etc/init.d/rhttpproxy restart
/sbin/auto-backup.sh                                  # 持久化（只能 SSH，GuestOps 會 Operation not permitted）
```

Layer 1 vSAN/LSOM 6 settings（驗證值 `0,0,1,0,1,1`）：
```sh
esxcli system settings advanced set -o /LSOM/VSANDeviceMonitoring       -i 0
esxcli system settings advanced set -o /LSOM/lsomSlowDeviceUnmount      -i 0
esxcli system settings advanced set -o /VSAN/SwapThickProvisionDisabled -i 1
esxcli system settings advanced set -o /VSAN/Vsan2ZdomCompZstd          -i 0
esxcli system settings advanced set -o /VSAN/FakeSCSIReservations       -i 1
esxcli system settings advanced set -o /VSAN/GuestUnmap                 -i 1
```

---

## 網路 / swsec（外層 vCenter）

```powershell
$pg = Get-VDPortgroup -Name 'trunk'
Get-VDSecurityPolicy -VDPortgroup $pg | Format-List AllowPromiscuous,MacChanges,ForgedTransmits
# flush swsec stale
Get-VDSecurityPolicy -VDPortgroup $pg | Set-VDSecurityPolicy -AllowPromiscuous $false
Get-VDSecurityPolicy -VDPortgroup $pg | Set-VDSecurityPolicy -AllowPromiscuous $true

# inner vCenter network rollback off（每次重部要重設）
$si=Get-View ServiceInstance; $m=Get-View $si.Content.Setting
$o=New-Object VMware.Vim.OptionValue; $o.Key='config.vpxd.network.rollback'; $o.Value='false'
$m.UpdateOptions(@($o))
```

---

## vCenter 服務 / host

```bash
service-control --status
service-control --start --all                         # 硬斷恢復後補齊（15-30 分，不可取消）
service-control --stop --all && service-control --start --all   # 修 SPS START_PENDING / CSI 鏈
```
```powershell
# host NotResponding：直連 hostd 重啟 vpxa
Restart-VMHostService -HostService (Get-VMHostService -VMHost <h> | ? Key -eq 'vpxa')
# 硬 reset PSOD 的 nested host
Restart-VM 'vcf-m02-esxXX-91' -Confirm:$false
```

---

## supervisor / VCFA K8s

```bash
K="echo <pw> | sudo -S kubectl --kubeconfig=/etc/kubernetes/admin.conf"
eval $K get pods -A | awk '{print $4}'|sort|uniq -c        # 相位統計
eval $K get pods -A | grep -vE "Running|Completed"
eval $K get pods -n kube-system | grep -E "etcd|apiserver|kube-vip"
eval $K get pods -n prelude                                # VCFA app 層
eval $K get events -A --sort-by=.lastTimestamp | tail -20
uptime ; iostat -x 1 2                                     # load / write await

# etcd fsync（CP 節點）
curl -s http://127.0.0.1:2381/metrics | grep -E 'etcd_disk_wal_fsync_duration_seconds_(sum|count)'
crictl ps -a --name "etcd|kube-apiserver|kube-vip"

# kube-vip lease 補丁
sudo sed -i '/vip_leaseduration/{n;s/"15"/"120"/}; /vip_renewdeadline/{n;s/"10"/"100"/}; /vip_retryperiod/{n;s/"2"/"20"/}' /etc/kubernetes/manifests/kube-vip.yaml

# CSI globalmount 死掛載清理
for m in $(mount | grep csi.vsphere.vmware.com | grep globalmount | awk '{print $3}'); do
  timeout 5 stat "$m" >/dev/null 2>&1 || { echo wedged:$m; echo <pw> | sudo -S umount -f -l "$m"; }
done

# 殭屍 VM（host 端）
esxcli vm process list ; esxcli vm process kill -t hard -w <wid>
vim-cmd vmsvc/power.on <vmid>
```

---

## VCF Installer / SDDC Manager REST

```powershell
# token
$tok = (Invoke-RestMethod -Method POST "https://192.168.114.5/v1/tokens" `
  -Body (@{username='admin@local';password='<pw>'}|ConvertTo-Json) `
  -ContentType 'application/json' -SkipCertificateCheck).accessToken
$hdr = @{Authorization="Bearer $tok"; 'Content-Type'='application/json'}

# 狀態
Invoke-RestMethod "https://192.168.114.5/v1/sddcs/$id" -Headers $hdr -SkipCertificateCheck   # 看 sddcSubTasks

# bundle 下載（VSP/Fleet）
Invoke-RestMethod "https://<sddc>/v1/bundles/$id" -Method PATCH -Headers $hdr `
  -Body (@{bundleDownloadSpec=@{downloadNow=$true}}|ConvertTo-Json) -SkipCertificateCheck

# 送 bringup（validator WARNING 別當失敗）
Invoke-RestMethod -Method POST "https://192.168.114.5/v1/sddcs" -Headers $hdr `
  -Body (Get-Content -Raw generated-bringup.json) -SkipCertificateCheck

# retry/resume（override pool + skipValidations）
$spec = Invoke-RestMethod "https://192.168.114.5/v1/sddcs/$id/spec" -Headers $hdr -SkipCertificateCheck
$spec.vspClusterSpec | Add-Member fleetFqdn '<...>-fleet.rtolab.local' -Force
Invoke-RestMethod -Method PATCH "https://192.168.114.5/v1/sddcs/$id?skipValidations=true" `
  -Headers $hdr -Body ($spec|ConvertTo-Json -Depth 50) -SkipCertificateCheck
```

domainmanager timeout（兩台都改，改完 `systemctl restart domainmanager`）：
```
# /etc/vmware/vcf/domainmanager/application.properties
nsxt.manager.wait.minutes=1800
edge.node.vm.creation.max.wait.minutes=900
vsp.bootstrap.task.timeout.minutes=2400
vsp.bootstrap.command.timeout.minutes=2000
nsxt.alb.image.upload.retry.check.interval.seconds=900
vc.appliance.services.check.timeout.minutes=2400
orchestrator.task.retry.max=5
```

---

## domainmanager log（找 Fleet LCM / VCFA task）

```bash
F=/var/log/vmware/vcf/domainmanager/domainmanager.log
grep -aiE 'fleet|prelude|vcfa|automation' $F | tail -30
# 找 svc-sddclcm-vc（RequestCanceled 來源）/ HttpNfcLease / GetVcfAutomationVmNames
```
> ⚠️ domainmanager.log 有單行數十 KB 的 JSON，grep 要收斂否則炸輸出。
