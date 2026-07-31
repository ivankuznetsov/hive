require "test_helper"
require "digest"
require "fileutils"
require "hive/modules/migration/qualification_checkpoint_evidence"

class QualificationCheckpointEvidenceTest < Minitest::Test
  include HiveTestHelper

  EVIDENCE =
    Hive::Modules::Migration::QualificationCheckpointEvidence

  def test_captures_bounded_immutable_state_and_absent_roots
    with_sandbox do |sandbox, roots|
      write_state(roots.fetch("state"), "record.json", "{\"step\":1}\n")

      snapshot = EVIDENCE.new.capture(
        sandbox_root: sandbox,
        roots: roots
      )

      assert_instance_of EVIDENCE::Snapshot, snapshot
      assert_match(/\A[0-9a-f]{64}\z/, snapshot.sha256)
      assert_equal 1, snapshot.file_count
      assert_equal 2, snapshot.root_count
      assert_equal(
        "absent",
        snapshot.roots
          .find { |root| root.fetch("name") == "attempts" }
          .fetch("state")
      )
      assert snapshot.frozen?
      assert snapshot.to_h.frozen?
      assert snapshot.roots.frozen?
      assert snapshot.roots.all?(&:frozen?)

      first_digest = snapshot.sha256
      write_state(roots.fetch("state"), "record.json", "{\"step\":2}\n")
      changed = EVIDENCE.new.capture(
        sandbox_root: sandbox,
        roots: roots
      )

      refute_equal first_digest, changed.sha256
    end
  end

  def test_snapshot_round_trip_rejects_tampering
    with_sandbox do |sandbox, roots|
      write_state(roots.fetch("state"), "record.json", "{}\n")
      snapshot = EVIDENCE.new.capture(
        sandbox_root: sandbox,
        roots: roots
      )

      loaded = EVIDENCE::Snapshot.from_h(snapshot.to_h)
      assert_equal snapshot.to_h, loaded.to_h

      tampered = mutable(snapshot.to_h)
      tampered["roots"].fetch(1).fetch("entries").fetch(1)["sha256"] =
        "f" * 64

      assert_malformed { EVIDENCE::Snapshot.from_h(tampered) }
    end
  end

  def test_canonicalizes_nested_entries_independently_of_walk_order
    with_sandbox do |sandbox, roots|
      state = roots.fetch("state")
      FileUtils.mkdir_p(File.join(state, "a"), mode: 0o700)
      write_state(state, "a/z.json", "{}\n")
      write_state(state, "a.txt", "sibling\n")

      snapshot = EVIDENCE.new.capture(
        sandbox_root: sandbox,
        roots: roots
      )
      entries =
        snapshot.roots
          .find { |root| root.fetch("name") == "state" }
          .fetch("entries")
      paths = entries.map { |entry| entry.fetch("path") }

      assert_equal [ ".", "a", "a.txt", "a/z.json" ], paths
      assert_equal(
        snapshot.to_h,
        EVIDENCE::Snapshot.from_h(snapshot.to_h).to_h
      )
    end
  end

  def test_binds_checkpoint_facts_to_the_exact_snapshot
    with_sandbox do |sandbox, roots|
      write_state(roots.fetch("state"), "record.json", "{}\n")
      snapshot = EVIDENCE.new.capture(
        sandbox_root: sandbox,
        roots: roots
      )
      checkpoint = EVIDENCE.new.bind(
        checkpoint: "after_module_decision",
        snapshot: snapshot,
        facts: {
          "decision_count" => 1,
          "decision_ids" => [ "dec-1" ]
        }
      )

      assert_equal "after_module_decision", checkpoint.checkpoint
      assert_equal snapshot.sha256, checkpoint.state_sha256
      assert checkpoint.frozen?
      assert checkpoint.to_h.frozen?
      assert_equal(
        checkpoint.to_h,
        EVIDENCE::Checkpoint.from_h(checkpoint.to_h).to_h
      )

      tampered = mutable(checkpoint.to_h)
      tampered["facts"]["decision_count"] = 2
      assert_malformed { EVIDENCE::Checkpoint.from_h(tampered) }
    end
  end

  def test_rejects_checkpoint_bound_to_a_different_snapshot
    with_sandbox do |sandbox, roots|
      write_state(roots.fetch("state"), "record.json", "{\"step\":1}\n")
      first = EVIDENCE.new.capture(
        sandbox_root: sandbox,
        roots: roots
      )
      checkpoint = EVIDENCE.new.bind(
        checkpoint: "after_effect_intent",
        snapshot: first,
        facts: { "intent_count" => 1 }
      )
      write_state(roots.fetch("state"), "record.json", "{\"step\":2}\n")
      second = EVIDENCE.new.capture(
        sandbox_root: sandbox,
        roots: roots
      )

      assert_malformed do
        EVIDENCE.new.verify!(
          checkpoint,
          checkpoint: "after_effect_intent",
          snapshot: second
        )
      end
    end
  end

  def test_rejects_unsafe_or_unbounded_state
    with_sandbox do |sandbox, roots|
      state = roots.fetch("state")
      write_state(state, "record.json", "{}\n")

      File.symlink("record.json", File.join(state, "alias.json"))
      assert_malformed do
        EVIDENCE.new.capture(sandbox_root: sandbox, roots: roots)
      end
      File.unlink(File.join(state, "alias.json"))

      File.chmod(0o666, File.join(state, "record.json"))
      assert_malformed do
        EVIDENCE.new.capture(sandbox_root: sandbox, roots: roots)
      end
      File.chmod(0o600, File.join(state, "record.json"))

      File.link(
        File.join(state, "record.json"),
        File.join(state, "linked.json")
      )
      assert_malformed do
        EVIDENCE.new.capture(sandbox_root: sandbox, roots: roots)
      end
      File.unlink(File.join(state, "linked.json"))

      File.binwrite(
        File.join(state, "large.bin"),
        "x" * (EVIDENCE::MAX_FILE_BYTES + 1)
      )
      assert_malformed do
        EVIDENCE.new.capture(sandbox_root: sandbox, roots: roots)
      end
    end
  end

  def test_rejects_roots_outside_the_owned_sandbox
    with_sandbox do |sandbox, roots|
      roots["outside"] = File.dirname(sandbox)

      assert_malformed do
        EVIDENCE.new.capture(sandbox_root: sandbox, roots: roots)
      end
    end
  end

  private

  def with_sandbox
    with_tmp_dir do |directory|
      sandbox = File.join(directory, "sandbox")
      state = File.join(sandbox, "state")
      FileUtils.mkdir_p(state, mode: 0o700)
      roots = {
        "attempts" => File.join(sandbox, "attempts"),
        "state" => state
      }
      yield sandbox, roots
    end
  end

  def write_state(root, name, bytes)
    FileUtils.mkdir_p(root, mode: 0o700)
    path = File.join(root, name)
    File.binwrite(path, bytes)
    File.chmod(0o600, path)
  end

  def mutable(value)
    Marshal.load(Marshal.dump(value))
  end

  def assert_malformed
    error = assert_raises(Hive::ConfigError) { yield }
    assert_equal(
      "patrol qualification checkpoint evidence is malformed",
      error.message
    )
  end
end
