#!/usr/bin/env python3
"""brand_image.py - suntik branding (logo + nama GitHub) ke halaman About.

Bekerja pada image vendor_boot yang SUDAH jadi: fragmen recovery dibongkar,
tema di dalamnya dipatch, lalu dirakit ulang. Tidak perlu build ulang source.

Yang dipatch:

TWRP (twres/ui.xml + twres/portrait.xml)
  - resource `brand_logo`
  - halaman `about`: logo, nama, URL, versi, tombol Back
  - entri "About" di menu Advanced (theme TWRP 12.1 tidak punya halaman ini)
  - splash: `images/splashlogo.png` diganti logo brand

OrangeFox (twres/pages/settings.xml + twres/themes/style.xml)
  - `logo_about` (logo besar di halaman Settings -> About) diganti logo brand
  - kartu maintainer dibuat selalu tampil, isinya nama + URL GitHub
  - `images/Default/About/maintainer.png` diganti logo brand

Pemakaian:
    python3 tools/brand_image.py --image vendor_boot.img
    python3 tools/brand_image.py --image in.img --out out.img --no-splash
"""

import argparse
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import vbimg2  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
PART_SIZE = 67108864


def decompress(data):
    if data[:4] == b"\x02\x21\x4c\x18":
        return vbimg2.lz4_legacy_decompress(data)
    return data


def entry_map(entries):
    return {e["name"]: e for e in entries}


def put(entries, name, body, mode=0o100644):
    """Tambah/ganti satu file di daftar cpio (sebelum TRAILER)."""
    idx = entry_map(entries)
    if name in idx:
        idx[name]["body"] = body
        idx[name]["vals"][1] = mode
        return "ganti"
    vals = [0, mode, 0, 0, 1, 0, len(body), 0, 0, 0, 0, len(name) + 1, 0]
    new = {"name": name, "body": body, "vals": vals}
    entries.insert(len(entries) - 1, new)
    return "baru"


def text(entries, name):
    e = entry_map(entries).get(name)
    if e is None:
        return None
    return e["body"].decode("utf-8", "replace")


def write_text(entries, name, s):
    e = entry_map(entries)[name]
    e["body"] = s.encode("utf-8")


# --------------------------------------------------------------------- TWRP ---
TWRP_RESOURCE = '''\t\t<!-- brand: logo maintainer -->
\t\t<image name="brand_logo" filename="brand_logo" retainaspect="1"/>
'''


def twrp_about_page(name, url):
    page = '''\t\t<!-- brand: halaman About (ditambahkan tools/brand_image.py) -->
\t\t<page name="about">
\t\t\t<template name="page"/>

\t\t\t<text style="text_l">
\t\t\t\t<placement x="%col1_x_header%" y="%row3_header_y%"/>
\t\t\t\t<text>{@about_hdr=About}</text>
\t\t\t</text>

\t\t\t<image>
\t\t\t\t<image resource="brand_logo"/>
\t\t\t\t<placement x="540" y="200" placement="4"/>
\t\t\t</image>

\t\t\t<text style="text_m">
\t\t\t\t<placement x="%col1_x_header%" y="700"/>
\t\t\t\t<text>@NAME@</text>
\t\t\t</text>

\t\t\t<text style="text_m">
\t\t\t\t<placement x="%col1_x_header%" y="766"/>
\t\t\t\t<text>@URL@</text>
\t\t\t</text>

\t\t\t<text style="text_s">
\t\t\t\t<placement x="%col1_x_header%" y="832"/>
\t\t\t\t<text>TWRP %tw_version%</text>
\t\t\t</text>

\t\t\t<button style="main_button_half_height">
\t\t\t\t<placement x="%center_x%" y="%row21a_y%"/>
\t\t\t\t<text>{@back_btn=Back}</text>
\t\t\t\t<action function="page">advanced</action>
\t\t\t</button>

\t\t\t<action>
\t\t\t\t<touch key="back"/>
\t\t\t\t<action function="page">advanced</action>
\t\t\t</action>
\t\t</page>

'''
    return page.replace("@NAME@", name).replace("@URL@", url)


def patch_twrp(entries, args):
    log = []

    ui = text(entries, "twres/ui.xml")
    if ui is None:
        raise SystemExit("twres/ui.xml tidak ada - bukan image TWRP?")
    if "brand_logo" not in ui:
        if "</resources>" not in ui:
            raise SystemExit("ui.xml: </resources> tidak ditemukan")
        ui = ui.replace("</resources>", TWRP_RESOURCE + "\t</resources>", 1)
        write_text(entries, "twres/ui.xml", ui)
        log.append("ui.xml: resource brand_logo")
    else:
        log.append("ui.xml: resource brand_logo sudah ada")

    pt = text(entries, "twres/portrait.xml")
    if pt is None:
        raise SystemExit("twres/portrait.xml tidak ada")
    if 'name="about"' not in pt:
        if "</pages>" not in pt:
            raise SystemExit("portrait.xml: </pages> tidak ditemukan")
        pt = pt.replace("</pages>", twrp_about_page(args.name, args.url) + "\t</pages>", 1)
        log.append("portrait.xml: halaman about")
    else:
        log.append("portrait.xml: halaman about sudah ada")

    # entri menu Advanced -> about
    if "brand: entri About" not in pt:
        m = re.search(r'(<page name="advanced">.*?)</page>', pt, re.S)
        if m:
            block = m.group(1)
            if "<listitem" in block:
                item = ('\t\t\t\t<listitem name="{@about_btn=About}">'
                        '<!-- brand: entri About -->\n'
                        '\t\t\t\t\t<action function="page">about</action>\n'
                        '\t\t\t\t</listitem>\n')
                new_block = block.replace("\t\t\t</listbox>", item + "\t\t\t</listbox>", 1)
                if new_block != block:
                    pt = pt.replace(block, new_block, 1)
                    log.append("portrait.xml: menu Advanced -> About")
                else:
                    log.append("portrait.xml: PERINGATAN listbox advanced tidak ketemu")
            else:
                log.append("portrait.xml: PERINGATAN tidak ada listitem di advanced")
        else:
            log.append("portrait.xml: PERINGATAN halaman advanced tidak ketemu")
    else:
        log.append("portrait.xml: entri About sudah ada")
    write_text(entries, "twres/portrait.xml", pt)

    log.append("images/brand_logo.png: %s" % put(
        entries, "twres/images/brand_logo.png", open(args.logo, "rb").read()))

    if args.splash:
        body = open(args.logo_splash, "rb").read()
        log.append("images/splashlogo.png: %s" % put(
            entries, "twres/images/splashlogo.png", body))
    return log


# ------------------------------------------------------------------ OFOX -----
def patch_ofox(entries, args):
    log = []

    st = text(entries, "twres/themes/style.xml")
    if st is None:
        raise SystemExit("twres/themes/style.xml tidak ada - bukan image OrangeFox?")
    if "Default/About/brand_logo" not in st:
        st = st.replace('filename="SVG/Logos/logo_o.svg"',
                        'filename="Default/About/brand_logo"', 1)
        write_text(entries, "twres/themes/style.xml", st)
        log.append("style.xml: logo_about -> brand_logo")
    else:
        log.append("style.xml: logo_about sudah brand_logo")

    body = open(args.logo_about, "rb").read()
    log.append("Default/About/brand_logo.png: %s" % put(
        entries, "twres/images/Default/About/brand_logo.png", body))
    log.append("Default/About/maintainer.png: %s" % put(
        entries, "twres/images/Default/About/maintainer.png", body))

    sx = text(entries, "twres/pages/settings.xml")
    if sx is None:
        raise SystemExit("twres/pages/settings.xml tidak ada")
    if args.name in sx and args.url in sx:
        log.append("settings.xml: kartu maintainer sudah dipatch")
        return log

    lines = sx.split("\n")
    start = next((i for i, l in enumerate(lines) if "<!-- Maintainer -->" in l), None)
    if start is None:
        log.append("settings.xml: PERINGATAN blok maintainer tidak ketemu")
        return log
    end = None
    for i in range(start, min(start + 60, len(lines))):
        if "abt_maintainer" in lines[i]:
            end = i
            break
    if end is None:
        log.append("settings.xml: PERINGATAN akhir blok maintainer tidak ketemu")
        return log

    out = []
    dropped = 0
    for i, line in enumerate(lines):
        if start <= i <= end and 'of_maintainer' in line and line.strip().startswith("<condition"):
            dropped += 1
            continue
        if start <= i <= end:
            line = line.replace("%of_maintainer%", args.name)
            line = line.replace("{@abt_maintainer}", args.url)
        out.append(line)
    write_text(entries, "twres/pages/settings.xml", "\n".join(out))
    log.append("settings.xml: kartu maintainer selalu tampil (%s / %s), %d condition dibuang"
               % (args.name, args.url, dropped))
    return log


# ------------------------------------------------------------------ main -----
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--image", required=True)
    ap.add_argument("--out", default="")
    ap.add_argument("--name", default="gbrsaski20")
    ap.add_argument("--url", default="github.com/gbrsaski20")
    ap.add_argument("--logo", default=os.path.join(REPO, "branding", "logo_mid.png"),
                    help="logo untuk halaman About TWRP")
    ap.add_argument("--logo-about", default=os.path.join(REPO, "branding", "logo_about.png"),
                    help="logo kecil untuk OrangeFox About")
    ap.add_argument("--logo-splash", default=os.path.join(REPO, "branding", "logo_mid.png"),
                    help="logo untuk splash TWRP")
    ap.add_argument("--no-splash", dest="splash", action="store_false",
                    help="jangan ganti splashlogo TWRP")
    args = ap.parse_args()

    for f in (args.logo, args.logo_about):
        if not os.path.exists(f):
            raise SystemExit("asset tidak ada: %s" % f)
    if args.splash and not os.path.exists(args.logo_splash):
        raise SystemExit("asset tidak ada: %s" % args.logo_splash)

    out = args.out or args.image
    info = vbimg2.parse_image(args.image)
    if len(info["frags"]) < 2:
        raise SystemExit("image tidak punya fragmen recovery")

    plat, rec = None, None
    for f in info["frags"]:
        if f["type"] == 2:
            rec = f
        else:
            plat = f
    if rec is None:
        raise SystemExit("fragmen recovery (type 2) tidak ada")

    entries = vbimg2.cpio_parse(decompress(rec["data"]))
    names = {e["name"] for e in entries}

    if "twres/pages/settings.xml" in names:
        flavour = "orangefox"
        log = patch_ofox(entries, args)
    elif "twres/portrait.xml" in names:
        flavour = "twrp"
        log = patch_twrp(entries, args)
    else:
        raise SystemExit("tema twres tidak dikenali (bukan TWRP/OrangeFox)")

    print("image   : %s (%s)" % (args.image, flavour))
    for l in log:
        print("  %s" % l)

    frags = [
        {"name": plat["name"], "type": plat["type"], "data": plat["data"]},
        {"name": rec["name"], "type": rec["type"],
         "data": vbimg2.lz4_legacy_compress(vbimg2.cpio_build(entries), 9)},
    ]
    size = vbimg2.build_image(info, frags, out)
    print("hasil   : %s (%d byte, sisa %d)" % (out, size, PART_SIZE - size))
    if size > PART_SIZE:
        raise SystemExit("GAGAL: image melebihi ukuran partisi vendor_boot")

    chk = vbimg2.parse_image(out)
    ents = vbimg2.cpio_parse(decompress([f for f in chk["frags"] if f["type"] == 2][0]["data"]))
    ok = "TRAILER!!!" in {e["name"] for e in ents}
    print("verifikasi: %s (%d entri)" % ("OK" if ok else "GAGAL", len(ents)))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
