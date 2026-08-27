#!/usr/bin/env python3
# Parse a QP's --raw (rawfile) + path statistics -j (pstfile) for the qwnd->0 mechanism.
# argv: ts qp rawfile pstfile
import sys, re, json
ts, qp, rawf, pstf = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
raw = open(rawf).read()
pst = open(pstf).read()
def rv(name):
    m = re.search(rf'\b{re.escape(name)}\s*:\s*(0x[0-9a-fA-F]+|\d+)', raw)
    if not m: return None
    v = m.group(1); return int(v, 16) if v.startswith('0x') else int(v)
W = rv('sqcb1.qp_cwnd_whole'); frac = rv('sqcb1.qp_cwnd_fraction')
T = rv('sqcb1.qp_cwnd_whole_tx'); R = rv('sqcb1.qp_cwnd_whole_rx')
qmin = rv('sqcb0.qwnd_min'); ninact = rv('sqcb1.num_inactive_path')
ndis = rv('sqcb3.num_cnt_path_disabled'); nboot = rv('sqcb3.num_cnt_path_bootstrap')
cc = rv('sqcb0.congestion_state')
effW = (W + T - R) if None not in (W, T, R) else None
rto = inact = 0
try:
    dec = json.JSONDecoder(); i = 0; s = pst.strip()
    while i < len(s):
        t = s[i:].lstrip()
        if not t: break
        i = len(s) - len(t)
        o, e = dec.raw_decode(s[i:]); i += e
        def walk(x):
            global rto, inact
            if isinstance(x, dict):
                for k, v in x.items():
                    if k == 'num_rto_output_port_changes': rto += int(v)
                    elif k == 'num_inactive_output_port_changes': inact += int(v)
                    else: walk(v)
            elif isinstance(x, list):
                for y in x: walk(y)
        walk(o)
except Exception:
    rto = inact = '?'
bypass = 'YES' if (W is not None and qmin is not None and W < qmin) else 'no'
print(f"{ts} {qp} W={W} frac={frac} T={T} R={R} effW={effW} qmin={qmin} ninact={ninact} cc={cc} ndis={ndis} nboot={nboot} rto_oport={rto} inact_oport={inact} floor_bypassed={bypass}")
