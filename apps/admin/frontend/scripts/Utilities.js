function escapeHtml(value) {
  return String(value == null ? "" : value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/\"/g, "&quot;")
    .replace(/'/g, "&#39;");
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
      translateStatus(entry.status || "pending"),
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
  return `${String(hours).padStart(2, "0")}h ${String(minutes).padStart(2, "0")}m`;
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
  payload: null,
};

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
  switch (String(status || "").toLowerCase()) {
    case "approved":
      return "approved";
    case "rejected":
      return "rejected";
    default:
      return "pending";
  }
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
  return Boolean(entry && entry.punchIn && !entry.punchOut);
}

function getEntryContextLabel(entry) {
  const parts = [];

  if (entry && entry.projectCode) {
    parts.push(String(entry.projectCode));
  }

  if (entry && entry.overtimeCode) {
    parts.push(String(entry.overtimeCode));
  }

  return parts.length > 0 ? parts.join(" | ") : t("shared.uncoded");
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

function buildOvertimeCodeOptions(overtimeCodes, placeholder, selectedValue) {
  const options = Array.isArray(overtimeCodes) ? overtimeCodes : [];
  const placeholderText = placeholder || t("shared.overtimeCode");
  const nextSelectedValue = selectedValue || "";
  return [`<option value="">${escapeHtml(placeholderText)}</option>`]
    .concat(options.map(item => {
      const code = String(item.code || "");
      const label = String(item.label || code);
      const selected = code === nextSelectedValue ? " selected" : "";
      return `<option value="${escapeHtml(code)}"${selected}>${escapeHtml(code)} | ${escapeHtml(label)}</option>`;
    }))
    .join("");
}

async function fetchOvertimeEntryLookups(forceRefresh = false) {
  const currentApiUrl = window.apiUrl || "";
  if (!forceRefresh && overtimeEntryLookupCache.payload && overtimeEntryLookupCache.apiUrl === currentApiUrl) {
    return overtimeEntryLookupCache.payload;
  }

  const response = await fetch(apiUrl + "self/options");
  const payload = await parseResponse(response);
  const normalizedPayload = {
    projects: Array.isArray(payload && payload.projects) ? payload.projects : [],
    overtimeCodes: Array.isArray(payload && payload.overtimeCodes) ? payload.overtimeCodes : [],
  };

  overtimeEntryLookupCache.apiUrl = currentApiUrl;
  overtimeEntryLookupCache.payload = normalizedPayload;
  return normalizedPayload;
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

  return fragments.join(" ");
}

function translateAuditMessage(message) {
  const rawMessage = String(message == null ? "" : message).trim();
  if (!rawMessage) {
    return t("shared.noMessage");
  }

  let match = rawMessage.match(/^Added an entry on ([A-Za-z]+ \d{1,2}, \d{4}), starting at <strong>(.*?)<\/strong> and finishing at <strong>(.*?)<\/strong> for project <strong>(.*?)<\/strong> and overtime code <strong>(.*?)<\/strong>\.$/i);
  if (match) {
    return t("history.message.addedEntry", {
      date: localizeAuditHumanDate(match[1]),
      start: match[2],
      end: match[3],
      projectCode: match[4],
      overtimeCode: match[5],
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

  match = rawMessage.match(/^Entry on ([A-Za-z]+ \d{1,2}, \d{4}) updated successfully\.$/i);
  if (match) {
    return t("history.message.updatedEntrySimple", {
      date: localizeAuditHumanDate(match[1]),
    });
  }

  match = rawMessage.match(/^Deleted an entry on ([A-Za-z]+ \d{1,2}, \d{4}) starting at <strong>(.*?)<\/strong>\.(?: Reason: (.*))?$/i);
  if (match) {
    if (match[3]) {
      return t("history.message.deletedEntryReason", {
        date: localizeAuditHumanDate(match[1]),
        time: match[2],
        reason: match[3],
      });
    }
    return t("history.message.deletedEntry", {
      date: localizeAuditHumanDate(match[1]),
      time: match[2],
    });
  }

  match = rawMessage.match(/^Approved an entry on ([A-Za-z]+ \d{1,2}, \d{4}) starting at <strong>(.*?)<\/strong>\.$/i);
  if (match) {
    return t("history.message.approvedEntry", {
      date: localizeAuditHumanDate(match[1]),
      time: match[2],
    });
  }

  match = rawMessage.match(/^Rejected an entry on ([A-Za-z]+ \d{1,2}, \d{4}) starting at <strong>(.*?)<\/strong>\.$/i);
  if (match) {
    return t("history.message.rejectedEntry", {
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
