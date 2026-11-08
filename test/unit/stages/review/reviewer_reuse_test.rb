require "test_helper"
require "json"
require "hive/stages/review/context"
require "hive/stages/review/reviewer_reuse"

class ReviewerReuseTest < Minitest::Test
  include HiveTestHelper

  Reuse = Hive::Stages::Review::ReviewerReuse
  HEAD = "a" * 40

  def make_ctx(dir, pass: 1)
    Hive::Stages::Review::Context.new(
      worktree_path: dir, task_folder: dir, default_branch: "main", pass: pass
    )
  end

  def write_output(dir, basename, body, pass: 1)
    FileUtils.mkdir_p(File.join(dir, "reviews"))
    path = File.join(dir, "reviews", "#{basename}-#{format('%02d', pass)}.md")
    File.write(path, body)
    path
  end

  def test_record_then_consume_round_trips_and_is_single_use
    with_tmp_dir do |dir|
      ctx = make_ctx(dir)
      write_output(dir, "codex", "## Low\n- [ ] a\n")
      digests = Reuse.digests(ctx, [ "codex", "missing" ])
      assert_equal [ "codex" ], digests.keys, "absent outputs carry no digest"

      Reuse.record(ctx, head: HEAD, pre_triage_digests: digests)
      receipt = JSON.parse(File.read(Reuse.path(dir, 1)))
      assert_equal({ "version" => 1, "pass" => 1, "head" => HEAD, "outputs" => digests }, receipt)

      assert_equal digests, Reuse.consume(ctx, head: HEAD)
      refute File.exist?(Reuse.path(dir, 1)), "the receipt is consumed on read"
      assert_equal({}, Reuse.consume(ctx, head: HEAD))
    end
  end

  def test_record_drops_outputs_triage_edited_and_skips_empty_receipts
    with_tmp_dir do |dir|
      ctx = make_ctx(dir)
      path = write_output(dir, "codex", "before triage\n")
      digests = Reuse.digests(ctx, [ "codex" ])
      File.write(path, "partially triaged\n")

      Reuse.record(ctx, head: HEAD, pre_triage_digests: digests)
      refute File.exist?(Reuse.path(dir, 1)), "nothing reusable means no receipt"

      File.write(path, "before triage\n")
      Reuse.record(ctx, head: "", pre_triage_digests: digests)
      refute File.exist?(Reuse.path(dir, 1)), "an unknown HEAD can never bind a receipt"
    end
  end

  def test_consume_rejects_moved_head_other_pass_and_malformed_receipts
    with_tmp_dir do |dir|
      ctx = make_ctx(dir)
      FileUtils.mkdir_p(File.join(dir, "reviews"))
      receipt = { "version" => 1, "pass" => 1, "head" => HEAD, "outputs" => { "codex" => "d" } }
      write = ->(data) { File.write(Reuse.path(dir, 1), data.is_a?(String) ? data : JSON.generate(data)) }

      write.call(receipt)
      assert_equal({}, Reuse.consume(ctx, head: "b" * 40), "a moved HEAD invalidates the receipt")
      refute File.exist?(Reuse.path(dir, 1))

      write.call(receipt)
      assert_equal({}, Reuse.consume(ctx, head: nil))
      write.call(receipt.merge("pass" => 2))
      assert_equal({}, Reuse.consume(ctx, head: HEAD))
      write.call(receipt.merge("version" => 0))
      assert_equal({}, Reuse.consume(ctx, head: HEAD))
      write.call(receipt.merge("outputs" => [ "codex" ]))
      assert_equal({}, Reuse.consume(ctx, head: HEAD))
      write.call(receipt.merge("outputs" => { "codex" => "d", "bad" => 1 }))
      assert_equal({ "codex" => "d" }, Reuse.consume(ctx, head: HEAD))
      write.call("[]")
      assert_equal({}, Reuse.consume(ctx, head: HEAD))
      write.call("{not json")
      assert_equal({}, Reuse.consume(ctx, head: HEAD))
    end
  end

  def test_reusable_requires_a_recorded_matching_digest
    with_tmp_dir do |dir|
      ctx = make_ctx(dir)
      path = write_output(dir, "codex", "body\n")
      digest = Digest::SHA256.file(path).hexdigest

      assert Reuse.reusable?(ctx, "codex", { "codex" => digest })
      refute Reuse.reusable?(ctx, "codex", {})
      refute Reuse.reusable?(ctx, nil, { "codex" => digest })
      refute Reuse.reusable?(ctx, "codex", { "codex" => "0" * 64 })
      File.delete(path)
      refute Reuse.reusable?(ctx, "codex", { "codex" => digest }), "a deleted output is re-run"
    end
  end

  def test_record_write_failure_warns_and_leaves_no_receipt
    with_tmp_dir do |dir|
      ctx = make_ctx(dir)
      write_output(dir, "codex", "body\n")
      digests = Reuse.digests(ctx, [ "codex" ])
      failing = ->(*_args, **_kwargs) { raise Errno::ENOSPC, "disk full" }

      _out, err = capture_io do
        with_replaced_singleton_method(Hive::AtomicFile, :write, failing) do
          Reuse.record(ctx, head: HEAD, pre_triage_digests: digests)
        end
      end

      assert_match(/could not record reviewer reuse receipt: Errno::ENOSPC/, err)
      refute File.exist?(Reuse.path(dir, 1))
    end
  end
end
