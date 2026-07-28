module HiveLiveAgentProof
  module OpenClawCreatorGatewayRuntime
    class Main
      CONFIG_SCHEMA = "hive-openclaw-audit-gateway-config".freeze
      CONFIG_VERSION = 1
      CONFIG_KEYS = %w[
        audit_path candidate candidate_identity commands credential_names expected_digest
        lock_path result_path run_placeholder safe_slug_pattern schema schema_version
        task_key task_workflow workspace
      ].freeze
      SHA256 = /\A[0-9a-f]{64}\z/

      def self.call(config, argv)
        new(config).call(argv)
      rescue InvalidLedger => e
        warn "workflow-creator proof audit ledger is invalid: #{e.message}"
        68
      rescue LedgerWriteFailed => e
        warn "workflow-creator proof audit write/fsync failed: #{e.message}"
        69
      rescue StandardError => e
        warn "workflow-creator proof gateway failed closed: #{e.class}: #{e.message}"
        69
      end

      def initialize(config)
        validate_config!(config)
        @config = config
        @candidate = config.fetch("candidate")
        @expected_digest = config.fetch("expected_digest")
        @commands = config.fetch("commands")
        @workspace = config["workspace"]
        @safe_slug = Regexp.new(config.fetch("safe_slug_pattern"))
        @ledger = AttemptLedger.new(
          path: config.fetch("audit_path"),
          candidate_realpath: @candidate,
          candidate_sha256: @expected_digest
        )
        @result_appender = DurableJsonLineAppender.new(config.fetch("result_path"))
        @result_ledger =
          ResultLedger.new(path: config.fetch("result_path"), safe_slug: @safe_slug)
        @task_binding = TaskBinding.new(
          workspace: @workspace,
          safe_slug: @safe_slug,
          task_key: config.fetch("task_key"),
          workflow: config.fetch("task_workflow")
        )
        @identity = CandidateIdentity.new(
          candidate: @candidate,
          expected_digest: @expected_digest,
          installation_identity: config["candidate_identity"]
        )
        @executor = CandidateExecutor.new(
          candidate: @candidate,
          credential_names: config.fetch("credential_names"),
          safe_slug: @safe_slug
        )
      end

      def call(argv)
        with_lock do
          state = @ledger.read
          return pending_failure(state.pending) if state.pending
          return poisoned_failure(state.poisoned_terminal) if state.poisoned_terminal
          result_rows = @result_ledger.read(attempt_pairs: state.pairs)
          attempt = @ledger.begin_attempt(state: state, argv: argv)
          execute_attempt(attempt, completed_count: state.completed_count, result_rows: result_rows)
        end
      end

      private

      def with_lock
        path = @config.fetch("lock_path")
        FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
        reject_existing_non_regular!(path, "gateway lock")
        flags = File::RDWR | File::CREAT
        flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
        File.open(path, flags, 0o600) do |lock|
          raise InvalidLedger, "gateway lock is not a regular file" unless lock.stat.file?
          lock.flock(File::LOCK_EX)
          yield
        end
      end

      def execute_attempt(attempt, completed_count:, result_rows:)
        expected = @commands.fetch(completed_count, nil)
        unless expected
          return deny_attempt(
            attempt, expected: nil, dynamic_slug: nil,
            reason: "budget_exhausted", exit_code: 64,
            message: "workflow-creator proof command budget is exhausted"
          )
        end

        dynamic_slug = nil
        if expected == [ "run", @config.fetch("run_placeholder") ]
          dynamic_slug = @task_binding.created_slug(
            result_rows: result_rows, ordinal: attempt.fetch("ordinal")
          )
          unless dynamic_slug
            return deny_attempt(
              attempt, expected: expected, dynamic_slug: nil,
              reason: "dynamic_binding_failed", exit_code: 66,
              message: "workflow-creator proof could not bind one created slug"
            )
          end
          expected = [ "run", dynamic_slug ]
        end
        unless attempt.fetch("argv") == expected
          return deny_attempt(
            attempt, expected: expected, dynamic_slug: dynamic_slug,
            reason: "wrong_order", exit_code: 64,
            message: "workflow-creator proof expected #{expected.inspect}, " \
                     "got #{attempt.fetch('argv').inspect}"
          )
        end
        unless @identity.valid?
          return deny_attempt(
            attempt, expected: expected, dynamic_slug: dynamic_slug,
            reason: "candidate_digest_drift", exit_code: 65,
            message: "workflow-creator proof candidate digest changed"
          )
        end
        run_candidate(attempt, expected: expected, dynamic_slug: dynamic_slug)
      rescue LedgerWriteFailed
        raise
      rescue StandardError => e
        finish_unexpected(attempt, expected: expected, dynamic_slug: dynamic_slug, error: e)
      end

      def run_candidate(attempt, expected:, dynamic_slug:)
        result = @executor.call(
          argv: attempt.fetch("argv"),
          ordinal: attempt.fetch("ordinal"),
          attempt_id: attempt.fetch("attempt_id")
        )
        unless @identity.valid?
          warn "workflow-creator proof candidate closure changed"
          return fail_attempt(
            attempt, expected: expected, dynamic_slug: dynamic_slug,
            reason: "candidate_closure_drift", exit_code: 65, status: result.status
          )
        end
        if result.result_record
          begin
            @result_appender.append(result.result_record)
          rescue LedgerWriteFailed => e
            warn "workflow-creator proof result write failed: #{e.message}"
            return fail_attempt(
              attempt, expected: expected, dynamic_slug: dynamic_slug,
              reason: "result_write_failed", exit_code: 69, status: result.status
            )
          end
        end
        if result.success
          @ledger.finish_attempt(
            attempt: attempt,
            expected_argv: expected,
            dynamic_slug: dynamic_slug,
            decision: "succeeded",
            reason: "completed",
            exit_status: result.status.exitstatus,
            signal: result.status.termsig
          )
          0
        else
          fail_attempt(
            attempt, expected: expected, dynamic_slug: dynamic_slug,
            reason: result.reason, exit_code: result.exit_code, status: result.status
          )
        end
      rescue SystemCallError => e
        warn "workflow-creator proof candidate launch failed: #{e.message}"
        fail_attempt(
          attempt, expected: expected, dynamic_slug: dynamic_slug,
          reason: "candidate_launch_failed", exit_code: 69, status: nil
        )
      end

      def deny_attempt(attempt, expected:, dynamic_slug:, reason:, exit_code:, message:)
        @ledger.finish_attempt(
          attempt: attempt,
          expected_argv: expected,
          dynamic_slug: dynamic_slug,
          decision: "denied",
          reason: reason
        )
        warn message
        exit_code
      end

      def fail_attempt(attempt, expected:, dynamic_slug:, reason:, exit_code:, status:)
        @ledger.finish_attempt(
          attempt: attempt,
          expected_argv: expected,
          dynamic_slug: dynamic_slug,
          decision: "failed",
          reason: reason,
          exit_status: status&.exitstatus,
          signal: status&.termsig
        )
        exit_code
      end

      def finish_unexpected(attempt, expected:, dynamic_slug:, error:)
        warn "workflow-creator proof gateway failed closed: #{error.class}: #{error.message}"
        fail_attempt(
          attempt, expected: expected, dynamic_slug: dynamic_slug,
          reason: "gateway_internal_error", exit_code: 69, status: nil
        )
      end

      def pending_failure(row)
        warn(
          "workflow-creator proof audit ledger contains a pending attempt " \
          "(#{row.fetch('attempt_id')}: #{row.fetch('argv').inspect})"
        )
        68
      end

      def poisoned_failure(row)
        warn(
          "workflow-creator proof audit ledger contains a prior denied or failed attempt " \
          "(#{row.fetch('reason')}: #{row.fetch('argv').inspect})"
        )
        68
      end

      def validate_config!(config)
        raise InvalidLedger, "gateway config is not an object" unless config.is_a?(Hash)
        raise InvalidLedger, "gateway config fields are invalid" unless
          config.keys.sort == CONFIG_KEYS
        raise InvalidLedger, "gateway config schema is invalid" unless
          config["schema"] == CONFIG_SCHEMA &&
          config["schema_version"] == CONFIG_VERSION
        %w[audit_path candidate lock_path result_path].each do |key|
          raise InvalidLedger, "gateway config #{key} is not absolute" unless
            Pathname.new(config[key].to_s).absolute?
        end
        raise InvalidLedger, "gateway candidate digest is invalid" unless
          SHA256.match?(config["expected_digest"].to_s)
        raise InvalidLedger, "gateway command contract is invalid" unless
          config["commands"].is_a?(Array) && !config["commands"].empty? &&
          config["commands"].all? { |argv| argv?(argv) }
        raise InvalidLedger, "gateway credential contract is invalid" unless
          config["credential_names"].is_a?(Array) &&
          config["credential_names"].all? { |name| name.is_a?(String) }
        raise InvalidLedger, "gateway workspace is invalid" unless
          config["workspace"].nil? ||
          Pathname.new(config["workspace"].to_s).absolute?
        raise InvalidLedger, "gateway task workflow is invalid" unless
          config["task_workflow"].is_a?(String) &&
          /\A[a-z][a-z0-9_-]{0,63}\z/.match?(config["task_workflow"])
        Regexp.new(config.fetch("safe_slug_pattern"))
      rescue RegexpError, KeyError => e
        raise InvalidLedger, "gateway config is invalid: #{e.message}"
      end

      def argv?(value)
        value.is_a?(Array) &&
          value.all? { |argument| argument.is_a?(String) }
      end

      def reject_existing_non_regular!(path, label)
        return unless File.exist?(path) || File.symlink?(path)

        stat = File.lstat(path)
        raise InvalidLedger, "#{label} is not a regular file" unless
          stat.file? && !stat.symlink?
      end
    end
  end
end
