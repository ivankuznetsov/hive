#!/usr/bin/env ruby
# frozen_string_literal: true

# Prints the v1 slate's live availability — the model-pinned cells and whether
# each agent CLI is installed, authed, and new enough to run here. A cell that
# can't run reports a precise reason rather than being silently skipped.
#
#   ruby harness/preflight.rb

require "profiles/slate"

rows = HiveBench::Slate.profiles.map do |p|
  r = p.preflight
  [p.id, r.available, r.available ? "v#{r.version}" : r.reason]
end

width = rows.map { |id, _, _| id.length }.max
rows.each do |id, ok, detail|
  printf("%-#{width}s  %-3s  %s\n", id, ok ? "OK" : "NO", detail)
end

exit(rows.all? { |_, ok, _| ok } ? 0 : 1)
