require_relative "../../test_helper"
require "json"
require "json_schemer"
require "pathname"
require "hive/provider_routing/policy_store"

class ProviderRoutingPolicyStoreTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir("provider-routing-policy-store")
    @root = File.join(@tmp, "routing-policies", "v1")
    @store = Hive::ProviderRouting::PolicyStore.new(root: @root)
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def test_explicit_policy_round_trips_as_a_complete_owner_private_snapshot
    candidate = policy(model: "gpt-5.6-sol")

    stored = @store.fetch_or_store(
      ownership_generation: ownership_generation,
      subject: subject,
      policy: candidate
    )
    fetched = Hive::ProviderRouting::PolicyStore.new(root: @root).fetch(
      ownership_generation: ownership_generation,
      subject: subject,
      policy: candidate
    )

    assert_equal candidate.to_h, stored.to_h
    assert_equal candidate.to_h, fetched.to_h

    payload = JSON.parse(File.binread(policy_path))
    assert schema.valid?(payload), schema.validate(payload).to_a.inspect
    assert_equal "hive-routing-policy", payload.fetch("schema")
    assert_equal ownership_generation, payload.fetch("ownership_generation")
    assert_equal subject, payload.fetch("subject")
    assert_equal candidate.to_h, payload.fetch("policy")
    assert_equal "team-a", payload.dig("policy", "accounts", "codex-primary", "launch_binding")
    refute_match(/credential|api[_-]?key|access[_-]?token|secret-canary/i, JSON.generate(payload))

    state_directories.each do |path|
      assert_equal 0o700, File.stat(path).mode & 0o777, path
    end
    state_files.each do |path|
      assert_equal 0o600, File.stat(path).mode & 0o777, path
    end
  end

  def test_same_point_is_first_writer_wins_while_a_new_generation_can_change
    first = policy(model: "gpt-5.6-sol")
    changed = policy(model: "gpt-5.6-terra")

    winner = @store.fetch_or_store(
      ownership_generation: ownership_generation,
      subject: subject,
      policy: first
    )
    replay = @store.fetch_or_store(
      ownership_generation: ownership_generation,
      subject: subject,
      policy: changed
    )
    next_generation = @store.fetch_or_store(
      ownership_generation: "opaque-owner:v8",
      subject: subject,
      policy: changed
    )

    assert_equal first.digest, winner.digest
    assert_equal first.digest, replay.digest
    assert_equal changed.digest, next_generation.digest
    assert_equal 2, policy_paths.length
  end

  def test_concurrent_writers_converge_on_one_immutable_policy
    candidates = [ policy(model: "gpt-5.6-sol"), policy(model: "gpt-5.6-terra") ]
    gate = Queue.new
    writers = 8.times.map do |index|
      Thread.new do
        gate.pop
        @store.fetch_or_store(
          ownership_generation: ownership_generation,
          subject: subject,
          policy: candidates.fetch(index % candidates.length)
        ).digest
      end
    end
    8.times { gate << true }
    returned = writers.map(&:value)

    assert_equal 1, returned.uniq.length
    assert_includes candidates.map(&:digest), returned.first
    assert_equal returned.first, @store.fetch(
      ownership_generation: ownership_generation,
      subject: subject,
      policy: candidates.first
    ).digest
    assert_equal 1, policy_paths.length
  end

  def test_digest_covered_change_or_secret_shaped_field_fails_closed_without_overwrite
    original = policy(model: "gpt-5.6-sol")
    changed = policy(model: "gpt-5.6-terra")
    @store.fetch_or_store(
      ownership_generation: ownership_generation,
      subject: subject,
      policy: original
    )
    path = policy_path
    payload = JSON.parse(File.binread(path))

    payload.dig("policy", "accounts", "codex-primary")["max_concurrent"] = 3
    assert schema.valid?(payload), schema.validate(payload).to_a.inspect
    File.binwrite(path, JSON.generate(payload) + "\n")
    bytes = File.binread(path)
    assert_raises(Hive::ProviderRouting::PolicyStore::InvalidSnapshot) do
      @store.fetch_or_store(
        ownership_generation: ownership_generation,
        subject: subject,
        policy: changed
      )
    end
    assert_equal bytes, File.binread(path)

    payload = snapshot_payload(original)
    payload.dig("policy", "accounts", "codex-primary")["credential"] = "secret-canary"
    File.binwrite(path, JSON.generate(payload) + "\n")
    bytes = File.binread(path)
    refute schema.valid?(payload)
    assert_raises(Hive::ProviderRouting::PolicyStore::InvalidSnapshot) do
      @store.fetch(
        ownership_generation: ownership_generation,
        subject: subject,
        policy: original
      )
    end
    assert_equal bytes, File.binread(path)
  end

  def test_embedded_key_and_strict_subject_are_validated_before_use
    invalid_subject = subject.merge("credential" => "secret-canary")
    assert_raises(Hive::ProviderRouting::PolicyStore::InvalidSnapshot) do
      @store.fetch_or_store(
        ownership_generation: ownership_generation,
        subject: invalid_subject,
        policy: policy(model: "gpt-5.6-sol")
      )
    end
    refute File.exist?(@root)

    candidate = policy(model: "gpt-5.6-sol")
    @store.fetch_or_store(
      ownership_generation: ownership_generation,
      subject: subject,
      policy: candidate
    )
    path = policy_path
    payload = JSON.parse(File.binread(path))
    payload["ownership_generation"] = "other-owner"
    File.binwrite(path, JSON.generate(payload) + "\n")

    assert_raises(Hive::ProviderRouting::PolicyStore::InvalidSnapshot) do
      @store.fetch(
        ownership_generation: ownership_generation,
        subject: subject,
        policy: candidate
      )
    end
  end

  def test_module_hook_subject_shape_is_supported_but_remains_closed
    module_subject = {
      "kind" => "module_hook",
      "project_id" => "project-1",
      "module" => "patrol",
      "hook" => "task-completed",
      "event_id" => "event-1",
      "occurrence_id" => "occurrence-1",
      "event_name" => "task.completed",
      "module_generation" => "module-generation-1",
      "configuration_digest" => "a" * 64,
      "grant_digest" => "b" * 64
    }
    candidate = policy(model: "gpt-5.6-sol")

    stored = @store.fetch_or_store(
      ownership_generation: "module-owner-1",
      subject: module_subject,
      policy: candidate
    )

    assert_equal candidate.digest, stored.digest
    assert_raises(Hive::ProviderRouting::PolicyStore::InvalidSnapshot) do
      @store.fetch_or_store(
        ownership_generation: "module-owner-2",
        subject: module_subject.merge("future" => true),
        policy: candidate
      )
    end
  end

  def test_legacy_policy_bypasses_key_validation_and_all_storage_io
    root = File.join(@tmp, "legacy-must-not-exist")
    store = Hive::ProviderRouting::PolicyStore.new(root: root)
    legacy = Hive::ProviderRouting::Policy.legacy(stage: "execute")

    assert_same legacy, store.fetch_or_store(
      ownership_generation: nil,
      subject: { "kind" => "invalid" },
      policy: legacy
    )
    assert_same legacy, store.fetch(
      ownership_generation: nil,
      subject: { "kind" => "invalid" },
      policy: legacy
    )
    refute File.exist?(root)
  end

  def test_schema_rejects_legacy_unknown_and_incomplete_policy_shapes
    candidate = policy(model: "gpt-5.6-sol")
    payload = snapshot_payload(candidate)

    assert schema.valid?(payload), schema.validate(payload).to_a.inspect
    refute schema.valid?(payload.merge("stdout" => "secret-canary"))
    refute schema.valid?(payload.merge("policy" => payload.fetch("policy").merge("mode" => "legacy")))
    refute schema.valid?(
      payload.merge(
        "policy" => payload.fetch("policy").merge(
          "accounts" => {
            "codex-primary" => {
              "adapter" => "codex",
              "launch_binding" => "team-a",
              "max_concurrent" => 2
            }
          }
        )
      )
    )
  end

  private

  def ownership_generation
    "opaque-owner:v7/alpha"
  end

  def subject
    {
      "kind" => "task_stage",
      "task_id" => 42,
      "task_slug" => "durable-route-task",
      "intended_stage" => "4-execute"
    }
  end

  def policy(model:)
    route = Hive::ProviderRouting::Route.new(
      id: "codex-primary/#{model}",
      account: "codex-primary",
      adapter: "codex",
      launch_binding: "team-a",
      model: model,
      effort: "high",
      order: 0,
      capabilities: {
        "context" => "large",
        "quality" => "high",
        "tools" => %w[shell filesystem],
        "permissions" => %w[read write]
      }
    )
    Hive::ProviderRouting::Policy.explicit(
      stage: "execute",
      routes: [ route ],
      requirements: Hive::ProviderRouting::Requirements.new(
        context: "large", quality: "high", tools: [ "filesystem" ], permissions: [ "read" ]
      ),
      pin: Hive::ProviderRouting::Pin.new(provider: "codex-primary"),
      account_policy: {
        "codex-primary" => {
          "adapter" => "codex",
          "launch_binding" => "team-a",
          "models" => %w[gpt-5.6-sol gpt-5.6-terra],
          "max_concurrent" => 2,
          "cooldown_sec" => Hive::ProviderRouting::DEFAULT_COOLDOWN_SEC
        }
      }
    )
  end

  def snapshot_payload(candidate)
    {
      "schema" => "hive-routing-policy",
      "schema_version" => 1,
      "ownership_generation" => ownership_generation,
      "subject" => subject,
      "policy" => Hive::ProviderRouting.deep_copy(candidate.to_h)
    }
  end

  def schema
    @schema ||= JSONSchemer.schema(
      Pathname(File.join(Hive::Schemas.schema_dir, "hive-routing-policy.v1.json"))
    )
  end

  def policy_paths
    Dir.glob(File.join(@root, "**", "*.json"))
  end

  def policy_path
    policy_paths.fetch(0)
  end

  def state_directories
    [ @root, *Dir.glob(File.join(@root, "**", "*")) ].select { |path| File.directory?(path) }
  end

  def state_files
    Dir.glob(File.join(@root, "**", "*"), File::FNM_DOTMATCH).select { |path| File.file?(path) }
  end
end
