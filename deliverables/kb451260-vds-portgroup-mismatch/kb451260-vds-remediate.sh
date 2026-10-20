#!/bin/bash
# =============================================================================
# kb451260-vds-remediate.sh
#
# Broadcom KB 451260 — "VCF Cluster Expansion fails with error: PortGroup
# configuration mismatch detected for VDS [...] in cluster ..."
#
# Runs ON the SDDC Manager appliance (as vcf or root) and talks to the local
# SDDC Manager API (https://localhost):
#
#   1. find the cluster (GET /v1/clusters)
#   2. CHECK  : run the same async expansion pre-validation the UI runs
#               (POST /v1/clusters/{id}/validations?useAsyncValidation=true)
#               with a placeholder host, and report the result of
#               "Validate Network Infrastructure State for Cluster operations"
#   3. BACKUP : save the SDDC inventory VDS / port group view (API JSON;
#               plus the platform DB vds rows when run as root)
#   4. FIX    : POST /v1/clusters/{id}/remediations
#               {"name":"SDDC_NETWORKING_DATA_REMEDIATION"}
#               and poll GET /v1/clusters/{id}/remediations/{remediationId}
#   5. RE-CHECK the network infrastructure state
#
# Default mode is --check (read-only). Nothing is changed unless --remediate
# is given (and confirmed, or --yes).
#
# Usage:
#   bash kb451260-vds-remediate.sh --list
#   bash kb451260-vds-remediate.sh -c <cluster name|id>                # check only
#   bash kb451260-vds-remediate.sh -c <cluster name|id> --remediate    # fix
#
# Options:
#   -c, --cluster NAME|ID   target cluster (name or UUID)
#   -l, --list              list clusters and exit
#   -u, --user USER         SSO user for /v1/tokens (default administrator@vsphere.local)
#                           password: env SDDC_PASSWORD, otherwise prompted
#       --remediate         run the remediation API after the check
#       --force             remediate even if the check passes
#   -y, --yes               do not ask for confirmation
#       --skip-check        do not run the pre-validation (remediate directly)
#       --host-id UUID      host id used in the pre-validation spec
#                           (default: a non-existent placeholder; the last check
#                           "Validate Cluster Expansion Specification" then fails
#                           with "ESXi Host ... not found" — that is expected)
#       --out DIR           where to write backups/logs (default /tmp/kb451260-<ts>)
#       --timeout SEC       polling timeout per async job (default 900)
#   -h, --help
#
# Exit codes: 0 = network state OK (or fixed), 1 = usage/API error,
#             2 = mismatch still present, 3 = remediation FAILED
# =============================================================================
set -o pipefail

API=https://localhost
SSO_USER=administrator@vsphere.local
CLUSTER=""
MODE=check
FORCE=0
YES=0
SKIP_CHECK=0
LIST=0
HOST_ID=00000000-0000-0000-0000-000000451260
TIMEOUT=900
OUT=/tmp/kb451260-$(date +%Y%m%d-%H%M%S)
NET_CHECK_DESC="Validate Network Infrastructure State"

usage() { sed -n '3,/^# =\{20,\}/p' "$0" | sed '$d; s/^# \{0,1\}//'; }
log()   { printf '%s  %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$OUT/run.log" >&2; }
die()   { log "ERROR: $*"; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    -c|--cluster)  CLUSTER=$2; shift ;;
    -l|--list)     LIST=1 ;;
    -u|--user)     SSO_USER=$2; shift ;;
    --remediate)   MODE=remediate ;;
    --check)       MODE=check ;;
    --force)       FORCE=1 ;;
    -y|--yes)      YES=1 ;;
    --skip-check)  SKIP_CHECK=1 ;;
    --host-id)     HOST_ID=$2; shift ;;
    --out)         OUT=$2; shift ;;
    --timeout)     TIMEOUT=$2; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 1 ;;
  esac
  shift
done

command -v jq   >/dev/null || { echo "jq not found" >&2; exit 1; }
command -v curl >/dev/null || { echo "curl not found" >&2; exit 1; }
mkdir -p "$OUT" || exit 1
chmod 700 "$OUT"

# ---------------------------------------------------------------- API helpers
TOKEN=""
get_token() {
  local pw=${SDDC_PASSWORD:-}
  if [ -z "$pw" ]; then
    read -r -s -p "Password for $SSO_USER: " pw </dev/tty; echo >&2
  fi
  TOKEN=$(jq -nc --arg u "$SSO_USER" --arg p "$pw" '{username:$u,password:$p}' |
          curl -sk -X POST "$API/v1/tokens" -H 'Content-Type: application/json' --data-binary @- |
          jq -r '.accessToken // empty')
  [ -n "$TOKEN" ] || die "cannot get API token for $SSO_USER (wrong password, or SDDC Manager services not up)"
}

# api METHOD PATH [BODY]  -> sets $RESP (body) and $HTTP (status) in the current shell
HTTP=""; RESP=""
api() {
  local m=$1 p=$2 b=$3 tmp
  tmp=$(mktemp -p "$OUT" .resp.XXXXXX)
  if [ -n "$b" ]; then
    HTTP=$(curl -sk -o "$tmp" -w '%{http_code}' -X "$m" "$API$p" \
           -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' --data-binary "$b")
  else
    HTTP=$(curl -sk -o "$tmp" -w '%{http_code}' -X "$m" "$API$p" -H "Authorization: Bearer $TOKEN")
  fi
  RESP=$(cat "$tmp"); rm -f "$tmp"
}

api_ok() { case "$HTTP" in 2??) return 0 ;; *) return 1 ;; esac; }
api_err() { jq -r '"\(.errorCode // "") \(.message // .)"' 2>/dev/null <<<"$1" || echo "$1"; }

# ------------------------------------------------------------- cluster lookup
list_clusters() {
  api GET /v1/clusters; api_ok || die "GET /v1/clusters -> HTTP $HTTP: $(api_err "$RESP")"
  echo "$RESP" | jq -r '.elements[] | [.id, .name, (.hosts|length|tostring)+" hosts", .domain.id] | @tsv' |
    awk -F'\t' 'BEGIN{printf "%-38s %-30s %-9s %s\n","CLUSTER ID","NAME","HOSTS","DOMAIN ID"}{printf "%-38s %-30s %-9s %s\n",$1,$2,$3,$4}'
}

resolve_cluster() {
  api GET /v1/clusters; api_ok || die "GET /v1/clusters -> HTTP $HTTP: $(api_err "$RESP")"
  local hit
  hit=$(echo "$RESP" | jq -c --arg c "$CLUSTER" '[.elements[] | select(.id==$c or .name==$c)]')
  case $(echo "$hit" | jq length) in
    1) CID=$(echo "$hit" | jq -r '.[0].id'); CNAME=$(echo "$hit" | jq -r '.[0].name') ;;
    0) die "cluster '$CLUSTER' not found (use --list)" ;;
    *) die "cluster name '$CLUSTER' is ambiguous, use the cluster id" ;;
  esac
}

# ------------------------------------------------------------- inventory dump
dump_inventory() {   # $1 = tag (before/after)
  local tag=$1 r
  api GET "/v1/clusters/$CID/vdses"; r=$RESP
  if api_ok; then
    echo "$r" > "$OUT/vdses-$tag.json"
    log "SDDC inventory VDS/port groups ($tag):"
    echo "$r" | jq -r '.[] | "  VDS \(.name)  mtu=\(.mtu) nsx=\(.isUsedByNsxt)",
                         (.portGroups[]? | "    - \(.transportType|tostring|.[0:14]) \t\(.name)\tvlan=\(.vlanId)\tactive=\(.activeUplinks|join(","))")' |
      tee -a "$OUT/run.log" >&2
  else
    log "WARN: GET /v1/clusters/$CID/vdses -> HTTP $HTTP: $(api_err "$r")"
  fi
  # platform DB rows (root only) — this is what the remediation rewrites
  if [ "$(id -u)" = 0 ] && command -v psql >/dev/null; then
    psql -h localhost -U postgres -d platform -At -c \
      "select row_to_json(v) from vds v where v.id in (select vds_id from cluster_and_vds where cluster_id='$CID')" \
      > "$OUT/db-vds-$tag.json" 2>>"$OUT/run.log" &&
    log "platform DB vds rows saved: $OUT/db-vds-$tag.json" &&
    jq -r '"  DB vds \(.id) source_id=\(.source_id)  pg=" + ((.port_groups|fromjson)|map("\(.transportType):\(.sourceId)")|join(" "))' \
      "$OUT/db-vds-$tag.json" 2>/dev/null | tee -a "$OUT/run.log" >&2
  fi
}

# ------------------------------------------------- network state pre-validation
# Prints PASS / FAIL / UNKNOWN on stdout, details to the log.
run_check() {   # $1 = tag
  local tag=$1 vds body r vid st s
  api GET "/v1/clusters/$CID/vdses"; vds=$(jq -r '.[0].name // empty' <<<"$RESP" 2>/dev/null)
  if [ -z "$vds" ]; then
    api GET "/v1/clusters/$CID/network-details"; vds=$(jq -r '.vdsSpecs[0].name // empty' <<<"$RESP" 2>/dev/null)
  fi
  body=$(jq -nc --arg h "$HOST_ID" --arg v "$vds" '{clusterExpansionSpec:{
            deployWithoutLicenseKeys:true, interRackExpansion:false,
            hostSpecs:[{id:$h, hostNetworkSpec:{vmNics:[{id:"vmnic0",vdsName:$v,uplink:"uplink1"},
                                                       {id:"vmnic1",vdsName:$v,uplink:"uplink2"}]}}]}}')
  log "pre-validation ($tag): POST /v1/clusters/$CID/validations?useAsyncValidation=true"
  api POST "/v1/clusters/$CID/validations?useAsyncValidation=true" "$body"; r=$RESP
  api_ok || { log "WARN: validation request -> HTTP $HTTP: $(api_err "$r")"; echo UNKNOWN; return; }
  vid=$(echo "$r" | jq -r .id)
  local end=$((SECONDS + TIMEOUT))
  while :; do
    api GET "/v1/clusters/$CID/validations/$vid?useAsyncValidation=true"; s=$RESP
    st=$(jq -r '.executionStatus // empty' <<<"$s" 2>/dev/null)
    [ "$st" != IN_PROGRESS ] && break
    [ $SECONDS -ge $end ] && { log "WARN: validation $vid still IN_PROGRESS after ${TIMEOUT}s"; echo UNKNOWN; return; }
    sleep 5
  done
  echo "$s" > "$OUT/validation-$tag.json"
  echo "$s" | jq -r '.validationChecks[]? | "  [\(.resultStatus)] \(.description)" +
                     (if .errorResponse then "\n      error : \(.errorResponse.message)\n      remedy: \(.errorResponse.remediationMessage // "-")" else "" end)' |
    tee -a "$OUT/run.log" >&2
  local net
  net=$(echo "$s" | jq -r --arg d "$NET_CHECK_DESC" '[.validationChecks[]? | select(.description|startswith($d))][0].resultStatus // empty')
  case "$net" in
    SUCCEEDED) echo PASS ;;
    FAILED)    echo FAIL ;;
    *)         log "WARN: network infrastructure check did not run (an earlier check failed?) - see $OUT/validation-$tag.json"; echo UNKNOWN ;;
  esac
}

# ---------------------------------------------------------------- remediation
run_remediation() {
  local r rid st s
  log "POST /v1/clusters/$CID/remediations {\"name\":\"SDDC_NETWORKING_DATA_REMEDIATION\"}"
  api POST "/v1/clusters/$CID/remediations" '{"name":"SDDC_NETWORKING_DATA_REMEDIATION"}'; r=$RESP
  echo "$r" > "$OUT/remediation-start.json"
  api_ok || die "remediation request -> HTTP $HTTP: $(api_err "$r")"
  rid=$(echo "$r" | jq -r '.id // empty')
  [ -n "$rid" ] || die "remediation request returned no id: $r"
  log "remediationId=$rid status=$(echo "$r" | jq -r .status)"
  local end=$((SECONDS + TIMEOUT))
  while :; do
    api GET "/v1/clusters/$CID/remediations/$rid"; s=$RESP
    st=$(jq -r '.status // empty' <<<"$s" 2>/dev/null)
    [ "$st" != IN_PROGRESS ] && break
    [ $SECONDS -ge $end ] && die "remediation $rid still IN_PROGRESS after ${TIMEOUT}s"
    sleep 5
  done
  echo "$s" > "$OUT/remediation-result.json"
  log "remediation $rid -> $st"
  if [ "$st" != COMPLETED ]; then
    log "error: $(echo "$s" | jq -c '{errorCode,errorResponse}')"
    log "details: /var/log/vmware/vcf/domainmanager/domainmanager.log (grep -i remediat)"
    exit 3
  fi
}

# ======================================================================= main
get_token
if [ $LIST = 1 ] || [ -z "$CLUSTER" ]; then
  list_clusters
  [ -z "$CLUSTER" ] && [ $LIST = 0 ] && echo "(use -c <cluster> to check a cluster)" >&2
  exit 0
fi

resolve_cluster
log "KB451260  cluster=$CNAME ($CID)  mode=$MODE  out=$OUT"
dump_inventory before

RESULT=UNKNOWN
if [ $SKIP_CHECK = 0 ]; then
  RESULT=$(run_check before)
  log "network infrastructure state (before): $RESULT"
fi

if [ "$MODE" = check ]; then
  case $RESULT in
    PASS) log "OK - SDDC inventory matches vCenter for cluster $CNAME"; exit 0 ;;
    FAIL) log "MISMATCH - rerun with --remediate to sync the SDDC inventory from vCenter"; exit 2 ;;
    *)    exit 1 ;;
  esac
fi

if [ "$RESULT" = PASS ] && [ $FORCE = 0 ]; then
  log "network state already OK - nothing to remediate (use --force to run anyway)"
  exit 0
fi

if [ $YES = 0 ]; then
  read -r -p "Run SDDC_NETWORKING_DATA_REMEDIATION on cluster $CNAME now? [y/N] " a </dev/tty
  [[ $a =~ ^[Yy]$ ]] || { log "aborted by user"; exit 1; }
fi

run_remediation
dump_inventory after
# Port group summary per VDS / traffic type (full diffs are kept in $OUT/*.diff).
# Note: the remediation rewrites the whole VDS record from vCenter, so NIOC
# shares, VDS name and NSX switch mode may change too - see the .diff files.
pg_view() { jq -r '.[] | .name as $v | .portGroups[]? | "\($v)|\(.transportType)|\(.name)|vlan=\(.vlanId)"' "$1" | sort; }
db_view() { jq -r '.source_id as $v | (.port_groups|fromjson)[] | "\($v)|\(.transportType)|\(.sourceId)"' "$1" | sort; }
if [ -f "$OUT/vdses-before.json" ] && [ -f "$OUT/vdses-after.json" ]; then
  diff <(jq -S . "$OUT/vdses-before.json") <(jq -S . "$OUT/vdses-after.json") > "$OUT/vdses.diff"
  if diff -q <(pg_view "$OUT/vdses-before.json") <(pg_view "$OUT/vdses-after.json") >/dev/null; then
    log "port groups in SDDC inventory (API view): unchanged"
  else
    log "port groups in SDDC inventory (API view)  VDS|traffic|portgroup:"
    diff <(pg_view "$OUT/vdses-before.json") <(pg_view "$OUT/vdses-after.json") |
      sed -n 's/^< /    before: /p; s/^> /    after : /p' | tee -a "$OUT/run.log" >&2
  fi
fi
if [ -f "$OUT/db-vds-before.json" ] && [ -f "$OUT/db-vds-after.json" ]; then
  diff <(jq -S '.port_groups|=fromjson' "$OUT/db-vds-before.json") \
       <(jq -S '.port_groups|=fromjson' "$OUT/db-vds-after.json") > "$OUT/db-vds.diff"
  if ! diff -q <(db_view "$OUT/db-vds-before.json") <(db_view "$OUT/db-vds-after.json") >/dev/null; then
    log "port group morefs in platform DB  dvs|traffic|moref:"
    diff <(db_view "$OUT/db-vds-before.json") <(db_view "$OUT/db-vds-after.json") |
      sed -n 's/^< /    before: /p; s/^> /    after : /p' | tee -a "$OUT/run.log" >&2
  fi
  log "full before/after diffs: $OUT/vdses.diff $OUT/db-vds.diff"
fi

if [ $SKIP_CHECK = 0 ]; then
  RESULT=$(run_check after)
  log "network infrastructure state (after): $RESULT"
  [ "$RESULT" = PASS ] || { log "mismatch still present - check domainmanager.log"; exit 2; }
fi
log "done - retry the cluster expansion. Logs/backups: $OUT"
exit 0
