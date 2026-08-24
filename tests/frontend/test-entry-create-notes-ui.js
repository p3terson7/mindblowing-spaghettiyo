#!/usr/bin/env node

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const repoRoot = path.resolve(__dirname, "..", "..");
const read = relativePath => fs.readFileSync(path.join(repoRoot, relativePath), "utf8");
const indexSource = read("app/frontend/index.html");
const dashboardSource = read("app/frontend/scripts/Views/DashboardView.js");
const i18nSource = read("app/frontend/scripts/I18n.js");

assert.match(
  indexSource,
  /id="addEntryForm"[\s\S]*?for="addWorkComment"[\s\S]*?id="addWorkComment"[^>]*maxlength="1000"[\s\S]*?for="addManagerMessage"[\s\S]*?id="addManagerMessage"[^>]*maxlength="1000"/,
  "Creating an entry must expose optional employee-comment and supervisor-note fields.",
);
assert.match(
  dashboardSource,
  /\["addWorkComment", "addManagerMessage"\]\.forEach\(id => \{[\s\S]*?\.value = ""/,
  "Opening a new-entry modal must clear notes left over from a cancelled creation.",
);
assert.match(
  dashboardSource,
  /const workComment = document\.getElementById\("addWorkComment"\)\.value\.trim\(\);[\s\S]*?const managerMessage = document\.getElementById\("addManagerMessage"\)\.value\.trim\(\);/,
  "The creation workflow must read both optional note fields.",
);
assert.match(
  dashboardSource,
  /reasonCode,[\s\S]*?workComment,[\s\S]*?message: managerMessage,/,
  "The creation request must send the employee comment and supervisor note using the existing API contract.",
);
assert(i18nSource.includes('"modal.employeeCommentOptional": "Employee comment (optional)"'), "English employee-comment copy is missing.");
assert(i18nSource.includes('"modal.supervisorNoteOptional": "Supervisor note (optional)"'), "English supervisor-note copy is missing.");
assert(i18nSource.includes('"modal.employeeCommentOptional": "Commentaire de l’employé (facultatif)"'), "French employee-comment copy is missing.");
assert(i18nSource.includes('"modal.supervisorNoteOptional": "Note du superviseur (facultative)"'), "French supervisor-note copy is missing.");

console.log("Entry creation note UI contracts passed.");
