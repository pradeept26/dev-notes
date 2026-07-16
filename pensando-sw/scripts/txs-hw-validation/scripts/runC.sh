#!/bin/bash
# Exercise C: IB latency size-sweep. Per card x RCN, ib_write_lat -a QP1.
set -u; export SSHPASS=amd123
declare -A DEV S1U S2U SRV
DEV[B1]=roce_benic1p1; S1U[B1]=42424650-5232-3534-3830-303136000000; S2U[B1]=42424650-5232-3534-3830-303330000000; SRV[B1]=2001:db8:1::1
DEV[B2]=roce_benic2p1; S1U[B2]=42424650-5232-3535-3230-303944000000; S2U[B2]=42424650-5232-3535-3230-304237000000; SRV[B2]=2001:db8:2::1
DEV[F]=roce_benic3p1;  S1U[F]=42424650-5232-3534-3830-303033000000;  S2U[F]=42424650-5232-3534-3830-303241000000;  SRV[F]=2001:db8:3::1
S1=10.30.75.198; S2=10.30.75.204; GID=2; PORT=18515
mkdir -p /tmp/results2/latsweep
s1(){ sshpass -e ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 ubuntu@$S1 "$@"; }
s2(){ sshpass -e ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 ubuntu@$S2 "$@"; }
for img in B1 B2 F; do
  for rcn in off on; do
    rc=disable; [ "$rcn" = on ] && rc=enable
    s1 "sudo nicctl update pipeline rdma congestion-control profile -p 0 --rcn $rc -c ${S1U[$img]} >/dev/null 2>&1"
    s2 "sudo nicctl update pipeline rdma congestion-control profile -p 0 --rcn $rc -c ${S2U[$img]} >/dev/null 2>&1"
    s1 "sudo killall -9 ib_write_lat 2>/dev/null"; s2 "sudo killall -9 ib_write_lat 2>/dev/null"; sleep 2
    CMD="ib_write_lat -d ${DEV[$img]} -x $GID --use_hugepages -i 1 -p $PORT -F -a -n 1000 --ipv6-addr"
    s1 "sudo nohup $CMD > /tmp/lsrv.log 2>&1 &"; sleep 6
    s2 "sudo timeout 900 $CMD ${SRV[$img]} > /tmp/lcli.log 2>&1"
    s2 "cat /tmp/lcli.log" > /tmp/results2/latsweep/${img}_${rcn}.log 2>&1
    echo "C $img rcn=$rcn done $(date +%H:%M:%S)"
  done
done
s1 "sudo killall -9 ib_write_lat 2>/dev/null"; s2 "sudo killall -9 ib_write_lat 2>/dev/null"
echo "===== ExerciseC DONE $(date) ====="
