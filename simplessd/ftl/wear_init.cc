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

#include "ftl/wear_init.hh"

#include <algorithm>
#include <random>
#include <vector>

#include "ftl/config.hh"
#include "sim/trace.hh"

namespace SimpleSSD {

namespace FTL {

// Fixed seed: both baseline and improved runs must pre-wear the SAME blocks.
static const uint64_t PREWORN_SEED = 0xC0FFEEULL;

void applyInitialWear(std::list<Block> &freeBlocks, ConfigReader &conf) {
  float ratio = conf.readFloat(CONFIG_FTL, FTL_PREWORN_BLOCK_RATIO);

  if (ratio <= 0.f || freeBlocks.empty()) {
    return;
  }

  uint64_t threshold = conf.readUint(CONFIG_FTL, FTL_BAD_BLOCK_THRESHOLD);
  float ecRatio = conf.readFloat(CONFIG_FTL, FTL_PREWORN_ERASE_RATIO);
  uint32_t preEC = (uint32_t)(threshold * ecRatio);

  uint64_t total = freeBlocks.size();
  uint64_t nWorn = (uint64_t)(total * ratio);

  if (nWorn == 0) {
    return;
  }

  // Build an index list and shuffle it deterministically, then pre-wear the
  // first nWorn blocks. Selecting by position keeps the choice independent of
  // list ordering so both FTLs wear identical block indices.
  std::vector<std::list<Block>::iterator> iters;
  iters.reserve(total);
  for (auto it = freeBlocks.begin(); it != freeBlocks.end(); ++it) {
    iters.push_back(it);
  }

  // ExperimentSeed lets us vary which blocks are pre-worn across runs for
  // multi-seed statistics; 0 keeps the original fixed, reproducible selection.
  uint64_t seed = conf.readUint(CONFIG_FTL, FTL_EXPERIMENT_SEED);
  std::mt19937_64 gen(seed != 0 ? seed : PREWORN_SEED);
  std::shuffle(iters.begin(), iters.end(), gen);

  for (uint64_t i = 0; i < nWorn; i++) {
    iters[i]->setEraseCount(preEC);
  }

  // Restore the ascending-by-EC invariant the FTLs depend on.
  freeBlocks.sort([](const Block &a, const Block &b) {
    return a.getEraseCount() < b.getEraseCount();
  });

  info("ftl: pre-worn %" PRIu64 " / %" PRIu64
       " blocks to erase count %" PRIu32 " (threshold %" PRIu64 ")",
       nWorn, total, preEC, threshold);
}

}  // namespace FTL

}  // namespace SimpleSSD
