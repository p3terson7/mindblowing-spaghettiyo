const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const repoRoot = path.resolve(__dirname, "..");
const read = relativePath => fs.readFileSync(path.join(repoRoot, relativePath), "utf8");

const indexSource = read("apps/admin/frontend/index.html");
const utilitiesSource = read("apps/admin/frontend/scripts/Utilities.js");
const appShellSource = read("apps/admin/frontend/scripts/AppShell.js");
const employeesSource = read("apps/admin/frontend/scripts/Views/EmployeesView.js");
const i18nSource = read("apps/admin/frontend/scripts/I18n.js");

for (const inputId of [
  "selfGc179PositionSelect",
  "selfGc179LevelInput",
  "employeeEditorGc179PositionSelect",
  "employeeEditorGc179LevelInput",
]) {
  assert.match(
    indexSource,
    new RegExp(`<input[^>]+id=["']${inputId}["'][^>]*>`),
    `${inputId} must be an editable GC179 code input.`,
  );
  assert.doesNotMatch(
    indexSource,
    new RegExp(`<select[^>]+id=["']${inputId}["']`),
    `${inputId} must not return to a fixed selector.`,
  );
}

assert.match(indexSource, /id="selfGc179PositionSelect"[^>]+list="gc179PositionSuggestions"/);
assert.match(indexSource, /id="employeeEditorGc179PositionSelect"[^>]+list="gc179PositionSuggestions"/);
assert.match(indexSource, /id="selfGc179LevelInput"[^>]+list="gc179LevelSuggestions"/);
assert.match(indexSource, /id="employeeEditorGc179LevelInput"[^>]+list="gc179LevelSuggestions"/);
assert.match(indexSource, /id="selfGc179PositionSelect"[^>]+maxlength="6"/);
assert.match(indexSource, /id="employeeEditorGc179PositionSelect"[^>]+maxlength="6"/);
assert.match(indexSource, /id="selfGc179LevelInput"[^>]+maxlength="10"/);
assert.match(indexSource, /id="employeeEditorGc179LevelInput"[^>]+maxlength="10"/);
for (const suggestion of ["STS", "CR4", "AS03", "AS04", "SUF-00", "1", "2", "3", "4"]) {
  assert(indexSource.includes(`<option value="${suggestion}"></option>`), `Missing GC179 suggestion: ${suggestion}`);
}

const normalizerStart = utilitiesSource.indexOf("function normalizeGc179ProfileCode");
const normalizerEnd = utilitiesSource.indexOf("function formatGc179Pri", normalizerStart);
assert(normalizerStart >= 0 && normalizerEnd > normalizerStart, "Unable to locate the GC179 frontend normalizers.");
const normalizerContext = {};
vm.runInNewContext(utilitiesSource.slice(normalizerStart, normalizerEnd), normalizerContext);
assert.strictEqual(normalizerContext.normalizeGc179Position(""), "STS", "A blank legacy position must default to STS.");
assert.strictEqual(normalizerContext.normalizeGc179Echelon(""), "SUF-00", "A blank legacy step must default to SUF-00.");
assert.strictEqual(normalizerContext.normalizeGc179Position(" as-05 "), "AS-05", "Custom position codes must retain hyphens.");
assert.strictEqual(normalizerContext.normalizeGc179Echelon(" suf-02 "), "SUF-02", "Custom step codes must retain hyphens.");
assert.strictEqual(normalizerContext.normalizeGc179Position("cr 7"), "CR7", "Frontend normalization must remove whitespace like the backend.");
assert.strictEqual(normalizerContext.normalizeGc179Position("abcdefghi"), "ABCDEF", "GC179 Group codes must be limited to six characters.");
assert.strictEqual(normalizerContext.normalizeGc179Echelon("abcdefghijklm"), "ABCDEFGHIJ", "GC179 Sub-Group codes must be limited to ten characters.");

for (const source of [appShellSource, employeesSource]) {
  assert(source.includes("normalizeGc179Position("), "A GC179 profile flow is not using the shared position normalizer.");
  assert(source.includes("normalizeGc179Echelon("), "A GC179 profile flow is not using the shared step normalizer.");
}

assert(indexSource.includes('id="selfGc179GroupPreview"'), "The self settings need a live Group preview.");
assert(indexSource.includes('id="selfGc179SubGroupPreview"'), "The self settings need a live Sub-Group preview.");
assert.match(appShellSource, /function updateSelfGc179MappingPreview\(\)[\s\S]*?selfGc179GroupPreview[\s\S]*?normalizeGc179Position/);
assert.match(appShellSource, /function updateSelfGc179MappingPreview\(\)[\s\S]*?selfGc179SubGroupPreview[\s\S]*?normalizeGc179Echelon/);
assert.match(appShellSource, /bindGc179CodeFormatter\(document\.getElementById\("selfGc179PositionSelect"\), updateSelfGc179MappingPreview\)/);
assert.match(appShellSource, /bindGc179CodeFormatter\(document\.getElementById\("selfGc179LevelInput"\), updateSelfGc179MappingPreview\)/);
assert.match(appShellSource, /bindGc179CodeFormatter\(document\.getElementById\("employeeEditorGc179PositionSelect"\)\)/);
assert.match(appShellSource, /bindGc179CodeFormatter\(document\.getElementById\("employeeEditorGc179LevelInput"\)\)/);

const openSettingsStart = appShellSource.indexOf("async function openSelfSettingsForm");
const saveSettingsStart = appShellSource.indexOf("async function submitSelfGc179Profile", openSettingsStart);
const openSettingsSource = appShellSource.slice(openSettingsStart, saveSettingsStart);
assert(openSettingsStart >= 0 && saveSettingsStart > openSettingsStart, "Unable to locate the self GC179 settings flow.");
assert(!openSettingsSource.includes("timeEntryTypes"), "Diverse-only employees must not be blocked from GC179 profile settings.");

for (const copy of [
  '"employees.gc179Position": "Position (GC179 Group)"',
  '"employees.gc179Level": "Step (GC179 Sub-Group)"',
  '"employees.gc179Position": "Poste (groupe GC179)"',
  '"employees.gc179Level": "Échelon (sous-groupe GC179)"',
]) {
  assert(i18nSource.includes(copy), `Missing bilingual GC179 mapping label: ${copy}`);
}

for (const asset of ["I18n.js", "Utilities.js", "AppShell.js"]) {
  assert(indexSource.includes(`${asset}?v=20260803-gc179-codes`), `${asset} is missing the GC179 cache buster.`);
}
assert(
  appShellSource.includes("EmployeesView.js?v=20260803-gc179-codes"),
  "EmployeesView is missing the GC179 cache buster.",
);

console.log("GC179 profile UI contract tests passed.");
