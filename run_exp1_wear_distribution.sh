#!/bin/bash
# ============================================================================
# EXPERIMENT 1 — Wear flatness under the SAME fixed input  (20 runs each)
# ============================================================================
# Per professor's spec: feed EVERY algorithm the SAME fixed amount of host input
# (e.g. ~2G of writes) and compare how FLAT the resulting per-block erase-count
# distribution is (stddev_ec, lower = flatter). NO block is allowed to die here
# (death is exp2's job); the input is sized to stay below the first death so the
# comparison is a clean, equal-input snapshot. Repeated over RUNS independent
# seeds (different pre-worn positions + RNG + advancing trace start) for mean+/-std.
#
# IMPORTANT (threshold): EraseThreshold must be a REALISTIC value, NOT a huge one.
# WL's migration rate (lambda ~ 1/threshold) and RBPA's budget (threshold-EC) both
# scale with the threshold, so a huge threshold (e.g. 100000) silently disables
# WL/RBPA and makes the comparison meaningless. We therefore keep the same small
# threshold used in exp2 and cap the input below death.
#
#   Algorithms: 0 PAGE(baseline)  1 WL  2 RBPA  3 LA
#   Inputs    : gen (synthetic, larger io_size) AND looped Nexus5 trace
#   Per run, per (input,algo): seed -> ExperimentSeed (pre-worn + RBPA RNG),
#                              gen also varies randseed (workload).
#
# Output -> results/exp1_<ts>/
#   <input>/<algo>/run<NN>/{wl_snapshot.csv, wl_snapshot_init.csv, wl_summary.csv}
#   exp1_runs.csv          - one row per run (min/max/mean/stddev/wl_factor)
#   exp1_summary.txt       - mean & std of stddev_ec per (input,algo) over RUNS
#   exp1_representative.csv- the run whose stddev_ec is closest to the group mean
#                            (use THIS run's wl_snapshot.csv for the PPT heatmap)
# The huge per-run log.txt is deleted right after each run (kept only so the
# simulator's statistics() path emits the snapshot during the run).
# ============================================================================
set -u
SD="$HOME/SimpleSSD-Standalone"
BIN="$SD/simplessd-standalone"
GEN_BASE="$SD/config/sample.cfg"
TRC_BASE="$SD/config/trace.cfg"
SSD_BASE="$SD/simplessd/config/sample.cfg"
FITTED="$SD/trace_nexus5_fitted.txt"

RUNS=${RUNS:-20}
# SAME fixed input for every algorithm. Sized (by calibration, _cal_exp1.sh) to be
# the largest input where the baseline still does NOT die, which maximizes the
# wear-flatness separation while keeping it a clean equal-input, no-death snapshot.
GEN_IOSIZE="${GEN_IOSIZE:-800M}"   # gen: ~196k write-pages, baseline max_ec~95 (<100)
TRACE_IOLIMIT="${TRACE_IOLIMIT:-400000}"  # trace: baseline max_ec~920 (<1000)
# EraseThreshold must stay REALISTIC (a huge value silently disables WL/RBPA whose
# tuning scales with threshold). Trace uses a higher threshold to survive its
# bursty intro. These match exp2.
ERASE_THR_GEN="100"
ERASE_THR_TRC="1000"
PREWORN="0.3"
PREWORN_EC_RATIO="0.7"   # *threshold = pre-worn initial erase count (gen 70 / trace 700)

# --- Trace: ADVANCING-START (not the same front each run) -------------------
# Each run starts STEP lines later in a looped source and replays a FIXED number
# of requests (TRACE_IOLIMIT), so the 20 runs sweep sequentially through the trace
# while every run/algorithm sees the same input volume.
TRACE_SRC="/tmp/exp1_trace_src.txt"
[ -s "$TRACE_SRC" ] || cat "$FITTED" "$FITTED" "$FITTED" "$FITTED" "$FITTED" "$FITTED" > "$TRACE_SRC"
TRACE_L=$(wc -l < "$FITTED")
TRACE_STEP=$(( TRACE_L / RUNS ))

TS=$(date +"%Y%m%d_%H%M%S")
OUT="$SD/results/exp1_$TS"
mkdir -p "$OUT"
name_of(){ case "$1" in 0)echo baseline;;1)echo WL;;2)echo RBPA;;3)echo LA;;esac; }

RUNS_CSV="$OUT/exp1_runs.csv"
echo "input,algo,run,seed,min_ec,max_ec,mean_ec,stddev_ec,wl_factor" > "$RUNS_CSV"

run_one(){ # input mode seed run
  local input="$1" m="$2" seed="$3" rn="$4" algo dir simcfg ssd rt="" off
  algo=$(name_of "$m")
  dir="$OUT/$input/$algo/run$(printf '%02d' "$rn")"; mkdir -p "$dir"

  local thr; if [ "$input" = "gen" ]; then thr="$ERASE_THR_GEN"; else thr="$ERASE_THR_TRC"; fi
  ssd="/tmp/exp1_ssd_${input}_${m}.cfg"; cp "$SSD_BASE" "$ssd"
  sed -i "s/^EraseThreshold[[:space:]]*=.*/EraseThreshold = $thr/;
          s/^PrewornBlockRatio[[:space:]]*=.*/PrewornBlockRatio = $PREWORN/;
          s/^PrewornEraseRatio[[:space:]]*=.*/PrewornEraseRatio = $PREWORN_EC_RATIO/;
          s/^MappingMode[[:space:]]*=.*/MappingMode = $m/;
          s/^StopAtFirstDeath[[:space:]]*=.*/StopAtFirstDeath = 0/;
          s/^ExperimentSeed[[:space:]]*=.*/ExperimentSeed = $seed/" "$ssd"
  # Apply tuned knobs ONLY to the algorithm they belong to (everything else stays
  # exactly as before): WL (mode1) -> WLLambdaScale, RBPA (mode2) -> RBPAExponent.
  [ "$m" = 1 ] && [ -n "${WL_LAMBDA:-}" ] && sed -i "s/^WLLambdaScale[[:space:]]*=.*/WLLambdaScale = $WL_LAMBDA/" "$ssd"
  [ "$m" = 2 ] && [ -n "${RBPA_BETA:-}" ] && sed -i "s/^RBPAExponent[[:space:]]*=.*/RBPAExponent = $RBPA_BETA/" "$ssd"

  if [ "$input" = "gen" ]; then
    simcfg="/tmp/exp1_sim_gen_${m}.cfg"; cp "$GEN_BASE" "$simcfg"
    sed -i "s/^io_size = .*/io_size = $GEN_IOSIZE/;
            s/^randseed = .*/randseed = $((1000+seed))/" "$simcfg"
  else
    simcfg="/tmp/exp1_sim_trace_${m}.cfg"; cp "$TRC_BASE" "$simcfg"
    off=$(( (rn-1) * TRACE_STEP ))                 # advancing start offset
    rt="/tmp/exp1_rt_${m}.txt"
    tail -n +$((off+1)) "$TRACE_SRC" > "$rt"        # from offset; IOLimit caps the volume
    sed -i "s#^File = .*#File = $rt#;
            s/^IOLimit = .*/IOLimit = $TRACE_IOLIMIT/" "$simcfg"
  fi
  sed -i "s#^WLSummaryLogFile = .*#WLSummaryLogFile = $dir/wl_summary.csv#;
          s#^WLSnapshotLogFile = .*#WLSnapshotLogFile = $dir/wl_snapshot.csv#;
          s#^WLSnapshotInitLogFile = .*#WLSnapshotInitLogFile = $dir/wl_snapshot_init.csv#;
          s#^FirstDeathLogFile = .*#FirstDeathLogFile = $dir/first_death.csv#;
          s#^LogFile = .*#LogFile = $dir/log.txt#;
          s#^DebugLogFile = .*#DebugLogFile = #;
          s#^LatencyLogFile = .*#LatencyLogFile = #" "$simcfg"

  "$BIN" "$simcfg" "$ssd" "$dir" >"$dir/full.txt" 2>&1
  rm -f "$dir/log.txt"; [ -n "$rt" ] && rm -f "$rt"

  read mn mx me st wf < <(awk -F, '
    NR==1{for(i=1;i<=NF;i++)c[$i]=i;next}
    {mn=c["min_ec"]?$(c["min_ec"]):"";mx=c["max_ec"]?$(c["max_ec"]):"";
     me=c["mean_ec"]?$(c["mean_ec"]):"";st=c["stddev_ec"]?$(c["stddev_ec"]):"";
     wf=c["wl_factor"]?$(c["wl_factor"]):""}
    END{print mn,mx,me,st,wf}' "$dir/wl_summary.csv" 2>/dev/null)
  echo "$input,$algo,$rn,$seed,$mn,$mx,$me,$st,$wf" >> "$RUNS_CSV"
  echo ">>> exp1 $input $algo run$rn seed$seed  stddev=$st" >&2
}

for input in gen trace; do
  for m in 0 1 2 3; do
    for rn in $(seq 1 "$RUNS"); do run_one "$input" "$m" "$rn" "$rn"; done
  done
done

# ---- aggregate: mean & std of stddev_ec per (input,algo) -------------------
{ printf "%-8s %-9s %3s %12s %10s %8s %8s %8s\n" \
    "input" "algo" "N" "stddev_mean" "stddev_sd" "min_avg" "max_avg" "mean_avg"
  awk -F, 'NR>1{k=$1" "$2;n[k]++;s[k]+=$8;ss[k]+=$8*$8;mn[k]+=$5;mx[k]+=$6;me[k]+=$7}
    END{for(k in n){split(k,a," ");m=s[k]/n[k];v=ss[k]/n[k]-m*m;sd=(v>0)?sqrt(v):0;
          printf "%-8s %-9s %3d %12.2f %10.2f %8.1f %8.1f %8.1f\n",
                 a[1],a[2],n[k],m,sd,mn[k]/n[k],mx[k]/n[k],me[k]/n[k]}}' "$RUNS_CSV" | sort
} > "$OUT/exp1_summary.txt"

# ---- representative run per (input,algo): stddev_ec closest to group mean --
{ echo "input,algo,run,seed,stddev_ec,group_mean"
  awk -F, 'NR==FNR{ if(FNR>1){k=$1" "$2;n[k]++;s[k]+=$8} next }
    FNR==1{next}
    { k=$1" "$2;m=s[k]/n[k];d=($8>m)?$8-m:m-$8;
      if(!(k in bd)||d<bd[k]){bd[k]=d;br[k]=$1","$2","$3","$4","$8","m} }
    END{for(k in br)print br[k]}' "$RUNS_CSV" "$RUNS_CSV" | sort
} > "$OUT/exp1_representative.csv"

cat "$OUT/exp1_summary.txt"
echo "exp1 done ($RUNS runs/group) -> $OUT"
