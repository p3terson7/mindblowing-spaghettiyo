#!/usr/bin/env node

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const repoRoot = path.resolve(__dirname, "..", "..");
const read = relativePath => fs.readFileSync(path.join(repoRoot, relativePath), "utf8");
const utilitiesSource = read("app/frontend/scripts/Utilities.js");
const appShellSource = read("app/frontend/scripts/AppShell.js");
const dashboardSource = read("app/frontend/scripts/Views/DashboardView.js");
const approvalsSource = read("app/frontend/scripts/Views/ApprovalsView.js");
const employeesSource = read("app/frontend/scripts/Views/EmployeesView.js");
const projectsSource = read("app/frontend/scripts/Views/ProjectsView.js");
const selfSource = read("app/frontend/scripts/Views/SelfView.js");
const historySource = read("app/frontend/scripts/Views/HistoryView.js");
const i18nSource = read("app/frontend/scripts/I18n.js");
const indexSource = read("app/frontend/index.html");

const localDateStart = utilitiesSource.indexOf("function toLocalDateInputValue");
const localDateEnd = utilitiesSource.indexOf("function isDateWithinRange", localDateStart);
assert(localDateStart >= 0 && localDateEnd > localDateStart, "Local date input helper is missing.");
const dateContext = { Date, Number, Object, String, TypeError, window: { Saphir: {} } };
vm.createContext(dateContext);
vm.runInContext(`${utilitiesSource.slice(localDateStart, localDateEnd)}\nthis.toLocalDateInputValue = toLocalDateInputValue;`, dateContext);
assert.equal(
  dateContext.toLocalDateInputValue(new Date(2026, 7, 13, 23, 55)),
  "2026-08-13",
  "Date inputs must use local calendar fields rather than UTC serialization.",
);
assert(dashboardSource.includes("toLocalDateInputValue(new Date())"), "Manual entry still defaults through UTC.");

const dashboardHelpersStart = dashboardSource.indexOf("function getDashboardEmployeeSearchLabel");
const dashboardHelpersEnd = dashboardSource.indexOf("function buildProjectFilterOptions", dashboardHelpersStart);
assert(dashboardHelpersStart >= 0 && dashboardHelpersEnd > dashboardHelpersStart, "Dashboard employee helpers are missing.");
const elements = {
  dashboardEmployeeSearchInput: {
    value: "Unmatched employee",
    attributes: new Map(),
    setAttribute(name, value) { this.attributes.set(name, value); },
    removeAttribute(name) { this.attributes.delete(name); },
  },
  employeeSelect: { value: "000100000" },
};
let employeeRefreshCount = 0;
const storedValues = new Map([["selectedEmployee", "000100000"]]);
const dashboardContext = {
  String,
  Boolean,
  Array,
  dashboardState: {
    employees: [{ code: "000100000", name: "Mélanie Langevin", role: "employee" }],
  },
  document: { getElementById: id => elements[id] || null },
  localStorage: {
    setItem: (key, value) => storedValues.set(key, value),
    removeItem: key => storedValues.delete(key),
  },
  fetchEmployeeData: () => { employeeRefreshCount += 1; },
  window: {
    clearTimeout() {},
    setTimeout() {},
    Saphir: {
      textSearch: {
        tokenize: text => String(text == null ? "" : text).split(/\s+/).filter(Boolean),
        matchesAll: (text, tokens) => (tokens || []).every(token => String(text == null ? "" : text).includes(token)),
      },
    },
  },
};
vm.createContext(dashboardContext);
vm.runInContext(`${dashboardSource.slice(dashboardHelpersStart, dashboardHelpersEnd)}
this.resolveDashboardEmployeeSearchInput = resolveDashboardEmployeeSearchInput;`, dashboardContext);
assert.equal(dashboardContext.resolveDashboardEmployeeSearchInput(), false);
assert.equal(elements.employeeSelect.value, "", "An unmatched search must clear the previous hidden employee target.");
assert.equal(elements.dashboardEmployeeSearchInput.value, "Unmatched employee", "Clearing the target must not erase what the user typed.");
assert.equal(storedValues.has("selectedEmployee"), false, "The stale employee target must also be removed from storage.");
assert.equal(employeeRefreshCount, 1, "The inspector must immediately reflect that no employee is selected.");
assert.equal(elements.dashboardEmployeeSearchInput.attributes.get("aria-invalid"), "true");

assert.match(
  appShellSource,
  /\.then\(result => \{\s*if \(result === false\) \{\s*state\.stale = true;\s*return false;/,
  "A caught view-load failure must stay stale instead of being marked loaded.",
);
for (const [label, source, functionName] of [
  ["dashboard", dashboardSource, "refreshDashboardView"],
  ["review", approvalsSource, "loadReviewView"],
  ["employees", employeesSource, "loadEmployeesView"],
  ["projects", projectsSource, "refreshProjectsView"],
  ["self", selfSource, "refreshSelfView"],
  ["history", historySource, "fetchHistory"],
]) {
  const start = source.indexOf(`function ${functionName}`);
  assert(start >= 0, `Unable to locate ${label} loader ${functionName}.`);
  const remainingSource = source.slice(start + 1);
  const nextFunctionOffset = remainingSource.search(/\n(?:async\s+)?function\s+/);
  const end = nextFunctionOffset >= 0 ? start + 1 + nextFunctionOffset : source.length;
  const excerpt = source.slice(start, end);
  assert(excerpt.includes("return false;"), `${label} loader does not report caught failures.`);
}

assert.match(approvalsSource, /function isPendingApprovalTabActive\(\)/, "Pending-tab guard is missing.");
assert.match(approvalsSource, /button\.classList\.toggle\("d-none", !isPendingTab\)/, "Bulk approval remains visible on historical tabs.");
assert.match(approvalsSource, /button\.disabled = !isPendingTab \|\| actionableCount === 0;/, "Bulk approval must be disabled when nothing visible is actionable.");
assert.match(approvalsSource, /async function approveFilteredEntries[\s\S]*?if \(!isPendingApprovalTabActive\(\)\) \{\s*return;/, "The bulk handler itself is not protected by the active tab.");
assert.match(approvalsSource, /"approvalTabs"\)\.addEventListener\("shown\.bs\.tab"/, "Bulk approval state is not refreshed after tab changes.");

assert(employeesSource.includes("employee-open-button"), "Employee cards need an explicit keyboard-accessible open action.");
assert(employeesSource.includes('aria-controls="employeeDetailContainer"'), "Employee open actions must identify their target region.");
const employeeCardStart = employeesSource.indexOf("function renderEmployeeDirectoryCard");
const employeeCardEnd = employeesSource.indexOf("function renderEmployeeDirectorySection", employeeCardStart);
assert(employeeCardStart >= 0 && employeeCardEnd > employeeCardStart, "Unable to locate employee directory-card rendering.");
const employeeCardSource = employeesSource.slice(employeeCardStart, employeeCardEnd);
assert(employeeCardSource.includes("employee-card-title-button employee-open-button"), "The employee name must remain the explicit keyboard-accessible file action.");
assert(!employeeCardSource.includes("employee-card-actions"), "Employee directory cards must not retain a redundant action row.");
assert(!employeeCardSource.includes('t("action.openEmployee")'), "Employee directory cards must not repeat a Fiche employé button.");
assert(!employeeCardSource.includes("employee-edit-button"), "Employee directory cards must not include a Modifier button.");
const employeeDetailStart = employeesSource.indexOf("function renderEmployeeDetail");
const employeeDetailEnd = employeesSource.indexOf("async function loadEmployeeDetail", employeeDetailStart);
const employeeDetailSource = employeesSource.slice(employeeDetailStart, employeeDetailEnd);
assert(employeeDetailSource.includes("employee-edit-button"), "Employee editing must remain available in the employee detail header.");
assert.match(employeesSource, /function focusEmployeeDetailCard\(\)[\s\S]*?detailTitle\.focus\(\{ preventScroll: true \}\)[\s\S]*?detailCard\.scrollIntoView\(\{ behavior: "smooth", block: "start" \}\)/, "Opening an employee card must focus its loaded detail heading using the visible card as its scroll target.");
assert.match(employeesSource, /function openEmployeeDetailFromDirectory[\s\S]*?loadEmployeeDetail\(normalizedEmployeeCode\)[\s\S]*?return focusEmployeeDetailCard\(\);/, "Opening an employee card must reuse the shared detail-focus workflow.");
assert.match(employeesSource, /const titleButton = employeeCard\.querySelector\("\.employee-card-title-button\.employee-open-button"\)[\s\S]*?openEmployeeDetailFromDirectory\(employeeCode\)/, "Whole-card clicks must use the retained title button and the accessible detail workflow.");
assert(projectsSource.includes("project-open-button"), "Project cards need an explicit keyboard-accessible open action.");
assert(projectsSource.includes('aria-controls="projectWorkspace"'), "Project open actions must identify their workspace destination.");
assert(
  /function setProjectWorkspaceVisibility\([\s\S]*?portfolio\.classList\.toggle\("d-none", isOpen\)[\s\S]*?title\.focus\(\{ preventScroll: true \}\)/.test(projectsSource),
  "Project detail actions must replace the portfolio and focus the named workspace heading."
);
assert(
  /runButtonAction\(openButton, \(\) => openProjectDetailFromPortfolio\(projectCode, currentProjectFilter, \{ opener: openButton \}\)/.test(projectsSource),
  "The explicit project detail action must use the project-detail navigation workflow."
);
assert(indexSource.includes('id="projectPortfolioWorkspace"'), "The project portfolio needs its own visibility root.");
assert(indexSource.includes('id="projectWorkspace" class="project-workspace d-none"'), "The project workspace must start hidden.");
assert(indexSource.includes('id="projectWorkspaceTitle"'), "The project workspace must have a stable accessible heading.");
assert(
  indexSource.includes('id="projectDetailContainer" class="project-workspace-body" role="region" aria-labelledby="projectWorkspaceTitle" aria-live="polite" aria-busy="false"'),
  "The project workspace body must expose named loading updates to assistive technology."
);
assert(
  /function openProjectDetailFromPortfolio\([\s\S]*?setProjectWorkspaceVisibility\(true,[\s\S]*?return loadProjectDetailStats\(normalizedCode, filterPeriod\)/.test(projectsSource),
  "Opening a project must reveal its dedicated workspace before loading the detail payload."
);
assert(projectsSource.includes("portfolioScrollY"), "Returning from a project must preserve the portfolio scroll position.");
assert(projectsSource.includes("window.history.back()"), "The in-app Back action must cooperate with browser history.");
assert(selfSource.includes('aria-label="${escapeHtml(t("action.previousYear"))}"'), "Previous-year control is not labelled.");
assert(selfSource.includes('aria-label="${escapeHtml(t("action.nextYear"))}"'), "Next-year control is not labelled.");
for (const key of ["action.openProject", "action.previousYear", "action.nextYear"]) {
  assert.equal(i18nSource.split(`"${key}"`).length - 1, 2, `${key} must exist in English and French.`);
}

console.log("UX detour guard tests passed.");
