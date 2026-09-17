const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const repoRoot = path.resolve(__dirname, "..", "..");
const read = relativePath => fs.readFileSync(path.join(repoRoot, relativePath), "utf8");
const projectsSource = read("app/frontend/scripts/Views/ProjectsView.js");
const indexSource = read("app/frontend/index.html");
const i18nSource = read("app/frontend/scripts/I18n.js");

const ensureStart = projectsSource.indexOf("function ensureProjectChartCanvas");
const ensureEnd = projectsSource.indexOf("function getProjectInsightStage", ensureStart);
const compactStart = projectsSource.indexOf("function compactProjectTrendData");
const helperStart = projectsSource.indexOf("function getProjectTrendColorWithOpacity", compactStart);
const helperEnd = projectsSource.indexOf("function renderProjectInsights", helperStart);
const chartStart = projectsSource.indexOf("function renderProjectMultiLineChart");
const chartEnd = projectsSource.indexOf('document.getElementById("projectsSummaryContainer")', chartStart);
assert(ensureStart >= 0 && ensureEnd > ensureStart, "The chart canvas lifecycle helper is missing.");
assert(compactStart >= 0 && helperStart > compactStart && helperEnd > helperStart, "The project trend clarity helpers are missing.");
assert(chartStart >= 0 && chartEnd > chartStart, "The project trend renderer is missing.");

const canvas = {
  setAttribute() {},
  getContext: () => ({ canvas: true }),
};
const stage = { innerHTML: "" };
const document = {
  documentElement: {},
  querySelector(selector) {
    return selector === "#projectChartContainer .chart-stage" ? stage : null;
  },
  getElementById(id) {
    return id === "projectMultiLineChart" ? canvas : null;
  },
};

const chartInstances = [];
class FakeChart {
  constructor(context, config) {
    this.context = context;
    this.config = config;
    this.data = config.data;
    this.updateCalls = [];
    this.shown = [];
    this.hidden = [];
    chartInstances.push(this);
  }
  destroy() {
    this.destroyed = true;
  }
  resize() {
    this.resized = true;
  }
  update(mode) {
    this.updateCalls.push(mode);
  }
  show(index) {
    this.shown.push(index);
  }
  hide(index) {
    this.hidden.push(index);
  }
}

const context = {
  Intl,
  Chart: FakeChart,
  document,
  window: {
    requestAnimationFrame(callback) {
      callback();
      return 1;
    },
    cancelAnimationFrame() {},
    projectChartInstance: null,
  },
  pendingProjectChartFrameId: null,
  PROJECT_OTHER_TREND_KEY: "__SAPHIR_OTHER_PROJECTS__",
  PROJECT_OTHER_CHART_POINT_STYLE: "crossRot",
  PROJECT_OTHER_CHART_BORDER_DASH: [3, 5],
  PROJECT_TREND_LINE_WIDTH: 3,
  PROJECT_TREND_FOCUSED_LINE_WIDTH: 3.75,
  PROJECT_TREND_MUTED_LINE_WIDTH: 1.5,
  projectsViewState: {
    projects: [
      { projectCode: "QMS-730", markerKey: "triangle" },
      { projectCode: "DAT-390", markerKey: "diamond" },
    ],
  },
  findProjectByCode: (projects, code) => projects.find(project => project.projectCode === code) || null,
  getProjectColorCssValue: project => project && project.projectCode === "DAT-390" ? "#c43840" : "#0868d7",
  getProjectChartPointStyle: project => project && project.markerKey === "diamond" ? "rectRot" : "triangle",
  getProjectChartTheme: () => ({
    textMuted: "#667085",
    textSecondary: "#4a5568",
    tooltip: "#1d1d1f",
    tooltipText: "#ffffff",
    grid: "rgba(29, 29, 31, 0.08)",
  }),
  formatYMToWords: value => value,
  getCurrentLocale: () => "en-CA",
  t: key => key === "projects.other" ? "Other" : key,
  createEmptyState: message => message,
};
vm.createContext(context);
vm.runInContext(`
${projectsSource.slice(ensureStart, ensureEnd)}
${projectsSource.slice(compactStart, helperEnd)}
${projectsSource.slice(chartStart, chartEnd)}
this.getProjectTrendColorWithOpacity = getProjectTrendColorWithOpacity;
this.formatProjectTrendHours = formatProjectTrendHours;
this.updateProjectTrendFocus = updateProjectTrendFocus;
this.toggleProjectTrendLegendDataset = toggleProjectTrendLegendDataset;
this.renderProjectMultiLineChart = renderProjectMultiLineChart;
`, context);

assert.equal(context.getProjectTrendColorWithOpacity("#0868d7", 0.28), "rgba(8, 104, 215, 0.28)", "Trend colors must support reliable visual muting.");
assert.equal(context.formatProjectTrendHours(3.5), "3.50 h", "Tooltip formatting must preserve the exact two-decimal trend value.");

context.renderProjectMultiLineChart({
  "QMS-730": [
    { month: "2026-06", overtime: 4.25 },
    { month: "2026-07", overtime: 6 },
  ],
  "DAT-390": [
    { month: "2026-06", overtime: 3.5 },
    { month: "2026-07", overtime: 2.75 },
  ],
  "OPS-100": [
    { month: "2026-06", overtime: 8 },
    { month: "2026-07", overtime: 9.5 },
  ],
  "APP-220": [
    { month: "2026-06", overtime: 2 },
    { month: "2026-07", overtime: 4 },
  ],
  "NET-640": [
    { month: "2026-06", overtime: 1.25 },
    { month: "2026-07", overtime: 2 },
  ],
  "CLT-120": [
    { month: "2026-06", overtime: 1 },
    { month: "2026-07", overtime: 1.5 },
  ],
  "EXTRA-1": [
    { month: "2026-06", overtime: 1 },
    { month: "2026-07", overtime: 1 },
  ],
});

assert.equal(chartInstances.length, 1, "The project trend must create one Chart.js instance.");
const chart = chartInstances[0];
const actualProjectDatasets = chart.data.datasets.filter(dataset => !dataset.$saphirIsOther);
const otherDataset = chart.data.datasets.find(dataset => dataset.$saphirIsOther);
assert(actualProjectDatasets.length > 0, "At least one concrete project dataset must remain visible.");
for (const dataset of actualProjectDatasets) {
  assert.equal(dataset.borderWidth, 3, "Concrete project lines must use the readable primary line width.");
  assert.deepEqual(Array.from(dataset.borderDash), [], "Concrete project lines must remain solid; marker shapes already distinguish them.");
  assert.equal(dataset.pointRadius, 4, "Concrete project points must remain large enough to target.");
  assert.equal(dataset.tension, 0, "Trend lines must join exact monthly values without decorative curvature.");
}
assert(otherDataset, "Compacted trends must retain the contextual Other series.");
assert.deepEqual(Array.from(otherDataset.borderDash), [3, 5], "The aggregate Other series must stay visually distinct.");
assert.equal(otherDataset.borderWidth, 1.5, "The aggregate Other series must not compete with concrete projects.");

const chartOptions = chart.config.options;
assert.equal(chartOptions.interaction.mode, "nearest", "Trend hover must work between points.");
assert.equal(chartOptions.interaction.intersect, false, "Trend hover must not require pixel-perfect targeting.");
assert.equal(chartOptions.scales.x.grid.display, false, "Vertical grid lines must be removed to reduce chart noise.");
assert.equal(chartOptions.plugins.tooltip.callbacks.label({ dataset: { label: "QMS-730" }, parsed: { y: 4.25 } }), "QMS-730: 4.25 h", "Trend tooltips must expose exact series values.");

chartOptions.onHover({}, [{ datasetIndex: 1 }], chart);
assert.equal(chart.data.datasets[1].borderWidth, 3.75, "Hovering a series must give it priority.");
assert.equal(chart.data.datasets[0].borderWidth, 1.5, "Hovering a series must soften competing project lines.");
assert(chart.updateCalls.includes("none"), "Focus changes must redraw without animation lag.");

chartOptions.plugins.legend.onClick({}, { datasetIndex: 0 }, { chart });
assert.equal(chart.$saphirIsolatedDatasetIndex, 0, "Clicking a legend item must isolate its project.");
assert(chart.hidden.includes(1), "Isolating a project must hide competing series.");
chartOptions.plugins.legend.onClick({}, { datasetIndex: 0 }, { chart });
assert.equal(chart.$saphirIsolatedDatasetIndex, null, "Clicking the isolated legend item again must restore all projects.");
assert(chart.shown.length >= chart.data.datasets.length, "Restoring a project must make every series visible again.");

assert(indexSource.includes('id="projectTrendInteractionHint"'), "The chart must explain its hover and legend interaction.");
assert(indexSource.includes('aria-describedby="projectTrendInteractionHint"'), "The chart interaction instructions must be exposed to assistive technology.");
for (const copy of [
  '"projects.portfolioTrendInteractionHint": "Hover a line for its exact value.',
  '"projects.portfolioTrendInteractionHint": "Survolez une ligne pour voir sa valeur exacte.',
]) {
  assert(i18nSource.includes(copy), `Missing chart interaction copy: ${copy}`);
}

console.log("Project trend clarity UI tests passed.");
