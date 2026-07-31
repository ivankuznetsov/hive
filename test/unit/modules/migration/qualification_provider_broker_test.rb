require "test_helper"
require "rbconfig"
require "hive/attempts/process_identity"
require "hive/modules/migration/qualification_provider_broker"

class ModulesMigrationQualificationProviderBrokerTest <
    Minitest::Test
  BROKER =
    Hive::Modules::Migration::QualificationProviderBroker
  PROTOCOL =
    Hive::Modules::Migration::QualificationProviderProtocol
  TRANSPORT =
    Hive::Modules::Migration::QualificationOpenRouterTransport
  PROCESS_IDENTITY = Hive::Attempts::ProcessIdentity.new

  FakeTransport = Data.define(:content, :calls) do
    def call(prompt:, kind:, timeout_seconds:)
      calls << {
        prompt: prompt,
        kind: kind,
        timeout_seconds: timeout_seconds
      }
      TRANSPORT::Result.new(
        content: content,
        input_tokens: 31,
        output_tokens: 7
      ).freeze
    end
  end

  FailingTransport = Data.define(:reason, :retryable) do
    def call(**)
      raise TRANSPORT::Failure.new(
        reason: reason,
        retryable: retryable
      )
    end
  end

  def test_one_generation_call_writes_canonical_output_and_seals_transcript
    Dir.mktmpdir("provider-broker-test") do |workspace|
      prepare_workspace(workspace)
      calls = []
      broker = build_broker(
        workspace,
        transport:
          FakeTransport.new(
            content: "{ \"findings\" : [] }",
            calls: calls
          )
      )
      binding = broker.binding
      broker.arm!(current_identity)
      request = request_for(binding)

      response = round_trip(binding, request)
      transcript = broker.seal!

      assert_predicate response, :ok?
      assert_equal 1, calls.length
      assert_equal(
        "{\"findings\":[]}\n",
        File.binread(
          File.join(
            workspace,
            "cases/case-one",
            request.output_ref
          )
        )
      )
      assert_equal 1, transcript.fetch("call_count")
      assert_nil transcript.fetch("failure")
      assert_equal(
        response.sha256,
        transcript.dig("calls", 0, "response_sha256")
      )
      refute_includes(
        PROTOCOL.canonical(transcript),
        "review this private fixture"
      )
      refute_includes(
        PROTOCOL.canonical(transcript),
        "provider-token"
      )
      refute File.exist?(binding.host_root)
    end
  end

  def test_replay_exhausts_one_call_budget_without_second_provider_call
    Dir.mktmpdir("provider-broker-test") do |workspace|
      prepare_workspace(workspace)
      calls = []
      broker = build_broker(
        workspace,
        transport:
          FakeTransport.new(
            content: '{"findings":[]}',
            calls: calls
          )
      )
      binding = broker.binding
      broker.arm!(current_identity)
      request = request_for(binding)

      assert_predicate round_trip(binding, request), :ok?
      replay = round_trip(binding, request)
      transcript = broker.seal!

      refute_predicate replay, :ok?
      assert_equal "session_budget_exhausted", replay.reason
      assert_equal 1, calls.length
      assert_equal 1, transcript.fetch("call_count")
      assert_equal(
        "session_budget_exhausted",
        transcript.dig("failure", "reason")
      )
    end
  end

  def test_provider_failure_is_closed_retryable_evidence
    Dir.mktmpdir("provider-broker-test") do |workspace|
      prepare_workspace(workspace)
      broker = build_broker(
        workspace,
        transport:
          FailingTransport.new(
            reason: "provider_rate_limited",
            retryable: true
          )
      )
      binding = broker.binding
      broker.arm!(current_identity)

      response = round_trip(binding, request_for(binding))
      transcript = broker.seal!

      refute_predicate response, :ok?
      assert_equal "provider_rate_limited", response.reason
      assert_equal 0, transcript.fetch("call_count")
      assert_equal true,
                   transcript.dig("failure", "retryable")
      assert_equal "provider_rate_limited",
                   transcript.dig("failure", "reason")
    end
  end

  def test_seal_failure_still_removes_the_capability_root
    Dir.mktmpdir("provider-broker-test") do |workspace|
      prepare_workspace(workspace)
      broker = build_broker(
        workspace,
        transport:
          FakeTransport.new(
            content: '{"findings":[]}',
            calls: []
          )
      )
      binding = broker.binding
      broker.arm!(current_identity)
      request = request_for(binding)
      assert_predicate round_trip(binding, request), :ok?
      File.binwrite(
        File.join(
          workspace,
          "cases/case-one",
          request.output_ref
        ),
        "{\"findings\":[{}]}\n"
      )

      error = assert_raises(BROKER::Failure) do
        broker.seal!
      end

      assert_equal "session_protocol_violation", error.reason
      assert_predicate broker, :sealed?
      refute File.exist?(binding.host_root)
    end
  end

  def test_unrelated_process_tree_is_rejected_before_transport
    Dir.mktmpdir("provider-broker-test") do |workspace|
      prepare_workspace(workspace)
      calls = []
      broker = build_broker(
        workspace,
        transport:
          FakeTransport.new(
            content: '{"findings":[]}',
            calls: calls
          )
      )
      binding = broker.binding
      unrelated = spawn(RbConfig.ruby, "-e", "sleep 5")
      broker.arm!(PROCESS_IDENTITY.capture(unrelated))

      socket = UNIXSocket.new(
        File.join(binding.host_root, BROKER::SOCKET_NAME)
      )
      request = request_for(binding)
      begin
        PROTOCOL.write_frame(
          socket, PROTOCOL.canonical(request.to_h)
        )
        socket.shutdown(Socket::SHUT_WR)
        bytes = PROTOCOL.read_frame(socket)
        response = PROTOCOL.load_response(
          bytes,
          expected_request_id: request.request_id
        )
        assert_equal "session_protocol_violation",
                     response.reason
      rescue Hive::ConfigError, Errno::ECONNRESET,
             Errno::EPIPE
        # A peer rejected before request parsing has no request id to echo.
      ensure
        socket.close unless socket.closed?
      end
      transcript = broker.seal!

      assert_empty calls
      assert_equal(
        "session_protocol_violation",
        transcript.dig("failure", "reason")
      )
    ensure
      Process.kill("TERM", unrelated) if unrelated
      Process.wait(unrelated) if unrelated
    end
  end

  private

  def prepare_workspace(workspace)
    File.chmod(0o700, workspace)
    FileUtils.mkdir_p(
      File.join(workspace, "cases/case-one"),
      mode: 0o700
    )
    File.chmod(
      0o700,
      File.join(workspace, "cases")
    )
    File.chmod(
      0o700,
      File.join(workspace, "cases/case-one")
    )
  end

  def current_identity
    PROCESS_IDENTITY.capture(Process.pid)
  end

  def build_broker(workspace, transport:)
    BROKER.new(
      workspace: workspace,
      run_id: "patrol-#{"a" * 64}",
      lane: "installed",
      case_id: "case-one",
      generation: 1,
      scenario_request_sha256: "b" * 64,
      deadline:
        Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5,
      api_key: "provider-token",
      transport: transport
    )
  end

  def request_for(binding)
    PROTOCOL.build_request(
      session: binding.session,
      case_id: binding.case_id,
      generation: binding.generation,
      scenario_request_sha256:
        binding.scenario_request_sha256,
      kind: "ordinary_findings",
      prompt: "review this private fixture",
      context_refs: [],
      output_ref:
        "sandbox/repository/.hive-state/patrol/run/findings.json"
    )
  end

  def round_trip(binding, request)
    socket = UNIXSocket.new(
      File.join(binding.host_root, BROKER::SOCKET_NAME)
    )
    PROTOCOL.write_frame(
      socket, PROTOCOL.canonical(request.to_h)
    )
    socket.shutdown(Socket::SHUT_WR)
    PROTOCOL.load_response(
      PROTOCOL.read_frame(socket),
      expected_request_id: request.request_id
    )
  ensure
    socket&.close unless socket&.closed?
  end
end
