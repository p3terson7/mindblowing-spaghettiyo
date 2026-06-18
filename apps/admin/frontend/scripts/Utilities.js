function escapeHtml(value) {
  return String(value == null ? "" : value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/\"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function timeRangeArrowIconMarkup() {
  return '<i class="fa-solid fa-arrow-right-long time-range-arrow" aria-hidden="true"></i>';
}

function timeRangeArrowText() {
  return "→";
}

function buildTimeRangeText(start, end) {
  return `${start} ${timeRangeArrowText()} ${end}`;
}

function buildTimeRangeMarkup(start, end) {
  return `${escapeHtml(start)} ${timeRangeArrowIconMarkup()} ${escapeHtml(end)}`;
}

function getCurrentLocale() {
  if (typeof window.getI18nLocale === "function") {
    return window.getI18nLocale();
  }
  return undefined;
}

function filterEntries(entries, searchTerm) {
  const tokens = String(searchTerm || "").toLowerCase().split(/\s+/).filter(token => token.length > 0);
  if (tokens.length === 0) {
    return entries;
  }

  return entries.filter(entry => {
    const combinedText = [
      entry.employeeName,
      entry.employeeCode,
      entry.date,
      formatDateToWords(entry.date),
      entry.projectCode,
      entry.overtimeCode,
      entry.paymentOption,
      entry.reasonCode,
      entry.entryType,
      entry.diverseReason,
      entry.diverseSummary,
      getEntryStatusLabel(entry),
      entry.message,
    ].join(" ").toLowerCase();

    return tokens.every(token => combinedText.includes(token));
  });
}

function formatTimeString(timeStr) {
  if (!timeStr) {
    return "--:--";
  }

  const parts = String(timeStr).split(":");
  if (parts.length < 2) {
    return String(timeStr);
  }

  return `${parts[0].padStart(2, "0")}:${parts[1].padStart(2, "0")}`;
}

function normalizeTime(timeString) {
  return timeString ? String(timeString).slice(0, 5) : "";
}

function parseLocalDate(dateString) {
  const parts = String(dateString || "").split("-").map(Number);
  if (parts.length < 3 || parts.some(Number.isNaN)) {
    return null;
  }

  const date = new Date(parts[0], parts[1] - 1, parts[2]);
  return Number.isNaN(date.getTime()) ? null : date;
}

function normalizeDateInputValue(dateString) {
  const trimmed = String(dateString || "").trim();
  if (!trimmed) {
    return "";
  }

  const parsedDate = parseLocalDate(trimmed);
  if (!parsedDate) {
    return "";
  }

  return trimmed;
}

function isDateWithinRange(dateString, startDate, endDate) {
  const entryDate = parseLocalDate(dateString);
  if (!entryDate) {
    return false;
  }

  const normalizedStartDate = normalizeDateInputValue(startDate);
  if (normalizedStartDate) {
    const start = parseLocalDate(normalizedStartDate);
    if (start && entryDate < start) {
      return false;
    }
  }

  const normalizedEndDate = normalizeDateInputValue(endDate);
  if (normalizedEndDate) {
    const end = parseLocalDate(normalizedEndDate);
    if (end && entryDate > end) {
      return false;
    }
  }

  return true;
}

function buildDateRangeLabel(startDate, endDate) {
  const normalizedStart = normalizeDateInputValue(startDate);
  const normalizedEnd = normalizeDateInputValue(endDate);

  if (normalizedStart && normalizedEnd) {
    return buildTimeRangeText(formatDateLabel(normalizedStart), formatDateLabel(normalizedEnd));
  }

  if (normalizedStart) {
    return `${t("filters.startDate")} ${formatDateLabel(normalizedStart)}`;
  }

  if (normalizedEnd) {
    return `${t("filters.endDate")} ${formatDateLabel(normalizedEnd)}`;
  }

  return "";
}

function formatDateToWords(dateString) {
  if (!dateString) {
    return t("shared.unknownDate");
  }

  const date = parseLocalDate(dateString);
  if (!date) {
    return String(dateString);
  }

  return date.toLocaleDateString(getCurrentLocale(), { year: "numeric", month: "long", day: "numeric" });
}

function formatDateLabel(dateString) {
  if (!dateString) {
    return t("shared.unknownDate");
  }

  const date = parseLocalDate(dateString);
  if (!date) {
    return String(dateString);
  }

  return date.toLocaleDateString(getCurrentLocale(), { weekday: "short", month: "short", day: "numeric" });
}

function formatYMToWords(dateStr) {
  if (!dateStr) {
    return t("shared.unknown");
  }

  const [year, month] = String(dateStr).split("-");
  const date = new Date(Number(year), Number(month) - 1, 1);
  if (Number.isNaN(date.getTime())) {
    return String(dateStr);
  }

  return date.toLocaleDateString(getCurrentLocale(), { month: "short", year: "numeric" });
}

function formatDateTimeStamp(timestamp) {
  if (!timestamp) {
    return t("shared.unknownTime");
  }

  const normalized = String(timestamp).replace(" ", "T");
  const date = new Date(normalized);
  if (Number.isNaN(date.getTime())) {
    return String(timestamp);
  }

  return `${date.toLocaleDateString(getCurrentLocale(), { month: "short", day: "numeric", year: "numeric" })} | ${date.toLocaleTimeString(getCurrentLocale(), { hour: "2-digit", minute: "2-digit" })}`;
}

function convertFormattedTimeToBackend(timeStr) {
  if (!timeStr) {
    return "";
  }

  const cleaned = String(timeStr).replace(/\s+/g, "").replace("h", ":");
  if (cleaned.split(":").length === 2) {
    return `${cleaned}:00`;
  }

  return cleaned;
}

function timeStringToSeconds(timeStr) {
  if (!timeStr || timeStr === "N/A") {
    return 0;
  }

  const parts = String(timeStr).split(":").map(Number);
  if (parts.some(Number.isNaN)) {
    return 0;
  }

  while (parts.length < 3) {
    parts.push(0);
  }

  return (parts[0] * 3600) + (parts[1] * 60) + parts[2];
}

function secondsToDurationLabel(totalSeconds) {
  const safeSeconds = Math.max(0, Number(totalSeconds) || 0);
  const hours = Math.floor(safeSeconds / 3600);
  const minutes = Math.floor((safeSeconds % 3600) / 60);
  return `${String(hours).padStart(2, "0")}h ${String(minutes).padStart(2, "0")}`;
}

function updateTotalOvertime(entries) {
  const totalSeconds = (entries || []).reduce((accumulator, entry) => accumulator + timeStringToSeconds(entry.overtime), 0);
  const target = document.getElementById("totalOvertime");
  if (target) {
    target.innerText = secondsToDurationLabel(totalSeconds);
  }
}

const overtimeEntryLookupCache = {
  apiUrl: null,
  scopeKey: null,
  payload: null,
};

const scopedProjectLookupCache = {
  apiUrl: null,
  scopeKey: null,
  payload: null,
};

function getLookupCacheScopeKey() {
  const user = typeof getCurrentUser === "function" ? getCurrentUser() : null;
  const role = user && typeof normalizeClientRole === "function"
    ? normalizeClientRole(user.role)
    : String(user && user.role || "");
  const username = String(user && user.username || "");
  const employeeCode = String(user && user.employeeCode || "");
  return [role, username, employeeCode].join("|");
}

function parseResponse(response) {
  if (!response.ok) {
    return response.text().then(text => {
      if (!text) {
        throw new Error(t("error.requestFailedStatus", { status: response.status }));
      }

      try {
        const payload = JSON.parse(text);
        throw new Error(payload.error || text);
      } catch (error) {
        if (error instanceof SyntaxError) {
          throw new Error(text);
        }
        throw error;
      }
    });
  }

  return response.text().then(text => {
    if (!text) {
      return {};
    }
    return JSON.parse(text);
  });
}

function createLoadingState(variant = "list", count = 3) {
  const safeCount = Math.max(1, Number(count) || 1);

  if (variant === "chart") {
    return `
      <div class="loading-shell loading-shell-chart" aria-hidden="true">
        <div class="loading-chart">
          <span class="loading-bar loading-bar-title"></span>
          <span class="loading-bar loading-bar-chart"></span>
        </div>
      </div>
    `;
  }

  if (variant === "detail") {
    return `
      <div class="loading-shell loading-shell-detail" aria-hidden="true">
        <div class="loading-card loading-card-detail">
          <span class="loading-bar loading-bar-title"></span>
          <span class="loading-bar loading-bar-meta"></span>
          <span class="loading-bar loading-bar-wide"></span>
          <span class="loading-bar loading-bar-wide"></span>
        </div>
      </div>
    `;
  }

  const cards = Array.from({ length: safeCount }).map(() => `
    <div class="loading-card">
      <span class="loading-bar loading-bar-title"></span>
      <span class="loading-bar loading-bar-meta"></span>
      <span class="loading-bar loading-bar-wide"></span>
    </div>
  `).join("");

  const shellClass = variant === "grid"
    ? "loading-shell-grid"
    : variant === "activity"
      ? "loading-shell-activity"
      : "loading-shell-list";

  return `<div class="loading-shell ${shellClass}" aria-hidden="true">${cards}</div>`;
}

function setLoadingState(targetOrId, variant = "list", count = 3) {
  const target = typeof targetOrId === "string"
    ? document.getElementById(targetOrId)
    : targetOrId;

  if (!target) {
    return;
  }

  target.innerHTML = createLoadingState(variant, count);
}

function setChartLoadingState(containerId) {
  const container = document.getElementById(containerId);
  if (!container) {
    return;
  }

  const chartStage = container.querySelector(".chart-stage");
  if (!chartStage) {
    return;
  }

  chartStage.innerHTML = createLoadingState("chart", 1);
}

function getStatusTone(status) {
  if (status && typeof status === "object" && isEntryForgottenClockOut(status)) {
    return "attention";
  }

  const statusValue = status && typeof status === "object" ? status.status : status;
  switch (String(statusValue || "").toLowerCase()) {
    case "approved":
      return "approved";
    case "rejected":
      return "rejected";
    default:
      return "pending";
  }
}

function canModifyEntry(entry) {
  return !entry || entry.canModify !== false;
}

function canApproveEntry(entry) {
  return !entry || entry.canApprove !== false;
}

function getEntryPermissionReason(entry) {
  if (!canModifyEntry(entry)) {
    return "readOnlyProject";
  }

  if (!canApproveEntry(entry)) {
    return String(entry && entry.permissionReason || "superAdminApproval");
  }

  return "";
}

function getEntryPermissionBadgeMarkup(entry) {
  const reason = getEntryPermissionReason(entry);
  if (!reason) {
    return "";
  }

  const tone = reason === "superAdminApproval" ? "locked" : "readonly";
  return `<span class="permission-badge ${tone}">${escapeHtml(t(`permissions.${reason}`))}</span>`;
}

function isEntryForgottenClockOut(entry) {
  if (!entry || typeof entry !== "object") {
    return false;
  }

  const value = entry.forgottenClockOut !== undefined && entry.forgottenClockOut !== null
    ? entry.forgottenClockOut
    : entry.needsClockOutReview;
  if (typeof value === "boolean") {
    return value;
  }

  const normalized = String(value || "").trim().toLowerCase();
  return normalized === "true" || normalized === "1" || normalized === "yes";
}

function getEntryStatusLabel(entry) {
  if (isEntryForgottenClockOut(entry)) {
    return t("status.clockOutMissing");
  }

  return translateStatus(entry && entry.status ? entry.status : "pending");
}

function formatRelativeTime(timestamp) {
  if (!timestamp) {
    return t("date.justNow");
  }

  const normalized = String(timestamp).replace(" ", "T");
  const date = new Date(normalized);
  if (Number.isNaN(date.getTime())) {
    return String(timestamp);
  }

  const deltaSeconds = Math.round((Date.now() - date.getTime()) / 1000);
  if (deltaSeconds < 60) {
    return t("date.justNow");
  }
  if (deltaSeconds < 3600) {
    return t("date.minutesAgo", { count: Math.floor(deltaSeconds / 60) });
  }
  if (deltaSeconds < 86400) {
    return t("date.hoursAgo", { count: Math.floor(deltaSeconds / 3600) });
  }

  return t("date.daysAgo", { count: Math.floor(deltaSeconds / 86400) });
}

function sortEntriesByDateTime(entries, latestFirst) {
  return (entries || []).slice().sort((left, right) => {
    const leftDate = toEntryDateTime(left).getTime();
    const rightDate = toEntryDateTime(right).getTime();
    return latestFirst ? rightDate - leftDate : leftDate - rightDate;
  });
}

function toEntryDateTime(entry) {
  const fallback = entry && entry.date ? `${entry.date}T${entry.punchIn || "00:00:00"}` : Date.now();
  return new Date(fallback);
}

function getLatestEntry(entries) {
  const sorted = sortEntriesByDateTime(entries, true);
  return sorted.length > 0 ? sorted[0] : null;
}

function isEntryOpen(entry) {
  return Boolean(entry && entry.punchIn && !entry.punchOut && !isEntryForgottenClockOut(entry));
}

function getEntryType(entry) {
  const normalized = String(entry && entry.entryType ? entry.entryType : "overtime").trim().toLowerCase();
  return normalized === "diverse" ? "diverse" : "overtime";
}

function isDiverseEntry(entry) {
  return getEntryType(entry) === "diverse";
}

function getEntryContextLabel(entry) {
  if (isDiverseEntry(entry)) {
    const reason = String(entry && entry.diverseReason || "").trim();
    return reason ? `${t("shared.diverse")} | ${reason}` : t("shared.diverse");
  }

  const parts = [];

  if (entry && entry.projectCode) {
    parts.push(String(entry.projectCode));
  }

  if (entry && entry.overtimeCode) {
    parts.push(String(entry.overtimeCode));
  }

  if (entry && entry.paymentOption) {
    parts.push(formatPaymentOptionValue(entry.paymentOption));
  }

  if (entry && entry.reasonCode) {
    parts.push(String(entry.reasonCode));
  }

  return parts.length > 0 ? parts.join(" | ") : t("shared.uncoded");
}

function getEntryExactPunchIn(entry) {
  if (!entry) {
    return "";
  }

  return String(entry.exactPunchIn || entry.punchIn || "");
}

function getEntryExactPunchOut(entry) {
  if (!entry) {
    return "";
  }

  return String(entry.exactPunchOut || entry.punchOut || "");
}

function getEntryRoundedTimeRange(entry) {
  const roundedPunchIn = formatTimeString(entry && entry.punchIn);
  const roundedPunchOut = entry && entry.punchOut ? formatTimeString(entry.punchOut) : t("shared.inProgress");
  return buildTimeRangeText(roundedPunchIn, roundedPunchOut);
}

function getEntryRoundedTimeRangeMarkup(entry) {
  const roundedPunchIn = formatTimeString(entry && entry.punchIn);
  const roundedPunchOut = entry && entry.punchOut ? formatTimeString(entry.punchOut) : t("shared.inProgress");
  return buildTimeRangeMarkup(roundedPunchIn, roundedPunchOut);
}

function getEntryExactTimeLabel(entry) {
  const exactPunchIn = getEntryExactPunchIn(entry);
  const exactPunchOut = getEntryExactPunchOut(entry);
  const exactStart = exactPunchIn ? formatTimeString(exactPunchIn) : "";
  const exactEnd = exactPunchOut ? formatTimeString(exactPunchOut) : "";
  const hasExactStartDifference = Boolean(exactPunchIn && entry && entry.punchIn && exactPunchIn !== entry.punchIn);
  const hasExactEndDifference = Boolean(exactPunchOut && entry && entry.punchOut && exactPunchOut !== entry.punchOut);

  if (!hasExactStartDifference && !hasExactEndDifference) {
    return "";
  }

  if (entry && entry.punchOut && exactEnd) {
    return t("shared.exactRange", { start: exactStart, end: exactEnd });
  }

  return t("shared.exactClockIn", { time: exactStart });
}

function buildProjectOptions(projects, placeholder, selectedValue) {
  const options = Array.isArray(projects) ? projects : [];
  const placeholderText = placeholder || t("shared.project");
  const nextSelectedValue = selectedValue || "";
  return [`<option value="">${escapeHtml(placeholderText)}</option>`]
    .concat(options.map(project => {
      const code = String(project.projectCode || "");
      const name = String(project.projectName || code);
      const selected = code === nextSelectedValue ? " selected" : "";
      return `<option value="${escapeHtml(code)}"${selected}>${escapeHtml(code)} | ${escapeHtml(name)}</option>`;
    }))
    .join("");
}

function getLocalizedOptionLabel(item) {
  if (!item) {
    return "";
  }

  const locale = String(getCurrentLocale() || "").toLowerCase();
  if (locale.startsWith("fr")) {
    return String(item.labelFr || item.label || item.labelEn || item.descriptionFr || item.description || item.code || "");
  }

  return String(item.labelEn || item.label || item.labelFr || item.descriptionEn || item.description || item.code || "");
}

function buildCodeOptions(options, placeholder, selectedValue, optionsConfig = {}) {
  const items = Array.isArray(options) ? options : [];
  const placeholderText = placeholder || "";
  const nextSelectedValue = selectedValue || "";
  const includePlaceholder = optionsConfig.includePlaceholder !== false;
  const codeProperty = optionsConfig.codeProperty || "code";
  const blankLabel = optionsConfig.blankLabel || placeholderText;
  const renderedOptions = includePlaceholder
    ? [`<option value="">${escapeHtml(placeholderText)}</option>`]
    : [];

  items.forEach(item => {
    const code = String(item && item[codeProperty] != null ? item[codeProperty] : "");
    const label = getLocalizedOptionLabel(item) || code || blankLabel;
    const selected = code === nextSelectedValue ? " selected" : "";
    const text = code ? `${code} | ${label}` : label;
    renderedOptions.push(`<option value="${escapeHtml(code)}"${selected}>${escapeHtml(text)}</option>`);
  });

  return renderedOptions.join("");
}

function buildOvertimeCodeOptions(overtimeCodes, placeholder, selectedValue) {
  return buildCodeOptions(overtimeCodes, placeholder || t("shared.overtimeCode"), selectedValue, {
    includePlaceholder: false,
    blankLabel: t("shared.overtimeCode"),
  });
}

function buildPaymentOptionOptions(paymentOptions, placeholder, selectedValue) {
  return buildCodeOptions(paymentOptions, placeholder || t("shared.paymentOption"), selectedValue, {
    includePlaceholder: true,
  });
}

function buildReasonCodeOptions(reasonCodes, placeholder, selectedValue) {
  return buildCodeOptions(reasonCodes, placeholder || t("shared.reasonCode"), selectedValue, {
    includePlaceholder: false,
    blankLabel: t("shared.reasonCode"),
  });
}

function getLookupOptionByCode(collection, code) {
  return (Array.isArray(collection) ? collection : []).find(item => String(item.code || "") === String(code || "")) || null;
}

function formatPaymentOptionValue(code) {
  const cached = overtimeEntryLookupCache.payload;
  const option = cached ? getLookupOptionByCode(cached.paymentOptions, code) : null;
  if (option) {
    return getLocalizedOptionLabel(option);
  }

  const normalizedCode = String(code || "");
  if (normalizedCode === "cash") {
    return String(getCurrentLocale() || "").toLowerCase().startsWith("fr") ? "En espèce" : "Cash";
  }
  if (normalizedCode === "leave") {
    return String(getCurrentLocale() || "").toLowerCase().startsWith("fr") ? "Congé" : "Leave";
  }
  return normalizedCode;
}

function formatLookupCodeValue(collection, code, fallbackLabel) {
  const normalizedCode = String(code || "").trim();
  if (!normalizedCode) {
    return fallbackLabel || "-";
  }

  const option = getLookupOptionByCode(collection, normalizedCode);
  const label = getLocalizedOptionLabel(option);
  if (label && label !== normalizedCode) {
    return `${normalizedCode} - ${label}`;
  }

  return normalizedCode;
}

function formatMonthlyExportMonth(monthKey) {
  const parts = String(monthKey || "").split("-").map(Number);
  if (parts.length < 2 || parts.some(Number.isNaN)) {
    return String(monthKey || t("shared.unknownDate"));
  }

  const date = new Date(parts[0], parts[1] - 1, 1);
  if (Number.isNaN(date.getTime())) {
    return String(monthKey || t("shared.unknownDate"));
  }

  return date.toLocaleDateString(getCurrentLocale(), { month: "long", year: "numeric" });
}

function formatMonthlyExportDay(dateString) {
  const date = parseLocalDate(dateString);
  if (!date) {
    return String(dateString || t("shared.unknownDate"));
  }

  return date.toLocaleDateString(getCurrentLocale(), { weekday: "long", month: "short", day: "numeric" });
}

function getMonthlyExportEntrySeconds(entry) {
  if (entry && entry.overtime) {
    return timeStringToSeconds(entry.overtime);
  }

  if (isEntryOpen(entry)) {
    return Math.max(0, Math.floor((Date.now() - toEntryDateTime(entry).getTime()) / 1000));
  }

  return 0;
}

function buildMonthlyEntriesExportHtml(config) {
  const sourceEntries = Array.isArray(config && config.entries) ? config.entries : [];
  const monthKey = String(config && config.monthKey || "");
  const lookups = config && config.lookups ? config.lookups : {};
  const monthEntries = sortEntriesByDateTime(sourceEntries.filter(entry => {
    const status = String(entry && entry.status || "pending").toLowerCase();
    return String(entry && entry.date || "").slice(0, 7) === monthKey && status !== "rejected" && !isDiverseEntry(entry);
  }), false);
  const totalSeconds = monthEntries.reduce((accumulator, entry) => accumulator + getMonthlyExportEntrySeconds(entry), 0);
  const employeeName = String(config && config.employeeName || t("shared.employee"));
  const employeeCode = String(config && config.employeeCode || "");
  const reportTitle = t("export.monthlyTitle");
  const monthLabel = formatMonthlyExportMonth(monthKey);
  const generatedAt = new Date().toLocaleString(getCurrentLocale(), { dateStyle: "medium", timeStyle: "short" });

  const rows = monthEntries.map(entry => {
    const reason = formatLookupCodeValue(lookups.reasonCodes, entry.reasonCode, "-");
    const overtimeCode = formatLookupCodeValue(lookups.overtimeCodes, entry.overtimeCode, "-");
    const paymentOption = (() => {
      const option = getLookupOptionByCode(lookups.paymentOptions, entry.paymentOption || "cash");
      return option ? getLocalizedOptionLabel(option) : formatPaymentOptionValue(entry.paymentOption || "cash");
    })();
    const endTime = entry.punchOut ? formatTimeString(entry.punchOut) : t("shared.inProgress");
    return `
      <tr>
        <td>${escapeHtml(formatMonthlyExportDay(entry.date))}</td>
        <td>${escapeHtml(reason)}</td>
        <td class="mono">${escapeHtml(formatTimeString(entry.punchIn))}</td>
        <td class="mono">${escapeHtml(endTime)}</td>
        <td>${escapeHtml(overtimeCode)}</td>
        <td>${escapeHtml(paymentOption || "-")}</td>
        <td class="mono">${escapeHtml(secondsToDurationLabel(getMonthlyExportEntrySeconds(entry)))}</td>
      </tr>
    `;
  }).join("");

  return `<!doctype html>
<html lang="${escapeHtml(String(getCurrentLocale() || "en").slice(0, 2))}">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${escapeHtml(reportTitle)} - ${escapeHtml(employeeName)} - ${escapeHtml(monthLabel)}</title>
  <style>
    :root {
      color-scheme: light;
      --bg: #f6f8fa;
      --panel: #ffffff;
      --panel-muted: #f6f8fa;
      --line: #d8dee4;
      --line-strong: #d0d7de;
      --text: #24292f;
      --muted: #57606a;
      --accent: #3574f0;
      --mono: "JetBrains Mono", "Cascadia Code", Consolas, Menlo, Monaco, monospace;
      --sans: "Segoe UI", -apple-system, BlinkMacSystemFont, "Helvetica Neue", Arial, sans-serif;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      padding: 20px;
      color: var(--text);
      background: var(--bg);
      font-family: var(--sans);
      font-size: 12px;
    }
    .report-shell {
      max-width: 1120px;
      margin: 0 auto;
      padding: 16px;
      border: 1px solid var(--line-strong);
      border-radius: 6px;
      background: var(--panel);
    }
    .report-topbar {
      display: flex;
      justify-content: space-between;
      align-items: flex-start;
      gap: 12px;
      margin-bottom: 12px;
      padding-bottom: 10px;
      border-bottom: 1px solid var(--line-strong);
    }
    .kicker {
      color: var(--muted);
      font-size: 10px;
      font-weight: 800;
      letter-spacing: 0.12em;
      text-transform: uppercase;
    }
    h1 {
      margin: 4px 0 0;
      font-size: 20px;
      line-height: 1.15;
      font-weight: 700;
    }
    .meta-grid {
      display: grid;
      gap: 5px;
      min-width: 280px;
      padding: 8px 10px;
      border: 1px solid var(--line-strong);
      border-radius: 4px;
      background: var(--panel-muted);
    }
    .meta-row {
      display: grid;
      grid-template-columns: 92px minmax(0, 1fr);
      gap: 8px;
    }
    .meta-label {
      color: var(--muted);
      font-size: 10px;
      font-weight: 800;
      letter-spacing: 0.08em;
      text-transform: uppercase;
    }
    .meta-value {
      font-weight: 700;
    }
    table {
      width: 100%;
      border-collapse: collapse;
      table-layout: fixed;
      border: 0;
    }
    th,
    td {
      border: 0;
      border-bottom: 1px solid var(--line);
      padding: 8px 10px;
      vertical-align: top;
      text-align: left;
      overflow-wrap: anywhere;
    }
    th {
      background: #eef1f5;
      color: var(--muted);
      font-size: 10px;
      font-weight: 800;
      letter-spacing: 0.08em;
      text-transform: uppercase;
    }
    tbody tr:hover td {
      background: #f6f8fa;
    }
    tbody tr:last-child td {
      border-bottom: 0;
    }
    tfoot td {
      border-top: 1px solid var(--line-strong);
      border-bottom: 0;
      background: var(--panel-muted);
      font-weight: 800;
    }
    .mono {
      font-family: var(--mono);
      white-space: nowrap;
    }
    .empty {
      padding: 14px;
      border: 1px solid var(--line);
      border-radius: 4px;
      background: var(--panel-muted);
      color: var(--muted);
      font-weight: 700;
    }
    @media print {
      body { padding: 0; }
      .report-shell { max-width: none; }
      th { background: #f0f0f0 !important; }
    }
  </style>
</head>
<body>
  <main class="report-shell">
    <div class="report-topbar">
      <div>
        <div class="kicker">GÉEM</div>
        <h1>${escapeHtml(reportTitle)}</h1>
      </div>
      <div class="meta-grid">
        <div class="meta-row"><span class="meta-label">${escapeHtml(t("export.employee"))}</span><span class="meta-value">${escapeHtml(employeeName)}${employeeCode ? ` (${escapeHtml(employeeCode)})` : ""}</span></div>
        <div class="meta-row"><span class="meta-label">${escapeHtml(t("export.month"))}</span><span class="meta-value">${escapeHtml(monthLabel)}</span></div>
        <div class="meta-row"><span class="meta-label">${escapeHtml(t("export.generated"))}</span><span class="meta-value">${escapeHtml(generatedAt)}</span></div>
      </div>
    </div>
    ${monthEntries.length === 0 ? `<div class="empty">${escapeHtml(t("export.noEntries"))}</div>` : `
      <table>
        <thead>
          <tr>
            <th>${escapeHtml(t("export.day"))}</th>
            <th>${escapeHtml(t("export.reason"))}</th>
            <th>${escapeHtml(t("export.startTime"))}</th>
            <th>${escapeHtml(t("export.endTime"))}</th>
            <th>${escapeHtml(t("export.overtimeCode"))}</th>
            <th>${escapeHtml(t("export.payment"))}</th>
            <th>${escapeHtml(t("export.totalTime"))}</th>
          </tr>
        </thead>
        <tbody>${rows}</tbody>
        <tfoot>
          <tr>
            <td colspan="6">${escapeHtml(t("export.total"))}</td>
            <td class="mono">${escapeHtml(secondsToDurationLabel(totalSeconds))}</td>
          </tr>
        </tfoot>
      </table>
    `}
  </main>
</body>
</html>`;
}

function openMonthlyEntriesExportHtml(config) {
  const html = buildMonthlyEntriesExportHtml(config);
  const blob = new Blob([html], { type: "text/html;charset=utf-8" });
  const url = URL.createObjectURL(blob);
  const newWindow = window.open(url, "_blank");
  if (!newWindow) {
    URL.revokeObjectURL(url);
    showToast(t("export.popupBlocked"), "error");
    return false;
  }

  setTimeout(() => URL.revokeObjectURL(url), 60000);
  return true;
}

function getDownloadFilenameFromDisposition(contentDisposition, fallbackName) {
  const fallback = fallbackName || "download.fdf";
  if (!contentDisposition) {
    return fallback;
  }

  const utf8Match = String(contentDisposition).match(/filename\*=UTF-8''([^;]+)/i);
  if (utf8Match) {
    try {
      return decodeURIComponent(utf8Match[1]);
    } catch (error) {
      return utf8Match[1];
    }
  }

  const filenameMatch = String(contentDisposition).match(/filename="?([^";]+)"?/i);
  return filenameMatch ? filenameMatch[1] : fallback;
}

function downloadBlob(blob, fileName) {
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = url;
  link.download = fileName || "download.fdf";
  document.body.appendChild(link);
  link.click();
  link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 60000);
}

async function downloadGc179FdfExport(config) {
  const monthKey = String(config && config.monthKey || "").trim();
  const employeeCode = String(config && config.employeeCode || "").trim();
  const isSelfExport = Boolean(config && config.self);
  const path = isSelfExport
    ? `self/gc179-fdf?month=${encodeURIComponent(monthKey)}`
    : `employee/${encodeURIComponent(employeeCode)}/gc179-fdf?month=${encodeURIComponent(monthKey)}`;

  if (!monthKey || (!isSelfExport && !employeeCode)) {
    showToast(t("export.gc179DownloadError", { message: t("error.missingRequiredFields") }), "error");
    return false;
  }

  try {
    const response = await fetch(apiUrl + path);
    if (!response.ok) {
      const text = await response.text();
      let message = text || t("error.requestFailedStatus", { status: response.status });
      try {
        const payload = JSON.parse(text);
        message = payload.error || message;
      } catch (error) {
        // The server normally sends JSON errors, but keep plain text readable.
      }
      throw new Error(message);
    }

    const blob = await response.blob();
    const fileName = getDownloadFilenameFromDisposition(response.headers.get("Content-Disposition"), `gc179-${employeeCode || "self"}-${monthKey}.fdf`);
    downloadBlob(blob, fileName);
    showToast(t("export.gc179DownloadSuccess"), "success");
    return true;
  } catch (error) {
    showToast(t("export.gc179DownloadError", { message: error.message || error }), "error");
    return false;
  }
}

async function fetchOvertimeEntryLookups(forceRefresh = false) {
  const currentApiUrl = window.apiUrl || "";
  const scopeKey = getLookupCacheScopeKey();
  if (!forceRefresh && overtimeEntryLookupCache.payload && overtimeEntryLookupCache.apiUrl === currentApiUrl && overtimeEntryLookupCache.scopeKey === scopeKey) {
    return overtimeEntryLookupCache.payload;
  }

  const response = await fetch(apiUrl + "self/options");
  const payload = await parseResponse(response);
  const normalizedPayload = {
    projects: Array.isArray(payload && payload.projects) ? payload.projects : [],
    overtimeCodes: Array.isArray(payload && payload.overtimeCodes) ? payload.overtimeCodes : [],
    paymentOptions: Array.isArray(payload && payload.paymentOptions) ? payload.paymentOptions : [],
    reasonCodes: Array.isArray(payload && payload.reasonCodes) ? payload.reasonCodes : [],
    timeEntryTypes: Array.isArray(payload && payload.timeEntryTypes) ? payload.timeEntryTypes : ["overtime"],
  };

  overtimeEntryLookupCache.apiUrl = currentApiUrl;
  overtimeEntryLookupCache.scopeKey = scopeKey;
  overtimeEntryLookupCache.payload = normalizedPayload;
  return normalizedPayload;
}

async function fetchScopedProjects(forceRefresh = false) {
  const currentApiUrl = window.apiUrl || "";
  const scopeKey = getLookupCacheScopeKey();
  if (!forceRefresh && scopedProjectLookupCache.payload && scopedProjectLookupCache.apiUrl === currentApiUrl && scopedProjectLookupCache.scopeKey === scopeKey) {
    return scopedProjectLookupCache.payload;
  }

  const response = await fetch(apiUrl + "projects");
  const payload = await parseResponse(response);
  const projects = Array.isArray(payload) ? payload : [];
  scopedProjectLookupCache.apiUrl = currentApiUrl;
  scopedProjectLookupCache.scopeKey = scopeKey;
  scopedProjectLookupCache.payload = projects;
  return projects;
}

function clearOvertimeEntryLookupCache() {
  overtimeEntryLookupCache.apiUrl = null;
  overtimeEntryLookupCache.scopeKey = null;
  overtimeEntryLookupCache.payload = null;
}

function clearScopedProjectLookupCache() {
  scopedProjectLookupCache.apiUrl = null;
  scopedProjectLookupCache.scopeKey = null;
  scopedProjectLookupCache.payload = null;
}

function clearLookupCaches() {
  clearOvertimeEntryLookupCache();
  clearScopedProjectLookupCache();
}

function normalizeToastMessage(message) {
  const rawMessage = String(message == null ? "" : message).replace(/<br\s*\/?>/gi, " | ");
  const scratch = document.createElement("div");
  scratch.innerHTML = rawMessage;
  return scratch.textContent.replace(/\s+/g, " ").trim();
}

function localizeAuditHumanDate(dateLabel) {
  const rawDate = String(dateLabel || "").trim();
  if (!rawDate) {
    return t("shared.unknownDate");
  }

  const parsedDate = new Date(rawDate);
  if (Number.isNaN(parsedDate.getTime())) {
    return rawDate;
  }

  return parsedDate.toLocaleDateString(getCurrentLocale(), { year: "numeric", month: "long", day: "numeric" });
}

function buildTranslatedAuditUpdateFragments(message) {
  const rawMessage = String(message || "");
  const fragments = [];
  const punchInMatch = rawMessage.match(/Punch In from <strong>(.*?)<\/strong> to <strong>(.*?)<\/strong>\./i);
  const punchOutMatch = rawMessage.match(/Punch Out from <strong>(.*?)<\/strong> to <strong>(.*?)<\/strong>\./i);
  const punchOutRecordedMatch = rawMessage.match(/Punch Out recorded at <strong>(.*?)<\/strong>\./i);
  const projectUpdatedMatch = /Project Code updated\./i.test(rawMessage);
  const overtimeUpdatedMatch = /Overtime Code updated\./i.test(rawMessage);
  const paymentUpdatedMatch = /Payment option updated\./i.test(rawMessage);
  const reasonUpdatedMatch = /Reason code updated\./i.test(rawMessage);

  if (punchInMatch) {
    fragments.push(t("history.fragment.punchInFromTo", { from: punchInMatch[1], to: punchInMatch[2] }));
  }
  if (punchOutMatch) {
    fragments.push(t("history.fragment.punchOutFromTo", { from: punchOutMatch[1], to: punchOutMatch[2] }));
  }
  if (punchOutRecordedMatch) {
    fragments.push(t("history.fragment.punchOutRecorded", { time: punchOutRecordedMatch[1] }));
  }
  if (projectUpdatedMatch) {
    fragments.push(t("history.fragment.projectCodeUpdated"));
  }
  if (overtimeUpdatedMatch) {
    fragments.push(t("history.fragment.overtimeCodeUpdated"));
  }
  if (paymentUpdatedMatch) {
    fragments.push(t("history.fragment.paymentOptionUpdated"));
  }
  if (reasonUpdatedMatch) {
    fragments.push(t("history.fragment.reasonCodeUpdated"));
  }

  return fragments.join(" ");
}

function translateAuditMessage(message) {
  const rawMessage = String(message == null ? "" : message).trim();
  if (!rawMessage) {
    return t("shared.noMessage");
  }

  let match = rawMessage.match(/^Added an entry on ([A-Za-z]+ \d{1,2}, \d{4}), starting at <strong>(.*?)<\/strong> and finishing at <strong>(.*?)<\/strong> for project <strong>(.*?)<\/strong>, overtime code <strong>(.*?)<\/strong>, payment <strong>(.*?)<\/strong>, and reason <strong>(.*?)<\/strong>\.$/i);
  if (match) {
    return t("history.message.addedEntryWithOptions", {
      date: localizeAuditHumanDate(match[1]),
      start: match[2],
      end: match[3],
      projectCode: match[4],
      overtimeCode: match[5] || t("shared.overtimeCode"),
      paymentOption: formatPaymentOptionValue(match[6]),
      reasonCode: match[7] || t("shared.reasonCode"),
    });
  }

  match = rawMessage.match(/^Added an entry on ([A-Za-z]+ \d{1,2}, \d{4}), starting at <strong>(.*?)<\/strong> and finishing at <strong>(.*?)<\/strong> for project <strong>(.*?)<\/strong> and overtime code <strong>(.*?)<\/strong>\.$/i);
  if (match) {
    return t("history.message.addedEntry", {
      date: localizeAuditHumanDate(match[1]),
      start: match[2],
      end: match[3],
      projectCode: match[4],
      overtimeCode: match[5] || t("shared.overtimeCode"),
    });
  }

  match = rawMessage.match(/^Updated an entry on ([A-Za-z]+ \d{1,2}, \d{4}),\s*(.*)$/i);
  if (match) {
    const translatedFragments = buildTranslatedAuditUpdateFragments(match[2]);
    if (translatedFragments) {
      return t("history.message.updatedEntry", {
        date: localizeAuditHumanDate(match[1]),
        details: translatedFragments,
      });
    }
  }

  match = rawMessage.match(/^Updated an entry on ([A-Za-z]+ \d{1,2}, \d{4}) from <strong>(.*?)<\/strong> to <strong>(.*?)<\/strong>\.\s*(.*)$/i);
  if (match) {
    const translatedFragments = buildTranslatedAuditUpdateFragments(match[4]);
    if (translatedFragments) {
      return t("history.message.updatedEntryWithSpan", {
        date: localizeAuditHumanDate(match[1]),
        start: match[2],
        end: match[3],
        details: translatedFragments,
      });
    }

    return t("history.message.updatedEntryWithSpanSimple", {
      date: localizeAuditHumanDate(match[1]),
      start: match[2],
      end: match[3],
    });
  }

  match = rawMessage.match(/^Entry on ([A-Za-z]+ \d{1,2}, \d{4}) updated successfully\.$/i);
  if (match) {
    return t("history.message.updatedEntrySimple", {
      date: localizeAuditHumanDate(match[1]),
    });
  }

  match = rawMessage.match(/^Deleted an entry on ([A-Za-z]+ \d{1,2}, \d{4}) from <strong>(.*?)<\/strong> to <strong>(.*?)<\/strong>\.(?: Reason: (.*))?$/i);
  if (match) {
    if (match[4]) {
      return t("history.message.deletedEntryReason", {
        date: localizeAuditHumanDate(match[1]),
        start: match[2],
        end: match[3],
        reason: match[4],
      });
    }
    return t("history.message.deletedEntry", {
      date: localizeAuditHumanDate(match[1]),
      start: match[2],
      end: match[3],
    });
  }

  match = rawMessage.match(/^Deleted an entry on ([A-Za-z]+ \d{1,2}, \d{4}) starting at <strong>(.*?)<\/strong>\.(?: Reason: (.*))?$/i);
  if (match) {
    if (match[3]) {
      return t("history.message.deletedEntryReasonLegacy", {
        date: localizeAuditHumanDate(match[1]),
        time: match[2],
        reason: match[3],
      });
    }
    return t("history.message.deletedEntryLegacy", {
      date: localizeAuditHumanDate(match[1]),
      time: match[2],
    });
  }

  match = rawMessage.match(/^Approved an entry on ([A-Za-z]+ \d{1,2}, \d{4}) from <strong>(.*?)<\/strong> to <strong>(.*?)<\/strong>\.$/i);
  if (match) {
    return t("history.message.approvedEntry", {
      date: localizeAuditHumanDate(match[1]),
      start: match[2],
      end: match[3],
    });
  }

  match = rawMessage.match(/^Approved an entry on ([A-Za-z]+ \d{1,2}, \d{4}) starting at <strong>(.*?)<\/strong>\.$/i);
  if (match) {
    return t("history.message.approvedEntryLegacy", {
      date: localizeAuditHumanDate(match[1]),
      time: match[2],
    });
  }

  match = rawMessage.match(/^Rejected an entry on ([A-Za-z]+ \d{1,2}, \d{4}) from <strong>(.*?)<\/strong> to <strong>(.*?)<\/strong>\.$/i);
  if (match) {
    return t("history.message.rejectedEntry", {
      date: localizeAuditHumanDate(match[1]),
      start: match[2],
      end: match[3],
    });
  }

  match = rawMessage.match(/^Rejected an entry on ([A-Za-z]+ \d{1,2}, \d{4}) starting at <strong>(.*?)<\/strong>\.$/i);
  if (match) {
    return t("history.message.rejectedEntryLegacy", {
      date: localizeAuditHumanDate(match[1]),
      time: match[2],
    });
  }

  match = rawMessage.match(/^Created a sign-in account and set a password for <strong>(.*?)<\/strong>\.$/i);
  if (match) {
    return t("history.message.createdAccount", { name: match[1] });
  }

  match = rawMessage.match(/^Reset the password for <strong>(.*?)<\/strong> and required a password change at next sign-in\.$/i);
  if (match) {
    return t("history.message.resetPasswordRequireChange", { name: match[1] });
  }

  match = rawMessage.match(/^Reset the password for <strong>(.*?)<\/strong>\.$/i);
  if (match) {
    return t("history.message.resetPassword", { name: match[1] });
  }

  match = rawMessage.match(/^Created an employee profile for <strong>(.*?)<\/strong> with code <strong>(.*?)<\/strong>\.$/i);
  if (match) {
    return t("history.message.employeeCreated", { name: match[1], code: match[2] });
  }

  match = rawMessage.match(/^Updated the employee profile for <strong>(.*?)<\/strong>\.$/i);
  if (match) {
    return t("history.message.employeeUpdated", { name: match[1] });
  }

  match = rawMessage.match(/^Removed employee access for <strong>(.*?)<\/strong>\.$/i);
  if (match) {
    return t("history.message.employeeRemoved", { name: match[1] });
  }

  match = rawMessage.match(/^Reinstated employee access for <strong>(.*?)<\/strong>\.$/i);
  if (match) {
    return t("history.message.employeeRestored", { name: match[1] });
  }

  match = rawMessage.match(/^Created a project named <strong>(.*?)<\/strong> with code <strong>(.*?)<\/strong>\.$/i);
  if (match) {
    return t("history.message.projectCreated", { name: match[1], code: match[2] });
  }

  match = rawMessage.match(/^Updated the project <strong>(.*?)<\/strong>\.$/i);
  if (match) {
    return t("history.message.projectUpdated", { code: match[1] });
  }

  match = rawMessage.match(/^Removed the project <strong>(.*?)<\/strong>\.$/i);
  if (match) {
    return t("history.message.projectRemoved", { code: match[1] });
  }

  return rawMessage;
}

function sanitizeAuditHtml(message) {
  const scratch = document.createElement("div");
  scratch.innerHTML = String(message == null ? "" : message);

  function renderNode(node) {
    if (node.nodeType === Node.TEXT_NODE) {
      return escapeHtml(node.textContent || "").replace(/\r?\n/g, "<br>");
    }

    if (node.nodeType !== Node.ELEMENT_NODE) {
      return "";
    }

    const tagName = String(node.tagName || "").toLowerCase();
    if (tagName === "br") {
      return "<br>";
    }

    const childHtml = Array.from(node.childNodes || []).map(renderNode).join("");
    if (tagName === "strong") {
      return `<strong>${childHtml}</strong>`;
    }

    return childHtml;
  }

  return Array.from(scratch.childNodes || []).map(renderNode).join("");
}

function renderAuditMessage(message) {
  return sanitizeAuditHtml(translateAuditMessage(message));
}

function auditMessageToText(message) {
  const scratch = document.createElement("div");
  scratch.innerHTML = renderAuditMessage(message);
  return scratch.textContent.replace(/\s+/g, " ").trim();
}

function getExplicitHistoryAuthorName(entry) {
  if (!entry) {
    return "";
  }

  const candidates = [entry.author, entry.actor, entry.performedBy, entry.authorName];
  for (const candidate of candidates) {
    const normalized = String(candidate || "").trim();
    if (normalized) {
      return normalized;
    }
  }

  return "";
}

function getHistoryAuthorName(entry) {
  return getExplicitHistoryAuthorName(entry) || t("history.authorNotRecorded");
}

function isEmployeeTargetedHistoryEntry(entry) {
  const rawMessage = String(entry && entry.message || "");
  return /^(Added|Updated|Deleted|Approved|Rejected) an entry on /i.test(rawMessage)
    || /employee (profile|access)/i.test(rawMessage)
    || /^Created a sign-in account/i.test(rawMessage)
    || /^Reset the password/i.test(rawMessage);
}

function getHistorySubjectName(entry) {
  if (!entry || !isEmployeeTargetedHistoryEntry(entry)) {
    return "";
  }

  const candidates = [entry.targetEmployee, entry.subjectEmployee, entry.employee];
  const explicitAuthorName = getExplicitHistoryAuthorName(entry);
  for (const candidate of candidates) {
    const normalized = String(candidate || "").trim();
    if (!normalized) {
      continue;
    }

    if (explicitAuthorName && normalized.toLowerCase() === explicitAuthorName.toLowerCase()) {
      continue;
    }

    return normalized;
  }

  return "";
}

function renderHistorySubjectLine(entry) {
  const subjectName = getHistorySubjectName(entry);
  if (!subjectName) {
    return "";
  }

  return `<div class="timeline-card-subject">${escapeHtml(t("history.concernedEmployee", { name: subjectName }))}</div>`;
}

function getHistorySearchText(entry) {
  return [
    getHistoryAuthorName(entry),
    getHistorySubjectName(entry),
    entry && entry.authorUsername,
    entry && entry.authorRole,
    entry && entry.employee,
    entry && entry.timestamp,
    entry && entry.action,
    translateHistoryAction(entry && entry.action || "event"),
    auditMessageToText(entry && entry.message || ""),
    formatDateToWords(String(entry && entry.timestamp || "").split(" ")[0] || ""),
  ].join(" ").toLowerCase();
}

function showToast(message, type = "success") {
  const toastContainer = document.getElementById("toastContainer");
  if (!toastContainer) {
    return;
  }

  const tone = type === "error" ? "danger" : type === "info" ? "info" : type;
  const iconClass = tone === "success"
    ? "fa-circle-check"
    : tone === "danger"
      ? "fa-circle-xmark"
      : "fa-circle-info";

  const toast = document.createElement("div");
  toast.className = "toast custom-toast";
  toast.setAttribute("role", "alert");
  toast.setAttribute("aria-live", "assertive");
  toast.setAttribute("aria-atomic", "true");

  toast.innerHTML = `
    <div class="toast-header">
      <i class="fa-solid ${iconClass} me-2 text-${tone}"></i>
      <strong class="me-auto">${escapeHtml(t("app.name"))}</strong>
      <small class="text-muted">${escapeHtml(t("shared.now"))}</small>
      <button type="button" class="btn-close" data-bs-dismiss="toast" aria-label="${escapeHtml(t("shared.close"))}"></button>
    </div>
    <div class="toast-body">${escapeHtml(normalizeToastMessage(message))}</div>
  `;

  toastContainer.appendChild(toast);
  const bsToast = new bootstrap.Toast(toast, { delay: 3600 });
  bsToast.show();
  toast.addEventListener("hidden.bs.toast", () => {
    toast.remove();
  });
}
