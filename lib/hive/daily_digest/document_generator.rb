require "fileutils"
require "tempfile"
require "hive/agent"
require "hive/agent_runtime"
require "hive/config"
require "hive/paths"
require "hive/secret_patterns"
require "hive/stages/base"

module Hive
  module DailyDigest
    # PRDigest owns the prompt; the host's configured agent supplies prose.
    class DocumentGenerator
      OUTPUT_LIMIT = 8 * 1024 * 1024

      def initialize(config_loader: -> { Config.load(Paths.state_home).merge("daily_digest" => Config.load_global_daily_digest) }, timeout_sec: 300)
        @config_loader, @timeout_sec = config_loader, timeout_sec
      end

      def generate(facts)
        require "prdigest"
        config = @config_loader.call
        profile = Hive::Stages::Base.stage_profile(config, "execute", explicit_agent: config.dig("daily_digest", "agent"))
        invocation = Hive::AgentRuntime.compile(Hive::AgentRuntime::Request.new(
          profile: profile, prompt: Prdigest::Document.prompt(facts),
          permission_mode: Hive::Config.claude_permission_mode(config),
          **Hive::Stages::Base.model_launch_arguments(config, "execute", profile, current: config.fetch("daily_digest", {}))
        ))
        output = capture(invocation, profile)
        text = final_message(profile, output)
        if text.to_s.strip.empty?
          raise Hive::AgentError, "digest agent did not return a complete document"
        end
        Hive::SecretPatterns.redact(text)
      end

      private

      def final_message(profile, output)
        begin
          parsed = Hive::AgentRuntime.parse_run(profile, stdout: output)
          return nil if parsed.final_message_truncated || %w[length content-filter].include?(parsed.terminal_reason)

          return parsed.final_message
        rescue AgentCliRuntime::UnsupportedCapability
          # Older adapters use Hive's event extractor rather than the strict
          # runtime parser. Launcher text still cannot become a document.
        end
        messages = Hive::Agent::MessageExtractor::Accumulator.new(
          max_bytes: 256 * 1024,
          structured_output_protocol: Hive::AgentSupport.for(profile) ||
            Hive::AgentSupport.for_protocol(profile.structured_output_protocol)
        )
        output.each_line do |line|
          messages.observe(Hive::Agent::MessageExtractor.parse_json_line(line), raw_line: line)
        end
        text = messages.value
        messages.source == :structured ? text : nil
      end

      def capture(invocation, profile)
        files = Array.new(3) { Tempfile.new("hive-digest-agent") }
        input, output, errors = files
        input.write(invocation.stdin_data.to_s)
        input.rewind
        FileUtils.mkdir_p(Paths.state_home, mode: 0o700)
        environment = profile.subscription_environment.merge(Hive::Agent::SCRUBBED_CHILD_ENV)
        pid = Process.spawn(environment, *invocation.argv, chdir: Paths.state_home,
                            in: input, out: output, err: errors, pgroup: true)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @timeout_sec
        loop do
          waited = Process.waitpid2(pid, Process::WNOHANG)
          if waited
            pid = nil
            unless waited.last.success?
              errors.rewind
              output.rewind
              detail = errors.read(2_000).to_s
              detail = final_message(profile, output.read(OUTPUT_LIMIT)).to_s if detail.empty?
              raise Hive::AgentError, "digest agent failed (exit #{waited.last.exitstatus}): #{Hive::SecretPatterns.redact(detail)[0, 2_000]}"
            end
            raise Hive::AgentError, "digest agent output exceeded the limit" if output.size > OUTPUT_LIMIT

            output.rewind
            return output.read
          end
          if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline ||
             output.size > OUTPUT_LIMIT || errors.size > OUTPUT_LIMIT
            raise Hive::AgentError, "digest agent exceeded its time or output limit"
          end
          sleep 0.1
        end
      ensure
        if pid
          begin
            Process.kill("KILL", -pid)
            Process.waitpid(pid)
          rescue Errno::ESRCH, Errno::ECHILD
            nil
          end
        end
        files&.each(&:close!)
      end
    end
  end
end
