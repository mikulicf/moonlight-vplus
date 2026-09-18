"use strict";

(() => {
  let sessionToken = "";
  let currentUser = null;
  let users = [];
  let machines = [];
  let grants = [];
  let passwordUserID = "";
  let visibleHostToken = "";
  let toastTimer = 0;

  const byID = (id) => document.getElementById(id);
  const loginView = byID("login-view");
  const adminView = byID("admin-view");
  const loginForm = byID("login-form");
  const loginError = byID("login-error");
  const sessionBar = byID("session-bar");
  const toast = byID("toast");

  function setHidden(element, hidden) {
    element.hidden = hidden;
  }

  function setText(element, value) {
    element.textContent = value == null ? "" : String(value);
  }

  function button(label, className, action) {
    const item = document.createElement("button");
    item.type = "button";
    item.className = className;
    setText(item, label);
    item.addEventListener("click", action);
    return item;
  }

  function showToast(message, kind = "success") {
    window.clearTimeout(toastTimer);
    toast.className = `toast toast-${kind}`;
    setText(toast, message);
    setHidden(toast, false);
    toastTimer = window.setTimeout(() => {
      setHidden(toast, true);
      setText(toast, "");
    }, 4200);
  }

  async function api(path, options = {}) {
    const headers = new Headers(options.headers || {});
    headers.set("Accept", "application/json");
    if (sessionToken) headers.set("Authorization", `Bearer ${sessionToken}`);
    if (options.body !== undefined) headers.set("Content-Type", "application/json");

    const response = await fetch(path, {
      method: options.method || "GET",
      headers,
      body: options.body === undefined ? undefined : JSON.stringify(options.body),
      credentials: "omit",
      cache: "no-store",
      redirect: "error"
    });
    let payload = null;
    try {
      payload = await response.json();
    } catch (_) {
      payload = null;
    }
    if (!response.ok) {
      if (response.status === 401 && path !== "/v1/login") resetSession("Your session ended. Sign in again.");
      throw new Error(payload && payload.error ? payload.error : `Request failed (${response.status}).`);
    }
    return payload;
  }

  function resetSession(message = "") {
    sessionToken = "";
    currentUser = null;
    users = [];
    machines = [];
    grants = [];
    passwordUserID = "";
    hideHostToken();
    closePasswordModal();
    setHidden(adminView, true);
    setHidden(sessionBar, true);
    setHidden(loginView, false);
    if (message) {
      setText(loginError, message);
      setHidden(loginError, false);
    }
    byID("login-username").focus();
  }

  function showAdmin() {
    setText(byID("session-user"), currentUser.username);
    setHidden(loginError, true);
    setHidden(loginView, true);
    setHidden(sessionBar, false);
    setHidden(adminView, false);
  }

  async function loadData(showConfirmation = false) {
    const [nextUsers, nextMachines, nextGrants, audit] = await Promise.all([
      api("/v1/admin/users"),
      api("/v1/admin/machines"),
      api("/v1/admin/grants"),
      api("/v1/admin/audit")
    ]);
    users = Array.isArray(nextUsers) ? nextUsers : [];
    machines = Array.isArray(nextMachines) ? nextMachines : [];
    grants = Array.isArray(nextGrants) ? nextGrants : [];
    renderUsers();
    renderMachines();
    renderGrants();
    renderAudit(Array.isArray(audit) ? audit : []);
    if (showConfirmation) showToast("Administration data refreshed.");
  }

  function badge(text, kind) {
    const item = document.createElement("span");
    item.className = `badge badge-${kind}`;
    setText(item, text);
    return item;
  }

  function recordHeader(title, subtitle, badges) {
    const header = document.createElement("div");
    header.className = "record-header";
    const copy = document.createElement("div");
    const heading = document.createElement("h3");
    const detail = document.createElement("p");
    setText(heading, title);
    setText(detail, subtitle);
    copy.append(heading, detail);
    const badgeRow = document.createElement("div");
    badgeRow.className = "badge-row";
    badges.forEach((item) => badgeRow.append(item));
    header.append(copy, badgeRow);
    return header;
  }

  function renderUsers() {
    const list = byID("users-list");
    list.replaceChildren();
    setText(byID("user-count"), `${users.length} ${users.length === 1 ? "user" : "users"}`);
    users.forEach((user) => {
      const card = document.createElement("article");
      card.className = "record-card";
      const badges = [badge(user.disabled ? "Disabled" : "Active", user.disabled ? "muted" : "good")];
      if (user.admin) badges.push(badge("Admin", "accent"));
      card.append(recordHeader(user.username, `ID ${user.id}`, badges));

      const actions = document.createElement("div");
      actions.className = "button-row record-actions";
      actions.append(
        button("Reset password", "button button-secondary", () => openPasswordModal(user)),
        button(user.admin ? "Remove admin" : "Make admin", "button button-quiet", async () => {
          await updateUser(user.id, { admin: !user.admin }, "Administrator role updated.");
        }),
        button(user.disabled ? "Enable user" : "Disable user", user.disabled ? "button button-secondary" : "button button-danger", async () => {
          await updateUser(user.id, { disabled: !user.disabled }, user.disabled ? "User enabled." : "User disabled.");
        })
      );
      card.append(actions);
      list.append(card);
    });
    if (!users.length) list.append(emptyState("No users have been created."));
  }

  async function updateUser(id, changes, successMessage) {
    try {
      await api(`/v1/admin/users/${encodeURIComponent(id)}`, { method: "PATCH", body: changes });
      await loadData();
      showToast(successMessage);
    } catch (error) {
      showToast(error.message, "error");
    }
  }

  function renderMachines() {
    const list = byID("machines-list");
    list.replaceChildren();
    setText(byID("machine-count"), `${machines.length} ${machines.length === 1 ? "machine" : "machines"}`);
    machines.forEach((machine) => {
      const card = document.createElement("article");
      card.className = "record-card";
      const state = machine.disabled ? badge("Disabled", "muted") : badge("Enabled", "good");
      const lastSeen = machine.last_seen ? `Last seen ${formatTime(machine.last_seen)}` : "Awaiting first heartbeat";
      card.append(recordHeader(machine.name, `${machine.address} · HTTP ${machine.http_port} · HTTPS ${machine.https_port}`, [state]));
      const meta = document.createElement("p");
      meta.className = "record-meta";
      setText(meta, `${lastSeen} · ID ${machine.id}`);
      card.append(meta);

      const actions = document.createElement("div");
      actions.className = "button-row record-actions";
      actions.append(
        button(machine.disabled ? "Enable machine" : "Disable machine", machine.disabled ? "button button-secondary" : "button button-danger", async () => {
          await updateMachine(machine.id, { disabled: !machine.disabled }, machine.disabled ? "Machine enabled." : "Machine disabled.");
        }),
        button("Rotate host token", "button button-quiet", () => rotateHostToken(machine))
      );
      card.append(actions);
      list.append(card);
    });
    if (!machines.length) list.append(emptyState("No machines have been added."));
  }

  async function updateMachine(id, changes, successMessage) {
    try {
      await api(`/v1/admin/machines/${encodeURIComponent(id)}`, { method: "PATCH", body: changes });
      await loadData();
      showToast(successMessage);
    } catch (error) {
      showToast(error.message, "error");
    }
  }

  async function rotateHostToken(machine) {
    if (!window.confirm(`Rotate the host token for ${machine.name}? The current token will stop working.`)) return;
    try {
      const result = await api(`/v1/admin/machines/${encodeURIComponent(machine.id)}/rotate-token`, { method: "POST", body: {} });
      if (!result || typeof result.host_token !== "string" || !result.host_token) {
        throw new Error("The token was rotated, but no replacement token was returned.");
      }
      showHostToken(result.host_token);
      await loadData();
    } catch (error) {
      showToast(error.message, "error");
    }
  }

  function emptyState(message) {
    const item = document.createElement("p");
    item.className = "empty-state";
    setText(item, message);
    return item;
  }

  function grantKey(userID, machineID) {
    return `${userID}\u0000${machineID}`;
  }

  function renderGrants() {
    const target = byID("grants-table");
    target.replaceChildren();
    if (!users.length || !machines.length) {
      target.append(emptyState("Create at least one user and one machine to assign access."));
      return;
    }
    const active = new Set(grants.map((grant) => grantKey(grant.user_id, grant.machine_id)));
    const table = document.createElement("table");
    const head = document.createElement("thead");
    const headingRow = document.createElement("tr");
    const userHeading = document.createElement("th");
    setText(userHeading, "User");
    headingRow.append(userHeading);
    machines.forEach((machine) => {
      const cell = document.createElement("th");
      setText(cell, machine.name);
      headingRow.append(cell);
    });
    head.append(headingRow);
    const body = document.createElement("tbody");
    users.forEach((user) => {
      const row = document.createElement("tr");
      const name = document.createElement("th");
      name.scope = "row";
      setText(name, user.username);
      row.append(name);
      machines.forEach((machine) => {
        const cell = document.createElement("td");
        const input = document.createElement("input");
        input.type = "checkbox";
        input.checked = active.has(grantKey(user.id, machine.id));
        // Existing grants may always be revoked. Disabled records only prevent
        // creation of new grants.
        input.disabled = (user.disabled || machine.disabled) && !input.checked;
        input.setAttribute("aria-label", `${user.username} may access ${machine.name}`);
        input.addEventListener("change", async () => {
          const desired = input.checked;
          input.disabled = true;
          try {
            const path = `/v1/admin/grants/${encodeURIComponent(user.id)}/${encodeURIComponent(machine.id)}`;
            await api(path, { method: desired ? "PUT" : "DELETE" });
            if (desired) active.add(grantKey(user.id, machine.id));
            else active.delete(grantKey(user.id, machine.id));
            showToast(desired ? "Access granted." : "Access revoked.");
            const next = await api("/v1/admin/audit");
            renderAudit(Array.isArray(next) ? next : []);
          } catch (error) {
            input.checked = !desired;
            showToast(error.message, "error");
          } finally {
            input.disabled = (user.disabled || machine.disabled) && !input.checked;
          }
        });
        cell.append(input);
        row.append(cell);
      });
      body.append(row);
    });
    table.append(head, body);
    const scroller = document.createElement("div");
    scroller.className = "table-scroll";
    scroller.append(table);
    target.append(scroller);
  }

  function renderAudit(entries) {
    const body = byID("audit-body");
    body.replaceChildren();
    entries.forEach((entry) => {
      const row = document.createElement("tr");
      [formatTime(entry.at), entry.actor, entry.event, entry.target].forEach((value) => {
        const cell = document.createElement("td");
        setText(cell, value);
        row.append(cell);
      });
      body.append(row);
    });
    if (!entries.length) {
      const row = document.createElement("tr");
      const cell = document.createElement("td");
      cell.colSpan = 4;
      cell.className = "empty-state";
      setText(cell, "No audit events are available.");
      row.append(cell);
      body.append(row);
    }
  }

  function formatTime(value) {
    const number = Number(value);
    if (!Number.isFinite(number) || number <= 0) return "Never";
    const date = new Date(number < 100000000000 ? number * 1000 : number);
    return Number.isNaN(date.getTime()) ? "Unknown" : date.toLocaleString();
  }

  function openPasswordModal(user) {
    passwordUserID = user.id;
    setText(byID("password-user"), `Account: ${user.username}`);
    setHidden(byID("password-modal"), false);
    byID("reset-password").focus();
  }

  function closePasswordModal() {
    passwordUserID = "";
    byID("reset-password").value = "";
    setText(byID("password-user"), "");
    setHidden(byID("password-modal"), true);
  }

  function showHostToken(token) {
    visibleHostToken = typeof token === "string" ? token : "";
    setText(byID("host-token"), visibleHostToken);
    setText(byID("copy-token"), "Copy token");
    setHidden(byID("token-modal"), false);
    byID("copy-token").focus();
  }

  function hideHostToken() {
    visibleHostToken = "";
    setText(byID("host-token"), "");
    setHidden(byID("token-modal"), true);
  }

  loginForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    const usernameField = byID("login-username");
    const passwordField = byID("login-password");
    let password = passwordField.value;
    passwordField.value = "";
    const credentials = { username: usernameField.value, password };
    setHidden(loginError, true);
    try {
      const result = await api("/v1/login", { method: "POST", body: credentials });
      if (!result.user || !result.user.admin) {
        sessionToken = result.token || "";
        if (sessionToken) await api("/v1/logout", { method: "POST", body: {} });
        throw new Error("Administrator access is required.");
      }
      sessionToken = result.token;
      currentUser = result.user;
      usernameField.value = "";
      showAdmin();
      await loadData();
    } catch (error) {
      resetSession(error.message);
      passwordField.focus();
    } finally {
      password = "";
      credentials.password = "";
    }
  });

  byID("logout-button").addEventListener("click", async () => {
    try {
      if (sessionToken) await api("/v1/logout", { method: "POST", body: {} });
    } catch (_) {
      // Local token removal is authoritative even if the network is unavailable.
    } finally {
      resetSession();
    }
  });

  byID("refresh-button").addEventListener("click", async () => {
    try {
      await loadData(true);
    } catch (error) {
      showToast(error.message, "error");
    }
  });

  byID("create-user-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    const form = event.currentTarget;
    const passwordField = byID("new-user-password");
    let password = passwordField.value;
    passwordField.value = "";
    const payload = {
      username: byID("new-username").value,
      password,
      admin: byID("new-user-admin").checked
    };
    try {
      await api("/v1/admin/users", { method: "POST", body: payload });
      form.reset();
      await loadData();
      showToast("User created.");
    } catch (error) {
      showToast(error.message, "error");
    } finally {
      password = "";
      payload.password = "";
    }
  });

  byID("create-machine-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    const form = event.currentTarget;
    const payload = {
      name: byID("new-machine-name").value,
      address: byID("new-machine-address").value,
      http_port: Number(byID("new-machine-http").value),
      https_port: Number(byID("new-machine-https").value)
    };
    try {
      const result = await api("/v1/admin/machines", { method: "POST", body: payload });
      form.reset();
      byID("new-machine-http").value = "47989";
      byID("new-machine-https").value = "47984";
      if (!result || typeof result.host_token !== "string" || !result.host_token) {
        throw new Error("The machine was created, but no host token was returned.");
      }
      showHostToken(result.host_token);
      await loadData();
    } catch (error) {
      showToast(error.message, "error");
    }
  });

  byID("password-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    const passwordField = byID("reset-password");
    let password = passwordField.value;
    passwordField.value = "";
    const payload = { password };
    const userID = passwordUserID;
    try {
      await api(`/v1/admin/users/${encodeURIComponent(userID)}`, { method: "PATCH", body: payload });
      closePasswordModal();
      await loadData();
      showToast("Password updated. Existing sessions were revoked.");
    } catch (error) {
      showToast(error.message, "error");
      passwordField.focus();
    } finally {
      password = "";
      payload.password = "";
    }
  });

  byID("password-cancel").addEventListener("click", closePasswordModal);
  byID("dismiss-token").addEventListener("click", hideHostToken);
  byID("copy-token").addEventListener("click", async () => {
    if (!visibleHostToken) return;
    try {
      await navigator.clipboard.writeText(visibleHostToken);
      setText(byID("copy-token"), "Copied");
    } catch (_) {
      showToast("Clipboard access was denied. Select and copy the token manually.", "error");
    }
  });

  document.querySelectorAll(".tab").forEach((tab) => {
    tab.addEventListener("click", () => {
      document.querySelectorAll(".tab").forEach((item) => item.classList.toggle("is-active", item === tab));
      document.querySelectorAll(".workspace").forEach((panel) => setHidden(panel, panel.id !== tab.dataset.panel));
    });
  });

  document.addEventListener("keydown", (event) => {
    if (event.key !== "Escape") return;
    if (!byID("token-modal").hidden) hideHostToken();
    if (!byID("password-modal").hidden) closePasswordModal();
  });
})();
