const APP_API_URL_KEY = "overtimeAppApiUrl";
const APP_SESSION_KEY = "overtimeAppSession";
const LEGACY_API_URL_KEYS = ["adminApiUrl", "employeeApiUrl"];
const LEGACY_SESSION_KEYS = ["adminSession", "employeeSession"];
const ROLE_VIEW_MAP = {
  admin: ["dashboardView", "employeesView", "adminView", "projectsView"],
  employee: ["selfView"],
};

const appShellState = {
  nativeFetch: window.fetch.bind(window),
  initialized: false,
  syncTimerId: null,
  lastSyncVersion: null,
  syncRequestInFlight: false,
};

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
  const keysToCheck = [APP_SESSION_KEY].concat(LEGACY_SESSION_KEYS);
  for (const key of keysToCheck) {
    const session = tryReadSession(key);
    if (session && session.token && session.user) {
      return session;
    }
  }

  return null;
}

function setStoredSession(session) {
  localStorage.setItem(APP_SESSION_KEY, JSON.stringify(session));
  LEGACY_SESSION_KEYS.forEach(key => localStorage.removeItem(key));
}

function clearStoredSession() {
  localStorage.removeItem(APP_SESSION_KEY);
  LEGACY_SESSION_KEYS.forEach(key => localStorage.removeItem(key));
}

function getSessionToken() {
  const session = getStoredSession();
  return session && session.token ? session.token : null;
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

function updateSessionSummary() {
  const summary = document.getElementById("appSessionSummary");
  const changePasswordButton = document.getElementById("appChangePasswordButton");
  const logoutButton = document.getElementById("appLogoutButton");
  const user = getCurrentUser();

  if (!user) {
    summary.textContent = t("session.notSignedIn");
    changePasswordButton.classList.add("d-none");
    logoutButton.classList.add("d-none");
    return;
  }

  const identity = user.displayName || user.username;
  const suffix = user.role === "employee" && user.employeeCode
    ? t("session.employeeCode", { code: user.employeeCode })
    : t(`session.role.${user.role}`);

  summary.textContent = `${identity} | ${suffix}`;
  changePasswordButton.classList.remove("d-none");
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
  resetModalPasswordForm();
  const modal = new bootstrap.Modal(document.getElementById("selfPasswordModal"));
  modal.show();
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
}

function getAllowedViewsForUser(user) {
  if (!user || !ROLE_VIEW_MAP[user.role]) {
    return [];
  }

  return ROLE_VIEW_MAP[user.role].slice();
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

  if (!user || !ROLE_VIEW_MAP[user.role]) {
    window.allowedViewIds = [];
    return;
  }

  setRoleScopeVisibility("admin", user.role === "admin");
  setRoleScopeVisibility("employee", user.role === "employee");
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
  return document.hidden ? 8000 : 2500;
}

function scheduleNextSyncPoll(delayMs) {
  stopSyncPolling();
  appShellState.syncTimerId = window.setTimeout(() => {
    pollSyncState();
  }, typeof delayMs === "number" ? delayMs : getSyncPollDelay());
}

async function refreshViewById(viewId) {
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

window.refreshAppViewById = refreshViewById;
window.refreshAdminViewById = refreshViewById;

async function refreshActiveView() {
  const user = getCurrentUser();
  if (!user) {
    return;
  }

  const activeViewId = document.querySelector(".view.active")?.id || localStorage.getItem("activeView") || resolvePreferredView(user);
  await refreshViewById(activeViewId);
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
      setSyncStatus(t("status.updatedRev", { version: nextVersion }));
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

function startSyncPolling() {
  scheduleNextSyncPoll(0);
}

async function bootstrapApplication() {
  const user = getCurrentUser();
  if (!user) {
    return;
  }

  configureRoleUi(user);

  if (user.role === "employee" && typeof initializeSelfView === "function") {
    initializeSelfView();
  }

  const preferredView = resolvePreferredView(user);
  if (typeof showView === "function") {
    showView(preferredView);
  }

  await refreshViewById(preferredView);
  await pollSyncState();
  startSyncPolling();
  appShellState.initialized = true;
}

function installFetchWrapper() {
  window.fetch = function (resource, options) {
    const requestOptions = options ? { ...options } : {};
    const headers = new Headers(requestOptions.headers || {});
    const targetUrl = typeof resource === "string" ? resource : resource.url;
    const token = getSessionToken();

    if (token && typeof targetUrl === "string" && targetUrl.indexOf(apiUrl) === 0 && !headers.has("Authorization")) {
      headers.set("Authorization", `Bearer ${token}`);
    }

    requestOptions.headers = headers;

    return appShellState.nativeFetch(resource, requestOptions).then(response => {
      const isAuthRequest = typeof targetUrl === "string" && targetUrl.indexOf(apiUrl + "auth/") === 0;
      if (response.status === 401 && !isAuthRequest) {
        handleSessionExpired();
      }
      return response;
    });
  };
}

function handleSessionExpired() {
  stopSyncPolling();
  appShellState.lastSyncVersion = null;
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

  if (!ROLE_VIEW_MAP[user.role]) {
    throw new Error(`Unsupported role: ${user.role}`);
  }

  if (user.role === "employee" && !user.employeeCode) {
    throw new Error(t("auth.employeeCodeRequired"));
  }
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
    await refreshActiveView();
    await pollSyncState();
    startSyncPolling();
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
      await refreshActiveView();
      await pollSyncState();
      startSyncPolling();
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
    bootstrap.Modal.getInstance(document.getElementById("selfPasswordModal")).hide();
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

  try {
    const response = await fetch(apiUrl + "auth/me");
    const currentUser = await parseResponse(response);
    await applySession({
      token: session.token,
      user: currentUser,
    });
  } catch (error) {
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
  document.getElementById("changePasswordButton").addEventListener("click", submitPasswordChange);
  document.getElementById("appChangePasswordButton").addEventListener("click", openModalPasswordForm);
  document.getElementById("selfPasswordSaveButton").addEventListener("click", submitModalPasswordChange);
  document.getElementById("appLogoutButton").addEventListener("click", submitLogout);
  document.getElementById("authAdvancedToggle").addEventListener("click", () => toggleAuthAdvancedPanel());
  clearRoleUi();
  updateSessionSummary();
  setSyncStatus(t("status.waitingForSignIn"));
  installFetchWrapper();
  restoreSession();
});

document.addEventListener("visibilitychange", () => {
  if (!getSessionToken()) {
    return;
  }

  scheduleNextSyncPoll(0);
});

window.addEventListener("app:language-changed", event => {
  updateConnectionDisplay();
  updateSessionSummary();

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

  refreshActiveView().catch(error => {
    console.error("Unable to refresh active view after language change:", error);
  });
});
