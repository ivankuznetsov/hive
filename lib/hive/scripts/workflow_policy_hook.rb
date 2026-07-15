#!/usr/bin/env ruby

require "json"
require "shellwords"
require "uri"

module Hive
  module Scripts
    module WorkflowPolicyHook
      module_function

      def run(policy_path, input: $stdin, output: $stdout)
        policy = JSON.parse(File.read(policy_path))
        event = JSON.parse(input.read)
        decision, reason = evaluate(policy, event)

        output.puts JSON.generate(
          "hookSpecificOutput" => {
            "hookEventName" => "PreToolUse",
            "permissionDecision" => decision,
            "permissionDecisionReason" => reason
          }
        )
      end

      def evaluate(policy, event)
        tool = event.fetch("tool_name", "")
        input = event.fetch("tool_input", {})
        return denied("tool is not declared by the managed workflow") unless policy.fetch("allowed_tools").include?(tool)

        denial = bash_denial(policy, input) if tool == "Bash"
        denial ||= web_fetch_denial(policy, input) if tool == "WebFetch"
        denial ||= path_denial(policy, input)
        denial || [ "allow", "declared by managed workflow policy" ]
      end

      def bash_denial(policy, input)
        command = input.fetch("command", "").to_s
        return denied("shell syntax is outside the declared command contract") if unsafe_shell_syntax?(command)

        command.split(/\s*(?:&&|;)\s*/).each do |segment|
          actual = Shellwords.shellsplit(segment)
          executable = actual.first
          resolved = policy.fetch("executables")[executable]
          return denied("shell executable is not approved") unless executable_approved?(executable, resolved)
          return denied("shell command is not declared by the managed workflow") unless command_declared?(policy, actual)
          return denied("shell network domain is not declared by the managed workflow") unless domains_declared?(policy, actual)
        rescue ArgumentError
          return denied("shell command has invalid quoting")
        end
        nil
      end

      def unsafe_shell_syntax?(command)
        command.empty? || command.match?(/[|<>`\n\r]|\$\(|\$\{/)
      end

      def executable_approved?(executable, resolved)
        resolved && (executable == File.basename(executable) || File.expand_path(executable) == resolved)
      end

      def command_declared?(policy, actual)
        policy.fetch("commands").any? do |declaration|
          expected = Shellwords.shellsplit(declaration)
          prefix = expected.last == "*"
          expected.pop if prefix
          prefix ? actual.first(expected.length) == expected : actual == expected
        end
      end

      def domains_declared?(policy, arguments)
        hosts = arguments.filter_map do |argument|
          next unless argument.match?(%r{\Ahttps?://}i)

          URI.parse(argument).host.to_s.downcase
        rescue URI::InvalidURIError
          ""
        end
        hosts.all? { |host| !host.empty? && domain_allowed?(policy, host) }
      end

      def web_fetch_denial(policy, input)
        host = URI.parse(input.fetch("url", "").to_s).host.to_s.downcase
        return if domain_allowed?(policy, host)

        denied("network domain is not declared by the managed workflow")
      rescue URI::InvalidURIError
        denied("network domain is not declared by the managed workflow")
      end

      def domain_allowed?(policy, host)
        policy.fetch("domains").any? do |entry|
          normalized = entry.delete_prefix("*.")
          host == normalized || (entry.start_with?("*.") && host.end_with?(".#{normalized}"))
        end
      end

      def path_denial(policy, input)
        path = input["file_path"] || input["path"]
        return unless path

        resolved = resolve_with_existing_ancestor(path)
        allowed = policy.fetch("directories").any? do |directory|
          resolved == directory || resolved.start_with?(directory + File::SEPARATOR)
        end
        denied("path is outside the managed workflow directory scope") unless allowed
      end

      def resolve_with_existing_ancestor(path)
        candidate = File.expand_path(path)
        suffix = []
        cursor = candidate
        until File.exist?(cursor) || File.symlink?(cursor) || cursor == File.dirname(cursor)
          suffix.unshift(File.basename(cursor))
          cursor = File.dirname(cursor)
        end
        File.join(File.realpath(cursor), *suffix)
      rescue Errno::ENOENT, Errno::EACCES
        candidate
      end

      def denied(reason)
        [ "deny", reason ]
      end
    end
  end
end
