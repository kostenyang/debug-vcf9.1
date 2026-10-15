"""overlay(FULL_STACK_VPC) Supervisor 啟用精靈:逐頁截圖 + 印出 Workload Network 頁欄位;--finish 才按 FINISH"""
import re, sys, time
from playwright.sync_api import sync_playwright

SH = "E:/9.1/doc-shots/m06-overlay/"
VC = "https://vcf-m06-vc01.home.lab"
PRIVATE_CIDR = ""  # 留精靈預設 172.30.0.0/16(不可與 private TGW block 172.26.0.0/16 重疊)


def main():
    import os
    os.makedirs(SH, exist_ok=True)
    with sync_playwright() as pw:
        b = pw.chromium.connect_over_cdp("http://127.0.0.1:9222")
        p = [x for c in b.contexts for x in c.pages if "vcf-m06-vc01" in x.url][0]
        p.bring_to_front(); p.set_default_timeout(30000)

        def shot(n):
            time.sleep(1); p.screenshot(path=SH + n + ".png"); print("shot", n)

        def banners():
            for _ in range(4):
                x = p.locator("button[aria-label*='lose']").first
                if x.count() and x.is_visible():
                    x.click(); time.sleep(1)

        p.goto(VC + "/ui/app/workload-platform", wait_until="domcontentloaded"); time.sleep(15); banners()
        shot("01-supervisor-mgmt-home")
        rx = re.compile(r"^\s*GET STARTED\s*$", re.I)
        done = False
        for loc in (p.get_by_role("button", name=rx), p.get_by_role("link", name=rx), p.get_by_text(rx)):
            for i in range(loc.count()):
                if loc.nth(i).is_visible():
                    loc.nth(i).click(); done = True; break
            if done:
                break
        if not done:
            print("GET STARTED not found"); return
        time.sleep(10)
        d = p.locator(".modal-dialog:visible").last
        d.get_by_label("VCF Networking with VPC (recommended)").check(force=True); time.sleep(2)
        shot("02-sv-1-network")
        nxt = lambda w=8: (d.get_by_role("button", name=re.compile(r"^\s*NEXT\s*$", re.I)).last.click(), time.sleep(w))
        nxt()
        cd = d.get_by_role("tab", name=re.compile(r"cluster deployment", re.I)).first
        cd.wait_for(state="visible", timeout=60000); cd.click(); time.sleep(5)
        name = d.locator("input[name='vsc-wcp-supervisor-name']:visible").first
        name.fill("vcf-m06-sv02"); name.blur()
        d.locator("clr-dg-row", has_text="vcf-m06-cl01").first.locator("input[type=radio]").check(force=True); time.sleep(1)
        zone = d.locator("input[name='vsc-wcp-zone-name']:visible").first
        if zone.count() and zone.is_enabled():
            zone.fill("vz-01"); zone.blur(); time.sleep(1)
        else:
            print("zone input disabled (existing zone):", zone.input_value() if zone.count() else "n/a")
        shot("03-sv-2-location")
        nxt()
        for lbl in ["Control Plane Storage Policy", "Ephemeral Disks Storage Policy", "Image Cache Storage Policy"]:
            d.get_by_label(lbl).select_option(label="vks-ftt0"); time.sleep(1)
        shot("04-sv-3-storage")
        nxt(10)
        d.locator("select:visible").first.select_option(label="Static"); time.sleep(2)
        for nm, val in [("vsc-wcp-starting-ip-address", "10.0.1.222-10.0.1.226"), ("vsc-wcp-subnet-mask", "255.255.254.0"),
                        ("vsc-wcp-gateway", "10.0.0.1"), ("vsc-wcp-master-dns-search-domains", "home.lab")]:
            el = d.locator(f"input[name='{nm}']:visible").first; el.fill(val); el.blur(); time.sleep(0.5)
        d.locator("#network-select-combobox button[aria-label='Show options']").first.click(); time.sleep(3)
        p.locator("[role=option]:visible").filter(has_text="SDDC-DPortGroup-VM-Mgmt").first.click(); time.sleep(2)
        shot("05-sv-4-mgmt-network")
        nxt(10)
        shot("06-sv-5-workload-raw")
        txt = d.inner_text()
        i = txt.find("Workload Network")
        print("---- workload page text ----"); print(txt[i:i + 2500]); print("----")
        # 列出此頁所有 input 的 name/id/placeholder,找 private CIDR 欄位
        for el in d.locator("input:visible, textarea:visible").all():
            print("INPUT", el.get_attribute("name"), el.get_attribute("id"), el.get_attribute("placeholder"), repr(el.input_value()[:40]))
        d.locator("#nsx-vpc-dns-servers").fill("10.0.0.200"); d.locator("#nsx-vpc-dns-servers").blur()
        d.locator("#nsx-vpc-ntp-servers").fill("10.0.1.254"); d.locator("#nsx-vpc-ntp-servers").blur(); time.sleep(1)
        # private CIDR 欄位(若有)
        pc = d.locator("#nsx-vpc-private-cidrs:visible")
        print("private cidr field:", pc.count() and pc.first.input_value())
        if PRIVATE_CIDR and pc.count():
            pc.first.fill(PRIVATE_CIDR); pc.first.blur()
        shot("07-sv-5-workload")
        nxt()
        d.locator("#control-plane-size-sel").select_option(label="Small (CPUs: 4, Memory: 16 GB, Storage: 48 GB)"); time.sleep(1)
        shot("08-sv-6-advanced")
        nxt()
        t = d.inner_text(); print(t[t.find("Ready to complete", 200):][:2500])
        shot("09-sv-7-ready")
        if "--finish" in sys.argv:
            d.get_by_role("button", name=re.compile(r"^\s*FINISH\s*$", re.I)).last.click(); time.sleep(20)
            shot("10-sv-configuring")
        else:
            print("not finishing (no --finish)")


if __name__ == "__main__":
    main()
