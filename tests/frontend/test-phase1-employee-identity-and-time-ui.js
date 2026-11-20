#!/usr/bin/env node

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const repoRoot = path.resolve(__dirname, "..", "..");
const read = relativePath => fs.readFileSync(path.join(repoRoot, relativePath), "utf8");
const utilitiesSource = read("app/frontend/scripts/Utilities.js");
const employeesSource = read("app/frontend/scripts/Views/EmployeesView.js");
const baseCssSource = read("app/frontend/assets/styles.css");
const themeCssSource = read("app/frontend/assets/apple-ui.css");

const identityStart = utilitiesSource.indexOf("function getExplicitHistoryAuthorName");
const identityEnd = utilitiesSource.indexOf("function getHistorySearchText", identityStart);
assert(identityStart >= 0 && identityEnd > identityStart, "Unable to locate the history employee identity helpers.");

const context = {
  String,
  escapeHtml: value => String(value),
  t(key, values = {}) {
    if (key === "history.concernedEmployee") return `Employé concerné : ${values.name}`;
    if (key === "history.concernedEmployeeCode") return `SIGRH ${values.code}`;
    return key;
  },
};
vm.createContext(context);
vm.runInContext(`${utilitiesSource.slice(identityStart, identityEnd)}\nthis.renderHistorySubjectLine = renderHistorySubjectLine;`, context);

const enrichedMarkup = context.renderHistorySubjectLine({
  action: "Update",
  message: "Updated an entry on September 2, 2026.",
  employee: "000123456",
  targetEmployeeName: "Sophie Tremblay",
  targetEmployeeCode: "000123456",
});
assert(enrichedMarkup.includes("Employé concerné : Sophie Tremblay"), "The employee name is not the primary history subject.");
assert(enrichedMarkup.includes("SIGRH 000123456"), "The HRMIS identifier is not retained as secondary history information.");

const legacyMarkup = context.renderHistorySubjectLine({
  action: "Update",
  message: "Updated an entry on September 2, 2026.",
  employee: "000123456",
});
assert(legacyMarkup.includes("Employé concerné : 000123456"), "Unmapped legacy history entries must keep a safe HRMIS fallback.");
assert(!legacyMarkup.includes("timeline-card-subject-code"), "The fallback must not repeat the HRMIS value twice.");

assert.match(baseCssSource, /\.time-value,[\s\S]*?\.duration-value,[\s\S]*?font-variant-numeric:\s*tabular-nums;/, "Base styling does not share one numeric treatment for times and durations.");
assert.match(themeCssSource, /\.time-value,[\s\S]*?\.duration-value,[\s\S]*?font-family:\s*inherit;[\s\S]*?font-variant-numeric:\s*tabular-nums;/, "Theme styling does not normalize time and duration typography.");
assert(employeesSource.includes('t("employees.statsRejectedTime")'), "Personnel does not expose rejected time.");
assert(employeesSource.includes("model.totals.rejectedSeconds"), "Personnel rejected time is not based on rejected durations.");
assert(employeesSource.includes("employee-rejected-time-action"), "Rejected time does not provide direct access to a rejected entry.");
assert.match(employeesSource, /employee-rejected-time-action[\s\S]*?currentMonthByEmployee[\s\S]*?focusEmployeeEntry/, "Rejected time does not open and focus the employee's latest rejected entry.");

console.log("Phase 1 employee identity and time UI tests passed.");
