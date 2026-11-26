#!/usr/bin/env node

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const repoRoot = path.resolve(__dirname, "..", "..");
const read = relativePath => fs.readFileSync(path.join(repoRoot, relativePath), "utf8");
const indexSource = read("app/frontend/index.html");
const appShellSource = read("app/frontend/scripts/AppShell.js");
const i18nSource = read("app/frontend/scripts/I18n.js");

assert(!i18nSource.includes("Group uses letters; sub-group and level use two digits."), "Settings still shows classification-format filler text in English.");
assert(!i18nSource.includes("Le groupe contient des lettres; le sous-groupe et le niveau contiennent deux chiffres."), "Settings still shows classification-format filler text in French.");
const stylesSource = read("app/frontend/assets/styles.css");

assert.match(indexSource, /id="compensationGridSettingsSection"[^>]+data-role-scope="superAdmin"/, "The compensation grid must be limited to super admins in the Settings modal.");
for (const id of [
  "compensationGridSettingsRows",
  "compensationGridAddButton",
  "compensationGridSaveButton",
]) {
  assert(indexSource.includes(`id="${id}"`), `Missing compensation grid control: ${id}`);
}
assert(appShellSource.includes('type="date" class="form-control form-control-sm compensation-grid-date-input compensation-grid-effective-from-input"'), "Each band needs an effective-from date.");
assert(appShellSource.includes('type="date" class="form-control form-control-sm compensation-grid-date-input compensation-grid-effective-to-input"'), "Each band needs an optional effective-to date.");
assert(stylesSource.includes(".compensation-grid-table-wrap"), "The editable compensation table needs its responsive wrapper.");

for (const key of [
  "settings.compensationGrid",
  "settings.compensationGridHint",
  "settings.compensationGroup",
  "settings.compensationSubGroup",
  "settings.compensationLevel",
  "settings.compensationAnnualSalary",
  "settings.compensationEffectiveFrom",
  "settings.compensationEffectiveTo",
  "settings.compensationAddBand",
  "settings.compensationSave",
  "settings.compensationRequiredFields",
  "settings.compensationInvalidClassification",
  "settings.compensationInvalidSalary",
  "settings.compensationInvalidDate",
  "settings.compensationInvalidDateRange",
  "settings.compensationDuplicateBand",
  "settings.compensationOverlappingBand",
]) {
  assert.equal(i18nSource.split(`"${key}"`).length - 1, 2, `Missing bilingual compensation text: ${key}`);
}

const helperStart = appShellSource.indexOf("function normalizeCompensationGridCode");
const helperEnd = appShellSource.indexOf("function addCompensationGridBand", helperStart);
assert(helperStart >= 0 && helperEnd > helperStart, "Unable to locate compensation-grid form helpers.");

const context = {
  Date,
  Math,
  Number,
  Intl,
  RegExp,
  Set,
  String,
  t: key => key,
};
vm.createContext(context);
vm.runInContext(`${appShellSource.slice(helperStart, helperEnd)}
this.compensationGridApi = {
  normalizeCompensationGridCode,
  normalizeCompensationGroupCode,
  normalizeCompensationTwoDigitCode,
  normalizeCompensationGridDate,
  parseCompensationAnnualSalaryCents,
  formatCompensationAnnualSalaryCents,
  getCompensationGridValidationError,
};`, context);

const api = context.compensationGridApi;
assert.equal(api.normalizeCompensationGridCode("", 32), "", "A blank compensation dimension must stay blank instead of inheriting a GC179 default.");
assert.equal(api.normalizeCompensationGridCode(" as - 03 ", 32), "AS-03", "Compensation dimensions should be normalized without a hard-coded classification list.");
assert.equal(api.normalizeCompensationGridCode("AS*", 32), "", "Unsupported classification characters must be rejected before saving.");
assert.equal(api.normalizeCompensationGroupCode(" as-03 "), "AS-03", "Group normalization must not silently erase invalid characters.");
assert.equal(api.normalizeCompensationTwoDigitCode("4"), "04", "A one-digit classification value must receive a leading zero.");
assert.equal(api.normalizeCompensationTwoDigitCode("level 02"), "level 02", "Numeric normalization must not silently erase invalid characters.");
assert.equal(api.normalizeCompensationGridDate("2026-02-29"), "", "Invalid calendar dates must be rejected.");
assert.equal(api.normalizeCompensationGridDate("2028-02-29"), "2028-02-29", "Leap-day effective dates must remain valid.");
assert.equal(api.parseCompensationAnnualSalaryCents("57 271"), 5727100, "French-style salary spacing must convert to integer cents.");
assert.equal(api.parseCompensationAnnualSalaryCents("$73,798.50"), 7379850, "English-style salary formatting must convert to integer cents.");
assert.equal(api.parseCompensationAnnualSalaryCents("0"), null, "A zero annual salary must be rejected.");
assert.equal(api.parseCompensationAnnualSalaryCents("not a salary"), null, "Non-numeric annual salaries must be rejected.");
assert.match(api.formatCompensationAnnualSalaryCents(8061200), /80[\s,\u00a0\u202f]?612[,.]00/, "Saved salary cents must be rendered without precision loss.");

const validBand = {
  id: "AS-03-1-2026",
  group: "AS",
  subGroup: "03",
  level: "01",
  annualSalaryCents: 7379800,
  effectiveFrom: "2026-01-01",
  effectiveTo: "",
};
assert.equal(api.getCompensationGridValidationError([validBand]), "", "A complete compensation band should be ready to save.");
assert.equal(api.getCompensationGridValidationError([{ ...validBand, group: "" }]), "settings.compensationRequiredFields", "A missing group must not be silently filled in.");
assert.equal(api.getCompensationGridValidationError([{ ...validBand, group: "AS3" }]), "settings.compensationInvalidClassification", "A Group containing digits must be rejected.");
assert.equal(api.getCompensationGridValidationError([{ ...validBand, level: "1" }]), "settings.compensationInvalidClassification", "A one-digit unnormalized Level must be rejected.");
assert.equal(api.getCompensationGridValidationError([{ ...validBand, effectiveTo: "2025-12-31" }]), "settings.compensationInvalidDateRange", "An end date cannot precede the effective date.");
assert.equal(api.getCompensationGridValidationError([validBand, { ...validBand, id: "duplicate" }]), "settings.compensationDuplicateBand", "Duplicate classification dates must be caught before saving.");
assert.equal(api.getCompensationGridValidationError([validBand, { ...validBand, id: "later", effectiveFrom: "2026-06-01" }]), "settings.compensationOverlappingBand", "Overlapping classification dates must be caught before saving.");

assert.match(appShellSource, /const COMPENSATION_GRID_ENDPOINT = "compensation-grid";/, "The compensation endpoint is missing.");
assert.match(appShellSource, /async function openSelfSettingsForm[\s\S]*?isSuperAdminUser\(user\) \? loadCompensationGrid\(\)/, "The grid must load only when a super admin opens Settings.");
assert.match(appShellSource, /method: "PUT"[\s\S]*?body: JSON\.stringify\(\{ bands \}\)/, "The grid save must submit all bands atomically.");
assert(appShellSource.includes('key: "compensation-grid-save"'), "The grid save must use the shared busy-button state.");
assert(appShellSource.includes('maxlength="2" pattern="[0-9]{2}" inputmode="numeric"'), "Sub-group and Level inputs must expose their two-digit constraint.");

console.log("Compensation grid Settings UI contract test passed.");
