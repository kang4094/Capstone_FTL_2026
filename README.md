# Capstone FTL 2026 — 사전 마모 SSD를 위한 마모 인지 FTL

[SimpleSSD-Standalone](https://github.com/SimpleSSD/SimpleSSD-Standalone) 기반 종합설계 프로젝트.
**사전 마모(pre-worn)된 SSD의 수명(endurance)** 을 늘리기 위해, 페이지 매핑 FTL의 GC victim 선택·블록 할당·채널 균형 단계에 **마모도(Erase Count)** 를 반영하는 알고리즘을 설계하고 baseline과 비교·분석한다.

## 알고리즘 (FTL `MappingMode`)

| Mode | 이름 | 핵심 | 구현 |
|---|---|---|---|
| `0` | PAGE (baseline) | greedy GC victim (유효 페이지 최소) | `simplessd/ftl/page_mapping.*` |
| `1` | WL | 마모 인지 victim: `cost = validPages + λ·EC` | `simplessd/ftl/wl_page_mapping.*` |
| `2` | RBPA | 잔여 수명 비례 할당 `P ∝ (잔여+1)^β` (+ WL과 동일 victim) | `simplessd/ftl/rbpa_page_mapping.*` |
| `3` | LA | 채널 상대 마모 균형 (할당·victim에 채널 편향 α) | `simplessd/ftl/la_page_mapping.*` |

알고리즘 선택과 튜닝 노브는 SSD 설정 파일(`simplessd/config/sample.cfg`)에서 지정한다.

## 빌드

요구: Linux/WSL · CMake ≥ 3.10 · g++ (C++17)

```bash
git clone https://github.com/kang4094/Capstone_FTL_2026.git
cd Capstone_FTL_2026
cmake -DDEBUG_BUILD=off .
make -j$(nproc)
```

→ 실행 파일 `simplessd-standalone` 가 생성된다. (서브모듈을 풀어 코드를 직접 포함했으므로 `--recursive` 불필요.)

## 단일 실행

```bash
./simplessd-standalone <엔진/워크로드 cfg> <SSD/FTL cfg> <출력 디렉터리>

# 예) 합성 워크로드 + WL(=MappingMode 1)
mkdir -p out
./simplessd-standalone config/sample.cfg simplessd/config/sample.cfg out
```

- **1번째 인자**: 워크로드/시뮬레이션 엔진 설정 — `config/sample.cfg`(합성 randrw), `config/trace.cfg`(트레이스 재생)
- **2번째 인자**: SSD/FTL 설정 — `MappingMode`, `EraseThreshold`, `Preworn*`, `WLLambdaScale`, `RBPAExponent`, `LAAlphaScale` 등
- **출력**: 지정한 디렉터리에 `wl_summary.csv`(주기별 블록 마모 통계: min/max/mean/stddev EC), `wl_snapshot*.csv`(블록별 EC 스냅샷) 등

## 실험 재현

| 스크립트 | 내용 |
|---|---|
| `run_exp1_wear_distribution.sh` | **실험 1** — 동일 고정 입력에서 마모 평탄도(σ) 비교 (20회) |
| `run_exp2_first_death.sh` | **실험 2** — 첫 블록 사망까지의 수명(흡수 입력량) 비교 (20회) |
| `run_opt_design.sh` | λ·β 파라미터 최적화 스윕 |
| `run_la_sweep.sh` / `run_la_waf.sh` | LA의 α 스윕 / WAF 측정 |
| `run_param_sweep.sh` · `run_autopilot.sh` · `run_all_20x.sh` | 통합 스윕·자동화 |

```bash
bash run_exp1_wear_distribution.sh
bash run_exp2_first_death.sh
```

결과는 `results/<실험>_<timestamp>/` 에 저장된다. (대용량이라 저장소에는 포함하지 않음 — 스크립트로 재생성.)

## 주요 설정 키 (`simplessd/config/sample.cfg`)

| 키 | 의미 |
|---|---|
| `MappingMode` | 0 PAGE / 1 WL / 2 RBPA / 3 LA |
| `EraseThreshold` | 블록 사망 임계 Erase Count |
| `PrewornBlockRatio` / `PrewornEraseRatio` | 사전 마모 블록 비율 / 초기 EC 강도(×threshold) |
| `WLLambdaScale` (λ) | WL victim 마모 가중치 |
| `RBPAExponent` (β) | RBPA 할당 확률 지수 |
| `LAAlphaScale` (α) | LA 채널 바이어스 강도 |
| `StopAtFirstDeath` | 첫 블록 사망 시 종료 (실험 2용) |
| `ExperimentSeed` | 사전 마모·RBPA RNG 재현 시드 |

## 팀

지효재 · 강형구 · 정재윤 · 정무현 — 2026 종합설계 프로젝트

## 라이선스 / 기반

본 저장소는 [CAMELab](http://camelab.org)의 **SimpleSSD-Standalone (v2.0)** 을 기반으로 하며, **GPLv3** 라이선스를 따른다(`LICENSE` 참조). 추가·수정 범위는 FTL 정책 계층(`simplessd/ftl/`)과 실험 자동화 스크립트(`run_*.sh`)다.
