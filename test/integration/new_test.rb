require "test_helper"
require "hive/commands/init"
require "hive/commands/new"

class NewTest < Minitest::Test
  include HiveTestHelper

  def setup_project
    @prev_stdout = $stdout
    $stdout = StringIO.new
    yield
  ensure
    $stdout = @prev_stdout
  end

  def initialize_project(dir)
    Hive::Commands::Init.new(dir).call
  end

  def test_creates_idea_in_inbox
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        setup_project { initialize_project(dir) }
        project = File.basename(dir)
        _, _err = capture_io { Hive::Commands::New.new(project, "add inbox filter").call }

        glob = Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "add-inbox-filter-*")]
        assert_equal 1, glob.size, "expected one task folder, got #{glob.inspect}"
        idea = File.read(File.join(glob.first, "idea.md"))
        assert_includes idea, "add inbox filter"
        assert_includes idea, "<!-- WAITING -->"

        log = `git -C #{File.join(dir, ".hive-state")} log --format=%s -1`.strip
        assert_match(%r{\Ahive: 1-inbox/add-inbox-filter-\d{6}-[0-9a-f]{4} captured\z}, log)
      end
    end
  end

  def test_unicode_text_falls_back_to_task_slug
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        setup_project { initialize_project(dir) }
        project = File.basename(dir)
        capture_io { Hive::Commands::New.new(project, "добавить inbox фильтр").call }
        glob = Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "*")]
        assert_equal 1, glob.size
        # Cyrillic strips to "inbox"; final slug starts with "inbox-".
        assert_match(/\Ainbox-/, File.basename(glob.first))
      end
    end
  end

  def test_only_punctuation_falls_back_to_task_slug
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        setup_project { initialize_project(dir) }
        project = File.basename(dir)
        capture_io { Hive::Commands::New.new(project, "!!! ???").call }
        glob = Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "*")]
        assert_equal 1, glob.size
        assert_match(/\Atask-\d{6}-[0-9a-f]{4}\z/, File.basename(glob.first))
      end
    end
  end

  def test_very_long_words_do_not_overflow_slug_regex
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        setup_project { initialize_project(dir) }
        project = File.basename(dir)
        # Two single "words" that together exceed the 64-char slug limit.
        long_text = "#{'a' * 80} #{'b' * 80}"
        capture_io { Hive::Commands::New.new(project, long_text).call }
        glob = Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "*")]
        assert_equal 1, glob.size, "long text must not cause new to reject its own derived slug"
        slug = File.basename(glob.first)
        assert_operator slug.length, :<=, 64, "derived slug must always fit SLUG_RE max length"
        assert_match(/\A[a-z][a-z0-9-]{0,62}[a-z0-9]\z/, slug)
      end
    end
  end

  def test_long_text_truncates_to_five_words
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        setup_project { initialize_project(dir) }
        project = File.basename(dir)
        capture_io { Hive::Commands::New.new(project, "one two three four five six seven eight").call }
        glob = Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "*")]
        assert_equal 1, glob.size
        slug = File.basename(glob.first)
        assert_match(/\Aone-two-three-four-five-\d{6}-[0-9a-f]{4}\z/, slug)
      end
    end
  end

  def test_unregistered_project_fails
    with_tmp_global_config do
      _, err, status = with_captured_exit { Hive::Commands::New.new("nope", "x").call }
      assert_equal 1, status
      assert_includes err, "not initialized"
    end
  end

  def test_slug_override
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        setup_project { initialize_project(dir) }
        project = File.basename(dir)
        capture_io { Hive::Commands::New.new(project, "x", slug_override: "manual-slug-260424-aaaa").call }
        assert File.directory?(File.join(dir, ".hive-state", "stages", "1-inbox", "manual-slug-260424-aaaa"))
      end
    end
  end

  def test_invalid_slug_override_rejected
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        setup_project { initialize_project(dir) }
        project = File.basename(dir)
        _, err, status = with_captured_exit do
          Hive::Commands::New.new(project, "x", slug_override: "invalid_slug").call
        end
        assert_equal 1, status
        assert_includes err, "invalid slug"
      end
    end
  end

  def with_captured_exit
    out_pipe = StringIO.new
    err_pipe = StringIO.new
    real_stdout = $stdout
    real_stderr = $stderr
    $stdout = out_pipe
    $stderr = err_pipe
    status = 0
    begin
      yield
    rescue SystemExit => e
      status = e.status
    ensure
      $stdout = real_stdout
      $stderr = real_stderr
    end
    [ out_pipe.string, err_pipe.string, status ]
  end
end
