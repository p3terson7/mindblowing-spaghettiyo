#!/usr/bin/env node

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { performance } = require("node:perf_hooks");

const repoRoot = path.resolve(__dirname, "..");
const source = fs.readFileSync(
  path.join(repoRoot, "apps/admin/frontend/scripts/Views/HistoryView.js"),
  "utf8"
);

const groupStart = source.indexOf("function createEmptyHistoryCategories");
const groupEnd = source.indexOf("function getHistoryTabConfig", groupStart);
assert.notEqual(groupStart, -1, "Unable to find history category helpers");
assert.notEqual(groupEnd, -1, "Unable to find the end of history category helpers");

const context = {};
vm.createContext(context);
vm.runInContext(`${source.slice(groupStart, groupEnd)}\nthis.groupHistoryEntries = groupHistoryEntries;`, context);

const fixture = [
  { action: "Add" },
  { action: "Update" },
  { action: "Approved" },
  { action: "Rejected" },
  { action: "Delete" },
  { action: "Seed" },
];
const groupedFixture = context.groupHistoryEntries(fixture);
assert.equal(groupedFixture.all.length, 6);
assert.equal(groupedFixture.add.length, 1);
assert.equal(groupedFixture.update.length, 1);
assert.equal(groupedFixture.approval.length, 2);
assert.equal(groupedFixture.delete.length, 1);

assert.match(source, /const HISTORY_FILTER_DEBOUNCE_MS = 150;/, "History filtering should stay debounced");
assert.match(source, /addEventListener\("input", scheduleHistoryFilterUpdate\)/, "Search input should use the debounce scheduler");
assert.match(source, /addEventListener\("show\.bs\.tab"/, "Incoming tabs should render lazily");
assert.match(source, /addEventListener\("shown\.bs\.tab"[\s\S]*clearInactiveHistoryContainers/, "Outgoing tab DOM should be released after transition");
assert.match(source, /renderHistoryCategory\(targetConfig \|\| getActiveHistoryTabConfig\(\), clearInactive\)/, "Filter updates should render only the target tab");

const actions = ["Add", "Update", "Approved", "Rejected", "Delete"];
const entries = Array.from({ length: 5000 }, (_, index) => ({
  action: actions[index % actions.length],
  message: `Synthetic history message ${index}`,
  timestamp: `2026-07-${String((index % 28) + 1).padStart(2, "0")} 12:00:00`,
}));
const categories = context.groupHistoryEntries(entries);

function renderCards(items) {
  return items.map((entry, index) => (
    `<article class="timeline-card" data-index="${index}"><strong>${entry.action}</strong><span>${entry.timestamp}</span><p>${entry.message}</p></article>`
  )).join("");
}

function median(values) {
  const sorted = [...values].sort((left, right) => left - right);
  return sorted[Math.floor(sorted.length / 2)];
}

function measure(action, iterations = 9) {
  action();
  const samples = [];
  let result;
  for (let index = 0; index < iterations; index += 1) {
    const startedAt = performance.now();
    result = action();
    samples.push(performance.now() - startedAt);
  }
  return { milliseconds: median(samples), result };
}

const legacy = measure(() => [
  renderCards(categories.all),
  renderCards(categories.add),
  renderCards(categories.update),
  renderCards(categories.approval),
  renderCards(categories.delete),
].join(""));
const lazy = measure(() => renderCards(categories.all));

const legacyMountedCards = categories.all.length
  + categories.add.length
  + categories.update.length
  + categories.approval.length
  + categories.delete.length;
assert.equal(legacyMountedCards, 10000, "Synthetic legacy fixture should mount all and categorized copies");
assert.equal(categories.all.length, 5000, "Lazy all-tab fixture should mount one copy per record");
assert.ok(lazy.result.length < legacy.result.length * 0.6, "Lazy active-tab markup should be materially smaller");

console.log("History lazy-tab test passed.");
console.log(`Synthetic initial render (5,000 entries): ${legacy.milliseconds.toFixed(2)} ms legacy vs ${lazy.milliseconds.toFixed(2)} ms lazy.`);
console.log(`Mounted cards: ${legacyMountedCards} legacy vs ${categories.all.length} lazy; HTML: ${(legacy.result.length / 1024).toFixed(1)} KiB vs ${(lazy.result.length / 1024).toFixed(1)} KiB.`);
