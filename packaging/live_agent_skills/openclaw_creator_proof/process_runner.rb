module HiveLiveAgentProof
  module OpenClawCreatorProof
    class ProcessRunner
      attr_reader :containment_root_pid, :owner_pid, :worker_pid

      # Compatibility seam: callers which previously observed the supervisor
      # now observe the expendable worker, never the containment owner.
      def supervisor_pid = @worker_pid

      def initialize(timeout:, term_grace:, output_limit:, exact_secrets:,
                     worker_factory: nil)
        @timeout = Float(timeout)
        @term_grace = Float(term_grace)
        @output_limit = Integer(output_limit)
        @exact_secrets = exact_secrets.map(&:to_s)
        @worker_factory = worker_factory
        raise ArgumentError, "timeout must be positive" unless @timeout.positive?
        raise ArgumentError, "term_grace must be positive" unless @term_grace.positive?
        raise ArgumentError, "output_limit must be positive" unless @output_limit.positive?
      end

      def call(environment:, argv:, chdir:, stdin_data: nil, timeout: @timeout)
        ContainmentWarden.ensure_available!
        budget = ProcessBudget.new(timeout: timeout, term_grace: @term_grace)
        protocol = ProcessProtocol.new(
          output_limit: @output_limit,
          detail_limit: DETAIL_LIMIT
        )
        session = ContainmentSession.start(
          protocol: protocol,
          budget: budget,
          output_limit: @output_limit,
          exact_secrets: @exact_secrets,
          secret_patterns: HiveLiveAgentProof::SECRET_PATTERNS,
          request: {
            environment: environment,
            argv: argv,
            chdir: chdir,
            stdin_data: stdin_data,
            timeout: budget.timeout
          },
          worker_factory: @worker_factory
        )
        @containment_root_pid = session.pid
        session.result do |ready|
          @owner_pid = ready.owner_pid
          @worker_pid = ready.worker_pid
        end
      rescue EOFError, IOError, SystemCallError, TypeError, ArgumentError,
             RangeError => e
        fail_containment!(
          "process containment returned invalid evidence: #{e.message}"
        )
      ensure
        original_error = $!
        begin
          cleanup_error = cleanup_session(session)
        ensure
          @containment_root_pid = nil
          @owner_pid = nil
          @worker_pid = nil
        end
        raise cleanup_error if cleanup_error && original_error.nil?
      end

      private

      def cleanup_session(session)
        return unless session

        cleanup_error = nil
        begin
          cleanup_error = capture_cleanup_error("shutdown") { session.shutdown }
        ensure
          close_error = capture_cleanup_error("pipe close") { session.close }
        end
        cleanup_error || close_error
      end

      def capture_cleanup_error(action)
        yield
        nil
      rescue Failure => e
        e
      rescue StandardError => e
        Failure.new(
          phase: "process",
          reason: "containment_failed",
          detail: "process containment #{action} failed: #{e.class}: #{e.message}"
        )
      end

      def fail_containment!(detail)
        raise Failure.new(
          phase: "process",
          reason: "containment_failed",
          detail: detail
        )
      end
    end
  end
end
