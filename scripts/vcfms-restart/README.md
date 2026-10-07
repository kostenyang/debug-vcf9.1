# VCFMS（VSP 叢集）優雅重開機 + KB 440874 / 440862 / 448334

| 檔案 | 說明 |
|---|---|
| `Restart-VCFMS.sh` | 優雅重開整個 VCFMS（VSP 叢集）：KB 440874 drain（`--skip-poweroff`、`TASK_TIMEOUT_SECONDS=2400`）→ 先關 worker、最後關 control → 先開 control、等 300 秒再開 worker → 用 plink 進 control node 輪詢，直到 `kubectl get nodes` 全部 Ready、`power-off-marker` 消失、沒有非 Running/Completed 的 pod（上限 `WAIT_MAX=1800`）。⚠ **尚未實機跑過**，請先用 `TEST=1` 做 dry-run。 |
| `KB-Shutdown-VCFA-VSP.sh` | 舊版（2026-06）VCFA+VSP 關機 wrapper，`--node-ip 10.0.0.222` 寫死在裡面；VCFA 已移除，留著備查。 |

## 執行前準備

```bash
export VCPW='<vCenter administrator@vsphere.local 密碼>'
export VSPPW='<VSP vmware-system-user 密碼>'
export KBSCRIPT=/path/to/vcf_services_runtime_shutdown.sh   # 預設 /e/9.1/vcf_services_runtime_shutdown.sh
TEST=1 bash Restart-VCFMS.sh
```

- `vcf_services_runtime_shutdown.sh` 是 **KB 440874** 的附件（Broadcom Confidential），**不放在這個 repo**，請自行從 KB 下載。
- 選項：`SKIP_DRAIN=1` 跳過 drain；`AUTO_RECOVER=1` 自動跑 KB 440862 的附件 `cluster-manual-recovery.sh`（同樣要自行下載）。
- 執行環境：Windows git bash，PuTTY plink/pscp 裝在預設路徑。

## 相關 KB 規則

- **KB 440874**：drain 腳本的 `--node-ip` 填任一台可連線節點的 5480 位址；先跑 `--dry-run`。
- **開機順序**（techdocs「Start VCF Management Services」）：control node（vCPU/記憶體較少的那台）先開，等它起來再開 worker；worker 大約要 20 分鐘。
- **KB 440862**：開機 20 分鐘後 UI 還不通時，SSH 進 control node 檢查：
  - `kubectl get nodes` 是否有 `Ready,SchedulingDisabled`
  - `kubectl get configmap power-off-marker -n vmsp-platform` 是否還在

  有的話跑附件 `cluster-manual-recovery.sh`。最後 `kubectl get pods -A | grep -v "Completed\|Running"` 應該沒有輸出。
- **KB 448334**：drain 超過 600 秒逾時，會留下卡住的 `system-shutdown` task，節點就永遠不會 uncordon；要先刪掉 task 再 `kubectl uncordon`。這支腳本把逾時設成 2400 秒，就是為了避開這個問題。
