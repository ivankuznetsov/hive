# 2026-10-02 — Keep Darwin replay aliases out of low descriptor slots

- Replay now duplicates the selected artifact onto reserved child descriptor
  198, falling back to 197 only if the source already occupies that slot.
- This keeps Darwin spawn and Bash 3.2 process-control activity from consuming
  or reusing the descriptor named by the replay alias.
