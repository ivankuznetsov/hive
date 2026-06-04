require "json"
require "pty"
require "securerandom"
require "thread"
require "fileutils"

module Hive
  module Web
    class AgentsAuth
      URL_RE = %r{https?://[^\s<>"']+}.freeze
      AGENT_COMMANDS = {
        "claude" => %w[claude setup-token],
        "codex" => %w[codex login]
      }.freeze

      Session = Struct.new(:id, :agent, :pid, :io, :output, :url, :done, :error, keyword_init: true)

      def initialize
        @sessions = {}
        @mutex = Mutex.new
      end

      def statuses
        %w[claude codex pi].to_h do |agent|
          [ agent, { "logged_in" => Hive::AgentProfiles.logged_in?(agent) } ]
        end
      end

      def start(agent)
        argv = AGENT_COMMANDS.fetch(agent.to_s)
        session = Session.new(id: SecureRandom.hex(8), agent: agent.to_s, output: +"", done: false)
        reader, writer, pid = PTY.spawn(*argv)
        session.io = writer
        session.pid = pid
        @mutex.synchronize { @sessions[session.id] = session }

        Thread.new do
          begin
            reader.each_char do |char|
              @mutex.synchronize do
                session.output << char
                session.url ||= session.output[URL_RE]
              end
            end
          rescue Errno::EIO
            nil
          ensure
            _, status = Process.wait2(pid)
            @mutex.synchronize { session.done = true; session.error = "exit #{status.exitstatus}" unless status.success? }
          end
        end
        session
      rescue KeyError
        raise Hive::InvalidTaskPath, "unknown agent login flow: #{agent}"
      end

      def session(id)
        @mutex.synchronize { @sessions[id] }
      end

      def complete(id, code)
        s = session(id)
        raise Hive::InvalidTaskPath, "unknown login session" unless s
        raise Hive::Error, "login session already finished" if s.done
        raise Hive::Error, "missing callback code or URL" if code.to_s.strip.empty?

        s.io.write("#{code}\n")
        s
      end

      def write_pi_token(raw_json)
        parsed = JSON.parse(raw_json.to_s)
        raise Hive::Error, "pi token JSON must be a non-empty object" unless parsed.is_a?(Hash) && parsed.any?

        path = File.expand_path("~/.pi/agent/auth.json")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, JSON.pretty_generate(parsed), mode: "w", perm: 0o600)
        path
      rescue JSON::ParserError => e
        raise Hive::Error, "pi token JSON is invalid: #{e.message}"
      end
    end
  end
end
