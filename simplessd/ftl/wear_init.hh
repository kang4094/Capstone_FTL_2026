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

#ifndef __FTL_WEAR_INIT__
#define __FTL_WEAR_INIT__

#include <list>

#include "ftl/common/block.hh"
#include "sim/config_reader.hh"

namespace SimpleSSD {

namespace FTL {

// Test-scenario helper (NOT a wear-leveling algorithm):
// pre-wears a fraction of the free blocks to an initial erase count, modelling
// a drive sold with some blocks already partially worn. Applied identically to
// every FTL via a fixed RNG seed so baseline and improved runs share the exact
// same starting state. No-op when PrewornBlockRatio <= 0.
// Leaves freeBlocks sorted ascending by erase count (the invariant the FTLs
// rely on for getFreeBlock / eraseInternal).
void applyInitialWear(std::list<Block> &freeBlocks, ConfigReader &conf);

}  // namespace FTL

}  // namespace SimpleSSD

#endif
