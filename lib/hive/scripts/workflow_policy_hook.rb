#!/usr/bin/env ruby

require "json"
require "shellwords"
require "uri"

policy_path = ARGV.fetch(0)
policy = JSON.parse(File.read(policy_path))
event = JSON.parse($stdin.read)
tool = event.fetch("tool_name", "")
input = event.fetch("tool_input", {})

decision = "allow"
reason = "declared by managed workflow policy"

deny = lambda do |message|
  decision = "deny"
  reason = message
end

unless policy.fetch("allowed_tools").include?(tool)
  deny.call("tool is not declared by the managed workflow")
end

if decision == "allow" && tool == "Bash"
  command = input.fetch("command", "").to_s
  if command.empty? || command.match?(/[|<>`\n\r]|\$\(|\$\{/)
    deny.call("shell syntax is outside the declared command contract")
  else
    segments = command.split(/\s*(?:&&|;)\s*/)
    segments.each do |segment|
      begin
        actual = Shellwords.shellsplit(segment)
      rescue ArgumentError
        deny.call("shell command has invalid quoting")
        break
      end
      executable = actual.first
      resolved = policy.fetch("executables")[executable]
      unless resolved && (executable == File.basename(executable) || File.expand_path(executable) == resolved)
        deny.call("shell executable is not approved")
        break
      end
      allowed = policy.fetch("commands").any? do |declaration|
        expected = Shellwords.shellsplit(declaration)
        prefix = expected.last == "*"
        expected.pop if prefix
        prefix ? actual.first(expected.length) == expected : actual == expected
      end
      unless allowed
        deny.call("shell command is not declared by the managed workflow")
        break
      end
    end
  end
end

if decision == "allow" && tool == "WebFetch"
  begin
    host = URI.parse(input.fetch("url", "").to_s).host.to_s.downcase
  rescue URI::InvalidURIError
    host = ""
  end
  allowed = policy.fetch("domains").any? do |entry|
    normalized = entry.delete_prefix("*.")
    host == normalized || (entry.start_with?("*.") && host.end_with?(".#{normalized}"))
  end
  deny.call("network domain is not declared by the managed workflow") unless allowed
end

if decision == "allow"
  path = input["file_path"] || input["path"]
  if path
    expanded = File.expand_path(path)
    resolved = begin
      File.realpath(expanded)
    rescue Errno::ENOENT, Errno::EACCES
      expanded
    end
    allowed = policy.fetch("directories").any? do |directory|
      resolved == directory || resolved.start_with?(directory + File::SEPARATOR)
    end
    deny.call("path is outside the managed workflow directory scope") unless allowed
  end
end

puts JSON.generate(
  "hookSpecificOutput" => {
    "hookEventName" => "PreToolUse",
    "permissionDecision" => decision,
    "permissionDecisionReason" => reason
  }
)
