#!/usr/bin/env python3
# Parse `nicctl show rdma queue-pair --rccl-data --used -j` output (file arg)
# and emit one line per QP: ts qp W cc_state qstate active disabled inactive outstanding
import sys, json
ts = sys.argv[1]
raw = open(sys.argv[2]).read().strip()
dec = json.JSONDecoder(); objs = []; i = 0
while i < len(raw):
    s = raw[i:].lstrip()
    if not s: break
    i = len(raw) - len(s)
    try:
        o, e = dec.raw_decode(raw[i:]); objs.append(o); i += e
    except Exception:
        break
def g(d, k, dflt='?'):
    return d.get(k, dflt) if isinstance(d, dict) else dflt
for o in objs:
    for nic in o.get('nic', []):
        for lif in nic.get('lif', []):
            for qp in lif.get('queue_pair', []):
                sp = qp.get('spec', {}); st = qp.get('status', {}).get('send_queue', {})
                tx = st.get('requester_tx_status', {}) or {}
                qid = g(sp, 'local_qp_id')
                W = g(tx, 'qp_cwnd_whole'); cc = g(tx, 'congestion_state'); qs = str(g(st, 'queue_state')).replace(' ', '_')
                a = g(tx, 'num_active_path'); d = g(tx, 'num_disabled_path'); ina = g(tx, 'num_inactive_path')
                try:
                    outs = int(g(tx, 'message_sequence_number', 0)) - int(g(tx, 'completion_sequence_number', 0))
                except Exception:
                    outs = '?'
                print(f"{ts} {qid} {W} {cc} {qs} {a} {d} {ina} {outs}")
