#!/usr/bin/env node

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const repoRoot = path.resolve(__dirname, "..", "..");
const read = relativePath => fs.readFileSync(path.join(repoRoot, relativePath), "utf8");
const indexSource = read("app/frontend/index.html");
const dashboardSource = read("app/frontend/scripts/Views/DashboardView.js");
const utilitiesSource = read("app/frontend/scripts/Utilities.js");
const i18nSource = read("app/frontend/scripts/I18n.js");

assert.match(
  indexSource,
  /id="updateEntryForm"[\s\S]*?id="originalDate"[\s\S]*?<label for="updateDate"[^>]*data-i18n="modal\.date"[\s\S]*?<input type="date"[^>]*id="updateDate"[^>]*required/,
  "The entry editor must expose a required date input while retaining the original lookup date.",
);
assert.match(
  dashboardSource,
  /getElementById\("originalDate"\)\.value = date;[\s\S]*?getElementById\("updateDate"\)\.value = date;/,
  "Opening the editor must initialize both the immutable lookup date and editable date.",
);
assert.match(
  dashboardSource,
  /const originalDate = document\.getElementById\("originalDate"\)\.value;[\s\S]*?const newDate = updateDateInput\.value;/,
  "The editor must keep the original and replacement dates separate.",
);
assert.match(
  dashboardSource,
  /if \(!updateDateInput\.checkValidity\(\)\)[\s\S]*?updateDateInput\.reportValidity\(\);/,
  "The replacement date must pass native date validation before submission.",
);
assert.match(
  dashboardSource,
  /newDate === originalDate[\s\S]*?dashboard\.noChanges/,
  "A date-only edit must not be rejected as an unchanged entry.",
);
assert.equal(
  (dashboardSource.match(/date: originalDate, newDate, originalPunchIn/g) || []).length,
  2,
  "Both overtime and Diverse updates must send the old lookup date plus additive newDate.",
);
assert.match(
  dashboardSource,
  /new Date\(`\$\{newDate\}T\$\{punchOutBackend\}`\)[\s\S]*?new Date\(`\$\{newDate\}T\$\{newPunchInBackend\}`\)/,
  "Time-order validation must use the replacement calendar day.",
);

assert.match(utilitiesSource, /Date from <strong>\(\\d\{4\}-\\d\{2\}-\\d\{2\}\)<\\\/strong>/, "The audit translator must recognize date-change fragments.");
assert.match(utilitiesSource, /history\.fragment\.dateFromTo/, "Date-change history must use localized copy.");
assert(i18nSource.includes('"history.fragment.dateFromTo": "Date from'), "English date-change audit copy is missing.");
assert(i18nSource.includes('"history.fragment.dateFromTo": "Date du'), "French date-change audit copy is missing.");

const parseDateStart = utilitiesSource.indexOf("function parseLocalDate");
const parseDateEnd = utilitiesSource.indexOf("function normalizeDateInputValue", parseDateStart);
const auditStart = utilitiesSource.indexOf("function localizeAuditHumanDate");
const auditEnd = utilitiesSource.indexOf("function translateAuditMessage", auditStart);
assert(parseDateStart >= 0 && parseDateEnd > parseDateStart && auditStart >= 0 && auditEnd > auditStart, "Unable to isolate the audit date helpers.");
const auditContext = {
  Date,
  Number,
  String,
  getCurrentLocale: () => "en-CA",
  t(key, values = {}) {
    return key === "history.fragment.dateFromTo" ? `${values.from} -> ${values.to}` : key;
  },
};
vm.createContext(auditContext);
vm.runInContext(`${utilitiesSource.slice(parseDateStart, parseDateEnd)}\n${utilitiesSource.slice(auditStart, auditEnd)}\nthis.buildDateFragment = buildTranslatedAuditUpdateFragments;`, auditContext);
assert.equal(
  auditContext.buildDateFragment("Date from <strong>2026-08-01</strong> to <strong>2026-08-04</strong>."),
  "August 1, 2026 -> August 4, 2026",
  "ISO entry dates must be localized as local calendar days without a UTC offset shift.",
);

console.log("Entry date-edit frontend contract tests passed.");
