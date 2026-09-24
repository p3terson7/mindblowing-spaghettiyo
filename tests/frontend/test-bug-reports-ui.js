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
const cacheKey = "20260924-bug-report-minimal-v3";

assert(indexSource.includes('id="navBugReports" data-role-scope="authenticated"'), "Authenticated users need an Issues navigation link.");
assert(indexSource.includes('id="appReportBugButton" data-role-scope="authenticated"'), "The global Report a problem shortcut is missing.");
assert(indexSource.includes('id="bugReportsView"'), "The bug-report workspace is missing.");
assert(indexSource.includes('id="bugReportCreatePanel"'), "Creation must use an in-page panel that cannot be dismissed by an outside click.");
assert(!indexSource.includes('id="bugReportCreatePanel" class="modal'), "Bug-report creation must not be an accidentally dismissible modal.");
assert(indexSource.includes('id="bugReportList" aria-live="polite" aria-busy="false"'), "The inquiry list needs an accessible loading region.");
assert(indexSource.includes('id="bugReportDetail" aria-live="polite" aria-busy="false"'), "The inquiry detail needs an accessible loading region.");
assert(indexSource.includes('id="bugReportDropZone"'), "The inquiry form is missing its image drop zone.");
assert(indexSource.includes('accept="image/png,image/jpeg,image/gif,image/webp"'), "The image picker does not limit selectable formats.");
assert(indexSource.includes('id="bugReportColorCodeFilter"'), "The inquiry list is missing its color-code filter.");
assert(!indexSource.includes('id="bugReportPriorityFilter"'), "The old priority filter is still visible.");
assert(!indexSource.includes('<option value="unranked"'), "The list filter still exposes a redundant no-color option.");
assert(!indexSource.includes('data-i18n="bugReports.queueKicker"'), "The bug list still has a redundant eyebrow label.");
assert(!indexSource.includes('data-i18n="bugReports.queueHint"'), "The bug list still has explanatory filler copy.");
assert(!indexSource.includes('data-i18n="bugReports.newKicker"'), "The create panel still repeats its title.");
assert(!indexSource.includes('data-i18n="bugReports.newHint"'), "The create panel still has filler copy above the form.");

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
assert(!viewSource.includes("renderBugReportHistory"), "The removed Activity section is still rendered.");
assert(!viewSource.includes("report.assignedTo"), "Assignment still appears in the inquiry dashboard.");
assert(!viewSource.includes('id="bugReportTriageAssignee"'), "The follow-up editor still contains an assignee control.");
assert(viewSource.includes("renderBugReportComments(report)"), "The inquiry discussion is not rendered in the detail pane.");
assert(viewSource.includes('id="bugReportCommentForm"'), "The inquiry comment composer is missing.");
assert(viewSource.includes('/comments`, {'), "The comment composer is not connected to the API.");
assert(viewSource.includes("expectedRevision: report.revision, body"), "Comments do not use optimistic concurrency.");
assert(viewSource.includes("response.status === 409"), "Comment conflicts do not reload the latest discussion.");
assert(viewSource.includes('maxlength="3000"'), "The comment length limit is missing from the UI.");
assert(viewSource.includes('report.status || "").toLowerCase() === "closed"'), "Closed inquiries do not lock their discussion.");
assert(viewSource.includes('class="bug-report-attachment-preview is-loading"'), "Saved screenshots do not render as interactive previews.");
assert(!viewSource.includes('download="${escapeHtml(attachment.fileName)}"'), "Clicking a screenshot still downloads it.");
assert(viewSource.includes("openBugReportImageViewer"), "Saved screenshots do not open in the large image viewer.");
assert(viewSource.includes("setBugReportImageViewerActualSize"), "The image viewer cannot switch to full resolution.");
assert(viewSource.includes('event.key === "Escape"'), "The image viewer cannot be closed with Escape.");
assert(viewSource.includes("renderBugReportList();") && viewSource.includes("renderBugReportDetail(bugReportViewState.selectedReport);"), "Language changes do not rerender both inquiry panes.");
assert(viewSource.includes("BUG_REPORT_COLOR_CODE_KEYS"), "Stored inquiry rankings are not mapped to color codes.");
assert(viewSource.includes("bug-report-color-code"), "Inquiry cards do not display their color code.");
assert(viewSource.includes("syncBugReportColorSelect"), "Color-code selectors do not reflect their current color.");
assert(viewSource.includes('normalized === "unranked"'), "Uncolored bugs still render a redundant gray badge.");
assert(!viewSource.includes('t("bugReports.discussionHint")'), "The discussion heading still has filler copy.");
assert(!viewSource.includes('t("bugReports.selectHint")'), "The empty detail pane still explains the obvious.");
assert(!viewSource.includes("bug-report-priority"), "The old priority badge is still rendered.");
assert(!i18nSource.includes("Signalement") && !i18nSource.includes("signalement"), "The French UI still repeats the vague Signalement wording.");
assert(!i18nSource.includes("Aucune couleur"), "The French UI still exposes the redundant Aucune couleur label.");

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
  "bugReports.actualSize",
  "bugReports.fitImage",
  "bugReports.closeImage",
  "bugReports.discussion",
  "bugReports.commentConflict",
  "bugReports.colorCode",
  "bugReports.allColorCodes",
  "bugReports.colorNone",
  "bugReports.colorRed",
  "bugReports.colorOrange",
  "bugReports.colorYellow",
  "bugReports.colorBlue",
]) {
  assert.equal((i18nSource.match(new RegExp(`"${key.replace(/\./g, "\\.")}"`, "g")) || []).length, 2, `${key} must exist in English and French.`);
}

assert(stylesSource.includes(".bug-report-workspace-grid"), "The inquiry list/detail layout is missing.");
assert(stylesSource.includes(".bug-report-card.is-selected"), "The selected inquiry has no visible state.");
assert(stylesSource.includes(".bug-report-drop-zone.is-dragging"), "The image drop zone has no drag feedback.");
assert(stylesSource.includes(".bug-report-upload-spinner"), "Image uploads have no loading animation.");
assert(stylesSource.includes(".bug-report-triage-panel"), "The triage editor has no dedicated visual hierarchy.");
assert(!stylesSource.includes(".bug-report-history-list"), "Obsolete Activity timeline styles remain.");
assert(stylesSource.includes(".bug-report-image-viewer"), "The large image viewer has no styling.");
assert(stylesSource.includes(".bug-report-image-viewer.is-actual-size"), "The image viewer has no full-resolution mode.");
assert(stylesSource.includes(".bug-report-comment-thread"), "The inquiry discussion thread has no styling.");
assert(stylesSource.includes(".bug-report-comments-closed"), "Closed inquiry discussions have no visible state.");
assert(stylesSource.includes(".bug-report-color-dot"), "Color-code badges do not have a visible color marker.");
assert(stylesSource.includes(".bug-report-card-color-p1"), "Red-coded inquiry cards have no color treatment.");
assert(stylesSource.includes(".bug-report-card-color-p4"), "Blue-coded inquiry cards have no color treatment.");
assert(stylesSource.includes(".bug-report-color-select-p1"), "Color-code selectors do not show the selected color.");
assert(!stylesSource.includes(".bug-report-priority"), "Obsolete priority badge styles remain.");
assert(stylesSource.includes("@media (max-width: 680px)"), "The inquiry dashboard has no small-screen layout.");

console.log("Bug-report UI contract passed: color codes, shared discussion, and large image previews are connected.");
