#!/usr/bin/env bash
# guardrail-importance.sh — run ON the SDDC Manager (9.1.1) as root:  ssh vcf@<sddc-manager>; su -
#
# Downgrades / restores the VCF import precheck "Cluster common datastore check."
# (validator primary-data-store-pre-import-validator) between CRITICAL (default) and WARNING by
# adding / removing  "validationImportanceLevel": "WARNING"  in the validator's extraArgs of the
# on-disk guardrail. Same key VMware already uses in the remove-cluster / remove-host guardrails.
#
#   show    print the validator block and whether the key is present (read-only)
#   apply   back up the original (once) to /root, add the key, validate JSON, restore file mode
#   revert  remove the key; report whether the file is byte-identical to the backup
#
# NOT an officially supported change. Use only after confirming the datastore itself is fine,
# and revert right after the import. No service restart is needed (lab-verified on 9.1.1.0).
set -euo pipefail
F=/opt/vmware/vcf/operationsmanager/scripts/assessment/guardrails/common/targetstates/esx-upgrade-shared.json
BAK=/root/esx-upgrade-shared.json.orig
ACT=${1:-show}

[ "$(id -u)" -eq 0 ] || { echo "ERROR: run as root (su -)"; exit 1; }
[ -f "$F" ] || { echo "ERROR: not found: $F"; exit 1; }

edit() {
python3 - "$F" "$1" <<'PY'
import json, sys
f, act = sys.argv[1], sys.argv[2]
s = open(f).read()
i = s.index('"id": "primary-data-store-pre-import-validator"')
end = s.index('"dependencies"', i)
anchor = '"existingDatastoreName": "${existingDatastoreName}"'
add = ',\n        "validationImportanceLevel": "WARNING"'
has = 'validationImportanceLevel' in s[i:end]
if act == 'apply' and not has:
    k = s.index(anchor, i)
    if k > end:
        sys.exit('ERROR: extraArgs anchor not found inside the validator block - edit by hand')
    k += len(anchor)
    s = s[:k] + add + s[k:]
elif act == 'revert' and has:
    s = s[:i] + s[i:end].replace(add, '', 1) + s[end:]
json.loads(s)                      # never write invalid JSON
if act in ('apply', 'revert'):
    open(f, 'w').write(s)
print('validationImportanceLevel present:', 'validationImportanceLevel' in s[i:s.index('"dependencies"', i)])
PY
}

case "$ACT" in
  show)
    ls -la "$F"
    grep -n -A10 '"id": "primary-data-store-pre-import-validator"' "$F"
    edit show
    ;;
  apply)
    MODE=$(stat -c '%a' "$F")
    [ -f "$BAK" ] || { cp -p "$F" "$BAK"; echo "backup: $BAK"; }
    chmod u+w "$F"
    edit apply
    chmod "$MODE" "$F"
    grep -n -A10 '"id": "primary-data-store-pre-import-validator"' "$F"
    echo "Done. Re-run the import Prechecks (BACK -> NEXT); the check now reports WARNING."
    ;;
  revert)
    MODE=$(stat -c '%a' "$F")
    chmod u+w "$F"
    edit revert
    chmod "$MODE" "$F"
    if [ -f "$BAK" ]; then
      if cmp -s "$F" "$BAK"; then echo "IDENTICAL to $BAK"; else echo "WARNING: differs from $BAK (restore with: cp -p $BAK $F)"; fi
    fi
    ;;
  *) echo "usage: $0 show|apply|revert"; exit 1 ;;
esac
