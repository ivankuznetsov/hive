(() => {
  const grid = document.querySelector("[data-status-grid]");
  if (!grid || !window.EventSource) return;

  const el = (tag, text) => {
    const node = document.createElement(tag);
    if (text != null) node.textContent = String(text);
    return node;
  };

  const headerRow = () => {
    const tr = el("tr");
    ["Task", "Stage", "Status", "Action"].forEach((label) => tr.appendChild(el("th", label)));
    return tr;
  };

  const taskRow = (project, task) => {
    const tr = el("tr");
    tr.dataset.slug = task.slug;

    const link = el("a", task.slug);
    link.setAttribute("href", `/tasks/${encodeURIComponent(project.name)}/${encodeURIComponent(task.slug)}`);
    const slugCell = el("td");
    slugCell.appendChild(link);
    tr.appendChild(slugCell);

    tr.appendChild(el("td", task.stage));
    tr.appendChild(el("td", task.marker));
    tr.appendChild(el("td", task.action_label || task.action));
    return tr;
  };

  // Update an existing row in place (textContent only) so the browser keeps
  // focus, selection, and scroll position instead of having the whole grid
  // torn down every frame.
  const updateRow = (tr, project, task) => {
    const cells = tr.children;
    const link = cells[0].querySelector("a");
    if (link) {
      if (link.textContent !== task.slug) link.textContent = task.slug;
      link.setAttribute("href", `/tasks/${encodeURIComponent(project.name)}/${encodeURIComponent(task.slug)}`);
    }
    const set = (cell, value) => {
      const next = value == null ? "" : String(value);
      if (cell.textContent !== next) cell.textContent = next;
    };
    set(cells[1], task.stage);
    set(cells[2], task.marker);
    set(cells[3], task.action_label || task.action);
  };

  // Reconcile one project's <tbody> against its task list, keyed by slug:
  // update changed cells, append new rows, drop departed rows. Avoids the
  // full replaceChildren() that destroyed focus/scroll every tick.
  const reconcileTasks = (tbody, project) => {
    const tasks = project.tasks || [];
    const seen = new Set();
    const existing = new Map();
    Array.from(tbody.children).forEach((tr) => existing.set(tr.dataset.slug, tr));

    let cursor = tbody.firstChild;
    tasks.forEach((task) => {
      seen.add(task.slug);
      let tr = existing.get(task.slug);
      if (tr) {
        updateRow(tr, project, task);
      } else {
        tr = taskRow(project, task);
      }
      // Keep DOM order aligned with the snapshot order.
      if (cursor === tr) {
        cursor = tr.nextSibling;
      } else {
        tbody.insertBefore(tr, cursor);
      }
    });

    existing.forEach((tr, slug) => {
      if (!seen.has(slug)) tr.remove();
    });
  };

  // Build the per-project section (heading + optional error + table). Reused
  // when a project first appears.
  const buildProject = (project) => {
    const section = el("section");
    section.dataset.project = project.name;
    section.appendChild(el("h2", project.name));

    const errorP = el("p");
    errorP.className = "error";
    errorP.dataset.role = "project-error";
    section.appendChild(errorP);

    const table = el("table");
    const thead = el("thead");
    thead.appendChild(headerRow());
    table.appendChild(thead);
    table.appendChild(el("tbody"));
    section.appendChild(table);
    return section;
  };

  const syncProjectError = (section, project) => {
    const errorP = section.querySelector('[data-role="project-error"]');
    if (!errorP) return;
    const message = project.error || "";
    if (errorP.textContent !== message) errorP.textContent = message;
    errorP.hidden = message === "";
  };

  // The server renders a flat grid (h2 + table siblings, no keying
  // attributes). Replace it ONCE on the first live snapshot with the keyed
  // structure below; every later tick reconciles in place. This drops the
  // old per-frame replaceChildren() — which destroyed focus/scroll every
  // second — while still adopting the live structure exactly once.
  let initialized = false;

  // Reconcile the whole grid from a status snapshot, keyed by project name
  // then task slug, mirroring the server-rendered markup in views/grid.erb.
  // DOM is built node-by-node with textContent so task slugs/markers can
  // never inject markup.
  const render = (payload) => {
    if (!initialized) {
      grid.replaceChildren();
      initialized = true;
    }
    const projects = (payload && payload.projects) || [];
    const seen = new Set();
    const existing = new Map();
    Array.from(grid.children).forEach((node) => {
      if (node.dataset && node.dataset.project != null) existing.set(node.dataset.project, node);
    });

    projects.forEach((project) => {
      seen.add(project.name);
      let section = existing.get(project.name);
      if (!section) {
        section = buildProject(project);
        grid.appendChild(section);
      }
      syncProjectError(section, project);
      reconcileTasks(section.querySelector("tbody"), project);
    });

    existing.forEach((section, name) => {
      if (!seen.has(name)) section.remove();
    });
  };

  const MAX_BACKOFF_MS = 30000;
  const BASE_BACKOFF_MS = 1000;
  let attempt = 0;
  let source = null;
  let reconnectTimer = null;

  // Toggle the "live updates paused" banner via a class (no alert/confirm).
  const setPaused = (paused) => {
    grid.classList.toggle("status-grid--paused", paused);
    grid.dataset.live = paused ? "false" : "true";
  };

  const clearReconnect = () => {
    if (reconnectTimer != null) {
      clearTimeout(reconnectTimer);
      reconnectTimer = null;
    }
  };

  const scheduleReconnect = () => {
    if (reconnectTimer != null) return;
    // Exponential backoff with full jitter so many tabs reconnecting after an
    // outage don't stampede the SSE limiter in lockstep.
    const ceiling = Math.min(MAX_BACKOFF_MS, BASE_BACKOFF_MS * 2 ** attempt);
    const delay = Math.random() * ceiling;
    attempt += 1;
    reconnectTimer = setTimeout(() => {
      reconnectTimer = null;
      connect();
    }, delay);
  };

  function connect() {
    clearReconnect();
    if (source) source.close();

    source = new EventSource("/events");

    source.addEventListener("open", () => {
      attempt = 0;
      setPaused(false);
    });

    source.addEventListener("status", (event) => {
      setPaused(false);
      try {
        render(JSON.parse(event.data));
      } catch (_e) {
        // Ignore malformed frames; the next snapshot will re-render.
      }
    });

    source.addEventListener("error", () => {
      // A 503 (limiter full), a closed stream, or a network drop all land
      // here. Surface it to the user, close the dead handle, and reconnect
      // with backoff instead of letting EventSource hammer the limiter.
      setPaused(true);
      if (source) source.close();
      source = null;
      scheduleReconnect();
    });
  }

  const teardown = () => {
    clearReconnect();
    if (source) {
      source.close();
      source = null;
    }
  };

  // Close the stream when the page is hidden/unloaded so the server releases
  // the SSE slot promptly instead of waiting for a keep-alive write to fail.
  window.addEventListener("pagehide", teardown);
  window.addEventListener("beforeunload", teardown);

  connect();
})();
