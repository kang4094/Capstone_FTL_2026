/*
 * Copyright (C) 2017 CAMELab
 *
 * This file is part of SimpleSSD.
 *
 * SimpleSSD is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * SimpleSSD is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with SimpleSSD.  If not, see <http://www.gnu.org/licenses/>.
 */

#ifndef __FTL_RBPA_PAGE_MAPPING__
#define __FTL_RBPA_PAGE_MAPPING__

#include <cinttypes>
#include <cmath>
#include <random>
#include <unordered_map>
#include <vector>

#include "ftl/abstract_ftl.hh"
#include "ftl/common/block.hh"
#include "ftl/ftl.hh"
#include "pal/pal.hh"

namespace SimpleSSD {

namespace FTL {

// Remaining-Budget-Proportional Allocation (RBPA) page-mapping FTL.
//
// Target scenario: a second-life / heterogeneous-endurance device whose
// controller already knows each block's accumulated wear at boot (a refurbished
// SSD reads per-block P/E counts from its metadata). Classic wear-leveling
// assumes a fresh, uniform device and *learns* the wear skew over time, then
// *reacts* to it (gap-triggered static-WL migration). RBPA instead bakes
// leveling into the allocation decision itself, proactively from t=0:
//
//   * getFreeBlock picks a write target with probability proportional to the
//     block's remaining endurance budget (threshold - eraseCount)^exponent, so
//     fresh blocks absorb proportionally more erases and pre-worn blocks are
//     spared. As fresh blocks wear, their weight self-adjusts -> every block is
//     driven toward end-of-life simultaneously.
//   * GC victim selection is budget-aware (worn blocks cost more, sparing them).
//
// Because allocation does the leveling, RBPA performs NO dedicated static-WL
// migration pass -- wlMigrationCount stays 0 by design. The intended result is
// leveling comparable to reactive WL but with lower write amplification.
class RBPAPageMapping : public AbstractFTL {
 private:
  PAL::PAL *pPAL;

  ConfigReader &conf;

  std::unordered_map<uint64_t, std::vector<std::pair<uint32_t, uint32_t>>>
      table;
  std::unordered_map<uint32_t, Block> blocks;
  std::list<Block> freeBlocks;
  std::list<Block> deadBlocks;  // retired blocks (EC >= threshold), kept for snapshot
  uint32_t nFreeBlocks;
  std::vector<uint32_t> lastFreeBlock;
  Bitset lastFreeBlockIOMap;
  uint32_t lastFreeBlockIndex;

  bool bReclaimMore;
  bool bRandomTweak;
  uint32_t bitsetSize;

  // Fixed-seed RNG so budget-proportional allocation is reproducible.
  std::mt19937 rng;

  struct {
    uint64_t gcCount;
    uint64_t reclaimedBlocks;
    uint64_t validSuperPageCopies;
    uint64_t validPageCopies;
    uint64_t hostWritePages;  // 호스트가 쓴 페이지 수(수명 직접 지표)
    uint64_t wlMigrationCount;
  } stat;

  float freeBlockRatio();
  uint32_t convertBlockIdx(uint32_t);
  uint32_t getFreeBlock(uint32_t);
  uint32_t getLastFreeBlock(Bitset &);
  void calculateVictimWeight(std::vector<std::pair<uint32_t, float>> &,
                             const EVICT_POLICY, uint64_t);
  void selectVictimBlock(std::vector<uint32_t> &, uint64_t &);
  void doGarbageCollection(std::vector<uint32_t> &, uint64_t &);

  float calculateWearLeveling();
  void calculateTotalPages(uint64_t &, uint64_t &);

  void printWLSummary(uint64_t tick);
  void printEraseCountSnapshot(uint64_t tick);
  void printInitialSnapshot();

  bool wlSummaryHeaderWritten;
  bool firstDeathRecorded;  // exp(2): first block-death already logged

  void readInternal(Request &, uint64_t &);
  void writeInternal(Request &, uint64_t &, bool = true);
  void trimInternal(Request &, uint64_t &);
  void eraseInternal(PAL::Request &, uint64_t &);

 public:
  RBPAPageMapping(ConfigReader &, Parameter &, PAL::PAL *, DRAM::AbstractDRAM *);
  ~RBPAPageMapping();

  bool initialize() override;

  void read(Request &, uint64_t &) override;
  void write(Request &, uint64_t &) override;
  void trim(Request &, uint64_t &) override;

  void format(LPNRange &, uint64_t &) override;

  Status *getStatus(uint64_t, uint64_t) override;

  void getStatList(std::vector<Stats> &, std::string) override;
  void getStatValues(std::vector<double> &) override;
  void resetStatValues() override;
};

}  // namespace FTL

}  // namespace SimpleSSD

#endif
