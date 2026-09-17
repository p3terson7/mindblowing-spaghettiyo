const assert = require("assert");
const fs = require("fs");
const path = require("path");

const repoRoot = path.resolve(__dirname, "..", "..");
const indexSource = fs.readFileSync(path.join(repoRoot, "app/frontend/index.html"), "utf8");

const modalOpeningTags = Array.from(indexSource.matchAll(/<div\b[^>]*>/g), match => match[0])
  .map(tag => {
    const classMatch = tag.match(/\bclass="([^"]*)"/);
    const idMatch = tag.match(/\bid="([^"]+)"/);
    return {
      id: idMatch ? idMatch[1] : "",
      classes: classMatch ? classMatch[1].split(/\s+/).filter(Boolean) : [],
      tag,
    };
  })
  .filter(element => element.id && element.classes.includes("modal"));

assert(modalOpeningTags.length > 0, "The application must expose at least one Bootstrap modal.");

const expectedDataEntryModals = [
  "updateEntryModal",
  "addEntryModal",
  "gc179ImportModal",
  "dashboardNoteModal",
  "selfSettingsModal",
  "employeeEditorModal",
  "projectEditorModal",
];

for (const modalId of expectedDataEntryModals) {
  assert(
    modalOpeningTags.some(modal => modal.id === modalId),
    `The audited data-entry modal ${modalId} is missing.`
  );
}

for (const modal of modalOpeningTags) {
  assert.match(
    modal.tag,
    /\bdata-bs-backdrop="static"/,
    `${modal.id} must ignore backdrop clicks so partially completed work is not discarded.`
  );
  assert.match(
    modal.tag,
    /\bdata-bs-keyboard="true"/,
    `${modal.id} must preserve the established Escape-key dismissal behavior.`
  );

  const modalStart = indexSource.indexOf(modal.tag);
  const nextModalStart = indexSource.indexOf('<div class="modal fade"', modalStart + modal.tag.length);
  const modalSection = indexSource.slice(modalStart, nextModalStart < 0 ? indexSource.length : nextModalStart);
  assert(
    /data-bs-dismiss="modal"/.test(modalSection),
    `${modal.id} must retain an explicit close or cancel control.`
  );
}

console.log(`Modal dismissal policy test passed for ${modalOpeningTags.length} modals.`);
