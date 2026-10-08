const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");

const repoRoot = path.resolve(__dirname, "..", "..");
const read = relativePath => fs.readFileSync(path.join(repoRoot, relativePath), "utf8");
const indexSource = read("app/frontend/index.html");
const employeesSource = read("app/frontend/scripts/Views/EmployeesView.js");
const i18nSource = read("app/frontend/scripts/I18n.js");

for (const prefix of ["selfGc179", "employeeEditorGc179"]) {
  for (const field of ["Group", "SubGroup", "Level"]) {
    const id = `${prefix}${field}Input`;
    assert.equal((indexSource.match(new RegExp(`id="${id}"`, "g")) || []).length, 1, `Classification field ${id} should appear once.`);
  }
}
assert(!indexSource.includes("employeeEditorCompensationAssignmentsBody"), "The retired employee classification period table is still visible.");
assert(!employeesSource.includes("compensationAssignments"), "Employee saves must submit one classification source.");
assert(employeesSource.includes("gc179Profile,"), "Employee saves must retain the shared GC179/classification profile.");
assert(i18nSource.includes('"employees.gc179Header": "Profile and classification"'));
assert(i18nSource.includes('"employees.gc179Header": "Profil et classification"'));
assert(indexSource.includes("styles.css?v=20261008-money-visibility-v1"));
assert(indexSource.includes("I18n.js?v=20261008-money-visibility-v1"));

console.log("Unified employee classification UI contract tests passed.");
