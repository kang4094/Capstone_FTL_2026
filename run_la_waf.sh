#!/bin/bash
# Quick alpha sweep capturing WAF (+ endurance, sigma) for the alpha curve.
set -u
SD=$HOME/SimpleSSD-Standalone; BIN=$SD/simplessd-standalone
GEN=$SD/config/sample.cfg; TRC=$SD/config/trace.cfg; SSD=$SD/simplessd/config/sample.cfg
FITTED=$SD/trace_nexus5_fitted.txt
ALPHAS="0 0.1 0.2 0.4 0.8 1.5"
TRACE_SRC=/tmp/la_trace.txt
[ -s "$TRACE_SRC" ] || { :>$TRACE_SRC; for i in $(seq 1 8); do cat "$FITTED">>$TRACE_SRC; done; }
OUT=$SD/results/la_waf_$(date +%Y%m%d_%H%M%S); mkdir -p $OUT
CSV=$OUT/la_waf.csv; echo "alpha,workload,endurance,waf,stddev_ec" > $CSV
run(){ local al=$1 wl=$2 thr d ssdc simc log
  if [ "$wl" = gen ]; then thr=100; else thr=1000; fi
  d=$OUT/a$al-$wl; mkdir -p $d; log=$d/log.txt
  ssdc=/tmp/lw_ssd.cfg; cp $SSD $ssdc
  sed -i "s/^EraseThreshold.*/EraseThreshold = $thr/;s/^PrewornBlockRatio.*/PrewornBlockRatio = 0.3/;s/^PrewornEraseRatio.*/PrewornEraseRatio = 0.7/;s/^MappingMode.*/MappingMode = 3/;s/^StopAtFirstDeath.*/StopAtFirstDeath = 1/;s/^LAAlphaScale.*/LAAlphaScale = $al/;s/^ExperimentSeed.*/ExperimentSeed = 1/" $ssdc
  simc=/tmp/lw_sim.cfg
  if [ "$wl" = gen ]; then cp $GEN $simc; sed -i "s/^io_size = .*/io_size = 16G/;s/^randseed = .*/randseed = 2001/" $simc
  else cp $TRC $simc; sed -i "s#^File = .*#File = $TRACE_SRC#;s/^IOLimit = .*/IOLimit = 0/" $simc; fi
  sed -i "s/^LogPeriod = .*/LogPeriod = 200/;s#^LogFile = .*#LogFile = $log#;s#^DebugLogFile = .*#DebugLogFile = #;s#^LatencyLogFile = .*#LatencyLogFile = #;s#^WLSummaryLogFile = .*#WLSummaryLogFile = $d/s.csv#;s#^WLSnapshotLogFile = .*#WLSnapshotLogFile = $d/sn.csv#;s#^WLSnapshotInitLogFile = .*#WLSnapshotInitLogFile = $d/si.csv#;s#^FirstDeathLogFile = .*#FirstDeathLogFile = $d/fd.csv#" $simc
  timeout 1200 $BIN $simc $ssdc $d > $d/full.txt 2>&1
  local e hw n waf sd
  e=$(awk -F, 'NR==2{print $2}' $d/fd.csv 2>/dev/null)
  hw=$(grep -E "^write\.request_count[[:space:]]" $log 2>/dev/null | tail -1 | awk '{print $2}')
  n=$(grep -E "^pal\.program\.count[[:space:]]" $log 2>/dev/null | tail -1 | awk '{print $2}')
  waf=$(awk -v p=${n:-0} -v w=${hw:-0} 'BEGIN{if(w>0)printf "%.3f",p/w; else printf "NA"}')
  sd=$(awk -F, 'NR==1{for(i=1;i<=NF;i++)c[$i]=i;next}{v=$(c["stddev_ec"])}END{print v}' $d/s.csv 2>/dev/null)
  echo "$al,$wl,${e:-},$waf,${sd:-}" >> $CSV
  echo ">>> a=$al $wl endur=${e:-NA} waf=$waf sd=${sd:-NA}" >&2
  rm -f $log
}
echo "===== LA WAF SWEEP START $(date) ====="
for al in $ALPHAS; do for wl in gen trace; do run $al $wl; done; done
cat $CSV; echo "===== DONE $(date) -> $OUT ====="
