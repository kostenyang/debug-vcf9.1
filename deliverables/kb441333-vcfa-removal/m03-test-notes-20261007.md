# KB 441333 — VCF Automation 正常移除 step-by-step(m03,2026-10-07)

## 環境
| 角色 | FQDN | IP |
|---|---|---|
| SDDC Manager(執行腳本的地方) | vcf-m03-sddcm01.home.lab | 10.0.1.65 |
| Fleet | vcf-m03-fleet01.home.lab | 10.0.1.67 |
| VCF services runtime(管理 VSP) | vcf-m03-vsp01.home.lab | VIP .69,節點 .82/.83/.84 |
| VCFA services runtime | vcf-m03-auto-platform.home.lab | VIP .73,節點 .98 |
| VCFA console | vcf-m03-auto-vip.home.lab | .72 |
| vCenter | vcf-m03-vc01.home.lab | 10.0.1.60 |

部署:greenfield VCF 9.1.1 含 VCFA,sddcId 70b06d65(COMPLETED_WITH_SUCCESS)
狀態:VCFA 可登入(admin / provider),未啟用 Supervisor

## 步驟與證據(cli/ 與 shots/)
- [x] 0 移除前狀態(Fleet 10 元件 / 11 VM / VCFA 200)
- [x] 1 腳本傳到 SDDC Manager(sha256 一致)
- [x] 2 驗 VSP 帳號 —— 只認 admin,administrator@vsphere.local 兩個 VSP 都 401
- [x] 3 list —— 多出 VCD_MIGRATOR(= Migration service engine)
- [x] 4 ① delete vsp-component VCFA 12f80ada —— 23m03s
- [x] 5 ② delete vsp-component Migration service engine 9c064f80 —— 12m02s
- [x] 6 root(pty su)
- [x] 7 ③ delete vsp-cluster 4fde9186(root)—— 3m10s,VM vm-43 刪除 + DB 清
- [x] 8 移除後驗證 —— Fleet 9 元件、VCFA 000、10.0.1.98 消失、Identity broker 正常
- [ ] 9 docx

## 關鍵發現
1. 🔑 變成**三步**(上次 m02 兩步):VCFA → Migration service engine → runtime
2. 🔴 Step ① 進行中 list 看不到 VCD_MIGRATOR ≠ 已刪;Step ② 還是在 Fleet 找到並刪了
3. 9.1.1 版本 → should_skip_infra_deletion=False → 真的刪 VM(m02 帳面 8.0.0 只清帳面)
4. 腳本不檢查 runtime 上還有沒有元件 → 順序要自己顧
5. ssh 跑 python 沒 TTY 會緩衝 → python3 -u;本機管線的 grep 也要 --line-buffered
6. Windows ping「Destination host unreachable」會算 Received → 用 Test-Connection 判讀
7. DNS 記錄不會被刪(vcf-m03-auto-vip / auto-platform 還在)
