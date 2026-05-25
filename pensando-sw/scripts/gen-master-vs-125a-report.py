#!/usr/bin/env python3
"""Generate HTML comparison report: master (1.130-pi-10) vs 1.125-a baseline.
Inputs:
  - Master IB CSV:    /home/pradeept/dev-notes/pensando-sw/scripts/ib-master-pi10-<ts>/summary.csv
  - Baseline IB CSV:  /home/pradeept/dev-notes/pensando-sw/scripts/baseline-125a-ib.csv
  - Master RCCL dir:  /mnt/clusterfs/karthik/vulcano/hydra_rccl_scripts/master_pi10_<ts>/ (on smc1)
  - Baseline RCCL dir: same dir, baseline_140_20260519_0058/
Output:
  - /home/pradeept/dev-notes/pensando-sw/scripts/master-pi10-vs-125a-report.html
"""
import csv, glob, re, sys, subprocess
from pathlib import Path

OUT = Path('/home/pradeept/dev-notes/pensando-sw/scripts/master-pi10-vs-125a-report.html')
BASE_IB = Path('/home/pradeept/dev-notes/pensando-sw/scripts/baseline-125a-ib.csv')
MASTER_IB_GLOB = '/home/pradeept/dev-notes/pensando-sw/scripts/ib-master-pi10-*/summary.csv'

# Baseline RCCL (parsed earlier from logs)
BASELINE_RCCL = {
    'all_reduce': 140.967,
    'sendrecv':    15.1564,
    'alltoall':    43.2643,
    'alltoallv':   31.6253,
}

QPS = ['2', '8', '16', '64', '256', '1024', '4090']
SIZES = ['2','4','8','16','32','64','128','256','512','1024','2048','4096','8192',
         '16384','32768','65536','131072','262144','524288','1048576','2097152','4194304','8388608']
SIZE_LABEL = {'2':'2B','4':'4B','8':'8B','16':'16B','32':'32B','64':'64B','128':'128B','256':'256B','512':'512B',
              '1024':'1K','2048':'2K','4096':'4K','8192':'8K','16384':'16K','32768':'32K','65536':'64K',
              '131072':'128K','262144':'256K','524288':'512K','1048576':'1M','2097152':'2M','4194304':'4M',
              '8388608':'8M'}

def load_csv(path, cols):
    """Load CSV into dict keyed by (mode,qp,size) -> bw"""
    data = {}
    with open(path) as f:
        r = csv.DictReader(f)
        for row in r:
            key = (row['mode'], row['qp'], row['size'])
            v = row.get('bw_avg_gbps', '').strip()
            if v and v != 'SKIP_KI009':
                try: data[key] = float(v)
                except: pass
    return data

def color_for_delta(d):
    if d is None: return '#999'
    if d >= 0: return '#2e7d32'  # green
    if d >= -2: return '#888'
    if d >= -5: return '#f57c00'  # warn
    return '#c62828'  # red

def fmt_delta(master, base):
    if master is None or base is None or base == 0:
        return '<td></td>'
    d = (master - base) / base * 100
    col = color_for_delta(d)
    sign = '+' if d >= 0 else ''
    return f'<td style="color:{col};font-weight:bold">{sign}{d:.1f}%</td>'

def fmt_bw(v):
    if v is None: return '<td>—</td>'
    return f'<td>{v:.2f}</td>'

# === Find master IB CSV (latest) ===
masters = sorted(glob.glob(MASTER_IB_GLOB))
if not masters:
    print('No master IB CSV found')
    sys.exit(1)
master_ib_csv = Path(masters[-1])
master_ib = load_csv(master_ib_csv, ['mode','qp','size','bw_avg_gbps'])
base_ib = load_csv(BASE_IB, ['mode','qp','size','bw_avg_gbps'])

# === Fetch master RCCL via SSH ===
SSH = ['sshpass','-p','amd123','ssh','-o','StrictHostKeyChecking=no',
       '-o','PreferredAuthentications=keyboard-interactive','-o','LogLevel=ERROR',
       'ubuntu@10.30.75.198']
master_rccl = {}
master_rccl_dir = None
try:
    p = subprocess.run(SSH + ['echo amd123 | sudo -S bash -c \'ls -td /mnt/clusterfs/karthik/vulcano/hydra_rccl_scripts/master_pi10_* 2>/dev/null | head -1\''],
                       capture_output=True, text=True, timeout=20)
    master_rccl_dir = p.stdout.strip().splitlines()[-1] if p.stdout else None
except Exception as e:
    print(f'Warning: could not find master RCCL dir: {e}')

if master_rccl_dir:
    print(f'Master RCCL dir: {master_rccl_dir}')
    for coll in BASELINE_RCCL:
        try:
            p = subprocess.run(SSH + [f'echo amd123 | sudo -S grep "Avg bus bandwidth" {master_rccl_dir}/{coll}.log 2>/dev/null | tail -1'],
                              capture_output=True, text=True, timeout=15)
            m = re.search(r'Avg bus bandwidth\s*:\s*([0-9.]+)', p.stdout)
            if m: master_rccl[coll] = float(m.group(1))
        except Exception as e:
            print(f'  {coll}: {e}')

# === Build HTML ===
html = ['<!DOCTYPE html><html><head><meta charset="utf-8">',
'<title>Master 1.130-pi-10 vs 1.125-a Baseline</title>',
'<style>',
'body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; max-width: 1800px; margin: 0 auto; padding: 20px; background: #f8f9fa; }',
'h1 { color: #1a237e; border-bottom: 3px solid #1a237e; padding-bottom: 10px; }',
'h2 { color: #283593; margin-top: 30px; border-bottom: 2px solid #c5cae9; padding-bottom: 6px; }',
'h3 { color: #3949ab; margin-top: 16px; }',
'table { border-collapse: collapse; width: 100%; margin: 8px 0 20px 0; font-size: 12px; }',
'th { background: #1a237e; color: white; padding: 6px 8px; text-align: right; font-size: 11px; white-space: nowrap; }',
'th:first-child { text-align: left; }',
'td { padding: 4px 8px; border-bottom: 1px solid #e0e0e0; text-align: right; font-family: "SF Mono",Consolas,monospace; font-size: 11px; }',
'td:first-child { text-align: left; font-family: inherit; font-weight: 500; }',
'tr:nth-child(even) { background: #fafafa; }',
'tr:hover { background: #e8eaf6; }',
'.card { background: white; border-radius: 8px; padding: 18px; margin: 12px 0; box-shadow: 0 2px 4px rgba(0,0,0,0.08); }',
'.metric { display: inline-block; margin: 10px 30px 10px 0; text-align: center; }',
'.metric-value { font-size: 32px; font-weight: bold; }',
'.metric-label { font-size: 12px; color: #666; }',
'.bl { border-left: 2px solid #c5cae9; }',
'.skip { background: #ffe0b2; color: #555; font-style: italic; }',
'</style></head><body>',
f'<h1>Master 1.130.0-pi-10 vs 1.125-a Baseline — SMC1/SMC2 CPU IB + RCCL</h1>',
f'<p><b>Testbed:</b> smc1 (10.30.75.198) + smc2 (10.30.75.204), Vulcano 8x400G, Micas switch<br>',
f'<b>Master FW:</b> 1.130.0-pi-10 (master + PT0 CSR meta_roce timestamp fix)<br>',
f'<b>Baseline:</b> 1.125-a (qp-scale-sweep-report.html @ 2026-05-14) + baseline_140 (FW 1.125-a-140 @ 2026-05-19)<br>',
f'<b>NIC:</b> roce_benic1p1 (single NIC, bidirectional, CPU memory)<br>',
f'<b>Master IB CSV:</b> {master_ib_csv}</p>',
]

# === RCCL Section ===
html.append('<div class="card"><h2 style="margin-top:0;border:none">RCCL (16-rank, 1K-16G, 100 iter, 5 warmup)</h2>')
html.append('<table><thead><tr><th>Collective</th><th class="bl">Baseline 1.125-a (GB/s)</th><th class="bl">Master 1.130-pi10 (GB/s)</th><th class="bl">Δ%</th></tr></thead><tbody>')
for coll, base in BASELINE_RCCL.items():
    m = master_rccl.get(coll)
    if m is None:
        html.append(f'<tr><td>{coll}</td><td class="bl">{base:.2f}</td><td class="bl skip">running…</td><td class="bl"></td></tr>')
    else:
        d = (m - base) / base * 100
        col = color_for_delta(d)
        sign = '+' if d >= 0 else ''
        html.append(f'<tr><td>{coll}</td><td class="bl">{base:.2f}</td><td class="bl">{m:.2f}</td><td class="bl" style="color:{col};font-weight:bold">{sign}{d:.1f}%</td></tr>')
html.append('</tbody></table></div>')

# === IB per-QP sections ===
html.append('<h2>IB CPU write_bw — bidirectional</h2>')
for qp in QPS:
    html.append(f'<h3>QP = {qp}</h3>')
    html.append('<table><thead><tr><th>Size</th><th class="bl">Base 1.125-a (Gbps)</th><th class="bl">Master pi-10 (Gbps)</th><th class="bl">Δ%</th></tr></thead><tbody>')
    for sz in SIZES:
        base = base_ib.get(('write_bw', qp, sz))
        master = master_ib.get(('write_bw', qp, sz))
        html.append('<tr>')
        html.append(f'<td>{SIZE_LABEL[sz]}</td>')
        html.append(fmt_bw(base).replace('<td>', '<td class="bl">'))
        html.append(fmt_bw(master).replace('<td>', '<td class="bl">'))
        # delta
        if base is None or master is None or base == 0:
            html.append('<td class="bl"></td>')
        else:
            d = (master - base) / base * 100
            col = color_for_delta(d)
            sign = '+' if d >= 0 else ''
            html.append(f'<td class="bl" style="color:{col};font-weight:bold">{sign}{d:.1f}%</td>')
        html.append('</tr>')
    html.append('</tbody></table>')

html.append('<h2>IB CPU write_with_imm — bidirectional</h2>')
for qp in QPS:
    html.append(f'<h3>QP = {qp}</h3>')
    if qp == '4090':
        html.append('<p class="skip" style="padding:8px;background:#ffe0b2">SKIPPED — KI-009: write_with_imm fails at 4090 QPs on 1x800 profile</p>')
        continue
    html.append('<table><thead><tr><th>Size</th><th class="bl">Base 1.125-a (Gbps)</th><th class="bl">Master pi-10 (Gbps)</th><th class="bl">Δ%</th></tr></thead><tbody>')
    for sz in SIZES:
        base = base_ib.get(('write_with_imm', qp, sz))
        master = master_ib.get(('write_with_imm', qp, sz))
        html.append('<tr>')
        html.append(f'<td>{SIZE_LABEL[sz]}</td>')
        html.append(fmt_bw(base).replace('<td>', '<td class="bl">'))
        html.append(fmt_bw(master).replace('<td>', '<td class="bl">'))
        if base is None or master is None or base == 0:
            html.append('<td class="bl"></td>')
        else:
            d = (master - base) / base * 100
            col = color_for_delta(d)
            sign = '+' if d >= 0 else ''
            html.append(f'<td class="bl" style="color:{col};font-weight:bold">{sign}{d:.1f}%</td>')
        html.append('</tr>')
    html.append('</tbody></table>')

html.append('<hr><p style="color:#999;font-size:11px">Generated by gen-master-vs-125a-report.py | Color: green ≥0%, gray -2..0%, orange -2..-5%, red &lt;-5%</p>')
html.append('</body></html>')

OUT.write_text('\n'.join(html))
print(f'Wrote {OUT}')
print(f'Master IB cells: {len(master_ib)}')
print(f'Master RCCL: {master_rccl}')
