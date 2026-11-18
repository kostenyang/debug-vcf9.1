#!/usr/bin/env bash
# Apply / revert KB 314607 on the m08 SDDC Manager (lab only):
#   validation.disable.vmotion.connectivity.check=true in /etc/vmware/vcf/domainmanager/application.properties
#   + systemctl restart domainmanager.  Used to check whether it changes the import precheck
#   'Cluster common datastore check' (primary-data-store-pre-import-validator, runs in operationsmanager).
# usage: bash kb314607-m08.sh show|apply|revert
set -u
ACT=${1:-show}
PW=${LABPASS:?set LABPASS (SDDC Manager vcf + root password)}
F=/etc/vmware/vcf/domainmanager/application.properties
KEY=validation.disable.vmotion.connectivity.check
case "$ACT" in
  show)   CMD="grep -n '$KEY' $F; systemctl is-active domainmanager" ;;
  apply)  CMD="cp -n $F $F.bak-kb314607; sed -i '/^$KEY=/d' $F; echo '$KEY=true' >> $F; grep -n '$KEY' $F; systemctl restart domainmanager; sleep 5; systemctl is-active domainmanager" ;;
  revert) CMD="sed -i 's/^$KEY=true/$KEY=false/' $F; grep -n '$KEY' $F; systemctl restart domainmanager; sleep 5; systemctl is-active domainmanager" ;;
  *) echo "usage: $0 show|apply|revert"; exit 1 ;;
esac
(sleep 3; echo "$PW"; sleep 2; echo "$CMD; exit"; sleep 20; echo exit) |
  timeout 120 plink -batch -t -ssh vcf@10.0.1.147 -pw "$PW" 'su -' 2>&1 | grep -v -i -E 'keyboard|^\s*$|Password:' | sed 's/\x1b\[[0-9;]*m//g'
