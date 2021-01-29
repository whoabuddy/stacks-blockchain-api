import * as express from 'express';
import { addAsync, RouterWithAsync } from '@awaitjs/express';
import { RosettaBlock, RosettaBlockResponse } from '@blockstack/stacks-blockchain-api-types';
import { DataStore } from '../../../datastore/common';
import {
  getRosettaTransactionFromDataStore,
  getRosettaBlockFromDataStore,
} from '../../controllers/db-controller';
import { has0xPrefix } from '../../../helpers';
import { RosettaErrors } from '../../rosetta-constants';
import { rosettaValidateRequest, ValidSchema, makeRosettaError } from '../../rosetta-validate';
import { ChainID } from '@stacks/transactions';

export function createRosettaBlockRouter(db: DataStore, chainId: ChainID): RouterWithAsync {
  const router = addAsync(express.Router());
  router.use(express.json());

  router.postAsync('/', async (req, res) => {
    const valid: ValidSchema = await rosettaValidateRequest(req.originalUrl, req.body, chainId);
    if (!valid.valid) {
      res.status(400).json(makeRosettaError(valid));
      return;
    }

    let block_hash = req.body.block_identifier?.hash;
    const index = req.body.block_identifier?.index;
    if (block_hash && !has0xPrefix(block_hash)) {
      block_hash = '0x' + block_hash;
    }

    const block = await getRosettaBlockFromDataStore(db, block_hash, index);

    if (!block.found) {
      res.status(404).json(RosettaErrors.blockNotFound);
      return;
    }
    const blockResponse: RosettaBlockResponse = {
      block: block.result,
    };
    res.json(blockResponse);
  });

  router.postAsync('/transaction', async (req, res) => {
    const valid: ValidSchema = await rosettaValidateRequest(req.originalUrl, req.body, chainId);
    if (!valid.valid) {
      res.status(400).json(makeRosettaError(valid));
      return;
    }

    let tx_hash = req.body.transaction_identifier.hash;
    if (!has0xPrefix(tx_hash)) {
      tx_hash = '0x' + tx_hash;
    }

    const transaction = await getRosettaTransactionFromDataStore(tx_hash, db);
    if (!transaction.found) {
      res.status(404).json(RosettaErrors.transactionNotFound);
      return;
    }

    res.json(transaction.result);
  });

  return router;
}
