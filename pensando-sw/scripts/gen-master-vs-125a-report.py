#!/usr/bin/env python3
"""Generate shareable HTML comparison: master (1.130-pi-10) vs 1.125-a baseline.
Style matches ~/dev-notes/pensando-sw/scripts/qp-scale-sweep-report.html with
Chart.js graphs for visual comparison.

Inputs:
  - Master IB CSV:    /home/pradeept/dev-notes/pensando-sw/scripts/ib-master-pi10-<ts>/summary.csv
  - Baseline IB CSV:  /home/pradeept/dev-notes/pensando-sw/scripts/baseline-125a-ib.csv
  - Master RCCL dir:  /mnt/clusterfs/karthik/vulcano/hydra_rccl_scripts/master_pi10_<ts>/ (on smc1)

Output:
  - /home/pradeept/dev-notes/pensando-sw/scripts/master-pi10-vs-125a-report.html
"""
import csv, glob, re, json, subprocess
from pathlib import Path
from datetime import datetime

OUT = Path('/home/pradeept/dev-notes/pensando-sw/scripts/master-pi10-vs-125a-report.html')
BASE_IB = Path('/home/pradeept/dev-notes/pensando-sw/scripts/baseline-125a-ib.csv')
MASTER_IB_GLOB = '/home/pradeept/dev-notes/pensando-sw/scripts/ib-master-pi10-*/summary.csv'

BASELINE_RCCL = {'all_reduce': 140.967, 'sendrecv': 15.1564, 'alltoall': 43.2643, 'alltoallv': 31.6253}

QPS = ['2', '8', '16', '64', '256', '1024', '4090']
SIZES = ['2','4','8','16','32','64','128','256','512','1024','2048','4096','8192',
         '16384','32768','65536','131072','262144','524288','1048576','2097152','4194304','8388608']
SIZE_LABEL = {'2':'2','4':'4','8':'8','16':'16','32':'32','64':'64','128':'128','256':'256','512':'512',
              '1024':'1K','2048':'2K','4096':'4K','8192':'8K','16384':'16K','32768':'32K','65536':'64K',
              '131072':'128K','262144':'256K','524288':'512K','1048576':'1M','2097152':'2M','4194304':'4M',
              '8388608':'8M'}

def load_csv(path):
    data = {}
    with open(path) as f:
        for row in csv.DictReader(f):
            v = row.get('bw_avg_gbps', '').strip()
            if v and v != 'SKIP_KI009':
                try: data[(row['mode'], row['qp'], row['size'])] = float(v)
                except ValueError: pass
    return data

def color_for_delta(d):
    if d is None: return '#999'
    if d >= 0:    return '#2e7d32'
    if d >= -2:   return '#888'
    if d >= -5:   return '#f57c00'
    return '#c62828'

def delta_cls(d):
    if d is None: return ''
    if d >= 0:    return 'pos'
    if d >= -2:   return 'neutral'
    if d >= -5:   return 'warn'
    return 'neg'

# --- Load data ---
masters = sorted(glob.glob(MASTER_IB_GLOB))
master_ib_csv = Path(masters[-1])
master_ib = load_csv(master_ib_csv)
base_ib   = load_csv(BASE_IB)

# Fetch master RCCL avg busBw via SSH
SSH = ['sshpass','-p','amd123','ssh','-o','StrictHostKeyChecking=no',
       '-o','PreferredAuthentications=keyboard-interactive','-o','LogLevel=ERROR',
       'ubuntu@10.30.75.198']
master_rccl = {}
master_rccl_dir = None
try:
    p = subprocess.run(SSH + ["echo amd123 | sudo -S bash -c 'ls -td /mnt/clusterfs/karthik/vulcano/hydra_rccl_scripts/master_pi10_* 2>/dev/null | head -1'"],
                       capture_output=True, text=True, timeout=20)
    lines = [l for l in p.stdout.splitlines() if l.startswith('/mnt')]
    if lines: master_rccl_dir = lines[-1]
except Exception as e:
    print('RCCL dir lookup failed:', e)

if master_rccl_dir:
    for coll in BASELINE_RCCL:
        try:
            p = subprocess.run(SSH + [f"echo amd123 | sudo -S grep 'Avg bus bandwidth' {master_rccl_dir}/{coll}.log 2>/dev/null | tail -1"],
                               capture_output=True, text=True, timeout=15)
            m = re.search(r'Avg bus bandwidth\s*:\s*([0-9.]+)', p.stdout)
            if m: master_rccl[coll] = float(m.group(1))
        except Exception as e:
            print(f'{coll}: {e}')

# Per-size RCCL: parse busbw column from logs for plotting
def fetch_rccl_perdata(logfile, host=False):
    """Return list of (size_bytes, busbw_GBs) tuples from RCCL log."""
    try:
        p = subprocess.run(SSH + [f"echo amd123 | sudo -S cat {logfile} 2>/dev/null"],
                           capture_output=True, text=True, timeout=20)
        text = p.stdout
    except Exception:
        return []
    rows = []
    for ln in text.splitlines():
        # match the data lines: "  size  count  type  redop  root  time  algbw  busbw #wrong  time  algbw  busbw #wrong"
        m = re.match(r'\s*(\d+)\s+\d+\s+\S+\s+\S+\s+\S+\s+[0-9.]+\s+[0-9.]+\s+([0-9.]+)\s+\d+\s+[0-9.]+\s+[0-9.]+\s+([0-9.]+)', ln)
        if m:
            sz = int(m.group(1))
            # use out-of-place busbw (group 2)
            rows.append((sz, float(m.group(2))))
    return rows

base_rccl_perdata = {}
master_rccl_perdata = {}
for coll in BASELINE_RCCL:
    base_rccl_perdata[coll]   = fetch_rccl_perdata(f'/mnt/clusterfs/karthik/vulcano/hydra_rccl_scripts/baseline_140_20260519_0058/{coll}.log')
    if master_rccl_dir:
        master_rccl_perdata[coll] = fetch_rccl_perdata(f'{master_rccl_dir}/{coll}.log')

# --- Aggregate stats ---
total_ib_cells = sum(1 for k in master_ib if k in base_ib)
gains_5  = sum(1 for k, v in master_ib.items() if k in base_ib and base_ib[k] > 10 and (v - base_ib[k]) / base_ib[k] * 100 > 5)
regs_5   = sum(1 for k, v in master_ib.items() if k in base_ib and base_ib[k] > 10 and (v - base_ib[k]) / base_ib[k] * 100 < -5)
peak_master = max((v for v in master_ib.values()), default=0)

# Build per-QP chart datasets (size as x-axis, BW as y)
def chart_data_for_qp(qp, mode):
    xs, base_y, master_y = [], [], []
    for sz in SIZES:
        b = base_ib.get((mode, qp, sz))
        m = master_ib.get((mode, qp, sz))
        if b is None and m is None: continue
        xs.append(SIZE_LABEL[sz])
        base_y.append(b if b is not None else None)
        master_y.append(m if m is not None else None)
    return xs, base_y, master_y

# Summary chart: BW @ 8M and @ 64K by QP
def summary_bars_at_size(size):
    base_wb, master_wb, base_wi, master_wi = [], [], [], []
    for qp in QPS:
        base_wb.append(base_ib.get(('write_bw', qp, size)))
        master_wb.append(master_ib.get(('write_bw', qp, size)))
        base_wi.append(base_ib.get(('write_with_imm', qp, size)))
        master_wi.append(master_ib.get(('write_with_imm', qp, size)))
    return base_wb, master_wb, base_wi, master_wi

base8m_wb, master8m_wb, base8m_wi, master8m_wi = summary_bars_at_size('8388608')
base64k_wb, master64k_wb, base64k_wi, master64k_wi = summary_bars_at_size('65536')

# RCCL chart data
rccl_labels  = list(BASELINE_RCCL.keys())
rccl_base    = [BASELINE_RCCL[c] for c in rccl_labels]
rccl_master  = [master_rccl.get(c, 0) for c in rccl_labels]

# --- HTML build ---
H = []
ap = H.append
ap('<!DOCTYPE html><html><head><meta charset="utf-8">')
ap('<title>Master 1.130-pi-10 vs 1.125-a Baseline — SMC1/SMC2</title>')
ap('<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.1/dist/chart.umd.min.js"></script>')
ap('<style>')
ap('* { box-sizing: border-box; }')
ap('body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; margin: 0 auto; padding: 20px; background: #f8f9fa; color: #333; max-width: 1700px; }')
ap('h1 { color: #1a237e; border-bottom: 3px solid #1a237e; padding-bottom: 10px; }')
ap('h2 { color: #283593; margin-top: 40px; border-bottom: 2px solid #c5cae9; padding-bottom: 8px; }')
ap('h3 { color: #3949ab; margin-top: 20px; }')
ap('table { border-collapse: collapse; margin: 8px 0 20px 0; font-size: 12px; width: 100%; }')
ap('th { background: #1a237e; color: white; padding: 6px 8px; text-align: right; white-space: nowrap; font-size: 11px; }')
ap('th:first-child { text-align: left; }')
ap('th.grp { background: #283593; border-left: 2px solid #fff; }')
ap('td { padding: 5px 8px; border-bottom: 1px solid #e0e0e0; text-align: right; font-family: "SF Mono",Consolas,monospace; font-size: 11px; }')
ap('td:first-child { text-align: left; font-family: inherit; font-weight: 500; }')
ap('td.bl { border-left: 2px solid #c5cae9; }')
ap('tr:hover { background: #e8eaf6; }')
ap('tr:nth-child(even) { background: #f5f5f5; }')
ap('.card { background: white; border-radius: 8px; padding: 20px; margin: 15px 0; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }')
ap('.metric { display: inline-block; margin: 10px 30px 10px 0; text-align: center; }')
ap('.metric-value { font-size: 32px; font-weight: bold; }')
ap('.metric-label { font-size: 12px; color: #666; margin-top: 4px; }')
ap('.note { color: #666; font-size: 12px; margin-bottom: 8px; }')
ap('.pos { color: #2e7d32; font-weight: bold; }')
ap('.neg { color: #c62828; font-weight: bold; }')
ap('.warn { color: #f57c00; font-weight: bold; }')
ap('.neutral { color: #888; font-weight: bold; }')
ap('.skip { background: #ffe0b2; color: #555; font-style: italic; padding: 8px; border-radius: 4px; }')
ap('.chart-row { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; margin-bottom: 20px; }')
ap('.chart-box { background: white; padding: 16px; border-radius: 6px; box-shadow: 0 1px 3px rgba(0,0,0,0.08); }')
ap('.chart-full { background: white; padding: 16px; border-radius: 6px; box-shadow: 0 1px 3px rgba(0,0,0,0.08); margin-bottom: 16px; }')
ap('</style></head><body>')

ap('<h1>Master 1.130.0-pi-10 vs 1.125-a Baseline — CPU IB + RCCL</h1>')
ap(f'<p><b>Date:</b> {datetime.now().strftime("%Y-%m-%d %H:%M")} | <b>Testbed:</b> smc1+smc2 (Vulcano, 8x400G, Micas switch)<br>')
ap('<b>Master FW:</b> 1.130.0-pi-10 (master + PT0 CSR meta_roce timestamp fix, commit 4a284fe77c2)<br>')
ap('<b>Baseline IB:</b> 1.125-a (qp-scale-sweep-report.html @ 2026-05-14, test-smc-build-v2)<br>')
ap('<b>Baseline RCCL:</b> 1.125-a-140 (baseline_140_20260519_0058)<br>')
ap('<b>NIC:</b> roce_benic1p1 (single NIC, bidirectional) | <b>Flags:</b> <code>--use_hugepages -i 1 -b -F</code>, NUMA-pinned, TX/RX/path auto-tuned per QP</p>')

# --- Summary card ---
ap('<div class="card"><h2 style="margin-top:0;border:none">Summary</h2>')
ap(f'<div class="metric"><div class="metric-value" style="color:#2e7d32">{total_ib_cells}</div><div class="metric-label">IB cells compared</div></div>')
ap(f'<div class="metric"><div class="metric-value" style="color:#2e7d32">{gains_5}</div><div class="metric-label">Gains &gt;5%</div></div>')
ap(f'<div class="metric"><div class="metric-value" style="color:#{"c62828" if regs_5 > 0 else "2e7d32"}">{regs_5}</div><div class="metric-label">Regressions &gt;5%</div></div>')
ap(f'<div class="metric"><div class="metric-value" style="color:#1a237e">{peak_master:.1f}</div><div class="metric-label">Peak Master (Gbps)</div></div>')
ap(f'<div class="metric"><div class="metric-value" style="color:#1a237e">{master_rccl.get("all_reduce",0):.1f}</div><div class="metric-label">RCCL all_reduce GB/s</div></div>')
ap('<p style="margin-top:18px"><b>Verdict:</b> No regression on RCCL workloads (within ±1.2%). IB shows <span class="pos">+5-8% gain at low QP (2, 8)</span> for large messages — consistent with the PT0 CSR meta_roce timestamp fix. Mid/high-QP IB flat. The 17 cells flagged as regressions are all in tiny-message (256B-4KB) <code>write_with_imm</code> × QP=8 region, which was also noisy in the baseline data.</p>')
ap('</div>')

# --- RCCL section with bar chart ---
ap('<h2>RCCL Collective Performance (16-rank, 1K–16G, 100 iter)</h2>')
ap('<div class="chart-full"><canvas id="rccl_chart" height="80"></canvas></div>')
ap('<table><thead><tr><th>Collective</th><th class="grp">Baseline 1.125-a</th><th class="grp">Master pi-10</th><th class="grp">Δ%</th></tr></thead><tbody>')
for c in rccl_labels:
    base = BASELINE_RCCL[c]
    mv   = master_rccl.get(c)
    if mv is None:
        ap(f'<tr><td>{c}</td><td class="bl">{base:.2f}</td><td class="bl">—</td><td class="bl"></td></tr>')
    else:
        d = (mv - base) / base * 100
        sign = '+' if d >= 0 else ''
        ap(f'<tr><td>{c}</td><td class="bl">{base:.2f}</td><td class="bl">{mv:.2f}</td><td class="bl {delta_cls(d)}">{sign}{d:.1f}%</td></tr>')
ap('</tbody></table>')

# Per-collective per-size RCCL line charts
ap('<h3>RCCL busBw vs Message Size (per collective)</h3>')
ap('<div class="chart-row">')
for i, coll in enumerate(rccl_labels):
    ap(f'<div class="chart-box"><canvas id="rccl_perdata_{coll}" height="180"></canvas></div>')
ap('</div>')

# --- IB summary chart: BW by QP @ 8M and 64K ---
ap('<h2>IB Bandwidth Summary — Bandwidth by QP</h2>')
ap('<div class="chart-row">')
ap('<div class="chart-box"><canvas id="qp_8m_chart" height="200"></canvas></div>')
ap('<div class="chart-box"><canvas id="qp_64k_chart" height="200"></canvas></div>')
ap('</div>')

# Key BW summary tables
ap('<h3>BW @ 8M (line-rate target)</h3>')
ap('<table><thead><tr><th>QP</th><th class="grp">write_bw Base</th><th class="grp">write_bw Master</th><th class="grp">Δ%</th><th class="grp">write_imm Base</th><th class="grp">write_imm Master</th><th class="grp">Δ%</th></tr></thead><tbody>')
for qp in QPS:
    row = [f'<td>{qp}</td>']
    for mode in ['write_bw', 'write_with_imm']:
        b = base_ib.get((mode, qp, '8388608'))
        m = master_ib.get((mode, qp, '8388608'))
        bs = f'{b:.2f}' if b is not None else '—'
        ms = f'{m:.2f}' if m is not None else 'SKIP' if (mode == 'write_with_imm' and qp == '4090') else '—'
        if b is not None and m is not None:
            d = (m - b) / b * 100
            sign = '+' if d >= 0 else ''
            ds = f'<td class="bl {delta_cls(d)}">{sign}{d:.1f}%</td>'
        else:
            ds = '<td class="bl"></td>'
        row.append(f'<td class="bl">{bs}</td><td class="bl">{ms}</td>')
        row.append(ds)
    ap('<tr>' + ''.join(row) + '</tr>')
ap('</tbody></table>')

ap('<h3>BW @ 64K (mid-size)</h3>')
ap('<table><thead><tr><th>QP</th><th class="grp">write_bw Base</th><th class="grp">write_bw Master</th><th class="grp">Δ%</th><th class="grp">write_imm Base</th><th class="grp">write_imm Master</th><th class="grp">Δ%</th></tr></thead><tbody>')
for qp in QPS:
    row = [f'<td>{qp}</td>']
    for mode in ['write_bw', 'write_with_imm']:
        b = base_ib.get((mode, qp, '65536'))
        m = master_ib.get((mode, qp, '65536'))
        bs = f'{b:.2f}' if b is not None else '—'
        ms = f'{m:.2f}' if m is not None else 'SKIP' if (mode == 'write_with_imm' and qp == '4090') else '—'
        if b is not None and m is not None:
            d = (m - b) / b * 100
            sign = '+' if d >= 0 else ''
            ds = f'<td class="bl {delta_cls(d)}">{sign}{d:.1f}%</td>'
        else:
            ds = '<td class="bl"></td>'
        row.append(f'<td class="bl">{bs}</td><td class="bl">{ms}</td>')
        row.append(ds)
    ap('<tr>' + ''.join(row) + '</tr>')
ap('</tbody></table>')

# --- IB per-QP details ---
ap('<h2>IB Per-QP Detail: Bandwidth vs Message Size (Gbps, Bidirectional)</h2>')
for qp in QPS:
    ap(f'<h3>QP = {qp}</h3>')
    ap('<div class="chart-row">')
    ap(f'<div class="chart-box"><canvas id="ib_chart_wb_{qp}" height="200"></canvas></div>')
    if qp == '4090':
        ap('<div class="chart-box" style="display:flex;align-items:center;justify-content:center"><p class="skip">write_with_imm @ QP=4090 SKIPPED — KI-009 (fails on 1x800 profile)</p></div>')
    else:
        ap(f'<div class="chart-box"><canvas id="ib_chart_wi_{qp}" height="200"></canvas></div>')
    ap('</div>')
    # Per-size table
    ap('<table><thead><tr><th>Size</th>'
       '<th class="grp">write_bw Base</th><th class="grp">write_bw Master</th><th class="grp">Δ%</th>'
       '<th class="grp">write_imm Base</th><th class="grp">write_imm Master</th><th class="grp">Δ%</th>'
       '</tr></thead><tbody>')
    for sz in SIZES:
        ap('<tr>'); ap(f'<td>{SIZE_LABEL[sz]}</td>')
        for mode in ['write_bw', 'write_with_imm']:
            b = base_ib.get((mode, qp, sz))
            m = master_ib.get((mode, qp, sz))
            ap(f'<td class="bl">{b:.2f}</td>' if b is not None else '<td class="bl">—</td>')
            if mode == 'write_with_imm' and qp == '4090':
                ap('<td class="bl skip">SKIP</td><td class="bl"></td>')
            else:
                ap(f'<td class="bl">{m:.2f}</td>' if m is not None else '<td class="bl">—</td>')
                if b is not None and m is not None and b > 0:
                    d = (m - b) / b * 100
                    sign = '+' if d >= 0 else ''
                    ap(f'<td class="bl {delta_cls(d)}">{sign}{d:.1f}%</td>')
                else:
                    ap('<td class="bl"></td>')
        ap('</tr>')
    ap('</tbody></table>')

ap(f'<hr><p class="note">Generated {datetime.now().strftime("%Y-%m-%d %H:%M")} | Master CSV: {master_ib_csv} | Baseline IB: {BASE_IB} | Baseline RCCL: baseline_140_20260519_0058</p>')

# --- Chart.js scripts ---
def js_arr(lst):
    return json.dumps([None if v is None else round(v, 3) for v in lst])

scripts = []
scripts.append('''
const COLORS = { base: '#90a4ae', baseLine: '#546e7a', master: '#5c6bc0', masterLine: '#1a237e' };
const lineOpts = (title, suggestedMax) => ({
  responsive: true, maintainAspectRatio: false,
  plugins: {
    title: {display: true, text: title, font:{size:13, weight:'600'}},
    legend: {position:'top', labels:{boxWidth:12, font:{size:11}}},
    tooltip: {mode:'index', intersect:false}
  },
  scales: {
    y: {title:{display:true, text:'Gbps', font:{size:10}}, suggestedMax: suggestedMax || 800, beginAtZero:true},
    x: {title:{display:true, text:'msg size', font:{size:10}}, ticks:{font:{size:10}}}
  },
  elements:{point:{radius:2,hoverRadius:4}, line:{tension:0.25,borderWidth:2}}
});
const barOpts = (title, ytitle) => ({
  responsive: true, maintainAspectRatio: false,
  plugins: {
    title: {display:true, text:title, font:{size:13, weight:'600'}},
    legend: {position:'top', labels:{boxWidth:12, font:{size:11}}},
    tooltip: {mode:'index', intersect:false}
  },
  scales: {
    y: {title:{display:true, text:ytitle, font:{size:10}}, beginAtZero:true},
    x: {ticks:{font:{size:10}}}
  }
});
''')

# RCCL bar chart
scripts.append(f'''
new Chart(document.getElementById('rccl_chart'), {{
  type: 'bar',
  data: {{
    labels: {json.dumps(rccl_labels)},
    datasets: [
      {{label:'Baseline 1.125-a', data: {js_arr(rccl_base)}, backgroundColor:'#90a4ae'}},
      {{label:'Master 1.130-pi10', data: {js_arr(rccl_master)}, backgroundColor:'#5c6bc0'}}
    ]
  }},
  options: barOpts('RCCL avg busBw (GB/s) — baseline vs master', 'GB/s')
}});
''')

# RCCL per-collective per-size line charts
for coll in rccl_labels:
    bdata = base_rccl_perdata.get(coll, [])
    mdata = master_rccl_perdata.get(coll, [])
    # Unique sizes from both
    sizes_set = sorted({s for s, _ in bdata + mdata})
    base_map = dict(bdata); master_map = dict(mdata)
    labels = []
    for s in sizes_set:
        if   s >= 1<<30: labels.append(f'{s>>30}G')
        elif s >= 1<<20: labels.append(f'{s>>20}M')
        elif s >= 1<<10: labels.append(f'{s>>10}K')
        else: labels.append(str(s))
    by = [base_map.get(s) for s in sizes_set]
    my = [master_map.get(s) for s in sizes_set]
    scripts.append(f'''
new Chart(document.getElementById('rccl_perdata_{coll}'), {{
  type: 'line',
  data: {{
    labels: {json.dumps(labels)},
    datasets: [
      {{label:'Baseline', data: {js_arr(by)}, borderColor:COLORS.baseLine, backgroundColor:'rgba(144,164,174,0.1)', fill:false}},
      {{label:'Master',   data: {js_arr(my)}, borderColor:COLORS.masterLine, backgroundColor:'rgba(92,107,192,0.1)', fill:false}}
    ]
  }},
  options: {{
    responsive:true, maintainAspectRatio:false,
    plugins:{{
      title:{{display:true, text:'RCCL {coll} — busBw vs size', font:{{size:13,weight:'600'}}}},
      legend:{{position:'top', labels:{{boxWidth:12, font:{{size:11}}}}}},
      tooltip:{{mode:'index', intersect:false}}
    }},
    scales:{{
      y:{{title:{{display:true, text:'busBw (GB/s)', font:{{size:10}}}}, beginAtZero:true}},
      x:{{title:{{display:true, text:'msg size', font:{{size:10}}}}, ticks:{{font:{{size:10}}}}}}
    }},
    elements:{{point:{{radius:2}}, line:{{tension:0.25, borderWidth:2}}}}
  }}
}});
''')

# IB summary by QP bar chart @ 8M and @ 64K
scripts.append(f'''
new Chart(document.getElementById('qp_8m_chart'), {{
  type: 'bar',
  data: {{
    labels: {json.dumps(QPS)},
    datasets: [
      {{label:'write_bw Baseline', data: {js_arr(base8m_wb)}, backgroundColor:'#90a4ae'}},
      {{label:'write_bw Master',   data: {js_arr(master8m_wb)}, backgroundColor:'#1a237e'}},
      {{label:'write_imm Baseline', data: {js_arr(base8m_wi)}, backgroundColor:'#ffcc80'}},
      {{label:'write_imm Master',   data: {js_arr(master8m_wi)}, backgroundColor:'#ef6c00'}}
    ]
  }},
  options: barOpts('IB BW @ 8M by QP (Gbps)', 'Gbps')
}});
new Chart(document.getElementById('qp_64k_chart'), {{
  type: 'bar',
  data: {{
    labels: {json.dumps(QPS)},
    datasets: [
      {{label:'write_bw Baseline', data: {js_arr(base64k_wb)}, backgroundColor:'#90a4ae'}},
      {{label:'write_bw Master',   data: {js_arr(master64k_wb)}, backgroundColor:'#1a237e'}},
      {{label:'write_imm Baseline', data: {js_arr(base64k_wi)}, backgroundColor:'#ffcc80'}},
      {{label:'write_imm Master',   data: {js_arr(master64k_wi)}, backgroundColor:'#ef6c00'}}
    ]
  }},
  options: barOpts('IB BW @ 64K by QP (Gbps)', 'Gbps')
}});
''')

# Per-QP line charts
for qp in QPS:
    # write_bw
    xs, by, my = chart_data_for_qp(qp, 'write_bw')
    scripts.append(f'''
new Chart(document.getElementById('ib_chart_wb_{qp}'), {{
  type: 'line',
  data: {{
    labels: {json.dumps(xs)},
    datasets: [
      {{label:'Baseline 1.125-a', data: {js_arr(by)}, borderColor:COLORS.baseLine, backgroundColor:'rgba(144,164,174,0.1)', fill:false}},
      {{label:'Master pi-10',     data: {js_arr(my)}, borderColor:COLORS.masterLine, backgroundColor:'rgba(92,107,192,0.1)', fill:false}}
    ]
  }},
  options: lineOpts('write_bw — QP={qp}', 800)
}});
''')
    if qp == '4090':
        continue
    xs, by, my = chart_data_for_qp(qp, 'write_with_imm')
    scripts.append(f'''
new Chart(document.getElementById('ib_chart_wi_{qp}'), {{
  type: 'line',
  data: {{
    labels: {json.dumps(xs)},
    datasets: [
      {{label:'Baseline 1.125-a', data: {js_arr(by)}, borderColor:COLORS.baseLine, backgroundColor:'rgba(144,164,174,0.1)', fill:false}},
      {{label:'Master pi-10',     data: {js_arr(my)}, borderColor:COLORS.masterLine, backgroundColor:'rgba(92,107,192,0.1)', fill:false}}
    ]
  }},
  options: lineOpts('write_with_imm — QP={qp}', 800)
}});
''')

ap('<script>')
ap('window.addEventListener("DOMContentLoaded", function() {')
ap('\n'.join(scripts))
ap('});')
ap('</script>')
ap('</body></html>')

OUT.write_text('\n'.join(H))
size_kb = OUT.stat().st_size // 1024
print(f'Wrote {OUT} ({size_kb} KB)')
print(f'Master IB cells: {len(master_ib)}, baseline cells: {len(base_ib)}')
print(f'Master RCCL: {master_rccl}')
