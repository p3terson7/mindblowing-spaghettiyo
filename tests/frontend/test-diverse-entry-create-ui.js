#!/usr/bin/env node

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const repoRoot = path.resolve(__dirname, "..", "..");
const read = relativePath => fs.readFileSync(path.join(repoRoot, relativePath), "utf8");
const indexSource = read("app/frontend/index.html");
const dashboardSource = read("app/frontend/scripts/Views/DashboardView.js");
const employeesSource = read("app/frontend/scripts/Views/EmployeesView.js");
const i18nSource = read("app/frontend/scripts/I18n.js");

assert.match(
  indexSource,
  /id="addEntryTypeField"[\s\S]*?name="addEntryType"[^>]*value="overtime"[\s\S]*?name="addEntryType"[^>]*value="diverse"/,
  "The create-entry modal must offer an accessible Overtime/Diverse category choice.",
);
assert.match(
  indexSource,
  /class="field-block add-diverse-field d-none"[\s\S]*?id="addDiverseReason"[^>]*maxlength="240"[\s\S]*?id="addDiverseSummary"[^>]*maxlength="1000"/,
  "Diverse creation must collect a bounded reason and work summary.",
);
assert.match(
  dashboardSource,
  /getDashboardEmployeeTimeEntryTypes\(employee\)[\s\S]*?\.includes\("diverse"\)[\s\S]*?isSuperAdminUser\(\)/,
  "The category choice must require both the employee privilege and existing super-admin authority.",
);
assert.match(
  dashboardSource,
  /diverseInput\.disabled = !diverseAllowed;[\s\S]*?typeField\.classList\.toggle\("d-none", !diverseAllowed\)|typeField\.classList\.toggle\("d-none", !diverseAllowed\)[\s\S]*?diverseInput\.disabled = !diverseAllowed;/,
  "The Diverse control must be hidden and disabled when the target employee is not entitled.",
);
assert.match(
  dashboardSource,
  /if \(entryType === "diverse"\)[\s\S]*?entryPayload\.diverseReason = diverseReason;[\s\S]*?entryPayload\.diverseSummary = diverseSummary;[\s\S]*?else \{[\s\S]*?entryPayload\.projectCode = projectCode;/,
  "The create request must send category-specific fields instead of project fields for Diverse time.",
);
assert.match(
  employeesSource,
  /openAddEntryModal\(employeeCode, addEntryButton, employee\)/,
  "Opening the modal from Personnel must pass the selected employee privileges to the shared workflow.",
);
assert(i18nSource.includes('"dashboard.diversePrivilegeRequired": "This employee does not have the Diverse time privilege."'), "English privilege feedback is missing.");
assert(i18nSource.includes('"dashboard.diversePrivilegeRequired": "Cet employé n’a pas le privilège de temps Divers."'), "French privilege feedback is missing.");

console.log("Diverse entry creation UI contracts passed.");
