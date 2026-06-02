#!/bin/bash
# ============================================================================
# AUTOPILOT — find optimal lambda/beta (rigorous, multi-variable), then re-run
# the professor's two experiments with ONLY lambda/beta updated.
#   stage1: run_opt_design.sh           (multi-cond, multi-seed, multi-variable)
#   stage2: auto-select lambda*/beta*   (robust endurance + knee rule)
#   stage3: run_exp1 with WL_LAMBDA/RBPA_BETA
#   stage4: run_exp2 with WL_LAMBDA/RBPA_BETA
# Fully self-contained; safe to run detached.
# ============================================================================
set -u
SD="$HOME/SimpleSSD-Standalone"; cd "$SD" || exit 1
TS=$(date +%Y%m%d_%H%M%S)
RUN="$SD/results/autopilot_$TS"; mkdir -p "$RUN"
LOG="$RUN/autopilot.log"; exec > >(tee -a "$LOG") 2>&1
echo "===== AUTOPILOT START $(date) -> $RUN ====="

# ---- stage 1: optimization sweep ------------------------------------------
export OUT="$RUN/optdesign"
echo "[stage1] $(date) optimization sweep -> $OUT"
bash run_opt_design.sh
CSV="$OUT/opt_runs.csv"
unset OUT

# ---- stage 2: select optimal lambda/beta ----------------------------------
echo "[stage2] $(date) selecting optimal lambda/beta from $CSV"
# robustness = mean over conditions of (mean-endurance(value) / best-endurance-in-condition).
# optimal = smallest value within 2% of the peak robustness (knee: max endurance,
# min cost on the secondary axes WAF/latency/energy that grow with the knob).
awk -F, '
  NR>1 && $6!="" { p=$1;v=$2;cond=$3"-"$4; k=p SUBSEP v SUBSEP cond
    sum[k]+=$6; cnt[k]++; pv[p SUBSEP v]=1; cset[p SUBSEP cond]=1 }
  END{
    for(k in sum){ split(k,a,SUBSEP); m=sum[k]/cnt[k]; mean[k]=m
      ck=a[1] SUBSEP a[3]; if(m>cmax[ck]) cmax[ck]=m }
    for(pvk in pv){ split(pvk,a,SUBSEP); p=a[1]; v=a[2]; s=0; n=0
      for(ck in cset){ split(ck,c,SUBSEP); if(c[1]!=p)continue
        k=p SUBSEP v SUBSEP c[2]; if((k in mean)&&cmax[ck]>0){s+=mean[k]/cmax[ck];n++} }
      if(n>0) rob[pvk]=s/n }
    for(pvk in rob){ split(pvk,a,SUBSEP); if(rob[pvk]>peak[a[1]])peak[a[1]]=rob[pvk] }
    for(pvk in rob){ split(pvk,a,SUBSEP); p=a[1]; v=a[2]
      if(rob[pvk]>=0.98*peak[p]){ if(!(p in best)||v+0<best[p]+0) best[p]=v } }
    print best["lambda"]+0, best["beta"]+0
  }' "$CSV" > "$RUN/_sel.txt"
LAMBDA=$(awk '{print $1}' "$RUN/_sel.txt")
BETA=$(awk '{print $2}' "$RUN/_sel.txt")
[ -z "${LAMBDA:-}" ] || [ "$LAMBDA" = 0 ] && { echo "WARN lambda sel=$LAMBDA; check"; }
[ -z "${LAMBDA:-}" ] && LAMBDA=1.0
[ -z "${BETA:-}" ] && BETA=1.0
echo "OPTIMAL  WLLambdaScale=$LAMBDA  RBPAExponent=$BETA" | tee "$RUN/optimal_params.txt"

# robustness/multi-variable table for review
{ echo "# per (param,value): robustScore + mean endurance/WAF/wbusy across conditions"
  awk -F, 'NR>1 && $6!=""{p=$1;v=$2;c=$3"-"$4
      es[p,v,c]+=$6; en[p,v,c]++; ws[p,v]+=$9; wn[p,v]++; bs[p,v]+=$15; pv[p,v]=1; cset[p,c]=1}
    END{ for(k in es){split(k,a,SUBSEP); m=es[k]/en[k]; mean[k]=m; ck=a[1] SUBSEP a[3]; if(m>cm[ck])cm[ck]=m}
      printf "%-7s %-5s %10s %8s %12s\n","param","val","robust","avgWAF","avgEndur"
      n=split("lambda beta",P," ")
      for(i=1;i<=n;i++){pp=P[i]
        for(k in pv){split(k,a,SUBSEP); if(a[1]!=pp)continue; v=a[2]; s=0;nn=0;te=0;tc=0
          for(ck in cset){split(ck,c,SUBSEP); if(c[1]!=pp)continue; kk=pp SUBSEP v SUBSEP c[2]
            if((kk in mean)&&cm[ck]>0){s+=mean[kk]/cm[ck];nn++;te+=mean[kk];tc++}}
          waf=(wn[pp,v]>0)?ws[pp,v]/wn[pp,v]:0
          if(nn>0)printf "%-7s %-5s %10.4f %8.3f %12.0f\n",pp,v,s/nn,waf,te/tc}
        print ""}}' "$CSV"
} > "$RUN/opt_robust.txt"
cat "$RUN/opt_robust.txt"

# ---- stage 3+4: re-run professor experiments with tuned knobs only --------
export WL_LAMBDA="$LAMBDA" RBPA_BETA="$BETA"
echo "[stage3] $(date) exp1 (same as before, WL lambda=$LAMBDA / RBPA beta=$BETA)"
bash run_exp1_wear_distribution.sh
echo "[stage4] $(date) exp2 (same as before, WL lambda=$LAMBDA / RBPA beta=$BETA)"
bash run_exp2_first_death.sh

echo "===== AUTOPILOT DONE $(date) ====="
echo "optimal: lambda=$LAMBDA beta=$BETA"
echo "sweep:   $CSV"
echo "exp1/exp2 dirs: $(ls -dt $SD/results/exp1_* | head -1) ; $(ls -dt $SD/results/exp2_* | head -1)"
