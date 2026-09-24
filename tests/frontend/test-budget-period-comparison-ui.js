const assert = require("assert");
const fs = require("fs");
const path = require("path");

const repoRoot = path.resolve(__dirname, "../..");
const indexSource = fs.readFileSync(path.join(repoRoot, "app/frontend/index.html"), "utf8");
const appShellSource = fs.readFileSync(path.join(repoRoot, "app/frontend/scripts/AppShell.js"), "utf8");
const projectsSource = fs.readFileSync(path.join(repoRoot, "app/frontend/scripts/Views/ProjectsView.js"), "utf8");
const i18nSource = fs.readFileSync(path.join(repoRoot, "app/frontend/scripts/I18n.js"), "utf8");
const stylesSource = fs.readFileSync(path.join(repoRoot, "app/frontend/assets/styles.css"), "utf8");

for (const id of [
  "budgetPeriodSettingsSection",
  "budgetPeriodCycleLabelInput",
  "budgetPeriodSettingsRows",
  "budgetPeriodSaveButton",
  "projectBudgetComparisonPanel",
  "projectBudgetComparisonControls",
  "projectBudgetComparisonSummary",
  "projectBudgetComparisonTable",
]) {
  assert(indexSource.includes(`id="${id}"`), `Missing Phase 5 UI element ${id}.`);
}

assert.match(indexSource, /id="budgetPeriodSettingsSection"[^>]+data-role-scope="superAdmin"/, "Only super admins should edit budget dates.");
assert(appShellSource.includes('const BUDGET_PERIOD_IDS = Object.freeze(["P1", "P2", "P3", "P4"])'), "Settings must keep the four stable budget-period IDs.");
assert(appShellSource.includes('fetch(apiUrl + BUDGET_PERIOD_ENDPOINT, { cache: "no-store" })'), "Settings must read budget dates from the backend.");
assert(appShellSource.includes('method: "PUT"'), "Settings must persist budget-date changes.");
assert(appShellSource.includes('key: "budget-period-save"'), "Budget saving must use the shared busy-button guard.");

assert(projectsSource.includes('fetch(`${apiUrl}stats/budget-periods`, { cache: "no-store" })'), "Projects must load the consolidated budget comparison endpoint.");
assert(projectsSource.includes("getBudgetComparisonProjectRows"), "The comparison must build precise project rows.");
assert(projectsSource.includes("departmentShare.percent"), "Each comparison value must include the project share for that period.");
assert(projectsSource.includes("formatBudgetComparisonDelta"), "The comparison must calculate a first-to-last change.");
assert(projectsSource.includes("rows.slice(0, 10)"), "Large portfolios must start with a compact top-10 comparison.");
assert(projectsSource.includes("data-budget-comparison-toggle"), "Users must be able to expand the complete project comparison.");
assert(projectsSource.includes('document.getElementById("projectBudgetComparisonControls").addEventListener("change"'), "Period selection must update interactively without navigation.");

for (const cssClass of [
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
  "projects.budgetShareValue",
  "projects.budgetPeriodsEmpty",
]) {
  assert.equal((i18nSource.match(new RegExp(`"${key.replaceAll(".", "\\.")}"`, "g")) || []).length, 2, `${key} must be translated in English and French.`);
}

console.log("Budget-period comparison UI tests passed.");
