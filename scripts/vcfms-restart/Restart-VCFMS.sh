#!/usr/bin/env bash
# Restart-VCFMS.sh — VCF Services Runtime(VCFMS / VSP 叢集)優雅重開機
#
# 依據(2026-10-06 查證):
#   KB 440874  How to safely shutdown all nodes within a VCF Services Runtime Cluster
#              → vcf_services_runtime_shutdown.sh(已放 E:\9.1\)做協調式 drain
#   techdocs   Shut Down / Start VCF Management Services(9.1 fleet-management shutdown & startup)
#              → 開機順序:control node 先、全部起來後再開 worker;worker 約需 20 分鐘
#   KB 440862  叢集開機後不自動恢復(節點留在 Ready,SchedulingDisabled / power-off-marker)
#              → control 先、等 5 分、再 worker;等 15-20 分;還不行跑 cluster-manual-recovery.sh
#   KB 448334  drain 600s 逾時留下 stalled system-shutdown task → 節點不 uncordon
#              → 本 lab 一律 TASK_TIMEOUT_SECONDS=2400(nested 慢,2026-06-18 踩過)
#
# 流程:
#   0) 由 vCenter 名稱 regex 動態解析 VSP VM(重建後 moref 會變,不寫死)
#      control node = vCPU 最少那台(techdocs:control nodes are the VMs with less CPU and memory)
#   1) KB 440874 drain(--skip-poweroff;VM 我們自己關,避開 git bash jq CRLF 的 base64 bug)
#   2) guest shutdown:worker 先 → control 最後;等 150s 驗證,仍 ON 的硬關
#   3) power on:control 先 → 等 300s → worker
#   4) 等叢集恢復:SSH control node 看 kubectl get nodes 全 Ready 且無 SchedulingDisabled、
#      power-off-marker 消失、非 Running/Completed pod 歸零;上限 WAIT_MAX 秒(預設 1800)
#   5) 超時仍 SchedulingDisabled → 印 KB 440862 手動步驟;若 E:\9.1\cluster-manual-recovery.sh 存在
#      且 AUTO_RECOVER=1 則自動上傳執行
#
# 環境變數:
#   TEST=1          dry-run(官方腳本 --dry-run、不關不開任何 VM、不等待)
#   SKIP_DRAIN=1    跳過 KB drain(只做 VM 層 reboot;不建議,只在 drain 端點壞掉時用)
#   AUTO_RECOVER=1  超時後自動跑 cluster-manual-recovery.sh(需先自 KB 440862 下載到 E:\9.1\)
#   VM_RE           VSP VM 名稱 regex(預設 vsp01;會排除 template)
#   WAIT_MAX        步驟 4 最長等待秒數(預設 1800)
#   VC / VCUSER / VCPW / VSPPW  覆寫連線資訊
#
# 用法:
#   export PATH=/e/9.1/tools:$PATH
#   TEST=1 bash /e/9.1/tools/Restart-VCFMS.sh     # 先 dry-run
#   bash /e/9.1/tools/Restart-VCFMS.sh            # 正式
export PATH="/e/9.1/tools:$PATH" MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
LOG=/e/9.1/tools/restart-vcfms.log
log(){ echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }

VC="${VC:-vcf-m02-vc01.home.lab}"
VCUSER="${VCUSER:-administrator@vsphere.local}"; VCPW="${VCPW:?請先 export VCPW=<vCenter 密碼>}"
VSPUSER=vmware-system-user; VSPPW="${VSPPW:?請先 export VSPPW=<vmware-system-user 密碼>}"
VM_RE="${VM_RE:-vsp01}"
KBSCRIPT="${KBSCRIPT:-/e/9.1/vcf_services_runtime_shutdown.sh}"  # KB 440874 附件,自行從 Broadcom KB 下載
RECOVER=/e/9.1/cluster-manual-recovery.sh
PLINK="/c/Program Files/PuTTY/plink.exe"; PSCP="/c/Program Files/PuTTY/pscp.exe"
TEST="${TEST:-0}"; SKIP_DRAIN="${SKIP_DRAIN:-0}"; AUTO_RECOVER="${AUTO_RECOVER:-0}"; WAIT_MAX="${WAIT_MAX:-1800}"

# ---------- vCenter REST helpers ----------
vctok(){ curl -sk -m 20 -u "$VCUSER:$VCPW" -X POST "https://$VC/api/session" 2>/dev/null | tr -d '"'; }
vmlist(){ curl -sk -m 20 -H "vmware-api-session-id: $1" "https://$VC/api/vcenter/vm" 2>/dev/null; }
vmstate(){ curl -sk -m 20 -H "vmware-api-session-id: $1" "https://$VC/api/vcenter/vm/$2/power" 2>/dev/null | jq -r '.state // "UNKNOWN"'; }
vmcpu(){ curl -sk -m 20 -H "vmware-api-session-id: $1" "https://$VC/api/vcenter/vm/$2" 2>/dev/null | jq -r '.cpu.count // 0'; }
vmips(){ curl -sk -m 20 -H "vmware-api-session-id: $1" "https://$VC/api/vcenter/vm/$2/guest/networking/interfaces" 2>/dev/null \
         | jq -r '.[]?.ip?.ip_addresses[]? | select(.ip_address|test("^10\\.")) | .ip_address' 2>/dev/null | sort -u; }
vmpower(){ # $1=tok $2=vm $3=guest-shutdown|stop|start
  case "$3" in
    guest-shutdown) curl -sk -m 30 -o /dev/null -w '%{http_code}' -X POST -H "vmware-api-session-id: $1" "https://$VC/api/vcenter/vm/$2/guest/power?action=shutdown";;
    *)              curl -sk -m 60 -o /dev/null -w '%{http_code}' -X POST -H "vmware-api-session-id: $1" "https://$VC/api/vcenter/vm/$2/power?action=$3";;
  esac; }
port_open(){ timeout 4 bash -c "</dev/tcp/$1/$2" 2>/dev/null; }

# ---------- SSH helper (plink, host key 每次重建會變 → 動態釘) ----------
hostkey_of(){ echo y | timeout 25 "$PLINK" -ssh -batch -pw "$VSPPW" "$VSPUSER@$1" true 2>&1 | grep -oE 'SHA256:[A-Za-z0-9+/=]+' | head -1; }
ssh_run(){ # $1=ip $2=cmd (以 root 執行,sudo 無 passwordless → -S 餵密碼)
  local hk; hk=$(hostkey_of "$1"); [ -z "$hk" ] && return 1
  timeout 120 "$PLINK" -ssh -batch -hostkey "$hk" -pw "$VSPPW" "$VSPUSER@$1" \
    "echo '$VSPPW' | sudo -S -p '' bash -c 'export KUBECONFIG=/etc/kubernetes/admin.conf; $2'" 2>&1 \
    | grep -v -e 'Keyboard-interactive' -e 'End of keyboard'; }

log "================ Restart-VCFMS 開始 (TEST=$TEST SKIP_DRAIN=$SKIP_DRAIN) ================"

# ---------- 0) 解析 VSP VM ----------
TOK=$(vctok); [ -z "$TOK" ] && { log "🔴 vCenter $VC 登入失敗/不通 → 中止"; exit 1; }
LIST=$(vmlist "$TOK")
mapfile -t VMS < <(echo "$LIST" | jq -r --arg re "$VM_RE" '.[] | select(.name|test($re)) | select(.name|test("template")|not) | .vm')
[ "${#VMS[@]}" -eq 0 ] && { log "🔴 名稱 /$VM_RE/ 解析不到任何 VM → 中止"; exit 1; }

declare -A NAME CPU IPS
CP=""; CPMIN=999999; WORKERS=()
for vm in "${VMS[@]}"; do
  NAME[$vm]=$(echo "$LIST" | jq -r --arg id "$vm" '.[] | select(.vm==$id) | .name')
  CPU[$vm]=$(vmcpu "$TOK" "$vm")
  IPS[$vm]=$(vmips "$TOK" "$vm" | tr '\n' ' ')
  log "  $vm  ${NAME[$vm]}  vCPU=${CPU[$vm]}  ip=[${IPS[$vm]}]  state=$(vmstate "$TOK" "$vm")"
  if [ "${CPU[$vm]}" -lt "$CPMIN" ]; then CPMIN=${CPU[$vm]}; CP=$vm; fi
done
for vm in "${VMS[@]}"; do [ "$vm" != "$CP" ] && WORKERS+=("$vm"); done
log "control node = $CP (${NAME[$CP]}, vCPU=$CPMIN) ; workers = ${WORKERS[*]:-<none>}"
# 若多台 vCPU 同為最小值(HA 部署 3 CP)此法只挑到一台;本 lab 是 Simple 部署(1 CP),夠用。
SAME=$(for vm in "${VMS[@]}"; do echo "${CPU[$vm]}"; done | grep -c "^$CPMIN$")
[ "$SAME" -gt 1 ] && log "⚠ 有 $SAME 台 vCPU 相同,control node 判定可能不準,請人工確認"

# control node IP:先挑 5480 開的、再挑 22 開的
CPIP=""; for ip in ${IPS[$CP]}; do port_open "$ip" 5480 && { CPIP=$ip; break; }; done
[ -z "$CPIP" ] && for ip in ${IPS[$CP]}; do port_open "$ip" 22 && { CPIP=$ip; break; }; done
NODEIP="$CPIP"
[ -z "$NODEIP" ] && for vm in "${VMS[@]}"; do for ip in ${IPS[$vm]}; do port_open "$ip" 5480 && { NODEIP=$ip; break 2; }; done; done
log "control node IP = ${CPIP:-?} ; drain 用 --node-ip = ${NODEIP:-?}"

# ---------- 1) KB 440874 drain ----------
if [ "$SKIP_DRAIN" = "1" ]; then
  log "(SKIP_DRAIN=1,略過官方 drain)"
elif [ -z "$NODEIP" ]; then
  log "⚠ 沒有任何節點 5480 可達 → 無法 drain,改走 VM 層 reboot"
elif [ ! -f "$KBSCRIPT" ]; then
  log "⚠ 找不到 $KBSCRIPT(自 KB 440874 下載)→ 略過 drain"
else
  DRYARG=""; [ "$TEST" = "1" ] && DRYARG="--dry-run"
  log "跑 KB 440874 drain (TASK_TIMEOUT_SECONDS=2400 --skip-poweroff $DRYARG) ..."
  TASK_TIMEOUT_SECONDS=2400 VMSP_PASSWORD="$VSPPW" bash "$KBSCRIPT" --node-ip "$NODEIP" --password "$VSPPW" --skip-poweroff $DRYARG 2>&1 | tee -a "$LOG"
  rc=${PIPESTATUS[0]}
  [ "$rc" -ne 0 ] && log "⚠ 官方 drain 回 $rc(逾時/錯誤)。KB 448334:若留下 stalled system-shutdown task,開機後節點可能不 uncordon。仍續關 VM"
fi

# ---------- 2) 關 VM:worker 先 → control 最後 ----------
TOK=$(vctok)
for vm in "${WORKERS[@]}" "$CP"; do
  if [ "$TEST" = "1" ]; then log "[TEST] 會對 $vm (${NAME[$vm]}) 送 guest shutdown;現狀 $(vmstate "$TOK" "$vm")"; continue; fi
  log "$vm (${NAME[$vm]}) guest shutdown -> HTTP $(vmpower "$TOK" "$vm" guest-shutdown)"
  sleep 15
done
if [ "$TEST" != "1" ]; then
  log "等 150s 後驗證,仍 ON 的硬關(2026-06-18 教訓:guest shutdown 回 204 卻沒關)..."; sleep 150
  TOK=$(vctok)
  for vm in "${VMS[@]}"; do
    s=$(vmstate "$TOK" "$vm")
    if [ "$s" = "POWERED_ON" ]; then
      log "⚠ $vm (${NAME[$vm]}) 仍 ON → force stop HTTP $(vmpower "$TOK" "$vm" stop)"; sleep 5; log "  現在 $(vmstate "$TOK" "$vm")"
    else log "$vm (${NAME[$vm]}) = $s ✓"; fi
  done
fi

# ---------- 3) 開機:control 先 → 等 300s → worker ----------
if [ "$TEST" = "1" ]; then
  log "[TEST] 會先開 $CP (${NAME[$CP]}),等 300s,再開 ${WORKERS[*]};然後等叢集 Ready(上限 ${WAIT_MAX}s)"
  log "================ Restart-VCFMS dry-run 完成 ================"; exit 0
fi
TOK=$(vctok)
log "開 control $CP (${NAME[$CP]}) -> HTTP $(vmpower "$TOK" "$CP" start)"
log "等 300s 讓 control plane 起來(KB 440862:control 先、等 5 分鐘)..."; sleep 300
TOK=$(vctok)
for vm in "${WORKERS[@]}"; do log "開 worker $vm (${NAME[$vm]}) -> HTTP $(vmpower "$TOK" "$vm" start)"; sleep 10; done
TOK=$(vctok); for vm in "${VMS[@]}"; do log "  $vm (${NAME[$vm]}) = $(vmstate "$TOK" "$vm")"; done

# ---------- 4) 等叢集恢復 ----------
# control IP 開機後重新解析一次(guest info 要等 tools 回報)
sleep 60; TOK=$(vctok)
for i in $(seq 1 20); do IPS[$CP]=$(vmips "$TOK" "$CP" | tr '\n' ' '); [ -n "${IPS[$CP]// }" ] && break; sleep 15; done
CPIP=""; for ip in ${IPS[$CP]}; do port_open "$ip" 22 && { CPIP=$ip; break; }; done
log "control node IP(開機後)= ${CPIP:-?};開始等叢集 Ready(上限 ${WAIT_MAX}s,techdocs:worker 約 20 分鐘)"
t0=$(date +%s); OK=0; LASTNODES=""
while [ $(( $(date +%s) - t0 )) -lt "$WAIT_MAX" ]; do
  if [ -n "$CPIP" ]; then
    NODES=$(ssh_run "$CPIP" "kubectl get nodes --no-headers 2>/dev/null")
    if [ -n "$NODES" ]; then
      LASTNODES="$NODES"
      total=$(echo "$NODES" | grep -c .); ready=$(echo "$NODES" | awk '$2=="Ready"' | grep -c .)
      cord=$(echo "$NODES" | grep -c SchedulingDisabled)
      marker=$(ssh_run "$CPIP" "kubectl get configmap power-off-marker -n vmsp-platform --no-headers 2>/dev/null | grep -c power-off-marker")
      bad=$(ssh_run "$CPIP" "kubectl get pods -A --no-headers 2>/dev/null | grep -v -e Running -e Completed | grep -c .")
      marker=$(echo "$marker" | tr -dc '0-9'); bad=$(echo "$bad" | tr -dc '0-9')
      log "  nodes Ready $ready/$total, SchedulingDisabled=$cord, power-off-marker=${marker:-?}, non-Running/Completed pods=${bad:-?}"
      if [ "$ready" -eq "$total" ] && [ "$cord" -eq 0 ] && [ "${marker:-1}" = "0" ] && [ "${bad:-1}" = "0" ]; then OK=1; break; fi
    else
      log "  control node $CPIP SSH/kubectl 還沒回應..."
    fi
  else
    for ip in ${IPS[$CP]}; do port_open "$ip" 22 && { CPIP=$ip; break; }; done
    log "  等 control node SSH 可達..."
  fi
  sleep 60
done

VIP=$(curl -sk -m 10 -o /dev/null -w '%{http_code}' "https://vcf-m02-vsp01.home.lab/" 2>/dev/null)
log "VSP VIP https://vcf-m02-vsp01.home.lab/ -> HTTP ${VIP:-000}(404/200 皆算活,走 Host header 路由)"

if [ "$OK" = "1" ]; then
  log "✅ 叢集恢復:全節點 Ready、無 cordon、marker 清除、pod 全 Running/Completed。VCF Ops > Build > Lifecycle > VCF Management 應可載入"
else
  log "🔴 ${WAIT_MAX}s 內未完全恢復。最後 kubectl get nodes:"; echo "$LASTNODES" | tee -a "$LOG"
  log "   → KB 440862 手動復原:SSH $VSPUSER@${CPIP:-<control-ip>} ; sudo -i ; export KUBECONFIG=/etc/kubernetes/admin.conf"
  log "     kubectl get nodes ; kubectl get configmap power-off-marker -n vmsp-platform ; 跑 KB 附件 cluster-manual-recovery.sh"
  log "   → 若節點 Ready,SchedulingDisabled 且有 stalled system-shutdown task(KB 448334):先刪該 task 再 kubectl uncordon <node>"
  if [ "$AUTO_RECOVER" = "1" ] && [ -f "$RECOVER" ] && [ -n "$CPIP" ]; then
    hk=$(hostkey_of "$CPIP")
    log "AUTO_RECOVER=1:上傳並執行 cluster-manual-recovery.sh ..."
    "$PSCP" -batch -hostkey "$hk" -pw "$VSPPW" "$RECOVER" "$VSPUSER@$CPIP:/tmp/cluster-manual-recovery.sh" 2>&1 | tee -a "$LOG"
    ssh_run "$CPIP" "chmod +x /tmp/cluster-manual-recovery.sh && /tmp/cluster-manual-recovery.sh" | tee -a "$LOG"
    ssh_run "$CPIP" "kubectl get nodes; kubectl get pods -A | grep -v -e Running -e Completed" | tee -a "$LOG"
  elif [ "$AUTO_RECOVER" = "1" ]; then
    log "   AUTO_RECOVER=1 但找不到 $RECOVER(請自 KB 440862 下載)或 control IP 未知,略過"
  fi
fi
log "================ Restart-VCFMS 完成 (OK=$OK) ================"
[ "$OK" = "1" ]
