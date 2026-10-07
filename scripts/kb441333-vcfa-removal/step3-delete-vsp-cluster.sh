#!/bin/bash
# ③ 刪 VCFA services runtime —— 必須以 root 在 SDDC Manager 上執行
#   用法(vcf 帳號下):
#     ROOTPW='<root 密碼>' python3 asroot.py 'LABPW="<密碼>" bash /home/vcf/step3-delete-vsp-cluster.sh <vsp-cluster-id>'
set -e
ID="${1:?給 vsp-cluster id}"
cd /home/vcf
echo "whoami: $(whoami)   time: $(date '+%Y-%m-%d %H:%M:%S')"
time python3 -u cleanup_component.py delete vsp-cluster \
  -c "$ID" \
  -ff vcf-m03-fleet01.home.lab \
  -vsrf vcf-m03-vsp01.home.lab -vsru admin -vsrp "$LABPW" \
  -vu administrator@vsphere.local -vp "$LABPW" \
  -fd
