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

#include "ftl/wl_page_mapping.hh"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <limits>
#include <random>

#include "ftl/wear_init.hh"
#include "sim/simulator.hh"
#include "util/algorithm.hh"
#include "util/bitset.hh"

namespace SimpleSSD {

namespace FTL {

WLPageMapping::WLPageMapping(ConfigReader &c, Parameter &p, PAL::PAL *l,
                             DRAM::AbstractDRAM *d)
    : AbstractFTL(p, l, d),
      pPAL(l),
      conf(c),
      lastFreeBlock(param.pageCountToMaxPerf),
      lastFreeBlockIOMap(param.ioUnitInPage),
      bReclaimMore(false),
      wlSummaryHeaderWritten(false) {
  blocks.reserve(param.totalPhysicalBlocks);
  table.reserve(param.totalLogicalBlocks * param.pagesInBlock);

  for (uint32_t i = 0; i < param.totalPhysicalBlocks; i++) {
    freeBlocks.emplace_back(Block(i, param.pagesInBlock, param.ioUnitInPage));
  }

  nFreeBlocks = param.totalPhysicalBlocks;

  status.totalLogicalPages = param.totalLogicalBlocks * param.pagesInBlock;

  // Same pre-wear injection as the baseline so both start identically.
  applyInitialWear(freeBlocks, conf);

  for (uint32_t i = 0; i < param.pageCountToMaxPerf; i++) {
    lastFreeBlock.at(i) = getFreeBlock(i);
  }

  lastFreeBlockIndex = 0;

  memset(&stat, 0, sizeof(stat));
  firstDeathRecorded = false;

  bRandomTweak = conf.readBoolean(CONFIG_FTL, FTL_USE_RANDOM_IO_TWEAK);
  bitsetSize = bRandomTweak ? param.ioUnitInPage : 1;
}

WLPageMapping::~WLPageMapping() {}

bool WLPageMapping::initialize() {
  uint64_t nPagesToWarmup;
  uint64_t nPagesToInvalidate;
  uint64_t nTotalLogicalPages;
  uint64_t maxPagesBeforeGC;
  uint64_t tick;
  uint64_t valid;
  uint64_t invalid;
  FILLING_MODE mode;

  Request req(param.ioUnitInPage);

  debugprint(LOG_FTL_PAGE_MAPPING, "Initialization started");

  nTotalLogicalPages = param.totalLogicalBlocks * param.pagesInBlock;
  nPagesToWarmup =
      nTotalLogicalPages * conf.readFloat(CONFIG_FTL, FTL_FILL_RATIO);
  nPagesToInvalidate =
      nTotalLogicalPages * conf.readFloat(CONFIG_FTL, FTL_INVALID_PAGE_RATIO);
  mode = (FILLING_MODE)conf.readUint(CONFIG_FTL, FTL_FILLING_MODE);
  maxPagesBeforeGC =
      param.pagesInBlock *
      (param.totalPhysicalBlocks *
           (1 - conf.readFloat(CONFIG_FTL, FTL_GC_THRESHOLD_RATIO)) -
       param.pageCountToMaxPerf);

  if (nPagesToWarmup + nPagesToInvalidate > maxPagesBeforeGC) {
    warn("ftl: Too high filling ratio. Adjusting invalidPageRatio.");
    nPagesToInvalidate = maxPagesBeforeGC - nPagesToWarmup;
  }

  debugprint(LOG_FTL_PAGE_MAPPING, "Total logical pages: %" PRIu64,
             nTotalLogicalPages);
  debugprint(LOG_FTL_PAGE_MAPPING,
             "Total logical pages to fill: %" PRIu64 " (%.2f %%)",
             nPagesToWarmup, nPagesToWarmup * 100.f / nTotalLogicalPages);
  debugprint(LOG_FTL_PAGE_MAPPING,
             "Total invalidated pages to create: %" PRIu64 " (%.2f %%)",
             nPagesToInvalidate,
             nPagesToInvalidate * 100.f / nTotalLogicalPages);

  req.ioFlag.set();

  // Step 1. Filling
  if (mode == FILLING_MODE_0 || mode == FILLING_MODE_1) {
    for (uint64_t i = 0; i < nPagesToWarmup; i++) {
      tick = 0;
      req.lpn = i;
      writeInternal(req, tick, false);
    }
  }
  else {
    std::random_device rd;
    std::mt19937_64 gen(rd());
    std::uniform_int_distribution<uint64_t> dist(0, nTotalLogicalPages - 1);

    for (uint64_t i = 0; i < nPagesToWarmup; i++) {
      tick = 0;
      req.lpn = dist(gen);
      writeInternal(req, tick, false);
    }
  }

  // Step 2. Invalidating
  if (mode == FILLING_MODE_0) {
    for (uint64_t i = 0; i < nPagesToInvalidate; i++) {
      tick = 0;
      req.lpn = i;
      writeInternal(req, tick, false);
    }
  }
  else if (mode == FILLING_MODE_1) {
    std::random_device rd;
    std::mt19937_64 gen(rd());
    std::uniform_int_distribution<uint64_t> dist(0, nPagesToWarmup - 1);

    for (uint64_t i = 0; i < nPagesToInvalidate; i++) {
      tick = 0;
      req.lpn = dist(gen);
      writeInternal(req, tick, false);
    }
  }
  else {
    std::random_device rd;
    std::mt19937_64 gen(rd());
    std::uniform_int_distribution<uint64_t> dist(0, nTotalLogicalPages - 1);

    for (uint64_t i = 0; i < nPagesToInvalidate; i++) {
      tick = 0;
      req.lpn = dist(gen);
      writeInternal(req, tick, false);
    }
  }

  calculateTotalPages(valid, invalid);
  debugprint(LOG_FTL_PAGE_MAPPING, "Filling finished. Page status:");
  debugprint(LOG_FTL_PAGE_MAPPING,
             "  Total valid physical pages: %" PRIu64
             " (%.2f %%, target: %" PRIu64 ", error: %" PRId64 ")",
             valid, valid * 100.f / nTotalLogicalPages, nPagesToWarmup,
             (int64_t)(valid - nPagesToWarmup));
  debugprint(LOG_FTL_PAGE_MAPPING,
             "  Total invalid physical pages: %" PRIu64
             " (%.2f %%, target: %" PRIu64 ", error: %" PRId64 ")",
             invalid, invalid * 100.f / nTotalLogicalPages, nPagesToInvalidate,
             (int64_t)(invalid - nPagesToInvalidate));
  debugprint(LOG_FTL_PAGE_MAPPING, "Initialization finished");

  // exp(1): capture the wear distribution at t=0 (after pre-wear + warm-up,
  // before the host workload) so initially-worn block positions are visible.
  printInitialSnapshot();

  return true;
}

void WLPageMapping::read(Request &req, uint64_t &tick) {
  uint64_t begin = tick;

  if (req.ioFlag.count() > 0) {
    readInternal(req, tick);

    debugprint(LOG_FTL_PAGE_MAPPING,
               "READ  | LPN %" PRIu64 " | %" PRIu64 " - %" PRIu64 " (%" PRIu64
               ")",
               req.lpn, begin, tick, tick - begin);
  }
  else {
    warn("FTL got empty request");
  }

  tick += applyLatency(CPU::FTL__PAGE_MAPPING, CPU::READ);
}

void WLPageMapping::write(Request &req, uint64_t &tick) {
  uint64_t begin = tick;

  if (req.ioFlag.count() > 0) {
    stat.hostWritePages += req.ioFlag.count();

    writeInternal(req, tick);

    debugprint(LOG_FTL_PAGE_MAPPING,
               "WRITE | LPN %" PRIu64 " | %" PRIu64 " - %" PRIu64 " (%" PRIu64
               ")",
               req.lpn, begin, tick, tick - begin);
  }
  else {
    warn("FTL got empty request");
  }

  tick += applyLatency(CPU::FTL__PAGE_MAPPING, CPU::WRITE);
}

void WLPageMapping::trim(Request &req, uint64_t &tick) {
  uint64_t begin = tick;

  trimInternal(req, tick);

  debugprint(LOG_FTL_PAGE_MAPPING,
             "TRIM  | LPN %" PRIu64 " | %" PRIu64 " - %" PRIu64 " (%" PRIu64
             ")",
             req.lpn, begin, tick, tick - begin);

  tick += applyLatency(CPU::FTL__PAGE_MAPPING, CPU::TRIM);
}

void WLPageMapping::format(LPNRange &range, uint64_t &tick) {
  PAL::Request req(param.ioUnitInPage);
  std::vector<uint32_t> list;

  req.ioFlag.set();

  for (auto iter = table.begin(); iter != table.end();) {
    if (iter->first >= range.slpn && iter->first < range.slpn + range.nlp) {
      auto &mappingList = iter->second;

      for (uint32_t idx = 0; idx < bitsetSize; idx++) {
        auto &mapping = mappingList.at(idx);
        auto block = blocks.find(mapping.first);

        if (block == blocks.end()) {
          panic("Block is not in use");
        }

        block->second.invalidate(mapping.second, idx);

        list.push_back(mapping.first);
      }

      iter = table.erase(iter);
    }
    else {
      iter++;
    }
  }

  std::sort(list.begin(), list.end());
  auto last = std::unique(list.begin(), list.end());
  list.erase(last, list.end());

  doGarbageCollection(list, tick);

  tick += applyLatency(CPU::FTL__PAGE_MAPPING, CPU::FORMAT);
}

Status *WLPageMapping::getStatus(uint64_t lpnBegin, uint64_t lpnEnd) {
  status.freePhysicalBlocks = nFreeBlocks;

  if (lpnBegin == 0 && lpnEnd >= status.totalLogicalPages) {
    status.mappedLogicalPages = table.size();
  }
  else {
    status.mappedLogicalPages = 0;

    for (uint64_t lpn = lpnBegin; lpn < lpnEnd; lpn++) {
      if (table.count(lpn) > 0) {
        status.mappedLogicalPages++;
      }
    }
  }

  return &status;
}

float WLPageMapping::freeBlockRatio() {
  return (float)nFreeBlocks / param.totalPhysicalBlocks;
}

uint32_t WLPageMapping::convertBlockIdx(uint32_t blockIdx) {
  return blockIdx % param.pageCountToMaxPerf;
}

uint32_t WLPageMapping::getFreeBlock(uint32_t idx) {
  uint32_t blockIndex = 0;

  if (idx >= param.pageCountToMaxPerf) {
    panic("Index out of range");
  }

  if (nFreeBlocks > 0) {
    auto iter = freeBlocks.begin();

    for (; iter != freeBlocks.end(); iter++) {
      blockIndex = iter->getBlockIndex();

      if (blockIndex % param.pageCountToMaxPerf == idx) {
        break;
      }
    }

    if (iter == freeBlocks.end()) {
      iter = freeBlocks.begin();
      blockIndex = iter->getBlockIndex();
    }

    if (blocks.find(blockIndex) != blocks.end()) {
      panic("Corrupted");
    }

    blocks.emplace(blockIndex, std::move(*iter));

    freeBlocks.erase(iter);
    nFreeBlocks--;
  }
  else {
    // Device end-of-life: identical clean-stop path as the baseline so the two
    // runs report their failure point comparably.
    uint64_t tick = getTick();
    printWLSummary(tick);
    wlSnapshotClear();
    printEraseCountSnapshot(tick);

    uint64_t nDead = param.totalPhysicalBlocks - blocks.size() - nFreeBlocks;
    printf("\n*** DEVICE END-OF-LIFE *** algo=wl_page_mapping gc=%" PRIu64
           " host_write_pages=%" PRIu64
           " wl_migrations=%" PRIu64 " dead_blocks=%" PRIu64 " / %" PRIu64
           " @tick %" PRIu64 "\n",
           stat.gcCount, stat.hostWritePages, stat.wlMigrationCount, nDead,
           (uint64_t)param.totalPhysicalBlocks, tick);
    fflush(stdout);

    exit(0);
  }

  return blockIndex;
}

uint32_t WLPageMapping::getLastFreeBlock(Bitset &iomap) {
  if (!bRandomTweak || (lastFreeBlockIOMap & iomap).any()) {
    lastFreeBlockIndex++;

    if (lastFreeBlockIndex == param.pageCountToMaxPerf) {
      lastFreeBlockIndex = 0;
    }

    lastFreeBlockIOMap = iomap;
  }
  else {
    lastFreeBlockIOMap |= iomap;
  }

  auto freeBlock = blocks.find(lastFreeBlock.at(lastFreeBlockIndex));

  if (freeBlock == blocks.end()) {
    panic("Corrupted");
  }

  if (freeBlock->second.getNextWritePageIndex() == param.pagesInBlock) {
    lastFreeBlock.at(lastFreeBlockIndex) = getFreeBlock(lastFreeBlockIndex);

    bReclaimMore = true;
  }

  return lastFreeBlock.at(lastFreeBlockIndex);
}

void WLPageMapping::calculateVictimWeight(
    std::vector<std::pair<uint32_t, float>> &weight, const EVICT_POLICY policy,
    uint64_t tick) {
  float temp;

  weight.reserve(blocks.size());

  switch (policy) {
    case POLICY_GREEDY:
    case POLICY_RANDOM:
    case POLICY_DCHOICE: {
      // Wear-aware greedy: cost = validPages + lambda * eraseCount.
      // The erase-count term raises the cost of worn blocks so the victim
      // search avoids near-death blocks while there are healthier candidates,
      // sparing pre-worn blocks from the erases that would push them to EOL.
      // lambda scales one full erase-budget (0..threshold) to roughly one full
      // valid-page range (0..pagesInBlock) so the two terms are comparable.
      uint64_t threshold = conf.readUint(CONFIG_FTL, FTL_BAD_BLOCK_THRESHOLD);
      float lambdaScale = conf.readFloat(CONFIG_FTL, FTL_WL_LAMBDA_SCALE);
      float lambda = threshold > 0
                         ? lambdaScale * (float)param.pagesInBlock / threshold
                         : 0.f;

      for (auto &iter : blocks) {
        if (iter.second.getNextWritePageIndex() != param.pagesInBlock) {
          continue;
        }

        float w = (float)iter.second.getValidPageCountRaw() +
                  lambda * (float)iter.second.getEraseCount();

        weight.push_back({iter.first, w});
      }

      break;
    }
    case POLICY_COST_BENEFIT:
      for (auto &iter : blocks) {
        if (iter.second.getNextWritePageIndex() != param.pagesInBlock) {
          continue;
        }

        temp = (float)(iter.second.getValidPageCountRaw()) / param.pagesInBlock;

        weight.push_back(
            {iter.first,
             temp / ((1 - temp) * (tick - iter.second.getLastAccessedTime()))});
      }

      break;
    default:
      panic("Invalid evict policy");
  }
}

void WLPageMapping::selectVictimBlock(std::vector<uint32_t> &list,
                                      uint64_t &tick) {
  static const GC_MODE mode = (GC_MODE)conf.readInt(CONFIG_FTL, FTL_GC_MODE);
  static const EVICT_POLICY policy =
      (EVICT_POLICY)conf.readInt(CONFIG_FTL, FTL_GC_EVICT_POLICY);
  static uint32_t dChoiceParam =
      conf.readUint(CONFIG_FTL, FTL_GC_D_CHOICE_PARAM);
  uint64_t nBlocks = conf.readUint(CONFIG_FTL, FTL_GC_RECLAIM_BLOCK);
  std::vector<std::pair<uint32_t, float>> weight;

  list.clear();

  if (mode == GC_MODE_0) {
    // DO NOTHING
  }
  else if (mode == GC_MODE_1) {
    static const float t = conf.readFloat(CONFIG_FTL, FTL_GC_RECLAIM_THRESHOLD);

    nBlocks = param.totalPhysicalBlocks * t - nFreeBlocks;
  }
  else {
    panic("Invalid GC mode");
  }

  if (bReclaimMore) {
    nBlocks += param.pageCountToMaxPerf;

    bReclaimMore = false;
  }

  calculateVictimWeight(weight, policy, tick);

  if (policy == POLICY_RANDOM || policy == POLICY_DCHOICE) {
    uint64_t randomRange =
        policy == POLICY_RANDOM ? nBlocks : dChoiceParam * nBlocks;
    std::random_device rd;
    std::mt19937 gen(rd());
    std::uniform_int_distribution<uint64_t> dist(0, weight.size() - 1);
    std::vector<std::pair<uint32_t, float>> selected;

    while (selected.size() < randomRange) {
      uint64_t idx = dist(gen);

      if (weight.at(idx).first < std::numeric_limits<uint32_t>::max()) {
        selected.push_back(weight.at(idx));
        weight.at(idx).first = std::numeric_limits<uint32_t>::max();
      }
    }

    weight = std::move(selected);
  }

  std::sort(
      weight.begin(), weight.end(),
      [](std::pair<uint32_t, float> a, std::pair<uint32_t, float> b) -> bool {
        return a.second < b.second;
      });

  nBlocks = MIN(nBlocks, weight.size());

  for (uint64_t i = 0; i < nBlocks; i++) {
    list.push_back(weight.at(i).first);
  }

  tick += applyLatency(CPU::FTL__PAGE_MAPPING, CPU::SELECT_VICTIM_BLOCK);
}

void WLPageMapping::doGarbageCollection(std::vector<uint32_t> &blocksToReclaim,
                                        uint64_t &tick) {
  PAL::Request req(param.ioUnitInPage);
  std::vector<PAL::Request> readRequests;
  std::vector<PAL::Request> writeRequests;
  std::vector<PAL::Request> eraseRequests;
  std::vector<uint64_t> lpns;
  Bitset bit(param.ioUnitInPage);
  uint64_t beginAt;
  uint64_t readFinishedAt = tick;
  uint64_t writeFinishedAt = tick;
  uint64_t eraseFinishedAt = tick;

  if (blocksToReclaim.size() == 0) {
    return;
  }

  for (auto &iter : blocksToReclaim) {
    auto block = blocks.find(iter);

    if (block == blocks.end()) {
      panic("Invalid block");
    }

    for (uint32_t pageIndex = 0; pageIndex < param.pagesInBlock; pageIndex++) {
      if (block->second.getPageInfo(pageIndex, lpns, bit)) {
        if (!bRandomTweak) {
          bit.set();
        }

        auto freeBlock = blocks.find(getLastFreeBlock(bit));

        req.blockIndex = block->first;
        req.pageIndex = pageIndex;
        req.ioFlag = bit;

        readRequests.push_back(req);

        uint32_t newBlockIdx = freeBlock->first;

        for (uint32_t idx = 0; idx < bitsetSize; idx++) {
          if (bit.test(idx)) {
            block->second.invalidate(pageIndex, idx);

            auto mappingList = table.find(lpns.at(idx));

            if (mappingList == table.end()) {
              panic("Invalid mapping table entry");
            }

            pDRAM->read(&(*mappingList), 8 * param.ioUnitInPage, tick);

            auto &mapping = mappingList->second.at(idx);

            uint32_t newPageIdx = freeBlock->second.getNextWritePageIndex(idx);

            mapping.first = newBlockIdx;
            mapping.second = newPageIdx;

            freeBlock->second.write(newPageIdx, lpns.at(idx), idx, beginAt);

            req.blockIndex = newBlockIdx;
            req.pageIndex = newPageIdx;

            if (bRandomTweak) {
              req.ioFlag.reset();
              req.ioFlag.set(idx);
            }
            else {
              req.ioFlag.set();
            }

            writeRequests.push_back(req);

            stat.validPageCopies++;
          }
        }

        stat.validSuperPageCopies++;
      }
    }

    req.blockIndex = block->first;
    req.pageIndex = 0;
    req.ioFlag.set();

    eraseRequests.push_back(req);
  }

  for (auto &iter : readRequests) {
    beginAt = tick;

    pPAL->read(iter, beginAt);

    readFinishedAt = MAX(readFinishedAt, beginAt);
  }

  for (auto &iter : writeRequests) {
    beginAt = readFinishedAt;

    pPAL->write(iter, beginAt);

    writeFinishedAt = MAX(writeFinishedAt, beginAt);
  }

  for (auto &iter : eraseRequests) {
    beginAt = readFinishedAt;

    eraseInternal(iter, beginAt);

    eraseFinishedAt = MAX(eraseFinishedAt, beginAt);
  }

  tick = MAX(writeFinishedAt, eraseFinishedAt);
  tick += applyLatency(CPU::FTL__PAGE_MAPPING, CPU::DO_GARBAGE_COLLECTION);
}

void WLPageMapping::readInternal(Request &req, uint64_t &tick) {
  PAL::Request palRequest(req);
  uint64_t beginAt;
  uint64_t finishedAt = tick;

  auto mappingList = table.find(req.lpn);

  if (mappingList != table.end()) {
    if (bRandomTweak) {
      pDRAM->read(&(*mappingList), 8 * req.ioFlag.count(), tick);
    }
    else {
      pDRAM->read(&(*mappingList), 8, tick);
    }

    for (uint32_t idx = 0; idx < bitsetSize; idx++) {
      if (req.ioFlag.test(idx) || !bRandomTweak) {
        auto &mapping = mappingList->second.at(idx);

        if (mapping.first < param.totalPhysicalBlocks &&
            mapping.second < param.pagesInBlock) {
          palRequest.blockIndex = mapping.first;
          palRequest.pageIndex = mapping.second;

          if (bRandomTweak) {
            palRequest.ioFlag.reset();
            palRequest.ioFlag.set(idx);
          }
          else {
            palRequest.ioFlag.set();
          }

          auto block = blocks.find(palRequest.blockIndex);

          if (block == blocks.end()) {
            panic("Block is not in use");
          }

          beginAt = tick;

          block->second.read(palRequest.pageIndex, idx, beginAt);
          pPAL->read(palRequest, beginAt);

          finishedAt = MAX(finishedAt, beginAt);
        }
      }
    }

    tick = finishedAt;
    tick += applyLatency(CPU::FTL__PAGE_MAPPING, CPU::READ_INTERNAL);
  }
}

void WLPageMapping::writeInternal(Request &req, uint64_t &tick, bool sendToPAL) {
  PAL::Request palRequest(req);
  std::unordered_map<uint32_t, Block>::iterator block;
  auto mappingList = table.find(req.lpn);
  uint64_t beginAt;
  uint64_t finishedAt = tick;
  bool readBeforeWrite = false;

  if (mappingList != table.end()) {
    for (uint32_t idx = 0; idx < bitsetSize; idx++) {
      if (req.ioFlag.test(idx) || !bRandomTweak) {
        auto &mapping = mappingList->second.at(idx);

        if (mapping.first < param.totalPhysicalBlocks &&
            mapping.second < param.pagesInBlock) {
          block = blocks.find(mapping.first);

          block->second.invalidate(mapping.second, idx);
        }
      }
    }
  }
  else {
    auto ret = table.emplace(
        req.lpn,
        std::vector<std::pair<uint32_t, uint32_t>>(
            bitsetSize, {param.totalPhysicalBlocks, param.pagesInBlock}));

    if (!ret.second) {
      panic("Failed to insert new mapping");
    }

    mappingList = ret.first;
  }

  block = blocks.find(getLastFreeBlock(req.ioFlag));

  if (block == blocks.end()) {
    panic("No such block");
  }

  if (sendToPAL) {
    if (bRandomTweak) {
      pDRAM->read(&(*mappingList), 8 * req.ioFlag.count(), tick);
      pDRAM->write(&(*mappingList), 8 * req.ioFlag.count(), tick);
    }
    else {
      pDRAM->read(&(*mappingList), 8, tick);
      pDRAM->write(&(*mappingList), 8, tick);
    }
  }

  if (!bRandomTweak && !req.ioFlag.all()) {
    readBeforeWrite = true;
  }

  for (uint32_t idx = 0; idx < bitsetSize; idx++) {
    if (req.ioFlag.test(idx) || !bRandomTweak) {
      uint32_t pageIndex = block->second.getNextWritePageIndex(idx);
      auto &mapping = mappingList->second.at(idx);

      beginAt = tick;

      block->second.write(pageIndex, req.lpn, idx, beginAt);

      if (readBeforeWrite && sendToPAL) {
        palRequest.blockIndex = mapping.first;
        palRequest.pageIndex = mapping.second;

        palRequest.ioFlag = req.ioFlag;
        palRequest.ioFlag.flip();

        pPAL->read(palRequest, beginAt);
      }

      mapping.first = block->first;
      mapping.second = pageIndex;

      if (sendToPAL) {
        palRequest.blockIndex = block->first;
        palRequest.pageIndex = pageIndex;

        if (bRandomTweak) {
          palRequest.ioFlag.reset();
          palRequest.ioFlag.set(idx);
        }
        else {
          palRequest.ioFlag.set();
        }

        pPAL->write(palRequest, beginAt);
      }

      finishedAt = MAX(finishedAt, beginAt);
    }
  }

  if (sendToPAL) {
    tick = finishedAt;
    tick += applyLatency(CPU::FTL__PAGE_MAPPING, CPU::WRITE_INTERNAL);
  }

  static float gcThreshold = conf.readFloat(CONFIG_FTL, FTL_GC_THRESHOLD_RATIO);

  if (freeBlockRatio() < gcThreshold) {
    if (!sendToPAL) {
      panic("ftl: GC triggered while in initialization");
    }

    std::vector<uint32_t> list;
    uint64_t beginAt = tick;

    selectVictimBlock(list, beginAt);

    debugprint(LOG_FTL_PAGE_MAPPING,
               "GC   | On-demand | %u blocks will be reclaimed", list.size());

    doGarbageCollection(list, beginAt);

    debugprint(LOG_FTL_PAGE_MAPPING,
               "GC   | Done | %" PRIu64 " - %" PRIu64 " (%" PRIu64 ")", tick,
               beginAt, beginAt - tick);

    stat.gcCount++;
    stat.reclaimedBlocks += list.size();

    printWLSummary(tick);
  }
}

void WLPageMapping::trimInternal(Request &req, uint64_t &tick) {
  auto mappingList = table.find(req.lpn);

  if (mappingList != table.end()) {
    if (bRandomTweak) {
      pDRAM->read(&(*mappingList), 8 * req.ioFlag.count(), tick);
    }
    else {
      pDRAM->read(&(*mappingList), 8, tick);
    }

    for (uint32_t idx = 0; idx < bitsetSize; idx++) {
      auto &mapping = mappingList->second.at(idx);
      auto block = blocks.find(mapping.first);

      if (block == blocks.end()) {
        panic("Block is not in use");
      }

      block->second.invalidate(mapping.second, idx);
    }

    table.erase(mappingList);

    tick += applyLatency(CPU::FTL__PAGE_MAPPING, CPU::TRIM_INTERNAL);
  }
}

void WLPageMapping::eraseInternal(PAL::Request &req, uint64_t &tick) {
  static uint64_t threshold =
      conf.readUint(CONFIG_FTL, FTL_BAD_BLOCK_THRESHOLD);
  auto block = blocks.find(req.blockIndex);

  if (block == blocks.end()) {
    panic("No such block");
  }

  if (block->second.getValidPageCount() != 0) {
    panic("There are valid pages in victim block");
  }

  block->second.erase();

  pPAL->erase(req, tick);

  uint32_t erasedCount = block->second.getEraseCount();

  if (erasedCount < threshold) {
    auto iter = freeBlocks.end();

    while (true) {
      iter--;

      if (iter->getEraseCount() <= erasedCount) {
        iter++;

        break;
      }

      if (iter == freeBlocks.begin()) {
        break;
      }
    }

    freeBlocks.emplace(iter, std::move(block->second));
    nFreeBlocks++;
  }
  else {
    // Block reached end-of-life. exp(2): record the first such death (host
    // input processed up to this point) but keep running. Retain the block in
    // deadBlocks so it still appears in the wear snapshot.
    if (!firstDeathRecorded) {
      firstDeathRecorded = true;
      firstDeathPrint(
          "algo,host_write_pages,tick,block_idx,erase_count,gc_count\n");
      firstDeathPrint("wl_page_mapping,%" PRIu64 ",%" PRIu64 ",%" PRIu32
                      ",%" PRIu32 ",%" PRIu64 "\n",
                      stat.hostWritePages, getTick(), block->first, erasedCount,
                      stat.gcCount);
    }

    deadBlocks.emplace_back(std::move(block->second));
    // exp(2): if StopAtFirstDeath is set, end the run at the FIRST block death
    // (host input measured to here). Otherwise (exp(1)) run on to full EOL.
    if (conf.readBoolean(CONFIG_FTL, FTL_STOP_AT_FIRST_DEATH)) {
      uint64_t etick = getTick();
      printWLSummary(etick);
      wlSnapshotClear();
      printEraseCountSnapshot(etick);
      fflush(stdout);
      exit(0);
    }
  }

  blocks.erase(block);

  tick += applyLatency(CPU::FTL__PAGE_MAPPING, CPU::ERASE_INTERNAL);
}

float WLPageMapping::calculateWearLeveling() {
  uint64_t totalEraseCnt = 0;
  uint64_t sumOfSquaredEraseCnt = 0;
  uint64_t numOfBlocks = param.totalLogicalBlocks;
  uint64_t eraseCnt;

  for (auto &iter : blocks) {
    eraseCnt = iter.second.getEraseCount();
    totalEraseCnt += eraseCnt;
    sumOfSquaredEraseCnt += eraseCnt * eraseCnt;
  }

  for (auto riter = freeBlocks.rbegin(); riter != freeBlocks.rend(); riter++) {
    eraseCnt = riter->getEraseCount();

    if (eraseCnt == 0) {
      break;
    }

    totalEraseCnt += eraseCnt;
    sumOfSquaredEraseCnt += eraseCnt * eraseCnt;
  }

  if (sumOfSquaredEraseCnt == 0) {
    return -1;
  }

  return (float)totalEraseCnt * totalEraseCnt /
         (numOfBlocks * sumOfSquaredEraseCnt);
}

void WLPageMapping::calculateTotalPages(uint64_t &valid, uint64_t &invalid) {
  valid = 0;
  invalid = 0;

  for (auto &iter : blocks) {
    valid += iter.second.getValidPageCount();
    invalid += iter.second.getDirtyPageCount();
  }
}

void WLPageMapping::getStatList(std::vector<Stats> &list, std::string prefix) {
  Stats temp;

  temp.name = prefix + "wl_page_mapping.gc.count";
  temp.desc = "Total GC count";
  list.push_back(temp);

  temp.name = prefix + "wl_page_mapping.gc.reclaimed_blocks";
  temp.desc = "Total reclaimed blocks in GC";
  list.push_back(temp);

  temp.name = prefix + "wl_page_mapping.gc.superpage_copies";
  temp.desc = "Total copied valid superpages during GC";
  list.push_back(temp);

  temp.name = prefix + "wl_page_mapping.gc.page_copies";
  temp.desc = "Total copied valid pages during GC";
  list.push_back(temp);

  temp.name = prefix + "wl_page_mapping.wear_leveling";
  temp.desc = "Wear-leveling factor";
  list.push_back(temp);

  temp.name = prefix + "wl_page_mapping.wl_migration_count";
  temp.desc = "Total active WL migrations";
  list.push_back(temp);
}

void WLPageMapping::getStatValues(std::vector<double> &values) {
  values.push_back(stat.gcCount);
  values.push_back(stat.reclaimedBlocks);
  values.push_back(stat.validSuperPageCopies);
  values.push_back(stat.validPageCopies);
  values.push_back(calculateWearLeveling());
  values.push_back(stat.wlMigrationCount);

  wlSnapshotClear();
  printEraseCountSnapshot(0);
}

void WLPageMapping::resetStatValues() {
  memset(&stat, 0, sizeof(stat));
}

void WLPageMapping::printWLSummary(uint64_t tick) {
  if (!wlSummaryHeaderWritten) {
    wlSummaryPrint(
        "tick,gc_count,wl_migration_count,n_active_blocks,n_free_blocks,"
        "dead_blocks,min_ec,max_ec,mean_ec,stddev_ec,wl_factor\n");
    wlSummaryHeaderWritten = true;
  }

  uint64_t nActive = blocks.size();
  uint64_t nFree = nFreeBlocks;
  uint64_t nDead = param.totalPhysicalBlocks - nActive - nFree;

  uint64_t minEc = UINT64_MAX;
  uint64_t maxEc = 0;
  double sumEc = 0.0;
  double sumSqEc = 0.0;
  uint64_t count = 0;

  for (auto &iter : blocks) {
    uint64_t ec = iter.second.getEraseCount();
    if (ec < minEc) minEc = ec;
    if (ec > maxEc) maxEc = ec;
    sumEc += ec;
    sumSqEc += (double)ec * ec;
    count++;
  }

  for (auto &iter : freeBlocks) {
    uint64_t ec = iter.getEraseCount();
    if (ec < minEc) minEc = ec;
    if (ec > maxEc) maxEc = ec;
    sumEc += ec;
    sumSqEc += (double)ec * ec;
    count++;
  }

  if (count == 0) {
    return;
  }

  double meanEc = sumEc / count;
  double variance = (sumSqEc / count) - (meanEc * meanEc);
  double stddevEc = (variance > 0.0) ? sqrt(variance) : 0.0;

  float wlFactor = -1.0f;
  if (sumSqEc > 0.0) {
    wlFactor = (float)(sumEc * sumEc) / (count * sumSqEc);
  }

  if (minEc == UINT64_MAX) minEc = 0;

  wlSummaryPrint("%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64
                 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%.3f,%.3f,%.6f\n",
                 tick, stat.gcCount, stat.wlMigrationCount, nActive, nFree,
                 nDead, minEc, maxEc, meanEc, stddevEc, (double)wlFactor);
}

void WLPageMapping::printEraseCountSnapshot(uint64_t tick) {
  wlSnapshotPrint("tick,gc_count,wl_migration_count,block_idx,erase_count,state\n");

  for (auto &iter : blocks) {
    wlSnapshotPrint(
        "%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu32 ",%" PRIu32 ",active\n",
        tick, stat.gcCount, stat.wlMigrationCount,
        iter.first, iter.second.getEraseCount());
  }

  for (auto &iter : freeBlocks) {
    wlSnapshotPrint(
        "%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu32 ",%" PRIu32 ",free\n",
        tick, stat.gcCount, stat.wlMigrationCount,
        iter.getBlockIndex(), iter.getEraseCount());
  }

  for (auto &iter : deadBlocks) {
    wlSnapshotPrint(
        "%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu32 ",%" PRIu32 ",dead\n",
        tick, stat.gcCount, stat.wlMigrationCount,
        iter.getBlockIndex(), iter.getEraseCount());
  }
}

void WLPageMapping::printInitialSnapshot() {
  wlSnapshotInitPrint(
      "tick,gc_count,wl_migration_count,block_idx,erase_count,state\n");

  for (auto &iter : blocks) {
    wlSnapshotInitPrint(
        "0,0,0,%" PRIu32 ",%" PRIu32 ",active\n", iter.first,
        iter.second.getEraseCount());
  }

  for (auto &iter : freeBlocks) {
    wlSnapshotInitPrint("0,0,0,%" PRIu32 ",%" PRIu32 ",free\n",
                        iter.getBlockIndex(), iter.getEraseCount());
  }
}

}  // namespace FTL

}  // namespace SimpleSSD
