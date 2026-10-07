#!/usr/bin/env bash
# KB-Shutdown-VCFA-VSP.sh — 照 KB 的關機 wrapper
# 順序(官方)：VCFA 先 → VCF Services Runtime 官方 drain(KB 440874) → 關 VSP 4 節點 VM
# 環境變數 TEST=1 → dry-run（官方腳本 --dry-run、不真的關 VM），用來驗證排程呼叫機制。
#
# 2026-07-19 改：VM ID 不再寫死（VM 重建後 moref 會變，舊版寫死 vm-92 已失效）。
#             改用名稱 pattern 經 vCenter API 動態解析 → auto-platform / vsp01。
export PATH="/e/9.1/tools:$PATH"
LOG=/e/9.1/tools/kb-shutdown.log
log(){ echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }

VC=vcf-m02-vc01.home.lab
VCUSER='administrator@vsphere.local'; VCPW="${VCPW:?請先 export VCPW=<vCenter 密碼>}"
KBSCRIPT="${KBSCRIPT:-/e/9.1/vcf_services_runtime_shutdown.sh}"  # KB 440874 附件,自行從 Broadcom KB 下載
TEST="${TEST:-0}"

vctok(){ curl -sk -u "$VCUSER:$VCPW" -X POST "https://$VC/api/session" 2>/dev/null | tr -d '"'; }
vmstate(){ curl -sk -H "vmware-api-session-id: $1" "https://$VC/api/vcenter/vm/$2/power" 2>/dev/null | grep -oE '"state":"[^"]*"'; }
# 用名稱 regex 動態解析 VM moref（可回多個，一行一個）。$1=token $2=name-regex
vmids_by_name(){ curl -sk -H "vmware-api-session-id: $1" "https://$VC/api/vcenter/vm" 2>/dev/null | jq -r --arg re "$2" '.[] | select(.name|test($re)) | .vm'; }
vmname(){ curl -sk -H "vmware-api-session-id: $1" "https://$VC/api/vcenter/vm" 2>/dev/null | jq -r --arg id "$2" '.[] | select(.vm==$id) | .name'; }

log "================ KB Shutdown 開始 (TEST=$TEST) ================"

TOK=$(vctok)
# 動態解析 VM ID（VCFA×1、VSP×N）
VCFA_VMS=$(vmids_by_name "$TOK" 'auto-platform')
VSP_VMS=$(vmids_by_name "$TOK" 'vsp01')
log "解析到 VCFA = [$(echo $VCFA_VMS)] ; VSP = [$(echo $VSP_VMS)]"
if [ -z "$VCFA_VMS" ] && [ -z "$VSP_VMS" ]; then
  log "⚠ 名稱解析不到任何 VM（vCenter 不通或名稱變更）→ 中止"; exit 1
fi

# 1) VCFA (auto-platform) 先優雅關
if [ -z "$VCFA_VMS" ]; then
  log "（找不到 auto-platform，略過 VCFA 步驟）"
else
  for vm in $VCFA_VMS; do
    if [ "$TEST" = "1" ]; then
      log "[TEST] 會對 $vm (VCFA $(vmname "$TOK" $vm)) 送 guest shutdown；現狀: $(vmstate "$TOK" $vm)"
    else
      log "VCFA $vm ($(vmname "$TOK" $vm)) guest shutdown..."
      curl -sk -X POST -H "vmware-api-session-id: $TOK" "https://$VC/api/vcenter/vm/$vm/guest/power?action=shutdown" -w " -> HTTP %{http_code}" 2>/dev/null | tee -a "$LOG"; echo "" | tee -a "$LOG"
    fi
  done
  [ "$TEST" = "1" ] || { log "等 VCFA 關機 180s..."; sleep 180; }
fi

# 2) 官方 KB drain (VCF Services Runtime) — --skip-poweroff(避開 base64 bug；VM 我們自己關)
# TASK_TIMEOUT_SECONDS=2400：nested lab drain 慢，預設 600s 會逾時(2026-06-18 踩過)
log "跑官方 KB 腳本 drain (TASK_TIMEOUT_SECONDS=2400) ..."
if [ "$TEST" = "1" ]; then
  TASK_TIMEOUT_SECONDS=2400 VMSP_PASSWORD="$VCPW" bash "$KBSCRIPT" --node-ip 10.0.0.222 --password "$VCPW" --skip-poweroff --dry-run 2>&1 | tee -a "$LOG"
else
  TASK_TIMEOUT_SECONDS=2400 VMSP_PASSWORD="$VCPW" bash "$KBSCRIPT" --node-ip 10.0.0.222 --password "$VCPW" --skip-poweroff 2>&1 | tee -a "$LOG" || log "⚠ 官方 drain 回非 0(逾時/錯誤)，仍續關 VM"
fi

# 3) 關 VSP 節點 VM（動態解析的每一台）
TOK=$(vctok)
for vm in $VSP_VMS; do
  if [ "$TEST" = "1" ]; then
    log "[TEST] 會對 $vm (VSP $(vmname "$TOK" $vm)) 送 guest shutdown；現狀: $(vmstate "$TOK" $vm)"
  else
    log "VSP $vm ($(vmname "$TOK" $vm)) guest shutdown..."
    curl -sk -X POST -H "vmware-api-session-id: $TOK" "https://$VC/api/vcenter/vm/$vm/guest/power?action=shutdown" -w " -> HTTP %{http_code}" 2>/dev/null | tee -a "$LOG"; echo "" | tee -a "$LOG"
    sleep 15
  fi
done

# 4) 驗證 + 硬關殘留(2026-06-18 vm-35 guest shutdown 回 204 卻沒關 → 一定要驗證+補硬關)
if [ "$TEST" != "1" ]; then
  log "等 150s 後驗證電源狀態，仍 ON 的硬關..."; sleep 150
  TOK=$(vctok)
  for vm in $VCFA_VMS $VSP_VMS; do
    s=$(vmstate "$TOK" $vm)
    if echo "$s" | grep -q POWERED_ON; then
      log "⚠ $vm ($(vmname "$TOK" $vm)) 仍 ON → 硬關 (force stop)"
      curl -sk -X POST -H "vmware-api-session-id: $TOK" "https://$VC/api/vcenter/vm/$vm/power?action=stop" -w " -> hard stop HTTP %{http_code}" 2>/dev/null | tee -a "$LOG"; echo "" | tee -a "$LOG"
      sleep 5; log "  $vm 現: $(vmstate "$TOK" $vm)"
    else
      log "$vm = $s ✓"
    fi
  done
fi
log "================ KB Shutdown 完成 (TEST=$TEST) ================"
