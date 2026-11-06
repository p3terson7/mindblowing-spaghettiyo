const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const source = fs.readFileSync(path.resolve(__dirname, "../../app/frontend/scripts/Views/ProjectsView.js"), "utf8");
const start = source.indexOf("async function ensureProjectEditorEmployees(");
const end = source.indexOf("function normalizeAssignmentCodes", start);
assert(start >= 0 && end > start);
const urls = [];
const employees = [{ code: "001", name: "Admin", role: "admin", archived: false }];
const context = {
  projectsViewState: { employees: [] },
  apiUrl: "http://localhost/",
  fetch: async url => { urls.push(url); return { payload: employees }; },
  parseResponse: async response => response.payload,
};
vm.createContext(context);
vm.runInContext(source.slice(start, end), context);
// Contributor rows must use the complete aggregates, not infer totals from
// the (now deliberately omitted) per-contributor entry lists.
const contributorStart = source.indexOf("function getProjectWorkspaceContributors(");
const contributorEnd = source.indexOf("function getProjectWorkspaceEntryStatus(", contributorStart);
assert(contributorStart >= 0 && contributorEnd > contributorStart);
const contributorContext = {
  getProjectWorkspaceApprovedSeconds: () => 7200,
  getProjectMonetaryModel: contributor => contributor.monetary,
  getLatestProjectEntryDate: () => "",
};
vm.createContext(contributorContext);
vm.runInContext(source.slice(contributorStart, contributorEnd), contributorContext);
const [contributor] = contributorContext.getProjectWorkspaceContributors({ contributors: [{
  employee: "Admin", approvedSeconds: 3600, approvedEntryCount: 4, pendingCount: 2,
  pendingSeconds: 1800, sharePercent: 50, averageApprovedSeconds: 900,
  lastActivityDate: "2026-10-05", monetary: { totalAmountCents: 12345 },
}] });
assert.equal(contributor.approvedEntryCount, 4);
assert.equal(contributor.pendingCount, 2);
assert.equal(contributor.pendingSeconds, 1800);
assert.equal(contributor.sharePercent, 50);
assert.equal(contributor.averageApprovedSeconds, 900);
assert.equal(contributor.monetaryTotalAmountCents, 12345);
assert.equal(contributor.lastActivityDate, "2026-10-05");
assert.equal(contributor.entries.length, 0);
(async () => {
  assert.equal(urls.length, 0, "Loading the Projects module must not fetch editor lookups.");
  await context.ensureProjectEditorEmployees();
  assert.deepEqual(urls, ["http://localhost/employees?scope=all&includeStats=false"]);
  assert.equal(context.projectsViewState.employees, employees);
  await context.ensureProjectEditorEmployees();
  assert.equal(urls.length, 1, "A valid lookup can be reused.");
  await context.ensureProjectEditorEmployees(true);
  assert.equal(urls.length, 2, "Reopening the editor can refresh roles without loading entry statistics.");
  console.log("Projects metadata-only lazy editor test passed.");
})().catch(error => { console.error(error); process.exitCode = 1; });
