const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const root = path.resolve(__dirname, "../..");
const source = fs.readFileSync(path.join(root, "app/frontend/scripts/Views/ProjectBudgetBeta.js"), "utf8");
const context = {
  window: {},
  t: key => key,
  getCurrentLocale: () => "fr-CA",
  escapeHtml: value => String(value).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;"),
  formatDateLabel: value => value,
  formatCurrencyCents: value => `${(value / 100).toFixed(2)} $`,
  secondsToDurationLabel: value => `${Math.floor(value / 3600)}h ${String(Math.floor(value % 3600 / 60)).padStart(2, "0")}`,
};
vm.runInNewContext(source, context);
const model = context.window.Saphir.budgetBeta.model;
const fullMoney = { totalAmountCents: 6000, cashAmountCents: 4000, compensatoryLeaveValueCents: 2000, calculatedEntryCount: 1, unavailableEntryCount: 0 };
const missingMoney = { totalAmountCents: 0, cashAmountCents: 0, compensatoryLeaveValueCents: 0, calculatedEntryCount: 0, unavailableEntryCount: 1 };
assert.equal(model.valueOf({ totalSeconds: 4500 }, "hours"), 1.25);
assert.equal(model.valueOf({ monetary: fullMoney }, "money"), 6000);
assert.equal(model.valueOf({ monetary: missingMoney }, "money"), null, "Unpriced overtime must not become a zero-dollar bar.");
assert.equal(model.valueOf({ totalSeconds: 3600 }, "money"), null, "The beta must not infer money from hours.");
const a = { id: "P1", configured: true, startDate: "2026-01-01", endDate: "2026-01-31", approvedSeconds: 7200, monetary: fullMoney, projects: [{ projectCode: "A", projectName: "Alpha", totalSeconds: 3600, monetary: fullMoney }, { projectCode: "B", projectName: "Beta", totalSeconds: 3600, monetary: missingMoney }] };
const b = { id: "P2", configured: true, startDate: "2026-02-01", endDate: "2026-02-28", approvedSeconds: 10800, monetary: fullMoney, projects: [{ projectCode: "A", projectName: "Alpha", totalSeconds: 10800, monetary: fullMoney }, { projectCode: "C", projectName: "Gamma", totalSeconds: 3600, monetary: fullMoney }] };
const rows = model.comparisonRows(a, b, "hours");
assert.equal(rows[0].code, "A", "Projects must be ranked by absolute change, not arbitrary order.");
assert.equal(rows.find(row => row.code === "B").b, 0, "A project absent in B should have zero activity in B.");
assert.equal(model.comparisonRows(a, b, "money").find(row => row.code === "B").a, null, "Missing monetary coverage must survive the comparison.");
assert.equal(model.comparisonRows(a, b, "hours", "change", "gamma").length, 1);
const colors = { surface: "#ffffff", foreground: "#222222", muted: "#666666", border: "#dddddd", accent: "#2369dc" };
const option = model.annualOption({ periods: [a, b] }, "money", colors);
assert.equal(option.series.length, 2, "Cash and leave need separate stacked series.");
assert.equal(option.series[0].data[0], 4000);
assert.equal(option.series[1].data[0], 2000);
assert.equal(option.dataZoom.length, 2);
assert(option.toolbox.feature.saveAsImage);
const echarts = require(path.join(root, "app/frontend/assets/vendor/echarts/echarts.min.js"));
const chart = echarts.init(null, null, { renderer: "svg", ssr: true, width: 1000, height: 400 });
chart.setOption(option);
const svg = chart.renderToSVGString();
assert(svg.includes("<svg") && svg.includes("P1") && svg.includes("P2"), "The vendored ECharts runtime must render the beta options.");
chart.dispose();
console.log("Budget ECharts beta tests passed: actual library rendering, exact values, missing coverage, project ranking and local runtime.");
