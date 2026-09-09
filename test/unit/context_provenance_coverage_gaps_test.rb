require "test_helper"
require "hive/context_provenance"

class ContextProvenanceCoverageGapsTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 8, 14, 12)
  TaskStub = Struct.new(
    :id, :slug, :folder, :project_root, :project_name, :workflow,
    keyword_init: true
  )
  ContextStub = Struct.new(
    :attempt_id, :task_generation, :ownership_generation, :project,
    :task_slug, :intended_stage, keyword_init: true
  )
  AttemptStub = Struct.new(:attempt_id, :data, keyword_init: true) do
    def [](key) = data[key]
    def task_input_epoch = data.fetch("task_input_epoch")
    def ownership_generation = data.fetch("ownership_generation")
  end

  def test_wiki_snapshot_covers_dirty_tree_bounds_and_descriptor_failures
    with_tmp_dir do |root|
      wiki = File.join(root, "wiki")
      FileUtils.mkdir_p(File.join(wiki, "nested"))
      File.write(File.join(wiki, "index.md"), "# Index\n")
      File.write(File.join(wiki, "nested", "page.md"), "page\n")

      snapshot = Hive::ContextProvenance::WikiSnapshot.capture(root)
      assert_equal "current", snapshot.fetch("state")
      assert_equal "bounded_digest", snapshot.fetch("identity_kind")
      assert_equal 2, snapshot.fetch("file_count")

      capped = Hive::ContextProvenance::WikiSnapshot.digest_tree(
        wiki, max_files: 0, max_bytes: 100
      )
      assert_equal "partial", capped.fetch("state")
      assert capped.fetch("truncated")

      outside = File.join(root, "outside")
      File.write(outside, "outside")
      File.symlink(outside, File.join(wiki, "link"))
      symlinked = Hive::ContextProvenance::WikiSnapshot.digest_tree(
        wiki, max_files: 10, max_bytes: 100
      )
      assert_equal "partial", symlinked.fetch("state")

      entries, truncated = Hive::ContextProvenance::WikiSnapshot.bounded_entries(
        wiki, deadline: Float::INFINITY, max_entries: 0
      )
      assert_empty entries
      assert truncated
      _entries, deadline_truncated = Hive::ContextProvenance::WikiSnapshot.bounded_entries(
        wiki, deadline: 0
      )
      assert deadline_truncated

      path = File.join(wiki, "index.md")
      before = File.lstat(path)
      mismatched = Struct.new(:dev, :ino, :size, :mtime).new(
        before.dev, before.ino + 1, before.size, before.mtime
      )
      assert_raises(IOError) do
        Hive::ContextProvenance::WikiSnapshot.descriptor_read(path, mismatched, 100)
      end
      assert_raises(IOError) do
        Hive::ContextProvenance::WikiSnapshot.descriptor_read(path, before, 0)
      end

      opened = Struct.new(:dev, :ino, :size, :mtime) do
        def file? = true
      end.new(before.dev, before.ino, before.size, before.mtime)
      changed = opened.dup
      changed.mtime = before.mtime + 1
      fake_io = Object.new
      stats = [ opened, changed ]
      fake_io.define_singleton_method(:stat) { stats.shift }
      fake_io.define_singleton_method(:read) { |_limit| "# Index\n" }
      replacement = ->(*, &block) { block.call(fake_io) }
      with_replaced_singleton_method(File, :open, replacement) do
        assert_raises(IOError) do
          Hive::ContextProvenance::WikiSnapshot.descriptor_read(path, before, 100)
        end
      end

      assert Hive::ContextProvenance::WikiSnapshot.contained?(root, root)
      refute Hive::ContextProvenance::WikiSnapshot.contained?(
        root, "#{root}-escape"
      )
      assert_equal "detail", Hive::ContextProvenance::WikiSnapshot.diagnostic(
        "code", "detail"
      ).fetch("detail")
    end
  end

  def test_wiki_snapshot_handles_missing_symlink_and_capture_errors
    with_tmp_dir do |root|
      assert_equal "missing", Hive::ContextProvenance::WikiSnapshot.capture(root).fetch("state")
      outside = File.join(root, "outside")
      FileUtils.mkdir_p(outside)
      File.symlink(outside, File.join(root, "wiki"))
      assert_equal "unavailable",
                   Hive::ContextProvenance::WikiSnapshot.capture(root).fetch("state")
    end
    assert_equal "unavailable",
                 Hive::ContextProvenance::WikiSnapshot.capture("/missing/context-root").fetch("state")
  end

  def test_wiki_snapshot_covers_mid_digest_deadline_and_read_failure
    with_tmp_dir do |root|
      wiki = File.join(root, "wiki")
      FileUtils.mkdir_p(wiki)
      path = File.join(wiki, "page.md")
      File.write(path, "page\n")

      entries = ->(*) { [ [ path ], false ] }
      ticks = [ 0.0, 3.0 ]
      clock = ->(*) { ticks.shift || 3.0 }
      with_replaced_singleton_method(
        Hive::ContextProvenance::WikiSnapshot, :bounded_entries, entries
      ) do
        with_replaced_singleton_method(Process, :clock_gettime, clock) do
          snapshot = Hive::ContextProvenance::WikiSnapshot.digest_tree(
            wiki, max_files: 10, max_bytes: 100
          )
          assert_equal "partial", snapshot.fetch("state")
          assert_equal 0, snapshot.fetch("file_count")
        end
      end

      failure = ->(*) { raise IOError, "read failed" }
      with_replaced_singleton_method(
        Hive::ContextProvenance::WikiSnapshot, :descriptor_read, failure
      ) do
        snapshot = Hive::ContextProvenance::WikiSnapshot.digest_tree(
          wiki, max_files: 10, max_bytes: 100
        )
        assert_equal "unavailable", snapshot.fetch("state")
      end
    end
  end

  def test_repository_snapshot_covers_process_deadlines_and_fallbacks
    mod = Hive::ContextProvenance::RepositorySnapshot
    output, status, overflow = mod.capture_command(
      [ RbConfig.ruby, "-e", "print 'ok'" ], timeout_sec: 5, max_bytes: 10
    )
    assert_equal "ok", output
    assert status.success?
    refute overflow

    output, status, overflow = mod.capture_command(
      [ RbConfig.ruby, "-e", "print 'abcdefghij'" ], timeout_sec: 5, max_bytes: 4
    )
    assert_equal "abcd", output
    assert status.nil? || status.success?
    assert overflow

    kills = []
    ticks = [ 0.0, 0.0, 1.0 ]
    with_replaced_singleton_method(mod, :monotonic_now, -> { ticks.shift || 1.0 }) do
      with_replaced_singleton_method(mod, :sleep, ->(*) { }) do
        with_replaced_singleton_method(
          Process, :kill, ->(signal, pid) { kills << [ signal, pid ] }
        ) do
          waitpid = ->(pid, flags = nil) { flags == Process::WNOHANG ? nil : pid }
          with_replaced_singleton_method(Process, :waitpid, waitpid) do
            mod.terminate(123)
          end
        end
      end
    end
    assert_equal [ [ "TERM", -123 ], [ "KILL", -123 ] ], kills

    _output, status, = mod.capture_command(
      [
        RbConfig.ruby, "-e",
        "trap('TERM') {}; STDOUT.sync = true; puts 'ready'; loop { sleep 1 }"
      ], timeout_sec: 0.1, max_bytes: 10
    )
    assert_nil status
    assert_nil mod.terminate(99_999_999)

    with_tmp_dir do |root|
      assert_equal "unavailable", mod.capture(File.join(root, "missing")).fetch("state")
      assert_match(/\Alocal-sha256:/, mod.repository_identity(root, root))
    end
    assert_nil mod.git("/missing/repository", %w[status])
    assert_nil mod.valid_oid("nope")
    assert_nil mod.bounded(nil, 10)
    assert_equal "detail", mod.diagnostic("code", "detail").fetch("detail")
    assert_equal "unavailable", mod.unavailable("IOError").fetch("state")

    failure = ->(*) { raise IOError, "spawn failed" }
    with_replaced_singleton_method(mod, :capture_command, failure) do
      assert_nil mod.git("/tmp/repository", %w[status])
    end
  end

  def test_receipt_validator_covers_rejected_shapes_and_reference_races
    with_fixture do |task, _attempt, context|
      base = agent_receipt(task, context)
      invalid = []
      invalid << base.merge("schema_version" => 2)
      invalid << base.merge("quality" => "observed")
      invalid << base.merge("captured_at" => Object.new)
      invalid << base.merge("captured_at" => "not-a-time")
      invalid.each do |receipt|
        assert_raises(Hive::ContextProvenance::ContextReceipt::InvalidReceipt) do
          Hive::ContextProvenance::ContextReceipt.validate_agent!(
            receipt, task: task, context: context
          )
        end
      end

      validator = Hive::ContextProvenance::ContextReceipt
      assert_raises(validator::InvalidReceipt) do
        validator.exact_keys!({}, [ "required" ], "object")
      end
      assert_raises(validator::InvalidReceipt) { validator.identifier("!", "identifier") }
      assert_raises(validator::InvalidReceipt) { validator.oid("xyz", "oid") }
      assert_raises(validator::InvalidReceipt) do
        validator.validate_reference!("missing.md", project_root: task.project_root)
      end
      assert_raises(validator::InvalidReceipt) do
        validator.validate_reference!("wiki", project_root: task.project_root)
      end

      path = File.join(task.project_root, "wiki", "index.md")
      original_stat = File.method(:stat)
      replacement = lambda do |candidate, *args|
        stat = original_stat.call(candidate, *args)
        candidate == path ? Struct.new(:dev, :ino).new(stat.dev, stat.ino + 1) : stat
      end
      with_replaced_singleton_method(File, :stat, replacement) do
        assert_raises(validator::InvalidReceipt) do
          validator.validate_reference!("wiki/index.md", project_root: task.project_root)
        end
      end
    end
  end

  def test_context_provenance_covers_advisory_failure_and_filesystem_guards
    with_fixture do |task, attempt, context|
      capture_failure = ->(*) { raise IOError, "capture failed" }
      with_replaced_singleton_method(
        Hive::ContextProvenance::RepositorySnapshot, :capture, capture_failure
      ) do
        receipt = Hive::ContextProvenance.capture_launch(
          task: task, attempt: attempt, clock: -> { NOW }
        )
        assert_equal "unavailable", receipt.dig("repository", "state")
      end

      oversized = ->(*) { "x" * (Hive::ContextProvenance::MAX_PROMPT_APPENDIX_BYTES + 1) }
      with_replaced_singleton_method(
        Hive::ContextProvenance, :prompt_appendix, oversized
      ) do
        assert_equal "prompt", Hive::ContextProvenance.decorate_prompt(
          task: task, prompt: "prompt", context: context
        )
      end

      assert_equal :unavailable, Hive::ContextProvenance.promote_agent_receipt(
        task: task, context: nil
      ).status
      assert_equal :missing, Hive::ContextProvenance.promote_agent_receipt(
        task: task, context: context
      ).status

      write_candidate(task, context, "{")
      assert_equal "invalid_json", Hive::ContextProvenance.promote_agent_receipt(
        task: task, context: context
      ).reason
      File.delete(candidate_path(task, context))

      final = agent_receipt(task, context)
      Hive::ContextProvenance.write_immutable(
        task.folder, Hive::ContextProvenance.promoted_reference(context.attempt_id), final
      )
      contender = agent_receipt(task, context)
      contender["selection"]["rationale"] = "different"
      write_candidate(task, context, contender)
      assert_equal "receipt_conflict", Hive::ContextProvenance.promote_agent_receipt(
        task: task, context: context
      ).reason

      reference = Hive::ContextProvenance.promoted_reference("second")
      receipt = { "array" => [ { "b" => 2, "a" => 1 } ] }
      Hive::ContextProvenance.write_immutable(task.folder, reference, receipt)
      assert_equal receipt,
                   Hive::ContextProvenance.write_immutable(task.folder, reference, receipt)
      assert_raises(Hive::ContextProvenance::UnsafeReceipt) do
        Hive::ContextProvenance.write_immutable(
          task.folder, reference, { "array" => [ { "a" => 2 } ] }
        )
      end
      assert_nil Hive::ContextProvenance.remove_candidate(
        task.folder, Hive::ContextProvenance.candidate_reference("absent")
      )
      assert_raises(Hive::ContextProvenance::UnsafeReceipt) do
        Hive::ContextProvenance.contained_receipt_path(task.folder, "../escape")
      end
      assert_raises(Hive::ContextProvenance::UnsafeReceipt) do
        Hive::ContextProvenance.safe_attempt_id("bad/id")
      end
      assert_nil Hive::ContextProvenance.fsync_directory("/missing/context-directory")

      legacy_attempt = Struct.new(:attempt_id, :data) do
        def [](key) = data[key]
      end.new("legacy", attempt.data)
      generation = Struct.new(:task_generation, :ownership_generation).new(9, "owner-9")
      binding = Hive::ContextProvenance.binding_for(
        task, legacy_attempt, generation: generation
      )
      assert_equal 9, binding.fetch("task_generation")
      assert_equal "owner-9", binding.fetch("ownership_generation")

      exploding = ->(*) { raise "unexpected validator failure" }
      with_replaced_singleton_method(
        Hive::ContextProvenance::ContextReceipt, :validate_agent!, exploding
      ) do
        File.delete(candidate_path(task, context)) if File.exist?(candidate_path(task, context))
        File.delete(File.join(task.folder, Hive::ContextProvenance.promoted_reference(context.attempt_id)))
        write_candidate(task, context, agent_receipt(task, context))
        result = Hive::ContextProvenance.promote_agent_receipt(task: task, context: context)
        assert_equal "receipt_promotion_failed", result.reason
      end
    end
  end

  def test_context_provenance_covers_default_clocks_partial_fallback_and_descriptor_races
    with_fixture do |task, attempt, context|
      receipt = Hive::ContextProvenance.capture_launch(task: task, attempt: attempt)
      assert_equal "controller_launch", receipt.fetch("kind")

      FileUtils.rm_rf(File.join(task.folder, "context-receipts"))
      broken_task = task.dup
      broken_task.folder = File.join(task.folder, "missing", "task")
      partial = Hive::ContextProvenance.partial_launch_receipt(
        task: broken_task, attempt: attempt, generation: nil,
        captured_at: NOW.iso8601(6), error: IOError.new("failed")
      )
      assert_equal "unavailable", partial.dig("repository", "state")

      FileUtils.mkdir_p(task.folder)
      reference = Hive::ContextProvenance.promoted_reference("race")
      Hive::ContextProvenance.write_immutable(task.folder, reference, { "ok" => true })
      path = File.join(task.folder, reference)
      real = File.lstat(path)
      mismatched = Struct.new(:dev, :ino, :size, :mtime) do
        def file? = true
      end.new(real.dev, real.ino + 1, real.size, real.mtime)
      fake_io = Object.new
      fake_io.define_singleton_method(:stat) { mismatched }
      replacement = ->(*, &block) { block.call(fake_io) }
      with_replaced_singleton_method(File, :open, replacement) do
        assert_raises(Hive::ContextProvenance::UnsafeReceipt) do
          Hive::ContextProvenance.read_json_nofollow(
            task.folder, reference, max_bytes: 100
          )
        end
      end

      opened = Struct.new(:dev, :ino, :size, :mtime) do
        def file? = true
      end.new(real.dev, real.ino, real.size, real.mtime)
      changed = opened.dup
      changed.size += 1
      fake_io = Object.new
      stats = [ opened, changed ]
      fake_io.define_singleton_method(:stat) { stats.shift }
      fake_io.define_singleton_method(:read) { |_limit| "{\"ok\":true}" }
      replacement = ->(*, &block) { block.call(fake_io) }
      with_replaced_singleton_method(File, :open, replacement) do
        assert_raises(Hive::ContextProvenance::UnsafeReceipt) do
          Hive::ContextProvenance.read_json_nofollow(
            task.folder, reference, max_bytes: 100
          )
        end
      end

      symlink_ref = Hive::ContextProvenance.promoted_reference("symlink-race")
      symlink_path = File.join(task.folder, symlink_ref)
      File.symlink(path, symlink_path)
      original_lstat = File.method(:lstat)
      lstat = ->(candidate) { candidate == symlink_path ? real : original_lstat.call(candidate) }
      with_replaced_singleton_method(File, :lstat, lstat) do
        assert_raises(Hive::ContextProvenance::UnsafeReceipt) do
          Hive::ContextProvenance.read_json_nofollow(
            task.folder, symlink_ref, max_bytes: 100
          )
        end
      end

      receipts = File.join(task.folder, "context-receipts")
      original_realpath = File.method(:realpath)
      shifted = lambda do |candidate|
        candidate == receipts ? "#{receipts}-elsewhere" : original_realpath.call(candidate)
      end
      with_replaced_singleton_method(File, :realpath, shifted) do
        assert_raises(Hive::ContextProvenance::UnsafeReceipt) do
          Hive::ContextProvenance.receipt_directory(task.folder)
        end
      end

      File.delete(path)
      candidate = agent_receipt(task, context)
      write_candidate(task, context, candidate)
      activity_factory = lambda do |_task, _context, clock:|
        clock.call
        nil
      end
      with_replaced_singleton_method(
        Hive::ContextProvenance, :activity_for_context, activity_factory
      ) do
        assert_equal :promoted, Hive::ContextProvenance.promote_agent_receipt(
          task: task, context: context
        ).status
      end
    end
  end

  def test_activity_for_context_delegates_to_the_shared_task_activity_boundary
    with_fixture do |task, _attempt, context|
      sentinel = Object.new
      observed = nil
      factory = lambda do |received_task, context:, clock:|
        observed = [ received_task, context, clock.call ]
        sentinel
      end

      result = with_replaced_singleton_method(Hive::TaskActivity, :for_context, factory) do
        Hive::ContextProvenance.activity_for_context(task, context, clock: -> { NOW })
      end

      assert_same sentinel, result
      assert_equal [ task, context, NOW ], observed
    end
  end

  private

  def with_fixture
    with_tmp_dir do |root|
      project = File.join(root, "demo")
      folder = File.join(project, ".hive-state", "stages", "4-execute", "task")
      FileUtils.mkdir_p(File.join(project, "wiki"))
      FileUtils.mkdir_p(folder)
      File.write(File.join(project, "wiki", "index.md"), "# Wiki\n")
      task = TaskStub.new(
        id: 7, slug: "task", folder: folder, project_root: project,
        project_name: "demo", workflow: :coding
      )
      attempt = AttemptStub.new(
        attempt_id: "attempt-1",
        data: {
          "task_id" => 7, "project" => "demo", "task_slug" => "task",
          "intended_stage" => "4-execute", "task_input_epoch" => 3,
          "ownership_generation" => "owner-3"
        }
      )
      context = ContextStub.new(
        attempt_id: "attempt-1", task_generation: 3,
        ownership_generation: "owner-3", project: "demo",
        task_slug: "task", intended_stage: "4-execute"
      )
      yield task, attempt, context
    end
  end

  def agent_receipt(task, context)
    {
      "schema" => "hive-context-receipt", "schema_version" => 1,
      "kind" => "agent_selection",
      "binding" => {
        "project" => task.project_name, "task_slug" => task.slug,
        "task_id" => task.id.to_s, "stage" => context.intended_stage,
        "attempt_id" => context.attempt_id,
        "task_generation" => context.task_generation,
        "ownership_generation" => context.ownership_generation
      },
      "captured_at" => NOW.iso8601(6), "quality" => "agent_asserted_used",
      "repository" => nil, "wiki" => nil,
      "selection" => {
        "references" => [], "queries" => [], "rationale" => "selected context"
      },
      "diagnostics" => []
    }
  end

  def candidate_path(task, context)
    File.join(task.folder, Hive::ContextProvenance.candidate_reference(context.attempt_id))
  end

  def write_candidate(task, context, content)
    FileUtils.mkdir_p(File.dirname(candidate_path(task, context)))
    body = content.is_a?(String) ? content : JSON.generate(content)
    File.write(candidate_path(task, context), body)
  end
end
