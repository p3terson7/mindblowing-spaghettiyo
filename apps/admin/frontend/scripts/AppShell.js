const APP_API_URL_KEY = "overtimeAppApiUrl";
const APP_SESSION_KEY = "overtimeAppSession";
const APP_THEME_KEY = "overtimeAppTheme";
const APP_SYNC_POLL_VISIBLE_MS = 10000;
const APP_SYNC_POLL_HIDDEN_MS = 30000;
const LEGACY_API_URL_KEYS = ["adminApiUrl", "employeeApiUrl"];
const LEGACY_SESSION_KEYS = ["adminSession", "employeeSession"];
const ROLE_VIEW_MAP = {
  superAdmin: ["dashboardView", "employeesView", "adminView", "projectsView"],
  admin: ["dashboardView", "employeesView", "adminView", "projectsView"],
  employee: ["selfView"],
};

function normalizeClientRole(role) {
  const normalized = String(role || "").trim().toLowerCase().replace(/[\s_-]/g, "");
  if (normalized === "superadmin" || normalized === "super") {
    return "superAdmin";
  }
  if (normalized === "admin") {
    return "admin";
  }
  return "employee";
}

function isSuperAdminUser(user = getCurrentUser()) {
  return Boolean(user && normalizeClientRole(user.role) === "superAdmin");
}

function isManagerUser(user = getCurrentUser()) {
  const role = user ? normalizeClientRole(user.role) : "";
  return role === "admin" || role === "superAdmin";
}

function userHasEmployeeWorkspace(user = getCurrentUser()) {
  return Boolean(user && user.employeeCode);
}

function getStoredTheme() {
  return localStorage.getItem(APP_THEME_KEY) === "dark" ? "dark" : "light";
}

function updateThemeToggle(theme) {
  const toggleButton = document.getElementById("appThemeToggleButton");
  const toggleText = document.getElementById("appThemeToggleText");
  if (!toggleButton || !toggleText) {
    updateSettingsThemeOptions(theme);
    return;
  }

  const nextTheme = theme === "dark" ? "light" : "dark";
  const icon = toggleButton.querySelector("i");
  if (icon) {
    icon.className = nextTheme === "dark" ? "fa-solid fa-moon" : "fa-solid fa-sun";
  }
  toggleText.textContent = t(nextTheme === "dark" ? "theme.dark" : "theme.light");
  toggleButton.setAttribute("aria-label", t("theme.label"));
  toggleButton.setAttribute("title", t("theme.label"));
  updateSettingsThemeOptions(theme);
}

function updateSettingsThemeOptions(theme) {
  document.querySelectorAll("[data-settings-theme]").forEach(button => {
    const isActive = button.getAttribute("data-settings-theme") === theme;
    button.classList.toggle("active", isActive);
    button.setAttribute("aria-pressed", isActive ? "true" : "false");
  });
}

function applyAppTheme(theme) {
  const resolvedTheme = theme === "dark" ? "dark" : "light";
  document.documentElement.setAttribute("data-theme", resolvedTheme);
  localStorage.setItem(APP_THEME_KEY, resolvedTheme);
  updateThemeToggle(resolvedTheme);
  window.dispatchEvent(new CustomEvent("app:theme-changed", {
    detail: {
      theme: resolvedTheme,
    },
  }));
}

function toggleAppTheme() {
  applyAppTheme(getStoredTheme() === "dark" ? "light" : "dark");
}

const appShellState = {
  nativeFetch: window.fetch.bind(window),
  initialized: false,
  syncTimerId: null,
  lastSyncVersion: null,
  syncRequestInFlight: false,
  getRequestInflight: {},
  viewState: {},
  storedSession: null,
  storedSessionLoaded: false,
};

function resetViewState() {
  appShellState.viewState = {};
}

function clearClientLookupCaches() {
  if (typeof clearLookupCaches === "function") {
    clearLookupCaches();
    return;
  }

  if (typeof clearOvertimeEntryLookupCache === "function") {
    clearOvertimeEntryLookupCache();
  }
  if (typeof clearScopedProjectLookupCache === "function") {
    clearScopedProjectLookupCache();
  }
}

function ensureViewState(viewId) {
  if (!appShellState.viewState[viewId]) {
    appShellState.viewState[viewId] = {
      loaded: false,
      stale: true,
      refreshPromise: null,
      lastLoadedAt: null,
    };
  }

  return appShellState.viewState[viewId];
}

function markViewsStale(viewIds) {
  (viewIds || []).forEach(viewId => {
    if (!viewId) {
      return;
    }

    const state = ensureViewState(viewId);
    state.stale = true;
  });
}

function getActiveViewId() {
  return document.querySelector(".view.active")?.id || localStorage.getItem("activeView") || "";
}

function requestViewRefresh(viewIds, options = {}) {
  const affectedViews = Array.isArray(viewIds) ? viewIds.filter(Boolean) : [];
  markViewsStale(affectedViews);

  if (options.refreshActive === false) {
    return Promise.resolve();
  }

  const activeViewId = getActiveViewId();
  if (!activeViewId || affectedViews.indexOf(activeViewId) < 0) {
    return Promise.resolve();
  }

  return refreshViewById(activeViewId, {
    force: !!options.forceActive,
  });
}

function markAllowedViewsStale(user) {
  markViewsStale(getAllowedViewsForUser(user));
}

function getViewsAffectedBySyncState(syncState) {
  const user = getCurrentUser();
  const category = String(syncState && syncState.category || "").toLowerCase();
  const resource = String(syncState && syncState.resource || "");

  if (!user) {
    return [];
  }

  if (category === "seed") {
    return getAllowedViewsForUser(user);
  }

  if (category === "history") {
    return isManagerUser(user)
      ? ["dashboardView", "adminView"]
      : [];
  }

  if (category === "employee-directory") {
    return isManagerUser(user)
      ? ["dashboardView", "employeesView"]
      : [];
  }

  if (category === "project") {
    return isManagerUser(user)
      ? ["dashboardView", "projectsView"]
      : ["selfView"];
  }

  if (category === "auth") {
    if (isManagerUser(user)) {
      return ["employeesView"];
    }

    return resource && user.employeeCode === resource
      ? ["selfView"]
      : [];
  }

  if (category === "employee") {
    if (isManagerUser(user)) {
      return ["dashboardView", "employeesView", "adminView", "projectsView"];
    }

    return resource && user.employeeCode === resource
      ? ["selfView"]
      : [];
  }

  return getAllowedViewsForUser(user);
}

function normalizeApiUrl(value, fallbackValue) {
  const rawValue = String(value || fallbackValue || "").trim();
  if (!rawValue) {
    return "";
  }

  return rawValue.endsWith("/") ? rawValue : `${rawValue}/`;
}

function upgradeLegacyEmployeeApiUrl(value) {
  if (!value) {
    return value;
  }

  try {
    const parsed = new URL(value, window.location.href);
    const isLocalHost = parsed.hostname === "localhost" || parsed.hostname === "127.0.0.1";
    if (isLocalHost && parsed.port === "8080") {
      parsed.port = "8081";
      return parsed.toString();
    }
  } catch (error) {
    return value;
  }

  return value;
}

function getStoredApiUrl() {
  const currentValue = localStorage.getItem(APP_API_URL_KEY);
  if (currentValue) {
    return normalizeApiUrl(currentValue, window.defaultApiUrl);
  }

  const legacyAdminUrl = localStorage.getItem("adminApiUrl");
  if (legacyAdminUrl) {
    return normalizeApiUrl(legacyAdminUrl, window.defaultApiUrl);
  }

  const legacyEmployeeUrl = localStorage.getItem("employeeApiUrl");
  if (legacyEmployeeUrl) {
    return normalizeApiUrl(upgradeLegacyEmployeeApiUrl(legacyEmployeeUrl), window.defaultApiUrl);
  }

  return normalizeApiUrl(window.defaultApiUrl, window.defaultApiUrl);
}

function updateConnectionDisplay() {
  const apiInput = document.getElementById("apiUrlInput");

  if (apiInput) {
    apiInput.value = window.apiUrl;
  }
}

function setStoredApiUrl(value) {
  window.apiUrl = normalizeApiUrl(value, window.defaultApiUrl);
  localStorage.setItem(APP_API_URL_KEY, window.apiUrl);
  LEGACY_API_URL_KEYS.forEach(key => localStorage.removeItem(key));
  updateConnectionDisplay();
}

function tryReadSession(key) {
  try {
    const rawValue = localStorage.getItem(key);
    return rawValue ? JSON.parse(rawValue) : null;
  } catch (error) {
    return null;
  }
}

function getStoredSession() {
  if (appShellState.storedSessionLoaded) {
    return appShellState.storedSession;
  }

  const keysToCheck = [APP_SESSION_KEY].concat(LEGACY_SESSION_KEYS);
  for (const key of keysToCheck) {
    const session = tryReadSession(key);
    if (session && session.token && session.user) {
      appShellState.storedSession = session;
      appShellState.storedSessionLoaded = true;
      return session;
    }
  }

  appShellState.storedSession = null;
  appShellState.storedSessionLoaded = true;
  return null;
}

function setStoredSession(session) {
  appShellState.storedSession = session;
  appShellState.storedSessionLoaded = true;
  localStorage.setItem(APP_SESSION_KEY, JSON.stringify(session));
  LEGACY_SESSION_KEYS.forEach(key => localStorage.removeItem(key));
}

function clearStoredSession() {
  appShellState.storedSession = null;
  appShellState.storedSessionLoaded = true;
  localStorage.removeItem(APP_SESSION_KEY);
  LEGACY_SESSION_KEYS.forEach(key => localStorage.removeItem(key));
}

function getSessionToken() {
  const session = getStoredSession();
  return session && session.token ? session.token : null;
}

function getCurrentApiUrl() {
  return normalizeApiUrl(window.apiUrl || getStoredApiUrl(), window.defaultApiUrl);
}

function getFetchTargetUrl(resource) {
  if (typeof resource === "string") {
    return resource;
  }

  if (resource && typeof resource.url === "string") {
    return resource.url;
  }

  if (resource && typeof resource.href === "string") {
    return resource.href;
  }

  return "";
}

function getBearerTokenFromHeader(headerValue) {
  const match = String(headerValue || "").match(/^Bearer\s+(.+)$/i);
  return match ? match[1].trim() : null;
}

function isApiRequestUrl(targetUrl, routePrefix) {
  const activeApiUrl = getCurrentApiUrl();
  if (!targetUrl || !activeApiUrl) {
    return false;
  }

  try {
    const requestUrl = new URL(targetUrl, window.location.href);
    const apiBaseUrl = new URL(activeApiUrl, window.location.href);
    if (requestUrl.origin !== apiBaseUrl.origin) {
      return false;
    }

    const basePath = apiBaseUrl.pathname.endsWith("/") ? apiBaseUrl.pathname : `${apiBaseUrl.pathname}/`;
    if (basePath !== "/" && requestUrl.pathname.indexOf(basePath) !== 0 && requestUrl.pathname !== apiBaseUrl.pathname) {
      return false;
    }

    if (!routePrefix) {
      return true;
    }

    const relativePath = basePath === "/"
      ? requestUrl.pathname.replace(/^\//, "")
      : requestUrl.pathname.slice(basePath.length);
    return relativePath.indexOf(routePrefix) === 0;
  } catch (error) {
    const normalizedApiUrl = normalizeApiUrl(activeApiUrl, window.defaultApiUrl);
    if (String(targetUrl).indexOf(normalizedApiUrl) !== 0) {
      return false;
    }

    return routePrefix
      ? String(targetUrl).indexOf(normalizedApiUrl + routePrefix) === 0
      : true;
  }
}

function getCurrentUser() {
  const session = getStoredSession();
  return session && session.user ? session.user : null;
}

function setSyncStatus(message) {
  const syncElement = document.getElementById("appSyncStatus");
  if (syncElement) {
    syncElement.textContent = message;
  }
}

function formatAppDateTime(value) {
  if (!value) {
    return "";
  }

  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return "";
  }

  const locale = typeof getI18nLocale === "function" ? getI18nLocale() : undefined;
  return date.toLocaleString(locale, {
    month: "short",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
  });
}

function setLastSyncStatus(syncState) {
  const syncElement = document.getElementById("appLastSyncStatus");
  if (!syncElement) {
    return;
  }

  const timestamp = syncState && syncState.updatedAtUtc ? syncState.updatedAtUtc : "";
  const formattedTimestamp = formatAppDateTime(timestamp);
  syncElement.textContent = formattedTimestamp
    ? t("status.lastSyncAt", { time: formattedTimestamp })
    : t("status.lastSyncNever");
}

function renderSettingsHealthLoading() {
  const panel = document.getElementById("settingsHealthPanel");
  if (panel) {
    panel.innerHTML = `<span class="panel-note">${escapeHtml(t("settings.healthLoading"))}</span>`;
  }
}

function renderSettingsHealthError(message) {
  const panel = document.getElementById("settingsHealthPanel");
  if (panel) {
    panel.innerHTML = `<span class="panel-note">${escapeHtml(message || t("settings.healthUnavailable"))}</span>`;
  }
}

function renderSettingsHealth(payload) {
  const panel = document.getElementById("settingsHealthPanel");
  if (!panel) {
    return;
  }

  const status = String(payload && payload.status || "warning").toLowerCase();
  const statusLabel = status === "ok" ? t("settings.healthOk") : t("settings.healthWarning");
  const syncVersion = payload && payload.sync && payload.sync.version != null ? String(payload.sync.version) : "-";
  const rows = [
    [t("settings.healthDataFolder"), payload && payload.dataFolder ? payload.dataFolder : "-"],
    [t("settings.healthWritable"), payload && payload.dataFolderWritable ? t("settings.healthOk") : t("settings.healthWarning")],
    [t("settings.healthPowerShell"), payload && payload.powershell ? payload.powershell : "-"],
    [t("settings.healthUsers"), payload && payload.usersCount != null ? String(payload.usersCount) : "-"],
    [t("settings.healthProjects"), payload && payload.projectsCount != null ? String(payload.projectsCount) : "-"],
    [t("settings.healthSync"), syncVersion],
    [t("settings.healthGc179"), payload && payload.gc179Template && payload.gc179Template.exists ? t("settings.healthOk") : t("settings.healthWarning")],
  ];

  const checks = Array.isArray(payload && payload.checks) ? payload.checks : [];
  panel.innerHTML = `
    <div class="settings-health-summary">
      <span class="status-badge ${status === "ok" ? "approved" : "pending"}">${escapeHtml(statusLabel)}</span>
      <span class="panel-note">${escapeHtml(formatAppDateTime(payload && payload.serverTimeUtc))}</span>
    </div>
    <div class="settings-health-grid">
      ${rows.map(([label, value]) => `
        <div class="settings-health-item" title="${escapeHtml(value)}">
          <span class="settings-health-label">${escapeHtml(label)}</span>
          <span class="settings-health-value">${escapeHtml(value)}</span>
        </div>
      `).join("")}
    </div>
    ${checks.length > 0 ? `
      <div class="settings-health-checks">
        ${checks.map(check => {
          const isOk = Boolean(check && check.ok);
          const label = check && check.label ? check.label : "";
          const detail = check && check.detail ? check.detail : "";
          return `
            <div class="settings-health-check ${isOk ? "is-ok" : "is-warning"}" title="${escapeHtml(detail)}">
              <i class="fa-solid ${isOk ? "fa-check" : "fa-triangle-exclamation"}"></i>
              <span>${escapeHtml(label)}${detail ? ` | ${escapeHtml(detail)}` : ""}</span>
            </div>
          `;
        }).join("")}
      </div>
    ` : ""}
  `;
}

async function loadSettingsHealth() {
  if (!getSessionToken()) {
    return;
  }

  renderSettingsHealthLoading();
  try {
    const response = await fetch(apiUrl + "health");
    const payload = await parseResponse(response);
    renderSettingsHealth(payload);
  } catch (error) {
    renderSettingsHealthError(error.message || t("settings.healthUnavailable"));
  }
}

function updateSessionSummary() {
  const summary = document.getElementById("appSessionSummary");
  const settingsButton = document.getElementById("appSettingsButton");
  const logoutButton = document.getElementById("appLogoutButton");
  const user = getCurrentUser();

  if (!user) {
    summary.textContent = t("session.notSignedIn");
    settingsButton.classList.add("d-none");
    logoutButton.classList.add("d-none");
    return;
  }

  const identity = user.displayName || user.username;
  const role = normalizeClientRole(user.role);
  const suffix = role === "employee" && user.employeeCode
    ? t("session.employeeCode", { code: user.employeeCode })
    : t(`session.role.${role}`);

  summary.textContent = `${identity} | ${suffix}`;
  settingsButton.classList.remove("d-none");
  logoutButton.classList.remove("d-none");
}

function setAuthMessage(message, type) {
  const messageBox = document.getElementById("authMessage");
  if (!message) {
    messageBox.className = "alert d-none";
    messageBox.textContent = "";
    return;
  }

  messageBox.className = `alert alert-${type || "danger"}`;
  messageBox.textContent = message;
}

function toggleAuthAdvancedPanel(forceState) {
  const panel = document.getElementById("authAdvancedPanel");
  if (!panel) {
    return;
  }

  const shouldShow = typeof forceState === "boolean" ? forceState : panel.classList.contains("d-none");
  panel.classList.toggle("d-none", !shouldShow);
}

function showAuthOverlay(requirePasswordChange) {
  document.getElementById("authOverlay").classList.remove("d-none");
  document.getElementById("passwordChangeSection").classList.toggle("d-none", !requirePasswordChange);
  document.getElementById("loginSubmitButton").classList.toggle("d-none", requirePasswordChange);
  document.getElementById("changePasswordButton").classList.toggle("d-none", !requirePasswordChange);
  if (requirePasswordChange) {
    toggleAuthAdvancedPanel(false);
  }
}

function hideAuthOverlay() {
  document.getElementById("authOverlay").classList.add("d-none");
  setAuthMessage("");
}

function setModalPasswordMessage(message, type) {
  const messageBox = document.getElementById("selfPasswordMessage");
  if (!message) {
    messageBox.className = "alert d-none";
    messageBox.textContent = "";
    return;
  }

  messageBox.className = `alert alert-${type || "danger"}`;
  messageBox.textContent = message;
}

function resetModalPasswordForm() {
  document.getElementById("selfCurrentPasswordInput").value = "";
  document.getElementById("selfNewPasswordInput").value = "";
  document.getElementById("selfConfirmPasswordInput").value = "";
  setModalPasswordMessage("");
}

function openModalPasswordForm() {
  openSelfSettingsForm();
  window.setTimeout(() => {
    const currentPasswordInput = document.getElementById("selfCurrentPasswordInput");
    if (currentPasswordInput) {
      currentPasswordInput.focus();
    }
  }, 150);
}

function toSelfGc179UpperText(value) {
  const text = String(value || "").trim();
  return text ? text.toUpperCase() : "";
}

function inferSelfGc179NameParts(displayName) {
  const tokens = String(displayName || "")
    .trim()
    .split(/\s+/)
    .filter(Boolean);
  if (tokens.length === 0) {
    return {
      surname: "",
      givenName: "",
      initials: "",
    };
  }

  const surname = tokens.length === 1 ? tokens[0] : tokens[tokens.length - 1];
  const givenName = tokens.length === 1 ? "" : tokens.slice(0, -1).join(" ");
  const initialParts = [];
  if (givenName) {
    initialParts.push(givenName.charAt(0).toUpperCase());
  }
  if (surname) {
    initialParts.push(surname.charAt(0).toUpperCase());
  }

  return {
    surname: toSelfGc179UpperText(surname),
    givenName: toSelfGc179UpperText(givenName),
    initials: initialParts.join("."),
  };
}

function normalizeSelfGc179Profile(profile, displayName) {
  const fallback = inferSelfGc179NameParts(displayName);
  const source = profile && typeof profile === "object" ? profile : {};
  return {
    surname: toSelfGc179UpperText(source.surname || source.Surname || source.lastName || fallback.surname),
    givenName: toSelfGc179UpperText(source.givenName || source.given || source.Given || fallback.givenName),
    initials: toSelfGc179UpperText(source.initials || source.Initials || fallback.initials),
    pri: formatGc179Pri(source.pri || source.PRI || ""),
    position: normalizeGc179Position(source.position || source.poste || source.classification || source.Position || ""),
    level: normalizeGc179Echelon(source.level || source.Level || source.echelon || source.Echelon || ""),
    compressedWorkWeek: normalizeBooleanValue(getFirstDefinedPropertyValue(source, ["compressedWorkWeek", "isCompressedWorkWeek", "compressed"]), false),
  };
}

function setSelfGc179ProfileMessage(message, type) {
  const messageBox = document.getElementById("selfGc179ProfileMessage");
  if (!message) {
    messageBox.className = "alert d-none";
    messageBox.textContent = "";
    return;
  }

  messageBox.className = `alert alert-${type || "danger"}`;
  messageBox.textContent = message;
}

function setSelfGc179ProfileForm(profile, displayName) {
  const normalized = normalizeSelfGc179Profile(profile, displayName);
  document.getElementById("selfGc179SurnameInput").value = normalized.surname;
  document.getElementById("selfGc179GivenInput").value = normalized.givenName;
  document.getElementById("selfGc179InitialsInput").value = normalized.initials;
  document.getElementById("selfGc179PriInput").value = normalized.pri;
  document.getElementById("selfGc179PositionSelect").value = normalized.position;
  document.getElementById("selfGc179LevelInput").value = normalized.level;
  document.getElementById("selfGc179CompressedWorkWeekInput").checked = Boolean(normalized.compressedWorkWeek);
}

function getSelfGc179ProfileForm(displayName) {
  return normalizeSelfGc179Profile({
    surname: document.getElementById("selfGc179SurnameInput").value,
    givenName: document.getElementById("selfGc179GivenInput").value,
    initials: document.getElementById("selfGc179InitialsInput").value,
    pri: document.getElementById("selfGc179PriInput").value,
    position: document.getElementById("selfGc179PositionSelect").value,
    level: document.getElementById("selfGc179LevelInput").value,
    compressedWorkWeek: document.getElementById("selfGc179CompressedWorkWeekInput").checked,
  }, displayName);
}

function updateStoredUserGc179Profile(profile) {
  const session = getStoredSession();
  if (!session || !session.user) {
    return;
  }

  session.user.gc179Profile = profile;
  setStoredSession(session);
}

async function openSelfSettingsForm() {
  const user = getCurrentUser();
  if (!user) {
    return;
  }

  setSelfGc179ProfileMessage("");
  resetModalPasswordForm();
  updateSettingsThemeOptions(getStoredTheme());
  setSelfGc179ProfileForm(user.gc179Profile, user.displayName || user.username || "");
  const modal = new bootstrap.Modal(document.getElementById("selfSettingsModal"));
  modal.show();
  loadSettingsHealth();

  try {
    const response = await fetch(apiUrl + "self/profile");
    const profile = await parseResponse(response);
    if (profile && profile.gc179Profile) {
      updateStoredUserGc179Profile(profile.gc179Profile);
      setSelfGc179ProfileForm(profile.gc179Profile, profile.displayName || user.displayName || user.username || "");
    }
  } catch (error) {
    setSelfGc179ProfileMessage(error.message || t("self.gc179ProfileError"), "warning");
  }
}

async function submitSelfGc179Profile() {
  const user = getCurrentUser();
  if (!user || !user.employeeCode) {
    return;
  }

  setSelfGc179ProfileMessage("");
  const gc179Profile = getSelfGc179ProfileForm(user.displayName || user.username || "");

  try {
    const response = await fetch(apiUrl + "self/gc179-profile", {
      method: "PUT",
      headers: {
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        gc179Profile,
      }),
    });
    const result = await parseResponse(response);
    const savedProfile = result && result.gc179Profile ? result.gc179Profile : gc179Profile;
    updateStoredUserGc179Profile(savedProfile);
    updateSessionSummary();
    setSelfGc179ProfileForm(savedProfile, user.displayName || user.username || "");
    bootstrap.Modal.getInstance(document.getElementById("selfSettingsModal")).hide();
    showToast(t("self.gc179ProfileSaved"), "success");
    markViewsStale(["selfView", "employeesView"]);
  } catch (error) {
    setSelfGc179ProfileMessage(error.message || t("self.gc179ProfileError"), "danger");
  }
}

function setRoleScopeVisibility(role, isVisible) {
  document.querySelectorAll(`[data-role-scope="${role}"]`).forEach(element => {
    element.classList.toggle("d-none", !isVisible);
  });
}

function clearRoleUi() {
  window.allowedViewIds = [];
  setRoleScopeVisibility("admin", false);
  setRoleScopeVisibility("employee", false);
  setRoleScopeVisibility("manager", false);
  setRoleScopeVisibility("superAdmin", false);
}

function getAllowedViewsForUser(user) {
  if (!user) {
    return [];
  }

  const views = [];
  if (userHasEmployeeWorkspace(user)) {
    views.push("selfView");
  }

  if (isManagerUser(user)) {
    ROLE_VIEW_MAP[normalizeClientRole(user.role)].forEach(viewId => {
      if (views.indexOf(viewId) < 0) {
        views.push(viewId);
      }
    });
  } else if (normalizeClientRole(user.role) === "employee") {
    ROLE_VIEW_MAP.employee.forEach(viewId => {
      if (views.indexOf(viewId) < 0) {
        views.push(viewId);
      }
    });
  }

  return views;
}

function resolvePreferredView(user) {
  const allowedViews = getAllowedViewsForUser(user);
  const savedView = localStorage.getItem("activeView");
  if (savedView && allowedViews.indexOf(savedView) >= 0) {
    return savedView;
  }

  return allowedViews.length > 0 ? allowedViews[0] : "dashboardView";
}

function configureRoleUi(user) {
  clearRoleUi();

  if (!user) {
    window.allowedViewIds = [];
    return;
  }

  setRoleScopeVisibility("employee", userHasEmployeeWorkspace(user));
  setRoleScopeVisibility("manager", isManagerUser(user));
  setRoleScopeVisibility("superAdmin", isSuperAdminUser(user));
  setRoleScopeVisibility("admin", isManagerUser(user));
  window.allowedViewIds = getAllowedViewsForUser(user);

  if (typeof showView === "function") {
    showView(resolvePreferredView(user));
  }
}

function stopSyncPolling() {
  if (appShellState.syncTimerId) {
    window.clearTimeout(appShellState.syncTimerId);
    appShellState.syncTimerId = null;
  }
}

function getSyncPollDelay() {
  return document.hidden ? APP_SYNC_POLL_HIDDEN_MS : APP_SYNC_POLL_VISIBLE_MS;
}

function scheduleNextSyncPoll(delayMs) {
  stopSyncPolling();
  appShellState.syncTimerId = window.setTimeout(() => {
    pollSyncState();
  }, typeof delayMs === "number" ? delayMs : getSyncPollDelay());
}

async function runViewRefresh(viewId) {
  if (viewId === "selfView" && typeof refreshSelfView === "function") {
    await refreshSelfView();
    return;
  }

  if (viewId === "dashboardView" && typeof refreshDashboardView === "function") {
    await refreshDashboardView();
    return;
  }

  if (viewId === "employeesView" && typeof loadEmployeesView === "function") {
    await loadEmployeesView();
    return;
  }

  if (viewId === "adminView") {
    if (typeof loadReviewView === "function") {
      await loadReviewView();
      return;
    }

    const tasks = [];
    if (typeof loadApprovalsView === "function") {
      tasks.push(loadApprovalsView());
    }
    if (typeof fetchHistory === "function") {
      tasks.push(fetchHistory());
    }
    await Promise.all(tasks);
    return;
  }

  if (viewId === "projectsView" && typeof refreshProjectsView === "function") {
    await refreshProjectsView();
  }
}

async function refreshViewById(viewId, options) {
  const state = ensureViewState(viewId);
  const forceRefresh = !!(options && options.force);

  if (!forceRefresh && state.loaded && !state.stale) {
    return;
  }

  if (state.refreshPromise) {
    return state.refreshPromise;
  }

  state.refreshPromise = runViewRefresh(viewId)
    .then(() => {
      state.loaded = true;
      state.stale = false;
      state.lastLoadedAt = Date.now();
    })
    .catch(error => {
      state.stale = true;
      throw error;
    })
    .finally(() => {
      state.refreshPromise = null;
    });

  return state.refreshPromise;
}

window.refreshAppViewById = refreshViewById;
window.refreshAdminViewById = refreshViewById;
window.requestAppViewRefresh = requestViewRefresh;
window.markAppViewsStale = markViewsStale;
window.getActiveAppViewId = getActiveViewId;

async function refreshActiveView(options) {
  const user = getCurrentUser();
  if (!user) {
    return;
  }

  const activeViewId = document.querySelector(".view.active")?.id || localStorage.getItem("activeView") || resolvePreferredView(user);
  await refreshViewById(activeViewId, options);
}

async function pollSyncState() {
  if (appShellState.syncRequestInFlight) {
    scheduleNextSyncPoll();
    return;
  }

  const sessionToken = getSessionToken();
  if (!sessionToken) {
    setSyncStatus(t("status.waitingForSignIn"));
    return;
  }

  appShellState.syncRequestInFlight = true;
  try {
    const response = await fetch(apiUrl + "sync/status");
    const syncState = await parseResponse(response);
    setLastSyncStatus(syncState);
    const nextVersion = syncState && typeof syncState.version === "number" ? syncState.version : 0;

    if (appShellState.lastSyncVersion === null) {
      appShellState.lastSyncVersion = nextVersion;
      setSyncStatus(t("status.liveRev", { version: nextVersion }));
      return;
    }

    if (nextVersion !== appShellState.lastSyncVersion) {
      appShellState.lastSyncVersion = nextVersion;
      if (typeof window.handleSyncStateChange === "function") {
        window.handleSyncStateChange(syncState);
      }
      markViewsStale(getViewsAffectedBySyncState(syncState));
      setSyncStatus(t("status.updatedRev", { version: nextVersion }));
      if (document.hidden) {
        return;
      }
      await refreshActiveView();
      return;
    }

    setSyncStatus(t("status.liveRev", { version: nextVersion }));
  } catch (error) {
    console.error("Unable to refresh sync state:", error);
    setSyncStatus(t("status.syncPaused"));
  } finally {
    appShellState.syncRequestInFlight = false;
    scheduleNextSyncPoll();
  }
}

async function bootstrapApplication() {
  const user = getCurrentUser();
  if (!user) {
    return;
  }

  resetViewState();
  markAllowedViewsStale(user);
  configureRoleUi(user);

  if (userHasEmployeeWorkspace(user) && typeof initializeSelfView === "function") {
    initializeSelfView();
  }

  const preferredView = resolvePreferredView(user);
  if (typeof showView === "function") {
    showView(preferredView);
  }

  await refreshViewById(preferredView, { force: true });
  pollSyncState().catch(error => {
    console.error("Unable to start sync polling:", error);
  });
  appShellState.initialized = true;
}

function installFetchWrapper() {
  window.fetch = function (resource, options) {
    const requestOptions = options ? { ...options } : {};
    const headers = new Headers(requestOptions.headers || (resource && resource.headers) || {});
    const targetUrl = getFetchTargetUrl(resource);
    const token = getSessionToken();
    let requestToken = getBearerTokenFromHeader(headers.get("Authorization"));

    if (token && isApiRequestUrl(targetUrl) && !headers.has("Authorization")) {
      headers.set("Authorization", `Bearer ${token}`);
      requestToken = token;
    }

    requestOptions.headers = headers;
    const method = String(requestOptions.method || (resource && resource.method) || "GET").toUpperCase();
    const shouldCoalesceGet = method === "GET" && isApiRequestUrl(targetUrl);
    const requestCacheKey = shouldCoalesceGet
      ? `${requestToken || token || ""}|${new URL(targetUrl, window.location.href).href}`
      : "";

    if (requestCacheKey && appShellState.getRequestInflight[requestCacheKey]) {
      return appShellState.getRequestInflight[requestCacheKey].then(response => response.clone());
    }

    const requestPromise = appShellState.nativeFetch(resource, requestOptions).then(response => {
      const isAuthRequest = isApiRequestUrl(targetUrl, "auth/");
      if (response.status === 401 && !isAuthRequest) {
        const currentToken = getSessionToken();
        if (!currentToken || (requestToken && currentToken === requestToken)) {
          handleSessionExpired();
        }
      }
      return response;
    });

    if (requestCacheKey) {
      appShellState.getRequestInflight[requestCacheKey] = requestPromise
        .then(response => response.clone())
        .finally(() => {
          delete appShellState.getRequestInflight[requestCacheKey];
        });
    }

    return requestPromise;
  };
}

function handleSessionExpired() {
  stopSyncPolling();
  appShellState.lastSyncVersion = null;
  resetViewState();
  clearClientLookupCaches();
  clearStoredSession();
  clearRoleUi();
  updateSessionSummary();
  setSyncStatus(t("status.sessionExpired"));
  showAuthOverlay(false);
  setAuthMessage(t("auth.sessionExpired"), "warning");
}

function validateAuthenticatedUser(user) {
  if (!user || !user.role) {
    throw new Error(t("auth.authenticationIncomplete"));
  }

  const role = normalizeClientRole(user.role);
  if (!ROLE_VIEW_MAP[role]) {
    throw new Error(`Unsupported role: ${user.role}`);
  }

  if (role === "employee" && !user.employeeCode) {
    throw new Error(t("auth.employeeCodeRequired"));
  }

  user.role = role;
}

async function applySession(authResult) {
  if (!authResult || !authResult.token || !authResult.user) {
    throw new Error(t("auth.authenticationIncomplete"));
  }

  validateAuthenticatedUser(authResult.user);

  setStoredSession({
    token: authResult.token,
    user: authResult.user,
  });
  appShellState.lastSyncVersion = null;
  resetViewState();
  clearClientLookupCaches();
  markAllowedViewsStale(authResult.user);
  updateSessionSummary();
  configureRoleUi(authResult.user);

  if (authResult.user.mustChangePassword) {
    showAuthOverlay(true);
    setAuthMessage(t("auth.passwordChangeRequired"), "warning");
    setSyncStatus(t("status.passwordUpdateRequired"));
    return;
  }

  hideAuthOverlay();

  if (!appShellState.initialized) {
    await bootstrapApplication();
  } else {
    await refreshActiveView({ force: true });
    await pollSyncState();
  }
}

async function submitLogin(event) {
  event.preventDefault();

  setStoredApiUrl(document.getElementById("apiUrlInput").value);
  setAuthMessage("");

  const username = document.getElementById("usernameInput").value.trim();
  const password = document.getElementById("passwordInput").value;

  if (!username || !password) {
    setAuthMessage(t("auth.usernamePasswordRequired"), "danger");
    return;
  }

  try {
    const response = await appShellState.nativeFetch(apiUrl + "auth/login", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ username, password }),
    });

    const authResult = await parseResponse(response);
    await applySession(authResult);
  } catch (error) {
    setAuthMessage(error.message || t("auth.signInError"), "danger");
  }
}

async function submitPasswordChange() {
  setAuthMessage("");

  const currentPassword = document.getElementById("passwordInput").value;
  const newPassword = document.getElementById("newPasswordInput").value;
  const confirmPassword = document.getElementById("confirmPasswordInput").value;

  if (!currentPassword || !newPassword || !confirmPassword) {
    setAuthMessage(t("auth.passwordFieldsRequired"), "danger");
    return;
  }

  if (newPassword !== confirmPassword) {
    setAuthMessage(t("auth.newPasswordsMismatch"), "danger");
    return;
  }

  try {
    const response = await fetch(apiUrl + "auth/change-password", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        currentPassword,
        newPassword,
      }),
    });

    await parseResponse(response);

    const session = getStoredSession();
    if (session && session.user) {
      session.user.mustChangePassword = false;
      setStoredSession(session);
    }

    document.getElementById("newPasswordInput").value = "";
    document.getElementById("confirmPasswordInput").value = "";
    updateSessionSummary();
    hideAuthOverlay();

    if (!appShellState.initialized) {
      await bootstrapApplication();
    } else {
      const user = getCurrentUser();
      if (user) {
        markAllowedViewsStale(user);
      }
      await refreshActiveView({ force: true });
      await pollSyncState();
    }

    showToast(t("auth.passwordUpdated"), "success");
  } catch (error) {
    setAuthMessage(error.message || t("auth.passwordUpdateError"), "danger");
  }
}

async function submitModalPasswordChange() {
  setModalPasswordMessage("");

  const currentPassword = document.getElementById("selfCurrentPasswordInput").value;
  const newPassword = document.getElementById("selfNewPasswordInput").value;
  const confirmPassword = document.getElementById("selfConfirmPasswordInput").value;

  if (!currentPassword || !newPassword || !confirmPassword) {
    setModalPasswordMessage(t("auth.passwordFieldsRequired"), "danger");
    return;
  }

  if (newPassword !== confirmPassword) {
    setModalPasswordMessage(t("auth.newPasswordsMismatch"), "danger");
    return;
  }

  try {
    const response = await fetch(apiUrl + "auth/change-password", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        currentPassword,
        newPassword,
      }),
    });

    await parseResponse(response);

    const session = getStoredSession();
    if (session && session.user) {
      session.user.mustChangePassword = false;
      setStoredSession(session);
    }

    updateSessionSummary();
    resetModalPasswordForm();
    showToast(t("auth.passwordUpdated"), "success");
  } catch (error) {
    setModalPasswordMessage(error.message || t("auth.passwordUpdateError"), "danger");
  }
}

async function submitLogout() {
  stopSyncPolling();

  const token = getSessionToken();
  if (token) {
    try {
      await appShellState.nativeFetch(apiUrl + "auth/logout", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
        },
      });
    } catch (error) {
      console.error("Unable to sign out cleanly:", error);
    }
  }

  appShellState.lastSyncVersion = null;
  resetViewState();
  clearClientLookupCaches();
  clearStoredSession();
  clearRoleUi();
  updateSessionSummary();
  setSyncStatus(t("status.signedOut"));
  showAuthOverlay(false);
  setAuthMessage(t("auth.signOutSuccess"), "success");
}

async function restoreSession() {
  const session = getStoredSession();
  if (!session || !session.token) {
    clearRoleUi();
    updateSessionSummary();
    showAuthOverlay(false);
    setSyncStatus(t("status.waitingForSignIn"));
    return;
  }

  const restoreToken = session.token;
  try {
    const response = await fetch(apiUrl + "auth/me");
    const currentUser = await parseResponse(response);
    const latestSession = getStoredSession();
    if (!latestSession || latestSession.token !== restoreToken) {
      return;
    }

    await applySession({
      token: restoreToken,
      user: currentUser,
    });
  } catch (error) {
    const latestSession = getStoredSession();
    if (latestSession && latestSession.token !== restoreToken) {
      return;
    }

    clearStoredSession();
    clearRoleUi();
    updateSessionSummary();
    showAuthOverlay(false);
    setAuthMessage(t("auth.signInToContinue"), "warning");
    setSyncStatus(t("status.waitingForSignIn"));
  }
}

window.refreshActiveAppView = refreshActiveView;

document.addEventListener("DOMContentLoaded", () => {
  window.apiUrl = getStoredApiUrl();
  localStorage.setItem(APP_API_URL_KEY, window.apiUrl);
  updateConnectionDisplay();
  document.getElementById("loginForm").addEventListener("submit", submitLogin);
  document.getElementById("selfPasswordForm").addEventListener("submit", event => {
    event.preventDefault();
    submitModalPasswordChange();
  });
  document.getElementById("selfGc179ProfileForm").addEventListener("submit", event => {
    event.preventDefault();
    submitSelfGc179Profile();
  });
  document.getElementById("changePasswordButton").addEventListener("click", submitPasswordChange);
  document.getElementById("appSettingsButton").addEventListener("click", openSelfSettingsForm);
  document.getElementById("settingsHealthRefreshButton").addEventListener("click", loadSettingsHealth);
  document.getElementById("selfPasswordSaveButton").addEventListener("click", submitModalPasswordChange);
  document.getElementById("selfGc179ProfileSaveButton").addEventListener("click", submitSelfGc179Profile);
  bindGc179PriFormatter(document.getElementById("selfGc179PriInput"));
  bindGc179PriFormatter(document.getElementById("employeeEditorGc179PriInput"));
  document.getElementById("appLogoutButton").addEventListener("click", submitLogout);
  document.querySelectorAll("[data-settings-theme]").forEach(button => {
    button.addEventListener("click", () => applyAppTheme(button.getAttribute("data-settings-theme")));
  });
  const authAdvancedToggle = document.getElementById("authAdvancedToggle");
  if (authAdvancedToggle) {
    authAdvancedToggle.addEventListener("click", () => toggleAuthAdvancedPanel());
  }
  applyAppTheme(getStoredTheme());
  clearRoleUi();
  updateSessionSummary();
  setSyncStatus(t("status.waitingForSignIn"));
  setLastSyncStatus(null);
  installFetchWrapper();
  restoreSession();
});

document.addEventListener("visibilitychange", () => {
  if (!getSessionToken()) {
    return;
  }

  if (!document.hidden) {
    refreshActiveView().catch(error => {
      console.error("Unable to refresh active view after returning to app:", error);
    });
  }
  scheduleNextSyncPoll(0);
});

window.addEventListener("app:language-changed", event => {
  updateConnectionDisplay();
  updateSessionSummary();
  updateThemeToggle(getStoredTheme());

  const user = getCurrentUser();
  if (!user) {
    setSyncStatus(t("status.waitingForSignIn"));
    return;
  }

  if (appShellState.lastSyncVersion === null) {
    if (user.mustChangePassword) {
      setSyncStatus(t("status.passwordUpdateRequired"));
    } else {
      setSyncStatus(t("status.waitingForSignIn"));
    }
  } else {
    setSyncStatus(t("status.liveRev", { version: appShellState.lastSyncVersion }));
  }

  if (typeof window.updateWorkspaceHeading === "function") {
    const activeViewId = document.querySelector(".view.active")?.id || resolvePreferredView(user);
    window.updateWorkspaceHeading(activeViewId);
  }

  if (event.detail && event.detail.refresh === false) {
    return;
  }

  refreshActiveView({ force: true }).catch(error => {
    console.error("Unable to refresh active view after language change:", error);
  });
});
