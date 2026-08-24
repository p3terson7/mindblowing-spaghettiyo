#!/usr/bin/env node

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const repoRoot = path.resolve(__dirname, "..", "..");
const read = relativePath => fs.readFileSync(path.join(repoRoot, relativePath), "utf8");
const approvalsSource = read("app/frontend/scripts/Views/ApprovalsView.js");
const i18nSource = read("app/frontend/scripts/I18n.js");
const indexSource = read("app/frontend/index.html");
const appShellSource = read("app/frontend/scripts/AppShell.js");
const cssSource = read("app/frontend/assets/apple-ui.css");
const cacheRevision = "20260824-review-attention-tab-v1";

const helperStart = approvalsSource.indexOf("const REVIEW_ISSUE_I18N_KEYS");
const helperEnd = approvalsSource.indexOf("function renderReviewIssues", helperStart);
assert(helperStart >= 0 && helperEnd > helperStart, "Unable to locate Review attention helpers.");

const attentionContext = { Array, Boolean, Object, Set, String };
vm.createContext(attentionContext);
vm.runInContext(
  `${approvalsSource.slice(helperStart, helperEnd)}\nthis.getReviewAttentionEntries = getReviewAttentionEntries;`,
  attentionContext,
);

const attentionEntries = attentionContext.getReviewAttentionEntries([
  { entryId: "pending-known", status: "pending", reviewIssues: [{ code: "shortOvertime" }] },
  { entryId: "approved-unknown", status: "approved", reviewIssues: [{ code: "futureServerCode" }] },
  { entryId: "rejected-flag", status: "rejected", hasReviewIssues: true, reviewIssues: [] },
  { entryId: "clean", status: "pending", reviewIssues: [] },
  { entryId: "not-an-issue", status: "pending" },
]);
assert.deepEqual(
  Array.from(attentionEntries, entry => entry.entryId),
  ["pending-known", "approved-unknown", "rejected-flag"],
  "The attention tab must keep every flagged entry, including unknown future issue codes and non-pending states, in source order.",
);

const labelsStart = approvalsSource.indexOf("function updateApprovalTabLabels");
const labelsEnd = approvalsSource.indexOf("const REVIEW_ISSUE_I18N_KEYS", labelsStart);
assert(labelsStart >= 0 && labelsEnd > labelsStart, "Unable to locate Review tab-label helper.");
const tabElements = {
  "pending-tab": {},
  "attention-tab": {},
  "rejected-tab": {},
  "approved-tab": {},
};
const labelsContext = {
  document: { getElementById: id => tabElements[id] },
  t: (key, values) => `${key}:${values.count}`,
};
vm.createContext(labelsContext);
vm.runInContext(
  `${approvalsSource.slice(labelsStart, labelsEnd)}\nthis.updateApprovalTabLabels = updateApprovalTabLabels;`,
  labelsContext,
);
labelsContext.updateApprovalTabLabels([{}], [{}, {}], [{}, {}, {}], [{}, {}, {}, {}]);
assert.equal(tabElements["pending-tab"].textContent, "review.pending:1");
assert.equal(tabElements["attention-tab"].textContent, "review.attentionTab:2", "The attention-tab count was not updated.");
assert.equal(tabElements["rejected-tab"].textContent, "review.rejected:3");
assert.equal(tabElements["approved-tab"].textContent, "review.approved:4");

const listStart = approvalsSource.indexOf("function renderApprovalsList");
const listEnd = approvalsSource.indexOf("function renderApprovalTabsFromFiltered", listStart);
assert(listStart >= 0 && listEnd > listStart, "Unable to locate Review list renderer.");
const attentionContainer = {};
const listContext = {
  document: { getElementById: id => (id === "attentionContainer" ? attentionContainer : null) },
  createEmptyState: message => `empty:${message}`,
  t: key => key,
};
vm.createContext(listContext);
vm.runInContext(
  `${approvalsSource.slice(listStart, listEnd)}\nthis.renderApprovalsList = renderApprovalsList;`,
  listContext,
);
listContext.renderApprovalsList("attentionContainer", [], true, "review.noneAttention");
assert.equal(attentionContainer.innerHTML, "empty:review.noneAttention", "The attention tab must use its dedicated empty state.");

assert.match(
  indexSource,
  /id="attention-tab"[^>]*data-bs-toggle="tab"[^>]*data-bs-target="#attentionContainer"[^>]*role="tab"[^>]*aria-controls="attentionContainer"[^>]*aria-selected="false"/,
  "The attention tab must be an accessible Bootstrap tab control.",
);
assert.match(
  indexSource,
  /id="attentionContainer"[^>]*role="tabpanel"[^>]*aria-labelledby="attention-tab"/,
  "The attention tab needs its matching labelled panel.",
);
assert.match(
  approvalsSource,
  /const attentionEntries = getReviewAttentionEntries\(entries\);[\s\S]*?renderApprovalsList\("attentionContainer", attentionEntries, true, t\("review.noneAttention"\)\);/,
  "The attention tab must receive the same already-filtered entries as the state tabs.",
);
assert.match(
  approvalsSource,
  /const canReview = showActions && isPending && !isEntryForgottenClockOut\(entry\) && canApproveEntry\(entry\);/,
  "Historical entries shown in the attention tab must not receive pending-only approval actions.",
);
assert.match(approvalsSource, /setLoadingState\("attentionContainer", "queue", 2\);/, "The attention tab should show a loading state while Review refreshes.");
assert.match(cssSource, /#attentionContainer \.review-card\s*\{/, "Attention entries need the same visible review-card affordance as the other tabs.");

for (const expectedCopy of [
  '"review.attentionTab": "Needs attention ({count})"',
  '"review.noneAttention": "No entries need attention."',
  '"review.attentionTab": "À vérifier ({count})"',
  '"review.noneAttention": "Aucune entrée à vérifier."',
]) {
  assert(i18nSource.includes(expectedCopy), `Missing attention-tab localization: ${expectedCopy}`);
}

assert(indexSource.includes(`assets/apple-ui.css?v=${cacheRevision}`), "The attention-tab styles are missing a cache-busting revision.");
assert(indexSource.includes(`scripts/I18n.js?v=${cacheRevision}`), "The attention-tab copy is missing a cache-busting revision.");
assert(appShellSource.includes(`ApprovalsView.js?v=${cacheRevision}`), "The lazy Review view is missing a cache-busting revision.");

console.log("Review attention tab UI tests passed.");
