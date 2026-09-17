const assert = require("assert");
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const repoRoot = path.resolve(__dirname, "..", "..");
const projectsSource = fs.readFileSync(
  path.join(repoRoot, "app/frontend/scripts/Views/ProjectsView.js"),
  "utf8"
);
const indexSource = fs.readFileSync(path.join(repoRoot, "app/frontend/index.html"), "utf8");
const i18nSource = fs.readFileSync(path.join(repoRoot, "app/frontend/scripts/I18n.js"), "utf8");

const helperStart = projectsSource.indexOf("function normalizeProjectPortfolioSearchText");
const helperEnd = projectsSource.indexOf("function getCurrentProjectUserRole", helperStart);
assert(helperStart >= 0 && helperEnd > helperStart, "Unable to locate the project portfolio helpers.");

const context = {
  Intl,
  window: {
    Saphir: {
      textSearch: {
        tokenize: text => String(text == null ? "" : text).split(/\s+/).filter(Boolean),
        matchesAll: (text, tokens) => (tokens || []).every(token => String(text == null ? "" : text).includes(token)),
      },
    },
  },
  projectsViewState: {
    portfolioSearch: "",
    portfolioScope: "active",
    portfolioSort: "activity",
  },
  document: {
    getElementById: () => null,
  },
  formatProjectAdminDisplay: () => [],
  getCurrentLocale: () => "fr-CA",
  getProjectTotalSeconds: project => Number(project && project.totalSeconds || 0),
  isProjectArchived: project => Boolean(project && project.archived),
};
vm.createContext(context);
vm.runInContext(`${projectsSource.slice(helperStart, helperEnd)}
this.getVisibleProjectSummaries = getVisibleProjectSummaries;
this.getScopedProjectSummaries = getScopedProjectSummaries;
this.sortProjectSummaries = sortProjectSummaries;
this.normalizeProjectPortfolioScope = normalizeProjectPortfolioScope;
this.normalizeProjectPortfolioSort = normalizeProjectPortfolioSort;`, context);

const projects = [
  { projectCode: "P10", projectName: "Zulu", sector: "Bravo", totalSeconds: 120, entryCount: 2, archived: false },
  { projectCode: "P02", projectName: "Éclair", sector: "Alpha", totalSeconds: 60, entryCount: 4, archived: false },
  { projectCode: "P01", projectName: "Alpha", sector: "", totalSeconds: 60, entryCount: 1, archived: false },
  { projectCode: "P20", projectName: "Archive", sector: "Alpha", totalSeconds: 500, entryCount: 8, archived: true },
];

assert.strictEqual(context.normalizeProjectPortfolioScope("unknown"), "active", "Unknown scopes must fail closed to active projects.");
assert.strictEqual(context.normalizeProjectPortfolioSort("unknown"), "activity", "Unknown sort modes must default to activity.");

assert.deepStrictEqual(
  Array.from(context.getVisibleProjectSummaries(projects), project => project.projectCode),
  ["P10", "P02", "P01"],
  "Activity sorting must show active projects by overtime, then entry count."
);

context.projectsViewState.portfolioScope = "archived";
assert.deepStrictEqual(
  Array.from(context.getVisibleProjectSummaries(projects), project => project.projectCode),
  ["P20"],
  "The archived scope must contain only archived projects."
);

context.projectsViewState.portfolioScope = "all";
context.projectsViewState.portfolioSort = "alphabetical";
assert.deepStrictEqual(
  Array.from(context.getVisibleProjectSummaries(projects), project => project.projectCode),
  ["P01", "P20", "P02", "P10"],
  "Alphabetical sorting must use localized project names."
);

context.projectsViewState.portfolioSort = "sector";
assert.deepStrictEqual(
  Array.from(context.getVisibleProjectSummaries(projects), project => project.projectCode),
  ["P20", "P02", "P10", "P01"],
  "Sector sorting must group named sectors first and use project names as a stable tie-breaker."
);

context.projectsViewState.portfolioScope = "active";
context.projectsViewState.portfolioSearch = "ecl";
assert.deepStrictEqual(
  Array.from(context.getVisibleProjectSummaries(projects), project => project.projectCode),
  ["P02"],
  "Search must ignore French diacritics and compose with the archive scope."
);

for (const controlId of [
  "projectPortfolioScopeSelect",
  "projectPortfolioSortSelect",
  "projectPortfolioResetButton",
]) {
  assert(projectsSource.includes(`document.getElementById("${controlId}")`), `Missing listener support for ${controlId}.`);
  assert(indexSource.includes(`id="${controlId}"`), `Missing project portfolio control ${controlId}.`);
}

for (const optionValue of ["active", "archived", "all", "activity", "alphabetical", "sector"]) {
  assert(indexSource.includes(`option value="${optionValue}"`), `Missing project portfolio option ${optionValue}.`);
}

assert(
  projectsSource.includes('createEmptyState(t("projects.noProjectsInScope"))'),
  "The project portfolio needs a distinct empty state for a scope with no projects."
);

assert(
  /async function restoreProject\([\s\S]*?encodeURIComponent\(project\.projectCode\) \+ "\/restore"[\s\S]*?method: "POST"/.test(projectsSource),
  "Archived projects must be restored through the dedicated POST endpoint."
);
assert(
  /function buildProjectBootstrapUrl\([\s\S]*?params\.set\("scope", "all"\)/.test(projectsSource),
  "The client-side archive tabs require an explicit all-scope bootstrap snapshot."
);
assert(
  projectsSource.includes('class="btn btn-outline-primary btn-sm project-restore-button"'),
  "Archived project cards must expose a restore action."
);
assert(
  projectsSource.includes('runButtonAction(restoreButton, () => restoreProject(project)')
    && projectsSource.includes('runButtonAction(event.currentTarget, async () => {'),
  "Project restore actions must use the shared busy-button workflow."
);
assert(
  projectsSource.includes('document.getElementById("projectEditorRestoreButton")'),
  "The project editor must support a restore button for archived projects."
);
assert(indexSource.includes('id="projectEditorRestoreButton"'), "The project editor restore button is missing from the modal.");

for (const translationKey of [
  "projects.controls",
  "projects.scope",
  "projects.scopeActive",
  "projects.scopeArchived",
  "projects.scopeAll",
  "projects.sort",
  "projects.sortActivity",
  "projects.sortAlphabetical",
  "projects.sortSector",
  "projects.sortActivityHint",
  "projects.noProjectsInScope",
  "projects.reinstate",
  "projects.restoreConfirm",
  "projects.restoreConfirmCodeOnly",
  "projects.projectRestored",
  "projects.restoreError",
]) {
  const occurrences = i18nSource.split(`"${translationKey}"`).length - 1;
  assert.strictEqual(occurrences, 2, `${translationKey} must have English and French translations.`);
}

console.log("Project portfolio scope and sorting test passed.");
