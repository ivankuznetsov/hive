#!/usr/bin/env ruby
# frozen_string_literal: false

require "rbconfig"

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
#   --descendant-pid-file PATH
#                      Spawn a TERM-ignoring child in a separate process group,
#                      write its PID to PATH, and leave it running for 30s

control_flags = {
  "--exit-code"   => :exit_code,
  "--stdout-text" => :stdout,
  "--stderr-text" => :stderr,
  "--sleep"       => :sleep,
  "--descendant-pid-file" => :descendant_pid_file
}

opts = {
  exit_code: 0, stdout: nil, stderr: nil, sleep: 0.0,
  descendant_pid_file: nil
}

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

if opts[:descendant_pid_file]
  Process.spawn(
    RbConfig.ruby, "-e", <<~'RUBY', opts[:descendant_pid_file],
      trap("TERM") { }
      File.write(ARGV.fetch(0), Process.pid)
      sleep 30
    RUBY
    pgroup: true, out: File::NULL, err: File::NULL
  )
end

sleep opts[:sleep] if opts[:sleep] > 0

$stdout.write(opts[:stdout]) if opts[:stdout]
$stderr.write(opts[:stderr]) if opts[:stderr]

exit opts[:exit_code]
