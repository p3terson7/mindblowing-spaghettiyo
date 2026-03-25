let allHistoryEntries = [];

async function fetchHistory() {
  try {
    const response = await fetch(apiUrl + "history");
    const historyEntries = await parseResponse(response);
    allHistoryEntries = Array.isArray(historyEntries) ? historyEntries : [];
    renderHistoryTabs(allHistoryEntries);
  } catch (error) {
    console.error("Error fetching history:", error);
    showToast("Error fetching history", "error");
  }
}

function formatHistoryTimestamp(timestamp) {
  if (!timestamp) {
    return "Unknown time";
  }

  const normalized = String(timestamp).replace(" ", "T");
  const date = new Date(normalized);
  if (Number.isNaN(date.getTime())) {
    return String(timestamp);
  }

  return date.toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" }) + " | " + date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
}

function filterHistoryEntries(entries, searchTerm) {
  const tokens = String(searchTerm || "").toLowerCase().split(/\s+/).filter(token => token.length > 0);
  if (tokens.length === 0) {
    return entries;
  }

  return entries.filter(entry => {
    const combinedText = [entry.timestamp, entry.action, entry.employee, entry.message].join(" ").toLowerCase();
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
  return `<span class="action-badge ${tone}">${escapeHtml(action || "Event")}</span>`;
}

function updateHistoryTabLabels(allEntries, addedEntries, updatedEntries, approvalEntries, deletedEntries) {
  document.getElementById("all-history-tab").textContent = `All (${allEntries.length})`;
  document.getElementById("add-history-tab").textContent = `Added (${addedEntries.length})`;
  document.getElementById("edit-history-tab").textContent = `Updated (${updatedEntries.length})`;
  document.getElementById("approve-history-tab").textContent = `Approved / Rejected (${approvalEntries.length})`;
  document.getElementById("delete-history-tab").textContent = `Deleted (${deletedEntries.length})`;
}

function renderHistoryList(container, entries) {
  const sortedEntries = (entries || []).slice().sort((left, right) => new Date(right.timestamp) - new Date(left.timestamp));
  if (sortedEntries.length === 0) {
    container.innerHTML = createEmptyState("No history entries match this filter.");
    return;
  }

  container.innerHTML = `<div class="activity-feed">${sortedEntries.map(entry => `
    <article class="timeline-card">
      <div class="review-card-header">
        <div>
          <strong>${escapeHtml(entry.employee || "System")}</strong>
          <div class="worklog-secondary">${escapeHtml(formatHistoryTimestamp(entry.timestamp))} | ${escapeHtml(formatRelativeTime(entry.timestamp))}</div>
        </div>
        ${getActionBadgeHtml(entry.action)}
      </div>
      <div class="timeline-card-message">${entry.message || "No message provided."}</div>
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

document.getElementById("historySearchInput").addEventListener("input", function () {
  const searchTerm = this.value;
  const filtered = filterHistoryEntries(allHistoryEntries, searchTerm);
  renderHistoryTabs(filtered);
});

document.getElementById("refreshHistoryBtn").addEventListener("click", fetchHistory);
