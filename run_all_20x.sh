#!/bin/bash
# Runs BOTH 20-run experiments back to back, in the background.
# Launch detached:  setsid nohup bash run_all_20x.sh >results/run20x.log 2>&1 </dev/null &

# cd "$HOME/SimpleSSD-Standalone" || exit 1 <-- 경로 수정함
cd "$(dirname "$0")" || exit 1

echo "===== START $(date) ====="
echo "[exp1] wear-flattening, 20 runs/group ..."
bash run_exp1_wear_distribution.sh
echo "===== EXP1 DONE $(date) ====="
echo "[exp2] first-death endurance, 20 runs/group ..."
bash run_exp2_first_death.sh
echo "===== EXP2 DONE $(date) ====="
echo "===== ALL DONE $(date) ====="
