const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const root = path.resolve(__dirname, "../..");
const read = name => fs.readFileSync(path.join(root, name), "utf8");
const shell = read("app/frontend/scripts/AppShell.js");
const html = read("app/frontend/index.html");
const i18n = read("app/frontend/scripts/I18n.js");
for (const [list, values] of [
  ["gc179GroupSuggestions", ["IT"]],
  ["gc179SubGroupSuggestions", ["01", "02", "03"]],
  ["gc179LevelSuggestions", ["01", "02", "03", "04", "05", "06", "07", "08"]],
]) {
  const content = html.match(new RegExp(`<datalist id="${list}">([\\s\\S]*?)</datalist>`))[1];
  for (const value of values) assert(content.includes(`value="${value}"`));
}
for (const key of ["settings.compensationAddIT02", "settings.compensationIT02Added", "settings.compensationIT02Exists", "shared.itHolidaySchedule", "money.unavailableReason.it-holiday-schedule-unconfirmed"]) {
  assert.equal(i18n.split(`"${key}"`).length - 1, 2, `Missing bilingual key ${key}`);
}
assert(html.includes('id="compensationGridAddIT02Button"'));
const context = { Date, Intl, Number, String, Math, Set, Map, RegExp, t: key => key, window: { crypto: { randomUUID: () => "new-preset-id" } } };
vm.createContext(context);
vm.runInContext(shell.slice(shell.indexOf("function normalizeCompensationGridCode"), shell.indexOf("function addCompensationGridBand")), context);
const defaults = JSON.parse(read("app/backend/defaults/compensation-grid.v1.json"));
const before = JSON.stringify(defaults);
const original = defaults.bands.filter(band => band.group !== "IT");
const additions = context.getCompensationIT02Additions(original, defaults.bands);
assert.equal(additions.length, 8);
assert.deepEqual(Array.from(additions, band => band.annualSalaryCents), [8585400, 8860300, 9134800, 9409500, 9684400, 9958900, 10233500, 10508000]);
assert.equal(context.getCompensationGridValidationError([...original, ...additions]), "");
const customized = { ...additions[0], annualSalaryCents: 9990000 };
const preserved = context.getCompensationIT02Additions([...original, customized], defaults.bands);
assert.equal(preserved.length, 7, "Do not replace a custom IT step.");
assert(!preserved.some(band => band.level === "01"));
assert.equal(context.getCompensationIT02Additions([...original, ...additions], defaults.bands).length, 0, "Repeated clicks must not duplicate salary rows.");
assert.equal(JSON.stringify(defaults), before, "Preset selection mutated its source.");
const applySource = shell.slice(shell.indexOf("function addCompensationIT02Bands"), shell.indexOf("function addCompensationGridBand"));
assert(applySource.includes("isSuperAdminUser()"));
assert(!applySource.includes("fetch("), "Adding the preset must wait for explicit Save before writing.");
const dashboard = read("app/frontend/scripts/Views/DashboardView.js");
for (const source of [dashboard, read("app/frontend/scripts/Views/EmployeesView.js"), read("app/frontend/scripts/Views/ApprovalsView.js")]) {
  assert(source.includes('data-holidaynotscheduled='), "Entry navigation must retain true/false holiday context.");
}
assert(dashboard.includes('value === "263"'));
assert(dashboard.includes('...(holidayValue !== originalHolidayValue ? { holidayNotScheduledWorkday } : {})'), "Unrelated edits must not add null holiday fields or audit noise.");
assert(dashboard.includes('holidayValue === originalHolidayValue'), "Changing only the holiday answer must not be treated as a no-op.");
console.log("IT classification UI passed: eight salary steps, preservation, idempotent explicit save, role guard, translations and holiday edit wiring.");
