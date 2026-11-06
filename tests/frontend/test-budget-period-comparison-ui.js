const assert = require("assert");
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const repoRoot = path.resolve(__dirname, "../..");
const indexSource = fs.readFileSync(path.join(repoRoot, "app/frontend/index.html"), "utf8");
const appShellSource = fs.readFileSync(path.join(repoRoot, "app/frontend/scripts/AppShell.js"), "utf8");
const projectsSource = fs.readFileSync(path.join(repoRoot, "app/frontend/scripts/Views/ProjectsView.js"), "utf8");
const i18nSource = fs.readFileSync(path.join(repoRoot, "app/frontend/scripts/I18n.js"), "utf8");
const stylesSource = fs.readFileSync(path.join(repoRoot, "app/frontend/assets/styles.css"), "utf8");

for (const id of [
  "budgetPeriodSettingsSection",
  "budgetPeriodCycleLabelInput",
  "budgetPeriodGeneratorStartMonth",
  "budgetPeriodGeneratorDay",
  "budgetPeriodGeneratorCount",
  "budgetPeriodGenerateButton",
  "budgetPeriodSettingsRows",
  "budgetPeriodAddButton",
  "budgetPeriodSaveButton",
  "projectBudgetComparisonPanel",
  "projectBudgetComparisonControls",
  "projectBudgetComparisonSummary",
  "projectBudgetComparisonTable",
]) {
  assert(indexSource.includes(`id="${id}"`), `Missing Phase 5 UI element ${id}.`);
}

assert.match(indexSource, /id="budgetPeriodSettingsSection"[^>]+data-role-scope="superAdmin"/, "Only super admins should edit budget dates.");
assert.match(indexSource, /<details class="project-budget-comparison-disclosure">/, "The Projects budget-period comparison must be collapsible.");
assert(!indexSource.includes('<details class="project-budget-comparison-disclosure" open>'), "The large budget-period comparison must start collapsed.");
assert(appShellSource.includes("const DEFAULT_BUDGET_PERIOD_COUNT = 12"), "New configurations must start with twelve budget periods.");
assert(appShellSource.includes("function addBudgetPeriod()"), "Settings must allow periods to be added.");
assert(appShellSource.includes("function removeBudgetPeriod(id)"), "Settings must allow periods to be removed.");
assert(appShellSource.includes("function generateMonthlyBudgetPeriods()"), "Settings must provide a monthly period generator.");
assert(appShellSource.includes("getMonthlyBudgetBoundary"), "The monthly generator must handle calendar boundaries.");
assert(appShellSource.includes('fetch(apiUrl + BUDGET_PERIOD_ENDPOINT, { cache: "no-store" })'), "Settings must read budget dates from the backend.");
assert(appShellSource.includes('method: "PUT"'), "Settings must persist budget-date changes.");
assert(appShellSource.includes('key: "budget-period-save"'), "Budget saving must use the shared busy-button guard.");

assert(projectsSource.includes('fetch(`${apiUrl}stats/budget-periods`, { cache: "no-store" })'), "Projects must load the consolidated budget comparison endpoint.");
assert(!projectsSource.includes("PROJECT_BUDGET_PERIOD_IDS"), "Projects must render the configured dynamic period list.");
assert(projectsSource.includes("getBudgetComparisonProjectRows"), "The comparison must build precise project rows.");
assert(projectsSource.includes("getDefaultProjectBudgetPeriodIds"), "The comparison must choose a compact default period pair.");
assert(projectsSource.includes("departmentShare.percent"), "Each comparison value must include the project share for that period.");
assert(projectsSource.includes("formatBudgetComparisonDelta"), "The comparison must calculate a first-to-last change.");
assert(projectsSource.includes("rows.slice(0, 10)"), "Large portfolios must start with a compact top-10 comparison.");
assert(projectsSource.includes("data-budget-comparison-toggle"), "Users must be able to expand the complete project comparison.");
assert(projectsSource.includes('document.getElementById("projectBudgetComparisonControls").addEventListener("change"'), "Period selection must update interactively without navigation.");

const monthlyHelperStart = appShellSource.indexOf("function formatBudgetPeriodDate");
const monthlyHelperEnd = appShellSource.indexOf("function generateMonthlyBudgetPeriods");
assert(monthlyHelperStart >= 0 && monthlyHelperEnd > monthlyHelperStart, "Monthly period helpers are missing.");
const monthlyContext = {};
vm.createContext(monthlyContext);
vm.runInContext(`${appShellSource.slice(monthlyHelperStart, monthlyHelperEnd)}; this.createMonthlyBudgetPeriods = createMonthlyBudgetPeriods;`, monthlyContext);
const generated = monthlyContext.createMonthlyBudgetPeriods(2027, 0, 31, 3);
assert.deepEqual(JSON.parse(JSON.stringify(generated)), [
  { id: "P1", startDate: "2027-01-31", endDate: "2027-02-27" },
  { id: "P2", startDate: "2027-02-28", endDate: "2027-03-30" },
  { id: "P3", startDate: "2027-03-31", endDate: "2027-04-29" },
], "Monthly generation must stay consecutive and clamp missing calendar days.");

for (const cssClass of [
  ".project-budget-comparison-disclosure",
  ".project-budget-comparison-content",
  ".budget-period-selector",
  ".budget-comparison-summary",
  ".budget-comparison-table-wrap",
  ".budget-comparison-delta",
]) {
  assert(stylesSource.includes(cssClass), `Missing comparison styling ${cssClass}.`);
}

for (const key of [
  "settings.budgetPeriods",
  "settings.budgetBothDatesRequired",
  "projects.budgetComparisonTitle",
  "projects.budgetExpand",
  "projects.budgetCollapse",
  "projects.budgetShareValue",
  "projects.budgetPeriodsEmpty",
]) {
  assert.equal((i18nSource.match(new RegExp(`"${key.replaceAll(".", "\\.")}"`, "g")) || []).length, 2, `${key} must be translated in English and French.`);
}

console.log("Budget-period comparison UI tests passed.");
