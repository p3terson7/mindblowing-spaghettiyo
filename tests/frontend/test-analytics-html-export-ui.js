const assert = require("assert");
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const repoRoot = path.resolve(__dirname, "..", "..");
const read = relativePath => fs.readFileSync(path.join(repoRoot, relativePath), "utf8");

const projectsSource = read("app/frontend/scripts/Views/ProjectsView.js");
const utilitiesSource = read("app/frontend/scripts/Utilities.js");
const indexSource = read("app/frontend/index.html");
const i18nSource = read("app/frontend/scripts/I18n.js");
const appShellSource = read("app/frontend/scripts/AppShell.js");

assert(indexSource.includes('id="projectAnalyticsExportButton"'), "The project analytics HTML export button is missing.");
assert(indexSource.includes('aria-describedby="projectAnalyticsExportHint"'), "The analytics export control does not explain which period it uses.");
assert(indexSource.includes('data-i18n="projects.exportAnalyticsHtml"'), "The analytics export button is not localized.");
assert(indexSource.includes('data-i18n="projects.analyticsExportHint"'), "The analytics export range hint is not localized.");

for (const translationKey of [
  "projects.exportAnalyticsHtml",
  "projects.analyticsExportHint",
  "projects.analyticsExportSuccess",
  "projects.analyticsExportError",
]) {
  const occurrences = i18nSource.split(`"${translationKey}"`).length - 1;
  assert.strictEqual(occurrences, 2, `${translationKey} must have English and French translations.`);
}

const helperStart = projectsSource.indexOf("function calculateDateRange");
const helperEnd = projectsSource.indexOf("function syncProjectCustomRangeInputs", helperStart);
assert(helperStart >= 0 && helperEnd > helperStart, "Unable to locate the analytics export range helpers.");
const dateRangeUtilityStart = utilitiesSource.indexOf("function parseLocalDate");
const dateRangeUtilityEnd = utilitiesSource.indexOf("function toCalendarMonthKey", dateRangeUtilityStart);
assert(dateRangeUtilityStart >= 0 && dateRangeUtilityEnd > dateRangeUtilityStart, "Unable to locate the shared date-range utilities.");

const localeState = { value: "fr-CA" };
const context = {
  URLSearchParams,
  apiUrl: "http://localhost:8081/",
  currentProjectFilter: "custom",
  projectsViewState: {
    customRange: {
      startDate: "2026-02-01",
      endDate: "2026-07-31",
    },
  },
  getCurrentLocale: () => localeState.value,
  window: { Saphir: {} },
};
vm.createContext(context);
vm.runInContext(`${utilitiesSource.slice(dateRangeUtilityStart, dateRangeUtilityEnd)}
${projectsSource.slice(helperStart, helperEnd)}
this.getProjectAnalyticsExportLocale = getProjectAnalyticsExportLocale;
this.buildProjectAnalyticsExportUrl = buildProjectAnalyticsExportUrl;
this.getProjectAnalyticsExportFallbackFilename = getProjectAnalyticsExportFallbackFilename;
this.sanitizeProjectAnalyticsExportFilename = sanitizeProjectAnalyticsExportFilename;
this.getProjectAnalyticsExportFilename = getProjectAnalyticsExportFilename;`, context);

assert.strictEqual(context.getProjectAnalyticsExportLocale(), "fr", "fr-CA must be normalized to the backend's fr locale.");
assert.strictEqual(
  context.buildProjectAnalyticsExportUrl("custom"),
  "http://localhost:8081/stats/analytics-export?startDate=2026-02-01&endDate=2026-07-31&locale=fr",
  "The export URL must reuse the applied custom project period."
);
assert.strictEqual(
  context.getProjectAnalyticsExportFallbackFilename("custom"),
  "saphir-analytics-2026-02-01_2026-07-31.html",
  "The fallback report filename must identify the selected period."
);

localeState.value = "en-CA";
assert.strictEqual(context.getProjectAnalyticsExportLocale(), "en", "Non-French locales must use the backend's en locale.");
assert.strictEqual(
  context.buildProjectAnalyticsExportUrl("all"),
  "http://localhost:8081/stats/analytics-export?locale=en",
  "The all-time export must omit bounded dates."
);

const encodedFilenameResponse = {
  headers: {
    get: name => name === "Content-Disposition"
      ? "attachment; filename*=UTF-8''SAPHIR-rapport%20ao%C3%BBt.html"
      : "",
  },
};
assert.strictEqual(
  context.getProjectAnalyticsExportFilename(encodedFilenameResponse, "fallback.html"),
  "SAPHIR-rapport août.html",
  "UTF-8 report filenames from Content-Disposition must be decoded."
);
assert.strictEqual(
  context.sanitizeProjectAnalyticsExportFilename("../../unsafe/report", "fallback.html"),
  "-..-unsafe-report.html",
  "Downloaded report filenames must not retain path separators."
);

assert(
  /async function downloadProjectAnalyticsHtmlReport[\s\S]*?fetch\(buildProjectAnalyticsExportUrl[\s\S]*?cache: "no-store"[\s\S]*?Accept: "text\/html"[\s\S]*?response\.blob\(\)[\s\S]*?triggerProjectAnalyticsExportDownload/.test(projectsSource),
  "The analytics export must fetch the authenticated report as an HTML blob."
);
assert(
  /projectAnalyticsExportButton[\s\S]*?runButtonAction\(event\.currentTarget[\s\S]*?key: "project-analytics-html-export"/.test(projectsSource),
  "The analytics export does not use the shared busy-button workflow."
);
assert(projectsSource.includes('link.download = filename;'), "The HTML report is not handed to the browser as a download.");
assert(indexSource.includes("scripts/I18n.js?v=20260824-review-attention-tab-v1"), "The localized export UI cache key was not bumped.");
assert(indexSource.includes("scripts/AppShell.js?v=20260824-review-attention-tab-v1"), "The application shell cache key was not bumped.");
assert(appShellSource.includes("ProjectsView.js?v=20260824-review-attention-tab-v1"), "The project view cache key was not bumped.");

console.log("Analytics HTML export UI contract test passed.");
