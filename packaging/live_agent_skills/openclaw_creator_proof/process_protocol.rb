module HiveLiveAgentProof
  module OpenClawCreatorProof
    class ProcessProtocol
      FRAME_OVERHEAD_LIMIT = 64 * 1024
      Outcome = Data.define(:failure, :result) do
        def success? = failure.nil?
      end

      def initialize(output_limit:, detail_limit:)
        @output_limit = Integer(output_limit)
        @detail_limit = Integer(detail_limit)
        @codec = FramedJson.new(
          max_bytes: (@output_limit * 3) + FRAME_OVERHEAD_LIMIT
        )
      end

      def failure_outcome(reason:, detail:, phase: "process")
        Outcome.new(
          failure: Failure.new(
            phase: phase.to_s,
            reason: reason.to_s,
            detail: detail.to_s.byteslice(0, @detail_limit).to_s.scrub
          ),
          result: nil
        )
      end

      def success_outcome(result)
        Outcome.new(failure: nil, result: result)
      end

      def write_ready(io, worker_pid)
        @codec.write(io, { "frame" => "ready", "worker_pid" => worker_pid })
      end

      def read_ready(io, deadline:)
        frame = @codec.read(io, deadline: deadline)
        exact_keys!(frame, %w[frame worker_pid], "ready frame")
        unless frame["frame"] == "ready" && frame["worker_pid"].is_a?(Integer) &&
               frame["worker_pid"].positive?
          fail_containment!("ready frame has invalid types")
        end
        frame.fetch("worker_pid")
      end

      def write_worker_outcome(io, outcome)
        @codec.write(io, encode_outcome(outcome, frame_name: "worker_result", worker: true))
      end

      def read_worker_outcome(io, deadline:)
        decode_outcome(
          @codec.read(io, deadline: deadline),
          frame_name: "worker_result",
          worker: true,
          raise_failure: false
        )
      end

      def write_parent_outcome(io, outcome)
        @codec.write(io, encode_outcome(outcome, frame_name: "result", worker: false))
      end

      def read_parent_frame(io, deadline:)
        @codec.read(io, deadline: deadline)
      end

      def decode_parent_frame(frame)
        outcome = decode_outcome(
          frame,
          frame_name: "result",
          worker: false,
          raise_failure: true
        )
        payload = outcome.result
        status_record = payload.fetch("status_record")
        {
          "status" => status_record && CapturedProcessStatus.new(
            exitstatus: status_record.fetch("exitstatus"),
            termsig: status_record.fetch("termsig")
          ),
          "stdout" => payload.fetch("stdout"),
          "stderr" => payload.fetch("stderr"),
          "secret_findings" => payload.fetch("secret_findings"),
          "record" => payload.fetch("record")
        }
      end

      def expect_eof!(io, deadline:)
        @codec.expect_eof!(io, deadline: deadline)
      end

      private

      def encode_outcome(outcome, frame_name:, worker:)
        {
          "frame" => frame_name,
          "failure" => outcome.failure && {
            "phase" => outcome.failure.phase.to_s,
            "reason" => outcome.failure.reason.to_s,
            "detail" =>
              outcome.failure.message.to_s.byteslice(0, @detail_limit).to_s.scrub
          },
          "result" => outcome.result && encode_result(outcome.result, worker: worker)
        }
      end

      def encode_result(payload, worker:)
        result = {
          "status_record" => payload.fetch("status_record"),
          "stdout_base64" => Base64.strict_encode64(payload.fetch("stdout").to_s.b),
          "stderr_base64" => Base64.strict_encode64(payload.fetch("stderr").to_s.b),
          "secret_findings" => payload.fetch("secret_findings"),
          "record" => payload.fetch("record")
        }
        result["worker_teardown"] = payload.fetch("worker_teardown") if worker
        result
      end

      def decode_outcome(frame, frame_name:, worker:, raise_failure:)
        exact_keys!(frame, %w[failure frame result], "#{frame_name} frame")
        fail_containment!("#{frame_name} frame identity is invalid") unless
          frame["frame"] == frame_name
        failure = frame["failure"]
        result = frame["result"]
        unless failure.nil? ^ result.nil?
          fail_containment!("#{frame_name} frame must contain exactly one outcome")
        end
        if failure
          typed = decode_failure(failure)
          raise typed if raise_failure
          return Outcome.new(failure: typed, result: nil)
        end

        Outcome.new(
          failure: nil,
          result: decode_result(result, worker: worker)
        )
      end

      def decode_result(result, worker:)
        expected = %w[record secret_findings status_record stderr_base64 stdout_base64]
        expected << "worker_teardown" if worker
        exact_keys!(result, expected, worker ? "worker process result" : "process result")
        status_record = validate_status_record!(result["status_record"])
        stdout = decode_binary!(result["stdout_base64"], "stdout")
        stderr = decode_binary!(result["stderr_base64"], "stderr")
        findings = result["secret_findings"]
        unless findings.is_a?(Array) && findings.length <= 64 &&
               findings.all? { |value|
                 value.is_a?(String) && value.bytesize <= @detail_limit
               }
          fail_containment!("secret finding frame is invalid")
        end
        record = validate_process_record!(result["record"], worker: worker)
        payload = {
          "status_record" => status_record,
          "stdout" => stdout,
          "stderr" => stderr,
          "secret_findings" => findings,
          "record" => record
        }
        if worker
          payload["worker_teardown"] =
            validate_worker_teardown!(result["worker_teardown"])
        end
        payload
      end

      def validate_status_record!(record)
        return nil if record.nil?

        exact_keys!(record, %w[exitstatus termsig], "status record")
        unless nullable_nonnegative_integer?(record["exitstatus"]) &&
               nullable_nonnegative_integer?(record["termsig"])
          fail_containment!("status record types are invalid")
        end
        record
      end

      def validate_process_record!(record, worker:)
        expected = %w[
          argv_sha256 duration_ms executable exit_status interrupted signal stderr
          stdout timed_out network
        ]
        expected << "teardown" unless worker
        exact_keys!(record, expected, "process record")
        unless record["executable"].is_a?(String) &&
               record["executable"].bytesize <= @detail_limit &&
               record["argv_sha256"].is_a?(String) &&
               record["argv_sha256"].match?(/\A[0-9a-f]{64}\z/) &&
               nullable_nonnegative_integer?(record["exit_status"]) &&
               nullable_nonnegative_integer?(record["signal"]) &&
               boolean?(record["timed_out"]) &&
               boolean?(record["interrupted"]) &&
               record["duration_ms"].is_a?(Integer) && record["duration_ms"] >= 0
          fail_containment!("process record scalar types are invalid")
        end
        validate_stream_record!(record["stdout"], "stdout")
        validate_stream_record!(record["stderr"], "stderr")
        validate_network_record!(record["network"])
        validate_teardown_record!(record["teardown"]) unless worker
        record
      end

      def validate_stream_record!(record, label)
        exact_keys!(record, %w[bytes retained_bytes sha256 truncated], "#{label} record")
        valid = record["sha256"].is_a?(String) &&
                record["sha256"].match?(/\A[0-9a-f]{64}\z/) &&
                record["bytes"].is_a?(Integer) && record["bytes"] >= 0 &&
                record["retained_bytes"].is_a?(Integer) &&
                record["retained_bytes"].between?(0, @output_limit) &&
                record["retained_bytes"] <= record["bytes"] &&
                boolean?(record["truncated"])
        fail_containment!("#{label} record types are invalid") unless valid
      end

      def validate_teardown_record!(record)
        exact_keys!(
          record,
          %w[containment descendants kill_sent readers reaped status term_sent writer],
          "teardown record"
        )
        valid = %w[not_started passed failed].include?(record["status"]) &&
                boolean?(record["term_sent"]) &&
                boolean?(record["kill_sent"]) &&
                boolean?(record["reaped"]) &&
                %w[not_started complete incomplete].include?(record["readers"]) &&
                %w[not_started complete incomplete].include?(record["writer"]) &&
                %w[not_checked none remaining].include?(record["descendants"]) &&
                record["containment"] == "linux_child_subreaper"
        fail_containment!("teardown record types are invalid") unless valid
      end

      def validate_worker_teardown!(record)
        exact_keys!(
          record,
          %w[descendants kill_sent readers target_reaped term_sent writer],
          "worker teardown observation"
        )
        valid = boolean?(record["term_sent"]) &&
                boolean?(record["kill_sent"]) &&
                boolean?(record["target_reaped"]) &&
                %w[complete incomplete].include?(record["readers"]) &&
                %w[complete incomplete].include?(record["writer"]) &&
                %w[none remaining].include?(record["descendants"])
        fail_containment!("worker teardown observation types are invalid") unless valid
        record
      end

      def validate_network_record!(record)
        exact_keys!(
          record,
          %w[sample_count socket_count sockets status],
          "network observation"
        )
        sockets = record["sockets"]
        valid = %w[observed unavailable].include?(record["status"]) &&
                record["sample_count"].is_a?(Integer) && record["sample_count"] >= 0 &&
                record["socket_count"].is_a?(Integer) &&
                record["socket_count"].between?(0, NetworkCapture::SOCKET_LIMIT) &&
                sockets.is_a?(Array) && sockets.length == record["socket_count"] &&
                sockets.all? do |row|
                  row.is_a?(Hash) &&
                    row.keys.sort == %w[protocol remote state] &&
                    row.values.all? { |value|
                      value.is_a?(String) && value.bytesize <= 128
                    }
                end
        fail_containment!("network observation types are invalid") unless valid
      end

      def decode_failure(failure)
        exact_keys!(failure, %w[detail phase reason], "failure frame")
        unless %w[detail phase reason].all? do |key|
          failure[key].is_a?(String) && !failure[key].empty? &&
            failure[key].bytesize <= @detail_limit
        end
          fail_containment!("failure frame types are invalid")
        end
        Failure.new(
          phase: failure.fetch("phase"),
          reason: failure.fetch("reason"),
          detail: failure.fetch("detail")
        )
      end

      def decode_binary!(encoded, label)
        unless encoded.is_a?(String) &&
               encoded.bytesize <= ((@output_limit * 4.0 / 3).ceil + 8)
          fail_containment!("#{label} frame is oversized or has the wrong type")
        end
        decoded = Base64.strict_decode64(encoded)
        fail_containment!("#{label} frame exceeds the output limit") if
          decoded.bytesize > @output_limit
        decoded
      rescue ArgumentError
        fail_containment!("#{label} frame is not strict Base64")
      end

      def exact_keys!(value, expected, label)
        unless value.is_a?(Hash) && value.keys.sort == expected.sort
          fail_containment!("#{label} fields are invalid")
        end
      end

      def nullable_nonnegative_integer?(value)
        value.nil? || (value.is_a?(Integer) && value >= 0)
      end

      def boolean?(value)
        value.instance_of?(TrueClass) || value.instance_of?(FalseClass)
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
