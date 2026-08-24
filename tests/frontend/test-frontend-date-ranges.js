#!/usr/bin/env node

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const repoRoot = path.resolve(__dirname, "..", "..");
const read = relativePath => fs.readFileSync(path.join(repoRoot, relativePath), "utf8");
const utilitiesSource = read("app/frontend/scripts/Utilities.js");
const selfSource = read("app/frontend/scripts/Views/SelfView.js");
const projectsSource = read("app/frontend/scripts/Views/ProjectsView.js");

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

function legacyNormalizeDateInputValue(dateString) {
  const trimmed = String(dateString || "").trim();
  if (!trimmed) {
    return "";
  }

  const parts = trimmed.split("-").map(Number);
  if (parts.length < 3 || parts.some(Number.isNaN)) {
    return "";
  }

  const date = new Date(parts[0], parts[1] - 1, parts[2]);
  return Number.isNaN(date.getTime()) ? "" : trimmed;
}

function legacyLocalDateInputValue(date) {
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
}

function legacySelfDateRange(range, customRange, now) {
  const normalizedRange = range || "month";

  if (normalizedRange === "custom") {
    return {
      startDate: legacyNormalizeDateInputValue(customRange.startDate),
      endDate: legacyNormalizeDateInputValue(customRange.endDate),
    };
  }

  if (normalizedRange === "year") {
    return {
      startDate: legacyLocalDateInputValue(new Date(now.getFullYear(), 0, 1)),
      endDate: legacyLocalDateInputValue(now),
    };
  }

  if (normalizedRange === "month") {
    return {
      startDate: legacyLocalDateInputValue(new Date(now.getFullYear(), now.getMonth(), 1)),
      endDate: legacyLocalDateInputValue(now),
    };
  }

  return { startDate: "", endDate: "" };
}

function legacyProjectDateRange(filterPeriod, customRange, now) {
  const normalizedFilter = filterPeriod || "all";
  const endDate = now.toISOString().split("T")[0];
  let startDate = "";
  let resolvedEndDate = endDate;

  switch (normalizedFilter) {
    case "1M":
      startDate = new Date(now.getFullYear(), now.getMonth(), 1).toISOString().split("T")[0];
      break;
    case "6M":
      startDate = new Date(now.getFullYear(), now.getMonth() - 6, 1).toISOString().split("T")[0];
      break;
    case "1Y":
      startDate = new Date(now.getFullYear() - 1, now.getMonth(), now.getDate()).toISOString().split("T")[0];
      break;
    case "custom":
      startDate = legacyNormalizeDateInputValue(customRange.startDate);
      resolvedEndDate = legacyNormalizeDateInputValue(customRange.endDate);
      break;
    case "all":
    default:
      startDate = "";
      resolvedEndDate = "";
      break;
  }

  return { startDate, endDate: resolvedEndDate };
}

const isolatedContext = {
  Array,
  Date,
  Number,
  Object,
  String,
  TypeError,
  window: {
    Saphir: {
      preservedNamespaceValue: "preserved",
    },
  },
};
let forbiddenGlobalReads = 0;
Object.defineProperty(isolatedContext, "document", {
  get() {
    forbiddenGlobalReads += 1;
    throw new Error("Date-range utilities must not read the DOM.");
  },
});
Object.defineProperty(isolatedContext, "fetch", {
  get() {
    forbiddenGlobalReads += 1;
    throw new Error("Date-range utilities must not read fetch.");
  },
});
Object.defineProperty(isolatedContext.window, "document", {
  get() {
    forbiddenGlobalReads += 1;
    throw new Error("Date-range utilities must not read window.document.");
  },
});
Object.defineProperty(isolatedContext.window, "fetch", {
  get() {
    forbiddenGlobalReads += 1;
    throw new Error("Date-range utilities must not read window.fetch.");
  },
});

const dateRangeUtilitySource = sourceBetween(
  utilitiesSource,
  "function parseLocalDate",
  "function toCalendarMonthKey",
);
vm.createContext(isolatedContext);
vm.runInContext(dateRangeUtilitySource, isolatedContext);

const dateRanges = isolatedContext.window.Saphir.dateRanges;
assert.equal(isolatedContext.window.Saphir.preservedNamespaceValue, "preserved", "The shared Saphir namespace must be preserved.");
assert.equal(Object.isFrozen(dateRanges), true, "The date-range API must expose a stable surface.");
assert.deepEqual(Object.keys(dateRanges).sort(), ["resolveProjects", "resolveSelf"]);

const referenceDates = [
  new Date(2026, 7, 17, 14, 30, 0),
  new Date(2026, 0, 1, 0, 30, 0),
  new Date(2024, 1, 29, 23, 30, 0),
  new Date(2026, 11, 31, 23, 59, 59),
];
const customRanges = [
  Object.freeze({ startDate: "2026-01-02", endDate: "2026-08-17" }),
  Object.freeze({ startDate: " 2024-02-29 ", endDate: "invalid" }),
  Object.freeze({ startDate: "", endDate: "" }),
];

referenceDates.forEach(now => {
  [undefined, "", "month", "year", "all", "unexpected"].forEach(range => {
    const customRange = customRanges[0];
    const beforeRange = JSON.stringify(customRange);
    const beforeTime = now.getTime();
    const expected = legacySelfDateRange(range, customRange, now);
    const first = dateRanges.resolveSelf(range, customRange, now);
    const second = dateRanges.resolveSelf(range, customRange, now);
    assert.deepEqual(plain(first), expected, `Self range ${String(range)} changed for ${now.toISOString()}.`);
    assert.deepEqual(plain(second), expected, "The same Self inputs must return the same range.");
    assert.equal(JSON.stringify(customRange), beforeRange, "Self custom input was mutated.");
    assert.equal(now.getTime(), beforeTime, "Self reference clock was mutated.");
  });

  customRanges.forEach(customRange => {
    const beforeRange = JSON.stringify(customRange);
    assert.deepEqual(
      plain(dateRanges.resolveSelf("custom", customRange, now)),
      legacySelfDateRange("custom", customRange, now),
    );
    assert.equal(JSON.stringify(customRange), beforeRange, "Self custom input was mutated.");
  });

  [undefined, "", "1M", "6M", "1Y", "all", "unexpected"].forEach(filterPeriod => {
    const customRange = customRanges[0];
    const beforeRange = JSON.stringify(customRange);
    const beforeTime = now.getTime();
    const expected = legacyProjectDateRange(filterPeriod, customRange, now);
    const first = dateRanges.resolveProjects(filterPeriod, customRange, now);
    const second = dateRanges.resolveProjects(filterPeriod, customRange, now);
    assert.deepEqual(plain(first), expected, `Project range ${String(filterPeriod)} changed for ${now.toISOString()}.`);
    assert.deepEqual(plain(second), expected, "The same Project inputs must return the same range.");
    assert.equal(JSON.stringify(customRange), beforeRange, "Project custom input was mutated.");
    assert.equal(now.getTime(), beforeTime, "Project reference clock was mutated.");
  });

  customRanges.forEach(customRange => {
    const beforeRange = JSON.stringify(customRange);
    assert.deepEqual(
      plain(dateRanges.resolveProjects("custom", customRange, now)),
      legacyProjectDateRange("custom", customRange, now),
    );
    assert.equal(JSON.stringify(customRange), beforeRange, "Project custom input was mutated.");
  });
});

assert.throws(() => dateRanges.resolveSelf("month", {}, "not-a-date"), /valid reference date/);
assert.throws(() => dateRanges.resolveProjects("1M", {}, "not-a-date"), /valid reference date/);
assert.equal(forbiddenGlobalReads, 0, "Pure date-range calculations touched a browser side effect.");

assert.doesNotMatch(selfSource, /function toSelfDateInputValue\s*\(/, "The duplicate Self date formatter still exists.");
const selfFacadeSource = sourceBetween(selfSource, "function getSelfStatsDateRange", "function getSelfStatsStatus");
assert.match(selfFacadeSource, /window\.Saphir\.dateRanges\.resolveSelf\s*\(/);
assert.doesNotMatch(selfFacadeSource, /getFullYear|getMonth|normalizeDateInputValue/, "The Self facade still owns range logic.");

const projectFacadeSource = sourceBetween(projectsSource, "function calculateDateRange", "function getProjectAnalyticsExportLocale");
assert.match(projectFacadeSource, /window\.Saphir\.dateRanges\.resolveProjects\s*\(/);
assert.doesNotMatch(projectFacadeSource, /toISOString|getFullYear|getMonth|normalizeDateInputValue/, "The Projects facade still owns range logic.");

class FixedDate extends Date {
  constructor(...args) {
    super(...(args.length ? args : ["2026-08-17T14:30:00Z"]));
  }
}

const selfCalls = [];
const selfMarker = { source: "self-resolver" };
const selfFacadeContext = {
  Date: FixedDate,
  selfViewState: {
    statsFilter: { range: "year", startDate: "2026-01-01", endDate: "2026-08-17" },
  },
  window: {
    Saphir: {
      dateRanges: {
        resolveSelf(...args) {
          selfCalls.push(args);
          return selfMarker;
        },
      },
    },
  },
};
vm.createContext(selfFacadeContext);
vm.runInContext(`${selfFacadeSource}\nthis.result = getSelfStatsDateRange();`, selfFacadeContext);
assert.equal(selfFacadeContext.result, selfMarker);
assert.equal(selfCalls.length, 1);
assert.equal(selfCalls[0][0], "year");
assert.equal(selfCalls[0][1], selfFacadeContext.selfViewState.statsFilter);
assert.equal(selfCalls[0][2].toISOString(), "2026-08-17T14:30:00.000Z");

const projectCalls = [];
const projectMarker = { source: "project-resolver" };
const projectFacadeContext = {
  Date: FixedDate,
  currentProjectFilter: "6M",
  projectsViewState: {
    customRange: { startDate: "2026-02-01", endDate: "2026-08-17" },
  },
  window: {
    Saphir: {
      dateRanges: {
        resolveProjects(...args) {
          projectCalls.push(args);
          return projectMarker;
        },
      },
    },
  },
};
vm.createContext(projectFacadeContext);
vm.runInContext(`${projectFacadeSource}\nthis.result = calculateDateRange();`, projectFacadeContext);
assert.equal(projectFacadeContext.result, projectMarker);
assert.equal(projectCalls.length, 1);
assert.equal(projectCalls[0][0], "6M", "The Projects facade must preserve its current-filter fallback.");
assert.equal(projectCalls[0][1], projectFacadeContext.projectsViewState.customRange);
assert.equal(projectCalls[0][2].toISOString(), "2026-08-17T14:30:00.000Z");

console.log("Frontend date-range boundary contracts passed.");
