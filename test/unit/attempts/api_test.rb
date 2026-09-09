require "test_helper"
require "hive/attempts/api"

class AttemptsAPITest < Minitest::Test
  include HiveTestHelper

  def test_public_contracts_are_available_at_the_api_boundary
    client_result = Hive::Attempts::ClientResult.new(
      status: :terminal, exit_status: 0, outcome: "succeeded",
      receipt: {}, attempt_id: "attempt-1"
    )
    dispatch_result = Hive::Attempts::DispatchResult.new(
      status: :accepted, attempt: Object.new, receipt: nil,
      attach_descriptor: nil, reason: nil
    )

    assert_equal false, client_result.stdout_emitted?
    assert_equal true, dispatch_result.accepted?
    assert_kind_of Hive::Error, Hive::Attempts::UnsupportedDetachment.new
  end

  def test_dispatch_delegates_foreground_admission
    foreground = Object.new
    call = nil
    foreground.define_singleton_method(:dispatch) do |**attributes|
      call = attributes
      :attached
    end
    api = Hive::Attempts::API.new(foreground: foreground, daemon: Object.new)

    result = api.dispatch(
      task: :task,
      intended_stage: "4-execute",
      argv: %w[hive run task],
      request_id: "request-1",
      provider: "codex",
      interactive: true,
      now: Time.at(0).utc
    )

    assert_equal :attached, result
    assert_equal :task, call.fetch(:task)
    assert_equal "4-execute", call.fetch(:intended_stage)
    assert_equal %w[hive run task], call.fetch(:argv)
    assert_equal "request-1", call.fetch(:request_id)
    assert_equal "codex", call.fetch(:provider)
    assert_equal true, call.fetch(:interactive)
    assert_equal Time.at(0).utc, call.fetch(:now)
  end

  def test_dispatch_request_delegates_daemon_delivery
    daemon = Object.new
    call = nil
    daemon.define_singleton_method(:dispatch_request) do |request, **options|
      call = [ request, options ]
      :accepted
    end
    api = Hive::Attempts::API.new(foreground: Object.new, daemon: daemon)

    result = api.dispatch_request(
      :request, interactive: false, now: Time.at(1).utc, admission_view: :tick,
      replay_semantic_terminal: true
    )

    assert_equal :accepted, result
    assert_equal :request, call.first
    assert_equal false, call.last.fetch(:interactive)
    assert_equal Time.at(1).utc, call.last.fetch(:now)
    assert_equal :tick, call.last.fetch(:admission_view)
    assert_equal true, call.last.fetch(:replay_semantic_terminal)
  end

  def test_dispatch_recovery_delegates_independent_admission
    daemon = Object.new
    call = nil
    daemon.define_singleton_method(:dispatch_recovery) do |**attributes|
      call = attributes
      :accepted
    end
    api = Hive::Attempts::API.new(foreground: Object.new, daemon: daemon)

    result = api.dispatch_recovery(
      task: :task,
      source_attempt: :lost,
      project: "demo",
      argv: %w[hive run task],
      request_id: "request-2",
      provider: "codex",
      admission_view: :tick
    )

    assert_equal :accepted, result
    assert_equal :task, call.fetch(:task)
    assert_equal :lost, call.fetch(:source_attempt)
    assert_equal "demo", call.fetch(:project)
    assert_equal %w[hive run task], call.fetch(:argv)
    assert_equal "request-2", call.fetch(:request_id)
    assert_equal "codex", call.fetch(:provider)
    assert_equal :tick, call.fetch(:admission_view)
  end

  def test_dispatch_module_hook_delegates_daemon_admission
    daemon = Object.new
    call = nil
    daemon.define_singleton_method(:dispatch_module_hook) do |**attributes|
      call = attributes
      :accepted
    end
    api = Hive::Attempts::API.new(foreground: Object.new, daemon: daemon)

    result = api.dispatch_module_hook(
      project_root: "/repo",
      argv: %w[hive __module-hook attempt-1],
      generation: :generation,
      subject: :subject,
      request_id: "request-3",
      provider: "internal",
      interactive: false,
      retry_charge: 2,
      now: Time.at(2).utc
    )

    assert_equal :accepted, result
    assert_equal "/repo", call.fetch(:project_root)
    assert_equal %w[hive __module-hook attempt-1], call.fetch(:argv)
    assert_equal :generation, call.fetch(:generation)
    assert_equal :subject, call.fetch(:subject)
    assert_equal "request-3", call.fetch(:request_id)
    assert_equal "internal", call.fetch(:provider)
    assert_equal false, call.fetch(:interactive)
    refute_includes call, :predecessor_attempt_id
    assert_equal 2, call.fetch(:retry_charge)
    assert_equal Time.at(2).utc, call.fetch(:now)

    assert_raises(ArgumentError) do
      api.dispatch_module_hook(
        project_root: "/repo",
        generation: :generation,
        subject: :subject,
        argv: %w[hive __module-hook attempt-1],
        request_id: "request-4",
        provider: "internal",
        providre: "typo"
      )
    end
  end

  def test_default_adapters_share_the_injected_store
    store = Object.new
    foreground_store = nil
    daemon_store = nil
    foreground = Object.new
    foreground.define_singleton_method(:dispatch) { |**_attributes| :attached }
    daemon = Object.new
    daemon.define_singleton_method(:dispatch_request) { |_request, **_options| :accepted }

    with_replaced_singleton_method(Hive::Attempts::Entrypoint, :new, lambda { |store:|
      foreground_store = store
      foreground
    }) do
      with_replaced_singleton_method(
        Hive::Attempts::ConfiguredDispatcher, :new,
        lambda { |store:|
          daemon_store = store
          daemon
        }
      ) do
        api = Hive::Attempts::API.new(store: store)
        assert_equal :attached,
                     api.dispatch(
                       task: :task, intended_stage: "4-execute",
                       argv: %w[hive run task]
                     )
        assert_equal :accepted, api.dispatch_request(:request)
      end
    end

    assert_same store, foreground_store
    assert_same store, daemon_store
  end

  def test_correlated_log_reader_resolves_sealed_references_through_the_store
    with_tmp_dir do |root|
      store = Struct.new(:root) do
        def sealed_payload_reference(reference) = reference.merge("sealed" => true)
      end.new(root)
      reader = Hive::Attempts::API.new(store: store).correlated_log_reader
      resolver = reader.instance_variable_get(:@reference_resolver)

      assert_equal({ "path" => "log", "sealed" => true }, resolver.call("path" => "log"))
    end
  end
end
