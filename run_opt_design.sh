#!/bin/bash
# ============================================================================
# OPTIMAL lambda / beta — rigorous, multi-variable  (autopilot stage 1)
# ============================================================================
# (1) Measured at the FIRST block death (StopAtFirstDeath=1).
# (2) Rigor: a MATRIX of conditions = {workload} x {preworn severity} x {seeds}.
# (3) NOT write-only: each run records many variables from the last periodic
#     statistics block the simulator writes to LogFile before it exits:
#       endurance = host write pages to first death (first_death.csv)        [up]
#       WAF       = pal.program.count / write.request_count                  [down]
#       gc_count, gc_page_copies, wl_migration_count                         [down]
#       wear_leveling factor, energy_uJ (pal.energy.total)                   [down]
#       wbusy/req = write.busy / write.request_count (service-time proxy)    [down]
#       erase_count, stddev_ec, mean_ec (wear dist. at death)                [down]
#
# Conditions:
#   gen   x {light 0.3@0.5, med 0.3@0.7, heavy 0.5@0.8}   (EraseThreshold 100)
#   trace x {med 0.3@0.7, heavy 0.5@0.8}                  (EraseThreshold 1000)
#   (trace light is skipped: very durable -> unreliable to reach death unattended)
# Grids: lambda(WL,mode1) {0 0.5 1 2 3 4 6}   beta(RBPA,mode2) {0 0.5 1 2 4 6}
# Seeds: 1..SEEDS (paired across values).
#
# Output -> $OUT/opt_runs.csv   (OUT passed in by the autopilot, or auto-created)
# ============================================================================
set -u
# SD="$HOME/SimpleSSD-Standalone" <-- 경로 수정함
SD="$(cd "$(dirname "$0")" && pwd)"
BIN="$SD/simplessd-standalone"
GEN_BASE="$SD/config/sample.cfg"
TRC_BASE="$SD/config/trace.cfg"
SSD_BASE="$SD/simplessd/config/sample.cfg"
FITTED="$SD/trace_nexus5_fitted.txt"

SEEDS=${SEEDS:-3}
GEN_IOSIZE="16G"
PER_RUN_TIMEOUT=${PER_RUN_TIMEOUT:-1500}
LAMBDA_VALS="${LAMBDA_VALS:-0 0.5 1 2 3 4 6}"
BETA_VALS="${BETA_VALS:-0 0.5 1 2 4 6}"
# condition list: workload:prewornName:blockRatio:eraseRatio
CONDS="${CONDS:-gen:light:0.3:0.5 gen:med:0.3:0.7 gen:heavy:0.5:0.8 trace:med:0.3:0.7 trace:heavy:0.5:0.8}"

# big trace source (created once); med/heavy preworn reach first death well within x10
TRACE_SRC="/tmp/optd_big_trace.txt"
if [ ! -s "$TRACE_SRC" ]; then : > "$TRACE_SRC"; for i in $(seq 1 10); do cat "$FITTED" >> "$TRACE_SRC"; done; fi

OUT="${OUT:-$SD/results/optdesign_$(date +%Y%m%d_%H%M%S)}"; mkdir -p "$OUT"
CSV="$OUT/opt_runs.csv"
echo "param,value,workload,preworn,seed,endurance,host_writes,nand_pgm,waf,gc_count,gc_copies,wl_mig,wlfactor,energy_uJ,wbusy_per_req,erase_cnt,stddev_ec,mean_ec" > "$CSV"

run_one(){ # param value mode workload prewornName br er seed
  local param="$1" val="$2" m="$3" wl="$4" pn="$5" br="$6" er="$7" seed="$8" thr dir simcfg ssd log
  if [ "$wl" = gen ]; then thr=100; else thr=1000; fi
  dir="$OUT/$param/v$val/$wl-$pn/seed$seed"; mkdir -p "$dir"; log="$dir/log.txt"
  ssd="/tmp/od_ssd_${param}_${wl}.cfg"; cp "$SSD_BASE" "$ssd"
  sed -i "s/^EraseThreshold[[:space:]]*=.*/EraseThreshold = $thr/;
          s/^PrewornBlockRatio[[:space:]]*=.*/PrewornBlockRatio = $br/;
          s/^PrewornEraseRatio[[:space:]]*=.*/PrewornEraseRatio = $er/;
          s/^MappingMode[[:space:]]*=.*/MappingMode = $m/;
          s/^StopAtFirstDeath[[:space:]]*=.*/StopAtFirstDeath = 1/;
          s/^ExperimentSeed[[:space:]]*=.*/ExperimentSeed = $seed/" "$ssd"
  if [ "$param" = lambda ]; then sed -i "s/^WLLambdaScale[[:space:]]*=.*/WLLambdaScale = $val/" "$ssd"
  else                          sed -i "s/^RBPAExponent[[:space:]]*=.*/RBPAExponent = $val/" "$ssd"; fi
  if [ "$wl" = gen ]; then
    simcfg="/tmp/od_sim_${param}_gen.cfg"; cp "$GEN_BASE" "$simcfg"
    sed -i "s/^io_size = .*/io_size = $GEN_IOSIZE/; s/^randseed = .*/randseed = $((2000+seed))/" "$simcfg"
  else
    simcfg="/tmp/od_sim_${param}_trace.cfg"; cp "$TRC_BASE" "$simcfg"
    sed -i "s#^File = .*#File = $TRACE_SRC#; s/^IOLimit = .*/IOLimit = 0/" "$simcfg"
  fi
  sed -i "s/^LogPeriod = .*/LogPeriod = 200/;
          s#^LogFile = .*#LogFile = $log#;
          s#^DebugLogFile = .*#DebugLogFile = #;
          s#^LatencyLogFile = .*#LatencyLogFile = #;
          s#^WLSummaryLogFile = .*#WLSummaryLogFile = $dir/wl_summary.csv#;
          s#^WLSnapshotLogFile = .*#WLSnapshotLogFile = $dir/wl_snapshot.csv#;
          s#^WLSnapshotInitLogFile = .*#WLSnapshotInitLogFile = $dir/wl_snapshot_init.csv#;
          s#^FirstDeathLogFile = .*#FirstDeathLogFile = $dir/first_death.csv#" "$simcfg"
  timeout "$PER_RUN_TIMEOUT" "$BIN" "$simcfg" "$ssd" "$dir" > "$dir/full.txt" 2>&1

  L(){ grep -E "$1" "$log" 2>/dev/null | tail -1 | awk '{print $2}'; }
  local hostwr nandpgm gccnt gccpy mig wlf energy wbusy erase endur stdec meanec waf wbpr
  hostwr=$(L '^write\.request_count[[:space:]]'); nandpgm=$(L '^pal\.program\.count[[:space:]]')
  gccnt=$(L 'ftl\.[a-z_]+\.gc\.count[[:space:]]'); gccpy=$(L 'ftl\.[a-z_]+\.gc\.page_copies[[:space:]]')
  mig=$(L 'ftl\.[a-z_]+\.wl_migration_count[[:space:]]'); wlf=$(L 'ftl\.[a-z_]+\.wear_leveling[[:space:]]')
  energy=$(L '^pal\.energy\.total[[:space:]]'); wbusy=$(L '^write\.busy[[:space:]]'); erase=$(L '^pal\.erase\.count[[:space:]]')
  endur=$(awk -F, 'NR==2{print $2}' "$dir/first_death.csv" 2>/dev/null)
  read meanec stdec < <(awk -F, 'NR==1{for(i=1;i<=NF;i++)c[$i]=i;next}{me=$(c["mean_ec"]);sd=$(c["stddev_ec"])}END{print me,sd}' "$dir/wl_summary.csv" 2>/dev/null)
  waf=$(awk -v p="${nandpgm:-0}" -v w="${hostwr:-0}" 'BEGIN{if(w>0)printf "%.3f",p/w; else printf "NA"}')
  wbpr=$(awk -v b="${wbusy:-0}" -v w="${hostwr:-0}" 'BEGIN{if(w>0)printf "%.0f",b/w; else printf "NA"}')
  echo "$param,$val,$wl,$pn,$seed,${endur:-},${hostwr:-},${nandpgm:-},$waf,${gccnt:-},${gccpy:-},${mig:-},${wlf:-},${energy:-},$wbpr,${erase:-},${stdec:-},${meanec:-}" >> "$CSV"
  echo ">>> $param=$val $wl-$pn seed$seed endur=${endur:-NA} waf=$waf gc=${gccnt:-NA} mig=${mig:-NA}" >&2
  rm -f "$log"
}

echo "===== OPT-DESIGN START $(date) (SEEDS=$SEEDS) ====="
for cond in $CONDS; do
  wl=${cond%%:*}; r=${cond#*:}; pn=${r%%:*}; r=${r#*:}; br=${r%%:*}; er=${r#*:}
  for val in $LAMBDA_VALS; do for s in $(seq 1 "$SEEDS"); do run_one lambda "$val" 1 "$wl" "$pn" "$br" "$er" "$s"; done; done
  for val in $BETA_VALS;   do for s in $(seq 1 "$SEEDS"); do run_one beta   "$val" 2 "$wl" "$pn" "$br" "$er" "$s"; done; done
  echo "===== condition $wl-$pn done $(date) ====="
done
echo "===== OPT-DESIGN DONE $(date) -> $OUT ====="
