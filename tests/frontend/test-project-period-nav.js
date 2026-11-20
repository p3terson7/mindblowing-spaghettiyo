const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const read = name => fs.readFileSync(path.resolve(__dirname, "../..", name), "utf8");
const html = read("app/frontend/index.html");
const source = read("app/frontend/scripts/Views/ProjectsView.js");
const css = read("app/frontend/assets/apple-ui.css");
const navStart = html.indexOf('<nav id="projectPeriodNav"');
const navEnd = html.indexOf("</nav>", navStart);
assert(navStart > html.indexOf('id="projectsView"'));
assert(navEnd < html.indexOf('id="projectPortfolioWorkspace"'), "Period must be shared by the portfolio and project detail.");
for (const id of ["projectPeriodNav", "projectCustomFilterPanel", "projectStartDate", "projectEndDate", "projectQuickRangeButtons"]) {
  assert.equal(html.split(`id="${id}"`).length - 1, 1, `There must be exactly one ${id}.`);
}
assert(!source.includes("projectWorkspaceRangeSelect") && !html.includes("projectWorkspaceRangeSelect"), "The duplicate workspace selector must be removed.");
assert(!source.includes("projects.customRangeInPortfolio"), "Custom dates must not require returning to the portfolio.");
assert.match(css, /\.project-period-nav\s*\{[^}]*position: sticky;[^}]*top: calc\(var\(--project-nav-offset/);
const navStyle = css.match(/\.project-period-nav\s*\{([^}]+)\}/)[1];
assert(navStyle.includes("width: fit-content;") && navStyle.includes("display: flex;"), "Period controls must form a compact left-aligned group, not a full-width grid.");
assert(!html.slice(navStart, navEnd).includes('data-i18n="filters.period"'), "The period navigation must show only the calendar icon, without a repeated Period label.");
assert(!/addEventListener\(["']scroll["']/.test(source), "Sticky positioning must not add a per-scroll handler.");
assert(!/resizeDelay:\s*[1-9]/.test(source), "A delayed chart update must not outlive the chart destroyed by a period change.");

function node() {
  return { classes: {}, attributes: {}, style: { values: {}, setProperty(key, value) { this.values[key] = value; } },
    classList: { toggle(key, value) { this.owner.classes[key] = value; } },
    setAttribute(key, value) { this.attributes[key] = value; } };
}
const panel = node(); panel.classList.owner = panel;
const label = { textContent: "" };
const buttons = ["1M", "6M", "1Y", "all"].map(range => {
  const button = node(); button.classList.owner = button;
  button.getAttribute = () => range;
  return button;
});
const context = { currentProjectFilter: "1M", formatProjectPeriodDate: value => value, t: key => key,
  calculateDateRange: range => range === "all" ? {} : range === "custom" ? { endDate: "2026-05-31" } : { startDate: "2026-11-01", endDate: "2026-11-30" },
  document: { querySelectorAll: () => buttons, getElementById: id => id === "projectPeriodRangeLabel" ? label : panel },
};
vm.createContext(context);
vm.runInContext(source.slice(source.indexOf("function syncProjectRangeButtons()"), source.indexOf("function closeProjectPeriodEditor()")), context);
context.syncProjectRangeButtons();
assert.equal(buttons[0].attributes["aria-pressed"], "true");
assert(buttons.slice(1).every(button => button.attributes["aria-pressed"] === "false"));
assert.equal(label.textContent, "2026-11-01 – 2026-11-30");
context.currentProjectFilter = "custom";
context.syncProjectRangeButtons();
assert.equal(label.textContent, "… – 2026-05-31");
assert(panel.classes["is-custom"]);
assert(buttons.every(button => button.attributes["aria-pressed"] === "false"));
context.currentProjectFilter = "all";
context.syncProjectRangeButtons();
assert.equal(label.textContent, "projects.range.custom");
assert(!panel.classes["is-custom"]);
assert.equal(buttons[3].attributes["aria-pressed"], "true");

const nav = node(), view = node();
let headerHeight = 64, observerCallback;
const chrome = { getBoundingClientRect: () => ({ height: headerHeight }) };
nav.getBoundingClientRect = () => ({ height: 48 });
const listeners = {};
panel.addEventListener = (name, fn) => { listeners[name] = fn; };
let focused = false;
panel.querySelector = () => ({ focus: options => { focused = options.preventScroll; } });
const layout = {
  document: { getElementById: id => ({ projectPeriodNav: nav, projectsView: view, projectCustomFilterPanel: panel })[id], querySelector: () => chrome },
  ResizeObserver: function (callback) { observerCallback = callback; this.observe = () => {}; },
};
vm.createContext(layout);
vm.runInContext(source.slice(source.indexOf("function initializeProjectPeriodNav()"), source.indexOf("function getMatchingPresetProjectRange(")), layout);
layout.initializeProjectPeriodNav();
assert.equal(nav.style.values["--project-nav-offset"], "64px");
headerHeight = 92;
observerCallback();
assert.equal(nav.style.values["--project-nav-offset"], "92px", "Sticky offset must follow the actual application navigation height.");
panel.open = true;
listeners.keydown({ key: "Escape", currentTarget: panel });
assert.equal(panel.open, false);
assert(focused, "Escape must restore focus without scrolling.");
console.log("Project period navigation passed: single global filter, active states, exact dates, responsive offset and keyboard dismissal.");
