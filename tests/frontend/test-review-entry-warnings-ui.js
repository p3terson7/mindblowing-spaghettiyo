#!/usr/bin/env node

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const repoRoot = path.resolve(__dirname, "..", "..");
const read = relativePath => fs.readFileSync(path.join(repoRoot, relativePath), "utf8");
const approvalsSource = read("app/frontend/scripts/Views/ApprovalsView.js");
const i18nSource = read("app/frontend/scripts/I18n.js");
const cssSource = read("app/frontend/assets/apple-ui.css");
const indexSource = read("app/frontend/index.html");
const appShellSource = read("app/frontend/scripts/AppShell.js");

const helperStart = approvalsSource.indexOf("const REVIEW_ISSUE_I18N_KEYS");
const helperEnd = approvalsSource.indexOf("function buildApprovalCard", helperStart);
assert(helperStart >= 0 && helperEnd > helperStart, "Unable to locate Review issue rendering helpers.");

const translations = {
  "review.attention": "Needs attention",
  "review.issue.shortOvertime": "Less than 15 minutes of overtime was worked.",
  "review.issue.clockOutMissing": "Clock-out is missing; complete this entry before reviewing it.",
  "review.issue.invalidPunchTimes": "Clock-in and clock-out times are invalid; verify this entry.",
  "review.issue.generic": "This entry needs to be checked.",
};
const context = {
  Array,
  Boolean,
  Object,
  Set,
  String,
  escapeHtml(value) {
    return String(value)
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;")
      .replaceAll('"', "&quot;")
      .replaceAll("'", "&#39;");
  },
  t(key) {
    return translations[key] || key;
  },
};
vm.createContext(context);
vm.runInContext(
  `${approvalsSource.slice(helperStart, helperEnd)}\nthis.getReviewIssueCodes = getReviewIssueCodes;\nthis.renderReviewIssues = renderReviewIssues;`,
  context,
);

assert.deepEqual(
  Array.from(context.getReviewIssueCodes({
    reviewIssues: [
      { code: "shortOvertime", actualSeconds: 240, creditedSeconds: 0 },
      "clockOutMissing",
      { issueCode: "invalidPunchTimes" },
      "shortOvertime",
      "unknownServerCode",
    ],
  })),
  ["shortovertime", "clockoutmissing", "invalidpunchtimes"],
  "Review must recognize the backend's structured issue objects, de-duplicate them, and safely ignore unknown codes.",
);

const issueMarkup = context.renderReviewIssues({
  hasReviewIssues: true,
  reviewIssues: [
    { code: "shortOvertime", actualSeconds: 240, creditedSeconds: 0 },
    { code: "clockOutMissing" },
    { code: "invalidPunchTimes" },
  ],
});
assert.match(issueMarkup, /class="review-card-attention"/, "Review issues need a distinct attention section.");
assert.match(issueMarkup, /Needs attention/, "The attention section is missing its label.");
assert.match(issueMarkup, /Less than 15 minutes of overtime was worked\./, "The short-overtime explanation is missing.");
assert.match(issueMarkup, /Clock-out is missing/, "The missing clock-out explanation is missing.");
assert.match(issueMarkup, /Clock-in and clock-out times are invalid/, "The invalid-time explanation is missing.");
assert.equal(context.renderReviewIssues({ reviewIssues: [] }), "", "Entries without review issues must not render an empty attention box.");
assert.match(
  context.renderReviewIssues({ hasReviewIssues: true, reviewIssues: [{ code: "futureServerCode" }] }),
  /This entry needs to be checked\./,
  "An unknown backend issue must fall back to safe generic copy instead of rendering raw server text.",
);

for (const expectedCopy of [
  '"review.attention": "Needs attention"',
  '"review.issue.shortOvertime": "Less than 15 minutes of overtime was worked."',
  '"review.issue.clockOutMissing": "Clock-out is missing; complete this entry before reviewing it."',
  '"review.issue.invalidPunchTimes": "Clock-in and clock-out times are invalid; verify this entry."',
  '"review.attention": "À vérifier"',
  '"review.issue.shortOvertime": "Moins de 15 minutes de temps supplémentaire effectué."',
  '"review.issue.clockOutMissing": "Punch out manquant : complétez l\'entrée avant de la réviser."',
  '"review.issue.invalidPunchTimes": "Heures de punch invalides : vérifiez cette entrée."',
]) {
  assert(i18nSource.includes(expectedCopy), `Missing Review issue localization: ${expectedCopy}`);
}

assert.match(cssSource, /\.review-card-attention\s*\{/, "The Review attention section needs a dedicated visual treatment.");
assert.match(cssSource, /\.review-card-attention-title\s*\{/, "The attention label needs a dedicated style.");
assert.match(cssSource, /\.review-card-attention-list\s*\{/, "The issue list needs a dedicated style.");
assert(indexSource.includes("assets/apple-ui.css?v=20260824-review-attention-tab-v1"), "The Review attention styles are missing a cache-busting revision.");
assert(indexSource.includes("scripts/I18n.js?v=20260824-review-attention-tab-v1"), "The Review attention copy is missing a cache-busting revision.");
assert(appShellSource.includes("ApprovalsView.js?v=20260824-review-attention-tab-v1"), "The lazy Review view is missing a cache-busting revision.");

console.log("Review entry warning UI tests passed.");
