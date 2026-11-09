require "test_helper"
require "hive/stages/review"
require "hive/stages/review/pass_archive"

class ReviewPassArchiveTest < Minitest::Test
  include HiveTestHelper

  Archive = Hive::Stages::Review::PassArchive

  def write(folder, relative, body = "x\n")
    path = File.join(folder, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
    path
  end

  def test_archives_numbered_passes_and_keeps_unnumbered_state
    with_tmp_dir do |folder|
      %w[
        claude-ce-code-review-06.md escalations-06.md fix-success-05.md errors-04.md
        ci-error-02.md browser-blocked-06.md
      ].each { |name| write(folder, File.join("reviews", name)) }
      %w[ci-blocked.md deferred-findings.md suppressed.md].each { |name| write(folder, File.join("reviews", name)) }
      write(folder, "reviews/notes-1.md")
      FileUtils.mkdir_p(File.join(folder, "reviews", "plan-review"))
      outside = write(folder, "outside.md")
      File.symlink(outside, File.join(folder, "reviews", "linked-03.md"))

      moves = Archive.archive!(folder, label: "20261108T200102Z-8-finalize-to-6-review")

      archive = "reviews/archive/20261108T200102Z-8-finalize-to-6-review"
      assert_equal 7, moves.length
      assert(moves.all? { |from, to| to == File.join(archive, File.basename(from)) })
      remaining = Dir.children(File.join(folder, "reviews")).sort
      assert_equal %w[archive ci-blocked.md deferred-findings.md notes-1.md plan-review suppressed.md],
                   remaining
      assert File.symlink?(File.join(folder, archive, "linked-03.md"))
      assert File.exist?(outside), "archiving a link never touches its target"
      assert_equal 0, Hive::Stages::Review.max_review_pass(folder, { "review" => { "max_passes" => 3 } }),
                   "the review stage no longer counts the archived generation"
    end
  end

  def test_archive_is_a_noop_without_a_reviews_directory_or_numbered_files
    with_tmp_dir do |folder|
      assert_empty Archive.archive!(folder, label: "x")

      write(folder, "reviews/ci-blocked.md")
      assert_empty Archive.archive!(folder, label: "x")
      refute File.exist?(File.join(folder, "reviews", "archive"))
    end
  end

  def test_archive_does_not_follow_a_symlinked_reviews_directory
    with_tmp_dir do |folder|
      elsewhere = File.join(folder, "elsewhere")
      write(folder, "elsewhere/claude-01.md")
      FileUtils.mkdir_p(File.join(folder, "task"))
      File.symlink(elsewhere, File.join(folder, "task", "reviews"))

      assert_empty Archive.archive!(File.join(folder, "task"), label: "x")
      assert File.exist?(File.join(elsewhere, "claude-01.md"))
    end
  end

  def test_repeated_labels_get_a_fresh_directory_and_unsafe_characters_are_replaced
    with_tmp_dir do |folder|
      write(folder, "reviews/claude-01.md", "first\n")
      first = Archive.archive!(folder, label: "gen/../1")
      write(folder, "reviews/claude-01.md", "second\n")
      second = Archive.archive!(folder, label: "gen/../1")

      assert_equal [ [ "reviews/claude-01.md", "reviews/archive/gen-1/claude-01.md" ] ], first
      assert_equal [ [ "reviews/claude-01.md", "reviews/archive/gen-1-1/claude-01.md" ] ], second
      assert_equal "first\n", File.read(File.join(folder, first.first.last))
      assert_equal "second\n", File.read(File.join(folder, second.first.last))
    end
  end

  def test_restore_reverses_moves_and_reports_what_it_cannot_restore
    with_tmp_dir do |folder|
      assert_nil Archive.restore!(folder, nil)
      assert_nil Archive.restore!(folder, [])

      write(folder, "reviews/claude-01.md", "one\n")
      write(folder, "reviews/claude-02.md", "two\n")
      moves = Archive.archive!(folder, label: "gen")
      assert_nil Archive.restore!(folder, moves)
      assert_equal "one\n", File.read(File.join(folder, "reviews", "claude-01.md"))
      refute File.exist?(File.join(folder, "reviews", "archive", "gen"))

      moves = Archive.archive!(folder, label: "gen")
      write(folder, "reviews/claude-01.md", "concurrent\n")
      File.delete(File.join(folder, moves.last.last))
      issue = Archive.restore!(folder, moves)

      assert_match(/reviews\/archive\/gen\/claude-02\.md missing/, issue)
      assert_match(/reviews\/claude-01\.md reappeared/, issue)
      assert_equal "concurrent\n", File.read(File.join(folder, "reviews", "claude-01.md"))
      assert File.exist?(File.join(folder, "reviews", "archive", "gen", "claude-01.md"))
    end
  end

  def test_generation_counts_archived_generation_directories
    with_tmp_dir do |folder|
      assert_equal 1, Archive.generation(folder)

      write(folder, "reviews/claude-01.md")
      assert_equal 1, Archive.generation(folder)

      Archive.archive!(folder, label: "gen")
      assert_equal 2, Archive.generation(folder)

      write(folder, "reviews/claude-01.md")
      moves = Archive.archive!(folder, label: "gen")
      write(folder, "reviews/archive/stray.md")
      File.symlink(File.join(folder, "reviews"), File.join(folder, "reviews", "archive", "linked"))
      assert_equal 3, Archive.generation(folder), "files and symlinks are not generations"

      Archive.restore!(folder, moves)
      assert_equal 2, Archive.generation(folder)
    end
  end

  def test_generation_ignores_a_symlinked_archive_root
    with_tmp_dir do |folder|
      with_tmp_dir do |elsewhere|
        FileUtils.mkdir_p(File.join(elsewhere, "gen"))
        FileUtils.mkdir_p(File.join(folder, "reviews"))
        File.symlink(elsewhere, File.join(folder, "reviews", "archive"))

        assert_equal 1, Archive.generation(folder)
      end
    end
  end
end
