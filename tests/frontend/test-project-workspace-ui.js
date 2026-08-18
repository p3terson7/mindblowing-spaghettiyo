#!/usr/bin/env node

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const repoRoot = path.resolve(__dirname, "..", "..");
const read = relativePath => fs.readFileSync(path.join(repoRoot, relativePath), "utf8");
const projectsSource = read("app/frontend/scripts/Views/ProjectsView.js");
const appShellSource = read("app/frontend/scripts/AppShell.js");
const viewSwitchingSource = read("app/frontend/scripts/Views/ViewSwitching.js");
const indexSource = read("app/frontend/index.html");
const cssSource = read("app/frontend/assets/apple-ui.css");
const i18nSource = read("app/frontend/scripts/I18n.js");

for (const id of [
  "projectPortfolioWorkspace",
  "projectWorkspace",
  "projectWorkspaceBackButton",
  "projectWorkspaceTitle",
  "projectWorkspaceRangeSelect",
  "projectWorkspaceReviewButton",
  "projectWorkspaceEntriesButton",
  "projectWorkspaceExportButton",
  "projectWorkspaceEditButton",
  "projectDetailContainer",
]) {
  assert(indexSource.includes(`id="${id}"`), `Project workspace control ${id} is missing.`);
}

assert(indexSource.includes('id="projectWorkspace" class="project-workspace d-none"'), "The workspace must not compete with the portfolio on first render.");
assert(indexSource.includes('aria-live="polite" aria-busy="false"'), "Workspace loading changes must be announced without interrupting the user.");
assert.match(projectsSource, /portfolio\.classList\.toggle\("d-none", isOpen\)/, "Opening a project must hide the long portfolio.");
assert.match(projectsSource, /workspace\.classList\.toggle\("d-none", !isOpen\)/, "Opening a project must show the dedicated workspace.");
assert.match(projectsSource, /portfolioScrollY[\s\S]*?window\.scrollTo\(\{ top: projectsViewState\.portfolioScrollY/, "Back must restore the portfolio's scroll position.");
assert.match(projectsSource, /project-open-button[\s\S]*?aria-controls=\"projectWorkspace\"/, "Project cards must expose a keyboard-accessible workspace action.");
assert(projectsSource.includes("window.history.back()"), "The workspace Back action must cooperate with browser history.");
assert(projectsSource.includes('window.addEventListener("popstate", syncProjectWorkspaceFromRoute)'), "Browser Back/Forward must synchronize the project workspace.");
assert.match(appShellSource, /function resolvePreferredView[\s\S]*?\^#projects\\\/[\^/\]\+\$[\s\S]*?return "projectsView";/, "A bookmarked project workspace must lazy-load through the Projects view.");
assert.match(viewSwitchingSource, /function clearProjectWorkspaceRouteWhenLeaving[\s\S]*?viewId === "projectsView"[\s\S]*?window\.history\.replaceState\(null/, "Leaving Projects must remove only the stale project-workspace route.");
assert.match(viewSwitchingSource, /function showView\(viewId\)[\s\S]*?clearProjectWorkspaceRouteWhenLeaving\(resolvedViewId\)/, "Every top-level view change must apply project route cleanup.");
assert.match(viewSwitchingSource, /window\.addEventListener\("load"[\s\S]*?\^#projects\\\/[\^/\]\+\$[\s\S]*?"projectsView"/, "Direct project links must survive the initial saved-view restoration.");
assert(projectsSource.includes("window.closeProjectWorkspaceForViewChange"), "View changes must also reset the hidden in-memory project workspace.");

const urlHelpersStart = projectsSource.indexOf("function buildProjectBootstrapUrl");
const urlHelpersEnd = projectsSource.indexOf("async function loadProjectDetailStats", urlHelpersStart);
assert(urlHelpersStart >= 0 && urlHelpersEnd > urlHelpersStart, "Unable to locate project request URL helpers.");
const urlContext = {
  URLSearchParams,
  apiUrl: "http://localhost:8081/",
  calculateDateRange: () => ({ startDate: "2026-01-01", endDate: "2026-06-30" }),
};
vm.createContext(urlContext);
vm.runInContext(`${projectsSource.slice(urlHelpersStart, urlHelpersEnd)}
this.buildProjectBootstrapUrl = buildProjectBootstrapUrl;
this.buildProjectStatsUrl = buildProjectStatsUrl;`, urlContext);

const portfolioUrl = new URL(urlContext.buildProjectBootstrapUrl("6M", ""));
assert.equal(portfolioUrl.searchParams.get("includeDetail"), "false", "Portfolio loading must not fetch a nested project detail payload.");
assert.equal(portfolioUrl.searchParams.get("scope"), "all", "Portfolio loading must retain active and archived projects.");
const detailUrl = urlContext.buildProjectStatsUrl("OPS / 42", "6M");
assert(detailUrl.includes("stats/projects/OPS%20%2F%2042"), "Project codes must be encoded in detail URLs.");

const trendHelpersStart = projectsSource.indexOf("function normalizeProjectTrendPoints");
const trendHelpersEnd = projectsSource.indexOf("function getSortedProjectWorkspaceContributors", trendHelpersStart);
assert(trendHelpersStart >= 0 && trendHelpersEnd > trendHelpersStart, "Unable to locate project trend rendering helpers.");
const trendContext = {
  createEmptyState: message => `EMPTY:${message}`,
  escapeHtml: value => String(value),
  secondsToDurationLabel: seconds => `${Number(seconds)} seconds`,
  t: (key, values = {}) => `${key}:${values.total || ""}`,
  getProjectChartTheme: () => ({
    tooltip: "#111111",
    tooltipText: "#ffffff",
    textMuted: "#777777",
    grid: "#dddddd",
  }),
  getProjectColorCssValue: () => "#0868d7",
};
vm.createContext(trendContext);
vm.runInContext(`let projectWorkspaceTrendChartInstance = null;
let pendingProjectWorkspaceTrendFrameId = null;
${projectsSource.slice(trendHelpersStart, trendHelpersEnd)}
this.normalizeProjectTrendPoints = normalizeProjectTrendPoints;
this.renderProjectWorkspaceTrend = renderProjectWorkspaceTrend;
this.initializeProjectWorkspaceTrendChart = initializeProjectWorkspaceTrendChart;
this.destroyProjectWorkspaceTrendChart = destroyProjectWorkspaceTrendChart;`, trendContext);

const gappedTrend = trendContext.normalizeProjectTrendPoints({
  period: { startDate: "2026-01-10", endDate: "2026-03-20" },
  approvedTrend: [
    { month: "2026-01", seconds: 3600 },
    { month: "2026-03", seconds: 7200 },
  ],
});
assert.deepEqual(
  Array.from(gappedTrend, point => ({ label: point.label, seconds: point.seconds })),
  [
    { label: "2026-01", seconds: 3600 },
    { label: "2026-02", seconds: 0 },
    { label: "2026-03", seconds: 7200 },
  ],
  "Known missing months inside the selected period must render as zero, not disappear."
);
const singlePointMarkup = trendContext.renderProjectWorkspaceTrend({
  approvedTrend: [{ month: "2026-07", seconds: 5400 }],
});
assert(singlePointMarkup.includes('id="projectWorkspaceTrendChart"'), "A one-month trend must use the shared Chart.js canvas.");
assert(singlePointMarkup.includes('class="project-workspace-trend-data"'), "A one-month trend needs an accessible exact-value table.");
assert(singlePointMarkup.includes("5400 seconds"), "A one-month trend table must retain its exact value.");
assert(!singlePointMarkup.startsWith("EMPTY:"), "A one-month trend must not be presented as missing data.");

const interactiveTrendMarkup = trendContext.renderProjectWorkspaceTrend({
  approvedTrend: [
    { month: "2026-07", seconds: 4500 },
    { month: "2026-08", seconds: 0 },
  ],
});
assert(interactiveTrendMarkup.includes("4500 seconds"), "Interactive trends must expose non-zero exact values in their table.");
assert(interactiveTrendMarkup.includes("0 seconds"), "Interactive trends must expose exact zero values in their table.");
assert(interactiveTrendMarkup.includes("<caption>projects.trendDataCaption:"), "The monthly values table must be independently named.");
assert(!interactiveTrendMarkup.includes("<svg"), "The project workspace must not retain the hand-built SVG chart.");
assert.match(projectsSource, /new Chart\(context,[\s\S]*?type: "line"[\s\S]*?responsive: true[\s\S]*?animation: false/, "The monthly trend must use the bundled responsive Chart.js line chart without animation delay.");
assert.match(projectsSource, /interaction:[\s\S]*?mode: "nearest"[\s\S]*?intersect: false[\s\S]*?tooltip:[\s\S]*?enabled: true[\s\S]*?secondsToDurationLabel\(tooltipContext\.parsed\.y\)/, "The Chart.js tooltip must reveal the exact duration on pointer hover.");
assert.match(projectsSource, /scales:[\s\S]*?x:[\s\S]*?ticks:[\s\S]*?y:[\s\S]*?beginAtZero: true[\s\S]*?callback: value => secondsToDurationLabel\(value\)/, "The trend must include readable month and duration axes.");
assert.match(projectsSource, /function renderProjectDetail\(detail\)[\s\S]*?destroyProjectWorkspaceTrendChart\(\)[\s\S]*?initializeProjectWorkspaceTrendChart\(container, detail\)/, "Every project detail rerender must replace, not stack, the workspace chart.");
assert.match(projectsSource, /function setProjectWorkspaceVisibility\(isOpen[\s\S]*?if \(!isOpen\) \{[\s\S]*?destroyProjectWorkspaceTrendChart\(\)/, "Closing the workspace must release the chart and any pending frame.");
assert.match(projectsSource, /addEventListener\("app:theme-changed"[\s\S]*?workspaceOpen[\s\S]*?initializeProjectWorkspaceTrendChart\(container, detail\)/, "Theme changes must recreate the workspace chart using current theme tokens.");
assert(!projectsSource.includes("renderProjectWorkspaceTrendPoint"), "The hand-built SVG point renderer must be removed.");
assert(!cssSource.includes(".project-workspace-sparkline"), "Dead manual sparkline styles must be removed.");

const queuedFrames = new Map();
let nextFrameId = 1;
const cancelledFrames = [];
const chartInstances = [];
trendContext.window = {
  requestAnimationFrame(callback) {
    const frameId = nextFrameId++;
    queuedFrames.set(frameId, callback);
    return frameId;
  },
  cancelAnimationFrame(frameId) {
    cancelledFrames.push(frameId);
    queuedFrames.delete(frameId);
  },
};
trendContext.Chart = class FakeChart {
  constructor(context, config) {
    this.context = context;
    this.config = config;
    this.destroyed = false;
    chartInstances.push(this);
  }
  destroy() {
    this.destroyed = true;
  }
};
const chartRegion = { innerHTML: "" };
const tableFallback = { open: false };
const canvas = {
  isConnected: true,
  closest: selector => selector === ".project-workspace-trend-chart" ? chartRegion : null,
  getContext: () => ({ canvas: true }),
};
const chartContainer = {
  querySelector(selector) {
    if (selector === "#projectWorkspaceTrendChart") return canvas;
    if (selector === ".project-workspace-trend-data") return tableFallback;
    return null;
  },
};
const lifecycleDetail = { approvedTrend: [{ month: "2026-07", seconds: 5400 }] };
trendContext.initializeProjectWorkspaceTrendChart(chartContainer, lifecycleDetail);
assert.equal(queuedFrames.size, 1, "Trend creation must wait for a rendered layout frame.");
const firstFrame = Array.from(queuedFrames.entries())[0];
queuedFrames.delete(firstFrame[0]);
firstFrame[1]();
assert.equal(chartInstances.length, 1, "A rendered workspace must create one Chart.js instance.");
assert.equal(chartInstances[0].config.options.animation, false, "The workspace trend must not animate after navigation or filtering.");
trendContext.destroyProjectWorkspaceTrendChart();
assert.equal(chartInstances[0].destroyed, true, "Closing or rerendering the workspace must destroy its Chart.js instance.");
trendContext.initializeProjectWorkspaceTrendChart(chartContainer, lifecycleDetail);
assert.equal(queuedFrames.size, 1, "Reopening or changing theme must schedule one replacement chart.");
const pendingFrameId = Array.from(queuedFrames.keys())[0];
trendContext.destroyProjectWorkspaceTrendChart();
assert(cancelledFrames.includes(pendingFrameId), "Closing before render must cancel the pending chart frame.");

for (const field of [
  "statusBuckets",
  "departmentShare",
  "comparison",
  "contributors",
  "recentEntries",
  "approvedTrend",
  "approvedSeconds",
  "pendingCount",
  "sharePercent",
  "lastActivityDate",
]) {
  assert(projectsSource.includes(field), `The project workspace does not consume ${field}.`);
}

assert(projectsSource.includes("PROJECT_WORKSPACE_RECENT_ENTRY_LIMIT"), "Recent entries must remain lazy until requested.");
assert(projectsSource.includes("project-contributor-sort"), "The contributor table must be sortable.");
assert(projectsSource.includes("window.openEmployeeEntryInPeopleView(employeeCode, projectCode, entryId)"), "Entry navigation must use the lazy-safe AppShell helper.");
assert(!/project-entry-navigator[\s\S]{0,1200}openPeopleProjectFilter/.test(projectsSource), "Entry navigation must not call an unloaded People view directly.");
assert.match(projectsSource, /downloadProjectAnalyticsHtmlReport\(currentProjectFilter, projectCode\)/, "Workspace export must pass the selected project code.");
assert.match(projectsSource, /params\.set\("projectCode", String\(projectCode\)\.trim\(\)\)/, "The analytics export URL must carry its project filter.");
assert.match(projectsSource, /const isLatestPendingRequest = pendingProjectDetailRequest[\s\S]*?isLatestPendingRequest && isCurrentProjectDetailRequest[\s\S]*?aria-busy/, "Only the latest current detail request may clear the workspace busy state.");
assert.match(projectsSource, /options\.opener[\s\S]*?projectsViewState\.workspaceOpener = options\.opener/, "The exact project control used to open the workspace must be retained.");
assert.match(projectsSource, /const exactOpener = projectsViewState\.workspaceOpener[\s\S]*?exactOpener && exactOpener\.isConnected[\s\S]*?exactOpener/, "Back must prefer the exact connected opener when restoring focus.");
assert.match(projectsSource, /openProjectDetailFromPortfolio\(projectCode, currentProjectFilter, \{ opener: openButton \}\)/, "Explicit project buttons must pass themselves to the workspace focus workflow.");
assert.match(projectsSource, /fallbackOpener = projectCard\.querySelector\("\.project-card-title-button\.project-open-button"\)/, "Clicking a project card must restore focus to its retained title button.");

const projectCardStart = projectsSource.indexOf("function renderProjectSummaryCard");
const projectCardEnd = projectsSource.indexOf("function applyProjectPortfolioSearch", projectCardStart);
assert(projectCardStart >= 0 && projectCardEnd > projectCardStart, "Unable to locate project card rendering.");
const projectCardSource = projectsSource.slice(projectCardStart, projectCardEnd);
assert(projectCardSource.includes("project-card-title-button project-open-button"), "The project title must remain an obvious keyboard-accessible workspace entry point.");
assert(!projectCardSource.includes('t("action.openProject")'), "Project cards must not repeat a Details button.");
assert(!projectCardSource.includes("project-edit-button"), "Project cards must not include an Edit button.");
assert(indexSource.includes('id="projectWorkspaceEditButton"'), "Project editing must remain available inside the project workspace.");
assert.match(projectsSource, /projectWorkspaceEditButton"\)\.addEventListener\("click"[\s\S]*?openProjectEditorModal\("edit", project\)/, "The workspace Edit action must still open the existing project editor.");

assert.match(appShellSource, /async function openProjectInReview[\s\S]*?ensureManagerAssetsForView\("adminView"\)[\s\S]*?reviewProjectFilter[\s\S]*?pending-tab/, "Review navigation must lazy-load and filter the pending review workspace.");
assert.match(appShellSource, /async function openProjectEntriesInPeople[\s\S]*?ensureManagerAssetsForView\("employeesView"\)[\s\S]*?employeesProjectSelect/, "View entries must lazy-load and filter People.");

for (const selector of [
  ".project-workspace-header",
  ".project-workspace-metrics",
  ".project-workspace-overview-grid",
  ".project-workspace-table-wrap",
  ".project-workspace-entry-row",
  ".project-workspace-trend-chart",
  ".project-workspace-trend-data",
  ".project-workspace-trend-data-wrap",
]) {
  assert(cssSource.includes(selector), `Missing responsive workspace style ${selector}.`);
}

for (const key of [
  "projects.backToPortfolio",
  "projects.reviewPending",
  "projects.viewEntries",
  "projects.exportProject",
  "projects.approvedHours",
  "projects.pendingHours",
  "projects.departmentShare",
  "projects.accessibleProjectsShare",
  "projects.departmentShareBasis",
  "projects.accessibleProjectsShareBasis",
  "projects.trendInteractionHint",
  "projects.trendDataToggle",
  "projects.trendDataCaption",
  "projects.month",
  "projects.duration",
  "projects.recentEntries",
]) {
  assert.equal(i18nSource.split(`"${key}"`).length - 1, 2, `${key} must be translated in English and French.`);
}

assert.match(projectsSource, /function getProjectWorkspaceShareLabel[\s\S]*?scope === "visibleProjects"[\s\S]*?projects\.accessibleProjectsShare/, "Restricted project share must be labelled as accessible scope, not the whole department.");
assert.match(projectsSource, /function getProjectWorkspaceShareBasis[\s\S]*?scope === "visibleProjects"[\s\S]*?projects\.accessibleProjectsShareBasis[\s\S]*?projects\.departmentShareBasis/, "Project share scope must move to the supporting note.");
assert(i18nSource.includes('"projects.departmentShare": "Part du projet"'), "The French project-share title must stay concise.");
assert(i18nSource.includes('"projects.departmentShareBasis": "Parmi les heures supp. approuvées du département"'), "The French project-share note must explain the department basis.");
assert(i18nSource.includes('"projects.usageOverTime": "Heures supp. approuvées par mois"'), "The French trend heading must state its measure and interval.");
assert(!i18nSource.includes('"projects.departmentShare": "Part du projet dans les heures supp. approuvées du département"'), "The oversized former project-share title must not return.");
assert(!i18nSource.includes('"projects.usageOverTime": "Utilisation des heures supp. dans le temps"'), "The vague former trend heading must not return.");

assert(!projectsSource.includes("20260817-project-detail-card-fixes"), "The project workspace must not retain the previous asset version.");
assert(indexSource.includes("assets/apple-ui.css?v=20260817-chartjs-employee-cards-v2"), "The project workspace stylesheet cache key was not bumped.");
assert(appShellSource.includes("ProjectsView.js?v=20260817-chartjs-employee-cards-v2"), "The lazy project script cache key was not bumped.");
assert(!indexSource.includes("20260817-employee-chart-loading-v1"), "The initial frontend assets must not mix the previous cache revision with the new one.");
assert(!appShellSource.includes("20260817-employee-chart-loading-v1"), "Lazy frontend assets must not mix the previous cache revision with the new one.");

console.log("Project workspace UI tests passed.");
