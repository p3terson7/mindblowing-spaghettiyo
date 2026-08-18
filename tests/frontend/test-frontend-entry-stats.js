#!/usr/bin/env node

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const repoRoot = path.resolve(__dirname, "..", "..");
const read = relativePath => fs.readFileSync(path.join(repoRoot, relativePath), "utf8");
const utilitiesSource = read("app/frontend/scripts/Utilities.js");
const selfSource = read("app/frontend/scripts/Views/SelfView.js");
const employeesSource = read("app/frontend/scripts/Views/EmployeesView.js");

function sourceBetween(source, startMarker, endMarker) {
  const start = source.indexOf(startMarker);
  const end = source.indexOf(endMarker, start + startMarker.length);
  assert.notEqual(start, -1, `Unable to find ${startMarker}`);
  assert.notEqual(end, -1, `Unable to find ${endMarker}`);
  return source.slice(start, end).trim();
}

function plain(value) {
  return JSON.parse(JSON.stringify(value));
}

function legacyResolveStatus(entry, isOpen) {
  if (isOpen(entry)) {
    return "live";
  }
  return String(entry && entry.status || "pending").toLowerCase();
}

function legacySelectTopBucket(buckets) {
  return Object.values(buckets).sort((left, right) => {
    if (right.seconds !== left.seconds) {
      return right.seconds - left.seconds;
    }
    return right.count - left.count;
  })[0] || null;
}

function legacySummarize(entries, options) {
  const sourceEntries = Array.isArray(entries) ? entries : [];
  const projectBuckets = {};
  const overtimeCodeBuckets = {};
  const totals = {
    count: sourceEntries.length,
    seconds: 0,
    approvedSeconds: 0,
    pending: 0,
    rejected: 0,
    live: 0,
    notes: 0,
    maxSeconds: 0,
  };

  sourceEntries.forEach(entry => {
    const seconds = options.getDurationSeconds(entry);
    const status = options.getStatus(entry);
    const projectCode = options.getProjectCode(entry);
    const overtimeCode = options.getOvertimeCode(entry);

    if (!projectBuckets[projectCode]) {
      const project = options.getProject(projectCode, entry);
      projectBuckets[projectCode] = {
        projectCode,
        projectName: project.projectName,
        colorKey: project.colorKey,
        count: 0,
        seconds: 0,
        approvedSeconds: 0,
        pending: 0,
        rejected: 0,
        live: 0,
        notes: 0,
        maxSeconds: 0,
        latestEntry: null,
        ...(options.includeProjectEntries ? { entries: [] } : {}),
        overtimeCodes: {},
      };
    }

    const projectBucket = projectBuckets[projectCode];
    if (options.includeProjectEntries) {
      projectBucket.entries.push(entry);
    }
    projectBucket.count += 1;
    projectBucket.seconds += seconds;
    projectBucket.maxSeconds = Math.max(projectBucket.maxSeconds, seconds);
    projectBucket.latestEntry = !projectBucket.latestEntry || options.getTimestamp(entry) > options.getTimestamp(projectBucket.latestEntry)
      ? entry
      : projectBucket.latestEntry;

    if (!projectBucket.overtimeCodes[overtimeCode]) {
      projectBucket.overtimeCodes[overtimeCode] = { code: overtimeCode, count: 0, seconds: 0 };
    }
    projectBucket.overtimeCodes[overtimeCode].count += 1;
    projectBucket.overtimeCodes[overtimeCode].seconds += seconds;

    if (!overtimeCodeBuckets[overtimeCode]) {
      overtimeCodeBuckets[overtimeCode] = { code: overtimeCode, count: 0, seconds: 0 };
    }
    overtimeCodeBuckets[overtimeCode].count += 1;
    overtimeCodeBuckets[overtimeCode].seconds += seconds;

    totals.seconds += seconds;
    totals.maxSeconds = Math.max(totals.maxSeconds, seconds);
    if (String(entry.message || "").trim()) {
      totals.notes += 1;
      projectBucket.notes += 1;
    }
    if (status === "approved") {
      totals.approvedSeconds += seconds;
      projectBucket.approvedSeconds += seconds;
    } else if (status === "pending") {
      totals.pending += 1;
      projectBucket.pending += 1;
    } else if (status === "rejected") {
      totals.rejected += 1;
      projectBucket.rejected += 1;
    } else if (status === "live") {
      totals.live += 1;
      projectBucket.live += 1;
    }
  });

  const summary = {
    totals,
    projects: Object.values(projectBuckets).sort((left, right) => right.seconds - left.seconds),
    topOvertimeCode: legacySelectTopBucket(overtimeCodeBuckets),
  };
  return options.includeSourceEntries
    ? { entries: sourceEntries, ...summary }
    : summary;
}

let forbiddenGlobalReads = 0;
const isolatedContext = {
  Array,
  Boolean,
  Math,
  Object,
  String,
  TypeError,
  window: {
    Saphir: {
      preservedNamespaceValue: "preserved",
    },
  },
};
for (const name of ["document", "fetch", "localStorage", "Date"]) {
  Object.defineProperty(isolatedContext, name, {
    get() {
      forbiddenGlobalReads += 1;
      throw new Error(`Entry statistics must not read ${name}.`);
    },
  });
  Object.defineProperty(isolatedContext.window, name, {
    get() {
      forbiddenGlobalReads += 1;
      throw new Error(`Entry statistics must not read window.${name}.`);
    },
  });
}

const entryStatsUtilitySource = sourceBetween(
  utilitiesSource,
  "(function initializeEntryStatsUtilities",
  "function toCalendarMonthKey",
);
vm.createContext(isolatedContext);
vm.runInContext(entryStatsUtilitySource, isolatedContext);

const entryStats = isolatedContext.window.Saphir.entryStats;
assert.equal(isolatedContext.window.Saphir.preservedNamespaceValue, "preserved", "The shared Saphir namespace must be preserved.");
assert.equal(Object.isFrozen(entryStats), true, "The entry statistics API must expose a stable surface.");
assert.deepEqual(Object.keys(entryStats).sort(), ["resolveStatus", "selectTopBucket", "summarize"]);
assert.equal(forbiddenGlobalReads, 0, "Initializing the pure statistics API touched a browser side effect or clock.");

assert.equal(entryStats.resolveStatus(null, () => false), "pending");
assert.equal(entryStats.resolveStatus({ status: "APPROVED" }, () => false), "approved");
assert.equal(entryStats.resolveStatus({ status: "approved" }, () => true), "live");
assert.equal(entryStats.selectTopBucket({}), null);

const tieBuckets = Object.freeze({
  first: Object.freeze({ code: "first", seconds: 3600, count: 1 }),
  second: Object.freeze({ code: "second", seconds: 3600, count: 2 }),
});
assert.equal(entryStats.selectTopBucket(tieBuckets), tieBuckets.second, "Count must break an equal-duration bucket tie.");
const stableTieBuckets = Object.freeze({
  first: Object.freeze({ code: "first", seconds: 3600, count: 2 }),
  second: Object.freeze({ code: "second", seconds: 3600, count: 2 }),
});
assert.equal(entryStats.selectTopBucket(stableTieBuckets), stableTieBuckets.first, "A complete tie must preserve insertion order.");

const projects = Object.freeze({
  P1: Object.freeze({ projectName: "Alpha", colorKey: "blue" }),
  P2: Object.freeze({ projectName: "Beta", colorKey: "mint" }),
  P3: Object.freeze({ projectName: "Gamma", colorKey: "purple" }),
});
const entries = Object.freeze([
  Object.freeze({ id: "a", status: "approved", projectCode: "P1", overtimeCode: "260", duration: 7200, timestamp: 100, message: "Révision" }),
  Object.freeze({ id: "b", status: "PENDING", projectCode: "P1", overtimeCode: "", duration: 3600, timestamp: 200, message: "  " }),
  Object.freeze({ id: "c", status: "rejected", projectCode: "", overtimeCode: "049", duration: 1800, timestamp: 150, message: "Note" }),
  Object.freeze({ id: "d", status: "approved", open: true, projectCode: "P2", overtimeCode: "049", duration: 900, timestamp: 300, message: "" }),
  Object.freeze({ id: "e", status: "other", projectCode: "P2", overtimeCode: "049", duration: 300, timestamp: 250, message: "" }),
  Object.freeze({ id: "f", status: "approved", projectCode: "P3", overtimeCode: "260", duration: 1800, timestamp: 100, message: "" }),
]);

const baseOptions = Object.freeze({
  getDurationSeconds(entry) {
    return entry.duration;
  },
  getStatus(entry) {
    return entryStats.resolveStatus(entry, candidate => Boolean(candidate && candidate.open));
  },
  getTimestamp(entry) {
    return entry.timestamp;
  },
  getProjectCode(entry) {
    return String(entry.projectCode || "").trim() || "__NO_PROJECT__";
  },
  getProject(projectCode, entry) {
    const rawProjectCode = String(entry.projectCode || "").trim();
    const project = projects[rawProjectCode];
    return {
      projectCode,
      projectName: project ? project.projectName : (rawProjectCode || "No project"),
      colorKey: project ? project.colorKey : `fallback:${projectCode}`,
    };
  },
  getOvertimeCode(entry) {
    return String(entry.overtimeCode || "").trim() || "Uncoded";
  },
});

function buildOptions(includeSourceEntries, includeProjectEntries) {
  return Object.freeze({
    ...baseOptions,
    includeSourceEntries,
    includeProjectEntries,
  });
}

for (const [label, source] of [["null", null], ["zero", []], ["singleton", entries.slice(0, 1)], ["multiple", entries]]) {
  for (const shape of [
    { label: "Self", includeSourceEntries: true, includeProjectEntries: false },
    { label: "Employees", includeSourceEntries: false, includeProjectEntries: true },
  ]) {
    const options = buildOptions(shape.includeSourceEntries, shape.includeProjectEntries);
    const beforeSource = JSON.stringify(source);
    const expected = legacySummarize(source, options);
    const first = entryStats.summarize(source, options);
    const second = entryStats.summarize(source, options);
    assert.deepEqual(plain(first), plain(expected), `${shape.label} ${label} statistics changed from the golden implementation.`);
    assert.deepEqual(plain(second), plain(expected), `${shape.label} ${label} statistics are not deterministic.`);
    assert.equal(JSON.stringify(source), beforeSource, `${shape.label} ${label} statistics mutated their entries.`);
  }
}

const selfModel = entryStats.summarize(entries, buildOptions(true, false));
const employeeModel = entryStats.summarize(entries, buildOptions(false, true));
assert.equal(selfModel.entries, entries, "The Self model must retain the exact filtered array reference.");
assert.equal(Object.prototype.hasOwnProperty.call(employeeModel, "entries"), false, "The employee model must not acquire a root entries property.");
assert.equal(Object.prototype.hasOwnProperty.call(selfModel.projects[0], "entries"), false, "Self project buckets must not acquire entry arrays.");
assert.equal(employeeModel.projects[0].entries[0], entries[0], "Employee project buckets must retain original entry references.");
assert.equal(selfModel.projects.find(project => project.projectCode === "P1").latestEntry, entries[1], "The latest project entry changed.");
assert.deepEqual(selfModel.projects.map(project => project.projectCode), ["P1", "__NO_PROJECT__", "P3", "P2"], "Equal project totals must keep insertion order.");
assert.deepEqual(plain(selfModel.totals), {
  count: 6,
  seconds: 15600,
  approvedSeconds: 9000,
  pending: 1,
  rejected: 1,
  live: 1,
  notes: 2,
  maxSeconds: 7200,
});
assert.deepEqual(plain(selfModel.topOvertimeCode), { code: "260", count: 2, seconds: 9000 });
assert.equal(forbiddenGlobalReads, 0, "Pure statistics calculations touched the DOM, fetch, storage, or clock.");

let projectDescriptionCalls = 0;
entryStats.summarize(entries, {
  ...buildOptions(false, false),
  getProject(projectCode, entry) {
    projectDescriptionCalls += 1;
    return baseOptions.getProject(projectCode, entry);
  },
});
assert.equal(projectDescriptionCalls, 4, "Project metadata must be resolved once per unique project bucket, not once per entry.");

for (const adapterName of ["getDurationSeconds", "getStatus", "getTimestamp", "getProjectCode", "getProject", "getOvertimeCode"]) {
  const incompleteOptions = { ...baseOptions };
  delete incompleteOptions[adapterName];
  assert.throws(
    () => entryStats.summarize([], incompleteOptions),
    new RegExp(adapterName),
    `A missing ${adapterName} adapter must fail explicitly.`,
  );
}

const selfStatusSource = sourceBetween(selfSource, "function getSelfStatsStatus", "function getSelfProjectName");
const selfTopSource = sourceBetween(selfSource, "function getTopSelfStatsBucket", "function buildSelfStatsModel");
const selfBuildSource = sourceBetween(selfSource, "function buildSelfStatsModel", "function renderSelfStats");
const employeeStatusSource = sourceBetween(employeesSource, "function getEmployeeStatsStatus", "function getTopEmployeeStatsBucket");
const employeeTopSource = sourceBetween(employeesSource, "function getTopEmployeeStatsBucket", "function buildEmployeeStatsModel");
const employeeBuildSource = sourceBetween(employeesSource, "function buildEmployeeStatsModel", "function buildEmployeeDetailedStatsMarkup");

for (const [label, source] of [["Self", selfBuildSource], ["Employees", employeeBuildSource]]) {
  assert.match(source, /window\.Saphir\.entryStats\.summarize\s*\(/, `${label} does not delegate to the shared summarizer.`);
  assert.doesNotMatch(source, /projectBuckets|overtimeCodeBuckets|\.forEach\s*\(/, `${label} still duplicates the aggregation loop.`);
}

function testFacadeDelegation(kind) {
  const isSelf = kind === "Self";
  const calls = { resolveStatus: [], selectTopBucket: [], summarize: [] };
  const summaryMarker = { source: `${kind}-summary` };
  const filteredEntries = [{ id: "filtered" }];
  const sourceEntries = [{ id: "source" }];
  const context = {
    String,
    getFilteredSelfStatsEntries() {
      return filteredEntries;
    },
    getEntryDurationSeconds(entry) {
      return entry.duration || 0;
    },
    toEntryDateTime(entry) {
      return entry.timestamp || 0;
    },
    isEntryOpen(entry) {
      return Boolean(entry && entry.open);
    },
    getSelfProjectByCode(code) {
      return code === "P1" ? { projectCode: code, projectName: "Alpha", colorKey: "blue" } : null;
    },
    getSelfProjectName(code) {
      return code === "P1" ? "Alpha" : code;
    },
    employeesViewState: {
      entryLookups: {
        projects: [{ projectCode: "P1", projectName: "Alpha", colorKey: "blue" }],
      },
    },
    findProjectByCode(projectList, code) {
      return (projectList || []).find(project => project.projectCode === code) || null;
    },
    getProjectDisplayName(project) {
      return project.projectName || project.projectCode;
    },
    getProjectColorKey(projectOrCode) {
      return typeof projectOrCode === "object" ? projectOrCode.colorKey : `fallback:${projectOrCode}`;
    },
    t(key) {
      return key === "shared.noProject" ? "No project" : "Uncoded";
    },
    window: {
      Saphir: {
        entryStats: {
          resolveStatus(...args) {
            calls.resolveStatus.push(args);
            return "resolved-status";
          },
          selectTopBucket(...args) {
            calls.selectTopBucket.push(args);
            return "selected-bucket";
          },
          summarize(...args) {
            calls.summarize.push(args);
            return summaryMarker;
          },
        },
      },
    },
  };
  vm.createContext(context);
  vm.runInContext([
    isSelf ? selfStatusSource : employeeStatusSource,
    isSelf ? selfTopSource : employeeTopSource,
    isSelf ? selfBuildSource : employeeBuildSource,
  ].join("\n\n"), context);

  const statusResult = context[isSelf ? "getSelfStatsStatus" : "getEmployeeStatsStatus"]({ open: true });
  const bucketInput = { one: { seconds: 1, count: 1 } };
  const bucketResult = context[isSelf ? "getTopSelfStatsBucket" : "getTopEmployeeStatsBucket"](bucketInput);
  const modelResult = context[isSelf ? "buildSelfStatsModel" : "buildEmployeeStatsModel"](sourceEntries);
  assert.equal(statusResult, "resolved-status");
  assert.equal(bucketResult, "selected-bucket");
  assert.equal(modelResult, summaryMarker);
  assert.equal(calls.resolveStatus.length, 1);
  assert.equal(calls.resolveStatus[0][1], context.isEntryOpen, `${kind} must inject its open-entry predicate.`);
  assert.equal(calls.selectTopBucket.length, 1);
  assert.equal(calls.selectTopBucket[0][0], bucketInput);
  assert.equal(calls.summarize.length, 1);
  assert.equal(calls.summarize[0][0], isSelf ? filteredEntries : sourceEntries);

  const options = calls.summarize[0][1];
  assert.equal(options.includeSourceEntries, isSelf);
  assert.equal(options.includeProjectEntries, !isSelf);
  assert.equal(options.getDurationSeconds, context.getEntryDurationSeconds);
  assert.equal(options.getTimestamp, context.toEntryDateTime);
  assert.equal(options.getProjectCode({ projectCode: "P1" }), "P1");
  assert.equal(options.getProjectCode({ projectCode: "" }), "__NO_PROJECT__");
  assert.deepEqual(plain(options.getProject("P1", { projectCode: "P1" })), {
    projectCode: "P1",
    projectName: "Alpha",
    colorKey: "blue",
  });
  assert.deepEqual(plain(options.getProject("__NO_PROJECT__", { projectCode: "" })), {
    projectCode: "__NO_PROJECT__",
    projectName: "No project",
    colorKey: "fallback:__NO_PROJECT__",
  });
  assert.equal(options.getOvertimeCode({ overtimeCode: "" }), "Uncoded");
}

testFacadeDelegation("Self");
testFacadeDelegation("Employees");

console.log("Frontend entry statistics boundary contracts passed.");
