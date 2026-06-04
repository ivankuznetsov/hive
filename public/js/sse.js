(() => {
  const grid = document.querySelector("[data-status-grid]");
  if (!grid || !window.EventSource) return;
  const source = new EventSource("/events");
  source.addEventListener("status", () => {
    grid.dataset.live = "true";
  });
})();
