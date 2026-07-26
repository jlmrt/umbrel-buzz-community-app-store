const form = document.querySelector("#setup-form");
const configuredView = document.querySelector("#configured-view");
const ownerInput = document.querySelector("#owner-key");
const ownerMessage = document.querySelector("#owner-message");
const verifiedKey = document.querySelector("#verified-key");
const ownerHex = document.querySelector("#owner-hex");
const ownerNpub = document.querySelector("#owner-npub");
const hexConfirmRow = document.querySelector("#hex-confirm-row");
const confirmPublicHex = document.querySelector("#confirm-public-hex");
const modeInputs = [...document.querySelectorAll('input[name="communityMode"]')];
const communityControls = document.querySelector("#community-controls");
const canonicalLock = document.querySelector("#canonical-lock");
const localDetail = document.querySelector("#local-detail");
const publicDetail = document.querySelector("#public-detail");
const localCommunityUrl = document.querySelector("#local-community-url");
const localDiscoveryMessage = document.querySelector("#local-discovery-message");
const publicCommunityUrl = document.querySelector("#public-community-url");
const reviewOwner = document.querySelector("#review-owner");
const reviewCommunityUrl = document.querySelector("#review-community-url");
const resetPanel = document.querySelector("#reset-panel");
const confirmReset = document.querySelector("#confirm-reset");
const resetPhrase = document.querySelector("#reset-phrase");
const submitButton = document.querySelector("#submit-button");
const actionTitle = document.querySelector("#action-title");
const actionDetail = document.querySelector("#action-detail");
const result = document.querySelector("#result");
const statusBadge = document.querySelector("#relay-status");
const statusText = document.querySelector("#relay-status-text");
const configuredCommunityUrl = document.querySelector("#configured-community-url");
const configuredOwner = document.querySelector("#configured-owner");
const configuredMode = document.querySelector("#configured-mode");
const editButton = document.querySelector("#edit-button");
const copyCommunityUrl = document.querySelector("#copy-community-url");
const operationsPanel = document.querySelector("#operations-panel");
const backupPanel = document.querySelector("#backup-panel");
const restorePanel = document.querySelector("#restore-panel");
const metricsFreshness = document.querySelector("#metrics-freshness");
const metricRelay = document.querySelector("#metric-relay");
const metricUptime = document.querySelector("#metric-uptime");
const metricVersion = document.querySelector("#metric-version");
const metricConnections = document.querySelector("#metric-connections");
const metricMembers = document.querySelector("#metric-members");
const metricChannels = document.querySelector("#metric-channels");
const metricMessages = document.querySelector("#metric-messages");
const metricEvents = document.querySelector("#metric-events");
const metricStorage = document.querySelector("#metric-storage");
const metricActivity = document.querySelector("#metric-activity");
const healthPostgres = document.querySelector("#health-postgres");
const healthRedis = document.querySelector("#health-redis");
const healthMinio = document.querySelector("#health-minio");
const healthWorker = document.querySelector("#health-worker");
const acknowledgeSensitive = document.querySelector("#acknowledge-sensitive");
const createBackup = document.querySelector("#create-backup");
const downloadBackup = document.querySelector("#download-backup");
const backupState = document.querySelector("#backup-state");
const backupProgress = document.querySelector("#backup-progress");
const backupProgressBar = document.querySelector("#backup-progress-bar");
const backupMessage = document.querySelector("#backup-message");
const archiveDetails = document.querySelector("#archive-details");
const backupCreated = document.querySelector("#backup-created");
const backupSize = document.querySelector("#backup-size");
const backupSha = document.querySelector("#backup-sha");
const packageVersion = document.querySelector("#package-version");

let status = null;
let preview = null;
let previewTimer = null;
let formTouched = false;
let editing = false;

async function api(path, options = {}) {
  const response = await fetch(path, {
    ...options,
    headers: {
      "Content-Type": "application/json",
      "X-Buzz-Setup": "1",
      ...(options.headers || {}),
    },
  });
  const payload = await response.json();
  if (!response.ok) {
    const error = new Error(payload.error || `Request failed (${response.status})`);
    error.payload = payload;
    throw error;
  }
  return payload;
}

function setStatus(state, text) {
  statusBadge.dataset.state = state;
  statusText.textContent = text;
}

function selectedMode() {
  return modeInputs.find((input) => input.checked)?.value || "local";
}

function selectedCommunityUrl() {
  if (status?.configured) {
    return status.communityUrl || "";
  }
  return selectedMode() === "local"
    ? status?.localCommunityUrl || ""
    : publicCommunityUrl.value.trim();
}

function setSelectedMode(mode) {
  const selected = modeInputs.find((input) => input.value === mode) || modeInputs[0];
  selected.checked = true;
}

function renderMode() {
  const local = selectedMode() === "local";
  localDetail.classList.toggle("hidden", !local);
  publicDetail.classList.toggle("hidden", local);
  publicCommunityUrl.required = !local;
  syncReview();
}

function renderCommunityLock() {
  const locked = Boolean(status?.configured);
  communityControls.disabled = locked;
  publicCommunityUrl.disabled = locked;
  canonicalLock.classList.toggle("hidden", !locked);
}

function renderLocalDiscovery() {
  const localUrl = status?.localCommunityUrl || "";
  localCommunityUrl.textContent = localUrl || "Local address unavailable";
  localDetail.dataset.state = localUrl ? "ready" : "error";
  localDiscoveryMessage.textContent = localUrl
    ? "Use this only from localhost or a trusted local network."
    : status?.localCommunityUrlError ||
      "Restart Buzz Relay from Umbrel. No manual technical URL entry is required.";
}

function syncReview() {
  reviewOwner.textContent = preview?.ownerNpub || "Not verified";
  reviewCommunityUrl.textContent = selectedCommunityUrl() || "Not selected";
}

function populateConfiguredView() {
  configuredCommunityUrl.textContent = status?.communityUrl || "Unavailable";
  configuredOwner.textContent = status?.ownerNpub || "Unavailable";
  configuredMode.textContent = status?.communityMode === "public"
    ? "Public community"
    : "Local testing";
}

function hydrateForm() {
  ownerInput.value = status?.ownerNpub || "";
  setSelectedMode(status?.communityMode || "local");
  publicCommunityUrl.value = status?.communityMode === "public"
    ? status.communityUrl || ""
    : "";
  renderLocalDiscovery();
  renderMode();
  renderCommunityLock();
  if (ownerInput.value) {
    void previewOwnerKey();
  } else {
    clearPreview();
  }
}

function renderStatus(nextStatus) {
  status = nextStatus;
  if (status.resetting) {
    setStatus("working", "Resetting application data");
  } else if (status.backup?.running || status.relayState === "backup-paused") {
    setStatus("working", "Creating backup");
  } else if (status.restarting) {
    setStatus("working", "Restarting relay");
  } else if (status.relayReady) {
    setStatus("ready", "Relay ready");
  } else if (!status.configured) {
    setStatus("waiting", "Setup required");
  } else if (status.relayState === "retrying-after-exit") {
    setStatus("error", "Relay start failed; retrying");
  } else if (status.relayState === "waiting-for-storage") {
    setStatus("working", "Waiting for object storage");
  } else if (status.relayState === "stopping") {
    setStatus("working", "Relay stopping");
  } else {
    setStatus("working", "Relay starting");
  }

  renderLocalDiscovery();
  const runtimeVersion = status.runtimeAssetVersion || "";
  packageVersion.textContent = runtimeVersion && runtimeVersion !== status.packageVersion
    ? `Package ${status.packageVersion || "unknown"}; runtime assets ${runtimeVersion}`
    : `Package ${status.packageVersion || runtimeVersion || "unknown"}`;
  const showConfigured = status.configured && !editing;
  configuredView.classList.toggle("hidden", !showConfigured);
  form.classList.toggle("hidden", showConfigured);
  operationsPanel.classList.toggle("hidden", !status.configured);
  backupPanel.classList.toggle("hidden", !status.configured);
  restorePanel.classList.toggle("hidden", !status.configured);
  if (showConfigured) {
    populateConfiguredView();
  } else if (!formTouched) {
    hydrateForm();
  }
  renderCommunityLock();
  renderOperations();
  renderBackup();
  updateOwnerChangeState();
}

function formatNumber(value) {
  return Number.isFinite(value) ? new Intl.NumberFormat().format(value) : "--";
}

function formatBytes(value) {
  if (!Number.isFinite(value)) return "--";
  const units = ["B", "KB", "MB", "GB", "TB"];
  let amount = Math.max(0, value);
  let index = 0;
  while (amount >= 1024 && index < units.length - 1) {
    amount /= 1024;
    index += 1;
  }
  return `${amount >= 10 || index === 0 ? amount.toFixed(0) : amount.toFixed(1)} ${units[index]}`;
}

function formatDuration(value) {
  if (!Number.isFinite(value)) return "--";
  const seconds = Math.max(0, Math.floor(value));
  const days = Math.floor(seconds / 86400);
  const hours = Math.floor((seconds % 86400) / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  if (days) return `${days}d ${hours}h`;
  if (hours) return `${hours}h ${minutes}m`;
  return `${minutes}m`;
}

function formatTimestamp(value) {
  if (!value) return "Not observed";
  const parsed = new Date(value);
  return Number.isNaN(parsed.getTime()) ? "Unavailable" : parsed.toLocaleString();
}

function renderHealth(element, label, value) {
  element.dataset.state = value === true ? "ready" : value === false ? "error" : "unknown";
  element.textContent = `${label}: ${value === true ? "connected" : value === false ? "unavailable" : "unknown"}`;
}

function renderOperations() {
  if (!status?.configured) return;
  const operations = status.operations || {};
  const counts = operations.counts || {};
  const connectivity = operations.connectivity || {};
  metricRelay.textContent = operations.relayReady ? "Ready" : operations.relayReachable ? "Not ready" : "Stopped";
  metricUptime.textContent = formatDuration(operations.uptimeSeconds);
  metricVersion.textContent = operations.relayVersion || operations.packageVersion || "--";
  metricConnections.textContent = formatNumber(counts.activeConnections);
  metricMembers.textContent = formatNumber(counts.memberCount);
  metricChannels.textContent = formatNumber(counts.channelCount);
  metricMessages.textContent = formatNumber(counts.messageCount);
  metricEvents.textContent = formatNumber(counts.eventsReceivedSinceStart);
  metricStorage.textContent = formatBytes(operations.storage?.dataBytes);
  metricActivity.textContent = formatTimestamp(operations.lastObservedActivityAt);
  metricsFreshness.textContent = operations.storage?.measuredAt
    ? `Storage measured ${formatTimestamp(operations.storage.measuredAt)}`
    : "Live health";
  renderHealth(healthPostgres, "Postgres", connectivity.postgres);
  renderHealth(healthRedis, "Redis", connectivity.redis);
  renderHealth(healthMinio, "MinIO", connectivity.objectStorage);
  renderHealth(healthWorker, "Backup worker", connectivity.operationsWorker);
}

function renderBackup() {
  if (!status?.configured) return;
  const backup = status.backup || {};
  const latest = backup.latest || {};
  backupState.textContent = backup.running ? `${backup.progress || 0}%` : backup.state || "Idle";
  backupProgress.classList.toggle("hidden", !backup.running);
  backupProgressBar.style.width = `${backup.progress || 0}%`;
  backupMessage.textContent = backup.message || "No backup is running.";
  createBackup.disabled = Boolean(backup.running || !backup.workerOnline);
  acknowledgeSensitive.disabled = Boolean(backup.running);
  downloadBackup.classList.toggle("hidden", !latest.available);
  archiveDetails.classList.toggle("hidden", !latest.available);
  if (latest.available) {
    downloadBackup.href = latest.downloadUrl;
    downloadBackup.download = latest.name;
    backupCreated.textContent = formatTimestamp(latest.createdAt);
    backupSize.textContent = formatBytes(latest.sizeBytes);
    backupSha.textContent = latest.sha256 || "Unavailable";
  }
}

function showResult(kind, message) {
  result.className = `result ${kind}`;
  result.textContent = message;
}

function hideResult() {
  result.className = "result hidden";
  result.textContent = "";
}

function clearPreview(message = "") {
  preview = null;
  verifiedKey.classList.add("hidden");
  ownerHex.textContent = "";
  ownerNpub.textContent = "";
  ownerMessage.textContent = message;
  ownerMessage.dataset.kind = message ? "error" : "";
  hexConfirmRow.classList.add("hidden");
  confirmPublicHex.checked = false;
  syncReview();
  updateOwnerChangeState();
}

async function previewOwnerKey() {
  const value = ownerInput.value.trim();
  if (!value) {
    clearPreview();
    return;
  }
  if (/^(nostr:)?nsec/i.test(value) || /private key/i.test(value)) {
    clearPreview("Private keys and nsec values are rejected.");
    return;
  }
  try {
    const response = await api("api/preview-key", {
      method: "POST",
      body: JSON.stringify({ ownerKey: value }),
    });
    if (ownerInput.value.trim() !== value) {
      return;
    }
    preview = response;
    ownerHex.textContent = preview.ownerHex;
    ownerNpub.textContent = preview.ownerNpub;
    ownerMessage.textContent = "Owner public key verified.";
    ownerMessage.dataset.kind = "success";
    verifiedKey.classList.remove("hidden");
    hexConfirmRow.classList.toggle("hidden", !preview.rawHex);
  } catch (error) {
    clearPreview(error.message);
  }
  syncReview();
  updateOwnerChangeState();
}

function updateOwnerChangeState() {
  const ownerChanged = Boolean(
    status?.ownerConfigured && preview?.ownerHex && preview.ownerHex !== status.ownerHex
  );
  resetPanel.classList.toggle("hidden", !ownerChanged);
  if (ownerChanged) {
    submitButton.textContent = "Reset data and change owner";
    submitButton.classList.add("danger-button");
    actionTitle.textContent = "Destructive owner change";
    actionDetail.textContent = "A full application data reset is required.";
  } else if (status?.ownerConfigured) {
    submitButton.textContent = "Save configuration";
    submitButton.classList.remove("danger-button");
    actionTitle.textContent = "Review changes";
    actionDetail.textContent = "The canonical Community URL is locked after initialization.";
  } else {
    submitButton.textContent = "Save and start relay";
    submitButton.classList.remove("danger-button");
    actionTitle.textContent = "Ready to configure";
    actionDetail.textContent = "Only the verified public key is saved.";
  }
}

ownerInput.addEventListener("input", () => {
  formTouched = true;
  preview = null;
  verifiedKey.classList.add("hidden");
  confirmPublicHex.checked = false;
  hexConfirmRow.classList.add("hidden");
  ownerMessage.textContent = "Verifying public key...";
  ownerMessage.dataset.kind = "";
  syncReview();
  updateOwnerChangeState();
  window.clearTimeout(previewTimer);
  previewTimer = window.setTimeout(previewOwnerKey, 250);
});

modeInputs.forEach((input) => {
  input.addEventListener("change", () => {
    formTouched = true;
    renderMode();
  });
});

publicCommunityUrl.addEventListener("input", () => {
  formTouched = true;
  syncReview();
});

[confirmPublicHex, confirmReset, resetPhrase].forEach((element) => {
  element.addEventListener("input", () => {
    formTouched = true;
  });
});

editButton.addEventListener("click", () => {
  editing = true;
  formTouched = false;
  hideResult();
  renderStatus(status);
  ownerInput.focus();
});

copyCommunityUrl.addEventListener("click", async () => {
  const value = status?.communityUrl || "";
  if (!value) return;
  try {
    await navigator.clipboard.writeText(value);
    copyCommunityUrl.textContent = "Copied";
    window.setTimeout(() => {
      copyCommunityUrl.textContent = "Copy community URL";
    }, 1600);
  } catch (_error) {
    showResult("error", "Copy failed. Select and copy the Community URL manually.");
  }
});

createBackup.addEventListener("click", async () => {
  if (!acknowledgeSensitive.checked) {
    showResult("error", "Confirm that the archive contains sensitive private data.");
    return;
  }
  createBackup.disabled = true;
  showResult("working", "Starting backup...");
  try {
    const response = await api("api/backups", {
      method: "POST",
      body: JSON.stringify({ acknowledgeSensitive: true }),
    });
    showResult("success", response.message);
    await refreshStatus();
  } catch (error) {
    showResult("error", error.message);
  } finally {
    createBackup.disabled = Boolean(status?.backup?.running || !status?.backup?.workerOnline);
  }
});

form.addEventListener("submit", async (event) => {
  event.preventDefault();
  showResult("working", "Saving configuration...");
  submitButton.disabled = true;
  try {
    await previewOwnerKey();
    if (!preview) {
      throw new Error(ownerMessage.textContent || "Enter a valid public key.");
    }
    const communityMode = selectedMode();
    const communityUrl = selectedCommunityUrl();
    if (!communityUrl) {
      throw new Error(
        selectedMode() === "local"
          ? "The local Community URL is unavailable. Restart Buzz Relay from Umbrel and try again."
          : "Enter a Community URL."
      );
    }
    const response = await api("api/apply", {
      method: "POST",
      body: JSON.stringify({
        ownerKey: ownerInput.value,
        confirmPublicHex: confirmPublicHex.checked,
        communityMode,
        communityUrl: communityMode === "public" ? communityUrl : "",
        confirmReset: confirmReset.checked,
        resetPhrase: resetPhrase.value,
      }),
    });
    showResult("success", response.message);
    resetPhrase.value = "";
    confirmReset.checked = false;
    formTouched = false;
    editing = false;
    await refreshStatus();
  } catch (error) {
    showResult("error", error.message);
  } finally {
    submitButton.disabled = false;
  }
});

async function refreshStatus() {
  try {
    const response = await fetch("api/status", { cache: "no-store" });
    if (!response.ok) {
      throw new Error(`Status request failed (${response.status})`);
    }
    renderStatus(await response.json());
  } catch (_error) {
    setStatus("error", "Setup service unavailable");
    localCommunityUrl.textContent = "Status unavailable";
    localDetail.dataset.state = "error";
    localDiscoveryMessage.textContent =
      "Restart Buzz Relay from Umbrel. No manual technical URL entry is required.";
    packageVersion.textContent = "Package status unavailable";
  }
}

refreshStatus();
window.setInterval(refreshStatus, 3000);
