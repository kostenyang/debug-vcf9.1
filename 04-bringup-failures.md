# 04 — Bringup 失敗對症修法

> VCF 9.1 nested bringup 在 vcf-m02 跑通的硬傷，依 bringup 流程順序。每項都是「不做就會卡」。先看失敗的 **task 名稱**對症。

---

## 0. 排錯順序（一句話總結）

1. Fix-CloneNetwork 別綁 vmk0 MAC（篇章 01）
2. 4 台 nested 釘同一外層 host + toggle trunk PG promisc reset swsec（篇章 02）
3. inner vCenter `network.rollback=false`（篇章 02）
4. **VSP/Fleet bundle 先下載到 SUCCESSFUL**（§2）
5. SDDC Manager 套 **VSP timeout properties + restart domainmanager**（§3）
6. 關 HA admission control + FTT=0 + nested ESXi reservation（§4）
7. spec 帶 **fleetFqdn**（§1）
8. PATCH retry bringup（§5）

---

## 1. `Save VCF Management Components` 失敗 → 缺 fleetFqdn

**症狀**：milestone `Deploy and configure VCF Management Platform` 失敗於 task `Save VCF Management Components`：
```
FAILED_TO_SAVE_OR_UPDATE_VCF_MGMT_COMPONENTS
500 on PATCH /v1/system/vcf-management-components → INVENTORY_INTERNAL_SERVER_ERROR
```
此時 vC/SDDC/NSX/cluster 都部完了，但 Operations/Automation/Mgmt Services 全 NOT_STARTED。

**根因**：spec 沒填 `vspClusterSpec.fleetFqdn` → Installer 把 `fleetLcm` 翻成 `fqdn=null` → SDDC Manager DB（`vcf_management_component.fqdn` NOT NULL）insert 失敗。
SDDC Manager `vcf-commonsvcs.log`：
```
ERROR: null value in column "fqdn" of relation "vcf_management_component" violates not-null constraint
  Detail: Failing row contains (FLEET_LCM, null, NEW, NOT_STARTED).
```

**修法（事前預防）**：spec 的 `vspClusterSpec` 加 `fleetFqdn`（並在 DNS 加 A record）：
```json
"vspClusterSpec": {
  "instanceFqdn": "<...>-vsp.example.com",
  "platformFqdn": "<...>-vspp.example.com",
  "fleetFqdn":    "<...>-fleet.example.com",   // 必填（primary VCF instance / VVF）
  ...
}
```
> Secondary VCF instance **不要**帶 fleetFqdn。VCF 9.0 schema 沒有獨立 fleetLcm，不受影響。

**修法（事後 retry）**：① DNS 加 fleet FQDN A record → ② PATCH `/v1/system/vcf-management-components` 補 `fleetLcm.fqdn` → ③ `GET /v1/sddcs/{id}/spec` 取回 spec、`Add-Member fleetFqdn` → `PATCH /v1/sddcs/{id}`（指令見 [reference/commands.md](reference/commands.md)）。retry 後 task 應變 `POSTVALIDATION_COMPLETED_WITH_SUCCESS`。

---

## 2. VSP bootstrap 失敗 → bundle 沒下載

**症狀**：`Bootstrap VCF Services Platform` → `PUBLIC_VSP_CLUSTER_BOOTSTRAP_FAILED` / `java.lang.StringIndexOutOfBoundsException: Range [-1, 0)` @ `VspServiceImpl.getBootstrapTask`。

**根因**：VSP + VCF_FLEET_LCM bundle 在 SDDC Manager catalog 是 `downloadStatus=PENDING`（從未下載）→ `getBootstrapTask` 找不到 bundle 的 ova/cliArchive 路徑 → 對空字串 substring → 爆。

**修法**：bootstrap 前先觸發 4 個 bundle 下載（2×VSP + 2×Fleet），等到 `downloadStatus=SUCCESSFUL`：
```powershell
$b = Invoke-RestMethod "https://<sddc>/v1/bundles" -Headers $hdr -SkipCertificateCheck
# 對每個 VSP/Fleet bundle id PATCH downloadNow
$body = @{ bundleDownloadSpec = @{ downloadNow = $true } } | ConvertTo-Json
Invoke-RestMethod "https://<sddc>/v1/bundles/$id" -Method PATCH -Headers $hdr -Body $body -SkipCertificateCheck
```
下載完 `getBootstrapTask` 會印 `Found VSP deliverables: {ova, cliArchive}`，bug 消失。

---

## 3. Timeout tuning（慢速 lab 必做，送 bringup 前）

SSH 進 SDDC Manager（與 VCF Installer 兩台皆改）→ 編 `/etc/vmware/vcf/domainmanager/application.properties`（owner `vcf_domainmanager:vcf`、權限 600）→ 改完 `systemctl restart domainmanager.service`：

```
nsxt.manager.wait.minutes=1800
edge.node.vm.creation.max.wait.minutes=900
vsp.bootstrap.task.timeout.minutes=2400
vsp.bootstrap.command.timeout.minutes=2000
nsxt.alb.image.upload.retry.check.interval.seconds=900
vc.appliance.services.check.timeout.minutes=2400
orchestrator.task.retry.max=5
```
（上面是 code 預設 ×10 的最終值。VCF 沒有單一通用 OVA deploy timeout；`vc.appliance.services.check.timeout.minutes` 最接近「appliance 部署後等待」。）

> ⚠️ 取 root 跑指令的技巧（pty + su）見篇章 00 §2。改檔記得先備份、可回退。
> 來源：William Lam — *VCF 9.1 Comprehensive VCF Installer & SDDC Manager Configuration Workarounds*。

---

## 4. VSP 部署的資源條件

VSP/VSPP appliance（4 vCPU / 10GB）無法 power on、DRS migration loop 時：
- inner vCenter cluster **關 HA Admission Control**（否則保留容量擋 VSPP placement）：`ClusterDasConfigInfo.AdmissionControlEnabled=$false`。
- inner vSAN **Default Storage Policy FTT=0**（省一半空間；也緩解 etcd fsync）。
- nested ESXi 給 **CPU/Mem reservation**（etcd 對延遲敏感）：每台 8GHz + 48GB 熱套（ReconfigVM，免 reboot）。

---

## 5. Retry / Resume（卡關優先用原生機制，少手動）

**重點：domainmanager 重啟不會自動續跑失敗的 task，retry 必須明確觸發。**

- **UI Retry（最穩）**：VCF Installer UI 按 Retry，從失敗點續跑、不重做 validation。
- **API retry**：`GET /v1/sddcs/{id}/spec` → `PATCH /v1/sddcs/{id}`（Broadcom KB 424770）。
  - 但 lab 中 raw PATCH 常撞 `QUICK_START_VALIDATION_FAILED`（IP pool 已被佔用）。
  - **解法**：override spec 的 pool 成「真的空」的 IP + `PATCH /v1/sddcs/{id}?skipValidations=true` → idempotent resume。（2026-06-29 rebuild 就是這樣過關：VSP 佔了 `vspClusterSpec.ipv4Pool` 12 個裡的 6 個 → 換 12 個全空 IP + skipValidations。）
- **包裝腳本**：`scripts/_retry_bringup.ps1 -Id <sddc-id>`。每次 retry 前先 flush trunk-PG swsec（篇章 02）。
- ⚠️ `retryTask` / `/v1/tasks` 只涵蓋 download task，**不涵蓋 bringup**。
- ⚠️ poll wrapper（`Submit-Bringup.ps1`）會在 ~1h 後因 **JWT 過期**死掉（沒 refresh token）—— **無害，bringup 在 server 端繼續**，改用每次重新 auth 的 poller 監控（這個 build `completionPercent` 是 null，用 `sddcSubTasks` 計數）。

---

## 6. Lab-mode skip checks（VCF 9.1）

`-LabMode` 自動注入（production 用 `-SkipLabMode` 不注入）：
`NESTED_CPU_CHECK`、`NIC_COUNT_CHECK`、`MIN_HOST_CHECK`、`VSAN_ESA_HCL_CHECK`、`ESX_THUMBPRINT_CHECK`。

validator 回 `WARNING`（vSAN 容量 / time sync / boot disk <32GB / cores<110）是 **nested lab 正常現象，不是 FAILED**。`Submit-Bringup.ps1` 會把 WARNING 當失敗 throw → 直接 `POST /v1/sddcs` 即可（指令見 reference）。

---

## 7. 完整 Option B spec 別漏元件

base spec ≠ full Option B。產 spec 後一定要跑 `_add_auto_ops_spec.ps1` 加 **Automation + Ops + Collector + License + vIDB**：
```powershell
pwsh -Command "& 'Generate-BringupSpec.ps1' -LabMode"
pwsh -Command "& '_add_auto_ops_spec.ps1'"
```

---

## 8. 重送 bringup 撞 `ALREADY_EXISTS` → 換 sddcId

重送會撞既有記錄。**改 spec 的 `sddcId`**（例 `vcf-m02` → `vcf-m02b`）即可。（2026-06-17 用 `vcf-m02` 即使 installer DB 有 25 筆舊記錄也沒撞 ALREADY_EXISTS，但若撞就換 id。）

---

## 9. Domain `.local` 的隱憂（未證實）

VMware "Bridging the .Local Gap"（2026-04）指 VCF 9.1 的 vIDB/Automation/Supervisor 對 `.local` TLD 有 guardrail。rtolab 用 `rtolab.local`，MGMT 層都過，VSP 階段才卡 —— 但實測根因是 bundle PENDING（§2）。若 §1~§4 都做了 VSP 仍失敗，再考慮改 domain 為 `.net/.lab/.internal` 重建。

---

來源：rtolab `layer2-bringup/nested-bringup-fixes.md`、`save-vcf-mgmt-components-fix.md`、`layer3-postbringup/vcf-operations-automation-deploy-troubleshooting.md`、`timeout-tuning.md`、lab-info `runbooks/bringup.md`、`golden-ova.md`。Broadcom KB 424770、William Lam VCF 9.1 workarounds。
