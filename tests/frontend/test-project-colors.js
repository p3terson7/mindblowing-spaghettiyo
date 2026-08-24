const fs = require("fs");
const path = require("path");
const vm = require("vm");

const repoRoot = path.resolve(__dirname, "..", "..");
const read = relativePath => fs.readFileSync(path.join(repoRoot, relativePath), "utf8");
const assert = (condition, message) => {
  if (!condition) throw new Error(message);
};

const utilities = read("app/frontend/scripts/Utilities.js");
const projects = read("app/frontend/scripts/Views/ProjectsView.js");
const approvals = read("app/frontend/scripts/Views/ApprovalsView.js");
const dashboard = read("app/frontend/scripts/Views/DashboardView.js");
const employees = read("app/frontend/scripts/Views/EmployeesView.js");
const self = read("app/frontend/scripts/Views/SelfView.js");
const index = read("app/frontend/index.html");
const css = read("app/frontend/assets/apple-ui.css");
const shell = read("app/frontend/scripts/AppShell.js");

const helperStart = utilities.indexOf("const SAPHIR_PROJECT_COLOR_KEYS");
const helperEnd = utilities.indexOf("function formatProjectCodeAndName", helperStart);
assert(helperStart >= 0 && helperEnd > helperStart, "Project color helpers are missing from Utilities.js.");
const context = {
  escapeHtml: value => String(value),
  getComputedStyle: () => ({ getPropertyValue: () => "" }),
  document: { documentElement: {} },
};
vm.createContext(context);
vm.runInContext(`${utilities.slice(helperStart, helperEnd)}
this.projectColorApi={
  SAPHIR_PROJECT_COLOR_KEYS,
  SAPHIR_PROJECT_MARKER_KEYS,
  SAPHIR_PROJECT_IDENTITY_COUNT,
  getProjectIdentityBucket,
  getProjectIdentityFromBucket,
  getDefaultProjectColorKey,
  getDefaultProjectMarkerKey,
  normalizeProjectColorKey,
  normalizeProjectMarkerKey,
  getProjectColorKey,
  getProjectMarkerKey,
  getProjectChartPointStyle,
  getProjectChartBorderDash,
  renderProjectIdentityPill,
};`, context);
const api = context.projectColorApi;
assert(api.normalizeProjectColorKey("VIOLET", "P1") === "violet", "Supported project colors are not normalized.");
assert(api.normalizeProjectColorKey("javascript:red", "P1") === api.getDefaultProjectColorKey("P1"), "Arbitrary project colors are not rejected by the client fallback.");
assert(api.getDefaultProjectColorKey("LEGACY") === api.getDefaultProjectColorKey("LEGACY"), "Legacy project color fallback is not stable.");
assert(api.normalizeProjectMarkerKey("DIAMOND", "P1") === "diamond", "Supported project markers are not normalized.");
assert(api.normalizeProjectMarkerKey("star", "P1") === api.getDefaultProjectMarkerKey("P1"), "Arbitrary project markers are not rejected by the client fallback.");
assert(api.SAPHIR_PROJECT_COLOR_KEYS.length === 10, "The accessible palette must retain its ten established colors.");
assert(api.SAPHIR_PROJECT_MARKER_KEYS.length === 4, "The project identity system must expose four marker shapes.");
assert(api.SAPHIR_PROJECT_IDENTITY_COUNT === 40, "Colors and markers must provide forty combinations.");

function getLegacyColorKey(projectCode) {
  let hash = 0;
  String(projectCode || "").trim().toUpperCase().split("").forEach(character => {
    hash = ((hash * 31) + character.charCodeAt(0)) % api.SAPHIR_PROJECT_COLOR_KEYS.length;
  });
  return api.SAPHIR_PROJECT_COLOR_KEYS[Math.abs(hash)];
}

for (const projectCode of ["", "P1", "LEGACY", "OPS / 42", "équipe-7", "zzzzzz"] ) {
  assert(api.getDefaultProjectColorKey(projectCode) === getLegacyColorKey(projectCode), `Legacy color fallback changed for ${projectCode}.`);
}

const pill = api.renderProjectIdentityPill({ projectCode: "P1", colorKey: "mint", markerKey: "diamond" }, "P1");
assert(pill.includes("project-color-mint"), "Project identity pills do not expose their semantic color token.");
assert(pill.includes("project-marker-diamond"), "Project identity pills do not expose their marker shape.");
assert(api.getProjectChartPointStyle({ markerKey: "diamond" }) === "rectRot", "Diamond identities do not map to Chart.js point styles.");
assert(JSON.stringify(api.getProjectChartBorderDash({ markerKey: "triangle" })) === JSON.stringify([12, 4, 3, 4]), "Triangle identities do not map to an accessible line pattern.");

const recommendationStart = projects.indexOf("function getProjectIdentityUsageCount");
const recommendationEnd = projects.indexOf("function getProjectEditorIdentityContext", recommendationStart);
assert(recommendationStart >= 0 && recommendationEnd > recommendationStart, "Project identity recommendation helpers are missing.");
context.projectsViewState = {
  projects: Array.from({ length: 39 }, (_, bucket) => ({
    projectCode: `USED-${bucket}`,
    ...api.getProjectIdentityFromBucket(bucket),
  })),
};
context.isProjectArchived = project => Boolean(project && project.archived);
vm.runInContext(`${projects.slice(recommendationStart, recommendationEnd)}
this.getRecommendedProjectIdentity=getRecommendedProjectIdentity;
this.getProjectIdentityUsageCount=getProjectIdentityUsageCount;`, context);
const recommendation = context.getRecommendedProjectIdentity("TARGET");
const unusedIdentity = api.getProjectIdentityFromBucket(39);
assert(recommendation.colorKey === unusedIdentity.colorKey && recommendation.markerKey === unusedIdentity.markerKey, "The editor does not scan all forty combinations to find the unused identity.");
assert(recommendation.usageCount === 0, "The recommended project identity is already in use.");
context.projectsViewState.projects.push({
  projectCode: "ARCHIVED-ONLY",
  archived: true,
  ...unusedIdentity,
});
assert(context.getProjectIdentityUsageCount(unusedIdentity.colorKey, unusedIdentity.markerKey) === 0, "Archived projects must not exhaust identities for the active portfolio.");

const legendStart = projects.indexOf("function createProjectDoughnutLegendLabels");
const legendEnd = projects.indexOf("function renderProjectDoughnutInsight", legendStart);
assert(legendStart >= 0 && legendEnd > legendStart, "Project doughnut legend helper is missing.");
context.Chart = {
  overrides: {
    doughnut: {
      plugins: {
        legend: {
          labels: {
            generateLabels: chart => chart.data.labels.map((text, index) => ({ text, index })),
          },
        },
      },
    },
  },
};
vm.runInContext(`${projects.slice(legendStart, legendEnd)}
this.createProjectDoughnutLegendLabels=createProjectDoughnutLegendLabels;`, context);
const doughnutItems = [
  { label: "A", project: { projectCode: "A", markerKey: "circle" } },
  { label: "B", project: { projectCode: "B", markerKey: "diamond" } },
  { label: "C", project: { projectCode: "C", markerKey: "triangle" } },
];
const doughnutLabels = context.createProjectDoughnutLegendLabels({ data: { labels: ["A", "B", "C"] } }, doughnutItems);
assert(doughnutLabels.length === doughnutItems.length, "A doughnut legend item is not generated for every arc.");
assert(JSON.stringify(doughnutLabels.map(item => item.pointStyle)) === JSON.stringify(["circle", "rectRot", "triangle"]), "Doughnut legend markers do not follow each project identity.");

assert(index.includes('id="projectEditorColorChoices"'), "The project editor has no visual color picker.");
assert(index.includes('id="projectEditorMarkerChoices"'), "The project editor has no visual marker picker.");
assert(index.includes('id="projectEditorIdentityUsage"'), "The project editor does not announce identity collisions.");
assert(index.includes('id="projectEditorUseRecommendedIdentityButton"'), "The project editor cannot apply its recommended free combination.");
assert(projects.includes('type="radio" name="projectEditorColorKey"'), "Project colors are not exposed as accessible radio choices.");
assert(projects.includes('type="radio" name="projectEditorMarkerKey"'), "Project markers are not exposed as accessible radio choices.");
assert(projects.includes("colorKey,"), "Project changes do not submit colorKey.");
assert(projects.includes("markerKey,"), "Project changes do not submit markerKey.");
assert(projects.includes("renderProjectEditorIdentityOptions(getProjectColorKey(project), getProjectMarkerKey(project))"), "Editing a project does not restore its chosen color and marker.");
assert(projects.includes("getProjectColorCssValue"), "Project charts do not consume persisted project colors.");
assert(projects.includes("getProjectChartPointStyle"), "Project charts do not consume persisted project marker shapes.");
assert(projects.includes("getProjectChartBorderDash"), "Project trend lines are not distinguishable between their points.");
assert(projects.includes(": getProjectColorCssValue(projectIdentity);"), "Trend rows for legacy projects outside the catalog do not keep a stable code-derived color.");
assert(projects.includes("generateLabels: chart => createProjectDoughnutLegendLabels(chart, chartItems)"), "The doughnut legend does not expose per-project marker shapes.");
assert(projects.includes("getStableProjectChartColor(item.label)"), "Non-project chart colors are not stable by label.");
assert(projects.includes('"#7f6b52", "#0f8f7a"'), "The generic chart palette does not expose all ten theme colors.");
assert(projects.includes('const PROJECT_OTHER_TREND_KEY = "__SAPHIR_OTHER_PROJECTS__"'), "The grouped project dataset has no language-independent sentinel.");
assert(projects.includes('const PROJECT_OTHER_CHART_POINT_STYLE = "crossRot"'), "The grouped project dataset has no reserved marker outside the assignable project shapes.");
assert(projects.includes("const PROJECT_OTHER_CHART_BORDER_DASH = Object.freeze([3, 5])"), "The grouped project dataset has no fixed line pattern.");
assert(projects.includes('label: isOther ? t("projects.other") : projectCode'), "The grouped project dataset does not separate its localized label from its stable identity.");
assert(projects.includes("item.isOther ? theme.textMuted"), "The grouped doughnut arc can change color with the interface language.");
assert(approvals.includes("renderProjectIdentityPill(projectRecord, projectCode)"), "Revision cards do not show project color identity.");
assert(dashboard.includes("renderDashboardEntryProjectIdentity"), "Dashboard entries do not show project color identity.");
assert(employees.includes("renderProjectIdentityPill(project, project.projectCode)"), "Employee project cards do not show project color identity.");
assert(self.includes("renderProjectColorDot(project)"), "Self project summaries do not show project color identity.");
assert(css.includes("--project-color-blue:"), "Theme project color tokens are missing.");
assert(css.includes(".project-identity-pill"), "Shared project identity pill styling is missing.");
for (const markerKey of api.SAPHIR_PROJECT_MARKER_KEYS) {
  assert(css.includes(`.project-color-dot.project-marker-${markerKey}`), `Project marker CSS is missing for ${markerKey}.`);
}
assert(css.includes(".project-identity-choice-input:focus-visible"), "Project identity radio choices lack a visible keyboard focus state.");

for (const asset of [
  "assets/apple-ui.css",
  "scripts/I18n.js",
  "scripts/Utilities.js",
  "scripts/AppShell.js",
  "scripts/Views/SelfView.js",
]) {
  assert(index.includes(`${asset}?v=20260824-review-attention-tab-v1`), `${asset} cache key was not bumped.`);
}
for (const view of ["EmployeesView", "DashboardView", "ApprovalsView", "ProjectsView"]) {
  assert(shell.includes(`${view}.js?v=20260824-review-attention-tab-v1`), `${view} cache key was not bumped.`);
}

console.log("Project color UI tests passed.");
