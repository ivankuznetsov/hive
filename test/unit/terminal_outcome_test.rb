require "test_helper"
require "hive/terminal_outcome"

class TerminalOutcomeTest < Minitest::Test
  include HiveTestHelper

  def outcomes
    Hive::Workflow::TerminalOutcomes.new(
      complete: [ "verified", "not-reproduced" ], blocked: [ "blocked" ]
    )
  end

  def classify(body)
    with_tmp_dir do |dir|
      path = File.join(dir, "repair-certificate.md")
      File.binwrite(path, body)
      return Hive::TerminalOutcome.classify(path, outcomes)
    end
  end

  def test_classifies_declared_complete_and_blocked_first_lines
    verified = classify("Outcome: verified\nproof\n<!-- COMPLETE -->\n")
    blocked = classify("Outcome: blocked\nreason\n<!-- COMPLETE -->\n")

    assert_equal :complete, verified.kind
    assert_equal "verified", verified.outcome
    assert_equal :blocked, blocked.kind
    assert_equal "blocked", blocked.outcome
  end

  def test_unknown_and_malformed_outcomes_fail_closed_with_safe_details
    unknown = classify("Outcome: inconclusive\n<!-- COMPLETE -->\n")
    malformed = classify(" Outcome: verified\n<!-- COMPLETE -->\n")
    trailing = classify("Outcome: verified extra\n<!-- COMPLETE -->\n")

    assert_equal [ :invalid, "inconclusive" ], [ unknown.kind, unknown.outcome ]
    assert_equal [ :invalid, "malformed" ], [ malformed.kind, malformed.outcome ]
    assert_equal [ :invalid, "malformed" ], [ trailing.kind, trailing.outcome ]
  end

  def test_invalid_utf8_overlong_symlink_directory_and_missing_fail_closed
    invalid_utf8 = classify("Outcome: \xFF\n<!-- COMPLETE -->\n".b)
    overlong = classify("Outcome: #{'a' * 513}\n<!-- COMPLETE -->\n")

    assert_equal [ :invalid, "invalid-utf8" ], [ invalid_utf8.kind, invalid_utf8.outcome ]
    assert_equal [ :invalid, "overlong" ], [ overlong.kind, overlong.outcome ]

    with_tmp_dir do |dir|
      target = File.join(dir, "target.md")
      link = File.join(dir, "link.md")
      File.write(target, "Outcome: verified\n<!-- COMPLETE -->\n")
      File.symlink(target, link)

      assert_equal "non-regular", Hive::TerminalOutcome.classify(link, outcomes).outcome
      assert_equal "non-regular", Hive::TerminalOutcome.classify(dir, outcomes).outcome
      assert_equal "missing", Hive::TerminalOutcome.classify(File.join(dir, "missing.md"), outcomes).outcome
    end
  end

  def test_reads_no_more_than_the_bounded_first_line_window
    with_tmp_dir do |dir|
      path = File.join(dir, "repair-certificate.md")
      File.write(path, "Outcome: verified\n#{'x' * 10_000}\n<!-- COMPLETE -->\n")
      reads = []
      wrapper = Class.new do
        define_method(:initialize) { |io, observed| @io = io; @observed = observed }
        define_method(:stat) { @io.stat }
        define_method(:read) do |length|
          @observed << length
          @io.read(length)
        end
        define_method(:close) { @io.close }
      end
      original = File.method(:open)
      replacement = lambda do |opened_path, flags, *args, &block|
        return original.call(opened_path, flags, *args, &block) unless opened_path == path

        io = wrapper.new(original.call(opened_path, flags, *args), reads)
        block ? block.call(io).tap { io.close } : io
      end

      result = with_replaced_singleton_method(File, :open, replacement) do
        Hive::TerminalOutcome.classify(path, outcomes)
      end

      assert_equal :complete, result.kind
      assert_equal [ Hive::TerminalOutcome::MAX_FIRST_LINE_BYTES + 1 ], reads
    end
  end

  def test_unreadable_file_fails_closed_without_exposing_the_path
    with_tmp_dir do |dir|
      path = File.join(dir, "repair-certificate.md")
      File.write(path, "Outcome: verified\n")
      original = File.method(:open)
      replacement = lambda do |opened_path, *args, &block|
        raise Errno::EACCES, "secret #{opened_path}" if opened_path == path

        original.call(opened_path, *args, &block)
      end

      result = with_replaced_singleton_method(File, :open, replacement) do
        Hive::TerminalOutcome.classify(path, outcomes)
      end

      assert_equal :invalid, result.kind
      assert_equal "unreadable", result.outcome
      refute_includes result.outcome, path
    end
  end

  def test_normalization_replaces_complete_marker_even_when_the_first_line_is_invalid_utf8
    with_tmp_dir do |dir|
      path = File.join(dir, "repair-certificate.md")
      File.binwrite(path, "Outcome: \xFF\n<!-- COMPLETE -->\n".b)
      workflow = Hive::Workflow.new(
        id: :repair,
        stages: [
          Hive::Workflow::Stage.new(
            name: "repair", index: 1, state_file: File.basename(path), kind: :agent,
            deliverable: File.basename(path), terminal_outcomes: outcomes
          )
        ]
      )
      task = Struct.new(:workflow, :stage_name, :state_file).new(workflow, "repair", path)

      normalization = Hive::TerminalOutcome.normalize(
        task, { commit: "complete", status: :complete }
      )
      marker = Hive::Markers.current(path)

      assert normalization.changed
      assert_equal({ commit: "error", status: :error }, normalization.result)
      assert_equal :error, marker.name
      assert_equal "terminal_outcome_invalid", marker.attrs.fetch("reason")
      assert_equal "invalid-utf8", marker.attrs.fetch("outcome")
      assert Hive::Markers.clear_current(
        path, expected_name: :error,
        match_attrs: { "reason" => "terminal_outcome_invalid" }, purge_history: true
      )
      assert_equal :none, Hive::Markers.current(path).name
      assert_includes File.binread(path), "\xFF".b
    end
  end
end
