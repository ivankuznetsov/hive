require "test_helper"
require "hive/markers"

class MarkersTest < Minitest::Test
  include HiveTestHelper

  def test_returns_none_for_missing_file
    with_tmp_dir do |dir|
      state = Hive::Markers.current(File.join(dir, "nope.md"))
      assert state.none?, "missing file should report :none"
    end
  end

  def test_reads_simple_waiting_marker
    with_tmp_dir do |dir|
      file = File.join(dir, "x.md")
      File.write(file, "body\n<!-- WAITING -->\n")
      state = Hive::Markers.current(file)
      assert_equal :waiting, state.name
      assert_empty state.attrs
    end
  end

  def test_takes_last_marker_when_multiple_present
    with_tmp_dir do |dir|
      file = File.join(dir, "x.md")
      File.write(file, "<!-- WAITING -->\n## Round 1\n<!-- COMPLETE -->\n")
      state = Hive::Markers.current(file)
      assert_equal :complete, state.name
    end
  end

  def test_parses_attrs
    with_tmp_dir do |dir|
      file = File.join(dir, "x.md")
      File.write(file, %(<!-- AGENT_WORKING pid=12345 started=2026-04-24T10:00:00Z -->\n))
      state = Hive::Markers.current(file)
      assert_equal :agent_working, state.name
      assert_equal "12345", state.attrs["pid"]
      assert_equal "2026-04-24T10:00:00Z", state.attrs["started"]
    end
  end

  def test_set_appends_marker_to_empty_file
    with_tmp_dir do |dir|
      file = File.join(dir, "x.md")
      Hive::Markers.set(file, :waiting)
      assert_includes File.read(file), "<!-- WAITING -->"
    end
  end

  def test_set_replaces_last_marker
    with_tmp_dir do |dir|
      file = File.join(dir, "x.md")
      File.write(file, "## Round 1\n<!-- WAITING -->\n")
      Hive::Markers.set(file, :complete)
      content = File.read(file)
      assert_includes content, "<!-- COMPLETE -->"
      refute_includes content, "<!-- WAITING -->"
      assert_includes content, "## Round 1", "body content must be preserved"
    end
  end

  def test_set_writes_attrs
    with_tmp_dir do |dir|
      file = File.join(dir, "x.md")
      Hive::Markers.set(file, :agent_working, pid: 12_345, started: "2026-04-24T10:00:00Z")
      content = File.read(file)
      assert_match(/<!-- AGENT_WORKING pid=12345 started=2026-04-24T10:00:00Z -->/, content)
    end
  end

  def test_unknown_marker_raises
    with_tmp_dir do |dir|
      file = File.join(dir, "x.md")
      assert_raises(ArgumentError) { Hive::Markers.set(file, :unknown) }
    end
  end

  # Regression from smoke: when an agent uses an in-place Edit tool (rather
  # than a full-file Write), the AGENT_WORKING marker hive set before spawn
  # remains at the top of the file, with the agent's terminal marker (e.g.,
  # WAITING) appended at the bottom. Markers.current must return the *last*
  # marker so state stays correct even though the file is noisy.
  def test_agent_working_left_in_file_does_not_override_terminal_marker
    with_tmp_dir do |dir|
      file = File.join(dir, "x.md")
      File.write(file, <<~MD)
        <!-- AGENT_WORKING pid=1234 started=2026-04-25T10:00Z -->

        ## Round 1
        ### Q1.
        ### A1.

        <!-- WAITING -->
      MD
      state = Hive::Markers.current(file)
      assert_equal :waiting, state.name, "terminal marker must win even with stale AGENT_WORKING above"
    end
  end
end
