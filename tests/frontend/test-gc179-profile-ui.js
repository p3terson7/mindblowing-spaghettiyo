const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const repoRoot = path.resolve(__dirname, "..", "..");
const read = relativePath => fs.readFileSync(path.join(repoRoot, relativePath), "utf8");

const indexSource = read("app/frontend/index.html");
const utilitiesSource = read("app/frontend/scripts/Utilities.js");
const appShellSource = read("app/frontend/scripts/AppShell.js");
const employeesSource = read("app/frontend/scripts/Views/EmployeesView.js");
const i18nSource = read("app/frontend/scripts/I18n.js");

const selfInputIds = [
  "selfGc179GroupInput",
  "selfGc179SubGroupInput",
  "selfGc179LevelInput",
];
const employeeInputIds = [
  "employeeEditorGc179GroupInput",
  "employeeEditorGc179SubGroupInput",
  "employeeEditorGc179LevelInput",
];

for (const inputId of [...selfInputIds, ...employeeInputIds]) {
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

for (const [inputId, datalistId, maximumLength] of [
  ["selfGc179GroupInput", "gc179GroupSuggestions", 6],
  ["employeeEditorGc179GroupInput", "gc179GroupSuggestions", 6],
  ["selfGc179SubGroupInput", "gc179SubGroupSuggestions", 10],
  ["employeeEditorGc179SubGroupInput", "gc179SubGroupSuggestions", 10],
  ["selfGc179LevelInput", "gc179LevelSuggestions", 10],
  ["employeeEditorGc179LevelInput", "gc179LevelSuggestions", 10],
]) {
  assert.match(indexSource, new RegExp(`id="${inputId}"[^>]+list="${datalistId}"`));
  assert.match(indexSource, new RegExp(`id="${inputId}"[^>]+maxlength="${maximumLength}"`));
}

for (const suggestion of ["STS", "CR4", "AS03", "AS04", "SUF-00", "CR/01", "AS/01", "1", "2", "3", "4"]) {
  assert(indexSource.includes(`<option value="${suggestion}"></option>`), `Missing GC179 suggestion: ${suggestion}`);
}

const normalizerStart = utilitiesSource.indexOf("function getFirstDefinedPropertyValue");
const normalizerEnd = utilitiesSource.indexOf("function formatGc179Pri", normalizerStart);
assert(normalizerStart >= 0 && normalizerEnd > normalizerStart, "Unable to locate the GC179 frontend normalizers.");
const normalizerContext = {};
vm.runInNewContext(utilitiesSource.slice(normalizerStart, normalizerEnd), normalizerContext);
assert.strictEqual(normalizerContext.normalizeGc179Group(""), "STS", "A blank Group must default to STS.");
assert.strictEqual(normalizerContext.normalizeGc179SubGroup(""), "SUF-00", "A blank Sub-Group must default to SUF-00.");
assert.strictEqual(normalizerContext.normalizeGc179Level(""), "", "A blank Level must remain blank.");
assert.strictEqual(normalizerContext.normalizeGc179Group(" as-05 "), "AS-05", "Custom Group codes must retain hyphens.");
assert.strictEqual(normalizerContext.normalizeGc179SubGroup(" suf-02 "), "SUF-02", "Custom Sub-Group codes must retain hyphens.");
assert.strictEqual(normalizerContext.normalizeGc179Level(" cr/01!? "), "CR/01", "Level code normalization must match the other GC179 fields.");
assert.strictEqual(normalizerContext.normalizeGc179Group("cr 7"), "CR7", "Group normalization must remove whitespace.");
assert.strictEqual(normalizerContext.normalizeGc179Group("abcdefghi"), "ABCDEF", "GC179 Group codes must be limited to six characters.");
assert.strictEqual(normalizerContext.normalizeGc179SubGroup("abcdefghijklm"), "ABCDEFGHIJ", "GC179 Sub-Group codes must be limited to ten characters.");
assert.strictEqual(normalizerContext.normalizeGc179Level("abcdefghijklm"), "ABCDEFGHIJ", "GC179 Level codes must be limited to ten characters.");
assert.strictEqual(normalizerContext.normalizeGc179Position("AS03"), "AS03", "The legacy Position normalizer must remain a Group alias.");
assert.strictEqual(normalizerContext.normalizeGc179Echelon("SUF-00"), "SUF-00", "The legacy Echelon normalizer must remain a Sub-Group alias.");

for (const source of [appShellSource, employeesSource]) {
  for (const normalizer of ["normalizeGc179Group(", "normalizeGc179SubGroup(", "normalizeGc179Level("]) {
    assert(source.includes(normalizer), `A GC179 profile flow is not using ${normalizer}.`);
  }
  assert(source.includes("hasExplicitGroup"), "A GC179 profile flow does not distinguish the old two-field profile shape.");
  assert(source.includes("hasExplicitSubGroup"), "A GC179 profile flow does not distinguish the new Sub-Group field.");
}

for (const previewId of ["selfGc179GroupPreview", "selfGc179SubGroupPreview", "selfGc179LevelPreview"]) {
  assert(indexSource.includes(`id="${previewId}"`), `The self settings need a live ${previewId} preview.`);
}
assert.match(appShellSource, /function updateSelfGc179MappingPreview\(\)[\s\S]*?selfGc179GroupPreview[\s\S]*?normalizeGc179Group/);
assert.match(appShellSource, /function updateSelfGc179MappingPreview\(\)[\s\S]*?selfGc179SubGroupPreview[\s\S]*?normalizeGc179SubGroup/);
assert.match(appShellSource, /function updateSelfGc179MappingPreview\(\)[\s\S]*?selfGc179LevelPreview[\s\S]*?normalizeGc179Level/);
for (const inputId of selfInputIds) {
  assert(appShellSource.includes(`bindGc179CodeFormatter(document.getElementById("${inputId}"), updateSelfGc179MappingPreview)`), `${inputId} is missing its self-settings formatter.`);
}
for (const inputId of employeeInputIds) {
  assert(appShellSource.includes(`bindGc179CodeFormatter(document.getElementById("${inputId}"))`), `${inputId} is missing its employee-editor formatter.`);
}

for (const [source, inputPrefix] of [[appShellSource, "selfGc179"], [employeesSource, "employeeEditorGc179"]]) {
  assert(source.includes(`group: document.getElementById("${inputPrefix}GroupInput").value`), "GC179 Group is not submitted as its own field.");
  assert(source.includes(`subGroup: document.getElementById("${inputPrefix}SubGroupInput").value`), "GC179 Sub-Group is not submitted as its own field.");
  assert(source.includes(`level: document.getElementById("${inputPrefix}LevelInput").value`), "GC179 Level is not submitted as its own field.");
}

const openSettingsStart = appShellSource.indexOf("async function openSelfSettingsForm");
const saveSettingsStart = appShellSource.indexOf("async function submitSelfGc179Profile", openSettingsStart);
const openSettingsSource = appShellSource.slice(openSettingsStart, saveSettingsStart);
assert(openSettingsStart >= 0 && saveSettingsStart > openSettingsStart, "Unable to locate the self GC179 settings flow.");
assert(!openSettingsSource.includes("timeEntryTypes"), "Diverse-only employees must not be blocked from GC179 profile settings.");

for (const copy of [
  '"employees.gc179GroupInput": "Group"',
  '"employees.gc179SubGroupInput": "Sub-Group"',
  '"employees.gc179LevelInput": "Level"',
  '"employees.gc179GroupInput": "Groupe"',
  '"employees.gc179SubGroupInput": "Sous-groupe"',
  '"employees.gc179LevelInput": "Niveau"',
]) {
  assert(i18nSource.includes(copy), `Missing bilingual GC179 field label: ${copy}`);
}

const gc179AssetCacheVersions = {
  "I18n.js": "20260824-review-attention-tab-v1",
  "Utilities.js": "20260824-review-attention-tab-v1",
  "AppShell.js": "20260824-review-attention-tab-v1",
};
for (const [asset, version] of Object.entries(gc179AssetCacheVersions)) {
  assert(indexSource.includes(`${asset}?v=${version}`), `${asset} is missing the GC179 cache buster.`);
}
assert(
  appShellSource.includes("EmployeesView.js?v=20260824-review-attention-tab-v1"),
  "EmployeesView is missing the GC179 cache buster.",
);

console.log("GC179 profile UI contract tests passed.");
