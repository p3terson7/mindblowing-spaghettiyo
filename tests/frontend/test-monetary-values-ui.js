const fs = require("fs");
const path = require("path");
const vm = require("vm");

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

const root = path.resolve(__dirname, "../..");
const utilities = fs.readFileSync(path.join(root, "app/frontend/scripts/Utilities.js"), "utf8");
const approvals = fs.readFileSync(path.join(root, "app/frontend/scripts/Views/ApprovalsView.js"), "utf8");
const projects = fs.readFileSync(path.join(root, "app/frontend/scripts/Views/ProjectsView.js"), "utf8");
const employees = fs.readFileSync(path.join(root, "app/frontend/scripts/Views/EmployeesView.js"), "utf8");
const i18n = fs.readFileSync(path.join(root, "app/frontend/scripts/I18n.js"), "utf8");
const styles = fs.readFileSync(path.join(root, "app/frontend/assets/apple-ui.css"), "utf8");

assert(utilities.includes("function formatCurrencyCents"), "Monetary values need one localized cents formatter.");
assert(approvals.includes("function renderEntryMonetaryPill"), "Review cards do not expose approved-entry estimates.");
assert(approvals.includes("entry.monetary"), "Review must consume the server projection instead of recalculating salaries.");
assert(!approvals.includes("annualSalaryCents") && !approvals.includes("hourlyRateCents"), "Review must not calculate from private salary details.");
assert(projects.includes("renderProjectMonetarySummaryPill"), "Project cards do not show the compact monetary summary.");
assert(projects.includes("monetaryTotalAmountCents"), "Project contributors cannot be compared by estimated value.");
assert(projects.includes("cashAmountCents") && projects.includes("compensatoryLeaveValueCents"), "Project details must distinguish cash from compensatory leave.");
assert(!projects.includes("annualSalaryCents") && !projects.includes("hourlyRateCents"), "Projects must not receive salary calculation inputs.");
assert(i18n.includes('"money.salaryOnlyEstimate"') && i18n.includes('"money.incompleteCoverage"'), "Monetary limits and incomplete coverage need localized copy.");
assert(styles.includes("grid-template-columns: repeat(auto-fit, minmax(150px, 1fr))"), "The extra project metric must remain responsive.");
assert(employees.includes("renderMonetarySummary(monetary"), "Personnel directory cards must show a visible monetary total.");
assert(employees.includes("summarizeEntryMonetaryValues(entries)"), "Personnel detail totals must consume scoped approved entries.");
assert(employees.includes("renderMonetaryEntryValue(entry)"), "Personnel entry rows must expose their amounts.");
assert(!employees.includes("annualSalaryCents") && !employees.includes("hourlyRateCents"), "Personnel must not recompute private payroll details in the browser.");
assert(projects.indexOf("project-insight-stat-money") < projects.indexOf("// Plain metrics"), "Project totals must render even if the chart library is missing.");

const context = {
  Intl, getCurrentLocale: () => "fr-CA", escapeHtml: value => String(value),
  t: (key, values) => values ? `${key}:${values.count}` : (key.startsWith("money.unavailableReason.") ? `translated:${key}` : key),
  isDiverseEntry: entry => entry.entryType === "diverse",
};
vm.createContext(context);
const start = utilities.indexOf("function formatCurrencyCents");
const end = utilities.indexOf("function getEntryDurationSeconds", start);
vm.runInContext(utilities.slice(start, end), context);
assert(context.formatCurrencyCents(null) === "", "An unavailable amount must not format as zero dollars.");
const final = { status: "final", totalAmountCents: 12345, cashAmountCents: 10000, compensatoryLeaveValueCents: 2345 };
const entries = [
  { status: "approved", monetary: final },
  { status: "pending", monetary: final },
  { status: "rejected", monetary: final },
  { status: "approved", entryType: "diverse", monetary: final },
  { status: "approved", monetary: { status: "unavailable", unavailableReason: "work-schedule-unconfirmed" } },
];
const total = context.summarizeEntryMonetaryValues(entries);
assert(total.totalAmountCents === 12345 && total.cashAmountCents === 10000 && total.compensatoryLeaveValueCents === 2345, "Personnel included pending, rejected or diverse values or mixed cash and leave.");
assert(total.approvedEntryCount === 2 && total.unavailableEntryCount === 1, "Missing coverage must be visible.");
assert(context.renderMonetarySummary(total, "scope").includes("money.partial"), "Partial totals must be explicitly labeled.");
assert(context.getMonetaryCoverageNote(total).includes("money.unavailableReason.work-schedule-unconfirmed"), "The reason a total is incomplete must be visible.");
const missing = context.summarizeEntryMonetaryValues([{ status: "approved" }]);
assert(context.getMonetaryAmountLabel(missing) === "money.toComplete", "All missing estimates must not display zero dollars.");
assert(context.getMonetaryAmountLabel(context.summarizeEntryMonetaryValues([])).includes("0,00"), "An empty approved period should show a real zero.");
const combined = context.summarizeMonetaryValues([total, total]);
assert(combined.totalAmountCents === 24690 && combined.unavailableReasons["work-schedule-unconfirmed"] === 2, "Portfolio monetary totals must retain amounts and missing coverage.");
assert(context.getMonetaryAmountLabel(context.getRecordMonetaryAggregate({ approvedCount: 3 })) === "money.toComplete", "An older backend response must not turn unpriced approvals into a zero-dollar total.");

console.log("Monetary values UI tests passed.");
