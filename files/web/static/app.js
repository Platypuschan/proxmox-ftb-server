"use strict";

const $ = (id) => document.getElementById(id);
const AUTO_LABELS = ["pre-update", "pre-restore"];
const STATE_TEXT = {
  active: "Läuft",
  activating: "Startet …",
  deactivating: "Stoppt …",
  inactive: "Gestoppt",
  failed: "Fehlgeschlagen",
};

let statusTimer = null;
let logTimer = null;
let lastJobId = null;
let dismissedJobId = null;
let currentTab = "status";
let modpack = null;
// Finished jobs stay visible this long, so a reload days later starts clean.
const JOB_VISIBLE_SECONDS = 600;

// ---------------------------------------------------------------- API
async function api(path, options = {}) {
  const init = { ...options, headers: { ...(options.headers || {}) } };
  if (options.json !== undefined) {
    init.body = JSON.stringify(options.json);
    init.headers["Content-Type"] = "application/json";
  }
  const res = await fetch(path, init);
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || `Fehler ${res.status}`);
  return data;
}

// ---------------------------------------------------------------- formatting
function bytes(n) {
  if (n == null) return "–";
  const units = ["B", "KB", "MB", "GB", "TB"];
  let i = 0;
  while (n >= 1024 && i < units.length - 1) { n /= 1024; i++; }
  return `${n.toFixed(n >= 10 || i === 0 ? 0 : 1)} ${units[i]}`;
}

function duration(s) {
  if (s == null) return "–";
  const d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60);
  if (d) return `${d} T ${h} Std`;
  if (h) return `${h} Std ${m} Min`;
  return `${m} Min ${s % 60} s`;
}

function dateTime(epoch) {
  return new Date(epoch * 1000).toLocaleString("de-DE", { dateStyle: "medium", timeStyle: "short" });
}

function meter(id, used, total) {
  const pct = total ? Math.min(100, (used / total) * 100) : 0;
  const bar = $(id);
  bar.style.width = `${pct}%`;
  bar.classList.toggle("high", pct > 85);
}

// ---------------------------------------------------------------- tabs
function selectTab(name) {
  currentTab = name;
  for (const btn of document.querySelectorAll(".tabs button")) {
    btn.setAttribute("aria-selected", String(btn.dataset.tab === name));
  }
  for (const tab of ["status", "backups", "modpack", "console"]) $(`tab-${tab}`).hidden = tab !== name;
  clearInterval(logTimer);
  if (name === "backups") refreshBackups();
  if (name === "modpack") refreshModpack(false);
  if (name === "console") {
    refreshLog(true);
    logTimer = setInterval(() => refreshLog(false), 3000);
  }
}

for (const btn of document.querySelectorAll(".tabs button")) {
  btn.addEventListener("click", () => selectTab(btn.dataset.tab));
}

// ---------------------------------------------------------------- status
async function refreshStatus() {
  let st;
  try {
    st = await api("/api/status");
  } catch {
    return;
  }
  const svc = st.service;
  const running = svc.active === "active";
  const reachable = running && st.ping;
  const jobRunning = st.job && st.job.state === "running";

  $("pack-name").textContent = st.pack.name || "Minecraft-Server";
  const installed = modpack && String(modpack.current.id) === String(st.pack.version_id) ? modpack.current : null;
  $("pack-meta").textContent = installed
    ? `FTB-Pack ${st.pack.id} · Version ${installed.name} · Minecraft ${installed.mc}`
    : `FTB-Pack ${st.pack.id ?? "?"} · Version ${st.pack.version_id ?? "?"}`;
  document.title = `${st.pack.name || "Minecraft"} – ${STATE_TEXT[svc.active] || svc.active}`;

  const dot = $("state-dot");
  dot.className = "dot " + (reachable ? "ok" : running || svc.active.endsWith("ing") ? "busy" : svc.active === "failed" ? "bad" : "");

  let stateText = STATE_TEXT[svc.active] || svc.active;
  if (running && !st.ping) stateText = "Startet … (Welt wird geladen)";
  $("s-state").textContent = stateText;
  $("s-uptime").textContent = running ? duration(svc.uptime) : "–";
  $("s-version").textContent = st.ping?.version || "–";
  $("s-motd").textContent = st.ping?.motd || "–";
  $("s-port").textContent = `${location.hostname}:${st.port}`;
  $("s-latency").textContent = st.ping ? `${st.ping.latency_ms} ms` : "–";

  const players = st.ping?.players || [];
  $("p-count").textContent = st.ping ? `${st.ping.online} / ${st.ping.max}` : "";
  $("p-list").replaceChildren(...players.map((name) => {
    const li = document.createElement("li");
    li.textContent = name;
    return li;
  }));
  $("p-empty").hidden = players.length > 0 || (st.ping && st.ping.online > 0);
  $("p-empty").textContent = st.ping ? "Niemand online." : "Server nicht erreichbar.";

  const sys = st.system;
  const cpuMax = 100 * (sys.cpus || 1);
  $("r-cpu-text").textContent = svc.cpu_percent != null && running ? `${svc.cpu_percent.toFixed(0)} % von ${cpuMax} %` : "–";
  meter("r-cpu", running ? svc.cpu_percent || 0 : 0, cpuMax);
  $("r-mem-text").textContent = running && svc.memory ? `${bytes(svc.memory)} von ${bytes(sys.mem_total)}` : "–";
  meter("r-mem", running ? svc.memory || 0 : 0, sys.mem_total);
  $("r-disk-text").textContent = `${bytes(sys.disk_used)} von ${bytes(sys.disk_total)}`;
  meter("r-disk", sys.disk_used, sys.disk_total);
  $("r-load").textContent = `Last: ${sys.load.map((l) => l.toFixed(2)).join(" / ")} · ${sys.cpus} CPU`;

  $("btn-start").disabled = jobRunning || running || svc.active === "activating";
  $("btn-stop").disabled = jobRunning || !running;
  $("btn-restart").disabled = jobRunning || !running;
  $("console-input").disabled = !running;

  renderJob(st.job);
}

// ---------------------------------------------------------------- jobs
function renderJob(job) {
  const stale = job && job.state !== "running" && Date.now() / 1000 - job.finished > JOB_VISIBLE_SECONDS;
  if (!job || job.id === dismissedJobId || stale) {
    $("job").hidden = true;
    return;
  }
  $("job").hidden = false;
  $("job-title").textContent = job.title;
  const badge = $("job-state");
  badge.className = `badge ${job.state}`;
  badge.textContent = { running: "läuft", done: "erledigt", failed: "fehlgeschlagen" }[job.state];
  const out = $("job-output");
  const atBottom = out.scrollTop + out.clientHeight >= out.scrollHeight - 20;
  out.textContent = job.output.join("\n") || (job.state === "running" ? "…" : "Ohne Ausgabe.");
  if (atBottom) out.scrollTop = out.scrollHeight;
  $("job-close").hidden = job.state === "running";

  // A job just finished: reload the lists it may have changed.
  if (job.state !== "running" && lastJobId === job.id + ":running") {
    if (currentTab === "backups") refreshBackups();
    if (job.kind === "modpack") refreshModpack(true);
  }
  lastJobId = `${job.id}:${job.state}`;
}

$("job-close").addEventListener("click", () => {
  dismissedJobId = lastJobId?.split(":")[0];
  $("job").hidden = true;
});

async function startJob(promise) {
  try {
    const job = await promise;
    dismissedJobId = null;
    renderJob(job);
  } catch (err) {
    alert(err.message);
  }
  refreshStatus();
}

function confirmAction(title, text, okLabel) {
  return new Promise((resolve) => {
    const dlg = $("confirm");
    $("confirm-title").textContent = title;
    $("confirm-text").textContent = text;
    $("confirm-ok").textContent = okLabel;
    dlg.addEventListener("close", () => resolve(dlg.returnValue === "ok"), { once: true });
    dlg.showModal();
  });
}

// ---------------------------------------------------------------- server actions
for (const btn of document.querySelectorAll("[data-action]")) {
  btn.addEventListener("click", async () => {
    const action = btn.dataset.action;
    if (action !== "start") {
      const ok = await confirmAction(
        action === "stop" ? "Server stoppen?" : "Server neu starten?",
        "Alle Spieler werden getrennt. Die Welt wird vorher gespeichert.",
        action === "stop" ? "Stoppen" : "Neu starten",
      );
      if (!ok) return;
    }
    startJob(api(`/api/server/${action}`, { method: "POST" }));
  });
}

// ---------------------------------------------------------------- backups
async function refreshBackups() {
  let data;
  try {
    data = await api("/api/backups");
  } catch {
    return;
  }
  $("b-free").textContent = `· ${bytes(data.free)} frei`;
  const p = data.provider;
  $("b-provider").textContent = p.kind === "own"
    ? `Das Modpack hat kein FTB Backups 2/3. Backups werden im Format von FTB Backups 3 in ${p.folder} abgelegt.`
    : `Backups laufen über ${p.name} (${p.folder}): automatische Backups des Mods erscheinen hier, ` +
      "Backups von hier erscheinen im Mod. Gesichert wird die Welt.";
  $("b-empty").hidden = data.backups.length > 0;
  $("b-list").replaceChildren(...data.backups.map(backupRow));
}

function backupRow(b) {
  const tr = document.createElement("tr");
  const kind = AUTO_LABELS.includes(b.label) ? "automatisch (Skript)"
    : b.auto ? "automatisch (Mod)"
    : b.protected ? "manuell, geschützt" : "manuell";
  const cells = [
    dateTime(b.created) + (b.complete ? "" : " (unvollständig)"),
    b.label || "–",
    kind,
    bytes(b.size),
  ];
  for (const text of cells) {
    const td = document.createElement("td");
    td.textContent = text;
    tr.append(td);
  }
  const actions = document.createElement("td");
  actions.className = "row-actions";

  const dl = document.createElement("a");
  dl.href = `/api/backups/${encodeURIComponent(b.name)}/download`;
  dl.textContent = "Download";
  dl.title = b.name;
  dl.hidden = b.format !== "zip";

  const restore = document.createElement("button");
  restore.className = "small";
  restore.textContent = "Einspielen";
  restore.addEventListener("click", async () => {
    const ok = await confirmAction(
      "Backup einspielen?",
      `Der Server wird gestoppt und die Welt durch das Backup vom ${dateTime(b.created)} ersetzt. ` +
        "Vorher wird automatisch ein Sicherungs-Backup der aktuellen Welt angelegt (Bezeichnung „pre-restore“). " +
        "Mods und Konfiguration bleiben unverändert.",
      "Einspielen",
    );
    if (ok) startJob(api(`/api/backups/${encodeURIComponent(b.name)}/restore`, { method: "POST" }));
  });

  const del = document.createElement("button");
  del.className = "small danger";
  del.textContent = "Löschen";
  del.addEventListener("click", async () => {
    const ok = await confirmAction("Backup löschen?", `${b.name} wird endgültig gelöscht.`, "Löschen");
    if (ok) startJob(api(`/api/backups/${encodeURIComponent(b.name)}`, { method: "DELETE" }));
  });

  actions.append(dl, restore, del);
  tr.append(actions);
  return tr;
}

$("backup-form").addEventListener("submit", (e) => {
  e.preventDefault();
  startJob(api("/api/backups", { method: "POST", json: { label: $("backup-label").value } }));
  $("backup-label").value = "";
});

$("upload-form").addEventListener("submit", (e) => {
  e.preventDefault();
  const file = $("upload-file").files[0];
  if (!file) return;
  // XMLHttpRequest instead of fetch: it reports upload progress.
  const xhr = new XMLHttpRequest();
  const bar = $("upload-progress");
  bar.hidden = false;
  bar.value = 0;
  xhr.upload.addEventListener("progress", (ev) => {
    if (ev.lengthComputable) bar.value = (ev.loaded / ev.total) * 100;
  });
  xhr.addEventListener("loadend", () => {
    bar.hidden = true;
    $("upload-file").value = "";
    let data = {};
    try { data = JSON.parse(xhr.responseText); } catch { /* empty */ }
    if (xhr.status >= 400 || xhr.status === 0) {
      alert(data.error || "Upload fehlgeschlagen");
      return;
    }
    dismissedJobId = null;
    renderJob(data);
    refreshStatus();
  });
  xhr.open("PUT", "/api/backups/upload");
  xhr.setRequestHeader("X-Filename", file.name);
  xhr.send(file);
});

// ---------------------------------------------------------------- modpack
function versionLabel(v) {
  const date = v.released ? new Date(v.released * 1000).toLocaleDateString("de-DE") : "";
  return `${v.name} (${v.type})${v.mc ? ` · Minecraft ${v.mc}` : ""}${date ? ` · ${date}` : ""}`;
}

async function refreshModpack(force) {
  $("m-error").textContent = "";
  try {
    modpack = await api(`/api/modpack${force ? "?refresh=1" : ""}`);
  } catch (err) {
    $("m-error").textContent = err.message;
    return;
  }
  $("m-name").textContent = `${modpack.name} (ID ${modpack.pack_id})`;
  $("m-current").textContent = versionLabel(modpack.current);
  $("m-latest").textContent = modpack.latest ? versionLabel(modpack.latest) : "–";
  $("m-badge").hidden = !modpack.update_available;
  $("m-update-latest").disabled = !modpack.update_available;
  $("m-update-latest").textContent = modpack.update_available
    ? `Auf ${modpack.latest.name} aktualisieren`
    : "Aktuell (neueste Release installiert)";
  $("m-version").replaceChildren(...modpack.versions.map((v) => {
    const option = document.createElement("option");
    option.value = v.id;
    option.textContent = versionLabel(v) + (v.id === modpack.current.id ? " – installiert" : "");
    return option;
  }));
  $("m-version").value = String(modpack.latest ? modpack.latest.id : modpack.current.id);
  refreshStatus(); // header shows the version name once it is known
}

async function switchVersion(version) {
  const older = version.released < (modpack.current.released || 0);
  const ok = await confirmAction(
    `Modpack auf ${version.name} umstellen?`,
    `Der Server wird gestoppt, die Welt gesichert (Backup „pre-update“) und das Modpack auf ${versionLabel(version)} umgestellt. ` +
      (older ? "Achtung: Das ist eine ältere Version als die installierte; die Welt kann damit inkompatibel sein. " : "") +
      "Danach startet der Server wieder.",
    "Umstellen",
  );
  if (ok) startJob(api("/api/modpack/update", { method: "POST", json: { version_id: version.id } }));
}

$("m-update-latest").addEventListener("click", () => modpack?.latest && switchVersion(modpack.latest));
$("m-refresh").addEventListener("click", () => refreshModpack(true));
$("m-form").addEventListener("submit", (e) => {
  e.preventDefault();
  const version = modpack?.versions.find((v) => String(v.id) === $("m-version").value);
  if (!version) return;
  if (version.id === modpack.current.id) {
    alert("Diese Version ist bereits installiert.");
    return;
  }
  switchVersion(version);
});

// ---------------------------------------------------------------- console
async function refreshLog(scroll) {
  let data;
  try {
    data = await api("/api/log");
  } catch {
    return;
  }
  const log = $("log");
  const atBottom = scroll || log.scrollTop + log.clientHeight >= log.scrollHeight - 30;
  log.textContent = data.lines.join("\n");
  if (atBottom) log.scrollTop = log.scrollHeight;
}

$("console-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const input = $("console-input");
  const command = input.value.trim();
  if (!command) return;
  try {
    await api("/api/console", { method: "POST", json: { command } });
    input.value = "";
    setTimeout(() => refreshLog(true), 800);
  } catch (err) {
    alert(err.message);
  }
});

// ---------------------------------------------------------------- start
refreshModpack(false);
refreshStatus();
statusTimer = setInterval(refreshStatus, 4000);
selectTab(currentTab);
