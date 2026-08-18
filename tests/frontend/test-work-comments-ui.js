#!/usr/bin/env node

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const repoRoot = path.resolve(__dirname, "..", "..");
const read = relativePath => fs.readFileSync(path.join(repoRoot, relativePath), "utf8");
const utilitiesSource = read("app/frontend/scripts/Utilities.js");
const selfSource = read("app/frontend/scripts/Views/SelfView.js");
const dashboardSource = read("app/frontend/scripts/Views/DashboardView.js");
const approvalsSource = read("app/frontend/scripts/Views/ApprovalsView.js");
const employeesSource = read("app/frontend/scripts/Views/EmployeesView.js");
const projectsSource = read("app/frontend/scripts/Views/ProjectsView.js");
const i18nSource = read("app/frontend/scripts/I18n.js");
const appShellSource = read("app/frontend/scripts/AppShell.js");
const indexSource = read("app/frontend/index.html");
const cssSource = read("app/frontend/assets/apple-ui.css");

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
    return {
      "action.viewEntryNotes": "View entry notes",
      "shared.employeeWorkComment": "Employee comment",
      "shared.managerMessage": "Supervisor note",
      "shared.entryNotes": "Entry notes",
      "shared.noEntryNotes": "No employee comment or supervisor note.",
    }[key] || key;
  },
};
vm.createContext(context);
vm.runInContext(`${utilitiesSource.slice(helperStart, helperEnd)}
this.workCommentApi = {
  getEntryWorkComment,
  getEntryNotes,
  renderEntryWorkComment,
  renderEntryNotesPreview,
  buildEntryNotesPopoverContent,
};`, context);

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

const combinedNotes = context.workCommentApi.getEntryNotes({
  workComment: "Prepared the monthly reconciliation",
  message: "Approved after verification",
});
assert.equal(combinedNotes.count, 2, "Employee and supervisor notes must be combined into one reader trigger.");
assert.equal(combinedNotes.preview, "Prepared the monthly reconciliation");
assert.equal(context.workCommentApi.getEntryNotes({ message: "Supervisor only" }).preview, "Supervisor only");

const previewMarkup = context.workCommentApi.renderEntryNotesPreview({
  workComment: '<script>alert("x")</script>\nSecond line',
  message: 'Manager said "approved"',
});
assert.match(previewMarkup, /<button[\s\S]*?type="button"[\s\S]*?class="entry-notes-preview"/, "Compact notes must be a real button.");
assert.match(previewMarkup, /data-entry-notes-trigger/, "The delegated popover trigger is missing.");
assert.match(previewMarkup, /aria-expanded="false"/, "The notes trigger is missing its expanded-state contract.");
assert.match(previewMarkup, /View entry notes/, "The notes trigger needs an accessible action label.");
assert.match(previewMarkup, /entry-notes-count[\s\S]*?>2</, "Two available notes must be signalled compactly.");
assert.match(previewMarkup, /&lt;script&gt;/, "The visible preview must escape note HTML.");
assert.doesNotMatch(previewMarkup, /<script>/, "Raw note HTML reached the preview markup.");
assert.match(previewMarkup, /%3Cscript%3E/, "Full note text must be safely encoded in data attributes.");
assert.equal(context.workCommentApi.renderEntryNotesPreview({}), "", "Empty entries must not create a clickable blank preview.");
assert.match(
  context.workCommentApi.renderEntryNotesPreview({}, { showEmpty: true }),
  /entry-notes-empty[\s\S]*?>-</,
  "Dense tables need a non-clickable empty-state marker.",
);

const popoverMarkup = context.workCommentApi.buildEntryNotesPopoverContent({
  getAttribute(name) {
    if (name === "data-entry-employee-comment") {
      return encodeURIComponent('<script>alert("employee")</script>\nSecond line');
    }
    if (name === "data-entry-supervisor-note") {
      return encodeURIComponent("Supervisor note with accents: vérifié");
    }
    return "";
  },
});
assert.match(popoverMarkup, /Employee comment/, "The reader must label the employee comment.");
assert.match(popoverMarkup, /Supervisor note/, "The reader must label the supervisor note.");
assert.match(popoverMarkup, /&lt;script&gt;/, "Popover content must escape stored note HTML.");
assert.doesNotMatch(popoverMarkup, /<script>/, "Raw note HTML reached the popover.");
assert.match(popoverMarkup, /vérifié/, "Unicode note content must survive attribute encoding.");

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
assert.match(selfSource, /renderEntryNotesPreview\(entry\)/, "Employees must get the unified notes preview in their calendar.");
assert.doesNotMatch(selfSource, /expandedNotes|calendar-note-toggle|calendar-entry-note/, "The self calendar still carries the old inline expansion system.");

assert.match(dashboardSource, /renderDashboardApprovalQueue[\s\S]*?renderEntryWorkComment\(entry\)/, "Dashboard approvals must show employee comments.");
assert.match(dashboardSource, /dashboard-entry-col-note[\s\S]*?renderEntryNotesPreview\(entry, \{ showEmpty: true \}\)/, "The dashboard inspector must use the unified compact notes reader.");
assert.match(dashboardSource, /class="dashboard-note-edit-button"[\s\S]*?action\.editSupervisorNote/, "Supervisor-note editing needs a separate explicit pencil action.");
assert.match(dashboardSource, /closest\("\.dashboard-note-edit-button"\)/, "The inspector pencil must remain wired to the existing editor.");
assert.doesNotMatch(dashboardSource, /getDashboardNotePreview|dashboard-note-trigger/, "The old inline dashboard note preview remains in use.");
assert.match(dashboardSource, /data-workcomment=/, "Entry edit buttons must carry the saved overtime comment.");
assert.match(dashboardSource, /workComment === originalWorkComment/, "Comment edits must participate in change detection.");
assert.match(dashboardSource, /reasonCode, workComment, status:/, "Normal entry updates must persist workComment.");
assert.match(approvalsSource, /buildApprovalCard[\s\S]*?renderEntryWorkComment\(entry\)/, "Review cards must show employee comments.");
assert.match(employeesSource, /renderPeopleProjectEntryRows[\s\S]*?renderEntryNotesPreview\(entry\)/, "Employee project rows must use the compact notes reader.");
assert.match(employeesSource, /entryPreview = dayEntries\.map[\s\S]*?renderEntryNotesPreview\(entry\)/, "The administrative employee calendar must use the compact notes reader.");
assert.doesNotMatch(employeesSource, /expandedNotes|calendar-note-toggle|calendar-entry-note/, "The administrative calendar still carries the old inline expansion system.");
assert.match(employeesSource, /data-workcomment=/, "Employee calendar edit buttons must retain the comment contract.");
assert.match(projectsSource, /renderProjectWorkspaceRecentEntries[\s\S]*?renderEntryNotesPreview\(entry\)/, "Project workspaces must use the compact notes reader.");

assert.match(appShellSource, /initializeEntryNotesPopover\(\)/, "The delegated notes reader must initialize with the app shell.");
for (const contract of [
  /document\.createElement\("aside"\)/,
  /document\.body\.appendChild\(popover\)/,
  /positionEntryNotesPopover\(\)/,
  /event\.key === "Escape"/,
  /activeEntryNotesPopover\.contains\(target\)/,
  /!activeEntryNotesTrigger\.isConnected/,
  /popover\.remove\(\)/,
]) {
  assert.match(utilitiesSource, contract, `Missing notes-popover lifecycle contract: ${contract}`);
}
assert.match(cssSource, /\.entry-notes-preview\s*\{[\s\S]*?max-width:\s*210px;/, "The notes preview is too wide to stay compact in dense entry layouts.");
assert.match(cssSource, /\.entry-notes-preview-text\s*\{[\s\S]*?overflow:\s*hidden;[\s\S]*?text-overflow:\s*ellipsis;[\s\S]*?white-space:\s*nowrap;/, "The compact preview does not ellipsize safely.");
assert.match(cssSource, /\.entry-notes-reader-text\s*\{[\s\S]*?overflow-wrap:\s*anywhere;[\s\S]*?white-space:\s*pre-wrap;/, "The full reader cannot safely display long multiline notes.");
assert.match(cssSource, /@media \(max-width: 760px\)[\s\S]*?\.entry-notes-popover\s*\{[\s\S]*?position:\s*fixed !important;[\s\S]*?inset:\s*auto 12px 12px !important;/, "Small screens need the non-modal bottom-sheet layout.");

for (const text of [
  "Employee comment",
  "Commentaire de l’employé",
  "What did you work on?",
  "Sur quoi avez-vous travaillé?",
  "View entry notes",
  "Lire les notes de l’entrée",
  "Edit supervisor note",
  "Modifier la note du superviseur",
]) {
  assert(i18nSource.includes(text), `Missing bilingual work-comment copy: ${text}`);
}

const workCommentViewCacheVersions = {
  EmployeesView: "20260817-chartjs-employee-cards-v2",
  DashboardView: "20260817-chartjs-employee-cards-v2",
  ApprovalsView: "20260817-chartjs-employee-cards-v2",
  ProjectsView: "20260817-chartjs-employee-cards-v2",
};
for (const [view, version] of Object.entries(workCommentViewCacheVersions)) {
  assert(
    appShellSource.includes(`scripts/Views/${view}.js?v=${version}`),
    `${view} is missing its work-comment cache buster.`,
  );
}
const workCommentAssetCacheVersions = {
  "apple-ui.css": "20260817-chartjs-employee-cards-v2",
  "I18n.js": "20260817-chartjs-employee-cards-v2",
  "Utilities.js": "20260817-chartjs-employee-cards-v2",
  "AppShell.js": "20260817-chartjs-employee-cards-v2",
  "SelfView.js": "20260817-chartjs-employee-cards-v2",
};
for (const [asset, version] of Object.entries(workCommentAssetCacheVersions)) {
  assert(indexSource.includes(`${asset}?v=${version}`), `${asset} is missing its work-comment cache buster.`);
}

console.log("Work-comment frontend contract tests passed.");
