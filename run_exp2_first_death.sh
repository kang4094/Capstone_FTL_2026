#!/bin/bash
# ============================================================================
# EXPERIMENT 2 — Host input processed until the FIRST block dies  (20 runs each)
# ============================================================================
# Measures how much host input each algorithm absorbs before the very first
# block reaches EraseThreshold (weakest-link endurance). Repeated over RUNS
# independent seeds so we report a mean +/- std. The run still continues past
# the first death and records full device end-of-life too (for reference).
#
#   Algorithms: 0 PAGE(baseline)  1 WL  2 RBPA  3 LA
#   Inputs    : gen (synthetic, large io_size ceiling) AND looped Nexus5 trace
#   Scenario  : EraseThreshold gen=100 / trace=1000 (trace needs headroom to
#               survive the bursty intro), PrewornBlockRatio=0.3, EraseRatio=0.7,
#               StopAtFirstDeath=1 -> the run halts the instant the first block
#               dies. seed -> ExperimentSeed (pre-worn + RBPA RNG); gen varies randseed.
#
# Output -> results/exp2_<ts>/
#   <input>/<algo>/run<NN>/{first_death.csv, wl_snapshot.csv, wl_snapshot_init.csv}
#   exp2_runs.csv    - one row per run (firstDeath_hostWr, deviceEOL_hostWr, dead)
#   exp2_summary.txt - mean & std of firstDeath_hostWr per (input,algo) over RUNS
# Higher firstDeath_hostWr = spread wear better before any single block gave out.
# ============================================================================
set -u
SD="$HOME/SimpleSSD-Standalone"
BIN="$SD/simplessd-standalone"
GEN_BASE="$SD/config/sample.cfg"
TRC_BASE="$SD/config/trace.cfg"
SSD_BASE="$SD/simplessd/config/sample.cfg"
FITTED="$SD/trace_nexus5_fitted.txt"

RUNS=${RUNS:-20}
GEN_IOSIZE="${GEN_IOSIZE:-8G}"   # ceiling; run actually stops at first death (well before)
ERASE_THR_GEN="100"
ERASE_THR_TRC="1000"
PREWORN="0.3"
PREWORN_EC_RATIO="0.7"   # *threshold = pre-worn initial erase count (gen 70 / trace 700)

# --- Trace: ADVANCING-START (not the same front each run) -------------------
# Each run starts STEP lines later in a long looped source and replays forward
# until the FIRST block dies, so the 20 runs sweep sequentially through the trace.
# Source is long (x6) because WL delays the first death almost to its own EOL.
TRACE_SRC="/tmp/exp2_trace_src.txt"
[ -s "$TRACE_SRC" ] || cat "$FITTED" "$FITTED" "$FITTED" "$FITTED" "$FITTED" "$FITTED" > "$TRACE_SRC"
TRACE_L=$(wc -l < "$FITTED")
TRACE_STEP=$(( TRACE_L / RUNS ))

TS=$(date +"%Y%m%d_%H%M%S")
OUT="$SD/results/exp2_$TS"
mkdir -p "$OUT"
name_of(){ case "$1" in 0)echo baseline;;1)echo WL;;2)echo RBPA;;3)echo LA;;esac; }

RUNS_CSV="$OUT/exp2_runs.csv"
echo "input,algo,run,seed,firstDeath_hostWr,dead" > "$RUNS_CSV"

run_one(){ # input mode seed run
  local input="$1" m="$2" seed="$3" rn="$4" algo dir simcfg ssd fd eolwr dead rt="" off
  algo=$(name_of "$m")
  dir="$OUT/$input/$algo/run$(printf '%02d' "$rn")"; mkdir -p "$dir"

  local thr; if [ "$input" = "gen" ]; then thr="$ERASE_THR_GEN"; else thr="$ERASE_THR_TRC"; fi
  ssd="/tmp/exp2_ssd_${input}_${m}.cfg"; cp "$SSD_BASE" "$ssd"
  sed -i "s/^EraseThreshold[[:space:]]*=.*/EraseThreshold = $thr/;
          s/^PrewornBlockRatio[[:space:]]*=.*/PrewornBlockRatio = $PREWORN/;
          s/^PrewornEraseRatio[[:space:]]*=.*/PrewornEraseRatio = $PREWORN_EC_RATIO/;
          s/^MappingMode[[:space:]]*=.*/MappingMode = $m/;
          s/^StopAtFirstDeath[[:space:]]*=.*/StopAtFirstDeath = 1/;
          s/^ExperimentSeed[[:space:]]*=.*/ExperimentSeed = $seed/" "$ssd"
  # Apply tuned knobs ONLY to the algorithm they belong to (everything else stays
  # exactly as before): WL (mode1) -> WLLambdaScale, RBPA (mode2) -> RBPAExponent.
  [ "$m" = 1 ] && [ -n "${WL_LAMBDA:-}" ] && sed -i "s/^WLLambdaScale[[:space:]]*=.*/WLLambdaScale = $WL_LAMBDA/" "$ssd"
  [ "$m" = 2 ] && [ -n "${RBPA_BETA:-}" ] && sed -i "s/^RBPAExponent[[:space:]]*=.*/RBPAExponent = $RBPA_BETA/" "$ssd"

  if [ "$input" = "gen" ]; then
    simcfg="/tmp/exp2_sim_gen_${m}.cfg"; cp "$GEN_BASE" "$simcfg"
    sed -i "s/^io_size = .*/io_size = $GEN_IOSIZE/;
            s/^randseed = .*/randseed = $((2000+seed))/" "$simcfg"
  else
    simcfg="/tmp/exp2_sim_trace_${m}.cfg"; cp "$TRC_BASE" "$simcfg"
    off=$(( (rn-1) * TRACE_STEP ))                 # advancing start offset
    rt="/tmp/exp2_rt_${m}.txt"
    tail -n +$((off+1)) "$TRACE_SRC" > "$rt"        # from offset to end -> until death
    sed -i "s#^File = .*#File = $rt#" "$simcfg"
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

  fd=$(awk -F, 'NR==2{print $2}' "$dir/first_death.csv" 2>/dev/null)
  dead=$(awk -F, 'NR>1 && $NF=="dead"{n++} END{print n+0}' "$dir/wl_snapshot.csv" 2>/dev/null)
  echo "$input,$algo,$rn,$seed,${fd:-},${dead:-0}" >> "$RUNS_CSV"
  echo ">>> exp2 $input $algo run$rn seed$seed  firstDeath=$fd" >&2
}

for input in gen trace; do
  for m in 0 1 2 3; do
    for rn in $(seq 1 "$RUNS"); do run_one "$input" "$m" "$rn" "$rn"; done
  done
done

# ---- aggregate: mean & std of firstDeath_hostWr per (input,algo) -----------
{ printf "%-8s %-9s %3s %16s %12s\n" \
    "input" "algo" "N" "firstDeath_mean" "firstDeath_sd"
  awk -F, 'NR>1 && $5!=""{k=$1" "$2;n[k]++;s[k]+=$5;ss[k]+=$5*$5}
    END{for(k in n){split(k,a," ");m=s[k]/n[k];v=ss[k]/n[k]-m*m;sd=(v>0)?sqrt(v):0;
          printf "%-8s %-9s %3d %16.0f %12.0f\n",a[1],a[2],n[k],m,sd}}' "$RUNS_CSV" | sort
} > "$OUT/exp2_summary.txt"

cat "$OUT/exp2_summary.txt"
echo "exp2 done ($RUNS runs/group) -> $OUT"
