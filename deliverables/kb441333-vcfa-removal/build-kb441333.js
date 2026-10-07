// KB 441333 — VCF Automation 正常移除 Step-by-Step(實測 VCF 9.1.1)
//   node build-kb441333.js
const fs = require('fs');
const path = require('path');
const {
  Document, Packer, Paragraph, TextRun, HeadingLevel, AlignmentType,
  Table, TableRow, TableCell, WidthType, ShadingType, ImageRun, PageBreak, BorderStyle
} = require('docx');

const BASE  = 'E:/9.1/kb441333';
const SHOTS = BASE + '/shots';
const CLI   = BASE + '/cli';
const DIAG  = BASE + '/diagrams';
const OUT   = 'E:/9.1/KB441333-VCF-Automation-正常移除-StepByStep.docx';

const C = { blue: '1F4E79', gray: '595959', red: 'C00000', green: '2E7D32', amber: 'B77E00' };
const W_UI = 600, W_DIAG = 640;

const H1 = t => new Paragraph({ text: t, heading: HeadingLevel.HEADING_1, spacing: { before: 340, after: 160 } });
const H2 = t => new Paragraph({ text: t, heading: HeadingLevel.HEADING_2, spacing: { before: 260, after: 120 } });
const P = (t, o = {}) => new Paragraph({
  children: [new TextRun({ text: t, size: o.size || 21, bold: o.bold, color: o.color, italics: o.italics })],
  spacing: { after: o.after != null ? o.after : 110 }, alignment: o.align });
const CODE = t => new Paragraph({
  children: String(t).split('\n').map((ln, i) => new TextRun({ text: ln, font: 'Consolas', size: 15, break: i ? 1 : 0 })),
  shading: { type: ShadingType.CLEAR, fill: 'F4F4F4' },
  spacing: { before: 70, after: 90 }, indent: { left: 200 } });
const BULLET = t => new Paragraph({ children: [new TextRun({ text: t, size: 21 })], bullet: { level: 0 }, spacing: { after: 60 } });
const NOTE = (t, fill, color) => new Paragraph({
  children: [new TextRun({ text: t, size: 20, color: color || C.gray })],
  shading: { type: ShadingType.CLEAR, fill: fill || 'FFF6E5' },
  spacing: { before: 90, after: 90 }, indent: { left: 120, right: 120 },
  border: { left: { style: BorderStyle.SINGLE, size: 18, color: color || C.amber } } });
const WARN = t => NOTE(t, 'FDEDED', C.red);
const GOOD = t => NOTE(t, 'EDF7EE', C.green);
const PB = () => new Paragraph({ children: [new PageBreak()] });

const TOTAL = 9000;
function table(headers, rows, pct) {
  const widths = pct.map(p => Math.round(TOTAL * p / 100));
  const hdr = new TableRow({ tableHeader: true, children: headers.map((h, i) => new TableCell({
    width: { size: widths[i], type: WidthType.DXA }, shading: { type: ShadingType.CLEAR, fill: C.blue },
    children: [new Paragraph({ children: [new TextRun({ text: h, bold: true, color: 'FFFFFF', size: 19 })] })] })) });
  const body = rows.map((r, ri) => new TableRow({ children: r.map((c, i) => new TableCell({
    width: { size: widths[i], type: WidthType.DXA },
    shading: ri % 2 ? { type: ShadingType.CLEAR, fill: 'F7F9FC' } : undefined,
    children: [new Paragraph({ children: [new TextRun({ text: String(c), size: 18 })] })] })) }));
  return new Table({ rows: [hdr].concat(body), columnWidths: widths, width: { size: TOTAL, type: WidthType.DXA } });
}
function pngSize(p) { const b = fs.readFileSync(p); return { w: b.readUInt32BE(16), h: b.readUInt32BE(20) }; }
let figNo = 0; const missing = [];
function fig(dir, file, caption, maxW) {
  const p = path.join(dir, file); const out = []; figNo++;
  if (fs.existsSync(p)) {
    const { w, h } = pngSize(p); const cw = maxW || W_UI; const ch = Math.round(cw * h / w);
    out.push(new Paragraph({ children: [new ImageRun({ type: 'png', data: fs.readFileSync(p), transformation: { width: cw, height: ch } })],
      alignment: AlignmentType.CENTER, spacing: { before: 140, after: 40 } }));
  } else {
    missing.push(file);
    out.push(new Paragraph({ children: [new TextRun({ text: '[ 缺圖:' + file + ' ]', italics: true, color: C.red, size: 18 })], alignment: AlignmentType.CENTER }));
  }
  out.push(new Paragraph({ children: [new TextRun({ text: '圖 ' + figNo + '\u3000' + caption, size: 18, color: C.gray })],
    alignment: AlignmentType.CENTER, spacing: { after: 180 } }));
  return out;
}
const F = (f, c, w) => fig(SHOTS, f, c, w);
const D = (f, c) => fig(DIAG, f, c, W_DIAG);

// 讀 CLI 證據檔:把連續的 "Task status: RUNNING" 收成一行,避免版面被洗掉
function cli(file, opt = {}) {
  const p = path.join(CLI, file);
  if (!fs.existsSync(p)) { missing.push(file); return '[缺:' + file + ']'; }
  let lines = fs.readFileSync(p, 'utf8').replace(/\r/g, '').split('\n')
    .filter(l => !/Keyboard-interactive|End of keyboard/.test(l));
  const out = []; let run = 0, first = null, last = null;
  const flush = () => {
    if (run === 0) return;
    if (run <= 2) { out.push(first); if (run === 2) out.push(last); }
    else { out.push(first); out.push(`    …(中間 ${run - 2} 次 RUNNING 省略)…`); out.push(last); }
    run = 0;
  };
  for (const l of lines) {
    if (/Task status: RUNNING/.test(l)) { if (run === 0) first = l; last = l; run++; continue; }
    flush(); out.push(l);
  }
  flush();
  let s = out.join('\n').trim();
  if (opt.wide) {
    const NL = String.fromCharCode(10);
    s = s.split(NL).map(l => {
      if (/^-{20,}$/.test(l.trim())) return '-'.repeat(96);            // 分隔線縮短
      if (l.includes(' | ')) return l.split('|').map(x => x.trim()).join(' | ');  // 欄位去掉補白
      return l;
    }).join(NL);
  }
  if (opt.from) { const i = s.indexOf(opt.from); if (i >= 0) s = s.slice(i); }
  if (opt.max) s = s.split('\n').slice(0, opt.max).join('\n');
  return s;
}

let body = [];
const add = (...x) => { x.forEach(e => Array.isArray(e) ? body.push(...e) : body.push(e)); };

// ============================ 封面 ============================
add(new Paragraph({ spacing: { before: 1800 } }),
  P('VMware Cloud Foundation 9.1.1 · KB 441333', { size: 28, color: C.gray, align: AlignmentType.CENTER }),
  new Paragraph({ children: [new TextRun({ text: 'VCF Automation 正常移除', size: 46, bold: true, color: C.blue })],
    alignment: AlignmentType.CENTER, spacing: { after: 120 } }),
  P('Step-by-Step 實作手冊', { size: 28, color: C.gray, align: AlignmentType.CENTER, after: 700 }),
  P('使用官方腳本 cleanup_component.py · 全程實測截圖與指令輸出', { size: 20, color: C.gray, align: AlignmentType.CENTER, after: 60 }),
  P('實測環境:home.lab 巢狀實驗室 · 2026-10-07', { size: 20, color: C.gray, align: AlignmentType.CENTER }),
  PB());

// ============================ 目錄 ============================
add(H1('目錄'), ...[
  '一、摘要', '二、三條指令各碰到哪裡(流程圖)', '三、環境與前提',
  '四、Step 0 — 移除前狀態', '五、Step 1 — 把腳本傳到 SDDC Manager', '六、Step 2 — 確認 VSP 認證帳號',
  '七、Step 3 — 列出要刪的元件 ID', '八、Step 4 — ① 刪除 VCF Automation 元件',
  '九、Step 5 — ② 刪除 Migration service engine 元件', '十、Step 6 — 在 SDDC Manager 取得 root',
  '十一、Step 7 — ③ 刪除 VCFA services runtime', '十二、Step 8 — 移除後驗證',
  '十三、注意事項與坑', '附錄 A:可直接複製的完整指令', '附錄 B:腳本參數一覽'
].map(t => P('　' + t, { after: 80 })), PB());

// ============================ 一、摘要 ============================
add(H1('一、摘要'));
add(P('KB 441333 提供官方腳本 cleanup_component.py,用來把 VCF Automation(VCFA)從 VCF fleet 中正常移除。本文在一套全新部署的 VCF 9.1.1(greenfield,含 VCFA)上完整執行一次,逐步記錄每條指令的輸出、UI 畫面與前後狀態。'));
add(table(['步驟', '指令', '執行身分', '實測耗時', '結果'], [
  ['①', 'delete vsp-component(VCF Automation)', 'vcf', '23 分 03 秒', '✅'],
  ['②', 'delete vsp-component(Migration service engine)', 'vcf', '12 分 02 秒', '✅'],
  ['③', 'delete vsp-cluster(VCFA services runtime)', 'root', '3 分 10 秒', '✅'],
], [8, 44, 14, 16, 18]));
add(P(''));
add(GOOD('結果:Fleet 元件由 10 個變 9 個,VCFA runtime VM(vcf-m03-auto-platform-lmh4w)已關機並刪除,SDDC Manager platform DB 的 vsp_cluster 紀錄已清除,VCFA console 連線逾時。Identity broker、VCF Operations、NSX、vCenter、SDDC Manager 完全不受影響。'));
add(H2('三個最重要的注意事項'));
add(BULLET('VSP 認證帳號必須用 admin,不是 administrator@vsphere.local(後者回 HTTP 401 access_denied)。'));
add(BULLET('是「三步」不是兩步:VCFA runtime 上還住著 Migration service engine(VCD_MIGRATOR),必須在刪 runtime 之前單獨刪掉。腳本不會幫你檢查。'));
add(BULLET('刪 runtime(③)必須在 SDDC Manager 上以 root 執行;vcf 帳號不在 sudoers,su 又需要 TTY。'));
add(PB());

// ============================ 二、流程圖 ============================
add(H1('二、三條指令各碰到哪裡'));
add(D('fig-flow.png', '三條指令分別作用在 Fleet、管理 VSP、VCFA runtime、vCenter、SDDC Manager DB 的情形'));
add(PB());

// ============================ 三、環境 ============================
add(H1('三、環境與前提'));
add(table(['角色', 'FQDN', 'IP'], [
  ['SDDC Manager(執行腳本的地方)', 'vcf-m03-sddcm01.home.lab', '10.0.1.65'],
  ['Fleet lifecycle', 'vcf-m03-fleet01.home.lab', '10.0.1.67'],
  ['VCF services runtime(管理 VSP)', 'vcf-m03-vsp01.home.lab', 'VIP .69,節點 .82/.83/.84'],
  ['VCFA services runtime(consumption VSP)', 'vcf-m03-auto-platform.home.lab', 'VIP .73,節點 .98'],
  ['VCF Automation console', 'vcf-m03-auto-vip.home.lab', '10.0.1.72'],
  ['vCenter', 'vcf-m03-vc01.home.lab', '10.0.1.60'],
], [38, 36, 26]));
add(P(''));
add(H2('前提'));
add(BULLET('VCF 9.1.1,VCFA 版本 9.1.1.0.25714559(≥ 9.1 才會真的刪除實體;< 9.1 只會清 Fleet 帳面)。'));
add(BULLET('能以 vcf 帳號 SSH 進 SDDC Manager,並知道 root 密碼。'));
add(BULLET('知道兩個 VSP 的 admin 密碼,以及 vCenter 的 administrator@vsphere.local 密碼。'));
add(BULLET('本次 VCFA 尚未啟用 Supervisor(provider 首頁顯示 Pre-requisites for setup are missing)。'));
add(PB());

// ============================ 四、Step 0 ============================
add(H1('四、Step 0 — 移除前狀態'));
add(P('先把移除前的狀態完整記下來,事後才有東西對照。'));
add(F('00-before-vcfa-login-ok.png', '移除前:VCFA provider 可正常登入(admin / System Administrator)'));
add(F('01-before-fleet-components.png', '移除前:VCF Operations → Build → Lifecycle → Components,共 10 個元件,VCF Automation 9.1.1.0.25714559 在列'));
add(CODE(cli('01-before-state.txt')));
add(PB());

// ============================ 五、Step 1 ============================
add(H1('五、Step 1 — 把腳本傳到 SDDC Manager'));
add(P('腳本要在 SDDC Manager 上執行(③ 會直接操作 SDDC Manager 的本機資料庫)。傳完比對 sha256。'));
add(CODE(cli('02-copy-script.txt')));
add(PB());

// ============================ 六、Step 2 ============================
add(H1('六、Step 2 — 確認 VSP 認證帳號'));
add(P('腳本對 VSP 的認證是 POST https://<vsp>/api/v1/identity/token(form-urlencoded,grant_type=password)。直接打一次,確認哪個帳號拿得到 token:'));
add(CODE(cli('03-vsp-account-check.txt')));
add(WARN('只有 admin 拿得到 token;administrator@vsphere.local 兩個 VSP 都回 401 access_denied。之前曾因此誤判「官方腳本需要 VSP 認證、無法執行」,其實只是帳號用錯。'));
add(GOOD('腳本會在任何刪除動作之前先驗證帳密(validate_vsp_credentials),帳號錯不會刪到一半。'));
add(PB());

// ============================ 七、Step 3 ============================
add(H1('七、Step 3 — 列出要刪的元件 ID'));
add(P('list 是唯讀操作,用 vcf 帳號即可。'));
add(CODE(cli('04-list-vsp-component.txt', { wide: true })));
add(CODE(cli('05-list-vsp-cluster.txt', { wide: true })));
add(table(['ID', '類型', '跑在哪個 runtime', '處理'], [
  ['12f80ada-…-6318ce58fe49', 'VCF Automation', 'vcf-m03-auto-platform', '① 刪除'],
  ['9c064f80-…-97fbccf26cdc', 'VCD_MIGRATOR(Migration service engine)', 'vcf-m03-auto-platform', '② 刪除'],
  ['4fde9186-…-a06664dad047', 'VCF services runtime(VCFA 用)', '—', '③ 刪除'],
  ['fe04c14c-…-05006adf5139', 'Identity broker', 'vcf-m03-vsp01(管理 VSP)', '⛔ 不能碰'],
], [30, 32, 24, 14]));
add(P(''));
add(WARN('VCD_MIGRATOR 也住在 VCFA runtime 上。它是 VCFA 部署時一起裝的 Migration service engine,必須在刪 runtime 之前另外刪掉。'));
add(PB());

// ============================ 八、Step 4 ============================
add(H1('八、Step 4 — ① 刪除 VCF Automation 元件'));
add(P('要同時給管理 VSP(-vsrf)與 VCFA runtime(-varf)的帳密,腳本才會連 VCFA runtime 上的元件一起處理。'));
add(CODE(cli('06-delete-vsp-component-vcfa.txt')));
add(P('流程:先刪 Fleet(60 秒)→ 等 120 秒回頭確認 404 → 查管理 VSP(不在,跳過)→ 到 VCFA runtime 刪除(1200 秒)。'));
add(H2('VCFA runtime 上的刪除任務'));
add(P('從 VCFA runtime 的 /api/v1/tasks 查到的任務,三個 stage:'));
add(CODE(cli('06b-consumption-vsp-delete-task.json', { max: 40 })));
add(H2('卸載過程'));
add(P('每分鐘記一次 VCFA runtime 上 prelude(VCFA 本體)namespace 的 pod 狀態,可以看到 pod 逐步進入 CreateContainerConfigError / ContainerCreating 後被清空:'));
add(CODE(cli('07-teardown-timeline.txt')));
add(NOTE('透過 ssh 執行 python 沒有 TTY,stdout 會被緩衝,刪除期間畫面完全沒輸出。建議改用 python3 -u。'));
add(PB());

// ============================ 九、Step 5 ============================
add(H1('九、Step 5 — ② 刪除 Migration service engine 元件'));
add(WARN('① 進行中如果跑 list vsp-component,會暫時看不到 VCD_MIGRATOR —— 但它並沒有被刪掉。下面的輸出顯示 ② 仍在 Fleet 中找到它並執行刪除(Deleting component ... from Fleet → SUCCEEDED)。不要因為 list 看不到就跳過這一步。'));
add(CODE(cli('08-delete-vsp-component-vcdmigrator.txt')));
add(P('刪除後再 list 一次,VCFA runtime 上已經沒有任何元件,只剩管理 VSP 上的 Identity broker:'));
add(CODE(cli('10-list-before-cluster-delete.txt', { wide: true })));
add(PB());

// ============================ 十、Step 6 ============================
add(H1('十、Step 6 — 在 SDDC Manager 取得 root'));
add(P('③ 會直接改 SDDC Manager 的 platform 資料庫,腳本會檢查兩件事:os.geteuid() == 0,以及 http://localhost/commonsvcs/about 回傳 name=COMMON_SERVICES。'));
add(P('vcf 帳號不在 sudoers,su 又必須在終端機裡執行。用 python 的 pty 模組開虛擬終端、看到密碼提示就送出密碼:'));
add(CODE(cli('09-get-root.txt')));
add(CODE([
  '# asroot.py(核心邏輯)',
  'pid, fd = pty.fork()',
  'if pid == 0:',
  '    os.execvp("su", ["su", "-", "root", "-c", cmd])',
  '# 父程序:讀到 "assword" 就寫入 root 密碼 + 換行,其餘輸出照印',
].join('\n')));
add(PB());

// ============================ 十一、Step 7 ============================
add(H1('十一、Step 7 — ③ 刪除 VCFA services runtime'));
add(P('這一步要給 vCenter 帳密(-vu / -vp),腳本會從 Fleet 取得 runtime 的 VM 清單與所在 vCenter,然後關機刪除。'));
add(CODE(cli('11-delete-vsp-cluster.txt')));
add(table(['動作', '結果'], [
  ['驗證 root', 'Verified: running as root on the SDDC Manager VM'],
  ['Fleet 刪除', 'task 01a1148e… SUCCEEDED(60 秒),120 秒後確認 404'],
  ['vCenter', 'vm-43 vcf-m03-auto-platform-lmh4w 關機 → 刪除'],
  ['SDDC Manager platform DB', 'vsp_cluster 紀錄刪除(psql: DO)'],
], [30, 70]));
add(PB());

// ============================ 十二、Step 8 ============================
add(H1('十二、Step 8 — 移除後驗證'));
add(F('09-after-fleet-components.png', '移除後:Fleet 元件剩 9 個,VCF Automation 已不在清單'));
add(F('10-after-fleet-tasks.png', '移除後:Fleet → Tasks 留有三筆刪除紀錄,狀態皆為 Completed'));
add(CODE([
  'Delete VCF Automation component           12f80ada…  Completed',
  'Delete Migration service engine component 9c064f80…  Completed',
  'Delete VCF services runtime component     4fde9186…  Completed',
].join('\n')));
add(F('11-after-vcfa-unreachable.png', '移除後:VCFA console 連線逾時(net::ERR_CONNECTION_TIMED_OUT)'));
add(CODE(cli('12-after-state-clean.txt')));
add(table(['檢查項目', '移除前', '移除後'], [
  ['Fleet 元件數', '10', '9(VCF Automation 消失)'],
  ['vCenter VM', '11(含 auto-platform-lmh4w)', '10(auto-platform-lmh4w 已刪)'],
  ['VCFA /automation/', '200', '000(連不上)'],
  ['10.0.1.98(runtime 節點)', '有回應', 'Test-Connection 全 TimedOut'],
  ['platform DB vsp_cluster', '含 4fde9186…(移除前未直接查;③ 刪除時腳本確認它存在並刪除)', '1 筆,只剩管理 VSP 的 16fbc3aa…'],
  ['Identity broker(管理 VSP)', 'pd Successful', 'pd Successful、2 pod Running(未受影響)'],
  ['DNS auto-vip / auto-platform', '存在', '仍存在(腳本不處理 DNS)'],
], [34, 30, 36]));
add(PB());

// ============================ 十三、注意事項 ============================
add(H1('十三、注意事項與坑'));
add(table(['症狀 / 情境', '原因', '做法'], [
  ['Failed to obtain VSP token (HTTP 401)', '用了 administrator@vsphere.local', 'VSP 帳號一律用 admin'],
  ['① 進行中 list 看不到 VCD_MIGRATOR', 'Fleet 清單暫時性的狀態', '不要跳過 ②;③ 之前再 list 確認'],
  ['直接跑 ③ 會留下孤兒', '腳本不檢查 runtime 上是否還有元件', '嚴守 ① → ② → ③ 順序'],
  ['③ 報 must be root', 'vsp-cluster 刪除要改本機 DB', '用 pty 執行 su(見 Step 6)'],
  ['刪除期間畫面沒輸出', 'ssh 無 TTY,python stdout 緩衝', 'python3 -u'],
  ['元件版本 < 9.1', 'should_skip_infra_deletion 會跳過實體刪除', '只會清 Fleet 帳面,VM 要另外處理'],
  ['ping 看起來有回應', 'Windows 把 Destination host unreachable 算成 Received', '看回應來源,或用 Test-Connection'],
  ['DNS 記錄還在', '腳本不處理 DNS', '自行刪除 auto-vip / auto-platform 的 A 與 PTR'],
], [30, 36, 34]));
add(P(''));
add(WARN('已知後續問題(KB 441127):VCFA 元件移除後若要再加回,可能因 infrastructure properties 為 NULL 而無法 import。移除前請確認之後不會需要原地加回同一套。'));
add(PB());

// ============================ 附錄 A ============================
add(H1('附錄 A:可直接複製的完整指令'));
add(P('以下在 SDDC Manager 上執行;密碼以變數代替。'));
add(CODE([
  '# 0) 準備',
  'cd /home/vcf',
  'export VSPPW=\'<VSP admin 密碼>\'  VCPW=\'<vCenter administrator@vsphere.local 密碼>\'',
  'FLEET=vcf-m03-fleet01.home.lab',
  'MGMT_VSP=vcf-m03-vsp01.home.lab',
  'VCFA_VSP=vcf-m03-auto-platform.home.lab',
  '',
  '# 1) 列出 ID(唯讀)',
  'python3 -u cleanup_component.py list vsp-component -ff $FLEET -vsrf $MGMT_VSP -vsru admin -vsrp "$VSPPW"',
  'python3 -u cleanup_component.py list vsp-cluster   -ff $FLEET -vsrf $MGMT_VSP -vsru admin -vsrp "$VSPPW"',
  '',
  '# 2) ① 刪 VCF Automation(vcf 帳號即可)',
  'python3 -u cleanup_component.py delete vsp-component -c <VCFA_ID> \\',
  '  -ff $FLEET -vsrf $MGMT_VSP -vsru admin -vsrp "$VSPPW" \\',
  '  -varf $VCFA_VSP -varu admin -varp "$VSPPW" -fd',
  '',
  '# 3) ② 刪 Migration service engine(VCD_MIGRATOR)',
  'python3 -u cleanup_component.py delete vsp-component -c <VCD_MIGRATOR_ID> \\',
  '  -ff $FLEET -vsrf $MGMT_VSP -vsru admin -vsrp "$VSPPW" \\',
  '  -varf $VCFA_VSP -varu admin -varp "$VSPPW" -fd',
  '',
  '# 4) 再 list 一次,確認 VCFA runtime 上已經沒有元件',
  'python3 -u cleanup_component.py list vsp-component -ff $FLEET -vsrf $MGMT_VSP -vsru admin -vsrp "$VSPPW"',
  '',
  '# 5) ③ 刪 VCFA services runtime(必須 root)',
  'python3 -u cleanup_component.py delete vsp-cluster -c <VSP_CLUSTER_ID> \\',
  '  -ff $FLEET -vsrf $MGMT_VSP -vsru admin -vsrp "$VSPPW" \\',
  '  -vu administrator@vsphere.local -vp "$VCPW" -fd',
].join('\n')));
add(PB());

// ============================ 附錄 B ============================
add(H1('附錄 B:腳本參數一覽'));
add(table(['參數', '長名稱', '用在', '說明'], [
  ['-ff', '--fleet-fqdn', '全部', 'Fleet lifecycle 的 FQDN'],
  ['-vsrf', '--vcf-services-runtime-fqdn', '全部', '管理 VSP 的 FQDN'],
  ['-vsru / -vsrp', '--vcf-services-runtime-username/password', '全部', '管理 VSP 帳密(帳號用 admin)'],
  ['-c', '--component-id', 'delete', '要刪的元件或 runtime ID'],
  ['-fd', '--force-delete', 'delete', '不詢問直接刪'],
  ['-varf', '--vcfa-vcf-services-runtime-fqdn', 'delete vsp-component', 'VCFA runtime FQDN(刪 VCFA / Migration service engine 必填)'],
  ['-varu / -varp', '--vcfa-vcf-services-runtime-username/password', 'delete vsp-component', 'VCFA runtime 帳密(帳號用 admin)'],
  ['-vu / -vp', '--vcenter-username/password', 'delete vsp-cluster', 'vCenter 帳密,用來關機刪 VM'],
], [16, 36, 20, 28]));
add(P(''));
add(table(['常數', '值', '意義'], [
  ['POLL_INTERVAL_IN_SECONDS', '30', '每 30 秒查一次任務狀態'],
  ['MAX_POLL_TIME_IN_SECONDS', '7200', '單一任務最多等 2 小時'],
  ['FLEET_DELETE_RETRY_DELAY_IN_SECONDS', '120', 'Fleet 刪完後等 2 分鐘回頭確認'],
], [42, 12, 46]));

// ============================ 組檔 ============================
const doc = new Document({
  styles: { default: {
    document: { run: { font: 'Microsoft JhengHei', size: 21 } },
    heading1: { run: { font: 'Microsoft JhengHei', size: 30, bold: true, color: C.blue } },
    heading2: { run: { font: 'Microsoft JhengHei', size: 25, bold: true, color: C.blue } },
  } },
  sections: [{ properties: { page: { margin: { top: 1000, bottom: 1000, left: 1000, right: 1000 } } }, children: body }],
});
Packer.toBuffer(doc).then(buf => {
  fs.writeFileSync(OUT, buf);
  console.log('OK ->', OUT, (buf.length / 1024 / 1024).toFixed(2) + ' MB', '| 圖數', figNo);
  if (missing.length) { console.log('缺檔 ' + missing.length + ':'); missing.forEach(m => console.log('   ' + m)); }
  else console.log('所有圖與 CLI 證據都找到了');
}).catch(e => { console.error('FAILED', e); process.exit(1); });
