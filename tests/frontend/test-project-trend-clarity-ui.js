const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync(require('node:path').resolve(__dirname, '../../app/frontend/scripts/Views/ProjectsView.js'), 'utf8');
const host = { isConnected: true, clientWidth: 900 };
const chart = { options: null, isDisposed: () => false, getDom: () => host, setOption(value) { this.options = value; }, resize() {} };
const context = { projectTrendRenderVersion: 0, projectTrendResizeObserver: null,
  ensureProjectChartCanvas: () => host, loadScriptOnce: async () => {}, window: { projectChartInstance: chart },
  projectsViewState: { projects: [] }, compactProjectTrendData: x => x, PROJECT_OTHER_TREND_KEY: 'OTHER',
  findProjectByCode: () => null, getProjectChartPointStyle: () => 'triangle', getProjectColorCssValue: () => '#0868d7',
  getProjectChartTheme: () => ({ textMuted: '#888', textSecondary: '#aaa', grid: '#333' }),
  document: { body: {} }, getComputedStyle: () => ({ fontFamily: 'sans-serif' }),
  formatYMToWords: x => x, formatProjectTrendHours: x => x + ' h', secondsToDurationLabel: x => String(x), escapeHtml: x => String(x), t: x => x,
};
vm.createContext(context);
const start = source.indexOf('function renderProjectMultiLineChart(');
const end = source.indexOf('document.getElementById("projectsSummaryContainer")', start);
vm.runInContext(source.slice(start, end), context);
(async () => {
  await context.renderProjectMultiLineChart({ P1: [{ month: '2026-01', overtime: 1.23, seconds: 4500 }], OTHER: [{ month: '2026-01', overtime: 2 }] });
  const option = chart.options;
  assert.equal(option.series[0].data[0], 1.25, 'Stored seconds must take precedence over rounded trend hours');
  assert.equal(option.series[0].lineStyle.width, 3);
  assert.equal(option.series[0].lineStyle.type, 'solid');
  assert.equal(option.series[0].smooth, false);
  assert.equal(option.series[1].lineStyle.type, 'dotted');
  assert.equal(option.tooltip.trigger, 'axis');
  assert.equal(option.legend.type, 'scroll');
  assert.equal(option.dataZoom.length, 2);
  assert.equal(option.dataZoom[0].zoomOnMouseWheel, 'ctrl', 'Ordinary page scrolling must not zoom the chart');
  assert.equal(option.aria.enabled, true);
  assert.equal(option.xAxis.axisLabel.alignMaxLabel, 'right', 'The last date must stay inside the plot');
  assert.equal(option.xAxis.axisLabel.showMaxLabel, true);
  assert(option.grid.bottom >= 88, 'Zoom controls need separation from the date labels');
  assert(option.yAxis.splitNumber >= 7, 'The taller chart needs enough Y-axis landmarks');
  assert(option.tooltip.formatter([{ axisValueLabel: 'Jan', seriesName: 'P1', marker: '', value: 1.25 }]).includes('4500'));
  const previous = chart.options;
  let releaseLibrary, hostTouches = 0;
  context.loadScriptOnce = () => new Promise(resolve => { releaseLibrary = resolve; });
  context.ensureProjectChartCanvas = () => { hostTouches++; return host; };
  const pending = context.renderProjectMultiLineChart({});
  assert.equal(hostTouches, 0, 'Keep the loading indicator until the chart library is ready');
  context.projectTrendRenderVersion++;
  releaseLibrary();
  await pending;
  assert.equal(hostTouches, 0, 'An obsolete library response must not clear a newer loading indicator');
  assert.equal(chart.options, previous, 'An obsolete library load must not overwrite a newer chart');
  console.log('ECharts project trend passed: exact values, readable lines, tooltip, legend, zoom and stale-render guard.');
})().catch(error => { console.error(error); process.exitCode = 1; });
