"""m08 SDDC Manager 對 vcf-i05-vc01(vSAN vMotion health 測試) 跑匯入 precheck(POST /v1/sddcs/imports/validations)。
用法: python -I run_precheck.py <label>   → 存 precheck-<label>.json,印出每項結果。
"""
import json, os, ssl, socket, hashlib, sys, time, urllib.request

SDDCM = 'https://10.0.1.147'
VC = 'vcf-i05-vc01.home.lab'
PW = os.environ['LABPASS']   # SDDC Manager + i05 vCenter SSO password
OUT = os.path.dirname(os.path.abspath(__file__))
label = sys.argv[1] if len(sys.argv) > 1 else 'run'
ctx = ssl._create_unverified_context()


def thumbprint(host):
    with socket.create_connection((host, 443), timeout=15) as s:
        with ctx.wrap_socket(s, server_hostname=host) as t:
            der = t.getpeercert(binary_form=True)
    h = hashlib.sha256(der).hexdigest().upper()
    return ':'.join(h[i:i + 2] for i in range(0, len(h), 2))


def call(method, path, body=None, tok=None):
    req = urllib.request.Request(SDDCM + path, method=method,
                                 data=json.dumps(body).encode() if body is not None else None)
    req.add_header('Content-Type', 'application/json')
    req.add_header('Accept', 'application/json')
    if tok:
        req.add_header('Authorization', 'Bearer ' + tok)
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=120) as r:
            return r.status, json.loads(r.read() or b'{}')
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b'{}')


tok = call('POST', '/v1/tokens', {'username': 'administrator@vsphere.local', 'password': PW})[1]['accessToken']
spec = {'vcenterAddress': VC, 'vcenterSslThumbprint': thumbprint(VC),
        'vcenterSsoUsername': 'administrator@vsphere.local', 'vcenterSsoPassword': PW}
if len(sys.argv) > 2:
    code, resp = 0, {}
else:
    code, resp = call('POST', '/v1/sddcs/imports/validations', spec, tok)
    print('POST', code, json.dumps(resp)[:600])
tid = resp.get('taskId') or resp.get('id')
if len(sys.argv) > 2:
    tid = sys.argv[2]          # 接續查既有的 taskId
if not tid:
    sys.exit(1)

final = resp
for _ in range(150):
    code, final = call('GET', f'/v1/sddcs/imports/{tid}', tok=tok)
    st = final.get('status') or final.get('executionStatus')
    if st and st.upper() not in ('IN_PROGRESS', 'PENDING', 'RUNNING'):
        break
    time.sleep(10)

json.dump(final, open(f'{OUT}/precheck-{label}.json', 'w', encoding='utf-8'), indent=1, ensure_ascii=False)
print('final status:', final.get('status') or final.get('executionStatus'), '| saved', f'precheck-{label}.json')


rows = []


def walk(o, ent=''):
    """攤平 baseliner 巢狀結果:每個有 validationStatus 的節點一列"""
    if isinstance(o, dict):
        c = o.get('context') or {}
        ent = c.get('entityName') or ent
        if c.get('validationStatus'):
            rows.append((c.get('validationName') or c.get('description') or '', ent,
                         c['validationStatus'], c.get('importanceLevel', ''), c.get('severity', ''),
                         o.get('message') or '', o.get('remediationMessage') or ''))
        for v in o.values():
            walk(v, ent)
    elif isinstance(o, list):
        for v in o:
            walk(v, ent)


walk(final.get('validationResult') or final)
bad = [r for r in rows if r[2] != 'VALIDATION_SUCCESSFUL']
print(f'{len(rows)} checks, {len(bad)} not successful')
for r in rows:
    if r[2] != 'VALIDATION_SUCCESSFUL' or 'datastore' in r[0].lower():
        print(f'{r[0][:70]:70s} | {r[1][:28]:28s} | {r[2]} | {r[3]} | {r[4]}')
        if r[2] != 'VALIDATION_SUCCESSFUL':
            print('      msg:', r[5][:400])
json.dump(rows, open(f'{OUT}/precheck-{label}.rows.json', 'w', encoding='utf-8'), indent=1, ensure_ascii=False)
