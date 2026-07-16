#!/bin/bash
# Exercise A: multi-QP spurious-PHV matrix. 3 images (per-card) x RCN{off,on} x size{512,1M} x QP{2..64} + lat anchor.
set -u
export SSHPASS=amd123
declare -A DEV S1U S2U SRV
DEV[B1]=roce_benic1p1; S1U[B1]=42424650-5232-3534-3830-303136000000; S2U[B1]=42424650-5232-3534-3830-303330000000; SRV[B1]=2001:db8:1::1
DEV[B2]=roce_benic2p1; S1U[B2]=42424650-5232-3535-3230-303944000000; S2U[B2]=42424650-5232-3535-3230-304237000000; SRV[B2]=2001:db8:2::1
DEV[F]=roce_benic3p1;  S1U[F]=42424650-5232-3534-3830-303033000000;  S2U[F]=42424650-5232-3534-3830-303241000000;  SRV[F]=2001:db8:3::1
for img in B1 B2 F; do
  for rcn in off on; do
    bash /tmp/spur.sh ${img}_lat_${rcn} ${DEV[$img]} ${S1U[$img]} ${S2U[$img]} ${SRV[$img]} lat 1 2 $rcn
    for size in 512 1048576; do
      for qp in 2 4 8 16 32 64; do
        bash /tmp/spur.sh ${img}_bw_${rcn}_q${qp}_s${size} ${DEV[$img]} ${S1U[$img]} ${S2U[$img]} ${SRV[$img]} bw $qp $size $rcn
      done
    done
  done
  echo ">>> $img done $(date +%H:%M:%S)"
done
echo "===== ExerciseA DONE $(date) ====="
