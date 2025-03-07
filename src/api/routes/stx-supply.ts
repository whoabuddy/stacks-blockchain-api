import * as express from 'express';
import { addAsync, RouterWithAsync } from '@awaitjs/express';
import BigNumber from 'bignumber.js';
import { DataStore } from '../../datastore/common';
import { microStxToStx, STACKS_DECIMAL_PLACES, TOTAL_STACKS } from '../../helpers';
import {
  GetStxCirculatingSupplyPlainResponse,
  GetStxSupplyLegacyFormatResponse,
  GetStxSupplyResponse,
  GetStxTotalSupplyPlainResponse,
} from '@stacks/stacks-blockchain-api-types';
import { getBlockParams } from '../query-helpers';

export function createStxSupplyRouter(db: DataStore): RouterWithAsync {
  const router = addAsync(express.Router());

  async function getStxSupplyInfo(
    args:
      | {
          blockHeight: number;
        }
      | {
          includeUnanchored: boolean;
        }
  ): Promise<{
    unlockedPercent: string;
    totalStx: string;
    unlockedStx: string;
    blockHeight: number;
  }> {
    const { stx: unlockedSupply, blockHeight } = await db.getUnlockedStxSupply(args);
    const totalMicroStx = new BigNumber(TOTAL_STACKS).shiftedBy(STACKS_DECIMAL_PLACES);
    const unlockedPercent = new BigNumber(unlockedSupply.toString())
      .div(totalMicroStx)
      .times(100)
      .toFixed(2);
    return {
      unlockedPercent,
      totalStx: microStxToStx(totalMicroStx),
      unlockedStx: microStxToStx(unlockedSupply),
      blockHeight: blockHeight,
    };
  }

  router.getAsync('/', async (req, res, next) => {
    const blockParams = getBlockParams(req, res, next);
    const supply = await getStxSupplyInfo(blockParams);
    const result: GetStxSupplyResponse = {
      unlocked_percent: supply.unlockedPercent,
      total_stx: supply.totalStx,
      unlocked_stx: supply.unlockedStx,
      block_height: supply.blockHeight,
    };
    res.json(result);
  });

  router.getAsync('/total/plain', async (req, res) => {
    const supply = await getStxSupplyInfo({ includeUnanchored: false });
    const result: GetStxTotalSupplyPlainResponse = supply.totalStx;
    res.type('text/plain').send(result);
  });

  router.getAsync('/circulating/plain', async (req, res) => {
    const supply = await getStxSupplyInfo({ includeUnanchored: false });
    const result: GetStxCirculatingSupplyPlainResponse = supply.unlockedStx;
    res.type('text/plain').send(result);
  });

  router.getAsync('/legacy_format', async (req, res, next) => {
    const blockParams = getBlockParams(req, res, next);
    const supply = await getStxSupplyInfo(blockParams);
    const result: GetStxSupplyLegacyFormatResponse = {
      unlockedPercent: supply.unlockedPercent,
      totalStacks: supply.totalStx,
      totalStacksFormatted: new BigNumber(supply.totalStx).toFormat(STACKS_DECIMAL_PLACES, 8),
      unlockedSupply: supply.unlockedStx,
      unlockedSupplyFormatted: new BigNumber(supply.unlockedStx).toFormat(STACKS_DECIMAL_PLACES, 8),
      blockHeight: supply.blockHeight.toString(),
    };
    res.json(result);
  });

  return router;
}
