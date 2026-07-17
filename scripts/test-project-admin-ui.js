const assert = require("assert");
const fs = require("fs");
const path = require("path");

const repoRoot = path.resolve(__dirname, "..");
const read = relativePath => fs.readFileSync(path.join(repoRoot, relativePath), "utf8");

const indexSource = read("apps/admin/frontend/index.html");
const employeesSource = read("apps/admin/frontend/scripts/Views/EmployeesView.js");
const projectsSource = read("apps/admin/frontend/scripts/Views/ProjectsView.js");
const i18nSource = read("apps/admin/frontend/scripts/I18n.js");
const appShellSource = read("apps/admin/frontend/scripts/AppShell.js");

assert(!indexSource.includes("seedDemoEntriesButton"), "The demo-entry button is still present in the UI.");
assert(!employeesSource.includes("seedDemoEntriesButton"), "EmployeesView still depends on the removed demo-entry button.");
assert(!employeesSource.includes("seedDemoEntries()"), "EmployeesView still exposes the demo-entry UI action.");
assert(!i18nSource.includes("employees.seedDemoEntries"), "Removed demo-entry UI translations are still present.");

assert(indexSource.includes('id="projectEditorOriginalCodeInput"'), "The project editor does not retain the original dossier number.");
assert(indexSource.includes('id="projectEditorDeleteButton"'), "The permanent project delete control is missing.");
assert(projectsSource.includes('document.getElementById("projectEditorCodeInput").readOnly = false;'), "The dossier number remains read-only while editing.");
assert(projectsSource.includes('encodeURIComponent(originalProjectCode)'), "Project updates are not routed through the original dossier number.");
assert(projectsSource.includes('?permanent=true'), "The UI does not request permanent project deletion explicitly.");
assert(projectsSource.includes('if (!canManageProjects())'), "Project editor actions lost their super-admin UI guard.");
assert(projectsSource.includes('response.status === 409'), "The project editor does not handle referenced-project conflicts.");

for (const translationKey of [
  "projects.renameInUse",
  "projects.deleteConfirm",
  "projects.projectDeleted",
  "projects.deleteInUse",
]) {
  const occurrences = i18nSource.split(`"${translationKey}"`).length - 1;
  assert.strictEqual(occurrences, 2, `${translationKey} must have both English and French translations.`);
}

assert(appShellSource.includes("EmployeesView.js?v=20260716-apple-ui"), "EmployeesView cache version was not bumped.");
assert(appShellSource.includes("ProjectsView.js?v=20260716-apple-ui"), "ProjectsView cache version was not bumped.");

console.log("Project admin UI contract test passed.");
