#!/usr/bin/env node

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const repoRoot = path.resolve(__dirname, "..");
const read = relativePath => fs.readFileSync(path.join(repoRoot, relativePath), "utf8");
const utilitiesSource = read("apps/admin/frontend/scripts/Utilities.js");
const selfSource = read("apps/admin/frontend/scripts/Views/SelfView.js");
const dashboardSource = read("apps/admin/frontend/scripts/Views/DashboardView.js");
const approvalsSource = read("apps/admin/frontend/scripts/Views/ApprovalsView.js");
const employeesSource = read("apps/admin/frontend/scripts/Views/EmployeesView.js");
const projectsSource = read("apps/admin/frontend/scripts/Views/ProjectsView.js");
const i18nSource = read("apps/admin/frontend/scripts/I18n.js");
const appShellSource = read("apps/admin/frontend/scripts/AppShell.js");
const indexSource = read("apps/admin/frontend/index.html");

const helperStart = utilitiesSource.indexOf("function getEntryWorkComment");
const helperEnd = utilitiesSource.indexOf("function formatTimeString", helperStart);
assert(helperStart >= 0 && helperEnd > helperStart, "Unable to locate the work-comment helpers.");

const context = {
  String,
  escapeHtml(value) {
    return String(value)
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;")
      .replaceAll('"', "&quot;")
      .replaceAll("'", "&#039;");
  },
  t(key) {
    return key === "shared.employeeWorkComment" ? "Employee comment" : key;
  },
};
vm.createContext(context);
vm.runInContext(`${utilitiesSource.slice(helperStart, helperEnd)}
this.workCommentApi = { getEntryWorkComment, renderEntryWorkComment };`, context);

assert.equal(context.workCommentApi.getEntryWorkComment({ workComment: "  Reconciled invoices  " }), "Reconciled invoices");
assert.equal(
  context.workCommentApi.getEntryWorkComment({ workComment: "", diverseSummary: "  Legacy diverse task  " }),
  "Legacy diverse task",
  "Legacy Diverse summaries must remain visible.",
);
assert.equal(
  context.workCommentApi.getEntryWorkComment({ workComment: "   ", diverseSummary: "  Legacy diverse task  " }),
  "Legacy diverse task",
  "Whitespace-only canonical values must not hide a legacy Diverse summary.",
);
assert.equal(
  context.workCommentApi.getEntryWorkComment({ workComment: "Current", diverseSummary: "Legacy" }),
  "Current",
  "The canonical overtime comment must take precedence.",
);
assert.equal(context.workCommentApi.getEntryWorkComment(null), "");

const escapedMarkup = context.workCommentApi.renderEntryWorkComment({ workComment: '<script>alert("x")</script>' });
assert.match(escapedMarkup, /Employee comment/, "The employee comment needs a visible label.");
assert.match(escapedMarkup, /&lt;script&gt;/, "Comment content must be HTML escaped.");
assert.doesNotMatch(escapedMarkup, /<script>/, "Raw comment HTML reached the rendered markup.");
assert.equal(context.workCommentApi.renderEntryWorkComment({ workComment: "" }), "");

assert.match(utilitiesSource, /entry\.workComment/, "Entry search must include overtime comments.");
assert.match(indexSource, /id="selfWorkCommentInput"[\s\S]*?required[\s\S]*?aria-required="true"/, "Clock-out needs an accessible required comment field.");
assert.match(indexSource, /id="updateWorkComment"/, "The manager editor must expose overtime comments.");
assert.doesNotMatch(indexSource, /id="selfDiverseSummaryInput"/, "The clock-out input must not remain Diverse-only.");
for (const textareaId of ["selfWorkCommentInput", "updateWorkComment", "updateDiverseSummary"]) {
  assert.match(indexSource, new RegExp(`id="${textareaId}"[^>]*maxlength="1000"`), `${textareaId} must enforce the shared comment length limit.`);
}

assert.match(selfSource, /if \(type === "out" && !workComment\)/, "Every clock-out must reject an empty comment.");
assert.match(selfSource, /punchPayload\.workComment = workComment/, "Normal overtime clock-out must send workComment to the backend.");
assert.match(selfSource, /punchPayload\.diverseSummary = workComment/, "Diverse clock-out must preserve the diverseSummary contract.");
assert.match(selfSource, /JSON\.stringify\(punchPayload\)/, "Clock-out must submit the type-specific comment payload.");
assert.match(selfSource, /renderEntryWorkComment\(entry, \{ compact: true \}\)/, "Employees must see their saved comments in the calendar.");

assert.match(dashboardSource, /renderDashboardApprovalQueue[\s\S]*?renderEntryWorkComment\(entry\)/, "Dashboard approvals must show employee comments.");
assert.match(dashboardSource, /data-workcomment=/, "Entry edit buttons must carry the saved overtime comment.");
assert.match(dashboardSource, /workComment === originalWorkComment/, "Comment edits must participate in change detection.");
assert.match(dashboardSource, /reasonCode, workComment, status:/, "Normal entry updates must persist workComment.");
assert.match(approvalsSource, /buildApprovalCard[\s\S]*?renderEntryWorkComment\(entry\)/, "Review cards must show employee comments.");
assert.match(employeesSource, /renderPeopleProjectEntryRows[\s\S]*?renderEntryWorkComment\(entry, \{ compact: true \}\)/, "Employee project rows must show employee comments.");
assert.match(employeesSource, /data-workcomment=/, "Employee calendar edit buttons must retain the comment contract.");
assert.match(projectsSource, /renderProjectEmployeeEntries[\s\S]*?renderEntryWorkComment\(entry, \{ compact: true \}\)/, "Project drilldowns must show employee comments.");

for (const text of ["Employee comment", "Commentaire de l’employé", "What did you work on?", "Sur quoi avez-vous travaillé?"]) {
  assert(i18nSource.includes(text), `Missing bilingual work-comment copy: ${text}`);
}

const workCommentViewCacheVersions = {
  EmployeesView: "20260803-gc179-codes",
  DashboardView: "20260803-work-comments",
  ApprovalsView: "20260803-work-comments",
  ProjectsView: "20260803-work-comments",
};
for (const [view, version] of Object.entries(workCommentViewCacheVersions)) {
  assert(
    appShellSource.includes(`scripts/Views/${view}.js?v=${version}`),
    `${view} is missing its work-comment cache buster.`,
  );
}
const workCommentAssetCacheVersions = {
  "apple-ui.css": "20260803-work-comments",
  "I18n.js": "20260803-gc179-codes",
  "Utilities.js": "20260803-gc179-codes",
  "AppShell.js": "20260803-gc179-codes",
  "SelfView.js": "20260803-work-comments",
};
for (const [asset, version] of Object.entries(workCommentAssetCacheVersions)) {
  assert(indexSource.includes(`${asset}?v=${version}`), `${asset} is missing its work-comment cache buster.`);
}

console.log("Work-comment frontend contract tests passed.");
