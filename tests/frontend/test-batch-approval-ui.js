#!/usr/bin/env node

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const repoRoot = path.resolve(__dirname, "..", "..");
const approvalsPath = path.join(repoRoot, "app/frontend/scripts/Views/ApprovalsView.js");
const approvalsSource = fs.readFileSync(approvalsPath, "utf8");
const helperStart = approvalsSource.indexOf("function normalizeBatchApprovalResult");
const helperEnd = approvalsSource.indexOf("async function approveFilteredEntries", helperStart);

assert(helperStart >= 0 && helperEnd > helperStart, "Unable to locate the batch-result normalization helper.");
assert.equal(
  approvalsSource.includes("result.updatedCount || filteredPendingEntries.length"),
  false,
  "A zero updatedCount must never fall back to the number of selected entries.",
);

const context = { Number, Math, String, Array };
vm.createContext(context);
vm.runInContext(
  `${approvalsSource.slice(helperStart, helperEnd)}
this.normalizeBatchApprovalResult = normalizeBatchApprovalResult;`,
  context,
);

const noUpdates = context.normalizeBatchApprovalResult({
  outcome: "none",
  requestedCount: 3,
  updatedCount: 0,
  failedCount: 3,
  failures: [{ index: 0 }, { index: 1 }, { index: 2 }],
}, 99);
assert.equal(noUpdates.requestedCount, 3);
assert.equal(noUpdates.updatedCount, 0, "A zero update result was replaced by a fallback count.");
assert.equal(noUpdates.failedCount, 3);
assert.equal(noUpdates.outcome, "none");
assert.equal(Array.from(noUpdates.failures).length, 3);

const missingUpdatedCount = context.normalizeBatchApprovalResult({
  requestedCount: 4,
  failedCount: 4,
}, 12);
assert.equal(missingUpdatedCount.updatedCount, 0, "A missing updatedCount must fail closed.");
assert.equal(missingUpdatedCount.outcome, "none");

const partial = context.normalizeBatchApprovalResult({
  outcome: "partial",
  requestedCount: 4,
  updatedCount: 2,
  failedCount: 2,
}, 4);
assert.equal(partial.updatedCount, 2);
assert.equal(partial.failedCount, 2);
assert.equal(partial.outcome, "partial");

const legacySuccess = context.normalizeBatchApprovalResult({ updatedCount: 2 }, 2);
assert.equal(legacySuccess.requestedCount, 2);
assert.equal(legacySuccess.updatedCount, 2);
assert.equal(legacySuccess.outcome, "success");

console.log("Batch approval UI result-contract test passed.");
