require "test_helper"
require "json"
require "fileutils"
require "tmpdir"
require "hive/bot/dispatch_request_writer"
require "hive/daemon/dispatch_request_queue"

class HiveBotDispatchRequestWriterTest < Minitest::Test
  include HiveTestHelper

  W = Hive::Bot::DispatchRequestWriter
  Q = Hive::Daemon::DispatchRequestQueue

  def test_write_emits_schema_versioned_json_with_required_fields
    Dir.mktmpdir("hive-writer") do |dir|
      request_id = W.write!(
        project: "hive",
        slug: "explore-the-simplest-way-to-260528-2503",
        argv: [ "hive", "run", "explore-the-simplest-way-to-260528-2503", "--json" ],
        chat_id: 123_456_789,
        update_id: 926_850_952,
        trigger: "answer_complete",
        state_home: dir,
        now: Time.utc(2026, 5, 28, 18, 11, 44)
      )

      assert_kind_of String, request_id
      refute_empty request_id

      files = Dir.glob(File.join(Q.directory(state_home: dir), "*.json"))
      assert_equal 1, files.size

      payload = JSON.parse(File.read(files.first))
      assert_equal "hive-dispatch-request", payload["schema"]
      assert_equal 1, payload["schema_version"]
      assert_equal request_id, payload["request_id"]
      assert_equal "2026-05-28T18:11:44.000000Z", payload["created_at"]
      assert_equal "hive", payload["project"]
      assert_equal "explore-the-simplest-way-to-260528-2503", payload["slug"]
      assert_equal [ "hive", "run", "explore-the-simplest-way-to-260528-2503", "--json" ], payload["argv"]
      assert_equal "bot", payload["requestor"]
      assert_equal 123_456_789, payload["chat_id"]
      assert_equal 926_850_952, payload["update_id"]
      assert_equal "answer_complete", payload["trigger"]
    end
  end

  def test_write_uses_chronologically_sortable_filename
    Dir.mktmpdir("hive-writer") do |dir|
      W.write!(project: "p", slug: "first", argv: [ "hive", "run", "first" ],
               state_home: dir, now: Time.utc(2026, 5, 28, 18, 0, 0))
      W.write!(project: "p", slug: "second", argv: [ "hive", "run", "second" ],
               state_home: dir, now: Time.utc(2026, 5, 28, 18, 1, 0))

      files = Dir.glob(File.join(Q.directory(state_home: dir), "*.json")).sort
      # Filenames sort lexicographically by created_at, so sorting on
      # the filename and on the time-ordering of the requests must
      # agree.
      first, second = files.map { |path| JSON.parse(File.read(path))["slug"] }
      assert_equal "first", first
      assert_equal "second", second
    end
  end

  def test_write_is_atomic_no_partial_files_remain
    Dir.mktmpdir("hive-writer") do |dir|
      # SEC-5 from PR #241 ce-code-review: slug must satisfy the
      # ADR-012 regex (min 2 chars). Use a realistic slug shape.
      W.write!(project: "hive", slug: "task-260528-aaaa",
               argv: [ "hive", "run", "task-260528-aaaa" ],
               state_home: dir, now: Time.utc(2026, 5, 28, 18, 0, 0))

      queue_dir = Q.directory(state_home: dir)
      # Atomic write must leave no `.tmp.<pid>.<tid>` siblings on
      # success — a concurrent daemon scan looks at *.json only, but a
      # stale .tmp would leak across runs.
      tmps = Dir.glob(File.join(queue_dir, ".*.tmp.*"))
      assert_empty tmps, "atomic write must not leak tmp files: #{tmps.inspect}"
    end
  end

  def test_write_rejects_non_allowlisted_argv
    Dir.mktmpdir("hive-writer") do |dir|
      good_slug = "task-260528-aaaa"
      assert_raises(ArgumentError) do
        W.write!(project: "hive", slug: good_slug, argv: [ "hive", "doctor" ], state_home: dir)
      end
      assert_raises(ArgumentError) do
        W.write!(project: "hive", slug: good_slug, argv: [ "echo", "rm", "-rf" ], state_home: dir)
      end
      assert_raises(ArgumentError) do
        W.write!(project: "hive", slug: good_slug, argv: "hive run #{good_slug}", state_home: dir)
      end
      # Nothing should have been written.
      files = Dir.glob(File.join(Q.directory(state_home: dir), "*.json"))
      assert_empty files
    end
  end

  # AC-04 from PR #241 ce-code-review: empty project or slug must
  # raise loudly at the producer boundary, not silently make the
  # daemon reject + reply "Couldn't queue".
  def test_write_rejects_empty_project_or_slug
    Dir.mktmpdir("hive-writer") do |dir|
      good_argv = [ "hive", "run", "task-260528-aaaa" ]

      empty_project = assert_raises(ArgumentError) do
        W.write!(project: "", slug: "task-260528-aaaa", argv: good_argv, state_home: dir)
      end
      assert_match(/project is required/, empty_project.message)

      empty_slug = assert_raises(ArgumentError) do
        W.write!(project: "hive", slug: "", argv: good_argv, state_home: dir)
      end
      assert_match(/slug is required/, empty_slug.message)

      files = Dir.glob(File.join(Q.directory(state_home: dir), "*.json"))
      assert_empty files
    end
  end

  # SEC-3 from PR #241 ce-code-review: queue dir must be 0700 so the
  # producer/consumer auth boundary is at least scoped to the
  # owning user. Default umask of 0022 would leave it world-readable
  # and any local user could enqueue a request.
  def test_directory_is_created_with_user_only_permissions
    Dir.mktmpdir("hive-writer") do |dir|
      W.write!(project: "hive", slug: "task-260528-aaaa",
               argv: [ "hive", "run", "task-260528-aaaa" ], state_home: dir)
      queue_dir = File.join(dir, "dispatch_requests")
      mode = File.stat(queue_dir).mode & 0o777
      assert_equal 0o700, mode,
                   "queue dir must be user-only (got #{mode.to_s(8)})"
    end
  end

  def test_write_produces_a_parseable_request_via_pending
    Dir.mktmpdir("hive-writer") do |dir|
      W.write!(project: "hive", slug: "s1",
               argv: [ "hive", "markers", "clear", "s1", "--name", "ERROR", "--project", "hive", "--json" ],
               trigger: "autofix",
               state_home: dir,
               now: Time.utc(2026, 5, 28, 18, 0, 0))

      pending = Q.pending(state_home: dir)
      assert_equal 1, pending.size
      req = pending.first
      assert_equal "hive", req.project
      assert_equal "s1", req.slug
      assert_equal "bot", req.requestor
      assert_equal "autofix", req.trigger
      assert_equal "markers", req.argv[1]
    end
  end

  def test_sequence_helpers_delegate_to_queue
    Dir.mktmpdir("hive-writer") do |dir|
      assert W.write_sequence!(
        request_id: "seq-writer-1",
        remaining_argvs: [ [ "hive", "review", "task-260528-aaaa", "--json" ] ],
        state_home: dir
      )

      sequence_path = File.join(Q.directory(state_home: dir), "seq-writer-1#{Q::SEQUENCE_SUFFIX}")
      assert File.exist?(sequence_path)
      assert W.discard_sequence!(request_id: "seq-writer-1", state_home: dir)
      refute File.exist?(sequence_path)
    end
  end
end
