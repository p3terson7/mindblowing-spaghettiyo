#!/usr/bin/env node

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { performance } = require("node:perf_hooks");

const repoRoot = path.resolve(__dirname, "..");
const viewPath = path.join(repoRoot, "apps/admin/frontend/scripts/Views/EmployeesView.js");
const source = fs.readFileSync(viewPath, "utf8");

function sourceBetween(startMarker, endMarker) {
  const start = source.indexOf(startMarker);
  const end = source.indexOf(endMarker, start + startMarker.length);
  assert.notEqual(start, -1, `Unable to find ${startMarker}`);
  assert.notEqual(end, -1, `Unable to find ${endMarker}`);
  return source.slice(start, end).trim();
}

const helperSource = [
  sourceBetween("function getEmployeeStatsProjectEntries", "function hydrateEmployeeProjectEntryDisclosure"),
  sourceBetween("function hydrateEmployeeProjectEntryDisclosure", "async function fetchEmployeeDetailEntries"),
].join("\n\n");

const entries = Array.from({ length: 10000 }, (_, index) => ({
  entryId: `entry-${index}`,
  date: `2026-${String((index % 12) + 1).padStart(2, "0")}-${String((index % 28) + 1).padStart(2, "0")}`,
  punchIn: `${String(index % 24).padStart(2, "0")}:00`,
  projectCode: index % 101 === 0 ? "" : `P-${String(index % 100).padStart(3, "0")}`,
}));

let renderedRowCount = 0;
let renderCallCount = 0;
function renderSyntheticRows(projectEntries, employeeCode) {
  renderCallCount += 1;
  renderedRowCount += projectEntries.length;
  return [...projectEntries]
    .sort((left, right) => right.date.localeCompare(left.date) || right.punchIn.localeCompare(left.punchIn))
    .map(entry => `<article data-employee="${employeeCode}" data-entry="${entry.entryId}">${entry.date}|${entry.punchIn}</article>`)
    .join("");
}

const context = {
  getVisibleEmployeeEntries: employeeCode => employeeCode === "EMP-1" ? entries : [],
  renderPeopleProjectEntryRows: renderSyntheticRows,
};
vm.createContext(context);
vm.runInContext(`${helperSource}\nthis.lazyHelpers = { getEmployeeStatsProjectEntries, hydrateEmployeeProjectEntryDisclosure };`, context);

function createDisclosure({ open = false, employeeCode = "EMP-1", projectCode = "P-007" } = {}) {
  const attributes = new Map([
    ["data-employee-code", employeeCode],
    ["data-project-code", projectCode],
  ]);
  const listAttributes = new Map([["data-entries-loaded", "false"]]);
  const list = {
    innerHTML: "",
    getAttribute(name) {
      return listAttributes.get(name) || null;
    },
    setAttribute(name, value) {
      listAttributes.set(name, String(value));
    },
  };
  return {
    open,
    list,
    getAttribute(name) {
      return attributes.get(name) || null;
    },
    querySelector(selector) {
      return selector === "[data-employee-project-entry-list]" ? list : null;
    },
  };
}

const disclosure = createDisclosure();
assert.equal(context.lazyHelpers.hydrateEmployeeProjectEntryDisclosure(disclosure), false, "collapsed disclosure must stay empty");
assert.equal(renderCallCount, 0, "collapsed disclosure must not render rows");
assert.equal(disclosure.list.innerHTML, "");

disclosure.open = true;
assert.equal(context.lazyHelpers.hydrateEmployeeProjectEntryDisclosure(disclosure), true, "first open must render rows");
assert.equal(renderCallCount, 1);
const selectedProjectEntryCount = entries.filter(entry => entry.projectCode === "P-007").length;
assert.equal(renderedRowCount, selectedProjectEntryCount);
assert.match(disclosure.list.innerHTML, /data-entry="entry-7"/);
assert.equal(disclosure.list.getAttribute("data-entries-loaded"), "true");

assert.equal(context.lazyHelpers.hydrateEmployeeProjectEntryDisclosure(disclosure), false, "already-loaded disclosure must not rerender");
assert.equal(renderCallCount, 1);

const uncodedDisclosure = createDisclosure({ open: true, projectCode: "__NO_PROJECT__" });
assert.equal(context.lazyHelpers.hydrateEmployeeProjectEntryDisclosure(uncodedDisclosure), true);
const uncodedEntryCount = entries.filter(entry => !entry.projectCode).length;
assert.equal(renderedRowCount, selectedProjectEntryCount + uncodedEntryCount, "uncoded entries must remain addressable by the synthetic project key");

assert.match(source, /shouldOpenEntries \? renderPeopleProjectEntryRows\(project\.entries, employeeCode\) : ""/, "auto-opened project must render immediately");
assert.match(source, /addEventListener\("toggle",[\s\S]*hydrateEmployeeProjectEntryDisclosure\(disclosure\);[\s\S]*}, true\);/, "toggle lifecycle listener must use capture");

const projectGroups = new Map();
entries.forEach(entry => {
  const projectCode = String(entry.projectCode || "").trim() || "__NO_PROJECT__";
  if (!projectGroups.has(projectCode)) {
    projectGroups.set(projectCode, []);
  }
  projectGroups.get(projectCode).push(entry);
});

function median(values) {
  const sorted = [...values].sort((left, right) => left - right);
  return sorted[Math.floor(sorted.length / 2)];
}

function measure(action, iterations = 9) {
  const samples = [];
  let result;
  action();
  for (let index = 0; index < iterations; index += 1) {
    const startedAt = performance.now();
    result = action();
    samples.push(performance.now() - startedAt);
  }
  return { milliseconds: median(samples), result, runs: iterations + 1 };
}

function renderLegacyCollapsedDetails() {
  return Array.from(projectGroups, ([projectCode, projectEntries]) => (
    `<details data-project="${projectCode}"><summary>${projectEntries.length}</summary>${renderSyntheticRows(projectEntries, "EMP-1")}</details>`
  )).join("");
}

function renderLazyCollapsedDetails() {
  return Array.from(projectGroups, ([projectCode, projectEntries]) => (
    `<details data-project="${projectCode}"><summary>${projectEntries.length}</summary><div data-entries-loaded="false"></div></details>`
  )).join("");
}

renderCallCount = 0;
renderedRowCount = 0;
const legacy = measure(renderLegacyCollapsedDetails);
const legacyRenderedRows = renderedRowCount / legacy.runs;
renderCallCount = 0;
renderedRowCount = 0;
const lazy = measure(renderLazyCollapsedDetails);

assert.equal(legacyRenderedRows, entries.length, "legacy fixture must render every hidden row per run");
assert.equal(renderedRowCount, 0, "lazy fixture must render no hidden rows");
assert.ok(lazy.result.length < legacy.result.length / 20, "lazy collapsed markup should be materially smaller");

console.log("Employee detail lazy-disclosure test passed.");
console.log(`Synthetic initial render (10,000 entries / ${projectGroups.size} projects): ${legacy.milliseconds.toFixed(2)} ms legacy vs ${lazy.milliseconds.toFixed(2)} ms lazy.`);
console.log(`Mounted entry rows: ${entries.length} legacy vs 0 lazy; HTML: ${(legacy.result.length / 1024).toFixed(1)} KiB vs ${(lazy.result.length / 1024).toFixed(1)} KiB.`);
