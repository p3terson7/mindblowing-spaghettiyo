const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const source = fs.readFileSync(path.resolve(__dirname, "../../app/frontend/scripts/Views/ProjectsView.js"), "utf8");
const start = source.indexOf("function loadProjectBudgetComparison()");
const end = source.indexOf("async function renderProjectBudgetBeta", start);
const disclosure = { open: false };
const state = { payload: null, stale: true, refreshVersion: 0, loadingPromise: null, selectedIds: new Set(), initialized: false };
const requests = [];
let renders = 0;
const context = {
  document: { querySelector: () => disclosure, getElementById: () => ({ innerHTML: "" }) },
  projectsViewState: { budgetComparison: state }, apiUrl: "/", console: { error() {} },
  fetch: url => new Promise((resolve, reject) => requests.push({ url, resolve, reject })),
  parseResponse: value => value, normalizeProjectBudgetComparisonPayload: value => value,
  getDefaultProjectBudgetPeriodIds: () => [], setProjectBudgetComparisonLoading() {},
  renderProjectBudgetComparison: () => { renders++; },
  getProjectBudgetComparisonElements: () => ({}), createEmptyState: value => value, t: value => value,
};
vm.createContext(context);
vm.runInContext(source.slice(start, end), context);
const response = { periods: [] };
(async () => {
  await context.loadProjectBudgetComparison();
  assert.equal(requests.length, 0, "Collapsed comparisons must make no expensive twelve-period request.");
  disclosure.open = true;
  const first = context.loadProjectBudgetComparison();
  assert.equal(first, context.loadProjectBudgetComparison(), "Repeated toggles must share the in-flight request.");
  assert.equal(requests.length, 1);
  requests[0].resolve(response);
  await first;
  await context.loadProjectBudgetComparison();
  assert.equal(requests.length, 1, "Reopening an unchanged comparison must use its existing data.");
  assert(renders > 0);
  state.stale = true;
  state.refreshVersion++;
  const staleRequest = context.loadProjectBudgetComparison();
  state.refreshVersion++;
  requests[1].resolve(response);
  await staleRequest;
  assert.equal(requests.length, 3, "An intervening source update must coalesce into exactly one fresh request.");
  const latest = state.loadingPromise;
  requests[2].resolve(response);
  await latest;
  disclosure.open = false;
  state.stale = true;
  await context.loadProjectBudgetComparison();
  assert.equal(requests.length, 3, "Background refresh must not reopen or load the hidden comparison.");
  disclosure.open = true;
  const failure = context.loadProjectBudgetComparison();
  requests[3].reject(new Error("offline"));
  await failure;
  assert.equal(requests.length, 4, "Failures must not cause an automatic retry loop.");
  const refreshStart = source.indexOf("async function refreshProjectsView");
  const refreshEnd = source.indexOf("function renderProjectSummaryCards", refreshStart);
  const refresh = source.slice(refreshStart, refreshEnd);
  assert(refresh.indexOf("fetch(buildProjectBootstrapUrl") < refresh.indexOf("loadProjectBudgetComparison()"), "The main request must precede the optional comparison on the serial server.");
  assert(!refresh.includes("await loadProjectBudgetComparison") && !refresh.includes("await budgetComparisonPromise"), "The workspace must not wait for optional comparison data.");
  console.log("Budget lazy-loading regression passed: collapsed requests, ordering, deduplication, stale responses and bounded retries.");
})().catch(error => { console.error(error); process.exitCode = 1; });
