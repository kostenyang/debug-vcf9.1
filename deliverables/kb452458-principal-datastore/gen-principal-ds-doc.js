const fs = require('fs');
const {
  Document, Packer, Paragraph, TextRun, HeadingLevel, AlignmentType,
  Table, TableRow, TableCell, WidthType, ShadingType, PageBreak,
  LevelFormat, BorderStyle, Footer, PageNumber
} = require('docx');

const OUT = require('path').join(__dirname, 'VCF91-Imported-Cluster-Principal-Datastore-Change.docx');

const C = { blue: '1F4E79', gray: '595959', red: 'C00000', green: '2E7D32', amber: '7F6000' };
const NL = String.fromCharCode(10);
const TW = 9026; // A4 text width in DXA (11906 - 2x1440)

const H1 = t => new Paragraph({ text: t, heading: HeadingLevel.HEADING_1, spacing: { before: 320, after: 160 } });
const H2 = t => new Paragraph({ text: t, heading: HeadingLevel.HEADING_2, spacing: { before: 240, after: 120 } });
const H3 = t => new Paragraph({ text: t, heading: HeadingLevel.HEADING_3, spacing: { before: 180, after: 100 } });
const P = (t, o) => {
  o = o || {};
  return new Paragraph({
    children: [new TextRun({ text: t, size: o.size || 21, bold: o.bold, color: o.color, italics: o.italics })],
    spacing: { after: 100 }, alignment: o.align
  });
};
const RICH = (runs, o) => {
  o = o || {};
  return new Paragraph({
    children: runs.map(r => typeof r === 'string'
      ? new TextRun({ text: r, size: 21 })
      : new TextRun({ text: r.t, size: 21, bold: r.b, color: r.c, font: r.mono ? 'Consolas' : undefined, italics: r.i })),
    spacing: { after: 100 }, alignment: o.align
  });
};
const CODE = t => new Paragraph({
  children: String(t).split(NL).map((line, i) =>
    new TextRun({ text: line, font: 'Consolas', size: 17, break: i === 0 ? 0 : 1 })),
  shading: { type: ShadingType.CLEAR, fill: 'F2F2F2' },
  spacing: { before: 60, after: 60 }, indent: { left: 200 }
});
const BULLET = (t, lvl) => new Paragraph({
  children: [new TextRun({ text: t, size: 21 })],
  numbering: { reference: 'bullets', level: lvl || 0 }, spacing: { after: 60 }
});
const STEP = t => new Paragraph({
  children: [new TextRun({ text: t, size: 21 })],
  numbering: { reference: 'steps', level: 0 }, spacing: { after: 80 }
});
let stepInstance = 0;
const STEPS = arr => { stepInstance++; return arr.map(t => new Paragraph({
  children: [new TextRun({ text: t, size: 21 })],
  numbering: { reference: 'steps', level: 0, instance: stepInstance }, spacing: { after: 80 }
})); };
const NOTE = (t, color, fill) => new Paragraph({
  children: [new TextRun({ text: t, size: 20, color: color || C.red, bold: true })],
  shading: { type: ShadingType.CLEAR, fill: fill || 'FFF2CC' },
  spacing: { before: 80, after: 80 }, indent: { left: 100 }
});
const HR = () => new Paragraph({
  border: { bottom: { style: BorderStyle.SINGLE, size: 6, color: 'BFBFBF', space: 1 } },
  spacing: { before: 80, after: 160 }
});
const BR = () => new Paragraph({ children: [new PageBreak()] });

function table(headers, rows, pct, opts) {
  opts = opts || {};
  const widths = pct.map(p => Math.round(TW * p / 100));
  const hdr = new TableRow({
    tableHeader: true,
    children: headers.map((h, i) => new TableCell({
      width: { size: widths[i], type: WidthType.DXA },
      shading: { type: ShadingType.CLEAR, fill: C.blue },
      children: [new Paragraph({ children: [new TextRun({ text: h, bold: true, color: 'FFFFFF', size: 19 })] })]
    }))
  });
  const rs = rows.map(r => new TableRow({
    children: r.map((c, i) => new TableCell({
      width: { size: widths[i], type: WidthType.DXA },
      children: [new Paragraph({
        children: [new TextRun({ text: String(c), size: 18, font: (opts.mono && opts.mono.indexOf(i) >= 0) ? 'Consolas' : undefined })]
      })]
    }))
  }));
  return new Table({ rows: [hdr].concat(rs), width: { size: TW, type: WidthType.DXA }, columnWidths: widths });
}

const body = [];

/* ---------- 封面 ---------- */
body.push(new Paragraph({ text: '', spacing: { after: 1400 } }));
body.push(new Paragraph({
  children: [new TextRun({ text: 'VMware Cloud Foundation 9.1', bold: true, size: 40, color: C.blue })],
  alignment: AlignmentType.CENTER, spacing: { after: 120 }
}));
body.push(new Paragraph({
  children: [new TextRun({ text: '匯入叢集（Imported Cluster）主要資料存放區更換作業手冊', bold: true, size: 32, color: C.blue })],
  alignment: AlignmentType.CENTER, spacing: { after: 120 }
}));
body.push(P('Principal Datastore Change Procedure — 依 KB 452458 以 REST API 更新 SDDC Manager 清單', { align: AlignmentType.CENTER, size: 22, color: C.gray }));
body.push(new Paragraph({ text: '', spacing: { after: 800 } }));
body.push(P('文件版本：v1.0', { align: AlignmentType.CENTER }));
body.push(P('發行日期：2026-09-14', { align: AlignmentType.CENTER }));
body.push(P('適用版本：VCF 9.1.x（SDDC Manager 9.1.1 實測）', { align: AlignmentType.CENTER }));
body.push(P('文件性質：作業程序（含實驗室實測驗證）', { align: AlignmentType.CENTER }));
body.push(BR());

/* ---------- 目錄（靜態） ---------- */
body.push(H1('目錄'));
[
  '1. 文件目的與重要結論',
  '2. 背景：主要資料存放區在 SDDC Manager 中的角色',
  '3. 作業總覽',
  '4. 前置準備與檢查清單',
  '5. 階段一：底層資料與虛擬機遷移',
  '6. 階段二：VCF Service Runtime（Supervisor）運行面調整',
  '7. 階段三：SDDC Manager 控制面更新（KB 452458）',
  '8. 驗證與收尾',
  '9. 回復程序',
  '10. 附錄'
].forEach(t => body.push(P(t)));
body.push(BR());

/* ---------- 1 ---------- */
body.push(H1('1. 文件目的與重要結論'));
body.push(P('本文件說明在 VMware Cloud Foundation（以下簡稱 VCF）9.1 環境中，為「匯入（Imported）」的叢集更換主要資料存放區（Principal Datastore，SDDC Manager 內部欄位名稱為 primary datastore）的完整作業程序，涵蓋底層儲存遷移、VCF Service Runtime（vSphere Supervisor／VKS）運行面調整，以及依 Broadcom KB 452458 透過 REST API 更新 SDDC Manager 清單（inventory）的方法。'));
body.push(NOTE('原廠研發確認：SDDC Manager 使用者介面不支援更換匯入叢集的主要資料存放區。KB 452458 所述的 REST API 只更新 SDDC Manager 控制面（Control Plane）資料庫中的清單記錄，不會對 vCenter、ESX 主機或任何工作負載執行遷移；底層與服務運作面的實際搬移必須以手動方式完成。', C.red));
body.push(H2('1.1 重要結論（實驗室實測摘要）'));
body.push(table(
  ['項目', '結論'],
  [
    ['API 位置', 'SDDC Manager 本機 http://localhost/inventory/extensions/vi/…，需先 SSH 登入 SDDC Manager 執行，不需 API 權杖。'],
    ['匯出方式', 'GET /inventory/extensions/vi/domainInventory?domainIds=<domainId>；/clusters 端點沒有 GET 方法。'],
    ['更新方式', 'PUT /inventory/extensions/vi/clusters（KB 原版，body 為整份 domain 清單且 clusters 與 esxis 皆不可為空）或 PUT /inventory/extensions/vi/clusters/{clusterId}（單一叢集物件，較精簡，本文件建議）。'],
    ['真正生效的欄位', 'primaryDatastoreSourceId（vCenter 的 datastore MoRef，例如 datastore-15）與 primaryDatastoreType（列舉值）。primaryDatastoreName 在 9.1 資料模型已標示為 Deprecated，公開 API 顯示的名稱是由 vCenter 即時解析而來。'],
    ['更新語意', '整筆覆寫（非合併）。務必以匯出的 JSON 為基礎修改後推回，不可只送部分欄位。'],
    ['已知陷阱', 'primaryDatastoreType 填入不存在的列舉值（例如 VMFS_FC）時 API 仍回 HTTP 200，但該欄位會被寫成 null，導致公開 API /v1/clusters/{id} 的所有欄位回傳 null。合法值見第 7.1 節。'],
    ['後續動作', '更新後於 SDDC Manager UI 執行 Sync Changes（變更同步），並以 /v1/clusters/{id} 確認。']
  ], [24, 76]));
body.push(H2('1.2 適用範圍'));
body.push(BULLET('適用於 VCF 9.1.x 由 vSphere 環境匯入（Import）或轉換（Convert）而來的工作負載網域叢集。'));
body.push(BULLET('不適用於以 SDDC Manager 原生建立且具備 UI 更換儲存功能的情境；亦不涵蓋 vSAN 延伸叢集（Stretched Cluster）。'));
body.push(BULLET('所有 API 範例皆以實驗室 SDDC Manager 9.1.1（build 25713928）實測，範例中的識別碼為實驗室值，執行時請以自身環境匯出的值取代。'));
body.push(BR());

/* ---------- 2 ---------- */
body.push(H1('2. 背景：主要資料存放區在 SDDC Manager 中的角色'));
body.push(P('SDDC Manager 為每個叢集在清單資料庫中記錄一個主要資料存放區（primary datastore）。此記錄本身不影響 vSphere 對儲存的實際使用，但會被 SDDC Manager 的工作流程當作依據，主要包括：'));
body.push(BULLET('新增主機（Add Host）／擴充叢集（Expand Cluster）：依 primaryDatastoreType 決定主機納管時的儲存類型檢核與掛載動作。'));
body.push(BULLET('叢集資訊顯示與公開 API（/v1/clusters）：primaryDatastoreName 與 primaryDatastoreType 的來源。'));
body.push(BULLET('部分生命週期與健康檢查流程：例如 vSAN 相關的前置檢查會依類型是否為 vSAN 而啟用或略過。'));
body.push(P('因此，當叢集的實際主要儲存已經由 vSAN 更換為 VMFS／NFS，或由一個 datastore 換到另一個 datastore 時，若 SDDC Manager 清單未同步更新，後續的新增主機或升級流程可能對錯誤的 datastore 進行檢核而失敗。'));
body.push(H2('2.1 資料模型（SDDC Manager 9.1.1 實測）'));
body.push(P('以下欄位取自 SDDC Manager 清單服務（commonsvcs）的 Cluster 模型，「Deprecated」表示 9.1 程式碼已標示為棄用、資料庫中通常為空值，由 vCenter 即時解析取代：'));
body.push(table(
  ['欄位', '說明', '9.1 狀態'],
  [
    ['id', 'SDDC Manager 叢集 UUID', '使用中'],
    ['domainId / vcenterId', '所屬網域與 vCenter 的 UUID', '使用中'],
    ['sourceId', 'vCenter 叢集 MoRef（例如 domain-c9）', '使用中'],
    ['datacenterSourceId', 'vCenter 資料中心 MoRef（例如 datacenter-3）', '使用中'],
    ['primaryDatastoreSourceId', 'vCenter datastore MoRef（例如 datastore-15）', '使用中（更換時必改）'],
    ['primaryDatastoreType', '主要儲存類型列舉值（見 7.1 節）', '使用中（更換時必改）'],
    ['primaryDatastoreName', '主要 datastore 名稱', 'Deprecated；仍可寫入，建議一併填上以維持相容'],
    ['vsanDatastoreName', 'vSAN datastore 名稱', '一般為空'],
    ['name / datacenter / ftt', '叢集名稱、資料中心名稱、FTT', 'Deprecated；名稱由 vCenter 解析'],
    ['isImported', '是否為匯入叢集', '使用中'],
    ['vsanClusterMode / isImageBased / isStretched / isDefault', '其他屬性', '使用中，更換儲存時不要改動']
  ], [30, 44, 26], { mono: [0] }));
body.push(BR());

/* ---------- 3 ---------- */
body.push(H1('3. 作業總覽'));
body.push(P('整體作業分為三個階段，順序不可對調：先讓 vSphere 層的資料與工作負載實際落在新儲存上，再調整 Supervisor 的儲存原則，最後才更新 SDDC Manager 的清單記錄並同步。'));
body.push(table(
  ['階段', '動作', '執行工具', '完成判準'],
  [
    ['0. 前置', '備份 SDDC Manager、記錄現況、確認新 datastore 已掛載至叢集所有主機', 'SDDC Manager UI、vSphere Client', '檢查清單全數勾選（第 4 章）'],
    ['1. 底層遷移', '一般 VM、Supervisor／VKS 節點 VM、FCD／PV、vCLS、Content Library 全部搬到新 datastore', 'vSphere Client、CNS API', '舊 datastore 上無任何 VM、vmdk、FCD 與程式庫項目'],
    ['2. 運行面', '儲存原則與 Namespace／Supervisor／VKS 叢集的 StorageClass 指向新 datastore；CNS 健康', 'vSphere Client（Workload Management）', '新建 PVC 落在新 datastore；既有 PV 全數健康'],
    ['3. 控制面', '依 KB 452458 匯出 domain 清單、修改三個欄位、PUT 推回，執行 Sync Changes', 'SDDC Manager SSH + curl、SDDC Manager UI', '/v1/clusters/{id} 顯示新 datastore；UI 叢集頁面一致'],
    ['4. 收尾', '驗證 Add Host 前置檢查、下線舊 datastore', 'SDDC Manager UI、vSphere Client', '舊 datastore 已卸載／刪除且無告警']
  ], [14, 40, 24, 22]));
body.push(NOTE('建議在維護時段執行。階段 1 的 Storage vMotion 對工作負載不中斷，但 Supervisor 控制平面 VM 與 VKS 節點 VM 遷移期間會有短暫的 API 延遲；階段 3 只改資料庫記錄，不影響工作負載。', C.amber));
body.push(BR());

/* ---------- 4 ---------- */
body.push(H1('4. 前置準備與檢查清單'));
body.push(H2('4.1 備份與保護'));
body.push(BULLET('SDDC Manager：於 UI 執行一次手動備份（Administration → Backup Configuration → Backup Now），並確認備份檔已送達 SFTP 目的地。'));
body.push(BULLET('SDDC Manager 虛擬機：在 vSphere Client 對 SDDC Manager VM 建立快照（關機一致或靜止快照皆可），作業完成並驗證後再刪除。'));
body.push(BULLET('vCenter：確認 vCenter 檔案式備份在有效期內；本作業不修改 vCenter 資料，但 Storage vMotion 大量進行時建議有可回復點。'));
body.push(H2('4.2 記錄現況'));
body.push(P('以下資訊在階段 3 修改 JSON 與階段 4 驗證時都會用到，請先記錄：'));
body.push(table(
  ['項目', '取得方式', '範例（實驗室）'],
  [
    ['網域 ID（domainId）', 'GET https://<sddc-manager>/v1/domains', 'a53df574-d2d5-4906-a9a8-80d15608f501'],
    ['叢集 ID（clusterId）', 'GET https://<sddc-manager>/v1/clusters', '6a898ac1-0cff-4189-8631-8c7213a16363'],
    ['叢集 vCenter MoRef', '同上回應中的 sourceId 或 vCenter REST /api/vcenter/cluster', 'domain-c9'],
    ['舊 datastore MoRef 與類型', '清單匯出檔中的 primaryDatastoreSourceId / primaryDatastoreType', 'datastore-15 / VSAN'],
    ['新 datastore MoRef 與類型', 'vCenter REST GET /api/vcenter/datastore（回應中的 datastore 與 type 欄位）', 'datastore-1048 / VMFS'],
    ['新 datastore 名稱', '同上（name 欄位）', 'vcd-ds01']
  ], [26, 44, 30], { mono: [2] }));
body.push(P('查詢 vCenter datastore MoRef 的範例（任何可連到 vCenter 的主機）：'));
body.push(CODE([
  'SID=$(curl -sk -X POST https://<vcenter>/api/session -u "administrator@vsphere.local:<密碼>" | tr -d \'"\')',
  'curl -sk https://<vcenter>/api/vcenter/datastore -H "vmware-api-session-id: $SID" | jq -c \'.[] | {datastore,name,type}\'',
  '# 實驗室輸出：',
  '# {"datastore":"datastore-1048","name":"vcd-ds01","type":"VMFS"}',
  '# {"datastore":"datastore-15","name":"m01-cl01-ds-vsan01","type":"VSAN"}'
].join(NL)));
body.push(H2('4.3 檢查清單'));
[
  '新 datastore 已以相同名稱掛載至叢集內「所有」ESX 主機（NFS 請確認掛載點與匯出路徑一致；VMFS 請確認所有主機皆可見）。',
  '新 datastore 可用容量 ≥ 舊 datastore 已用容量 × 1.2（Storage vMotion 期間需暫存空間）。',
  '已規劃新 datastore 對應的 VM 儲存原則（Storage Policy）：建議以標籤（Tag）方式把新 datastore 加入「既有」原則，而非建立新原則（理由見第 6.1 節）。',
  '已確認叢集內 Supervisor 的狀態為 Running，VKS 叢集皆為 Ready，且無進行中的升級或擴縮。',
  '已取得 SDDC Manager 的 vcf 使用者 SSH 密碼與 admin@local API 密碼。',
  '已排定維護時段並通知相關使用者。'
].forEach(t => body.push(BULLET(t)));
body.push(BR());

/* ---------- 5 ---------- */
body.push(H1('5. 階段一：底層資料與虛擬機遷移'));
body.push(P('目標：讓叢集內所有虛擬機、持久化磁碟與相依物件實際落在新 datastore 上，使舊 datastore 可以安全下線。'));
body.push(H2('5.1 一般虛擬機 Storage vMotion'));
body.push(...STEPS([
  '在 vSphere Client 以叢集為範圍，於 VMs 分頁篩選「Datastore = 舊 datastore」，確認清單。',
  '分批選取虛擬機 → Migrate → Change storage only → 選擇新 datastore；VM 儲存原則若採「加標籤到既有原則」方式則維持不變，否則在此步驟同時切換原則。',
  '大量遷移建議每批 5–10 台，並觀察 datastore 延遲；完成後在舊 datastore 的 VMs 分頁確認已無虛擬機。'
]));
body.push(H2('5.2 Supervisor 控制平面 VM 與 VKS 節點 VM'));
body.push(P('Supervisor 控制平面 VM（SupervisorControlPlaneVM）與 VKS 工作叢集的節點 VM 是由 vSphere Workload Management 依儲存原則放置，可以用 Storage vMotion 搬移，但有兩點限制：'));
body.push(BULLET('搬移後的 datastore 必須符合該 VM 目前所綁定的儲存原則，否則 VM 會顯示「不相容」且後續由 Supervisor 觸發的重建會放回符合原則的舊 datastore。務必先完成第 6 章的原則調整，或採用「標籤加入既有原則」方式讓新 datastore 一開始就相容。'));
body.push(BULLET('控制平面 VM 建議逐台遷移，每台完成後確認 Supervisor 狀態仍為 Running 再進行下一台。'));
body.push(H2('5.3 持久化磁碟（FCD／CNS Persistent Volume）'));
body.push(NOTE('只有「目前掛載在 VM 上」的持久化卷會隨 Storage vMotion 一起搬移；未掛載（Released／Available 或 Pod 已刪除但 PVC 保留）的 CNS 卷不會自動搬移，vSphere Client 的 Container Volumes 頁面也沒有搬移按鈕。', C.red));
body.push(P('未掛載卷的處理方式（擇一）：'));
body.push(BULLET('以 CNS RelocateVolume API 逐一搬移（vSphere 7.0 U2 起提供；可透過 govc volume.ls 列出、再以 vSphere SDK 或 PowerCLI 呼叫 CnsVolumeManager.RelocateVolume）。'));
body.push(BULLET('先在 Kubernetes 端建立一個暫時的 Pod 將 PVC 掛載，使其成為「已掛載」狀態，隨該 Pod 所在節點 VM 一起 Storage vMotion，完成後刪除暫時 Pod。'));
body.push(BULLET('對可重建的資料（例如快取、暫存）改以新的 StorageClass 重新建立 PVC，以應用層方式搬移資料。'));
body.push(P('完成後於 vSphere Client → 叢集 → Monitor → Cloud Native Storage → Container Volumes，逐一確認每個卷的 Datastore 欄位已為新 datastore，且 Health 為 Accessible。'));
body.push(H2('5.4 vSphere Cluster Services（vCLS）虛擬機'));
body.push(P('vCLS VM 由 vCenter 自動放置，若未限制允許的 datastore，會持續在舊 datastore 上重生，導致舊 datastore 無法卸載。'));
body.push(...STEPS([
  'vSphere Client → 叢集 → Configure → vSphere Cluster Services → Datastores → Add，將新 datastore 加入允許清單並移除舊 datastore。',
  '等待數分鐘讓 vCenter 自動將 vCLS VM 重新部署至新 datastore；亦可先將叢集設為 Retreat Mode 再解除以加速。'
]));
body.push(H2('5.5 Content Library（VKS／Supervisor 映像庫）'));
body.push(P('Content Library 的儲存後端在建立後無法變更。若 Supervisor 或 VKS 使用的映像庫（本機或訂閱式）位於舊 datastore，需要：'));
body.push(...STEPS([
  '在新 datastore 建立一個新的 Content Library（訂閱式請使用相同的訂閱 URL；本機式請重新匯入相同的 OVA／映像項目）。',
  'Supervisor → Configure → General／VKS Service，將 Content Library 改指向新程式庫；Namespace 層若有個別關聯亦需更新。',
  '確認 VKS 叢集的 TKR（Tanzu Kubernetes Release）清單仍可正常列出後，再刪除舊程式庫。'
]));
body.push(H2('5.6 其他常見遺漏'));
body.push(BULLET('ISO／範本（Template）與 OVF 檔：Storage vMotion 篩選不會顯示，需在 Datastore Browser 逐一確認。'));
body.push(BULLET('NSX Edge 節點 VM（若部署在此叢集）：可 Storage vMotion，但請逐台進行並確認 Edge 叢集狀態。'));
body.push(BULLET('vSAN 為舊 datastore 時：vSAN 本身不會因清單更新而關閉，需在所有資料搬離後另行評估是否停用 vSAN（見 8.3 節）。'));
body.push(BR());

/* ---------- 6 ---------- */
body.push(H1('6. 階段二：VCF Service Runtime（Supervisor）運行面調整'));
body.push(H2('6.1 儲存原則策略：優先「標籤加入既有原則」'));
body.push(P('Supervisor 的儲存配置有三層都引用 VM 儲存原則：Supervisor 本身（Control Plane、Ephemeral Disks、Image Cache）、每個 vSphere Namespace 指派的原則（對應 Kubernetes StorageClass），以及每個 VKS 叢集規格中引用的 StorageClass 名稱。'));
body.push(table(
  ['做法', '需要調整的地方', '風險'],
  [
    ['A. 把新 datastore 的標籤加入既有原則（建議）', '只需在 vSphere Client → Policies and Profiles 編輯原則的標籤規則；三層皆不需改動。', '低。既有 VKS 叢集的 StorageClass 名稱不變，擴縮與升級不受影響。'],
    ['B. 建立新原則', 'Supervisor → Configure → Storage 三個原則；每個 Namespace 新增原則；每個 VKS 叢集的 spec 中 storageClass 改名（或保留舊原則直到叢集重建）。', '中高。任何仍引用舊 StorageClass 的 VKS 叢集，在節點重建、擴縮或升級時會因原則不相容而卡住。']
  ], [30, 42, 28]));
body.push(H2('6.2 Namespace 儲存原則'));
body.push(...STEPS([
  'vSphere Client → Workload Management → Namespaces → 選擇 Namespace → Storage → Edit。',
  '確認（做法 A）或新增（做法 B）指向新 datastore 的儲存原則；做法 B 需同時保留舊原則直到所有 PVC 與 VKS 節點皆已遷移。',
  '在 Kubernetes 端以 kubectl get storageclass 確認對應的 StorageClass 已出現。'
]));
body.push(H2('6.3 Supervisor 層儲存原則（做法 B 才需要）'));
body.push(P('Workload Management → Supervisors → 選擇 Supervisor → Configure → Storage，將 Control Plane Storage Policy、Ephemeral Disks Storage Policy、Image Cache Storage Policy 三者改為新原則。修改後 Supervisor 會逐台重建控制平面 VM，期間 Kubernetes API 可能短暫中斷。'));
body.push(H2('6.4 Cloud Native Storage（CNS）狀態確認'));
body.push(...STEPS([
  'vSphere Client → 叢集 → Monitor → Cloud Native Storage → Container Volumes。',
  '逐一確認 Datastore 欄位為新 datastore、Health 為 Accessible、Storage Compliance 為 Compliant。',
  '在 Kubernetes 端以新的 StorageClass 建立一個測試 PVC 並掛載到測試 Pod，確認可正常 Bound，且在 Container Volumes 頁面可看到該卷落在新 datastore。'
]));
body.push(BR());

/* ---------- 7 ---------- */
body.push(H1('7. 階段三：SDDC Manager 控制面更新（KB 452458）'));
body.push(P('本階段只修改 SDDC Manager 清單資料庫中該叢集的主要 datastore 記錄。所有指令均在 SDDC Manager 虛擬機本機執行（SSH 以 vcf 使用者登入），清單服務的擴充端點掛在 http://localhost/inventory/extensions/vi，不需要 API 權杖。'));
body.push(H2('7.1 端點行為（SDDC Manager 9.1.1 實測）'));
body.push(table(
  ['端點', '方法', '實測行為'],
  [
    ['/inventory/extensions/vi/domainInventory?domainIds=<domainId>', 'GET', '回傳陣列，每個元素為一個網域的完整清單（clusters、esxis、vcenters、vds、nsxtClusters…）。這就是 KB 所稱的 domain.json。'],
    ['/inventory/extensions/vi/clusters', 'GET', 'HTTP 400 Request method GET is not supported（無法用此端點讀取）。'],
    ['/inventory/extensions/vi/clusters', 'PUT', 'KB 原版。body 為 domain 清單物件，程式碼強制 clusters 與 esxis 兩個陣列皆不可為空；缺 esxis 時回 HTTP 500 VCF_RUNTIME_ERROR。成功回 HTTP 200 無內容。'],
    ['/inventory/extensions/vi/clusters/{clusterId}', 'PUT', 'body 為單一叢集物件。成功回 HTTP 200 無內容。本文件建議使用此端點，影響範圍最小。'],
    ['/v1/clusters/{clusterId}（https，需權杖）', 'GET', '公開 API，用於驗證。name 與 primaryDatastoreName 由 vCenter 即時解析；primaryDatastoreType 直接來自清單記錄。']
  ], [38, 10, 52], { mono: [0] }));
body.push(P('primaryDatastoreType 合法列舉值（取自 9.1.1 DataStoreType 列舉）：'));
body.push(table(
  ['列舉值', '對應儲存'],
  [
    ['VSAN', 'vSAN OSA'],
    ['VSAN_ESA', 'vSAN ESA'],
    ['VSAN_MAX', 'vSAN Max（儲存專用叢集）'],
    ['VSAN_REMOTE', '遠端掛載的 vSAN datastore（HCI Mesh 用戶端）'],
    ['NFS', 'NFS v3'],
    ['NFS41', 'NFS v4.1'],
    ['FC', 'Fibre Channel（VMFS on FC）'],
    ['VMFS', 'VMFS（iSCSI／本機／其他區塊儲存）'],
    ['VVOL / VVOL_FC / VVOL_ISCSI / VVOL_NFS', 'vVols 及其傳輸協定變體']
  ], [40, 60], { mono: [0] }));
body.push(NOTE('陷阱：填入不在此清單的值（實測 VMFS_FC）時 API 仍回 HTTP 200，但 primaryDatastoreType 會被寫成 null，公開 API /v1/clusters/{id} 隨即對該叢集回傳全部 null。請逐字比對列舉值後再送出。', C.red));
body.push(H2('7.2 操作步驟'));
body.push(H3('步驟 1：登入 SDDC Manager 並匯出網域清單'));
body.push(CODE([
  'ssh vcf@<sddc-manager-fqdn>',
  'mkdir -p ~/kb452458 && cd ~/kb452458',
  'DOMAIN_ID=<網域 UUID>',
  'CLUSTER_ID=<叢集 UUID>',
  'curl -s "http://localhost/inventory/extensions/vi/domainInventory?domainIds=$DOMAIN_ID" > domain.json',
  'cp domain.json domain.json.bak            # 回復用，務必保留',
  'python3 -c "import json;d=json.load(open(\'domain.json\'))[0];print(json.dumps([c for c in d[\'clusters\'] if c[\'id\']==\'$CLUSTER_ID\'][0],indent=2))"'
].join(NL)));
body.push(P('實驗室匯出的叢集物件（修改前）：'));
body.push(CODE(JSON.stringify({
  domainId: 'a53df574-d2d5-4906-a9a8-80d15608f501',
  vcenterId: 'e781679f-a929-407d-89c1-b5dec124b761',
  datacenterSourceId: 'datacenter-3',
  vdsIds: ['80c1ed88-5550-4af9-b010-e8b3f35cb66c'],
  isStretched: false, isDefault: true, status: 'ACTIVE',
  primaryDatastoreSourceId: 'datastore-15',
  primaryDatastoreType: 'VSAN',
  sourceId: 'domain-c9',
  isImageBased: false, vsanClusterMode: 'NONE', isImported: false,
  id: '6a898ac1-0cff-4189-8631-8c7213a16363'
}, null, 2)));
body.push(P('注意：匯出物件中沒有 name 與 primaryDatastoreName，這是 9.1 的正常現象（資料庫中為空、欄位已棄用），不代表匯出不完整。', { italics: true, color: C.gray }));
body.push(H3('步驟 2：修改三個欄位'));
body.push(P('以步驟 1 匯出的物件為基礎，只改 primaryDatastoreSourceId、primaryDatastoreType、primaryDatastoreName 三個欄位，其餘欄位一律保留原值：'));
body.push(CODE([
  'NEW_DS_MOREF=datastore-1048      # 第 4.2 節查到的新 datastore MoRef',
  'NEW_DS_TYPE=VMFS                 # 第 7.1 節列舉值，逐字比對',
  'NEW_DS_NAME=vcd-ds01             # 新 datastore 名稱',
  'python3 - <<EOF',
  'import json',
  'd = json.load(open("domain.json"))[0]',
  'c = [x for x in d["clusters"] if x["id"] == "$CLUSTER_ID"][0]',
  'c["primaryDatastoreSourceId"] = "$NEW_DS_MOREF"',
  'c["primaryDatastoreType"]     = "$NEW_DS_TYPE"',
  'c["primaryDatastoreName"]     = "$NEW_DS_NAME"',
  'json.dump(c, open("cluster-new.json", "w"), indent=2)                       # 方法 A 用',
  'json.dump({"clusters": d["clusters"], "esxis": d["esxis"]}, open("domain-new.json", "w"))  # 方法 B 用',
  'print(json.dumps(c, indent=2))',
  'EOF'
].join(NL)));
body.push(H3('步驟 3：推回 SDDC Manager（二擇一）'));
body.push(P('方法 A（建議）：只更新該叢集。', { bold: true }));
body.push(CODE([
  'curl -s -w "HTTP %{http_code}\\n" -X PUT -H "Content-Type: application/json" \\',
  '  --data @cluster-new.json "http://localhost/inventory/extensions/vi/clusters/$CLUSTER_ID"',
  '# 預期輸出：HTTP 200（無 body）'
].join(NL)));
body.push(P('方法 B（KB 452458 原版）：以整份網域清單的 clusters 與 esxis 推回。', { bold: true }));
body.push(CODE([
  'curl -s -w "HTTP %{http_code}\\n" -X PUT -H "Content-Type: application/json" \\',
  '  --data @domain-new.json "http://localhost/inventory/extensions/vi/clusters"',
  '# 預期輸出：HTTP 200（無 body）；若回 500 VCF_RUNTIME_ERROR，先檢查 body 是否同時含 clusters 與 esxis'
].join(NL)));
body.push(P('兩種方法在資料庫層都是「整筆覆寫」：程式會以 body 中的物件重建整列後儲存，因此 body 中缺少的欄位會被清空。這也是為什麼必須從匯出檔修改、不可手寫最小 JSON 的原因。', { italics: true, color: C.gray }));
body.push(H3('步驟 4：確認清單已更新'));
body.push(CODE([
  '# 本機清單（免權杖）',
  'curl -s "http://localhost/inventory/extensions/vi/domainInventory?domainIds=$DOMAIN_ID" | \\',
  '  python3 -c "import sys,json;d=json.load(sys.stdin)[0];print([c for c in d[\'clusters\'] if c[\'id\']==\'$CLUSTER_ID\'][0])"',
  '',
  '# 公開 API（任何主機，需權杖）',
  'TOKEN=$(curl -sk -X POST https://<sddc-manager>/v1/tokens -H "Content-Type: application/json" \\',
  '  -d \'{"username":"admin@local","password":"<密碼>"}\' | jq -r .accessToken)',
  'curl -sk https://<sddc-manager>/v1/clusters/$CLUSTER_ID -H "Authorization: Bearer $TOKEN" | \\',
  '  jq \'{name,primaryDatastoreName,primaryDatastoreType,isDefault}\'',
  '# 預期：primaryDatastoreType 為新值；primaryDatastoreName 為 vCenter 解析出的新 datastore 名稱；name 與 isDefault 非 null'
].join(NL)));
body.push(NOTE('若 /v1/clusters/{id} 回傳的 name、primaryDatastoreType、isDefault 全為 null，代表 primaryDatastoreType 被寫成 null（通常是列舉值打錯）。請立即以 domain.json.bak 中的原物件依方法 A 推回（見第 9 章），再重新檢查列舉值。', C.red));
body.push(H3('步驟 5：SDDC Manager UI 執行變更同步（Sync Changes）'));
body.push(...STEPS([
  '登入 SDDC Manager UI → Inventory → Workload Domains → 選擇該網域 → Clusters → 選擇該叢集。',
  '若叢集頁面出現 Sync Changes／變更同步 提示，點選執行，等待工作完成。',
  '重新整理叢集摘要頁，確認 Primary Datastore 名稱與類型與 vCenter 一致。'
]));
body.push(H2('7.3 實驗室實測紀錄（供比對）'));
body.push(table(
  ['測試', '請求', '結果'],
  [
    ['A', 'PUT /clusters/{id}，僅將 primaryDatastoreName 改為測試值', 'HTTP 200；再次 GET 可見新值；/v1/clusters/{id} 的 primaryDatastoreName 仍顯示 vCenter 實際名稱（證明公開 API 的名稱由 vCenter 解析）'],
    ['B', 'PUT /clusters，body 為原始匯出的 {clusters, esxis}', 'HTTP 200；記錄還原為原值（證明整筆覆寫且 round-trip 安全）'],
    ['C', 'PUT /clusters，body 只有 clusters 無 esxis', 'HTTP 500 VCF_RUNTIME_ERROR（esxis 為必填）'],
    ['D', 'PUT /clusters/{id}，primaryDatastoreType 填 VMFS_FC（不存在）', 'HTTP 200 但 primaryDatastoreType 變 null；/v1/clusters/{id} 全部欄位為 null。以原物件 PUT 後恢復正常'],
    ['環境', 'SDDC Manager 9.1.1.0.25713928；網域 m01；叢集 m01-cl01（domain-c9）；datastore-15 = m01-cl01-ds-vsan01（VSAN）', '所有測試完成後已還原，公開 API 顯示正常']
  ], [8, 40, 52]));
body.push(BR());

/* ---------- 8 ---------- */
body.push(H1('8. 驗證與收尾'));
body.push(H2('8.1 控制面驗證'));
body.push(BULLET('/v1/clusters/{id}：primaryDatastoreType、primaryDatastoreName 為新值，name 與 isDefault 非 null。'));
body.push(BULLET('SDDC Manager UI 叢集摘要頁：Primary Datastore 顯示新 datastore。'));
body.push(BULLET('Add Host 前置驗證：於 SDDC Manager UI 對該叢集啟動 Add Host 精靈，走到驗證步驟確認儲存類型檢核通過後取消（不需真正新增主機）。'));
body.push(H2('8.2 運行面驗證'));
body.push(BULLET('Workload Management → Supervisors：狀態 Running、Config Status 無錯誤。'));
body.push(BULLET('kubectl get tanzukubernetescluster / cluster -A：所有 VKS 叢集 Ready；嘗試對一個測試叢集 scale +1 worker，確認新節點 VM 落在新 datastore。'));
body.push(BULLET('Cloud Native Storage → Container Volumes：全部 Accessible 且 Datastore 為新值。'));
body.push(H2('8.3 舊 datastore 下線'));
body.push(...STEPS([
  '在 Datastore Browser 確認舊 datastore 上除系統資料夾（.sdd.sf、.vSphere-HA 等）外沒有任何 VM 資料夾、vmdk、ISO 或 FCD（fcd 資料夾）。',
  '從 vSphere Cluster Services 的允許 datastore 清單移除舊 datastore（若 5.4 節尚未做）。',
  'NFS／VMFS：對叢集所有主機 Unmount；vSAN：所有資料搬離後，評估是否停用 vSAN 服務（停用前需先移除磁碟群組並確認 SDDC Manager 已無任何 vSAN 相關前置檢查依賴此叢集）。',
  '確認 vCenter 與 SDDC Manager 皆無新的告警後，刪除 SDDC Manager VM 快照。'
]));
body.push(BR());

/* ---------- 9 ---------- */
body.push(H1('9. 回復程序'));
body.push(P('控制面記錄的回復非常單純：以步驟 1 保留的 domain.json.bak 中的原始叢集物件，用方法 A 推回即可，不需要還原 SDDC Manager 備份。'));
body.push(CODE([
  'cd ~/kb452458',
  'python3 -c "import json;d=json.load(open(\'domain.json.bak\'))[0];json.dump([c for c in d[\'clusters\'] if c[\'id\']==\'$CLUSTER_ID\'][0],open(\'cluster-orig.json\',\'w\'))"',
  'curl -s -w "HTTP %{http_code}\\n" -X PUT -H "Content-Type: application/json" \\',
  '  --data @cluster-orig.json "http://localhost/inventory/extensions/vi/clusters/$CLUSTER_ID"',
  '# 再以 7.2 步驟 4 的指令確認'
].join(NL)));
body.push(P('若同時需要回復底層（工作負載搬回舊 datastore），順序與正向相反：先把清單記錄改回、再調整儲存原則、最後 Storage vMotion 回舊 datastore。只有在 SDDC Manager 本身狀態異常（服務無法啟動、清單服務回 500）時才使用 SDDC Manager 備份或 VM 快照回復。'));
body.push(BR());

/* ---------- 10 ---------- */
body.push(H1('10. 附錄'));
body.push(H2('10.1 程式碼層面的依據（SDDC Manager 9.1.1）'));
body.push(P('以下摘要來自 SDDC Manager 的 vcf-commonsvcs 服務，用以說明第 7 章各項行為的來源：'));
body.push(table(
  ['元件', '內容'],
  [
    ['InventoryExtensionsViController', '@RequestMapping("inventory/extensions/vi")；提供 GET /domainInventory、PUT /clusters（body DomainInventory）、PUT /clusters/{clusterId}（body Cluster）、PUT /esxis、PUT /vcenters、PUT /domains/{domainId} 等。'],
    ['updateCluster(DomainInventory)', 'Validate.notEmpty(clusters) 與 Validate.notEmpty(esxis) 後逐一呼叫 InventoryService.updateCluster / updateEsxi。'],
    ['TypedClientImpl.updateEntity', 'existsById → BeanUtils.copyProperties 建立新的資料庫實體 → repository.save，即整筆覆寫。'],
    ['Cluster 模型', 'name、datacenter、primaryDatastoreName、ftt 標示 @Deprecated；資料庫 cluster 表無 name 欄位。'],
    ['DataStoreType 列舉', 'VSAN、VSAN_ESA、VSAN_MAX、VSAN_REMOTE、NFS、NFS41、FC、VMFS、VVOL、VVOL_FC、VVOL_ISCSI、VVOL_NFS。']
  ], [30, 70], { mono: [0] }));
body.push(H2('10.2 參考資料'));
body.push(BULLET('Broadcom KB 452458：以 REST API 更新 SDDC Manager 清單中叢集的 Primary Datastore。'));
body.push(BULLET('VMware Cloud Foundation 9.1 Administration Guide：Import／Convert vSphere clusters、Sync Changes。'));
body.push(BULLET('vSphere IaaS Control Plane（Supervisor）文件：Storage Policies for Namespaces、Cloud Native Storage、Relocate CNS Volumes。'));
body.push(H2('10.3 文件維護'));
body.push(table(
  ['版本', '日期', '說明'],
  [['v1.0', '2026-09-14', '初版；含 SDDC Manager 9.1.1 實驗室實測結果']],
  [14, 20, 66]));

const doc = new Document({
  creator: 'VCF Lab',
  title: 'VCF 9.1 Imported Cluster Principal Datastore Change Procedure',
  numbering: {
    config: [
      { reference: 'bullets', levels: [
        { level: 0, format: LevelFormat.BULLET, text: '\u2022', alignment: AlignmentType.LEFT, style: { paragraph: { indent: { left: 560, hanging: 280 } } } },
        { level: 1, format: LevelFormat.BULLET, text: '\u2013', alignment: AlignmentType.LEFT, style: { paragraph: { indent: { left: 1000, hanging: 280 } } } }
      ] },
      { reference: 'steps', levels: [
        { level: 0, format: LevelFormat.DECIMAL, text: '%1.', alignment: AlignmentType.LEFT, style: { paragraph: { indent: { left: 560, hanging: 360 } } } }
      ] }
    ]
  },
  styles: { default: { document: { run: { font: 'Microsoft JhengHei', size: 21 } } } },
  sections: [{
    properties: { page: { margin: { top: 1440, bottom: 1440, left: 1440, right: 1440 } } },
    footers: { default: new Footer({ children: [new Paragraph({
      alignment: AlignmentType.CENTER,
      children: [new TextRun({ text: 'VCF 9.1 匯入叢集主要資料存放區更換作業手冊　｜　第 ', size: 16, color: C.gray }),
                 new TextRun({ children: [PageNumber.CURRENT], size: 16, color: C.gray }),
                 new TextRun({ text: ' 頁', size: 16, color: C.gray })]
    })] }) },
    children: body
  }]
});

Packer.toBuffer(doc).then(function (b) {
  fs.writeFileSync(OUT, b);
  console.log('OK 已產生: ' + OUT + '  (' + Math.round(b.length / 1024) + ' KB)');
});
