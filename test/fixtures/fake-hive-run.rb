#!/usr/bin/env ruby
# frozen_string_literal: false

# Deterministic stand-in for `hive ...` subprocesses spawned by
# ChildSupervisor. Used to test exit-code branches and stdout shapes
# without invoking the real hive binary.
#
# Mirrors a subset of real `hive` argv shape. The first positional is
# usually a verb (run / brainstorm / plan / develop / review / pr /
# archive); the second is a slug; everything after that is flags. The
# fixture does not interpret the verb / slug — it only reads its
# control flags below.
#
# Control flags (these MUST come before any unknown flag):
#   --exit-code N      Exit with code N (default 0)
#   --stdout-text S    Write S to stdout (no newline appended)
#   --stderr-text S    Write S to stderr (no newline appended)
#   --sleep SEC        Sleep SEC seconds before exiting

control_flags = {
  "--exit-code"   => :exit_code,
  "--stdout-text" => :stdout,
  "--stderr-text" => :stderr,
  "--sleep"       => :sleep
}

opts = { exit_code: 0, stdout: nil, stderr: nil, sleep: 0.0 }

# Manual argv walk: drop unknown flags + positionals silently, capture
# our own control flags. This is more robust than OptionParser for the
# fixture's purpose (we don't want OptionParser eating real hive flags
# like --json or --project as if they were our own).
i = 0
while i < ARGV.size
  arg = ARGV[i]
  if control_flags.key?(arg)
    key = control_flags[arg]
    val = ARGV[i + 1]
    case key
    when :exit_code then opts[:exit_code] = Integer(val)
    when :sleep     then opts[:sleep] = Float(val)
    else                 opts[key] = val
    end
    i += 2
  else
    i += 1
  end
end

sleep opts[:sleep] if opts[:sleep] > 0

$stdout.write(opts[:stdout]) if opts[:stdout]
$stderr.write(opts[:stderr]) if opts[:stderr]

exit opts[:exit_code]
