#!/usr/bin/env node

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const repoRoot = path.resolve(__dirname, "..", "..");
const read = relativePath => fs.readFileSync(path.join(repoRoot, relativePath), "utf8");
const utilitiesSource = read("app/frontend/scripts/Utilities.js");
const historySource = read("app/frontend/scripts/Views/HistoryView.js");
const dashboardSource = read("app/frontend/scripts/Views/DashboardView.js");
const employeesSource = read("app/frontend/scripts/Views/EmployeesView.js");
const projectsSource = read("app/frontend/scripts/Views/ProjectsView.js");

function sourceBetween(source, startMarker, endMarker) {
  const start = source.indexOf(startMarker);
  const end = source.indexOf(endMarker, start + startMarker.length);
  assert.notEqual(start, -1, `Unable to find ${startMarker}`);
  assert.notEqual(end, -1, `Unable to find ${endMarker}`);
  return source.slice(start, end).trim();
}

function plain(value) {
  return JSON.parse(JSON.stringify(value));
}

let forbiddenGlobalReads = 0;
const isolatedContext = {
  Object,
  String,
  window: {
    Saphir: {
      preservedNamespaceValue: "preserved",
    },
  },
};
for (const name of ["document", "fetch", "localStorage", "Date", "Intl", "navigator"]) {
  Object.defineProperty(isolatedContext, name, {
    get() {
      forbiddenGlobalReads += 1;
      throw new Error(`Text search must not read ${name}.`);
    },
  });
  Object.defineProperty(isolatedContext.window, name, {
    get() {
      forbiddenGlobalReads += 1;
      throw new Error(`Text search must not read window.${name}.`);
    },
  });
}

const textSearchUtilitySource = sourceBetween(
  utilitiesSource,
  "(function initializeTextSearchUtilities",
  "function filterEntries",
);
vm.createContext(isolatedContext);
vm.runInContext(textSearchUtilitySource, isolatedContext);

const textSearch = isolatedContext.window.Saphir.textSearch;
assert.equal(isolatedContext.window.Saphir.preservedNamespaceValue, "preserved", "The shared Saphir namespace must be preserved.");
assert.equal(Object.isFrozen(textSearch), true, "The text-search API must expose a stable surface.");
assert.deepEqual(Object.keys(textSearch), ["tokenize", "matchesAll"]);
assert.equal(forbiddenGlobalReads, 0, "Initializing text search touched a browser side effect.");

const tokenizeCases = [
  [null, []],
  [undefined, []],
  ["", []],
  ["   \t\n ", []],
  ["alpha", ["alpha"]],
  ["  alpha\tbeta\n gamma  ", ["alpha", "beta", "gamma"]],
  ["ÉTÉ été", ["ÉTÉ", "été"]],
  [0, ["0"]],
  [false, ["false"]],
];
tokenizeCases.forEach(([value, expected]) => {
  assert.deepEqual(plain(textSearch.tokenize(value)), expected, `Tokenization changed for ${String(value)}.`);
  assert.deepEqual(plain(textSearch.tokenize(value)), expected, "Tokenization is not deterministic.");
});

const tokens = Object.freeze(["alpha", "beta"]);
const beforeTokens = JSON.stringify(tokens);
assert.equal(textSearch.matchesAll("alpha beta gamma", tokens), true);
assert.equal(textSearch.matchesAll("beta ... alpha", tokens), true, "Token order must remain irrelevant.");
assert.equal(textSearch.matchesAll("alpha gamma", tokens), false);
assert.equal(textSearch.matchesAll("alpha", ["alpha", "alpha"]), true, "Repeated tokens must retain every/includes semantics.");
assert.equal(textSearch.matchesAll("a.b [c]", ["a.b", "[c]"]), true, "Search tokens must remain literal substrings, not regular expressions.");
assert.equal(textSearch.matchesAll("anything", []), true);
assert.equal(textSearch.matchesAll("anything", null), true);
assert.equal(textSearch.matchesAll(null, ["x"]), false);
assert.equal(textSearch.matchesAll(0, ["0"]), true);
assert.equal(textSearch.matchesAll("Résumé", ["resume"]), false, "The shared API must not silently remove accents.");
assert.equal(textSearch.matchesAll("Résumé", ["résumé"]), false, "The shared API must not silently change case.");
assert.equal(textSearch.matchesAll("Résumé", ["Résumé"]), true);
assert.equal(JSON.stringify(tokens), beforeTokens, "Text matching mutated its tokens.");
assert.equal(forbiddenGlobalReads, 0, "Text search touched DOM, network, storage, locale, or clock state.");

const filterEntriesSource = sourceBetween(utilitiesSource, "function filterEntries", "function getEntryWorkComment");
const historyFilterSource = sourceBetween(historySource, "function filterHistoryEntries", "function getActionBadgeHtml");
const dashboardLabelSource = sourceBetween(dashboardSource, "function getDashboardEmployeeSearchLabel", "function buildDashboardEmployeeSearchOptions");
const dashboardTextSource = sourceBetween(dashboardSource, "function getDashboardEmployeeSearchText", "function resolveDashboardEmployeeSearchValue");
const dashboardResolverSource = sourceBetween(dashboardSource, "function resolveDashboardEmployeeSearchValue", "function syncDashboardEmployeeSearchInput");
const dashboardRecentSource = sourceBetween(dashboardSource, "function renderDashboardRecentActivity", "function renderDashboardOverview");
const employeeTokenSource = sourceBetween(employeesSource, "function tokenizeEmployeeSearch", "function getEmployeeSearchResult");
const employeeResultSource = sourceBetween(employeesSource, "function getEmployeeSearchResult", "function employeeMatchesProjectFilter");
const projectNormalizeSource = sourceBetween(projectsSource, "function normalizeProjectPortfolioSearchText", "function normalizeProjectPortfolioScope");
const projectSearchSource = sourceBetween(projectsSource, "function projectMatchesPortfolioSearch", "function projectMatchesPortfolioScope");
const projectEditorSearchSource = sourceBetween(projectsSource, "function employeeMatchesProjectEditorSearch", "function renderProjectEditorAssignmentList");
const employeeEditorSearchSource = sourceBetween(employeesSource, "function employeeEditorProjectMatchesSearch", "function areEmployeeEditorSetsEqual");

for (const [label, source] of [
  ["entry filter", filterEntriesSource],
  ["history filter", historyFilterSource],
  ["dashboard employee resolver", dashboardResolverSource],
  ["dashboard recent activity", dashboardRecentSource],
  ["employee token helpers", employeeTokenSource],
  ["project portfolio search", projectSearchSource],
]) {
  assert.match(source, /window\.Saphir\.textSearch\./, `${label} does not delegate to the shared token search.`);
  assert.doesNotMatch(source, /\.every\s*\(\s*token\s*=>[^)]*\.includes\s*\(\s*token\s*\)/, `${label} still duplicates every/includes matching.`);
}
assert.match(projectEditorSearchSource, /\.includes\(normalizedSearch\)/, "The contiguous project-editor search changed semantics.");
assert.doesNotMatch(projectEditorSearchSource, /window\.Saphir\.textSearch/, "The contiguous project-editor search must remain outside token search.");
assert.match(employeeEditorSearchSource, /\.includes\(normalizedSearch\)/, "The contiguous employee-editor search changed semantics.");
assert.doesNotMatch(employeeEditorSearchSource, /window\.Saphir\.textSearch/, "The contiguous employee-editor search must remain outside token search.");

function legacyFilterEntries(entries, searchTerm, formatDateToWords, getEntryStatusLabel) {
  const queryTokens = String(searchTerm || "").toLowerCase().split(/\s+/).filter(token => token.length > 0);
  if (queryTokens.length === 0) {
    return entries;
  }
  return entries.filter(entry => {
    const combinedText = [
      entry.employeeName, entry.employeeCode, entry.date, formatDateToWords(entry.date),
      entry.projectCode, entry.overtimeCode, entry.paymentOption, entry.reasonCode,
      entry.entryType, entry.diverseReason, entry.diverseSummary, entry.workComment,
      getEntryStatusLabel(entry), entry.message,
    ].join(" ").toLowerCase();
    return queryTokens.every(token => combinedText.includes(token));
  });
}

const entryFilterContext = {
  String,
  window: { Saphir: { textSearch } },
  formatDateToWords(date) {
    return date === "2026-08-17" ? "17 août 2026" : date;
  },
  getEntryStatusLabel(entry) {
    return entry.statusLabel;
  },
};
vm.createContext(entryFilterContext);
vm.runInContext(filterEntriesSource, entryFilterContext);
const filterEntriesData = [
  { id: "a", employeeName: "Alice Résumé", employeeCode: "E1", date: "2026-08-17", projectCode: "P1", statusLabel: "Approuvé" },
  { id: "b", employeeName: "Bob", employeeCode: "E2", date: "2026-08-18", projectCode: "P2", statusLabel: "En attente", message: "Alpha" },
];
for (const searchTerm of [null, "", "   ", "ALICE P1", "août approuvé", "resume", "résumé", "bob alpha", "missing"]) {
  const expected = legacyFilterEntries(filterEntriesData, searchTerm, entryFilterContext.formatDateToWords, entryFilterContext.getEntryStatusLabel);
  const actual = entryFilterContext.filterEntries(filterEntriesData, searchTerm);
  assert.deepEqual(actual.map(entry => entry.id), expected.map(entry => entry.id), `Entry filtering changed for ${String(searchTerm)}.`);
  if (String(searchTerm || "").trim() === "") {
    assert.equal(actual, filterEntriesData, "An empty entry search must preserve the source-array reference.");
  }
}

let historySearchCalls = 0;
const historyFilterContext = {
  String,
  window: { Saphir: { textSearch } },
  isDateWithinRange(date, start, end) {
    return (!start || date >= start) && (!end || date <= end);
  },
  getHistorySearchText(entry) {
    historySearchCalls += 1;
    return entry.searchText;
  },
};
vm.createContext(historyFilterContext);
vm.runInContext(historyFilterSource, historyFilterContext);
const historyEntries = [
  { id: "old", timestamp: "2026-07-31 10:00:00", searchText: "alice p1" },
  { id: "a", timestamp: "2026-08-17 10:00:00", searchText: "alice résumé p1" },
  { id: "b", timestamp: "2026-08-18 11:00:00", searchText: "bob p2" },
];
historySearchCalls = 0;
assert.deepEqual(
  historyFilterContext.filterHistoryEntries(historyEntries, "ALICE P1", "2026-08-01", "2026-08-31").map(entry => entry.id),
  ["a"],
);
assert.equal(historySearchCalls, 2, "History must reject out-of-range entries before building searchable text.");
assert.deepEqual(historyFilterContext.filterHistoryEntries(historyEntries, "resume", "2026-08-01", "2026-08-31").map(entry => entry.id), [], "History search must remain accent-sensitive.");
const emptyHistoryResult = historyFilterContext.filterHistoryEntries(historyEntries, "", "", "");
assert.notEqual(emptyHistoryResult, historyEntries, "History must retain its historical filtered-array identity for an empty query.");

function legacyResolveDashboardEmployeeSearchValue(value, employees, getLabel, getText) {
  const normalizedValue = String(value || "").trim().toLowerCase();
  if (!normalizedValue) return null;
  const exactMatch = employees.find(employee => {
    const code = String(employee.code || "").trim().toLowerCase();
    const name = String(employee.name || "").trim().toLowerCase();
    const label = getLabel(employee).toLowerCase();
    return normalizedValue === code || normalizedValue === name || normalizedValue === label;
  });
  if (exactMatch) return exactMatch;
  const queryTokens = normalizedValue.split(/\s+/).filter(Boolean);
  if (queryTokens.length === 0) return null;
  const matches = employees.filter(employee => queryTokens.every(token => getText(employee).includes(token)));
  return matches.length === 1 ? matches[0] : null;
}

const dashboardEmployees = [
  { code: "E1", name: "Élodie Durand", role: "admin" },
  { code: "E2", name: "Elodie Martin", role: "admin" },
  { code: "E3", name: "Alice Durand", role: "employee" },
];
const dashboardResolverContext = {
  Array,
  String,
  dashboardState: { employees: dashboardEmployees },
  window: { Saphir: { textSearch } },
};
vm.createContext(dashboardResolverContext);
vm.runInContext([dashboardLabelSource, dashboardTextSource, dashboardResolverSource].join("\n\n"), dashboardResolverContext);
for (const query of ["", "E1", "Élodie Durand", "Élodie Durand | E1", "durand admin", "admin", "elodie", "elodie durand", "missing"]) {
  const expected = legacyResolveDashboardEmployeeSearchValue(query, dashboardEmployees, dashboardResolverContext.getDashboardEmployeeSearchLabel, dashboardResolverContext.getDashboardEmployeeSearchText);
  assert.equal(dashboardResolverContext.resolveDashboardEmployeeSearchValue(query), expected, `Dashboard employee resolution changed for ${query}.`);
}

const dashboardRecentElements = {
  dashboardRecentActivity: { innerHTML: "" },
  dashboardRecentSearchInput: { value: "" },
};
const dashboardRecentContext = {
  Array,
  String,
  dashboardState: { history: [] },
  window: { Saphir: { textSearch } },
  document: { getElementById(id) { return dashboardRecentElements[id]; } },
  getHistorySearchText(entry) { return entry.searchText; },
  getHistoryAuthorName(entry) { return entry.author; },
  formatRelativeTime() { return "recent"; },
  formatDateToWords(value) { return value; },
  translateHistoryAction(value) { return value; },
  renderHistorySubjectLine() { return ""; },
  renderAuditMessage(value) { return value; },
  createEmptyState(value) { return `EMPTY:${value}`; },
  escapeHtml(value) { return String(value == null ? "" : value); },
  t(key) { return key; },
};
vm.createContext(dashboardRecentContext);
vm.runInContext(dashboardRecentSource, dashboardRecentContext);
const recentEntries = [
  { author: "Alice", timestamp: "2026-08-17 10:00:00", action: "add", message: "A", searchText: "alice p1 résumé" },
  { author: "Bob", timestamp: "2026-08-18 10:00:00", action: "update", message: "B", searchText: "bob p2" },
];
dashboardRecentElements.dashboardRecentSearchInput.value = " ALICE P1 ";
dashboardRecentContext.renderDashboardRecentActivity(recentEntries);
assert.match(dashboardRecentElements.dashboardRecentActivity.innerHTML, /Alice/);
assert.doesNotMatch(dashboardRecentElements.dashboardRecentActivity.innerHTML, /Bob/);
dashboardRecentElements.dashboardRecentSearchInput.value = "resume";
dashboardRecentContext.renderDashboardRecentActivity(recentEntries);
assert.match(dashboardRecentElements.dashboardRecentActivity.innerHTML, /^EMPTY:/, "Dashboard recent search must remain accent-sensitive.");
dashboardRecentElements.dashboardRecentSearchInput.value = "   ";
dashboardRecentContext.renderDashboardRecentActivity(recentEntries);
assert.match(dashboardRecentElements.dashboardRecentActivity.innerHTML, /Alice/);
assert.match(dashboardRecentElements.dashboardRecentActivity.innerHTML, /Bob/);

const employeeSearchContext = {
  String,
  window: { Saphir: { textSearch } },
  getEmployeeRoleLabel(employee) { return employee.roleLabel; },
  getEmployeeResponsibilitySearchText(employee) { return employee.responsibilityText; },
  getEmployeeEntryProjectSearchText(employee) { return employee.entryProjectText; },
};
vm.createContext(employeeSearchContext);
vm.runInContext([employeeTokenSource, employeeResultSource].join("\n\n"), employeeSearchContext);
const rankedEmployee = {
  name: "Élodie Durand",
  code: "E1",
  roleLabel: "Admin",
  responsibilityText: "p1 alpha nord",
  entryProjectText: "p2 beta sud",
};
const rankCases = [
  ["", { matches: true, rank: 0 }],
  ["alpha nord", { matches: true, rank: 0 }],
  ["beta sud", { matches: true, rank: 1 }],
  ["élodie admin", { matches: true, rank: 2 }],
  ["durand alpha", { matches: true, rank: 3 }],
  ["elodie", { matches: false, rank: 99 }],
  ["missing", { matches: false, rank: 99 }],
];
rankCases.forEach(([query, expected]) => {
  assert.deepEqual(plain(employeeSearchContext.getEmployeeSearchResult(rankedEmployee, query)), expected, `Employee rank changed for ${query}.`);
});

const projectSearchContext = {
  String,
  projectsViewState: { portfolioSearch: "" },
  window: { Saphir: { textSearch } },
  getCurrentLocale() { return "fr-CA"; },
  formatProjectAdminDisplay(displayItems, fallbackCodes) {
    return Array.isArray(displayItems) ? displayItems : (Array.isArray(fallbackCodes) ? fallbackCodes : []);
  },
};
vm.createContext(projectSearchContext);
vm.runInContext([projectNormalizeSource, projectSearchSource].join("\n\n"), projectSearchContext);
const project = {
  projectCode: "P-01",
  projectName: "Résumé annuel",
  sector: "Nord",
  adminDisplay: ["René Tremblay"],
  backupAdminDisplay: ["Élodie Roy"],
};
for (const [query, expected] of [["", true], ["resume nord", true], ["rene", true], ["elodie p-01", true], ["résumé", true], ["resume absent", false]]) {
  projectSearchContext.projectsViewState.portfolioSearch = query;
  assert.equal(projectSearchContext.projectMatchesPortfolioSearch(project), expected, `Project accent-insensitive search changed for ${query}.`);
}

console.log("Frontend text-search boundary contracts passed.");
