const assert = require("assert");
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const repoRoot = path.resolve(__dirname, "..", "..");
const serviceSource = fs.readFileSync(
  path.join(repoRoot, "app/backend/services/AnalyticsReportService.ps1"),
  "utf8"
);
const functionStart = serviceSource.indexOf("function Get-AnalyticsDepartmentReportHtmlTemplate");
const templateMarker = "return @'\n<!doctype html>";
const templateStart = serviceSource.indexOf(templateMarker, functionStart);
const templateEnd = serviceSource.indexOf("\n'@\n}", templateStart);
assert(functionStart >= 0 && templateStart > functionStart && templateEnd > templateStart, "Unable to extract the department report template.");
const template = serviceSource.slice(templateStart + "return @'\n".length, templateEnd);

assert(!template.includes("employeeFilter"), "The department template must not include an employee filter.");
assert(!template.includes("employeeContributors"), "The department template must not include a contributor ranking.");
assert(!template.includes("employeeRef"), "The department template must not depend on employee references.");
assert(!template.includes("data.employees"), "The department template must not depend on employee data.");

const ui = {
  title: "Department overtime overview", subtitle: "Projects only", snapshot: "Generated", period: "Period",
  allData: "All", scope: "Scope", scopeAll: "All accessible projects", selectedProject: "Selected project",
  approvedHours: "Approved hours", pendingHours: "Pending hours", approvalRate: "Approval rate",
  activeProjects: "Active projects", entries: "Entries", decisionHighlights: "Discussion points",
  topProject: "Leading project", projectConcentration: "Top three concentration", peakMonth: "Busiest month",
  pendingDecision: "Hours to decide", noActivity: "No activity", projectPortfolio: "Project distribution",
  projectPortfolioHint: "Exact hours", project: "Project", sector: "Sector", approved: "Approved",
  pending: "Pending", rejected: "Rejected", other: "Other", projectShare: "Share", duration: "Duration",
  monthlyTrend: "Monthly trend", monthlyTrendHint: "Approved monthly", decisionTracking: "Decision tracking",
  decisionTrackingHint: "All statuses", paymentBreakdown: "Payment", paymentBreakdownHint: "Approved only",
  sectorBreakdown: "Sector distribution", sectorBreakdownHint: "By sector", drivers: "Drivers", driversHint: "Codes",
  reasons: "Reasons", overtimeCodes: "Overtime codes", qualityTitle: "Quality", qualitySummary: "Quality summary",
  qualityInvalidDate: "Invalid dates", qualityInvalidDuration: "Invalid duration", qualityIncompleteApproved: "Incomplete",
  qualityUnknownEntryType: "Unknown type", qualityUnknownStatus: "Unknown status", qualityMissingProject: "Missing project",
  qualityDiverse: "Diverse", qualityNone: "No issues", aggregatedData: "Aggregated project data",
  aggregatedDataHint: "No individual data", print: "Print", exportCsv: "Export aggregated", noData: "No data",
  cash: "Cash", leave: "Leave", noSector: "No sector", hours: "h",
};
const model = {
  meta: {
    schemaVersion: 1,
    reportMode: "department",
    generatedAtUtc: "2026-08-27T12:00:00.000Z",
    locale: "en",
    period: { startDate: "2026-07-01", endDate: "2026-08-31" },
    defaultProject: "",
  },
  ui,
  summary: {
    approvedSeconds: 10800,
    pendingSeconds: 1800,
    rejectedSeconds: 900,
    otherSeconds: 0,
    approvedEntryCount: 2,
    pendingEntryCount: 1,
    rejectedEntryCount: 1,
    otherEntryCount: 0,
    entryCount: 4,
    activeProjectCount: 2,
  },
  projects: [
    { projectCode: "P1", displayName: "Alpha", sector: "Ops", colorKey: "blue", markerKey: "circle", approvedSeconds: 7200, pendingSeconds: 1800, rejectedSeconds: 0, otherSeconds: 0, totalSeconds: 9000, approvedEntryCount: 1, pendingEntryCount: 1, rejectedEntryCount: 0, otherEntryCount: 0, entryCount: 2 },
    { projectCode: "P2", displayName: "Beta", sector: "Tech", colorKey: "coral", markerKey: "triangle", approvedSeconds: 3600, pendingSeconds: 0, rejectedSeconds: 900, otherSeconds: 0, totalSeconds: 4500, approvedEntryCount: 1, pendingEntryCount: 0, rejectedEntryCount: 1, otherEntryCount: 0, entryCount: 2 },
  ],
  months: [
    { month: "2026-07", approvedSeconds: 7200, pendingSeconds: 1800, rejectedSeconds: 0, otherSeconds: 0, totalSeconds: 9000, approvedEntryCount: 1, pendingEntryCount: 1, rejectedEntryCount: 0, otherEntryCount: 0, entryCount: 2 },
    { month: "2026-08", approvedSeconds: 3600, pendingSeconds: 0, rejectedSeconds: 900, otherSeconds: 0, totalSeconds: 4500, approvedEntryCount: 1, pendingEntryCount: 0, rejectedEntryCount: 1, otherEntryCount: 0, entryCount: 2 },
  ],
  sectors: [
    { sector: "Ops", approvedSeconds: 7200, pendingSeconds: 1800, rejectedSeconds: 0, otherSeconds: 0, totalSeconds: 9000, entryCount: 2 },
    { sector: "Tech", approvedSeconds: 3600, pendingSeconds: 0, rejectedSeconds: 900, otherSeconds: 0, totalSeconds: 4500, entryCount: 2 },
  ],
  payments: [{ payment: "cash", approvedSeconds: 10800, pendingSeconds: 1800, rejectedSeconds: 900, otherSeconds: 0, totalSeconds: 13500, entryCount: 4 }],
  reasons: [{ reasonCode: "D", approvedSeconds: 10800, pendingSeconds: 1800, rejectedSeconds: 900, otherSeconds: 0, totalSeconds: 13500, entryCount: 4 }],
  overtimeCodes: [{ overtimeCode: "260", approvedSeconds: 10800, pendingSeconds: 1800, rejectedSeconds: 900, otherSeconds: 0, totalSeconds: 13500, entryCount: 4 }],
  statuses: [
    { status: "approved", approvedSeconds: 10800, pendingSeconds: 0, rejectedSeconds: 0, otherSeconds: 0, totalSeconds: 10800, entryCount: 2 },
    { status: "pending", approvedSeconds: 0, pendingSeconds: 1800, rejectedSeconds: 0, otherSeconds: 0, totalSeconds: 1800, entryCount: 1 },
    { status: "rejected", approvedSeconds: 0, pendingSeconds: 0, rejectedSeconds: 900, otherSeconds: 0, totalSeconds: 900, entryCount: 1 },
  ],
  quality: { invalidDateCount: 0, invalidDurationCount: 0, incompleteApprovedCount: 0, unknownEntryTypeCount: 0, unknownStatusCount: 0, missingProjectCount: 0, diverseEntryCount: 0 },
};

const encoded = Buffer.from(JSON.stringify(model), "utf8").toString("base64");
const html = template
  .replace("__LANG__", "en")
  .replace("__TITLE__", ui.title)
  .replace("__REPORT_DATA_BASE64__", encoded);
const scripts = [...html.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/g)].map(match => match[1]);
assert.strictEqual(scripts.length, 2, "The department report must contain one data block and one executable script.");

class MockElement {
  constructor(tagName = "div", id = "") {
    this.tagName = tagName.toUpperCase();
    this.id = id;
    this.children = [];
    this.listeners = {};
    this.style = { setProperty(name, value) { this[name] = String(value); } };
    this._textContent = "";
    this.className = "";
    this.hidden = false;
  }
  set textContent(value) { this._textContent = String(value == null ? "" : value); }
  get textContent() { return this._textContent; }
  appendChild(child) { this.children.push(child); return child; }
  append(...children) { this.children.push(...children); }
  replaceChildren(...children) { this.children = [...children]; this.textContent = ""; }
  addEventListener(type, listener) { this.listeners[type] = listener; }
  click() { if (this.listeners.click) this.listeners.click({ currentTarget: this, target: this }); }
}

const elementIds = [
  "reportData", "reportTitle", "reportSubtitle", "reportPeriod", "reportSnapshot", "scopeLabel", "scopeSummary",
  "printButton", "csvButton", "approvedHoursLabel", "approvedHoursValue", "approvedHoursHint", "pendingHoursLabel",
  "pendingHoursValue", "pendingHoursHint", "approvalRateLabel", "approvalRateValue", "approvalRateHint",
  "activeProjectsLabel", "activeProjectsValue", "activeProjectsHint", "entriesLabel", "entriesValue", "entriesHint",
  "decisionHighlightsTitle", "topProjectLabel", "topProjectValue", "topProjectDetail", "concentrationLabel",
  "concentrationValue", "concentrationDetail", "peakMonthLabel", "peakMonthValue", "peakMonthDetail",
  "pendingDecisionLabel", "pendingDecisionValue", "pendingDecisionDetail", "projectPortfolioTitle", "projectPortfolioHint",
  "projectTableHead", "projectTableBody", "monthlyTrendTitle", "monthlyTrendHint", "monthlyTrend", "decisionTrackingTitle",
  "decisionTrackingHint", "statusBreakdown", "paymentBreakdownTitle", "paymentBreakdownHint", "paymentBreakdown",
  "sectorBreakdownTitle", "sectorBreakdownHint", "sectorBreakdown", "driversTitle", "driversHint", "reasonsTitle",
  "reasonDrivers", "overtimeCodesTitle", "overtimeCodeDrivers", "qualityPanel", "qualityTitle", "qualitySummary",
  "qualityList", "aggregatedDataTitle", "aggregatedDataHint",
];
const elements = new Map(elementIds.map(id => [id, new MockElement("div", id)]));
elements.get("reportData").textContent = encoded;
const createdElements = [];
let printCalled = false;
const context = {
  document: {
    getElementById: id => elements.get(id) || null,
    createElement: tag => { const element = new MockElement(tag); createdElements.push(element); return element; },
    createTextNode: text => ({ textContent: String(text) }),
  },
  window: { print: () => { printCalled = true; } },
  URL: { createObjectURL: () => "blob:test", revokeObjectURL: () => {} },
  Blob,
  TextDecoder,
  Uint8Array,
  Intl,
  Date,
  Math,
  Object,
  Array,
  String,
  Number,
  Buffer,
  atob: value => Buffer.from(value, "base64").toString("binary"),
  setTimeout: callback => callback(),
  console,
};
vm.createContext(context);
vm.runInContext(scripts[1], context);

assert.strictEqual(elements.get("approvedHoursValue").textContent, "3 h", "The department report approved-hours KPI is wrong.");
assert.strictEqual(elements.get("pendingHoursValue").textContent, "0.5 h", "The department report pending-hours KPI is wrong.");
assert.strictEqual(elements.get("activeProjectsValue").textContent, "2", "The department report active-project KPI is wrong.");
assert.strictEqual(elements.get("topProjectValue").textContent, "P1 — Alpha", "The leading project insight is wrong.");
assert.strictEqual(elements.get("projectTableBody").children.length, 2, "The department project table must show every active project.");
assert.strictEqual(elements.get("projectTableBody").children[0].children[3].textContent, "66.7%", "The department project share must use total approved department hours.");
assert.strictEqual(elements.get("monthlyTrend").children.length, 2, "The department monthly trend is missing month rows.");
assert.strictEqual(elements.get("statusBreakdown").children.length, 3, "The department status breakdown is missing workflow statuses.");
assert.strictEqual(elements.get("sectorBreakdown").children.length, 2, "The department sector breakdown is missing sectors.");
elements.get("printButton").click();
assert(printCalled, "The department report print control is not connected.");
elements.get("csvButton").click();
const csvLink = createdElements.find(element => element.tagName === "A");
assert(csvLink && csvLink.download === "saphir-analytics-department-projects.csv", "The department CSV export must use an aggregated filename.");

console.log("Department analytics report runtime passed.");
