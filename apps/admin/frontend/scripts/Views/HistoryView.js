let allHistoryEntries = [];
let filteredHistoryEntriesByCategory = createEmptyHistoryCategories();
let historyFilterTimerId = null;

const HISTORY_FILTER_DEBOUNCE_MS = 150;
const HISTORY_TAB_CONFIG = {
  "all-history-tab": { category: "all", containerId: "allHistoryContainer", skeletonCount: 4 },
  "add-history-tab": { category: "add", containerId: "addHistoryContainer", skeletonCount: 3 },
  "edit-history-tab": { category: "update", containerId: "editHistoryContainer", skeletonCount: 3 },
  "approve-history-tab": { category: "approval", containerId: "approveHistoryContainer", skeletonCount: 3 },
  "delete-history-tab": { category: "delete", containerId: "deleteHistoryContainer", skeletonCount: 3 },
};

async function fetchHistory() {
  try {
    setActiveHistoryLoadingState();
    const response = await fetch(apiUrl + "history");
    const historyEntries = await parseResponse(response);
    allHistoryEntries = Array.isArray(historyEntries) ? historyEntries : [];
    applyHistoryFilters();
  } catch (error) {
    console.error("Error fetching history:", error);
    showToast(t("history.fetchError"), "error");
  }
}

function formatHistoryTimestamp(timestamp) {
  return formatDateTimeStamp(timestamp);
}

function filterHistoryEntries(entries, searchTerm, startDate, endDate) {
  const tokens = String(searchTerm || "").toLowerCase().split(/\s+/).filter(token => token.length > 0);

  return (entries || []).filter(entry => {
    if (!isDateWithinRange(String(entry.timestamp || "").split(" ")[0] || "", startDate, endDate)) {
      return false;
    }

    if (tokens.length === 0) {
      return true;
    }

    const combinedText = getHistorySearchText(entry);
    return tokens.every(token => combinedText.includes(token));
  });
}

function getActionBadgeHtml(action) {
  const normalizedAction = String(action || "event").toLowerCase();
  const tone = normalizedAction === "add"
    ? "add"
    : normalizedAction === "update"
      ? "update"
      : normalizedAction === "approved"
        ? "approved"
        : normalizedAction === "rejected"
          ? "rejected"
          : normalizedAction === "delete"
            ? "delete"
            : "update";
  return `<span class="action-badge ${tone}">${escapeHtml(translateHistoryAction(action || "event"))}</span>`;
}

function updateHistoryTabLabels(allEntries, addedEntries, updatedEntries, approvalEntries, deletedEntries) {
  document.getElementById("all-history-tab").textContent = t("history.all", { count: allEntries.length });
  document.getElementById("add-history-tab").textContent = t("history.added", { count: addedEntries.length });
  document.getElementById("edit-history-tab").textContent = t("history.updated", { count: updatedEntries.length });
  document.getElementById("approve-history-tab").textContent = t("history.approvedRejected", { count: approvalEntries.length });
  document.getElementById("delete-history-tab").textContent = t("history.deleted", { count: deletedEntries.length });
}

function createEmptyHistoryCategories() {
  return {
    all: [],
    add: [],
    update: [],
    approval: [],
    delete: [],
  };
}

function groupHistoryEntries(entries) {
  const categories = createEmptyHistoryCategories();
  categories.all = Array.isArray(entries) ? entries : [];

  categories.all.forEach(entry => {
    const action = String(entry.action || "").toLowerCase();
    if (action === "add") {
      categories.add.push(entry);
    } else if (action === "update") {
      categories.update.push(entry);
    } else if (action === "approved" || action === "rejected") {
      categories.approval.push(entry);
    } else if (action === "delete") {
      categories.delete.push(entry);
    }
  });

  return categories;
}

function getHistoryTabConfig(tab) {
  return tab ? HISTORY_TAB_CONFIG[tab.id] || null : null;
}

function getActiveHistoryTabConfig() {
  const activeTab = document.querySelector("#historyTabs [data-bs-toggle='tab'].active");
  return getHistoryTabConfig(activeTab) || HISTORY_TAB_CONFIG["all-history-tab"];
}

function clearInactiveHistoryContainers(activeCategory) {
  Object.values(HISTORY_TAB_CONFIG).forEach(config => {
    if (config.category !== activeCategory) {
      document.getElementById(config.containerId).replaceChildren();
    }
  });
}

function isHistoryLoading() {
  return Object.values(HISTORY_TAB_CONFIG).some(config =>
    document.getElementById(config.containerId).querySelector(".loading-shell")
  );
}

function setActiveHistoryLoadingState() {
  const activeConfig = getActiveHistoryTabConfig();
  clearInactiveHistoryContainers(activeConfig.category);
  setLoadingState(activeConfig.containerId, "activity", activeConfig.skeletonCount);
}

function renderHistoryList(container, entries) {
  const sortedEntries = (entries || []).slice().sort((left, right) => new Date(right.timestamp) - new Date(left.timestamp));
  if (sortedEntries.length === 0) {
    container.innerHTML = createEmptyState(t("history.none"));
    return;
  }

  container.innerHTML = `<div class="activity-feed">${sortedEntries.map(entry => `
    <article class="timeline-card">
      <div class="review-card-header">
        <div>
          <strong>${escapeHtml(getHistoryAuthorName(entry))}</strong>
          <div class="worklog-secondary">${escapeHtml(formatHistoryTimestamp(entry.timestamp))} | ${escapeHtml(formatRelativeTime(entry.timestamp))}</div>
        </div>
        ${getActionBadgeHtml(entry.action)}
      </div>
      ${renderHistorySubjectLine(entry)}
      <div class="timeline-card-message">${renderAuditMessage(entry.message || t("shared.noMessage"))}</div>
    </article>
  `).join("")}</div>`;
}

function renderHistoryCategory(config, clearInactive = true) {
  if (!config) {
    return;
  }

  renderHistoryList(
    document.getElementById(config.containerId),
    filteredHistoryEntriesByCategory[config.category]
  );

  if (clearInactive) {
    clearInactiveHistoryContainers(config.category);
  }
}

function renderHistoryTabs(historyEntries, targetConfig, clearInactive = true) {
  filteredHistoryEntriesByCategory = groupHistoryEntries(historyEntries);

  updateHistoryTabLabels(
    filteredHistoryEntriesByCategory.all,
    filteredHistoryEntriesByCategory.add,
    filteredHistoryEntriesByCategory.update,
    filteredHistoryEntriesByCategory.approval,
    filteredHistoryEntriesByCategory.delete
  );
  renderHistoryCategory(targetConfig || getActiveHistoryTabConfig(), clearInactive);
}

function applyHistoryFilters(targetConfig, clearInactive = true) {
  if (historyFilterTimerId !== null) {
    window.clearTimeout(historyFilterTimerId);
    historyFilterTimerId = null;
  }

  const searchTerm = document.getElementById("historySearchInput").value;
  const startDate = document.getElementById("historyStartDate").value;
  const endDate = document.getElementById("historyEndDate").value;
  const filtered = filterHistoryEntries(allHistoryEntries, searchTerm, startDate, endDate);
  renderHistoryTabs(filtered, targetConfig, clearInactive);
}

function scheduleHistoryFilterUpdate() {
  if (historyFilterTimerId !== null) {
    window.clearTimeout(historyFilterTimerId);
  }

  historyFilterTimerId = window.setTimeout(() => {
    historyFilterTimerId = null;
    applyHistoryFilters();
  }, HISTORY_FILTER_DEBOUNCE_MS);
}

document.getElementById("historySearchInput").addEventListener("input", scheduleHistoryFilterUpdate);
document.getElementById("historyStartDate").addEventListener("input", scheduleHistoryFilterUpdate);
document.getElementById("historyEndDate").addEventListener("input", scheduleHistoryFilterUpdate);
document.getElementById("historyResetFiltersBtn").addEventListener("click", () => {
  document.getElementById("historySearchInput").value = "";
  document.getElementById("historyStartDate").value = "";
  document.getElementById("historyEndDate").value = "";
  applyHistoryFilters();
});

document.getElementById("historyTabs").addEventListener("show.bs.tab", event => {
  const targetConfig = getHistoryTabConfig(event.target);
  if (!targetConfig) {
    return;
  }

  if (isHistoryLoading()) {
    setLoadingState(targetConfig.containerId, "activity", targetConfig.skeletonCount);
    return;
  }

  if (historyFilterTimerId !== null) {
    applyHistoryFilters(targetConfig, false);
    return;
  }

  renderHistoryCategory(targetConfig, false);
});

document.getElementById("historyTabs").addEventListener("shown.bs.tab", event => {
  const targetConfig = getHistoryTabConfig(event.target);
  if (targetConfig) {
    clearInactiveHistoryContainers(targetConfig.category);
  }
});

document.getElementById("refreshHistoryBtn").addEventListener("click", async event => {
  await runButtonAction(event.currentTarget, async () => {
    if (typeof loadReviewView === "function") {
      await loadReviewView();
      return;
    }

    await fetchHistory();
  }, { key: "review-refresh" });
});
updateHistoryTabLabels([], [], [], [], []);
