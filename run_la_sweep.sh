#!/bin/bash
# Quick sweep of LA's alpha (LAAlphaScale) — endurance (first death) + flatness.
set -u
# SD="$HOME/SimpleSSD-Standalone"; BIN="$SD/simplessd-standalone" <-- 경로 수정함
SD="$(cd "$(dirname "$0")" && pwd)"; BIN="$SD/simplessd-standalone"
GEN="$SD/config/sample.cfg"; TRC="$SD/config/trace.cfg"; SSD="$SD/simplessd/config/sample.cfg"
FITTED="$SD/trace_nexus5_fitted.txt"
SEEDS=${SEEDS:-2}
ALPHAS="${ALPHAS:-0 0.1 0.2 0.4 0.8 1.5}"
CONDS="gen:med:0.3:0.7 gen:heavy:0.5:0.8 trace:med:0.3:0.7"
TRACE_SRC="/tmp/la_trace.txt"
[ -s "$TRACE_SRC" ] || { :>"$TRACE_SRC"; for i in $(seq 1 8); do cat "$FITTED">>"$TRACE_SRC"; done; }
OUT="$SD/results/la_sweep_$(date +%Y%m%d_%H%M%S)"; mkdir -p "$OUT"
CSV="$OUT/la_runs.csv"; echo "alpha,workload,preworn,seed,endurance,stddev_ec" > "$CSV"
run(){ local al=$1 wl=$2 pn=$3 br=$4 er=$5 sd=$6 thr d ssdc simc
  if [ "$wl" = gen ]; then thr=100; else thr=1000; fi
  d="$OUT/a$al/$wl-$pn/s$sd"; mkdir -p "$d"
  ssdc=/tmp/la_ssd_$wl.cfg; cp "$SSD" "$ssdc"
  sed -i "s/^EraseThreshold.*/EraseThreshold = $thr/;
          s/^PrewornBlockRatio.*/PrewornBlockRatio = $br/;
          s/^PrewornEraseRatio.*/PrewornEraseRatio = $er/;
          s/^MappingMode.*/MappingMode = 3/;
          s/^StopAtFirstDeath.*/StopAtFirstDeath = 1/;
          s/^LAAlphaScale.*/LAAlphaScale = $al/;
          s/^ExperimentSeed.*/ExperimentSeed = $sd/" "$ssdc"
  if [ "$wl" = gen ]; then simc=/tmp/la_sim_gen.cfg; cp "$GEN" "$simc"
    sed -i "s/^io_size = .*/io_size = 16G/; s/^randseed = .*/randseed = $((2000+sd))/" "$simc"
  else simc=/tmp/la_sim_trace.cfg; cp "$TRC" "$simc"
    sed -i "s#^File = .*#File = $TRACE_SRC#; s/^IOLimit = .*/IOLimit = 0/" "$simc"; fi
  sed -i "s#^WLSummaryLogFile = .*#WLSummaryLogFile = $d/wl_summary.csv#;
          s#^WLSnapshotLogFile = .*#WLSnapshotLogFile = $d/wl_snapshot.csv#;
          s#^WLSnapshotInitLogFile = .*#WLSnapshotInitLogFile = $d/wl_snapshot_init.csv#;
          s#^FirstDeathLogFile = .*#FirstDeathLogFile = $d/first_death.csv#;
          s#^LogFile = .*#LogFile = $d/log.txt#; s#^DebugLogFile = .*#DebugLogFile = #;
          s#^LatencyLogFile = .*#LatencyLogFile = #" "$simc"
  timeout 1200 "$BIN" "$simc" "$ssdc" "$d" > "$d/full.txt" 2>&1
  rm -f "$d/log.txt"
  local e s
  e=$(awk -F, 'NR==2{print $2}' "$d/first_death.csv" 2>/dev/null)
  s=$(awk -F, 'NR==1{for(i=1;i<=NF;i++)c[$i]=i;next}{v=$(c["stddev_ec"])}END{print v}' "$d/wl_summary.csv" 2>/dev/null)
  echo "$al,$wl,$pn,$sd,${e:-},${s:-}" >> "$CSV"
  echo ">>> alpha=$al $wl-$pn s$sd endur=${e:-NA} sd=${s:-NA}" >&2
}
echo "===== LA SWEEP START $(date) ====="
for al in $ALPHAS; do for c in $CONDS; do
  wl=${c%%:*}; r=${c#*:}; pn=${r%%:*}; r=${r#*:}; br=${r%%:*}; er=${r#*:}
  for sd in $(seq 1 "$SEEDS"); do run "$al" "$wl" "$pn" "$br" "$er" "$sd"; done
done; done
# aggregate: per-alpha mean endurance per condition + robust score (norm to best-in-cond)
{ awk -F, 'NR>1 && $5!=""{ a=$1; c=$2"-"$3; es[a,c]+=$5; en[a,c]++; ss[a,c]+=$6; av[a]=1; cv[c]=1 }
   END{
     for(a in av)for(c in cv) if((a,c) in es){ me[a,c]=es[a,c]/en[a,c]; if(me[a,c]>cmax[c])cmax[c]=me[a,c] }
     printf "%-7s %14s %14s %14s %12s\n","alpha","gen-med","gen-heavy","trace-med","robust"
     for(a in av){ s=0;k=0; line=sprintf("%-7s",a)
       for(c in cv){ if((a,c) in me){ line=line sprintf("%14.0f",me[a,c]); s+=me[a,c]/cmax[c]; k++ } else line=line sprintf("%14s","-") }
       printf "%s %12.4f\n", line, (k?s/k:0) }
   }' "$CSV" | sort
} > "$OUT/la_summary.txt"
echo "--- default alpha = 0.1 ---" >> "$OUT/la_summary.txt"
cat "$OUT/la_summary.txt"
echo "===== LA SWEEP DONE $(date) -> $OUT ====="