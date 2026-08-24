const assert = require("assert");
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const repoRoot = path.resolve(__dirname, "..", "..");
const serviceSource = fs.readFileSync(
  path.join(repoRoot, "app/backend/services/AnalyticsReportService.ps1"),
  "utf8"
);
const templateMarker = "return @'\n<!doctype html>";
const templateStart = serviceSource.indexOf(templateMarker);
const templateEnd = serviceSource.indexOf("\n'@\n}", templateStart);
assert(templateStart >= 0 && templateEnd > templateStart, "Unable to extract the standalone analytics template.");
const template = serviceSource.slice(templateStart + "return @'\n".length, templateEnd);

const ui = {
  title: "Overtime analytics", subtitle: "Interactive overview", snapshot: "Generated", period: "Period",
  allData: "All", officialBasis: "Approved by default", search: "Search", searchPlaceholder: "Search",
  employee: "Employee", allEmployees: "All employees", project: "Project", allProjects: "All projects",
  sector: "Sector", allSectors: "All sectors", status: "Status", allStatuses: "All statuses",
  month: "Month", allMonths: "All months", payment: "Payment", allPayments: "All payments",
  reset: "Reset", print: "Print", exportCsv: "CSV", selectedHours: "Selected hours", entries: "Entries",
  activeEmployees: "Employees", activeProjects: "Projects", medianEmployee: "Median", trackedEmployees: "tracked",
  employeeUsage: "Hours by employee", employeeUsageHint: "All", projectUsage: "Hours by project",
  monthlyTrend: "Trend", employeeProject: "Matrix", workflow: "Workflow", paymentBreakdown: "Payment",
  detail: "Details", date: "Date", duration: "Duration", overtimeCode: "OT", reasonCode: "Reason",
  approved: "Approved", pending: "Pending", rejected: "Rejected", other: "Other", cash: "Cash", leave: "Leave",
  noData: "No data", archived: "archived", noSector: "No sector", qualityTitle: "Quality",
  qualitySummary: "Quality summary", qualityInvalidDate: "Invalid dates", qualityInvalidDuration: "Invalid durations",
  qualityIncompleteApproved: "Incomplete", qualityUnknownEntryType: "Unknown type", qualityUnknownStatus: "Unknown status",
  qualityMissingProject: "Missing project", qualityDiverse: "Diverse", showingRows: "{shown}/{total}",
  limitedMatrix: "Limited", hours: "h",
};
const model = {
  meta: {
    schemaVersion: 1,
    generatedAtUtc: "2026-08-06T12:00:00.000Z",
    locale: "en",
    period: { startDate: "2026-07-01", endDate: "2026-07-31" },
    defaultStatus: "approved",
    defaultProject: "P1",
  },
  ui,
  employees: [
    { reportEmployeeId: "e1", displayName: "Alice", archived: false },
    { reportEmployeeId: "e2", displayName: "Bob", archived: false },
    { reportEmployeeId: "e3", displayName: "Chloé", archived: false },
  ],
  projects: [
    { projectCode: "P1", displayName: "Alpha", sector: "Ops", colorKey: "blue", markerKey: "diamond", archived: false },
    { projectCode: "P2", displayName: "Beta", sector: "Tech", colorKey: "coral", markerKey: "triangle", archived: false },
  ],
  facts: [
    { employeeRef: "e1", projectCode: "P1", date: "2026-07-01", month: "2026-07", durationSeconds: 7200, status: "approved", payment: "cash", overtimeCode: "260", reasonCode: "D" },
    { employeeRef: "e1", projectCode: "P2", date: "2026-07-02", month: "2026-07", durationSeconds: 3600, status: "approved", payment: "leave", overtimeCode: "260", reasonCode: "D" },
    { employeeRef: "e2", projectCode: "P1", date: "2026-07-03", month: "2026-07", durationSeconds: 1800, status: "pending", payment: "cash", overtimeCode: "260", reasonCode: "E" },
    { employeeRef: "e2", projectCode: "P2", date: "2026-07-04", month: "2026-07", durationSeconds: 900, status: "rejected", payment: "cash", overtimeCode: "260", reasonCode: "E" },
  ],
  summary: { approvedSeconds: 10800, trackedEmployeeCount: 3 },
  quality: { invalidDateCount: 0, invalidDurationCount: 0, incompleteApprovedCount: 0, unknownEntryTypeCount: 0, unknownStatusCount: 0, missingProjectCount: 0, diverseEntryCount: 0 },
};

const encoded = Buffer.from(JSON.stringify(model), "utf8").toString("base64");
const html = template
  .replace("__LANG__", "en")
  .replace("__TITLE__", "Overtime analytics")
  .replace("__REPORT_DATA_BASE64__", encoded);
const scripts = [...html.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/g)].map(match => match[1]);
assert.strictEqual(scripts.length, 2, "The report must contain one data block and one executable script.");

class MockElement {
  constructor(tagName = "div", id = "") {
    this.tagName = tagName.toUpperCase();
    this.id = id;
    this.children = [];
    this.listeners = {};
    this.style = {};
    this.value = "";
    this.textContent = "";
    this.className = "";
    this.hidden = false;
    this.title = "";
    this.attributes = {};
  }
  set textContent(value) { this._textContent = String(value == null ? "" : value); }
  get textContent() { return this._textContent || ""; }
  appendChild(child) { this.children.push(child); return child; }
  append(...children) { this.children.push(...children); }
  replaceChildren(...children) { this.children = [...children]; this.textContent = ""; }
  setAttribute(name, value) { this.attributes[name] = String(value); }
  addEventListener(type, listener) { this.listeners[type] = listener; }
  click() { if (this.listeners.click) this.listeners.click({ currentTarget: this }); }
  dispatch(type) { if (this.listeners[type]) this.listeners[type]({ currentTarget: this, target: this }); }
}

const elementIds = [
  "reportData", "reportTitle", "reportSubtitle", "reportPeriod", "reportSnapshot", "searchLabel", "searchFilter",
  "employeeLabel", "employeeFilter", "projectLabel", "projectFilter", "sectorLabel", "sectorFilter", "statusLabel",
  "statusFilter", "monthLabel", "monthFilter", "paymentLabel", "paymentFilter", "resetButton", "printButton", "csvButton",
  "basisText", "hoursKpiLabel", "hoursKpi", "entriesKpiLabel", "entriesKpi", "employeesKpiLabel", "employeesKpi",
  "employeesKpiHint", "projectsKpiLabel", "projectsKpi", "medianKpiLabel", "medianKpi", "qualityPanel", "qualityTitle",
  "qualitySummary", "qualityList", "employeeUsageTitle", "employeeUsageHint", "employeeBars", "projectUsageTitle", "projectBars",
  "monthlyTrendTitle", "monthlyTrend", "workflowTitle", "statusBreakdown", "paymentBreakdownTitle", "paymentBreakdown",
  "matrixTitle", "matrixHint", "matrixContainer", "detailTitle", "detailHead", "detailBody", "detailNote",
];
const elements = new Map(elementIds.map(id => [id, new MockElement("div", id)]));
for (const id of ["employeeFilter", "projectFilter", "sectorFilter", "statusFilter", "monthFilter", "paymentFilter"]) {
  elements.get(id).tagName = "SELECT";
}
elements.get("searchFilter").tagName = "INPUT";
elements.get("reportData").textContent = encoded;

const context = {
  document: {
    getElementById: id => elements.get(id) || null,
    createElement: tag => new MockElement(tag),
    createTextNode: text => ({ textContent: String(text) }),
  },
  window: { print: () => {}, setTimeout: callback => callback() },
  URL: { createObjectURL: () => "blob:test", revokeObjectURL: () => {} },
  Blob,
  TextDecoder,
  Uint8Array,
  Intl,
  Map,
  Set,
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

assert.strictEqual(elements.get("statusFilter").value, "approved", "Approved must be the report's default status.");
assert.strictEqual(elements.get("projectFilter").value, "P1", "The requested project must be selected when the report opens.");
assert.strictEqual(elements.get("hoursKpi").textContent, "2 h", "Initial KPI must count only approved overtime for the requested project.");
assert.strictEqual(elements.get("entriesKpi").textContent, "1", "Initial project entry count is wrong.");
assert.strictEqual(elements.get("employeesKpi").textContent, "1", "Initial active employee count is wrong.");
assert.strictEqual(elements.get("employeeBars").children.length, 3, "The employee chart must retain zero-hour roster members.");
const initialEmployeeSegment = elements.get("employeeBars").children[0].children[1].children[0];
assert(initialEmployeeSegment.className.includes("marker-diamond"), "Employee chart segments must retain the project's marker pattern.");
assert(initialEmployeeSegment.attributes["aria-label"].includes("Alpha"), "Employee chart segments need an accessible exact-value label.");
assert.strictEqual(initialEmployeeSegment.attributes.role, "img", "Employee chart segments need a semantic image role for their accessible label.");
assert.strictEqual(initialEmployeeSegment.tabIndex, 0, "Employee chart segments must expose exact values to keyboard users.");

elements.get("statusFilter").value = "";
elements.get("statusFilter").dispatch("change");
assert.strictEqual(elements.get("hoursKpi").textContent, "2.5 h", "All-status project filtering did not recompute hours.");
assert.strictEqual(elements.get("entriesKpi").textContent, "2", "All-status project filtering did not recompute entries.");

elements.get("projectFilter").value = "";
elements.get("searchFilter").value = "Beta";
elements.get("statusFilter").value = "approved";
elements.get("searchFilter").dispatch("input");
assert.strictEqual(elements.get("hoursKpi").textContent, "1 h", "Project search did not filter the report facts.");
assert.strictEqual(elements.get("employeeBars").children.length, 1, "Project search should retain the matching employee bar.");

elements.get("searchFilter").value = "";
elements.get("sectorFilter").value = "Ops";
elements.get("sectorFilter").dispatch("change");
assert.strictEqual(elements.get("hoursKpi").textContent, "2 h", "Sector filtering did not recompute the report.");
assert.strictEqual(elements.get("projectBars").children.length, 1, "Sector filtering should hide unrelated project bars.");

elements.get("resetButton").click();
assert.strictEqual(elements.get("statusFilter").value, "approved", "Reset must restore the approved default.");
assert.strictEqual(elements.get("projectFilter").value, "P1", "Reset must restore the report's requested project.");
assert.strictEqual(elements.get("hoursKpi").textContent, "2 h", "Reset did not restore the initial project report totals.");

console.log("Standalone analytics report runtime filters passed.");
