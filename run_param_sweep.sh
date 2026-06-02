#!/bin/bash
# ============================================================================
# PARAMETER SWEEP — tune WLLambdaScale (WL) and RBPAExponent / beta (RBPA)
# to MAXIMIZE endurance = host input until the FIRST block dies.
# ============================================================================
# Objective: first-death host write-pages (higher = better). This is the real
# wear-leveling goal (lifetime / weakest-link), and it automatically prices in
# the cost of being aggressive (extra erases / write amplification), so the best
# value sits at an interior peak rather than at "maximally flat".
#
# We sweep ONE knob per algorithm, all else fixed, over RUNS independent seeds
# (paired: every knob value sees the same seed set) -> mean +/- std per value.
# Scenario is identical to exp2 (StopAtFirstDeath=1; gen thr100 / trace thr1000;
# preworn 0.3 @ 0.7*threshold; advancing trace start).
#
# Output -> results/sweep_<ts>/
#   sweep_runs.csv    : one row per run (param,value,input,run,seed,firstDeath)
#   sweep_summary.txt : firstDeath mean & std per (param,input,value) -> the curve
# Read the curve: the value with the highest firstDeath_mean wins; check that the
# winner is robust across BOTH inputs (gen & trace), not just one.
# ============================================================================
set -u
SD="$HOME/SimpleSSD-Standalone"
BIN="$SD/simplessd-standalone"
GEN_BASE="$SD/config/sample.cfg"
TRC_BASE="$SD/config/trace.cfg"
SSD_BASE="$SD/simplessd/config/sample.cfg"
FITTED="$SD/trace_nexus5_fitted.txt"

RUNS=${RUNS:-8}
GEN_IOSIZE="8G"          # ceiling; run stops at first death well before this
PREWORN="0.3"
PREWORN_EC_RATIO="0.7"
LAMBDA_VALS="${LAMBDA_VALS:-0 0.5 1 2 4}"   # WLLambdaScale (WL victim wear-bias)
BETA_VALS="${BETA_VALS:-0 0.5 1 2 4}"       # RBPAExponent (alloc aggressiveness)

# Trace source long enough that even aggressive settings reach first death
# (higher lambda delays death -> needs more input). x8 of the fitted trace.
TRACE_SRC="/tmp/sweep_trace_src.txt"
[ -s "$TRACE_SRC" ] || cat "$FITTED" "$FITTED" "$FITTED" "$FITTED" \
                           "$FITTED" "$FITTED" "$FITTED" "$FITTED" > "$TRACE_SRC"
TRACE_L=$(wc -l < "$FITTED")
TRACE_STEP=$(( TRACE_L / RUNS ))

TS=$(date +"%Y%m%d_%H%M%S")
OUT="$SD/results/sweep_$TS"; mkdir -p "$OUT"
RUNS_CSV="$OUT/sweep_runs.csv"
echo "param,value,input,run,seed,firstDeath_hostWr" > "$RUNS_CSV"

run_one(){ # param value mode input run seed
  local param="$1" val="$2" m="$3" input="$4" rn="$5" seed="$6" thr dir simcfg ssd off rt=""
  if [ "$input" = gen ]; then thr=100; else thr=1000; fi
  dir="$OUT/$param/v$val/$input/run$(printf '%02d' "$rn")"; mkdir -p "$dir"
  ssd="/tmp/sw_ssd_${param}_${input}.cfg"; cp "$SSD_BASE" "$ssd"
  sed -i "s/^EraseThreshold[[:space:]]*=.*/EraseThreshold = $thr/;
          s/^PrewornBlockRatio[[:space:]]*=.*/PrewornBlockRatio = $PREWORN/;
          s/^PrewornEraseRatio[[:space:]]*=.*/PrewornEraseRatio = $PREWORN_EC_RATIO/;
          s/^MappingMode[[:space:]]*=.*/MappingMode = $m/;
          s/^StopAtFirstDeath[[:space:]]*=.*/StopAtFirstDeath = 1/;
          s/^ExperimentSeed[[:space:]]*=.*/ExperimentSeed = $seed/" "$ssd"
  if [ "$param" = lambda ]; then
    sed -i "s/^WLLambdaScale[[:space:]]*=.*/WLLambdaScale = $val/" "$ssd"
  else
    sed -i "s/^RBPAExponent[[:space:]]*=.*/RBPAExponent = $val/" "$ssd"
  fi
  if [ "$input" = gen ]; then
    simcfg="/tmp/sw_sim_${param}_gen.cfg"; cp "$GEN_BASE" "$simcfg"
    sed -i "s/^io_size = .*/io_size = $GEN_IOSIZE/; s/^randseed = .*/randseed = $((2000+seed))/" "$simcfg"
  else
    simcfg="/tmp/sw_sim_${param}_trace.cfg"; cp "$TRC_BASE" "$simcfg"
    off=$(( (rn-1) * TRACE_STEP )); rt="/tmp/sw_rt_${param}.txt"
    tail -n +$((off+1)) "$TRACE_SRC" > "$rt"
    sed -i "s#^File = .*#File = $rt#; s/^IOLimit = .*/IOLimit = 0/" "$simcfg"
  fi
  sed -i "s#^WLSummaryLogFile = .*#WLSummaryLogFile = $dir/wl_summary.csv#;
          s#^WLSnapshotLogFile = .*#WLSnapshotLogFile = $dir/wl_snapshot.csv#;
          s#^WLSnapshotInitLogFile = .*#WLSnapshotInitLogFile = $dir/wl_snapshot_init.csv#;
          s#^FirstDeathLogFile = .*#FirstDeathLogFile = $dir/first_death.csv#;
          s#^LogFile = .*#LogFile = $dir/log.txt#; s#^DebugLogFile = .*#DebugLogFile = #;
          s#^LatencyLogFile = .*#LatencyLogFile = #" "$simcfg"
  "$BIN" "$simcfg" "$ssd" "$dir" > "$dir/full.txt" 2>&1
  rm -f "$dir/log.txt"; [ -n "$rt" ] && rm -f "$rt"
  local fd; fd=$(awk -F, 'NR==2{print $2}' "$dir/first_death.csv" 2>/dev/null)
  echo "$param,$val,$input,$rn,$seed,${fd:-}" >> "$RUNS_CSV"
  echo ">>> $param=$val $input run$rn seed$seed firstDeath=$fd" >&2
}

echo "===== SWEEP START $(date) (RUNS=$RUNS) ====="
for val in $LAMBDA_VALS; do
  for input in gen trace; do
    for rn in $(seq 1 "$RUNS"); do run_one lambda "$val" 1 "$input" "$rn" "$rn"; done
  done
done
for val in $BETA_VALS; do
  for input in gen trace; do
    for rn in $(seq 1 "$RUNS"); do run_one beta "$val" 2 "$input" "$rn" "$rn"; done
  done
done

{ printf "%-7s %-6s %-6s %3s %16s %12s\n" param value input N firstDeath_mean firstDeath_sd
  awk -F, 'NR>1 && $6!=""{k=$1"|"$2"|"$3;n[k]++;s[k]+=$6;ss[k]+=$6*$6}
    END{for(k in n){split(k,a,"|");m=s[k]/n[k];v=ss[k]/n[k]-m*m;sd=(v>0)?sqrt(v):0;
      printf "%-7s %-6s %-6s %3d %16.0f %12.0f\n",a[1],a[2],a[3],n[k],m,sd}}' "$RUNS_CSV" \
  | sort -k1,1 -k3,3 -k2,2n
} > "$OUT/sweep_summary.txt"
cat "$OUT/sweep_summary.txt"
echo "===== SWEEP DONE $(date) -> $OUT ====="
