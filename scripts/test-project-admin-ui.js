const assert = require("assert");
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const repoRoot = path.resolve(__dirname, "..");
const read = relativePath => fs.readFileSync(path.join(repoRoot, relativePath), "utf8");

const indexSource = read("apps/admin/frontend/index.html");
const employeesSource = read("apps/admin/frontend/scripts/Views/EmployeesView.js");
const projectsSource = read("apps/admin/frontend/scripts/Views/ProjectsView.js");
const utilitiesSource = read("apps/admin/frontend/scripts/Utilities.js");
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
assert(projectsSource.includes('if (!projectCode || (mode === "edit" && !originalProjectCode))'), "The project editor still requires an optional project name.");
assert(projectsSource.includes('getProjectDisplayName(detail)'), "Nameless project cards do not fall back to the project code.");
assert(indexSource.includes('data-i18n="projects.projectName">Project Name (optional)</label>'), "The project editor does not mark the project name as optional.");
assert(employeesSource.includes('t("employees.employeeCode")'), "The employee sheet does not use the localized HRMIS/SIGRH label.");

for (const translationKey of [
  "projects.renameInUse",
  "projects.deleteConfirm",
  "projects.projectDeleted",
  "projects.deleteInUse",
  "projects.archiveConfirmCodeOnly",
  "projects.deleteConfirmCodeOnly",
  "history.message.projectCreatedWithoutName",
]) {
  const occurrences = i18nSource.split(`"${translationKey}"`).length - 1;
  assert.strictEqual(occurrences, 2, `${translationKey} must have both English and French translations.`);
}

assert(appShellSource.includes("EmployeesView.js?v=20260803-gc179-codes"), "EmployeesView cache version was not bumped.");
assert(appShellSource.includes("DashboardView.js?v=20260803-work-comments"), "DashboardView cache version was not bumped.");
assert(appShellSource.includes("ApprovalsView.js?v=20260803-work-comments"), "ApprovalsView cache version was not bumped.");
assert(appShellSource.includes("HistoryView.js?v=20260722-button-busy"), "HistoryView cache version was not bumped.");
assert(appShellSource.includes("ProjectsView.js?v=20260803-work-comments"), "ProjectsView cache version was not bumped.");

for (const expectedLabel of ['"employees.employeeCode": "HRMIS"', '"employees.employeeCode": "SIGRH"']) {
  assert(i18nSource.includes(expectedLabel), `Missing localized employee identifier label: ${expectedLabel}`);
}

const projectHelperStart = utilitiesSource.indexOf("function getProjectDisplayName");
const projectHelperEnd = utilitiesSource.indexOf("function getLocalizedOptionLabel", projectHelperStart);
assert(projectHelperStart >= 0 && projectHelperEnd > projectHelperStart, "Unable to locate project display helpers.");
const helperContext = {
  escapeHtml: value => String(value),
  t: key => key,
};
vm.createContext(helperContext);
vm.runInContext(`${utilitiesSource.slice(projectHelperStart, projectHelperEnd)}
this.getProjectDisplayName = getProjectDisplayName;
this.formatProjectCodeAndName = formatProjectCodeAndName;
this.buildProjectOptions = buildProjectOptions;`, helperContext);

const namelessProject = { projectCode: "P001", projectName: "" };
assert.strictEqual(helperContext.getProjectDisplayName(namelessProject), "P001", "A nameless project did not fall back to its code.");
assert.strictEqual(helperContext.formatProjectCodeAndName(namelessProject), "P001", "A nameless project produced a duplicate code/name label.");
assert(!helperContext.buildProjectOptions([namelessProject], "Choose", "").includes("P001 | P001"), "A nameless project option repeats its code.");
assert.strictEqual(
  helperContext.formatProjectCodeAndName({ projectCode: "P001", projectName: "Project One" }),
  "P001 | Project One",
  "A named project lost its descriptive option label."
);

console.log("Project admin UI contract test passed.");
