require "json"
require "time"
require "hive/bot/child_supervisor"

module Hive
  module Eval
    class FakeChildSupervisor
      ANYTHING = Object.new.freeze

      Dispatch = Struct.new(
        :pid,
        :command_argv,
        :cwd,
        :chat_id,
        :update_id,
        :project,
        :slug,
        :stdout,
        :stderr,
        :exit_status,
        :json_envelope,
        keyword_init: true
      )

      Response = Struct.new(:pattern, :stdout, :stderr, :exit_status, :json_envelope, keyword_init: true)

      attr_reader :dispatches

      def initialize(logger: nil, now: -> { Time.now })
        @logger = logger
        @now = now
        @responses = []
        @dispatches = []
        @completed = {}
        @unreaped = []
        @next_pid = 20_000
      end

      def self.anything
        ANYTHING
      end

      def respond_to(command_pattern)
        ResponseBuilder.new(self, command_pattern)
      end

      def add_response(pattern:, stdout: "", stderr: "", exit_status: 0, json_envelope: nil)
        @responses << Response.new(
          pattern: pattern,
          stdout: stdout,
          stderr: stderr,
          exit_status: exit_status,
          json_envelope: json_envelope
        )
      end

      def dispatch(command_argv:, cwd:, chat_id:, update_id:, project: nil, slug: nil)
        response = response_for(command_argv)
        @next_pid += 1
        dispatch = Dispatch.new(
          pid: @next_pid,
          command_argv: Array(command_argv),
          cwd: cwd,
          chat_id: chat_id,
          update_id: update_id,
          project: project,
          slug: slug,
          stdout: response.stdout,
          stderr: response.stderr,
          exit_status: response.exit_status,
          json_envelope: response.json_envelope || parse_json_envelope(response.stdout)
        )
        @dispatches << dispatch
        @logger&.event(:dispatched_command, pid: dispatch.pid, project: project,
                                            slug: slug, command: dispatch.command_argv.join(" "),
                                            dry_run: false, update_id: update_id)
        remember_exit(dispatch)
        dispatch.pid
      end

      def commands
        @dispatches.map(&:command_argv)
      end

      def completed_exit(pid)
        @completed[pid]
      end

      def reap_all
        @unreaped.shift(@unreaped.length)
      end

      def terminate_all(grace_sec:); end

      def in_flight_count
        0
      end

      private

      def response_for(argv)
        @responses.find { |response| command_matches?(response.pattern, argv) } ||
          Response.new(pattern: [], stdout: "", stderr: "", exit_status: 0, json_envelope: nil)
      end

      def command_matches?(pattern, argv)
        pattern = Array(pattern)
        argv = Array(argv)
        return false unless pattern.length == argv.length

        pattern.zip(argv).all? do |expected, actual|
          expected.equal?(ANYTHING) || expected === actual
        end
      end

      def parse_json_envelope(stdout)
        line = stdout.to_s.lines.reverse.find { |candidate| candidate.strip.start_with?("{") }
        line ? JSON.parse(line) : nil
      rescue JSON::ParserError
        nil
      end

      def remember_exit(dispatch)
        child = Hive::Bot::ChildSupervisor::ChildExit.new(
          pid: dispatch.pid,
          exit_code: dispatch.exit_status,
          project: dispatch.project,
          slug: dispatch.slug,
          command_argv: dispatch.command_argv,
          chat_id: dispatch.chat_id,
          update_id: dispatch.update_id,
          started_at: @now.call,
          finished_at: @now.call,
          log_path: nil,
          json_envelope: dispatch.json_envelope
        )
        @completed[dispatch.pid] = child
        @unreaped << child
        @logger&.event(:command_completed, pid: dispatch.pid, exit_code: dispatch.exit_status,
                                           project: dispatch.project, slug: dispatch.slug,
                                           update_id: dispatch.update_id,
                                           envelope_ok: dispatch.json_envelope&.dig("ok"),
                                           error_kind: dispatch.json_envelope&.dig("error_kind"))
      end

      class ResponseBuilder
        def initialize(supervisor, pattern)
          @supervisor = supervisor
          @pattern = pattern
        end

        def with_stdout(stdout, stderr: "", exit_status: 0, json_envelope: nil)
          @supervisor.add_response(
            pattern: @pattern,
            stdout: stdout,
            stderr: stderr,
            exit_status: exit_status,
            json_envelope: json_envelope
          )
        end
      end
    end
  end
end
