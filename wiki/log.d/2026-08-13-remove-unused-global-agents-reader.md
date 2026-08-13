# Remove unused global agents reader

- Removed `Config.load_global_agents`, a tested but unconnected reader with no
  executable, setup, init, or routing caller.
- Retained direct coverage for the separately tested selection writer,
  normalizer, and setup prompt. Those surfaces are not connected to the
  current setup executable and remain separate cleanup candidates.
