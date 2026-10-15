#!/usr/bin/env node

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const repoRoot = path.resolve(__dirname, "..", "..");
const read = relativePath => fs.readFileSync(path.join(repoRoot, relativePath), "utf8");

const selfSource = read("app/frontend/scripts/Views/SelfView.js");
const employeesSource = read("app/frontend/scripts/Views/EmployeesView.js");
const utilitiesSource = read("app/frontend/scripts/Utilities.js");
const i18nSource = read("app/frontend/scripts/I18n.js");
const selfRoutesSource = read("app/backend/routes/self.routes.ps1");
const employeeRoutesSource = read("app/backend/routes/employee/get.routes.ps1");
const routingModuleSource = read("app/backend/modules/Saphir.Routing.psm1");
const guideSource = read("scripts/create-french-demo-guide-pdf.py");
const readmeSource = read("README.md");

for (const [name, source] of Object.entries({ selfSource, employeesSource, utilitiesSource, i18nSource })) {
  for (const retiredContract of [
    "self-export-month-button",
    "people-export-month-button",
    "openMonthlyEntriesExportHtml",
    "buildMonthlyEntriesExportHtml",
    "export.openMonthlyHtml",
    "export.monthlyTitle",
    "export.popupBlocked",
  ]) {
    assert(!source.includes(retiredContract), `${name} still contains retired monthly HTML export code: ${retiredContract}`);
  }
}

for (const retiredTranslationKey of [
  "export.employee",
  "export.month",
  "export.generated",
  "export.noEntries",
  "export.startTime",
  "export.endTime",
  "export.total",
]) {
  assert(!i18nSource.includes(`"${retiredTranslationKey}"`), `Retired translation remains: ${retiredTranslationKey}`);
}

assert(!guideSource.includes("Extraire le mois"), "The demo guide still asks testers to use the retired monthly HTML export.");
assert(!guideSource.includes("Extraction mensuelle"), "The demo guide still names the retired monthly HTML export.");
assert(guideSource.includes("Export GC179 automatisé"), "The demo guide does not cover the replacement GC179 workflow.");
assert(!readmeSource.includes("Rapports mensuels HTML"), "The README still documents the retired monthly HTML export.");
assert(!readmeSource.includes("rapport mensuel est en HTML"), "The README still lists the retired HTML export as a limitation.");

assert(selfSource.includes("self-gc179-fdf-button"), "The employee GC179 button was removed with the HTML export.");
assert(selfSource.includes("key: `self-gc179-export:${monthKey}`"), "The employee GC179 action lost its busy-state contract.");
assert(employeesSource.includes("people-gc179-fdf-button"), "The manager GC179 button was removed with the HTML export.");
assert(employeesSource.includes("key: `people-gc179-export:${employeeCode}:${monthKey}`"), "The manager GC179 action lost its busy-state contract.");
assert(utilitiesSource.includes("async function downloadGc179FdfExport"), "The shared GC179 launcher was removed.");
assert(utilitiesSource.includes("self/gc179-open?month="), "The employee GC179 endpoint call was removed.");
assert(utilitiesSource.includes("employee/${encodeURIComponent(employeeCode)}/gc179-open?month="), "The manager GC179 endpoint call was removed.");
assert(selfRoutesSource.includes('"/self/gc179-open"'), "The employee GC179 backend route was removed.");
assert(employeeRoutesSource.includes("gc179-open"), "The manager GC179 backend route was removed.");
assert(routingModuleSource.includes("gc179-open"), "GC179 route dispatch was removed.");

console.log("Retired monthly HTML export and preserved GC179 contract test passed.");
