require "test_helper"
require "hive/brainstorm_suggestions/context_bundle"

class HiveBrainstormSuggestionsContextBundleTest < Minitest::Test
  def git(root, *args)
    env = {
      "GIT_AUTHOR_NAME" => "Test", "GIT_AUTHOR_EMAIL" => "test@example.com",
      "GIT_COMMITTER_NAME" => "Test", "GIT_COMMITTER_EMAIL" => "test@example.com"
    }
    output = IO.popen(env, [ "git", "-C", root, *args ], err: [ :child, :out ], &:read)
    raise "git #{args.join(' ')} failed: #{output}" unless $CHILD_STATUS.success?

    output
  end

  def with_repository
    Dir.mktmpdir do |root|
      git(root, "init", "-q")
      FileUtils.mkdir_p(File.join(root, "lib"))
      FileUtils.mkdir_p(File.join(root, "wiki"))
      File.write(File.join(root, "lib", "adapter.rb"), "ADAPTER = :old\n")
      File.write(File.join(root, "deleted.txt"), "remove me\n")
      File.write(File.join(root, "wiki", "architecture.md"), "The adapter boundary is stable.\n")
      git(root, "add", ".")
      git(root, "commit", "-qm", "initial")
      yield root
    end
  end

  def with_task(root)
    task = File.join(root, "task")
    FileUtils.mkdir_p(task)
    File.write(File.join(task, "idea.md"), "Choose the repository adapter safely.\n")
    File.write(File.join(task, "brainstorm.md"), <<~MARKDOWN)
      ## Round 1
      ### Q1. Which constraint is settled?
      ### A1.
      Keep the public API.
      ### Q2. Which adapter should we use?
      ### A2.
      <!-- WAITING -->
    MARKDOWN
    yield task
  end

  def test_capture_uses_tracked_overlay_and_preceding_durable_answers_only
    with_repository do |root|
      File.write(File.join(root, "lib", "adapter.rb"), "ADAPTER = :working_tree\n")
      File.write(File.join(root, "staged.rb"), "STAGED = true\n")
      git(root, "add", "staged.rb")
      File.delete(File.join(root, "deleted.txt"))
      File.write(File.join(root, "untracked.rb"), "UNTRACKED = true\n")
      File.write(File.join(root, "secret-adapter.yml"), "API_KEY=abcdefghijklmnopqrstuvwxyz123456\n")
      git(root, "add", "secret-adapter.yml")

      with_task(root) do |task|
        bundle = Hive::BrainstormSuggestions::ContextBundle.capture(
          project_root: root, task_root: task, question_ordinal: 2
        )
        paths = bundle.manifest.fetch("entries").map { |entry| entry.fetch("path") }
        context = bundle.render_context

        assert_includes context, "ADAPTER = :working_tree"
        assert_includes context, "STAGED = true"
        assert_includes paths, "wiki/architecture.md"
        refute_includes paths, "deleted.txt"
        refute_includes paths, "untracked.rb"
        refute_includes paths, "secret-adapter.yml"
        refute_includes context, "abcdefghijklmnopqrstuvwxyz123456"
        assert_equal [ "Keep the public API." ], bundle.settled_answers.map { |row| row.fetch("answer") }
        assert_equal "Which adapter should we use?", bundle.question.fetch("text")
        assert bundle.diagnostics.fetch("head")
        refute bundle.manifest.key?("head")
      end
    end
  end

  def test_empty_head_change_does_not_change_selected_identity
    with_repository do |root|
      with_task(root) do |task|
        before = Hive::BrainstormSuggestions::ContextBundle.capture(
          project_root: root, task_root: task, question_ordinal: 2
        ).selected_identity
        git(root, "commit", "--allow-empty", "-qm", "diagnostic head only")
        after = Hive::BrainstormSuggestions::ContextBundle.capture(
          project_root: root, task_root: task, question_ordinal: 2
        ).selected_identity

        assert_equal before, after
      end
    end
  end

  def test_unrelated_tracked_change_does_not_change_selected_identity
    with_repository do |root|
      with_task(root) do |task|
        before = Hive::BrainstormSuggestions::ContextBundle.capture(
          project_root: root, task_root: task, question_ordinal: 2
        ).selected_identity

        FileUtils.mkdir_p(File.join(root, "notes"))
        File.write(File.join(root, "notes", "unrelated.txt"), "zebra inventory\n")
        git(root, "add", "notes/unrelated.txt")
        git(root, "commit", "-qm", "unrelated tracked note")
        unrelated = Hive::BrainstormSuggestions::ContextBundle.capture(
          project_root: root, task_root: task, question_ordinal: 2
        ).selected_identity

        File.write(File.join(root, "lib", "adapter.rb"), "ADAPTER = :selected_change\n")
        selected = Hive::BrainstormSuggestions::ContextBundle.capture(
          project_root: root, task_root: task, question_ordinal: 2
        ).selected_identity

        assert_equal before, unrelated
        refute_equal unrelated, selected
      end
    end
  end

  def test_materialized_bundle_is_private_and_worker_immutable
    with_repository do |root|
      with_task(root) do |task|
        bundle = Hive::BrainstormSuggestions::ContextBundle.capture(
          project_root: root, task_root: task, question_ordinal: 2
        )
        Dir.mktmpdir do |runtime|
          bundle_root = bundle.materialize(runtime)

          assert_equal 0o700, File.stat(bundle_root).mode & 0o777
          files = Dir.glob(File.join(bundle_root, "**", "*"), File::FNM_DOTMATCH).select { |path| File.file?(path) }
          refute_empty files
          assert files.all? { |path| (File.stat(path).mode & 0o777) == 0o400 }
        end
      end
    end
  end

  def test_index_conflict_and_tracked_symlink_fail_closed
    with_repository do |root|
      File.symlink("/etc/passwd", File.join(root, "escape-link"))
      git(root, "add", "escape-link")
      with_task(root) do |task|
        error = assert_raises(Hive::BrainstormSuggestions::ContextBundle::CaptureError) do
          Hive::BrainstormSuggestions::ContextBundle.capture(
            project_root: root, task_root: task, question_ordinal: 2
          )
        end
        assert_equal "unsafe_tracked_entry", error.code
      end
    end
  end
end
