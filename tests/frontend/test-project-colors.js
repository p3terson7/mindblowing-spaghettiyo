const fs = require("fs");
const path = require("path");
const vm = require("vm");

const repoRoot = path.resolve(__dirname, "..", "..");
const read = relativePath => fs.readFileSync(path.join(repoRoot, relativePath), "utf8");
const assert = (condition, message) => {
  if (!condition) throw new Error(message);
};

const utilities = read("app/frontend/scripts/Utilities.js");
const projects = read("app/frontend/scripts/Views/ProjectsView.js");
const approvals = read("app/frontend/scripts/Views/ApprovalsView.js");
const dashboard = read("app/frontend/scripts/Views/DashboardView.js");
const employees = read("app/frontend/scripts/Views/EmployeesView.js");
const self = read("app/frontend/scripts/Views/SelfView.js");
const index = read("app/frontend/index.html");
const css = read("app/frontend/assets/apple-ui.css");
const shell = read("app/frontend/scripts/AppShell.js");

const helperStart = utilities.indexOf("const SAPHIR_PROJECT_COLOR_KEYS");
const helperEnd = utilities.indexOf("function formatProjectCodeAndName", helperStart);
assert(helperStart >= 0 && helperEnd > helperStart, "Project color helpers are missing from Utilities.js.");
const context = {
  escapeHtml: value => String(value),
  getComputedStyle: () => ({ getPropertyValue: () => "" }),
  document: { documentElement: {} },
};
vm.createContext(context);
vm.runInContext(`${utilities.slice(helperStart, helperEnd)}\nthis.projectColorApi={getDefaultProjectColorKey,normalizeProjectColorKey,getProjectColorKey,renderProjectIdentityPill};`, context);
const api = context.projectColorApi;
assert(api.normalizeProjectColorKey("VIOLET", "P1") === "violet", "Supported project colors are not normalized.");
assert(api.normalizeProjectColorKey("javascript:red", "P1") === api.getDefaultProjectColorKey("P1"), "Arbitrary project colors are not rejected by the client fallback.");
assert(api.getDefaultProjectColorKey("LEGACY") === api.getDefaultProjectColorKey("LEGACY"), "Legacy project color fallback is not stable.");
assert(api.renderProjectIdentityPill({ projectCode: "P1", colorKey: "mint" }, "P1").includes("project-color-mint"), "Project identity pills do not expose their semantic color token.");

assert(index.includes('id="projectEditorColorSelect"'), "The project editor has no color picker.");
assert(projects.includes("colorKey,"), "Project changes do not submit colorKey.");
assert(projects.includes("renderProjectEditorColorOptions(getProjectColorKey(project))"), "Editing a project does not restore its chosen color.");
assert(projects.includes("getProjectColorCssValue"), "Project charts do not consume persisted project colors.");
assert(approvals.includes("renderProjectIdentityPill(projectRecord, projectCode)"), "Revision cards do not show project color identity.");
assert(dashboard.includes("renderDashboardEntryProjectIdentity"), "Dashboard entries do not show project color identity.");
assert(employees.includes("renderProjectIdentityPill(project, project.projectCode)"), "Employee project cards do not show project color identity.");
assert(self.includes("renderProjectColorDot(project)"), "Self project summaries do not show project color identity.");
assert(css.includes("--project-color-blue:"), "Theme project color tokens are missing.");
assert(css.includes(".project-identity-pill"), "Shared project identity pill styling is missing.");

for (const asset of [
  "assets/apple-ui.css",
  "scripts/I18n.js",
  "scripts/Utilities.js",
  "scripts/AppShell.js",
  "scripts/Views/SelfView.js",
]) {
  assert(index.includes(`${asset}?v=20260817-chartjs-employee-cards-v2`), `${asset} cache key was not bumped.`);
}
for (const view of ["EmployeesView", "DashboardView", "ApprovalsView", "ProjectsView"]) {
  assert(shell.includes(`${view}.js?v=20260817-chartjs-employee-cards-v2`), `${view} cache key was not bumped.`);
}

console.log("Project color UI tests passed.");
