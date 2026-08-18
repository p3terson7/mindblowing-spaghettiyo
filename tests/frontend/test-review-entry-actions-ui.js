#!/usr/bin/env node

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const repoRoot = path.resolve(__dirname, "..", "..");
const read = relativePath => fs.readFileSync(path.join(repoRoot, relativePath), "utf8");
const approvalsSource = read("app/frontend/scripts/Views/ApprovalsView.js");
const appShellSource = read("app/frontend/scripts/AppShell.js");
const dashboardSource = read("app/frontend/scripts/Views/DashboardView.js");
const employeesSource = read("app/frontend/scripts/Views/EmployeesView.js");
const i18nSource = read("app/frontend/scripts/I18n.js");
const cssSource = read("app/frontend/assets/apple-ui.css");

assert.match(
  approvalsSource,
  /const canManage = canModifyEntry\(entry\);/,
  "Review must derive management actions from the same projected permission as the employee file.",
);
assert.match(
  approvalsSource,
  /\$\{canManage \? `[\s\S]*?approvals-edit-button[\s\S]*?approvals-delete-button[\s\S]*?` : ""\}/,
  "Review cards must expose edit and delete only for modifiable entries.",
);
assert.match(
  approvalsSource,
  /entryActionAttributes = \[[\s\S]*?data-entryid=[\s\S]*?data-exactpunchin=[\s\S]*?data-workcomment=[\s\S]*?data-status=[\s\S]*?data-message=/,
  "The Review editor trigger is missing fields required by the shared entry editor.",
);
assert.match(
  approvalsSource,
  /closest\("\.approvals-edit-button"\)[\s\S]*?setDashboardSelectedEmployee\(employeeCode\);[\s\S]*?openUpdateModal\(editButton, employeeCode\)/,
  "Review edit must reuse the established entry modal rather than implementing a second editor.",
);
assert.match(
  approvalsSource,
  /closest\("\.approvals-delete-button"\)[\s\S]*?deleteEntry\(deleteButton, deleteButton\.getAttribute\("data-employee-code"\)\)/,
  "Review delete must reuse the established delete workflow.",
);
assert.match(
  dashboardSource,
  /async function deleteEntry\(button, employeeCodeOverride = ""\)/,
  "The shared delete workflow must accept Review's explicit employee context.",
);
assert.match(
  approvalsSource,
  /closest\("\.approvals-jump-button"\)[\s\S]*?window\.openEmployeeEntryInPeopleView\(employeeCode, projectCode, entryId\)/,
  "Review must use the AppShell navigation helper that can lazy-load Personnel.",
);
assert.doesNotMatch(
  approvalsSource.slice(approvalsSource.indexOf('const jumpButton = event.target.closest(".approvals-jump-button")')),
  /openEmployeeFileFromDashboard|focusDashboardEmployee/,
  "Review navigation still depends on a helper that may not exist in a fresh lazy-loaded session.",
);
assert.match(
  dashboardSource,
  /openEmployeeFileFromDashboard\(employeeCode, projectCode = "", entryId = ""\)[\s\S]*?openPeopleProjectFilter\(normalizedEmployeeCode, String\(projectCode \|\| ""\)\.trim\(\), String\(entryId \|\| ""\)\.trim\(\)\)/,
  "Open Entry must preserve the stable entry ID on navigation.",
);
assert.match(
  employeesSource,
  /openPeopleProjectFilter\(employeeCode, projectCode, entryId = ""\)[\s\S]*?prepareEmployeeEntryFocus\(employeeCode, entryId\);[\s\S]*?focusEmployeeEntry\(entryId\);/,
  "The employee file must render the entry's month and focus the requested entry.",
);
assert.match(employeesSource, /scrollIntoView\(\{ behavior: "smooth", block: "center" \}\)/, "Open Entry must bring its target into view.");
assert.match(cssSource, /\.calendar-entry\.is-entry-focus-target/, "The opened entry needs a temporary visual focus marker.");
assert(i18nSource.includes('"action.openEntry": "Open Entry"'), "English Open Entry copy is missing.");
assert(i18nSource.includes('"action.openEntry": "Ouvrir l’entrée"'), "French Open Entry copy is missing.");

async function testFreshReviewNavigation() {
  const helperStart = appShellSource.indexOf("async function openEmployeeEntryInPeopleView");
  const helperEnd = appShellSource.indexOf("window.openEmployeeEntryInPeopleView = openEmployeeEntryInPeopleView;", helperStart);
  assert(helperStart >= 0 && helperEnd > helperStart, "Unable to locate the AppShell entry-navigation helper.");

  const calls = [];
  const context = {
    String,
    Error,
    window: {},
    t: key => key,
    async ensureManagerAssetsForView(viewId) {
      calls.push(["load", viewId]);
      context.window.openPeopleProjectFilter = async (...args) => {
        calls.push(["open", ...args]);
      };
    },
  };
  assert.equal(context.window.openPeopleProjectFilter, undefined, "The fresh-session test accidentally starts with Personnel loaded.");
  assert.equal(context.window.openEmployeeFileFromDashboard, undefined, "The fresh-session test accidentally starts with Dashboard navigation loaded.");
  assert.equal(context.window.focusDashboardEmployee, undefined, "The fresh-session test accidentally starts with the legacy fallback loaded.");

  vm.createContext(context);
  vm.runInContext(
    `${appShellSource.slice(helperStart, helperEnd)}\nthis.openEmployeeEntryInPeopleView = openEmployeeEntryInPeopleView;`,
    context,
  );
  const opened = await context.openEmployeeEntryInPeopleView(" 000100001 ", " P001 ", " entry-42 ");
  assert.equal(opened, true);
  assert.deepEqual(calls, [
    ["load", "employeesView"],
    ["open", "000100001", "P001", "entry-42"],
  ], "Fresh Review navigation did not load Personnel before forwarding the exact entry context.");
}

testFreshReviewNavigation()
  .then(() => console.log("Review direct entry action UI contracts passed."))
  .catch(error => {
    console.error(error);
    process.exitCode = 1;
  });
