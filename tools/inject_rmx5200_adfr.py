#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Inject an ADFR (Adaptive Dynamic Frame Rate) block into the Realme GT8 Pro
(RMX5200) AE084 dvt02 panel node of a decompiled DTBO, cloning the ADFR
register protocol used by the same-board AC180 panel.

Encoding rule (derived from the stock AC180/AD296 nodes):
    register value = base_fps / target_fps - 1
    reg 0x84 = BIGDC family min-fps, reg 0x83 = HPWM + plain ADFR min-fps
    page = FF 5A A5 2D
"""
import re, sys

AE084 = "qcom,mdss_dsi_panel_AE084_P_3_A0033_dsc_cmd_dvt02"
PANEL_NAME = '"AE084 P 3 A0033 dsc cmd mode panel"'
PAGE = "0x4ff 0x5aa52d39 0x4000"
TAIL = "0x390000 0x4 0xff5aa500"

def brace_delta(s):
    return s.count('{') - s.count('}')

def scan_depths(lines):
    d=[]; cur=0
    for ln in lines:
        d.append(cur); cur += brace_delta(ln)
    return d

def find_block_end(lines, d, start):
    """Return the line index that closes the block opened at `start`.

    `d[i]` is the brace depth *before* line i, so the closing line of the
    block opened at `start` is the first line whose depth-after returns to
    d[start].
    """
    base = d[start]
    for i in range(start+1, len(lines)):
        if d[i] + brace_delta(lines[i]) == base:
            return i
    return None

def find_node(lines, d, name, must_have=None):
    pat = re.compile(r'^\s*' + re.escape(name) + r'\s*\{')
    for i,ln in enumerate(lines):
        if pat.match(ln):
            e = find_block_end(lines, d, i)
            if e is None: continue
            body = "\n".join(lines[i:e+1])
            if must_have and not all(m in body for m in must_have):
                continue
            return i, e
    return None, None

def minfps_block(indent, base_fps, targets, page, val_regs, tail):
    """val_regs: dict family->reg byte string"""
    out = []
    fams = [("bigdc", val_regs["bigdc"]), ("hpwm", val_regs["hpwm"]), ("", val_regs["adfr"])]
    # command-state batch
    for fam, _ in fams:
        fname = f"{fam}-adfr" if fam else "adfr"
        for i in range(6):
            out.append(f"{indent}qcom,mdss-dsi-{fname}-min-fps-{i}-command-state = \"dsi_hs_mode\";")
    # command batch
    for fam, reg in fams:
        fname = f"{fam}-adfr" if fam else "adfr"
        for i, tfps in enumerate(targets):
            val = base_fps // tfps - 1
            cmd = f"<0x39000040 {page} 0x3{reg}{val:02x} {tail}>"
            out.append(f"{indent}qcom,mdss-dsi-{fname}-min-fps-{i}-command = {cmd};")
    tbl = " ".join(f"0x{v:x}" for v in targets)
    out.append(f"{indent}oplus,adfr-min-fps-mapping-table = <{tbl}>;")
    return out

PANEL_PROPS = [
    "qcom,mdss-dsi-qsync-min-refresh-rate = <0x1e>;",
    "qcom,qsync-enable;",
    "oplus,adfr-test-te-gpio = <0xffffffff 0x56 0x0>;",
    "oplus,adfr-config = <0xe51>;",
]

TARGETS = {120: [120,60,30,20,10,1], 60: [60,40,30,20,10,1]}

def inject(text):
    lines = text.splitlines()
    d = scan_depths(lines)
    ps, pe = find_node(lines, d, AE084, must_have=[PANEL_NAME, "qcom,mdss-dsi-display-timings"])
    if ps is None:
        raise SystemExit("AE084 dvt02 panel node not found")
    # insert panel props right after the panel-name line
    pname_idx = next(i for i in range(ps, pe) if PANEL_NAME in lines[i])
    ind = re.match(r'^(\s*)', lines[pname_idx]).group(1)
    panel_props = [f"{ind}{p}" for p in PANEL_PROPS]
    lines[pname_idx+1:pname_idx+1] = panel_props
    # recompute depths and re-locate
    d = scan_depths(lines)
    ps, pe = find_node(lines, d, AE084, must_have=[PANEL_NAME, "qcom,mdss-dsi-display-timings"])
    ds = next(i for i in range(ps, pe) if re.match(r'^\s*qcom,mdss-dsi-display-timings\s*\{', lines[i]))
    de = find_block_end(lines, d, ds)
    # iterate timing children
    inserted = {}
    i = ds + 1
    # collect children first (need stable indices)
    children = []
    j = ds + 1
    while j < de:
        m = re.match(r'^(\s*)timing@(wqhd_sdc_(\d+))\s*\{', lines[j])
        if m:
            e = find_block_end(lines, d, j)
            children.append((m.group(3), m.group(1), j, e))
            j = e + 1
        else:
            j += 1
    # insert bottom-up so earlier indices stay valid
    for name, ind, cs, ce in reversed(children):
        fps = int(name)
        if fps not in TARGETS:
            continue
        blk = minfps_block(ind + "\t", fps, TARGETS[fps], PAGE,
                           {"bigdc": "84", "hpwm": "83", "adfr": "83"}, TAIL)
        lines[ce:ce] = blk
        inserted[name] = len(blk)
    return "\n".join(lines) + "\n", inserted

if __name__ == "__main__":
    src, dst = sys.argv[1], sys.argv[2]
    with open(src, 'r', encoding='utf-8', errors='replace') as f:
        t = f.read()
    out, ins = inject(t)
    with open(dst, 'w', encoding='utf-8', newline='\n') as f:
        f.write(out)
    print(f"{src} -> {dst}  inserted: {ins}")



