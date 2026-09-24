const bugReportViewState = {
  initialized: false,
  reports: [],
  selectedReport: null,
  listRequestId: 0,
  detailRequestId: 0,
  pendingAttachments: [],
  pendingUploadsLocked: false,
  detailObjectUrls: [],
  imageViewerTrigger: null,
};

const BUG_REPORT_ATTACHMENT_MAX_COUNT = 5;
const BUG_REPORT_ATTACHMENT_MAX_BYTES = 8 * 1024 * 1024;
const BUG_REPORT_ATTACHMENT_TYPES = new Set(["image/png", "image/jpeg", "image/gif", "image/webp"]);

const BUG_REPORT_STATUS_KEYS = Object.freeze({
  new: "bugReports.statusNew",
  acknowledged: "bugReports.statusAcknowledged",
  inProgress: "bugReports.statusInProgress",
  waitingForUser: "bugReports.statusWaitingForUser",
  resolved: "bugReports.statusResolved",
  closed: "bugReports.statusClosed",
});

// P1-P4 remain the shared-storage encoding for backward compatibility. The UI
// deliberately exposes them only as color codes, so existing reports do not
// need a risky migration on the network disk.
const BUG_REPORT_COLOR_CODE_KEYS = Object.freeze({
  unranked: "bugReports.colorNone",
  p1: "bugReports.colorRed",
  p2: "bugReports.colorOrange",
  p3: "bugReports.colorYellow",
  p4: "bugReports.colorBlue",
});

const BUG_REPORT_CATEGORY_KEYS = Object.freeze({
  bug: "bugReports.categoryBug",
  performance: "bugReports.categoryPerformance",
  visual: "bugReports.categoryVisual",
  data: "bugReports.categoryData",
  suggestion: "bugReports.categorySuggestion",
  other: "bugReports.categoryOther",
});

function getBugReportStatusLabel(status) {
  const key = BUG_REPORT_STATUS_KEYS[String(status || "")];
  return key ? t(key) : String(status || "—");
}

function getBugReportCategoryLabel(category) {
  const key = BUG_REPORT_CATEGORY_KEYS[String(category || "")];
  return key ? t(key) : String(category || "—");
}

function getBugReportColorCodeLabel(storedCode) {
  const normalized = String(storedCode || "unranked").toLowerCase();
  const key = BUG_REPORT_COLOR_CODE_KEYS[normalized] || BUG_REPORT_COLOR_CODE_KEYS.unranked;
  return t(key);
}

function getBugReportColorCodeDescription(storedCode) {
  const normalized = String(storedCode || "unranked").toLowerCase();
  const key = {
    unranked: "bugReports.colorHintNone",
    p1: "bugReports.colorHintRed",
    p2: "bugReports.colorHintOrange",
    p3: "bugReports.colorHintYellow",
    p4: "bugReports.colorHintBlue",
  }[normalized];
  return key ? t(key) : "";
}

function renderBugReportColorCodeBadge(storedCode) {
  const normalized = String(storedCode || "unranked").toLowerCase();
  if (!BUG_REPORT_COLOR_CODE_KEYS[normalized] || normalized === "unranked") return "";
  return `<span class="bug-report-color-code bug-report-color-code-${escapeHtml(normalized)}"><span class="bug-report-color-dot" aria-hidden="true"></span>${escapeHtml(getBugReportColorCodeLabel(normalized))}</span>`;
}

function syncBugReportColorSelect(select) {
  if (!select) return;
  const supportedCodes = ["p1", "p2", "p3", "p4", "unranked", "all"];
  supportedCodes.forEach(code => select.classList.remove(`bug-report-color-select-${code}`));
  const storedCode = String(select.value || "").toLowerCase();
  select.classList.add(`bug-report-color-select-${BUG_REPORT_COLOR_CODE_KEYS[storedCode] ? storedCode : "all"}`);
}

function renderBugReportComments(report) {
  const comments = Array.isArray(report && report.comments) ? report.comments : [];
  const currentUser = typeof getCurrentUser === "function" ? getCurrentUser() : null;
  const currentUsername = String(currentUser && currentUser.username || "");
  const closed = String(report && report.status || "").toLowerCase() === "closed";
  return `
    <div class="bug-report-detail-section bug-report-comments-section">
      <div class="bug-report-comments-heading">
        <h4>${escapeHtml(t("bugReports.discussion"))}</h4>
        <span>${escapeHtml(t("bugReports.commentCount", { count: comments.length }))}</span>
      </div>
      <div class="bug-report-comment-thread" id="bugReportCommentThread">
        ${comments.length ? comments.map(comment => {
          const actor = comment && comment.createdBy && typeof comment.createdBy === "object" ? comment.createdBy : {};
          const author = String(actor.displayName || actor.username || t("bugReports.systemActor"));
          const ownComment = currentUsername && String(actor.username || "").toLowerCase() === currentUsername.toLowerCase();
          const managerComment = ["admin", "superadmin"].includes(String(actor.role || "").toLowerCase());
          return `
            <article class="bug-report-comment${ownComment ? " is-own" : ""}${managerComment ? " is-manager" : ""}" data-bug-report-comment-id="${escapeHtml(comment.commentId)}">
              <header>
                <strong>${escapeHtml(author)}</strong>
                ${managerComment ? `<span class="bug-report-comment-role">${escapeHtml(t("bugReports.supportRole"))}</span>` : ""}
                <time datetime="${escapeHtml(comment.createdAtUtc)}">${escapeHtml(formatBugReportDate(comment.createdAtUtc))}</time>
              </header>
              <p>${escapeHtml(comment.body).replace(/\n/g, "<br>")}</p>
            </article>
          `;
        }).join("") : `
          <div class="bug-report-comments-empty">
            <i class="fa-regular fa-comments" aria-hidden="true"></i>
            <span>${escapeHtml(t("bugReports.noComments"))}</span>
          </div>
        `}
      </div>
      ${closed ? `
        <div class="bug-report-comments-closed">
          <i class="fa-solid fa-lock" aria-hidden="true"></i>
          <span>${escapeHtml(t("bugReports.commentsClosed"))}</span>
        </div>
      ` : `
        <form class="bug-report-comment-form" id="bugReportCommentForm" data-report-id="${escapeHtml(report.reportId)}">
          <label for="bugReportCommentInput">${escapeHtml(t("bugReports.addComment"))}</label>
          <textarea class="form-control" id="bugReportCommentInput" maxlength="3000" rows="3" required placeholder="${escapeHtml(t("bugReports.commentPlaceholder"))}"></textarea>
          <div class="bug-report-comment-actions">
            <span>
              <span id="bugReportCommentCount">0</span> / 3000 · ${escapeHtml(t("bugReports.commentVisibility"))}
            </span>
            <button type="submit" class="btn btn-primary btn-sm" id="bugReportCommentSubmitButton">
              <i class="fa-solid fa-paper-plane" aria-hidden="true"></i>
              <span>${escapeHtml(t("bugReports.sendComment"))}</span>
            </button>
          </div>
          <span class="bug-report-comment-message" id="bugReportCommentMessage" role="status" aria-live="polite"></span>
        </form>
      `}
    </div>
  `;
}

function getBugReportReporterLabel(report) {
  const createdBy = report && report.createdBy && typeof report.createdBy === "object" ? report.createdBy : {};
  return String(createdBy.displayName || createdBy.username || "").trim();
}

function formatBugReportDate(value) {
  const date = new Date(value);
  if (!value || Number.isNaN(date.getTime())) {
    return "—";
  }
  return date.toLocaleString(typeof getI18nLocale === "function" ? getI18nLocale() : undefined, {
    year: "numeric",
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
}

function setBugReportBusy(target, isBusy) {
  if (!target) {
    return;
  }
  target.setAttribute("aria-busy", isBusy ? "true" : "false");
}

function setBugReportCreateMessage(message, type = "danger") {
  const messageBox = document.getElementById("bugReportCreateMessage");
  if (!messageBox) {
    return;
  }
  messageBox.textContent = String(message || "");
  messageBox.className = message ? `alert alert-${type}` : "alert d-none";
}

function revokeBugReportDetailObjectUrls() {
  closeBugReportImageViewer(false);
  bugReportViewState.detailObjectUrls.forEach(url => URL.revokeObjectURL(url));
  bugReportViewState.detailObjectUrls = [];
}

function ensureBugReportImageViewer() {
  let viewer = document.getElementById("bugReportImageViewer");
  if (viewer) return viewer;
  viewer = document.createElement("div");
  viewer.id = "bugReportImageViewer";
  viewer.className = "bug-report-image-viewer";
  viewer.hidden = true;
  viewer.setAttribute("role", "dialog");
  viewer.setAttribute("aria-modal", "true");
  viewer.setAttribute("aria-labelledby", "bugReportImageViewerTitle");
  viewer.innerHTML = `
    <div class="bug-report-image-viewer-dialog">
      <div class="bug-report-image-viewer-toolbar">
        <strong id="bugReportImageViewerTitle"></strong>
        <div>
          <button type="button" class="bug-report-image-viewer-size" aria-pressed="false">
            <i class="fa-solid fa-magnifying-glass-plus" aria-hidden="true"></i>
            <span></span>
          </button>
          <button type="button" class="bug-report-image-viewer-close">
            <i class="fa-solid fa-xmark" aria-hidden="true"></i>
          </button>
        </div>
      </div>
      <div class="bug-report-image-viewer-stage">
        <img alt="">
      </div>
    </div>
  `;
  document.body.appendChild(viewer);
  viewer.addEventListener("click", event => {
    if (event.target === viewer || event.target.closest(".bug-report-image-viewer-close")) {
      closeBugReportImageViewer();
      return;
    }
    if (event.target.closest(".bug-report-image-viewer-size") || event.target.closest(".bug-report-image-viewer-stage img")) {
      setBugReportImageViewerActualSize(viewer, !viewer.classList.contains("is-actual-size"));
    }
  });
  return viewer;
}

function syncBugReportImageViewerLabels(viewer) {
  if (!viewer) return;
  const actualSize = viewer.classList.contains("is-actual-size");
  const sizeButton = viewer.querySelector(".bug-report-image-viewer-size");
  const closeButton = viewer.querySelector(".bug-report-image-viewer-close");
  if (sizeButton) {
    sizeButton.setAttribute("aria-label", t(actualSize ? "bugReports.fitImage" : "bugReports.actualSize"));
    sizeButton.querySelector("span").textContent = t(actualSize ? "bugReports.fitImage" : "bugReports.actualSize");
  }
  closeButton?.setAttribute("aria-label", t("bugReports.closeImage"));
}

function setBugReportImageViewerActualSize(viewer, actualSize) {
  if (!viewer) return;
  viewer.classList.toggle("is-actual-size", actualSize);
  const sizeButton = viewer.querySelector(".bug-report-image-viewer-size");
  sizeButton?.setAttribute("aria-pressed", actualSize ? "true" : "false");
  const icon = sizeButton?.querySelector("i");
  if (icon) icon.className = `fa-solid ${actualSize ? "fa-compress" : "fa-magnifying-glass-plus"}`;
  syncBugReportImageViewerLabels(viewer);
}

function openBugReportImageViewer(imageUrl, fileName, trigger) {
  if (!imageUrl) return;
  const viewer = ensureBugReportImageViewer();
  const image = viewer.querySelector(".bug-report-image-viewer-stage img");
  const title = viewer.querySelector("#bugReportImageViewerTitle");
  bugReportViewState.imageViewerTrigger = trigger || document.activeElement;
  title.textContent = String(fileName || t("bugReports.images"));
  image.src = imageUrl;
  image.alt = String(fileName || "");
  setBugReportImageViewerActualSize(viewer, false);
  viewer.hidden = false;
  document.body.classList.add("bug-report-image-viewer-open");
  viewer.querySelector(".bug-report-image-viewer-close")?.focus({ preventScroll: true });
}

function closeBugReportImageViewer(restoreFocus = true) {
  const viewer = document.getElementById("bugReportImageViewer");
  if (!viewer || viewer.hidden) return;
  viewer.hidden = true;
  viewer.classList.remove("is-actual-size");
  viewer.querySelector(".bug-report-image-viewer-stage img")?.removeAttribute("src");
  document.body.classList.remove("bug-report-image-viewer-open");
  if (restoreFocus) bugReportViewState.imageViewerTrigger?.focus({ preventScroll: true });
  bugReportViewState.imageViewerTrigger = null;
}

function clearBugReportPendingAttachments() {
  bugReportViewState.pendingAttachments.forEach(item => URL.revokeObjectURL(item.previewUrl));
  bugReportViewState.pendingAttachments = [];
  const input = document.getElementById("bugReportAttachmentInput");
  if (input) input.value = "";
  renderBugReportPendingAttachments();
}

function renderBugReportPendingAttachments() {
  const container = document.getElementById("bugReportPendingAttachments");
  const counter = document.getElementById("bugReportAttachmentCounter");
  if (counter) counter.textContent = `${bugReportViewState.pendingAttachments.length} / ${BUG_REPORT_ATTACHMENT_MAX_COUNT}`;
  if (!container) return;
  container.innerHTML = bugReportViewState.pendingAttachments.map((item, index) => `
    <article class="bug-report-pending-attachment${item.uploading ? " is-uploading" : ""}" data-pending-attachment-index="${index}">
      <img src="${escapeHtml(item.previewUrl)}" alt="">
      <span class="bug-report-pending-attachment-info">
        <strong title="${escapeHtml(item.file.name)}">${escapeHtml(item.file.name)}</strong>
        <small>${escapeHtml(formatBugReportFileSize(item.file.size))}</small>
      </span>
      ${item.uploading ? '<span class="bug-report-upload-spinner" aria-hidden="true"></span>' : (bugReportViewState.pendingUploadsLocked ? "" : `
        <button type="button" class="bug-report-remove-attachment" data-remove-pending-attachment="${index}" aria-label="${escapeHtml(t("bugReports.removeImage"))}">
          <i class="fa-solid fa-xmark" aria-hidden="true"></i>
        </button>
      `)}
    </article>
  `).join("");
  container.querySelectorAll("[data-remove-pending-attachment]").forEach(button => {
    button.addEventListener("click", () => {
      const index = Number(button.getAttribute("data-remove-pending-attachment"));
      const [removed] = bugReportViewState.pendingAttachments.splice(index, 1);
      if (removed) URL.revokeObjectURL(removed.previewUrl);
      renderBugReportPendingAttachments();
    });
  });
}

function formatBugReportFileSize(bytes) {
  const mb = Number(bytes || 0) / (1024 * 1024);
  return mb >= 1 ? `${mb.toFixed(1)} MB` : `${Math.max(1, Math.round(Number(bytes || 0) / 1024))} KB`;
}

function addBugReportAttachmentFiles(fileList) {
  if (bugReportViewState.pendingUploadsLocked) return;
  const files = Array.from(fileList || []);
  const errors = [];
  files.forEach(file => {
    if (bugReportViewState.pendingAttachments.length >= BUG_REPORT_ATTACHMENT_MAX_COUNT) {
      errors.push(t("bugReports.imageCountError"));
      return;
    }
    if (!BUG_REPORT_ATTACHMENT_TYPES.has(String(file.type || "").toLowerCase())) {
      errors.push(t("bugReports.imageTypeError", { name: file.name }));
      return;
    }
    if (!file.size || file.size > BUG_REPORT_ATTACHMENT_MAX_BYTES) {
      errors.push(t("bugReports.imageSizeError", { name: file.name }));
      return;
    }
    const duplicate = bugReportViewState.pendingAttachments.some(item =>
      item.file.name === file.name && item.file.size === file.size && item.file.lastModified === file.lastModified);
    if (!duplicate) {
      bugReportViewState.pendingAttachments.push({ file, previewUrl: URL.createObjectURL(file), uploading: false });
    }
  });
  renderBugReportPendingAttachments();
  if (errors.length) setBugReportCreateMessage([...new Set(errors)].join(" "), "warning");
}

function getBugReportFilters() {
  return {
    status: String(document.getElementById("bugReportStatusFilter")?.value || ""),
    priority: String(document.getElementById("bugReportColorCodeFilter")?.value || ""),
    category: String(document.getElementById("bugReportCategoryFilter")?.value || ""),
  };
}

function buildBugReportListUrl() {
  const filters = getBugReportFilters();
  const query = new URLSearchParams();
  query.set("scope", isManagerUser() ? "all" : "mine");
  Object.keys(filters).forEach(name => {
    if (filters[name]) {
      query.set(name, filters[name]);
    }
  });
  return `${apiUrl}bug-reports?${query.toString()}`;
}

function renderBugReportList() {
  const container = document.getElementById("bugReportList");
  const summary = document.getElementById("bugReportQueueSummary");
  if (!container) {
    return;
  }

  if (summary) {
    summary.textContent = t(bugReportViewState.reports.length === 1 ? "bugReports.queueCountOne" : "bugReports.queueCountMany", {
      count: bugReportViewState.reports.length,
    });
  }
  if (bugReportViewState.reports.length === 0) {
    container.innerHTML = `
      <div class="bug-report-empty-state">
        <i class="fa-regular fa-circle-check" aria-hidden="true"></i>
        <strong>${escapeHtml(t("bugReports.emptyTitle"))}</strong>
      </div>
    `;
    return;
  }

  container.innerHTML = bugReportViewState.reports.map(report => {
    const selected = bugReportViewState.selectedReport && bugReportViewState.selectedReport.reportId === report.reportId;
    const reporter = getBugReportReporterLabel(report);
    return `
      <button type="button" class="bug-report-card bug-report-card-color-${escapeHtml(String(report.priority || "unranked").toLowerCase())}${selected ? " is-selected" : ""}" data-bug-report-id="${escapeHtml(report.reportId)}" aria-pressed="${selected ? "true" : "false"}">
        <span class="bug-report-card-topline">
          <span class="bug-report-status bug-report-status-${escapeHtml(String(report.status || "new").toLowerCase())}">${escapeHtml(getBugReportStatusLabel(report.status))}</span>
          ${renderBugReportColorCodeBadge(report.priority)}
        </span>
        <strong class="bug-report-card-title">${escapeHtml(report.title)}</strong>
        <span class="bug-report-card-preview">${escapeHtml(report.descriptionPreview)}</span>
        <span class="bug-report-card-meta">
          <span><i class="fa-regular fa-folder" aria-hidden="true"></i>${escapeHtml(getBugReportCategoryLabel(report.category))}</span>
          ${reporter && isManagerUser() ? `<span><i class="fa-regular fa-user" aria-hidden="true"></i>${escapeHtml(reporter)}</span>` : ""}
          ${isManagerUser() && Number(report.rank) > 0 ? `<span><i class="fa-solid fa-arrow-down-1-9" aria-hidden="true"></i>${escapeHtml(t("bugReports.queueOrderShort", { rank: report.rank }))}</span>` : ""}
          ${Number(report.commentCount) > 0 ? `<span><i class="fa-regular fa-comment" aria-hidden="true"></i>${escapeHtml(String(report.commentCount))}</span>` : ""}
          <span><i class="fa-regular fa-clock" aria-hidden="true"></i>${escapeHtml(formatBugReportDate(report.updatedAtUtc))}</span>
        </span>
      </button>
    `;
  }).join("");

  container.querySelectorAll("[data-bug-report-id]").forEach(button => {
    button.addEventListener("click", () => {
      const reportId = String(button.getAttribute("data-bug-report-id") || "");
      runButtonAction(button, () => loadBugReportDetail(reportId), {
        key: `bug-report-detail:${reportId}`,
      }).catch(error => {
        showToast(error.message || t("bugReports.detailLoadError"), "error");
      });
    });
  });
}

function renderBugReportDetailEmpty() {
  const container = document.getElementById("bugReportDetail");
  if (!container) {
    return;
  }
  revokeBugReportDetailObjectUrls();
  container.innerHTML = `
    <div class="bug-report-detail-empty">
      <i class="fa-regular fa-message" aria-hidden="true"></i>
      <strong>${escapeHtml(t("bugReports.selectTitle"))}</strong>
    </div>
  `;
}

function renderBugReportDetail(report) {
  const container = document.getElementById("bugReportDetail");
  if (!container || !report) {
    return;
  }
  const reporter = getBugReportReporterLabel(report);
  const details = [
    ["bugReports.steps", report.stepsToReproduce],
    ["bugReports.expected", report.expectedBehavior],
    ["bugReports.actual", report.actualBehavior],
  ].filter(([, value]) => String(value || "").trim());
  const attachments = Array.isArray(report.attachments) ? report.attachments : [];
  const managerMetadata = isManagerUser() ? `
    <div><dt>${escapeHtml(t("bugReports.queueOrder"))}</dt><dd>${escapeHtml(Number(report.rank) > 0 ? String(report.rank) : t("bugReports.notOrdered"))}</dd></div>
  ` : "";
  revokeBugReportDetailObjectUrls();

  container.innerHTML = `
    <div class="bug-report-detail-header">
      <div>
        <div class="bug-report-detail-badges">
          <span class="bug-report-status bug-report-status-${escapeHtml(String(report.status || "new").toLowerCase())}">${escapeHtml(getBugReportStatusLabel(report.status))}</span>
          ${renderBugReportColorCodeBadge(report.priority)}
        </div>
        <h3>${escapeHtml(report.title)}</h3>
      </div>
      <span class="bug-report-revision">${escapeHtml(t("bugReports.revision", { revision: report.revision }))}</span>
    </div>
    <dl class="bug-report-detail-meta">
      <div><dt>${escapeHtml(t("bugReports.category"))}</dt><dd>${escapeHtml(getBugReportCategoryLabel(report.category))}</dd></div>
      ${reporter ? `<div><dt>${escapeHtml(t("bugReports.reporter"))}</dt><dd>${escapeHtml(reporter)}</dd></div>` : ""}
      <div><dt>${escapeHtml(t("bugReports.created"))}</dt><dd>${escapeHtml(formatBugReportDate(report.createdAtUtc))}</dd></div>
      <div><dt>${escapeHtml(t("bugReports.updated"))}</dt><dd>${escapeHtml(formatBugReportDate(report.updatedAtUtc))}</dd></div>
      ${managerMetadata}
    </dl>
    ${isSuperAdminUser() ? `
      <form class="bug-report-triage-panel" id="bugReportTriageForm" data-report-id="${escapeHtml(report.reportId)}">
        <div class="bug-report-triage-heading">
          <div>
            <span class="panel-kicker">${escapeHtml(t("bugReports.triageKicker"))}</span>
            <h4>${escapeHtml(t("bugReports.triageTitle"))}</h4>
          </div>
          <span class="bug-report-triage-revision">${escapeHtml(t("bugReports.revision", { revision: report.revision }))}</span>
        </div>
        <div class="bug-report-triage-grid">
          <label>
            <span>${escapeHtml(t("bugReports.status"))}</span>
            <select class="form-select form-select-sm" id="bugReportTriageStatus">
              ${Object.keys(BUG_REPORT_STATUS_KEYS).map(status => `<option value="${status}"${report.status === status ? " selected" : ""}>${escapeHtml(getBugReportStatusLabel(status))}</option>`).join("")}
            </select>
          </label>
          <label>
            <span>${escapeHtml(t("bugReports.colorCode"))}</span>
            <select class="form-select form-select-sm bug-report-color-select" id="bugReportTriageColorCode">
              ${Object.keys(BUG_REPORT_COLOR_CODE_KEYS).map(storedCode => `<option value="${storedCode}"${report.priority === storedCode ? " selected" : ""}>${escapeHtml(getBugReportColorCodeLabel(storedCode))}</option>`).join("")}
            </select>
          </label>
          <label>
            <span>${escapeHtml(t("bugReports.queueOrder"))}</span>
            <input class="form-control form-control-sm" type="number" id="bugReportTriageRank" min="0" max="2147483647" step="1" value="${escapeHtml(String(Number(report.rank) || 0))}" required>
          </label>
        </div>
        <div class="bug-report-color-guidance" id="bugReportColorGuidance"${getBugReportColorCodeDescription(report.priority) ? "" : " hidden"}>
          <i class="fa-solid fa-circle-info" aria-hidden="true"></i>
          <span>${escapeHtml(getBugReportColorCodeDescription(report.priority))}</span>
        </div>
        <div class="bug-report-triage-actions">
          <span class="bug-report-triage-message" id="bugReportTriageMessage" role="status" aria-live="polite"></span>
          <button type="submit" class="btn btn-primary btn-sm" id="bugReportTriageSaveButton" disabled>
            <i class="fa-solid fa-check" aria-hidden="true"></i>
            <span>${escapeHtml(t("bugReports.saveTriage"))}</span>
          </button>
        </div>
      </form>
    ` : ""}
    <div class="bug-report-detail-section">
      <h4>${escapeHtml(t("bugReports.description"))}</h4>
      <p>${escapeHtml(report.description).replace(/\n/g, "<br>")}</p>
    </div>
    ${details.map(([labelKey, value]) => `
      <div class="bug-report-detail-section">
        <h4>${escapeHtml(t(labelKey))}</h4>
        <p>${escapeHtml(value).replace(/\n/g, "<br>")}</p>
      </div>
    `).join("")}
    ${attachments.length ? `
      <div class="bug-report-detail-section">
        <h4>${escapeHtml(t("bugReports.images"))}</h4>
        <div class="bug-report-attachment-gallery">
          ${attachments.map(attachment => `
            <button type="button" class="bug-report-attachment-preview is-loading" data-bug-report-attachment-id="${escapeHtml(attachment.attachmentId)}" data-bug-report-attachment-name="${escapeHtml(attachment.fileName)}" aria-label="${escapeHtml(t("bugReports.openImage", { name: attachment.fileName }))}">
              <span class="bug-report-upload-spinner" aria-hidden="true"></span>
              <span>${escapeHtml(attachment.fileName)}</span>
            </button>
          `).join("")}
        </div>
      </div>
    ` : ""}
    ${renderBugReportComments(report)}
    <div class="bug-report-detail-footer">
      <span><i class="fa-regular fa-image" aria-hidden="true"></i>${escapeHtml(t("bugReports.attachmentCount", { count: Array.isArray(report.attachments) ? report.attachments.length : 0 }))}</span>
      <span><i class="fa-regular fa-comment" aria-hidden="true"></i>${escapeHtml(t("bugReports.commentCount", { count: Array.isArray(report.comments) ? report.comments.length : 0 }))}</span>
    </div>
  `;
  bindBugReportTriageControls(report);
  bindBugReportCommentComposer(report);
}

function setBugReportCommentMessage(message, type = "") {
  const target = document.getElementById("bugReportCommentMessage");
  if (!target) return;
  target.textContent = String(message || "");
  target.className = `bug-report-comment-message${type ? ` is-${type}` : ""}`;
}

function bindBugReportCommentComposer(report) {
  const form = document.getElementById("bugReportCommentForm");
  const input = document.getElementById("bugReportCommentInput");
  const count = document.getElementById("bugReportCommentCount");
  if (!form || !input) return;
  input.addEventListener("input", () => {
    if (count) count.textContent = String(input.value.length);
    setBugReportCommentMessage("");
  });
  form.addEventListener("submit", event => submitBugReportComment(event, report));
}

async function submitBugReportComment(event, report) {
  event.preventDefault();
  const form = event.currentTarget;
  const input = document.getElementById("bugReportCommentInput");
  const submitButton = document.getElementById("bugReportCommentSubmitButton");
  if (!form || !input || !submitButton || !form.reportValidity()) return false;
  const body = String(input.value || "").trim();
  if (!body) {
    setBugReportCommentMessage(t("bugReports.commentRequired"), "error");
    return false;
  }
  setBugReportCommentMessage(t("bugReports.sendingComment"));
  return runButtonAction(submitButton, async () => {
    const response = await fetch(`${apiUrl}bug-reports/${encodeURIComponent(report.reportId)}/comments`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ expectedRevision: report.revision, body }),
    });
    try {
      const result = await parseResponse(response);
      const updatedReport = result && result.report ? result.report : null;
      if (!updatedReport) throw new Error(t("bugReports.commentSendError"));
      bugReportViewState.selectedReport = updatedReport;
      renderBugReportDetail(updatedReport);
      loadBugReportAttachmentPreviews(updatedReport, bugReportViewState.detailRequestId);
      await loadBugReportList();
      const commentId = String(result.comment && result.comment.commentId || "");
      if (commentId) {
        window.requestAnimationFrame(() => {
          document.querySelector(`[data-bug-report-comment-id="${CSS.escape(commentId)}"]`)?.scrollIntoView({ behavior: "smooth", block: "nearest" });
        });
      }
      showToast(t("bugReports.commentSent"), "success");
      return true;
    } catch (error) {
      if (response.status === 409) {
        showToast(t("bugReports.commentConflict"), "warning");
        await loadBugReportDetail(report.reportId);
        return false;
      }
      setBugReportCommentMessage(error.message || t("bugReports.commentSendError"), "error");
      return false;
    }
  }, {
    key: `bug-report-comment:${report.reportId}`,
    disableWhileRunning: () => form.querySelectorAll("textarea, button"),
  });
}

function getBugReportTriageValues() {
  return {
    status: String(document.getElementById("bugReportTriageStatus")?.value || "new"),
    priority: String(document.getElementById("bugReportTriageColorCode")?.value || "unranked"),
    rank: Number(document.getElementById("bugReportTriageRank")?.value || 0),
  };
}

function setBugReportTriageMessage(message, type = "") {
  const target = document.getElementById("bugReportTriageMessage");
  if (!target) return;
  target.textContent = String(message || "");
  target.className = `bug-report-triage-message${type ? ` is-${type}` : ""}`;
}

function bindBugReportTriageControls(report) {
  const form = document.getElementById("bugReportTriageForm");
  const saveButton = document.getElementById("bugReportTriageSaveButton");
  if (!form || !saveButton) return;
  const colorSelect = document.getElementById("bugReportTriageColorCode");
  const original = {
    status: String(report.status || "new"),
    priority: String(report.priority || "unranked"),
    rank: Number(report.rank || 0),
  };
  const updateState = () => {
    const values = getBugReportTriageValues();
    syncBugReportColorSelect(colorSelect);
    const dirty = Object.keys(original).some(key => values[key] !== original[key]);
    saveButton.disabled = !dirty;
    const guidance = document.querySelector("#bugReportColorGuidance span");
    if (guidance) {
      const description = getBugReportColorCodeDescription(values.priority);
      guidance.textContent = description;
      guidance.parentElement.hidden = !description;
    }
    setBugReportTriageMessage(dirty ? t("bugReports.unsavedTriage") : "");
  };
  form.querySelectorAll("input, select").forEach(control => {
    control.addEventListener("input", updateState);
    control.addEventListener("change", updateState);
  });
  syncBugReportColorSelect(colorSelect);
  form.addEventListener("submit", event => submitBugReportTriage(event, report));
}

async function submitBugReportTriage(event, report) {
  event.preventDefault();
  const form = event.currentTarget;
  const saveButton = document.getElementById("bugReportTriageSaveButton");
  if (!form || !saveButton || !form.reportValidity()) return false;
  const values = getBugReportTriageValues();
  if (!Number.isInteger(values.rank) || values.rank < 0 || values.rank > 2147483647) {
    setBugReportTriageMessage(t("bugReports.queueOrderError"), "error");
    return false;
  }
  setBugReportTriageMessage(t("bugReports.savingTriage"));
  return runButtonAction(saveButton, async () => {
    const response = await fetch(`${apiUrl}bug-reports/${encodeURIComponent(report.reportId)}`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ expectedRevision: report.revision, ...values }),
    });
    try {
      const result = await parseResponse(response);
      const updatedReport = result && result.report ? result.report : null;
      if (!updatedReport) throw new Error(t("bugReports.triageSaveError"));
      bugReportViewState.selectedReport = updatedReport;
      renderBugReportDetail(updatedReport);
      loadBugReportAttachmentPreviews(updatedReport, bugReportViewState.detailRequestId);
      await loadBugReportList();
      showToast(t("bugReports.triageSaveSuccess"), "success");
      return true;
    } catch (error) {
      if (response.status === 409) {
        showToast(t("bugReports.triageConflict"), "warning");
        await loadBugReportDetail(report.reportId);
        return false;
      }
      setBugReportTriageMessage(error.message || t("bugReports.triageSaveError"), "error");
      return false;
    }
  }, {
    key: `bug-report-triage:${report.reportId}`,
    disableWhileRunning: () => form.querySelectorAll("input, select, button"),
  });
}

async function loadBugReportAttachmentPreviews(report, requestId) {
  const attachments = Array.isArray(report && report.attachments) ? report.attachments : [];
  await Promise.all(attachments.map(async attachment => {
    const selector = `[data-bug-report-attachment-id="${CSS.escape(String(attachment.attachmentId || ""))}"]`;
    const tile = document.querySelector(selector);
    if (!tile) return;
    try {
      const response = await fetch(`${apiUrl}bug-reports/${encodeURIComponent(report.reportId)}/attachments/${encodeURIComponent(attachment.attachmentId)}`, { cache: "no-store" });
      if (!response.ok) throw new Error(t("bugReports.imageLoadError"));
      const blob = await response.blob();
      if (requestId !== bugReportViewState.detailRequestId) return;
      const objectUrl = URL.createObjectURL(blob);
      bugReportViewState.detailObjectUrls.push(objectUrl);
      tile.dataset.bugReportImageUrl = objectUrl;
      tile.innerHTML = `<img src="${escapeHtml(objectUrl)}" alt="${escapeHtml(attachment.fileName)}"><span>${escapeHtml(attachment.fileName)}</span>`;
      tile.classList.remove("is-loading");
    } catch (error) {
      tile.classList.remove("is-loading");
      tile.classList.add("is-error");
      tile.innerHTML = `<i class="fa-solid fa-triangle-exclamation" aria-hidden="true"></i><span>${escapeHtml(attachment.fileName)}</span>`;
      delete tile.dataset.bugReportImageUrl;
    }
  }));
}

async function loadBugReportDetail(reportId) {
  const normalizedId = String(reportId || "").trim();
  if (!normalizedId) {
    return false;
  }
  const container = document.getElementById("bugReportDetail");
  const requestId = ++bugReportViewState.detailRequestId;
  setBugReportBusy(container, true);
  setLoadingState(container, "detail", 1);
  try {
    const response = await fetch(`${apiUrl}bug-reports/${encodeURIComponent(normalizedId)}`, { cache: "no-store" });
    const report = await parseResponse(response);
    if (requestId !== bugReportViewState.detailRequestId) {
      return false;
    }
    bugReportViewState.selectedReport = report;
    renderBugReportList();
    renderBugReportDetail(report);
    loadBugReportAttachmentPreviews(report, requestId);
    return true;
  } catch (error) {
    if (requestId === bugReportViewState.detailRequestId && container) {
      container.innerHTML = `
        <div class="bug-report-empty-state is-error">
          <i class="fa-solid fa-triangle-exclamation" aria-hidden="true"></i>
          <strong>${escapeHtml(t("bugReports.detailLoadError"))}</strong>
          <span>${escapeHtml(error.message || t("bugReports.tryAgain"))}</span>
        </div>
      `;
    }
    throw error;
  } finally {
    if (requestId === bugReportViewState.detailRequestId) {
      setBugReportBusy(container, false);
    }
  }
}

async function loadBugReportList() {
  const container = document.getElementById("bugReportList");
  const requestId = ++bugReportViewState.listRequestId;
  setBugReportBusy(container, true);
  setLoadingState(container, "list", 4);
  try {
    const response = await fetch(buildBugReportListUrl(), { cache: "no-store" });
    const payload = await parseResponse(response);
    if (requestId !== bugReportViewState.listRequestId) {
      return false;
    }
    bugReportViewState.reports = Array.isArray(payload.reports) ? payload.reports : [];
    if (bugReportViewState.selectedReport && !bugReportViewState.reports.some(report => report.reportId === bugReportViewState.selectedReport.reportId)) {
      bugReportViewState.selectedReport = null;
      renderBugReportDetailEmpty();
    }
    renderBugReportList();
    return true;
  } catch (error) {
    if (requestId === bugReportViewState.listRequestId && container) {
      container.innerHTML = `
        <div class="bug-report-empty-state is-error">
          <i class="fa-solid fa-triangle-exclamation" aria-hidden="true"></i>
          <strong>${escapeHtml(t("bugReports.listLoadError"))}</strong>
          <span>${escapeHtml(error.message || t("bugReports.tryAgain"))}</span>
        </div>
      `;
    }
    return false;
  } finally {
    if (requestId === bugReportViewState.listRequestId) {
      setBugReportBusy(container, false);
    }
  }
}

function openBugReportCreatePanel() {
  const panel = document.getElementById("bugReportCreatePanel");
  const titleInput = document.getElementById("bugReportTitleInput");
  if (!panel) {
    return;
  }
  setBugReportCreateMessage("");
  panel.classList.remove("d-none");
  panel.scrollIntoView({ behavior: "smooth", block: "start" });
  window.setTimeout(() => titleInput?.focus({ preventScroll: true }), 180);
}

function closeBugReportCreatePanel() {
  document.getElementById("bugReportCreatePanel")?.classList.add("d-none");
  clearBugReportPendingAttachments();
  document.getElementById("bugReportOpenCreateButton")?.focus({ preventScroll: true });
}

function getBugReportCreatePayload() {
  return {
    title: String(document.getElementById("bugReportTitleInput")?.value || "").trim(),
    description: String(document.getElementById("bugReportDescriptionInput")?.value || "").trim(),
    category: String(document.getElementById("bugReportCategoryInput")?.value || "bug"),
    stepsToReproduce: String(document.getElementById("bugReportStepsInput")?.value || "").trim(),
    expectedBehavior: String(document.getElementById("bugReportExpectedInput")?.value || "").trim(),
    actualBehavior: String(document.getElementById("bugReportActualInput")?.value || "").trim(),
    technicalContext: {
      appVersion: "20260924-bug-report-minimal-v3",
      page: String(window.location && window.location.hash || "") || String(typeof window.getActiveAppViewId === "function" ? window.getActiveAppViewId() : "bugReportsView"),
      browser: String(navigator.userAgent || "").slice(0, 500),
      operatingSystem: String(navigator.platform || "").slice(0, 300),
      language: String(navigator.language || "").slice(0, 50),
    },
  };
}

async function submitBugReport(event) {
  event.preventDefault();
  const form = document.getElementById("bugReportCreateForm");
  const submitButton = document.getElementById("bugReportCreateSubmitButton");
  if (!form || !form.reportValidity()) {
    return;
  }
  const payload = getBugReportCreatePayload();
  setBugReportCreateMessage("");
  return runButtonAction(submitButton, async () => {
    try {
      const attachmentsToUpload = [...bugReportViewState.pendingAttachments];
      bugReportViewState.pendingUploadsLocked = true;
      renderBugReportPendingAttachments();
      const response = await fetch(`${apiUrl}bug-reports`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload),
      });
      const result = await parseResponse(response);
      let report = result && result.report ? result.report : null;
      let failedUploads = 0;
      for (let index = 0; report && index < attachmentsToUpload.length; index += 1) {
        const item = attachmentsToUpload[index];
        item.uploading = true;
        renderBugReportPendingAttachments();
        try {
          const uploadResponse = await fetch(`${apiUrl}bug-reports/${encodeURIComponent(report.reportId)}/attachments`, {
            method: "POST",
            headers: {
              "Content-Type": item.file.type,
              "X-SAPHIR-Expected-Revision": String(report.revision),
              "X-SAPHIR-File-Name": encodeURIComponent(item.file.name),
            },
            body: item.file,
          });
          const uploadResult = await parseResponse(uploadResponse);
          report = uploadResult && uploadResult.report ? uploadResult.report : report;
        } catch (error) {
          failedUploads += 1;
        } finally {
          item.uploading = false;
        }
      }
      form.reset();
      clearBugReportPendingAttachments();
      closeBugReportCreatePanel();
      showToast(failedUploads ? t("bugReports.createPartialSuccess", { count: failedUploads }) : t("bugReports.createSuccess"), failedUploads ? "warning" : "success");
      await loadBugReportList();
      if (report && report.reportId) {
        await loadBugReportDetail(report.reportId);
      }
    } catch (error) {
      setBugReportCreateMessage(error.message || t("bugReports.createError"), "danger");
    } finally {
      bugReportViewState.pendingUploadsLocked = false;
      renderBugReportPendingAttachments();
    }
  }, {
    key: "bug-report-create",
    disableWhileRunning: () => form.querySelectorAll("input, select, textarea, button"),
  });
}

function initializeBugReportsView() {
  if (bugReportViewState.initialized) {
    return;
  }
  bugReportViewState.initialized = true;
  document.getElementById("bugReportOpenCreateButton")?.addEventListener("click", openBugReportCreatePanel);
  document.getElementById("bugReportCreateCloseButton")?.addEventListener("click", closeBugReportCreatePanel);
  document.getElementById("bugReportCreateForm")?.addEventListener("submit", submitBugReport);
  const attachmentInput = document.getElementById("bugReportAttachmentInput");
  const dropZone = document.getElementById("bugReportDropZone");
  dropZone?.addEventListener("click", () => attachmentInput?.click());
  dropZone?.addEventListener("dragover", event => {
    event.preventDefault();
    dropZone.classList.add("is-dragging");
  });
  dropZone?.addEventListener("dragleave", () => dropZone.classList.remove("is-dragging"));
  dropZone?.addEventListener("drop", event => {
    event.preventDefault();
    dropZone.classList.remove("is-dragging");
    addBugReportAttachmentFiles(event.dataTransfer?.files);
  });
  attachmentInput?.addEventListener("change", event => addBugReportAttachmentFiles(event.target.files));
  document.getElementById("bugReportRefreshButton")?.addEventListener("click", event => {
    runButtonAction(event.currentTarget, loadBugReportList, { key: "bug-report-list" });
  });
  ["bugReportStatusFilter", "bugReportColorCodeFilter", "bugReportCategoryFilter"].forEach(id => {
    const filter = document.getElementById(id);
    filter?.addEventListener("change", () => {
      if (id === "bugReportColorCodeFilter") syncBugReportColorSelect(filter);
      loadBugReportList();
    });
  });
  syncBugReportColorSelect(document.getElementById("bugReportColorCodeFilter"));
  document.getElementById("bugReportDetail")?.addEventListener("click", event => {
    const preview = event.target.closest(".bug-report-attachment-preview[data-bug-report-image-url]");
    if (!preview) return;
    openBugReportImageViewer(
      preview.dataset.bugReportImageUrl,
      preview.dataset.bugReportAttachmentName,
      preview,
    );
  });
  document.addEventListener("keydown", event => {
    if (event.key === "Escape") closeBugReportImageViewer();
  });
}

async function refreshBugReportsView() {
  initializeBugReportsView();
  return loadBugReportList();
}

function rerenderBugReportsViewForLanguageChange() {
  renderBugReportList();
  if (bugReportViewState.selectedReport) {
    renderBugReportDetail(bugReportViewState.selectedReport);
    loadBugReportAttachmentPreviews(bugReportViewState.selectedReport, bugReportViewState.detailRequestId);
  } else {
    renderBugReportDetailEmpty();
  }
  syncBugReportImageViewerLabels(document.getElementById("bugReportImageViewer"));
}

window.openBugReportCreatePanel = openBugReportCreatePanel;
window.refreshBugReportsView = refreshBugReportsView;
window.rerenderBugReportsViewForLanguageChange = rerenderBugReportsViewForLanguageChange;
