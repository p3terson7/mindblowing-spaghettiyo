const fs = require("fs");
const path = require("path");

const repoRoot = path.resolve(__dirname, "../..");
const read = relativePath => fs.readFileSync(path.join(repoRoot, relativePath), "utf8");
const assert = (condition, message) => {
  if (!condition) {
    throw new Error(message);
  }
};

const index = read("app/frontend/index.html");
const selfView = read("app/frontend/scripts/Views/SelfView.js");
const utilities = read("app/frontend/scripts/Utilities.js");
const i18n = read("app/frontend/scripts/I18n.js");
const styles = read("app/frontend/assets/apple-ui.css");
const appShell = read("app/frontend/scripts/AppShell.js");
const selfRoute = read("app/backend/routes/self.routes.ps1");
const addRoute = read("app/backend/routes/employee/add.routes.ps1");
const updateRoute = read("app/backend/routes/employee/update.routes.ps1");
const importService = read("app/backend/services/Gc179ImportService.ps1");
const dashboardView = read("app/frontend/scripts/Views/DashboardView.js");

assert(index.includes('id="selfCompressedScheduleToggle"'), "The employee dashboard does not expose the global compressed-schedule switch.");
assert(index.includes('role="switch"'), "The compressed-schedule control is not exposed as an accessible switch.");
assert(selfView.includes('fetch(apiUrl + "self/work-schedule"'), "The dashboard switch is not persisted through the targeted schedule endpoint.");
assert(selfView.includes("compressedWorkWeek: Boolean(compressedWorkWeek)"), "The dashboard does not send an explicit boolean schedule value.");
assert(appShell.includes("syncSelfWorkScheduleFromGc179Profile"), "Saving GC179 settings does not synchronize the dashboard switch.");

assert(selfRoute.includes('workScheduleSource = "employee-profile"'), "Self punch-in does not snapshot schedule provenance.");
assert(addRoute.includes('workScheduleSource = "employee-profile"'), "Supervisor-created entries do not snapshot schedule provenance.");
assert(importService.includes('workScheduleSource = "gc179-import"'), "GC179 entries do not retain their imported schedule provenance.");
assert(importService.includes('"standard" { "regular" }'), "GC179 standard schedules are not normalized to the entry contract.");
assert(index.includes('id="updateWorkSchedule"'), "Supervisors cannot correct an entry's stored schedule from the edit modal.");
assert(index.includes('id="updateWorkSchedule" class="form-select" required'), "The entry editor does not require an explicit schedule for legacy entries.");
assert(dashboardView.includes('data-workschedule='), "Entry edit actions do not carry the stored schedule into the modal.");
assert(dashboardView.includes("workSchedule === originalWorkSchedule"), "A schedule-only correction is incorrectly treated as an unchanged entry.");
assert(dashboardView.includes("entryType, workSchedule,"), "The entry editor does not submit the corrected schedule.");
assert(updateRoute.includes('@("regular", "compressed") -notcontains $requestedWorkSchedule'), "The server does not reject ambiguous schedule values.");
assert(updateRoute.includes('workScheduleSource" -Value "supervisor-edit"'), "Schedule corrections do not retain supervisor-edit provenance.");

assert(utilities.includes("function renderEntryWorkScheduleBadge"), "Entries do not have a shared work-schedule label renderer.");
assert(utilities.includes('return "unconfirmed"'), "Legacy entries without a schedule are not visibly marked for confirmation.");
assert(i18n.includes('"shared.workScheduleCompressed": "Temps comprimé"'), "The compressed entry label is not localized in French.");
assert(i18n.includes('"shared.workScheduleUnconfirmed": "Horaire à confirmer"'), "The legacy schedule warning is not localized in French.");
assert(styles.includes(".self-work-schedule-control"), "The dashboard schedule control has no dedicated visual treatment.");
assert(styles.includes(".work-schedule-badge.unconfirmed"), "Unconfirmed legacy schedules have no warning treatment.");

const cacheRevision = "20260921-bug-reports-phase5-v1";
assert(index.includes(`scripts/Views/SelfView.js?v=${cacheRevision}`), "The self dashboard cache revision was not bumped.");
assert(appShell.includes(`ApprovalsView.js?v=${cacheRevision}`), "The Review entry labels may remain cached.");

console.log("Work-schedule dashboard and entry-label UI tests passed.");
