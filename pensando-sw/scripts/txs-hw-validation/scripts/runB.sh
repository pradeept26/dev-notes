#!/bin/bash
# Exercise B: IB write BW msg-size sweep. Per card x RCN x QP{2..64}, ib_write_bw -a -n 10000 bidir.
set -u; export SSHPASS=amd123
declare -A DEV S1U S2U SRV
DEV[B1]=roce_benic1p1; S1U[B1]=42424650-5232-3534-3830-303136000000; S2U[B1]=42424650-5232-3534-3830-303330000000; SRV[B1]=2001:db8:1::1
DEV[B2]=roce_benic2p1; S1U[B2]=42424650-5232-3535-3230-303944000000; S2U[B2]=42424650-5232-3535-3230-304237000000; SRV[B2]=2001:db8:2::1
DEV[F]=roce_benic3p1;  S1U[F]=42424650-5232-3534-3830-303033000000;  S2U[F]=42424650-5232-3534-3830-303241000000;  SRV[F]=2001:db8:3::1
S1=10.30.75.198; S2=10.30.75.204; GID=2; PORT=18515
mkdir -p /tmp/results2/bwsweep
s1(){ sshpass -e ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 ubuntu@$S1 "$@"; }
s2(){ sshpass -e ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 ubuntu@$S2 "$@"; }
for img in B1 B2 F; do
  for rcn in off on; do
    rc=disable; [ "$rcn" = on ] && rc=enable
    s1 "sudo nicctl update pipeline rdma congestion-control profile -p 0 --rcn $rc -c ${S1U[$img]} >/dev/null 2>&1"
    s2 "sudo nicctl update pipeline rdma congestion-control profile -p 0 --rcn $rc -c ${S2U[$img]} >/dev/null 2>&1"
    for qp in 2 4 8 16 32 64; do
      s1 "sudo killall -9 ib_write_bw 2>/dev/null"; s2 "sudo killall -9 ib_write_bw 2>/dev/null"; sleep 2
      CMD="ib_write_bw -d ${DEV[$img]} -x $GID --use_hugepages -i 1 --report_gbits -p $PORT -F -q $qp -t 128 -r 512 -a -n 10000 -b --ipv6-addr"
      s1 "sudo nohup $CMD > /tmp/bsrv.log 2>&1 &"; sleep 6
      s2 "sudo timeout 1200 $CMD ${SRV[$img]} > /tmp/bcli.log 2>&1"
      s2 "cat /tmp/bcli.log" > /tmp/results2/bwsweep/${img}_${rcn}_q${qp}.log 2>&1
      bwmax=$(grep -E "^[[:space:]]*[0-9]+[[:space:]]" /tmp/results2/bwsweep/${img}_${rcn}_q${qp}.log | awk '{print $4}' | sort -n | tail -1)
      echo "B $img rcn=$rcn qp=$qp peakBW=${bwmax:-NA} $(date +%H:%M:%S)"
    done
  done
done
s1 "sudo killall -9 ib_write_bw 2>/dev/null"; s2 "sudo killall -9 ib_write_bw 2>/dev/null"
echo "===== ExerciseB DONE $(date) ====="
