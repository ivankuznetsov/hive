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

  // Rebuild the grid from a status snapshot. Mirrors the server-rendered
  // markup in views/grid.erb so the live SSE feed delivers real updates
  // (U4 live status grid) instead of only flipping a data attribute.
  // DOM is built node-by-node with textContent so task slugs/markers can
  // never inject markup.
  const render = (payload) => {
    const projects = (payload && payload.projects) || [];
    grid.replaceChildren();
    projects.forEach((project) => {
      grid.appendChild(el("h2", project.name));
      if (project.error) {
        const p = el("p", project.error);
        p.className = "error";
        grid.appendChild(p);
      }

      const table = el("table");
      const thead = el("thead");
      thead.appendChild(headerRow());
      table.appendChild(thead);

      const tbody = el("tbody");
      (project.tasks || []).forEach((task) => {
        const tr = el("tr");

        const link = el("a", task.slug);
        link.setAttribute("href", `/tasks/${encodeURIComponent(project.name)}/${encodeURIComponent(task.slug)}`);
        const slugCell = el("td");
        slugCell.appendChild(link);
        tr.appendChild(slugCell);

        tr.appendChild(el("td", task.stage));
        tr.appendChild(el("td", task.marker));
        tr.appendChild(el("td", task.action_label || task.action));
        tbody.appendChild(tr);
      });
      table.appendChild(tbody);
      grid.appendChild(table);
    });
  };

  const source = new EventSource("/events");
  source.addEventListener("status", (event) => {
    grid.dataset.live = "true";
    try {
      render(JSON.parse(event.data));
    } catch (_e) {
      // Ignore malformed frames; the next snapshot will re-render.
    }
  });
})();
