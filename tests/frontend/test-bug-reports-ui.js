#!/usr/bin/env node

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const repoRoot = path.resolve(__dirname, "..", "..");
const read = relativePath => fs.readFileSync(path.join(repoRoot, relativePath), "utf8");
const indexSource = read("app/frontend/index.html");
const appShellSource = read("app/frontend/scripts/AppShell.js");
const switchingSource = read("app/frontend/scripts/Views/ViewSwitching.js");
const viewSource = read("app/frontend/scripts/Views/BugReportsView.js");
const i18nSource = read("app/frontend/scripts/I18n.js");
const stylesSource = read("app/frontend/assets/apple-ui.css");
const cacheKey = "20260921-schedule-gc179-fixes-v2";

assert(indexSource.includes('id="navBugReports" data-role-scope="authenticated"'), "Authenticated users need an Issues navigation link.");
assert(indexSource.includes('id="appReportBugButton" data-role-scope="authenticated"'), "The global Report a problem shortcut is missing.");
assert(indexSource.includes('id="bugReportsView"'), "The bug-report workspace is missing.");
assert(indexSource.includes('id="bugReportCreatePanel"'), "Creation must use an in-page panel that cannot be dismissed by an outside click.");
assert(!indexSource.includes('id="bugReportCreatePanel" class="modal'), "Bug-report creation must not be an accidentally dismissible modal.");
assert(indexSource.includes('id="bugReportList" aria-live="polite" aria-busy="false"'), "The inquiry list needs an accessible loading region.");
assert(indexSource.includes('id="bugReportDetail" aria-live="polite" aria-busy="false"'), "The inquiry detail needs an accessible loading region.");
assert(indexSource.includes('id="bugReportDropZone"'), "The inquiry form is missing its image drop zone.");
assert(indexSource.includes('accept="image/png,image/jpeg,image/gif,image/webp"'), "The image picker does not limit selectable formats.");

assert(switchingSource.includes('navBugReports: "bugReportsView"'), "Issues navigation is not mapped to its view.");
assert(switchingSource.includes('showView("bugReportsView")'), "The global shortcut does not navigate to Issues.");
assert(switchingSource.includes("window.openBugReportCreatePanel"), "The global shortcut does not open the creation panel.");
assert(appShellSource.includes('employee: ["selfView", "bugReportsView"]'), "Employees cannot access their inquiry dashboard.");
assert(appShellSource.includes('category === "bug-reports"'), "Bug-report sync changes do not target the inquiry view.");
assert(appShellSource.includes(`scripts/Views/BugReportsView.js?v=${cacheKey}`), "The inquiry view is not lazy-loaded with a fresh cache key.");
assert(indexSource.includes(`assets/apple-ui.css?v=${cacheKey}`), "The inquiry styles are missing a fresh cache key.");
assert(indexSource.includes(`scripts/I18n.js?v=${cacheKey}`), "The inquiry translations are missing a fresh cache key.");
assert(indexSource.includes(`scripts/AppShell.js?v=${cacheKey}`), "The application shell is missing a fresh cache key.");
assert(indexSource.includes(`scripts/Views/ViewSwitching.js?v=${cacheKey}`), "The navigation layer is missing a fresh cache key.");

assert(viewSource.includes('query.set("scope", isManagerUser() ? "all" : "mine")'), "Employee and manager list scopes are not explicit.");
assert(viewSource.includes('fetch(`${apiUrl}bug-reports`'), "The create form is not connected to the API.");
assert(viewSource.includes('fetch(`${apiUrl}bug-reports/${encodeURIComponent(normalizedId)}`'), "Inquiry details are not loaded on demand.");
assert(viewSource.includes('setLoadingState(container, "list", 4)'), "The inquiry list needs a loading skeleton.");
assert(viewSource.includes('setLoadingState(container, "detail", 1)'), "The inquiry detail needs a loading skeleton.");
assert(viewSource.includes('key: "bug-report-create"'), "Duplicate inquiry submissions are not guarded.");
assert(viewSource.includes("form.reportValidity()"), "The create form does not use browser validation.");
assert(viewSource.includes("technicalContext"), "The create form does not capture troubleshooting context.");
assert(viewSource.includes('addEventListener("drop"'), "Screenshots cannot be dropped into the inquiry form.");
assert(viewSource.includes('"X-SAPHIR-Expected-Revision": String(report.revision)'), "Image uploads do not use optimistic concurrency.");
assert(viewSource.includes("BUG_REPORT_ATTACHMENT_MAX_BYTES"), "The browser does not guard the image size before upload.");
assert(viewSource.includes("loadBugReportAttachmentPreviews"), "Saved screenshots are not loaded securely in the detail pane.");
assert(viewSource.includes("isSuperAdminUser()"), "The triage editor is not restricted to super admins in the UI.");
assert(viewSource.includes('id="bugReportTriageForm"'), "The super-admin triage panel is missing.");
assert(viewSource.includes('method: "PATCH"'), "Triage changes are not connected to the revision-aware API.");
assert(viewSource.includes("expectedRevision: report.revision"), "Triage changes do not use optimistic concurrency.");
assert(viewSource.includes("response.status === 409"), "Triage conflicts do not reload the latest shared version.");
assert(viewSource.includes("renderBugReportHistory(report)"), "Inquiry activity is not shown in the detail pane.");
assert(viewSource.includes("renderBugReportComments(report)"), "The inquiry discussion is not rendered in the detail pane.");
assert(viewSource.includes('id="bugReportCommentForm"'), "The inquiry comment composer is missing.");
assert(viewSource.includes('/comments`, {'), "The comment composer is not connected to the API.");
assert(viewSource.includes("expectedRevision: report.revision, body"), "Comments do not use optimistic concurrency.");
assert(viewSource.includes("response.status === 409"), "Comment conflicts do not reload the latest discussion.");
assert(viewSource.includes('maxlength="3000"'), "The comment length limit is missing from the UI.");
assert(viewSource.includes('report.status || "").toLowerCase() === "closed"'), "Closed inquiries do not lock their discussion.");
assert(viewSource.includes("renderBugReportList();") && viewSource.includes("renderBugReportDetail(bugReportViewState.selectedReport);"), "Language changes do not rerender both inquiry panes.");

for (const key of [
  "nav.bugReports",
  "workspace.bugReports",
  "bugReports.reportProblem",
  "bugReports.queueTitle",
  "bugReports.createSuccess",
  "bugReports.images",
  "bugReports.createPartialSuccess",
  "bugReports.triageTitle",
  "bugReports.triageConflict",
  "bugReports.activity",
  "bugReports.discussion",
  "bugReports.commentConflict",
]) {
  assert.equal((i18nSource.match(new RegExp(`"${key.replace(/\./g, "\\.")}"`, "g")) || []).length, 2, `${key} must exist in English and French.`);
}

assert(stylesSource.includes(".bug-report-workspace-grid"), "The inquiry list/detail layout is missing.");
assert(stylesSource.includes(".bug-report-card.is-selected"), "The selected inquiry has no visible state.");
assert(stylesSource.includes(".bug-report-drop-zone.is-dragging"), "The image drop zone has no drag feedback.");
assert(stylesSource.includes(".bug-report-upload-spinner"), "Image uploads have no loading animation.");
assert(stylesSource.includes(".bug-report-triage-panel"), "The triage editor has no dedicated visual hierarchy.");
assert(stylesSource.includes(".bug-report-history-list"), "The inquiry activity timeline has no styling.");
assert(stylesSource.includes(".bug-report-comment-thread"), "The inquiry discussion thread has no styling.");
assert(stylesSource.includes(".bug-report-comments-closed"), "Closed inquiry discussions have no visible state.");
assert(stylesSource.includes("@media (max-width: 680px)"), "The inquiry dashboard has no small-screen layout.");

console.log("Bug-report phase 5 UI contract passed: attributed comments, shared discussion, conflict recovery, and closed-state protection are connected.");
