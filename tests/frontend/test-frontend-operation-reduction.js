#!/usr/bin/env node

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const repoRoot = path.resolve(__dirname, "..", "..");
const read = relativePath => fs.readFileSync(path.join(repoRoot, relativePath), "utf8");
const appShellSource = read("app/frontend/scripts/AppShell.js");
const projectsSource = read("app/frontend/scripts/Views/ProjectsView.js");
const dashboardSource = read("app/frontend/scripts/Views/DashboardView.js");
const selfSource = read("app/frontend/scripts/Views/SelfView.js");
const employeesSource = read("app/frontend/scripts/Views/EmployeesView.js");
const approvalsSource = read("app/frontend/scripts/Views/ApprovalsView.js");

function sourceBetween(source, startMarker, endMarker) {
  const start = source.indexOf(startMarker);
  const end = source.indexOf(endMarker, start + startMarker.length);
  assert.notEqual(start, -1, `Unable to find ${startMarker}`);
  assert.notEqual(end, -1, `Unable to find ${endMarker}`);
  return source.slice(start, end).trim();
}

function projectMutationSource(functionName, nextFunctionName) {
  return sourceBetween(
    projectsSource,
    `async function ${functionName}`,
    `async function ${nextFunctionName}`,
  );
}

for (const mutationSource of [
  projectMutationSource("submitProjectEditor", "archiveProject"),
  projectMutationSource("archiveProject", "deleteProject"),
  sourceBetween(projectsSource, "async function deleteProject", "function renderProjectMultiLineChart"),
]) {
  assert.match(mutationSource, /invalidateProjectLookupCaches\(\)/, "Project mutations must invalidate lookup data");
  assert.doesNotMatch(mutationSource, /fetchOvertimeEntryLookups\(true\)/, "Project mutations must not eagerly refetch entry lookups");
  assert.doesNotMatch(mutationSource, /fetchScopedProjects\(true\)/, "Project mutations must not eagerly refetch scoped projects");
  assert.match(mutationSource, /await refreshProjectsView\(\)/, "The projects bootstrap must remain the authoritative post-mutation refresh");
}

{
  const timerTasks = new Map();
  const clearedTimers = [];
  const detailLoads = [];
  let nextTimerId = 1;
  const context = {
    PROJECT_DETAIL_REQUEST_DELAY_MS: 90,
    window: {
      setTimeout(callback) {
        const timerId = nextTimerId;
        nextTimerId += 1;
        timerTasks.set(timerId, callback);
        return timerId;
      },
      clearTimeout(timerId) {
        clearedTimers.push(timerId);
        timerTasks.delete(timerId);
      },
    },
    loadProjectDetailStats(...args) {
      detailLoads.push(args);
    },
    clearOvertimeEntryLookupCache() {},
    clearScopedProjectLookupCache() {},
  };
  vm.createContext(context);
  vm.runInContext(`
    var pendingProjectDetailTimerId = null;
    var pendingProjectDetailRequest = null;
    var projectDetailRequestVersion = 0;
    ${sourceBetween(projectsSource, "function supersedeProjectDetailRequests", "function getProjectDetailCacheKey")}
    this.detailRequestHarness = {
      scheduleProjectDetailStats,
      supersedeProjectDetailRequests,
      setPendingRequest(value) { pendingProjectDetailRequest = value; },
      getVersion() { return projectDetailRequestVersion; },
    };
  `, context);

  context.detailRequestHarness.scheduleProjectDetailStats("P-1", "6M");
  context.detailRequestHarness.scheduleProjectDetailStats("P-2", "6M");
  assert.deepEqual(clearedTimers, [1], "A rapid project selection must cancel the older scheduled detail request");
  assert.equal(timerTasks.has(1), false);
  assert.equal(timerTasks.has(2), true);
  timerTasks.get(2)();
  assert.equal(detailLoads.length, 1, "Only the latest scheduled project detail should reach the request loader");
  assert.equal(detailLoads[0][0], "P-2");
  assert.equal(detailLoads[0][2].requestVersion, 2);

  let abortCount = 0;
  context.detailRequestHarness.setPendingRequest({
    controller: {
      abort() {
        abortCount += 1;
      },
    },
  });
  context.detailRequestHarness.supersedeProjectDetailRequests();
  assert.equal(abortCount, 1, "An already-started obsolete detail request must be aborted");
}

async function testObsoleteProjectResponseGuard() {
  let resolvePayload;
  const payloadPromise = new Promise(resolve => {
    resolvePayload = resolve;
  });
  const renderedDetails = [];
  const detailBusyStates = [];
  const context = {
    AbortController: undefined,
    Number,
    String,
    console: { error() {} },
    document: {
      getElementById() {
        return {
          innerHTML: "",
          setAttribute(name, value) {
            if (name === "aria-busy") {
              detailBusyStates.push(value);
            }
          },
        };
      },
    },
    getProjectDetailCacheKey(projectCode, filterPeriod) {
      return `${projectCode}:${filterPeriod}`;
    },
    isCurrentProjectDetailRequest(requestVersion, projectCode, filterPeriod) {
      return requestVersion === context.projectDetailState.version
        && projectCode === context.projectDetailState.projectCode
        && filterPeriod === context.projectDetailState.filterPeriod;
    },
    supersedeProjectDetailRequests() {
      context.projectDetailState.version += 1;
      return context.projectDetailState.version;
    },
    buildProjectStatsUrl(projectCode) {
      return `/stats/${projectCode}`;
    },
    setLoadingState() {},
    async fetch() {
      return {};
    },
    async parseResponse() {
      return payloadPromise;
    },
    renderProjectDetail(detail) {
      renderedDetails.push(detail);
    },
    destroyProjectWorkspaceTrendChart() {},
    createEmptyState(value) {
      return value;
    },
    t(value) {
      return value;
    },
    projectDetailState: {
      version: 1,
      projectCode: "P-1",
      filterPeriod: "6M",
    },
  };
  vm.createContext(context);
  vm.runInContext(`
    var projectDetailCache = {};
    var pendingProjectDetailRequest = null;
    ${sourceBetween(projectsSource, "async function loadProjectDetailStats", "async function refreshProjectsView")}
    this.loadProjectDetailStatsForTest = loadProjectDetailStats;
    this.getProjectDetailCacheForTest = () => projectDetailCache;
  `, context);

  const requestPromise = context.loadProjectDetailStatsForTest("P-1", "6M", { requestVersion: 1 });
  await Promise.resolve();
  context.projectDetailState.version = 2;
  context.projectDetailState.projectCode = "P-2";
  resolvePayload({ projectCode: "P-1", entryCount: 4 });
  const result = await requestPromise;

  assert.equal(result, null, "An obsolete detail response should be discarded");
  assert.equal(renderedDetails.length, 0, "An obsolete detail response must not overwrite the current project");
  assert.equal(Object.keys(context.getProjectDetailCacheForTest()).length, 0, "Obsolete data must not be inserted into the short-lived detail cache");
  assert.deepEqual(detailBusyStates, ["true"], "An obsolete request must not clear the current workspace loading state");
}

{
  const cards = ["P-1", "P-2", "P-3"].map(projectCode => {
    const classes = new Set(projectCode === "P-1" ? ["is-active"] : []);
    return {
      classList: {
        toggle(className, enabled) {
          if (enabled) {
            classes.add(className);
          } else {
            classes.delete(className);
          }
        },
        contains(className) {
          return classes.has(className);
        },
      },
      getAttribute(name) {
        return name === "data-project-code" ? projectCode : "";
      },
    };
  });
  const context = {
    currentProjectCode: "P-2",
    projectsViewState: { workspaceOpen: true },
    document: {
      querySelectorAll() {
        return cards;
      },
    },
    String,
  };
  vm.createContext(context);
  vm.runInContext(`
    ${sourceBetween(projectsSource, "function updateActiveProjectSummaryCard", "function renderProjectSummaryCard")}
    updateActiveProjectSummaryCard();
  `, context);
  assert.equal(cards[0].classList.contains("is-active"), false);
  assert.equal(cards[1].classList.contains("is-active"), true);
  assert.equal(cards[2].classList.contains("is-active"), false);
}

assert.match(projectsSource, /const PROJECT_PORTFOLIO_SEARCH_DEBOUNCE_MS = 140;/, "Project portfolio filtering must remain debounced");
assert.match(projectsSource, /addEventListener\("input",[\s\S]*window\.setTimeout\([\s\S]*applyProjectPortfolioSearch/, "Project search input must defer its heavy rerender");
assert.doesNotMatch(
  sourceBetween(
    projectsSource,
    'document.getElementById("projectsSummaryContainer").addEventListener("click"',
    'document.getElementById("projectPortfolioSearchInput").addEventListener("input"',
  ),
  /renderProjectSummaryCards/,
  "Selecting a project must update the active card in place instead of rebuilding the portfolio",
);

{
  let currentUser = { role: "admin", employeeCode: "EMP-1" };
  const context = {
    getCurrentUser: () => currentUser,
    isManagerUser: user => Boolean(user && (user.role === "admin" || user.role === "superAdmin")),
    userHasEmployeeWorkspace: user => Boolean(user && user.employeeCode),
  };
  vm.createContext(context);
  vm.runInContext(`
    ${sourceBetween(appShellSource, "function getViewsAffectedBySyncState", "function normalizeApiUrl")}
    this.getViewsAffectedBySyncStateForTest = getViewsAffectedBySyncState;
  `, context);
  const affected = category => Array.from(context.getViewsAffectedBySyncStateForTest({ category, resource: "EMP-1" }));

  assert.deepEqual(affected("project"), ["dashboardView", "projectsView", "adminView"]);
  assert.deepEqual(affected("employee-directory"), ["dashboardView", "employeesView", "adminView"]);
  assert.deepEqual(affected("auth"), ["employeesView", "adminView"]);
  assert.deepEqual(affected("employee"), ["dashboardView", "employeesView", "adminView", "projectsView", "selfView"]);

  currentUser = { role: "employee", employeeCode: "EMP-1" };
  assert.deepEqual(affected("project"), ["selfView"]);
  assert.deepEqual(affected("auth"), ["selfView"]);
}

{
  const calledHandlers = [];
  const context = {
    getCurrentUser: () => ({ role: "admin" }),
    resolvePreferredView: () => "dashboardView",
    localStorage: { getItem: () => "" },
    document: {
      querySelector() {
        return { id: "projectsView" };
      },
    },
    window: {
      rerenderProjectsViewForLanguageChange() {
        calledHandlers.push("projects");
      },
    },
  };
  vm.createContext(context);
  vm.runInContext(`
    ${sourceBetween(appShellSource, "function rerenderActiveViewForLanguageChange", "async function pollSyncState")}
    rerenderActiveViewForLanguageChange();
  `, context);
  assert.deepEqual(calledHandlers, ["projects"], "Language changes must use the active view's local renderer");
}

const languageListenerSource = sourceBetween(
  appShellSource,
  'window.addEventListener("app:language-changed"',
  "\n});",
);
assert.match(languageListenerSource, /rerenderActiveViewForLanguageChange/, "Language changes must trigger a local rerender");
assert.doesNotMatch(languageListenerSource, /refreshActiveView/, "Language changes must not trigger a backend-backed view refresh");

for (const [source, handlerName] of [
  [selfSource, "rerenderSelfViewForLanguageChange"],
  [dashboardSource, "rerenderDashboardViewForLanguageChange"],
  [employeesSource, "rerenderEmployeesViewForLanguageChange"],
  [approvalsSource, "rerenderReviewViewForLanguageChange"],
  [projectsSource, "rerenderProjectsViewForLanguageChange"],
]) {
  assert.match(source, new RegExp(`window\\.${handlerName}\\s*=`), `Missing local language renderer: ${handlerName}`);
}

assert.match(
  dashboardSource,
  /fetchEmployeeData\(\{ allowFetch: false \}\)/,
  "The dashboard language renderer must explicitly forbid an accidental detail fetch",
);

testObsoleteProjectResponseGuard()
  .then(() => {
    console.log("Frontend operation reduction test passed.");
  })
  .catch(error => {
    console.error(error);
    process.exitCode = 1;
  });
