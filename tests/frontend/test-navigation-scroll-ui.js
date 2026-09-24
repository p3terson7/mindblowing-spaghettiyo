#!/usr/bin/env node

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const repoRoot = path.resolve(__dirname, "..", "..");
const read = relativePath => fs.readFileSync(path.join(repoRoot, relativePath), "utf8");
const projectsSource = read("app/frontend/scripts/Views/ProjectsView.js");
const employeesSource = read("app/frontend/scripts/Views/EmployeesView.js");
const cssSource = read("app/frontend/assets/apple-ui.css");

assert.match(
  projectsSource,
  /function setProjectWorkspaceVisibility\(isOpen, options = \{\}\) \{\s*const wasOpen = Boolean\(projectsViewState\.workspaceOpen\);/,
  "Project workspace visibility must distinguish an initial open from an in-place refresh.",
);
assert.match(
  projectsSource,
  /if \(isOpen\) \{[\s\S]*?if \(!wasOpen && options\.scrollToTop !== false\) \{\s*window\.scrollTo\(\{ top: 0, behavior: "auto" \}\);/,
  "Refreshing a Project period must not reset the page to the top.",
);
assert.match(
  projectsSource,
  /const shouldOpenWorkspaceFromRoute = Boolean\(routeProjectCode\) && !projectsViewState\.workspaceOpen;[\s\S]*?if \(routeProjectCode\) \{\s*currentProjectCode = routeProjectCode;\s*if \(shouldOpenWorkspaceFromRoute\) \{\s*setProjectWorkspaceVisibility\(true, \{ focus: false \}\);/,
  "A Project refresh must not re-open an already visible workspace.",
);

assert.match(
  employeesSource,
  /function focusEmployeeDetailCard\(\) \{[\s\S]*?detailTitle\.focus\(\{ preventScroll: true \}\);[\s\S]*?const detailCard = detailContainer\.querySelector\("\.employee-detail-card"\) \|\| detailContainer;[\s\S]*?detailCard\.scrollIntoView\(\{ behavior: "smooth", block: "start" \}\);/,
  "Employee navigation must target the detail card and retain its accessible heading focus.",
);
assert.match(
  employeesSource,
  /prepareEmployeeEntryFocus\(employeeCode, entryId\);\s*if \(!focusEmployeeEntry\(entryId\)\) \{\s*focusEmployeeDetailCard\(\);/,
  "A Fiche employé navigation without a specific entry must land on the employee information card.",
);
assert.match(
  employeesSource,
  /function focusEmployeeEntry\(entryId\)[\s\S]*?return false;[\s\S]*?return true;/,
  "Entry navigation must report whether it found the requested entry before the employee-card fallback is used.",
);
assert.match(
  cssSource,
  /\.employee-detail-card\s*\{[\s\S]*?scroll-margin-top:\s*88px;/,
  "Employee detail headers need safe space below the sticky application header.",
);

console.log("Navigation scroll UI contracts passed.");
