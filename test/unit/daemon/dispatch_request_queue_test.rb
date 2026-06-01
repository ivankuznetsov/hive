require "test_helper"
require "fileutils"
require "json"
require "tmpdir"
require "hive/daemon/dispatch_request_queue"

class HiveDaemonDispatchRequestQueueTest < Minitest::Test
  include HiveTestHelper

  Q = Hive::Daemon::DispatchRequestQueue

  def write_request(state_home, request_id:, created_at:, argv: [ "hive", "run", "slug-x", "--json" ],
                    project: "hive", slug: "slug-x", requestor: "bot", chat_id: 42,
                    update_id: 99, trigger: "answer_complete", schema_version: 1,
                    schema: "hive-dispatch-request")
    dir = Q.directory(state_home: state_home)
    filename = Q.filename_for(created_at: created_at, request_id: request_id)
    path = File.join(dir, filename)
    payload = {
      "schema" => schema,
      "schema_version" => schema_version,
      "request_id" => request_id,
      "created_at" => created_at.utc.iso8601(6),
      "project" => project,
      "slug" => slug,
      "argv" => argv,
      "requestor" => requestor,
      "chat_id" => chat_id,
      "update_id" => update_id,
      "trigger" => trigger
    }
    File.write(path, JSON.generate(payload))
    path
  end

  def test_directory_creates_under_state_home
    Dir.mktmpdir("hive-dispatch-queue") do |dir|
      path = Q.directory(state_home: dir)
      assert File.directory?(path)
      assert_equal File.join(dir, "dispatch_requests"), path
    end
  end

  def test_pending_returns_requests_sorted_by_created_at
    Dir.mktmpdir("hive-dispatch-queue") do |dir|
      later = Time.utc(2026, 5, 28, 18, 13, 9)
      earlier = Time.utc(2026, 5, 28, 18, 11, 44)
      write_request(dir, request_id: "B", created_at: later, slug: "second")
      write_request(dir, request_id: "A", created_at: earlier, slug: "first")

      pending = Q.pending(state_home: dir)
      assert_equal %w[first second], pending.map(&:slug)
      assert_equal %w[A B], pending.map(&:request_id)
    end
  end

  def test_pending_skips_malformed_json_via_bad_handler
    Dir.mktmpdir("hive-dispatch-queue") do |dir|
      good = write_request(dir, request_id: "OK", created_at: Time.utc(2026, 5, 28, 18, 0, 0), slug: "good")
      bad_path = File.join(Q.directory(state_home: dir), "20260528T180000000000-BROKEN.json")
      File.write(bad_path, "{not json")

      seen_bads = []
      pending = Q.pending(state_home: dir, bad_handler: ->(path:, reason:) {
        seen_bads << { path: path, reason: reason }
      })

      assert_equal [ "good" ], pending.map(&:slug)
      assert_equal 1, seen_bads.size
      assert_equal bad_path, seen_bads.first[:path]
      assert_equal "malformed_json", seen_bads.first[:reason]
      # Good entry must round-trip
      assert_equal good, pending.first.path
    end
  end

  def test_pending_rejects_wrong_schema
    Dir.mktmpdir("hive-dispatch-queue") do |dir|
      write_request(dir, request_id: "BAD", created_at: Time.utc(2026, 5, 28, 18, 0, 0),
                    schema: "not-our-schema")

      seen = []
      Q.pending(state_home: dir, bad_handler: ->(path:, reason:) { seen << reason })
      assert_equal [ "wrong_schema" ], seen
    end
  end

  def test_pending_rejects_unknown_schema_version
    Dir.mktmpdir("hive-dispatch-queue") do |dir|
      write_request(dir, request_id: "BAD", created_at: Time.utc(2026, 5, 28, 18, 0, 0),
                    schema_version: 999)
      reasons = []
      Q.pending(state_home: dir, bad_handler: ->(path:, reason:) { reasons << reason })
      assert_equal [ "unknown_schema_version" ], reasons
    end
  end

  def test_pending_rejects_missing_fields_and_bad_created_at
    Dir.mktmpdir("hive-dispatch-queue") do |dir|
      dir_path = Q.directory(state_home: dir)
      # Use realistic placeholders that pass the project/slug regex
      # gates (SEC-5 from PR #241 ce-code-review) so each fixture
      # below targets exactly ONE rejection reason — without this,
      # the new slug check short-circuits before reaching the
      # original invalid_argv / invalid_created_at branches.
      good_slug = "task-260528-aaaa"
      good_project = "test-project"
      good_argv = [ "hive", "run", good_slug ]
      ts = Time.utc(2026, 5, 28).iso8601

      # Missing request_id
      File.write(File.join(dir_path, "20260528T180000000000-A.json"), JSON.generate(
        "schema" => "hive-dispatch-request", "schema_version" => 1,
        "request_id" => "", "created_at" => ts,
        "project" => good_project, "slug" => good_slug, "argv" => good_argv
      ))
      # Missing project
      File.write(File.join(dir_path, "20260528T180000000001-B.json"), JSON.generate(
        "schema" => "hive-dispatch-request", "schema_version" => 1,
        "request_id" => "B", "created_at" => ts,
        "project" => "", "slug" => good_slug, "argv" => good_argv
      ))
      # Invalid project (path-traversal candidate)
      File.write(File.join(dir_path, "20260528T180000000002-B2.json"), JSON.generate(
        "schema" => "hive-dispatch-request", "schema_version" => 1,
        "request_id" => "B2", "created_at" => ts,
        "project" => "../etc/passwd", "slug" => good_slug, "argv" => good_argv
      ))
      # Missing slug
      File.write(File.join(dir_path, "20260528T180000000003-C.json"), JSON.generate(
        "schema" => "hive-dispatch-request", "schema_version" => 1,
        "request_id" => "C", "created_at" => ts,
        "project" => good_project, "slug" => "", "argv" => good_argv
      ))
      # Invalid slug (path-traversal candidate)
      File.write(File.join(dir_path, "20260528T180000000004-C2.json"), JSON.generate(
        "schema" => "hive-dispatch-request", "schema_version" => 1,
        "request_id" => "C2", "created_at" => ts,
        "project" => good_project, "slug" => "../escape", "argv" => good_argv
      ))
      # Invalid argv type
      File.write(File.join(dir_path, "20260528T180000000005-D.json"), JSON.generate(
        "schema" => "hive-dispatch-request", "schema_version" => 1,
        "request_id" => "D", "created_at" => ts,
        "project" => good_project, "slug" => good_slug,
        "argv" => "hive run #{good_slug}"
      ))
      # Bad created_at
      File.write(File.join(dir_path, "20260528T180000000006-E.json"), JSON.generate(
        "schema" => "hive-dispatch-request", "schema_version" => 1,
        "request_id" => "E", "created_at" => "not-a-time",
        "project" => good_project, "slug" => good_slug, "argv" => good_argv
      ))
      # Root not a hash
      File.write(File.join(dir_path, "20260528T180000000007-F.json"), JSON.generate([ "array", "root" ]))

      reasons = []
      Q.pending(state_home: dir, bad_handler: ->(path:, reason:) { reasons << reason })
      assert_equal %w[
        missing_request_id missing_project invalid_project missing_slug invalid_slug invalid_argv invalid_created_at not_a_hash
      ], reasons
    end
  end

  def test_remove_is_idempotent
    Dir.mktmpdir("hive-dispatch-queue") do |dir|
      path = write_request(dir, request_id: "RM-1", created_at: Time.utc(2026, 5, 28, 18, 0, 0))
      assert File.exist?(path)

      assert Q.remove("RM-1", state_home: dir)
      refute File.exist?(path)
      # Second remove is a no-op, not an error.
      refute Q.remove("RM-1", state_home: dir)
    end
  end

  def test_remove_ignores_empty_request_id
    Dir.mktmpdir("hive-dispatch-queue") do |dir|
      refute Q.remove("", state_home: dir)
      refute Q.remove(nil, state_home: dir)
    end
  end

  def test_remove_skips_malformed_file_whose_path_matches_request_id
    Dir.mktmpdir("hive-dispatch-queue") do |dir|
      # A malformed file whose path contains the request_id but
      # whose body is not valid JSON. `remove` must skip it
      # gracefully and report nothing was removed (no exception).
      good_path = write_request(dir, request_id: "GOODID", created_at: Time.utc(2026, 5, 28, 18, 0, 0))
      bad_path = File.join(Q.directory(state_home: dir), "20260528T180000000001-GOODID.json")
      File.write(bad_path, "{not json")

      removed = Q.remove("GOODID", state_home: dir)
      assert removed, "the well-formed file with matching request_id must still be removed"
      refute File.exist?(good_path)
      assert File.exist?(bad_path), "the malformed file must be left for the pending-side bad_handler"
    end
  end

  def test_remove_returns_false_when_directory_is_missing
    Dir.mktmpdir("hive-dispatch-queue") do |dir|
      missing_state_home = File.join(dir, "does-not-exist")
      # Simulate the post-directory-creation race by removing the
      # dir we just created. Subsequent glob returns []; the outer
      # rescue is reached when the FS surfaces ENOENT during the
      # operation (rare but possible on tmpfs under heavy churn).
      # Drive the rescue by stubbing Dir.glob to raise ENOENT:
      Dir.singleton_class.alias_method(:__orig_glob, :glob) unless Dir.singleton_class.method_defined?(:__orig_glob)
      Dir.define_singleton_method(:glob) { |*| raise Errno::ENOENT, "vanished" }
      begin
        refute Q.remove("ANY", state_home: missing_state_home),
               "outer ENOENT rescue must return false instead of raising"
      ensure
        Dir.define_singleton_method(:glob, Dir.singleton_class.instance_method(:__orig_glob).bind(Dir))
      end
    end
  end

  def test_remove_does_not_touch_other_requests
    Dir.mktmpdir("hive-dispatch-queue") do |dir|
      a = write_request(dir, request_id: "AAA", created_at: Time.utc(2026, 5, 28, 18, 0, 0), slug: "a")
      b = write_request(dir, request_id: "BBB", created_at: Time.utc(2026, 5, 28, 18, 0, 1), slug: "b")

      Q.remove("AAA", state_home: dir)

      refute File.exist?(a)
      assert File.exist?(b)
    end
  end

  def test_valid_argv_accepts_allowlisted_verbs
    %w[run develop brainstorm plan review open-pr artifacts finalize archive markers].each do |verb|
      argv = [ "hive", verb, "slug" ]
      assert Q.valid_argv?(argv), "argv must accept #{verb}"
    end
  end

  def test_valid_argv_rejects_non_allowlisted_verbs
    refute Q.valid_argv?([ "hive", "doctor" ])
    refute Q.valid_argv?([ "hive", "status", "--json" ])
    refute Q.valid_argv?([ "hive", "new", "project", "idea" ])
    refute Q.valid_argv?([ "hive", "approve", "slug" ])
  end

  def test_valid_argv_rejects_non_hive_first_token_and_malformed_argv
    refute Q.valid_argv?([ "echo", "rm", "-rf" ])
    refute Q.valid_argv?([ "/bin/sh", "-c", "evil" ])
    refute Q.valid_argv?(nil)
    refute Q.valid_argv?([])
    refute Q.valid_argv?("hive run slug")
    refute Q.valid_argv?([ "hive", :run, "slug" ])
  end

  def test_filename_for_is_chronologically_sortable
    a = Q.filename_for(created_at: Time.utc(2026, 5, 28, 18, 11, 44), request_id: "A")
    b = Q.filename_for(created_at: Time.utc(2026, 5, 28, 18, 13, 9), request_id: "B")
    assert_operator a, :<, b
  end

  def test_expired_compares_against_now
    later = Time.utc(2026, 5, 28, 19, 0, 0)
    request = Q::Request.new(
      request_id: "X", created_at: Time.utc(2026, 5, 28, 18, 0, 0),
      project: "p", slug: "s", argv: [ "hive", "run", "s" ], requestor: "bot",
      chat_id: nil, update_id: nil, trigger: "answer_complete", path: nil
    )

    assert Q.expired?(request, now: later, expiry_sec: 600)
    refute Q.expired?(request, now: later, expiry_sec: 7200)
  end

  # ── C3: atomic claim + restart recovery ───────────────────────────────

  def test_claim_renames_to_claimed_and_hides_from_pending
    Dir.mktmpdir("hive-dispatch-queue") do |dir|
      json_path = write_request(dir, request_id: "clm00001",
                                created_at: Time.utc(2026, 5, 28, 18, 0, 0))
      claimed = Q.claim("clm00001", pid: 4321, process_start_time: "999",
                        now: Time.utc(2026, 5, 28, 18, 0, 1), state_home: dir)

      assert_equal "#{json_path}#{Q::CLAIMED_SUFFIX}", claimed
      refute File.exist?(json_path), "original .json is renamed away"
      assert File.exist?(claimed)
      assert_empty Q.pending(state_home: dir),
                   "a claimed request must be invisible to pending (at-most-once dispatch)"

      data = JSON.parse(File.read(claimed))
      assert_equal 4321, data.dig("claim", "pid")
      assert_equal "999", data.dig("claim", "process_start_time")
    end
  end

  def test_claim_returns_nil_when_no_matching_pending_file
    Dir.mktmpdir("hive-dispatch-queue") do |dir|
      assert_nil Q.claim("missing0", pid: 1, state_home: dir)
    end
  end

  def test_remove_deletes_claimed_file
    Dir.mktmpdir("hive-dispatch-queue") do |dir|
      write_request(dir, request_id: "rmclaim1", created_at: Time.utc(2026, 5, 28, 18, 0, 0))
      Q.claim("rmclaim1", pid: 10, state_home: dir)
      assert Q.remove("rmclaim1", state_home: dir), "remove must find + delete the claimed file"
      assert_empty Dir.glob(File.join(dir, "dispatch_requests", "*"))
    end
  end

  def test_recover_claims_removes_dead_owner_without_redispatch
    Dir.mktmpdir("hive-dispatch-queue") do |dir|
      write_request(dir, request_id: "dead0001", created_at: Time.utc(2026, 5, 28, 18, 0, 0))
      Q.claim("dead0001", pid: 4321, process_start_time: "111",
              now: Time.utc(2026, 5, 28, 18, 0, 1), state_home: dir)
      recovered = []
      removed = Q.recover_claims(
        state_home: dir, now: Time.utc(2026, 5, 28, 18, 1, 0),
        alive: ->(_pid, _start) { false },
        handler: ->(request_id:, reason:, path:) { recovered << [ request_id, reason ] }
      )
      assert_equal 1, removed
      assert_equal [ [ "dead0001", "owner_gone" ] ], recovered
      assert_empty Q.pending(state_home: dir),
                   "owner-gone claim is removed, NOT re-enqueued (at-most-once)"
      assert_empty Dir.glob(File.join(dir, "dispatch_requests", "*"))
    end
  end

  def test_recover_claims_leaves_live_owner_alone
    Dir.mktmpdir("hive-dispatch-queue") do |dir|
      write_request(dir, request_id: "live0001", created_at: Time.utc(2026, 5, 28, 18, 0, 0))
      claimed = Q.claim("live0001", pid: 4321, process_start_time: "111",
                        now: Time.utc(2026, 5, 28, 18, 0, 1), state_home: dir)
      removed = Q.recover_claims(
        state_home: dir, now: Time.utc(2026, 5, 28, 18, 1, 0),
        alive: ->(_pid, _start) { true }
      )
      assert_equal 0, removed
      assert File.exist?(claimed), "a still-running owner's claim must survive recovery"
    end
  end

  def test_recover_claims_expires_aged_claim_even_when_owner_alive
    Dir.mktmpdir("hive-dispatch-queue") do |dir|
      write_request(dir, request_id: "aged0001", created_at: Time.utc(2026, 5, 28, 18, 0, 0))
      Q.claim("aged0001", pid: 4321, process_start_time: "111",
              now: Time.utc(2026, 5, 28, 18, 0, 0), state_home: dir)
      # 20 minutes later, well past the 600s expiry, even an "alive" owner
      # must not pin the claim forever.
      removed = Q.recover_claims(
        state_home: dir, now: Time.utc(2026, 5, 28, 18, 20, 0),
        alive: ->(_pid, _start) { true }, expiry_sec: 600
      )
      assert_equal 1, removed
      assert_empty Dir.glob(File.join(dir, "dispatch_requests", "*"))
    end
  end

  def test_claim_skips_malformed_decoy_and_returns_nil
    Dir.mktmpdir("hive-dispatch-queue") do |dir|
      qdir = Q.directory(state_home: dir)
      # A .json file whose NAME contains the request_id but whose body is
      # unparseable — claim must skip it (rescue → next) and, finding no
      # valid match, return nil.
      File.write(File.join(qdir, "20260528-clm99999.json"), "{not json")
      assert_nil Q.claim("clm99999", pid: 1, state_home: dir)
    end
  end

  def test_claim_returns_nil_on_directory_enoent
    Dir.mktmpdir("hive-dispatch-queue") do |dir|
      with_replaced_singleton_method(Dir, :glob, ->(*) { raise Errno::ENOENT, "vanished" }) do
        assert_nil Q.claim("anything", pid: 1, state_home: dir)
      end
    end
  end

  def test_metadata_returns_routing_fields
    Dir.mktmpdir("hive-dispatch-queue") do |dir|
      write_request(dir, request_id: "meta0001", created_at: Time.utc(2026, 5, 28, 18, 0, 0),
                    project: "hive", slug: "slug-x")
      meta = Q.metadata("meta0001", state_home: dir)
      assert_equal 42, meta[:chat_id]
      assert_equal "hive", meta[:project]
    end
  end

  def test_metadata_returns_nil_when_absent
    Dir.mktmpdir("hive-dispatch-queue") do |dir|
      assert_nil Q.metadata("nope", state_home: dir)
    end
  end

  def test_metadata_skips_malformed_decoy
    Dir.mktmpdir("hive-dispatch-queue") do |dir|
      qdir = Q.directory(state_home: dir)
      File.write(File.join(qdir, "20260528-mdbad001.json"), "{not json")
      assert_nil Q.metadata("mdbad001", state_home: dir)
    end
  end

  def test_metadata_returns_nil_on_directory_enoent
    Dir.mktmpdir("hive-dispatch-queue") do |dir|
      with_replaced_singleton_method(Dir, :glob, ->(*) { raise Errno::ENOENT, "vanished" }) do
        assert_nil Q.metadata("anything", state_home: dir)
      end
    end
  end

  def test_recover_claims_returns_zero_on_directory_enoent
    Dir.mktmpdir("hive-dispatch-queue") do |dir|
      with_replaced_singleton_method(Dir, :glob, ->(*) { raise Errno::ENOENT, "vanished" }) do
        assert_equal 0, Q.recover_claims(state_home: dir, alive: ->(_p, _s) { true })
      end
    end
  end

  def test_recover_claims_expires_claim_with_unparseable_timestamp
    Dir.mktmpdir("hive-dispatch-queue") do |dir|
      qdir = Q.directory(state_home: dir)
      # Hand-craft a claimed file whose claim.claimed_at is not a timestamp
      # → claim_aged_out? rescues the parse and treats it as aged-out.
      payload = {
        "schema" => "hive-dispatch-request", "schema_version" => 1,
        "request_id" => "badts001", "created_at" => Time.utc(2026, 5, 28).iso8601,
        "project" => "hive", "slug" => "slug-x",
        "argv" => [ "hive", "run", "slug-x" ], "requestor" => "bot",
        "claim" => { "pid" => 1, "process_start_time" => "x", "claimed_at" => "not-a-time" }
      }
      File.write(File.join(qdir, "20260528-badts001.json#{Q::CLAIMED_SUFFIX}"), JSON.generate(payload))
      removed = Q.recover_claims(state_home: dir, alive: ->(_p, _s) { true })
      assert_equal 1, removed
    end
  end

  def test_recover_claims_removes_malformed_claim_file
    Dir.mktmpdir("hive-dispatch-queue") do |dir|
      claim_dir = Q.directory(state_home: dir)
      bad = File.join(claim_dir, "20260528-bad.json#{Q::CLAIMED_SUFFIX}")
      File.write(bad, "{not json")
      reasons = []
      removed = Q.recover_claims(
        state_home: dir, now: Time.now, alive: ->(_p, _s) { true },
        handler: ->(request_id:, reason:, path:) { reasons << reason }
      )
      assert_equal 1, removed
      assert_equal [ "malformed_claim" ], reasons
      refute File.exist?(bad)
    end
  end
end
