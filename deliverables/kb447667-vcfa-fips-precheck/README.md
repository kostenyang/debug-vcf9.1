# KB 447667 — VCF Automation 升級 FIPS precheck 失敗（含「跳過 vCenter 檢查」）

> Broadcom KB：<https://knowledge.broadcom.com/external/article/447667>（KB 最後更新 2026-08-10）
> 相關 KB：446198（9.x 來源：skip configmap、補 PEM 憑證）、445623（端點加入時沒驗憑證）、454371（重試時 FIPS 與 IP pool / VIP 衝突一起報）
>
> 本篇 = KB 重點 + 客戶現場的處理順序 + KB 沒寫到的坑。
> 🔴 **「跳過 vsphere（vCenter）檢查」KB 沒有寫**。lab 只驗證了檔案的放法，**沒有實跑 precheck 確認真的會跳過**。

---

## 1. 症狀

升級到 VCF Automation 9.x 時，precheck 擋下：

```
Precheck failed: com.broadcom.vcfa.upgrade.90.application.check.test-application-01-9x-fips
One or more configured endpoints or integrations are not accessible in FIPS mode.
```

| 來源版本 | 失敗的 check | log 位置 |
|---|---|---|
| VCF Automation 9.x | `test-application-01-9x-fips` | 來源系統的 `/tmp/vcfa-upgrade/logs/fipschecker.log`、`/tmp/vcfa-upgrade/logs/fips-checks-failed` |
| Aria Automation 8.18.x | `test-application-02-8x-fips.sh` | vRA 節點的 `/var/log/vmware/prelude/` |

9.x 會對每個外部整合端點做 FIPS 140-2 檢查（要走有憑證的安全通道）。舊版 vRA / Aria Automation 建的整合常常不符合。

## 2. 什麼時候會跑（vRA 8 import 到 VCFMS 9 的情境）

| 階段 | 會不會跑 FIPS 檢查 |
|---|---|
| VCF Operations 裡 **Import**（把 vRA 8 註冊成 VCF Automation 元件） | 不會（lab 實測 import 約 5 分鐘就完成） |
| 之後按 **Upgrade → precheck** | **會**。這時在 vRA 節點上跑 `02-8x-fips`，並讀取下面 §5 的白名單 |

所以白名單檔案要在「按下 Upgrade precheck 的那一刻」還在。

## 3. 先看 log，再決定修還是跳

```bash
# 9.x 來源
cat  /tmp/vcfa-upgrade/logs/fips-checks-failed
less /tmp/vcfa-upgrade/logs/fipschecker.log

# 8.18 來源（vRA 節點）
ls -lt /var/log/vmware/prelude/ | head -20
grep -ril fips /var/log/vmware/prelude/ 2>/dev/null
```

判讀：

| log 裡看到 | 意思 |
|---|---|
| `certificate_unknown(46)`、`CertPathBuilderException: Unable to find certificate chain` | 端點憑證沒存下來，或缺 CA 鏈（KB 445623）→ 修憑證（§4） |
| 連線逾時 / connection refused | 端點本身連不到，例如 cloud account 指向已退役或關機的 vCenter |

## 4. 根因與修法（優先修，不要一開始就跳）

| 端點類型 | 常見原因 | 修法 |
|---|---|---|
| IPAM | integration 開了略過憑證檢查（Infoblox 是 `Infoblox.IPAM.DisableCertificateCheck`） | Infrastructure → Integrations → 編輯該 IPAM → 關掉略過憑證 → 跳出憑證時按接受 → Save |
| AD / LDAP | 用 `ldap://`（389） | Identity & Access Management → Directories → 改成 `ldaps://`（636）並提供 LDAP 的 CA 憑證；先確認 appliance 打得通 636 |
| vROps | 預設的憑證存法讓 precheck 讀不到 | KB 447667：只能跳過。KB 446198（9.x 來源）：補一張 PEM 憑證就能過 |
| vCenter（`vsphere`） | cloud account 憑證沒存 / 缺鏈，或 vCenter 連不到 | Cloud Accounts → 該 vCenter → **VALIDATE → ACCEPT 憑證 → SAVE**；vCenter 已退役就先決定這個 cloud account 怎麼處理 |

> lab 實測（2026-10-07）：vCenter cloud account 用 VALIDATE → ACCEPT → ADD 加入時，憑證會存進 provisioning DB，升級 precheck 一次就過，升級後 cloud account 也正常。

## 5. 真的要跳過：dropin 白名單

白名單列的是「**要檢查**的端點類型」：一行、單引號、逗號分隔。**拿掉哪個，就不檢查哪個。** 完整清單：

```
'vsphere','nsxt','activedirectory','org.bitbucket','com.github.saas','com.gitlab.saas','ipam','vro','vrops'
```

| 名稱 | 對應 vRA 裡的 |
|---|---|
| `'vsphere'` | **vCenter cloud account** |
| `'nsxt'` | NSX-T cloud account |
| `'activedirectory'` | AD / LDAP 目錄整合 |
| `'org.bitbucket'` | Bitbucket 整合 |
| `'com.github.saas'` | GitHub 整合 |
| `'com.gitlab.saas'` | GitLab 整合 |
| `'ipam'` | IPAM 整合（例如 Infoblox） |
| `'vro'` | vRO（Orchestrator）整合 |
| `'vrops'` | vROps / Aria Operations 整合 |

### 5.1 8.18 來源（**每一台** vRA 節點都要做）

例：跳過 vCenter（拿掉 `'vsphere'`）

```bash
mkdir -p /var/run/dropins
echo "'nsxt','activedirectory','org.bitbucket','com.github.saas','com.gitlab.saas','ipam','vro','vrops'" > /var/run/dropins/vra_fips_precheck_endpoints.list
cat -A /var/run/dropins/vra_fips_precheck_endpoints.list   # 應該只有一行，結尾是 $（LF，不是 ^M$）
```

KB 的範例是跳過 vROps：完整清單拿掉 `'vrops'`。IPAM、AD 修不好時也可以用同樣方式拿掉。

### 5.2 9.x 來源（在來源系統上，就是有 `/tmp/vcfa-upgrade/logs` 的那台）

```bash
mkdir -p /tmp/vcfa-upgrade/dropins
echo "'nsxt','activedirectory','org.bitbucket','com.github.saas','com.gitlab.saas','ipam','vro','vrops'" > /tmp/vcfa-upgrade/dropins/vcfa9_fips_precheck_endpoints.list
cat -A /tmp/vcfa-upgrade/dropins/vcfa9_fips_precheck_endpoints.list
```

### 5.3 9.x 另一招：skip configmap（KB 446198）

這招會跳過**整個 precheck ID**，不是只跳某一類端點。

```bash
kubectl -n prelude create configmap vcfa-precheck-skip-config \
  --from-literal=skip-config.json='{"precheckIds":["com.broadcom.vcfa.upgrade.90.application.check.test-application-01-9x-fips"],"reason":"<填原因>"}'
```

- **24 小時有效**，逾時要刪掉重建。
- 升級完要刪：`kubectl -n prelude delete configmap vcfa-precheck-skip-config`
- 上面的指令是依 KB 446198 的欄位整理的，執行前請對照 KB 原文。

## 6. 🔴 KB 沒寫到的坑

1. **跳過 `vsphere` 沒有官方文件。** 機制跟跳 vROps 一樣，但 KB 只列出 vROps / IPAM / AD 可以這樣跳。正式環境請先開 SR 跟 GSS 確認。
2. **`/var/run` 就是 `/run`，是 tmpfs，節點重開機檔案就會消失。** import 完到升級之間只要重開過就要重建；開跑前先 `cat` 確認檔案還在。（lab vRA 8.18.1 實測）
3. **跳過的只是 precheck。** 升級後執行階段仍會強制 FIPS；端點不合格的話，升完一樣會斷。升完要回頭把端點修好。
4. **vRA VM 必須在該 VCF instance 管理網域的 vCenter 裡。** 不在的話，Upgrade precheck 的 `import_vcfa` 步驟會用 govc 到該 vCenter 查來源 VM 的 network MoRef，查不到就 exit 1。UI 只顯示 `Internal error occurred` / `Step import_vcfa failed`，真因要在 VSP 叢集上 `kubectl -n prelude logs <vcfa-import-80-entrypoint-…> --all-containers` 才看得到。**這不是 FIPS 檢查，白名單跳不過**，要先把 VM 搬進管理網域 vCenter。
5. **重試時 FIPS 跟 IP pool / VIP 衝突一起報**（KB 454371）→ 先清掉上一輪殘留的 VMSP 節點、處理 vCO 的 pending task，再重跑。
6. 轉成 9.x 之後如果還要從 9.x 升到 9.1.x，白名單位置就換成 §5.2 的 `/tmp/vcfa-upgrade/dropins/...`，8.18 那份不會再用到。

## 7. 客戶現場處理順序

1. **看 log**（§3），確認是哪個端點、哪一種錯。
2. **能修就修**（§4），修完重跑 precheck。
3. **修不了才跳**（§5）。正式環境先跟 GSS 確認，特別是跳 `vsphere`。
4. **確認 vRA VM 在管理網域 vCenter 裡**（§6 第 4 點），不然跳了 FIPS 也會卡在 `import_vcfa`。
5. **升完收尾**：把跳過的端點修好；用了 configmap 的話要刪掉。

---

## 來源 / 實證

- KB 447667（2026-08-10 版）、KB 446198、KB 445623、KB 454371。
- 2026-11-03：在 lab 的 vRA 8.18.1 單節點建好 §5.1 的檔案，確認 `/var/run` → `/run` 是 tmpfs。**沒有實跑 precheck**。
- 2026-10-07：vRA 8.18.1（在管理網域內）import → 升級 VCF Automation 9.1.1，vCenter 端點的 precheck 一次就過（憑證有存）。
- 2026-09-08：管理網域外的 vRA import 成功，但升級 precheck 卡在 `import_vcfa`。
