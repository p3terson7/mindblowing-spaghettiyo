let allHistoryEntries = [];

async function fetchHistory() {
  try {
    setLoadingState("allHistoryContainer", "activity", 4);
    setLoadingState("addHistoryContainer", "activity", 3);
    setLoadingState("editHistoryContainer", "activity", 3);
    setLoadingState("approveHistoryContainer", "activity", 3);
    setLoadingState("deleteHistoryContainer", "activity", 3);
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

    const combinedText = [entry.timestamp, entry.action, translateHistoryAction(entry.action), entry.employee, auditMessageToText(entry.message)].join(" ").toLowerCase();
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
          <strong>${escapeHtml(entry.employee || t("shared.system"))}</strong>
          <div class="worklog-secondary">${escapeHtml(formatHistoryTimestamp(entry.timestamp))} | ${escapeHtml(formatRelativeTime(entry.timestamp))}</div>
        </div>
        ${getActionBadgeHtml(entry.action)}
      </div>
      <div class="timeline-card-message">${renderAuditMessage(entry.message || t("shared.noMessage"))}</div>
    </article>
  `).join("")}</div>`;
}

function renderHistoryTabs(historyEntries) {
  const allContainer = document.getElementById("allHistoryContainer");
  const addContainer = document.getElementById("addHistoryContainer");
  const editContainer = document.getElementById("editHistoryContainer");
  const approveContainer = document.getElementById("approveHistoryContainer");
  const deleteContainer = document.getElementById("deleteHistoryContainer");

  const addedEntries = historyEntries.filter(entry => String(entry.action || "").toLowerCase() === "add");
  const updatedEntries = historyEntries.filter(entry => String(entry.action || "").toLowerCase() === "update");
  const approvalEntries = historyEntries.filter(entry => {
    const action = String(entry.action || "").toLowerCase();
    return action === "approved" || action === "rejected";
  });
  const deletedEntries = historyEntries.filter(entry => String(entry.action || "").toLowerCase() === "delete");

  updateHistoryTabLabels(historyEntries, addedEntries, updatedEntries, approvalEntries, deletedEntries);
  renderHistoryList(allContainer, historyEntries);
  renderHistoryList(addContainer, addedEntries);
  renderHistoryList(editContainer, updatedEntries);
  renderHistoryList(approveContainer, approvalEntries);
  renderHistoryList(deleteContainer, deletedEntries);
}

function applyHistoryFilters() {
  const searchTerm = document.getElementById("historySearchInput").value;
  const startDate = document.getElementById("historyStartDate").value;
  const endDate = document.getElementById("historyEndDate").value;
  const filtered = filterHistoryEntries(allHistoryEntries, searchTerm, startDate, endDate);
  renderHistoryTabs(filtered);
}

document.getElementById("historySearchInput").addEventListener("input", applyHistoryFilters);
document.getElementById("historyStartDate").addEventListener("input", applyHistoryFilters);
document.getElementById("historyEndDate").addEventListener("input", applyHistoryFilters);
document.getElementById("historyResetFiltersBtn").addEventListener("click", () => {
  document.getElementById("historySearchInput").value = "";
  document.getElementById("historyStartDate").value = "";
  document.getElementById("historyEndDate").value = "";
  applyHistoryFilters();
});

document.getElementById("refreshHistoryBtn").addEventListener("click", () => {
  if (typeof loadReviewView === "function") {
    loadReviewView();
    return;
  }

  fetchHistory();
});
updateHistoryTabLabels([], [], [], [], []);
