function escapeHtml(value) {
  return String(value == null ? "" : value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/\"/g, "&quot;")
    .replace(/'/g, "&#39;");
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
      entry.status,
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

function formatDateToWords(dateString) {
  if (!dateString) {
    return "Unknown date";
  }

  const parts = String(dateString).split("-");
  const date = new Date(parts[0], parts[1] - 1, parts[2]);
  if (Number.isNaN(date.getTime())) {
    return String(dateString);
  }

  return date.toLocaleDateString(undefined, { year: "numeric", month: "long", day: "numeric" });
}

function formatDateLabel(dateString) {
  if (!dateString) {
    return "Unknown date";
  }

  const parts = String(dateString).split("-");
  const date = new Date(parts[0], parts[1] - 1, parts[2]);
  if (Number.isNaN(date.getTime())) {
    return String(dateString);
  }

  return date.toLocaleDateString(undefined, { weekday: "short", month: "short", day: "numeric" });
}

function formatYMToWords(dateStr) {
  if (!dateStr) {
    return "Unknown";
  }

  const [year, month] = String(dateStr).split("-");
  const date = new Date(Number(year), Number(month) - 1, 1);
  if (Number.isNaN(date.getTime())) {
    return String(dateStr);
  }

  return date.toLocaleDateString(undefined, { month: "short", year: "numeric" });
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
        throw new Error(`Request failed with status ${response.status}.`);
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
    return "Just now";
  }

  const normalized = String(timestamp).replace(" ", "T");
  const date = new Date(normalized);
  if (Number.isNaN(date.getTime())) {
    return String(timestamp);
  }

  const deltaSeconds = Math.round((Date.now() - date.getTime()) / 1000);
  if (deltaSeconds < 60) {
    return "Just now";
  }
  if (deltaSeconds < 3600) {
    const minutes = Math.floor(deltaSeconds / 60);
    return `${minutes}m ago`;
  }
  if (deltaSeconds < 86400) {
    const hours = Math.floor(deltaSeconds / 3600);
    return `${hours}h ago`;
  }

  const days = Math.floor(deltaSeconds / 86400);
  return `${days}d ago`;
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

  return parts.length > 0 ? parts.join(" | ") : "Uncoded";
}

function buildProjectOptions(projects, placeholder = "Project", selectedValue = "") {
  const options = Array.isArray(projects) ? projects : [];
  return [`<option value="">${escapeHtml(placeholder)}</option>`]
    .concat(options.map(project => {
      const code = String(project.projectCode || "");
      const name = String(project.projectName || code);
      const selected = code === selectedValue ? " selected" : "";
      return `<option value="${escapeHtml(code)}"${selected}>${escapeHtml(code)} | ${escapeHtml(name)}</option>`;
    }))
    .join("");
}

function buildOvertimeCodeOptions(overtimeCodes, placeholder = "Overtime Code", selectedValue = "") {
  const options = Array.isArray(overtimeCodes) ? overtimeCodes : [];
  return [`<option value="">${escapeHtml(placeholder)}</option>`]
    .concat(options.map(item => {
      const code = String(item.code || "");
      const label = String(item.label || code);
      const selected = code === selectedValue ? " selected" : "";
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
      <strong class="me-auto">Overtime Manager</strong>
      <small class="text-muted">Now</small>
      <button type="button" class="btn-close" data-bs-dismiss="toast" aria-label="Close"></button>
    </div>
    <div class="toast-body">${escapeHtml(message)}</div>
  `;

  toastContainer.appendChild(toast);
  const bsToast = new bootstrap.Toast(toast, { delay: 3600 });
  bsToast.show();
  toast.addEventListener("hidden.bs.toast", () => {
    toast.remove();
  });
}
