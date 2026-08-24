#!/usr/bin/env node

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const repoRoot = path.resolve(__dirname, "..", "..");
const read = relativePath => fs.readFileSync(path.join(repoRoot, relativePath), "utf8");
const employeesSource = read("app/frontend/scripts/Views/EmployeesView.js");
const baseCssSource = read("app/frontend/assets/styles.css");
const themeCssSource = read("app/frontend/assets/apple-ui.css");

const cardStart = employeesSource.indexOf("function renderEmployeeDirectoryCard");
const cardEnd = employeesSource.indexOf("function renderEmployeeDirectorySection", cardStart);
assert(cardStart >= 0 && cardEnd > cardStart, "Unable to locate employee directory-card rendering.");
const cardSource = employeesSource.slice(cardStart, cardEnd);

assert(cardSource.includes("employee-card-title-button employee-open-button"), "The employee name must be the explicit keyboard-accessible file action.");
assert(cardSource.includes('aria-controls="employeeDetailContainer"'), "The employee title action must identify the detail region it opens.");
assert(!cardSource.includes("employee-card-actions"), "Employee cards must not reserve a redundant action row.");
assert(!cardSource.includes('t("action.openEmployee")'), "Employee cards must not repeat a Fiche employé button.");
assert(!cardSource.includes("employee-edit-button"), "Employee cards must not include a Modifier button.");
assert(employeesSource.includes("const EMPLOYEE_CARD_PROJECT_TOKEN_LIMIT = 4;"), "Employee cards need a fixed two-row project-token budget.");

const projectTokensStart = employeesSource.indexOf("const EMPLOYEE_CARD_PROJECT_TOKEN_LIMIT");
const projectTokensEnd = employeesSource.indexOf("function renderEmployeeResponsibilitySummary", projectTokensStart);
assert(projectTokensStart >= 0 && projectTokensEnd > projectTokensStart, "Unable to locate employee project-token rendering.");
const projectTokenContext = {
  escapeHtml: value => String(value),
  getEmployeeBackupProjects: employee => employee.backupProjects || [],
  getEmployeeSupervisedProjects: employee => employee.supervisedProjects || [],
  getProjectDisplayName: project => project.projectName,
  normalizeEmployeeProjectReferenceArray: projects => projects || [],
  renderProjectIdentityPill: (project, label, extraClass) => `<span class="project-identity-pill ${extraClass}" data-project="${project.projectCode}">${label}</span>`,
  t: (key, values = {}) => key === "employees.moreProjects" ? `+${values.count}` : key,
};
vm.createContext(projectTokenContext);
vm.runInContext(`${employeesSource.slice(projectTokensStart, projectTokensEnd)}
this.renderEmployeeResponsibilityBubbles = renderEmployeeResponsibilityBubbles;`, projectTokenContext);
const compactProjectMarkup = projectTokenContext.renderEmployeeResponsibilityBubbles({
  supervisedProjects: [
    { projectCode: "P1", projectName: "One" },
    { projectCode: "P2", projectName: "Two" },
    { projectCode: "P3", projectName: "Three" },
  ],
  backupProjects: [
    { projectCode: "B1", projectName: "Backup One" },
    { projectCode: "B2", projectName: "Backup Two" },
    { projectCode: "B3", projectName: "Backup Three" },
  ],
}, true);
assert.equal((compactProjectMarkup.match(/project-identity-pill/g) || []).length, 3, "A crowded employee card must reserve its fourth token for +N.");
assert.equal((compactProjectMarkup.match(/employee-project-bubble is-more/g) || []).length, 1, "A crowded employee card must use one +N overflow token.");
assert(compactProjectMarkup.includes("is-backup"), "The compact token budget must preserve at least one backup responsibility when both types exist.");

const detailStart = employeesSource.indexOf("function renderEmployeeDetail");
const detailEnd = employeesSource.indexOf("async function loadEmployeeDetail", detailStart);
assert(detailStart >= 0 && detailEnd > detailStart, "Unable to locate employee detail rendering.");
const detailSource = employeesSource.slice(detailStart, detailEnd);
assert(detailSource.includes("employee-edit-button"), "Modifier must remain available in the employee detail header.");
assert(detailSource.includes('class="employee-detail-title'), "The employee detail needs a stable focus target.");
assert(detailSource.includes('tabindex="-1"'), "The employee detail heading must accept programmatic focus.");

assert.match(
  employeesSource,
  /function focusEmployeeDetailCard\(\)[\s\S]*?detailTitle\.focus\(\{ preventScroll: true \}\)[\s\S]*?detailCard\.scrollIntoView\(\{ behavior: "smooth", block: "start" \}\)/,
  "Opening an employee card must focus its loaded detail heading and use the card as the scroll target."
);
assert.match(
  employeesSource,
  /function openEmployeeDetailFromDirectory[\s\S]*?loadEmployeeDetail\(normalizedEmployeeCode\)[\s\S]*?return focusEmployeeDetailCard\(\);/,
  "Opening an employee card must use the shared offset-safe detail focus workflow."
);
assert.match(
  employeesSource,
  /const titleButton = employeeCard\.querySelector\("\.employee-card-title-button\.employee-open-button"\)[\s\S]*?openEmployeeDetailFromDirectory\(employeeCode\)/,
  "Whole-card clicks must use the same accessible detail workflow as the title button."
);

assert.match(
  baseCssSource,
  /\.employee-project-bubble-row\.is-compact\s*\{[\s\S]*?grid-template-columns:\s*repeat\(2, minmax\(0, 1fr\)\);[\s\S]*?max-height:\s*none;[\s\S]*?overflow:\s*hidden;/,
  "Compact employee project pills must occupy two unclipped rows without a nested scrollbar."
);
assert.match(
  themeCssSource,
  /\.employee-card \.project-identity-pill\s*\{[\s\S]*?background:\s*var\(--surface\);[\s\S]*?border-color:\s*var\(--separator\);/,
  "Employee project pills must share one neutral surface and outline while retaining their colored dots."
);
assert.match(
  themeCssSource,
  /\.employee-card \.project-identity-pill\.is-backup\s*\{[\s\S]*?border-style:\s*dashed;/,
  "Backup assignments must be distinguished without changing the neutral pill fill."
);
assert.match(
  themeCssSource,
  /:root\[data-theme="dark"\] \.employee-card \.project-identity-pill\.employee-project-bubble[\s\S]*?background:\s*var\(--surface\);[\s\S]*?border-color:\s*var\(--separator\);/,
  "Dark mode must preserve the same neutral employee-project pill surface and outline."
);

console.log("Employee directory card UI contract tests passed.");
