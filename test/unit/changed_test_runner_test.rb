require "test_helper"
require "stringio"
require_relative "../../script/test_changed"

class ChangedTestRunnerTest < Minitest::Test
  def in_repository
    Dir.mktmpdir do |directory|
      Dir.chdir(directory) do
        system("git", "init", "-q", exception: true)
        write("lib/hive/old.rb")
        write("test/unit/old_test.rb")
        system("git", "add", ".", exception: true)
        system("git", "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-qm", "base", exception: true)
        yield
      end
    end
  end

  def write(path, content = "")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def test_git_selection_includes_staged_unstaged_untracked_and_deleted_paths
    in_repository do
      File.unlink("lib/hive/old.rb")
      write("test/unit/old_test.rb", "changed")
      write("test/unit/new_test.rb")
      write("lib/hive/staged.rb")
      system("git", "add", "lib/hive/staged.rb", exception: true)
      assert_equal %w[lib/hive/old.rb lib/hive/staged.rb test/unit/new_test.rb test/unit/old_test.rb],
                   HiveChangedCoverage.changed_paths(base: "HEAD")
      assert_equal [ "lib/hive/staged.rb" ], HiveChangedCoverage.changed_sources(base: "HEAD")
    end
  end

  def test_selection_uses_merge_base_and_includes_branch_commits
    in_repository do
      system("git", "branch", "comparison", exception: true)
      write("test/unit/branch_test.rb")
      system("git", "add", ".", exception: true)
      system("git", "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-qm", "branch", exception: true)
      assert_equal [ "test/unit/branch_test.rb" ], HiveChangedCoverage.changed_paths(base: "comparison")
    end
  end

  def test_shared_configuration_selects_offline_suites_and_excludes_live_smoke
    in_repository do
      write("test/smoke/paid_test.rb")
      write("components/example/test/new_test.rb")
      write("web/test/models/new_test.rb")
      selected = HiveChangedCoverage.selection(paths: [ "Gemfile", "test/test_helper.rb" ])
      assert_equal [ "test/unit/old_test.rb" ], selected[:root]
      assert_equal [ "web/test/models/new_test.rb" ], selected[:web]
      assert_equal [ "components/example/test/new_test.rb" ], selected[:components]["components/example"]
      assert_equal 2, selected[:reasons].length
    end
  end

  def test_test_only_component_and_web_changes_dispatch_in_separate_processes
    in_repository do
      paths = %w[test/unit/new_test.rb components/example/test/new_test.rb web/test/models/new_test.rb web/test/system/new_test.rb]
      paths.each { |path| write(path) }
      commands = HiveChangedTestRunner.commands(HiveChangedCoverage.selection(paths: paths), options: [ "--seed", "42" ])
      assert_equal [ ".", ".", "web", "web" ], commands.map(&:first)
      assert_equal "bin/test", commands[0][1][0]
      assert_includes commands[1][1], "-Icomponents/example/test"
      assert_includes commands[2][1], "test/system/new_test.rb"
      assert_includes commands[3][1], "test/models/new_test.rb"
      assert commands.all? { |_directory, command| command.last(2) == [ "--seed", "42" ] }
    end
  end

  def test_unmapped_source_runs_root_suite_with_reason_and_docs_do_not
    in_repository do
      selection = HiveChangedCoverage.selection(paths: [ "lib/unmapped.rb" ])
      assert_equal [ "test/unit/old_test.rb" ], selection[:root]
      assert_includes selection[:reasons].first, "no focused owner"
      assert_empty HiveChangedTestRunner.commands(HiveChangedCoverage.selection(paths: [ "wiki/testing.md" ]))
    end
  end

  def test_list_does_not_execute_and_failure_stops_remaining_suites
    in_repository do
      write("test/unit/new_test.rb")
      write("web/test/models/new_test.rb")
      calls = []
      executor = ->(directory, command) { calls << [ directory, command ]; 23 }
      output = StringIO.new
      assert_equal 0, HiveChangedTestRunner.run([ "--base", "HEAD", "--list" ], output: output, executor: executor)
      assert_empty calls
      assert_includes output.string, "test/unit/new_test.rb"
      assert_equal 23, HiveChangedTestRunner.run([ "--base", "HEAD" ], output: output, executor: executor)
      assert_equal 1, calls.length
    end
  end

  def test_real_cli_executes_selected_root_command_and_propagates_exit
    script = File.expand_path("../../script/test_changed.rb", __dir__)
    in_repository do
      write("bin/test", "#!/usr/bin/env ruby\nFile.write('argv.txt', ARGV.join(\"\\n\"))\nexit 23\n")
      FileUtils.chmod(0o755, "bin/test")
      system("git", "add", "bin/test", exception: true)
      system("git", "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-qm", "runner", exception: true)
      write("test/unit/new_test.rb")
      _output, error, status = Open3.capture3(RbConfig.ruby, script, "--base", "HEAD", "--", "--seed", "42")
      assert_equal 23, status.exitstatus, error
      assert_equal [ "test/unit/new_test.rb", "--seed", "42" ], File.read("argv.txt").lines(chomp: true)
    end
  end

  def test_deleted_component_test_runs_remaining_component_and_root_tests
    in_repository do
      write("components/example/test/remaining_test.rb")
      selected = HiveChangedCoverage.selection(paths: [ "components/example/test/deleted_test.rb" ])
      assert_equal [ "test/unit/old_test.rb" ], selected[:root]
      assert_equal [ "components/example/test/remaining_test.rb" ], selected[:components]["components/example"]
    end
  end

  def test_missing_base_fails_clearly
    in_repository do
      error = StringIO.new
      assert_equal 1, HiveChangedTestRunner.run([ "--base", "missing-ref" ], error: error)
      assert_includes error.string, "merge-base failed"
    end
  end

  def test_packaged_markdown_is_not_treated_as_documentation_only
    in_repository do
      selected = HiveChangedCoverage.selection(paths: [ "templates/skills/hive/SKILL.md" ])
      assert_equal [ "test/unit/old_test.rb" ], selected[:root]
      refute_empty selected[:reasons]
    end
  end

  def test_web_source_changes_include_root_web_contract_tests
    in_repository do
      write("test/unit/web/source_bundle_test.rb")
      write("test/integration/web_command_test.rb")
      selected = HiveChangedCoverage.selection(paths: [ "web/app/controllers/tasks_controller.rb" ])
      assert_equal %w[test/integration/web_command_test.rb test/unit/web/source_bundle_test.rb], selected[:root]
    end
  end

  def test_implicit_owner_mapping_excludes_expensive_gates
    files = HiveChangedCoverage.test_files_for("lib/hive/babysitter/new_nested/unknown.rb")
    refute_empty files
    assert_empty files & HiveChangedCoverage::CI_GATE_FILES
  end

  def test_multiple_root_files_use_the_bounded_parallel_runner
    in_repository do
      write("test/unit/new_test.rb")
      selected = HiveChangedCoverage.selection(paths: %w[test/unit/old_test.rb test/unit/new_test.rb])
      command = HiveChangedTestRunner.commands(selected, options: [ "--seed", "42" ]).first.last
      assert_equal %w[bundle exec ruby script/test_parallel.rb], command.first(4)
      assert_equal [ "--seed", "42" ], command.last(2)
    end
  end

  def test_web_dispatch_overrides_an_inherited_root_gemfile
    script = File.expand_path("../../script/test_changed.rb", __dir__)
    in_repository do
      write("web/test/models/new_test.rb")
      Dir.mktmpdir("changed-test-bundle") do |bin|
        receipt = File.join(bin, "receipt")
        File.write(File.join(bin, "bundle"), "#!/bin/sh\nprintf '%s' \"$BUNDLE_GEMFILE\" > \"$HIVE_TEST_BUNDLE_RECEIPT\"\n")
        FileUtils.chmod(0o755, File.join(bin, "bundle"))
        _output, error, status = Open3.capture3(
          { "PATH" => "#{bin}:#{ENV.fetch('PATH')}", "BUNDLER_ORIG_PATH" => "#{bin}:#{ENV.fetch('PATH')}",
            "HIVE_TEST_BUNDLE_RECEIPT" => receipt },
          RbConfig.ruby, script, "--base", "HEAD"
        )
        assert status.success?, error
        assert_equal File.expand_path("web/Gemfile"), File.read(receipt)
      end
    end
  end
end
