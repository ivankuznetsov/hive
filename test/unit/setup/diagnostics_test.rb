require "test_helper"
require "hive/setup/diagnostics"

class SetupDiagnosticsTest < Minitest::Test
  include HiveTestHelper

  Status = Struct.new(:ok) do
    def success?
      ok
    end
  end

  def executable(dir, name)
    path = File.join(dir, name)
    File.write(path, "#!/bin/sh\n")
    FileUtils.chmod(0o755, path)
    path
  end

  def test_missing_gh_reports_auth_install_fix
    Dir.mktmpdir("hive-diag") do |dir|
      %w[git tmux claude codex node npm sqlite3].each { |name| executable(dir, name) }
      runner = ->(argv) { [ "#{File.basename(argv.first)} 9.9.9", "", Status.new(true) ] }

      result = Hive::Setup::Diagnostics.new(path: dir, runner: runner, ruby_version: "3.4.1").run
      row = result.results.find { |r| r.name == "gh" }

      assert_equal "missing", row.status
      assert_match(/install/, row.fix_command)
    end
  end

  def test_gh_unauthenticated_reports_login_without_fixing
    Dir.mktmpdir("hive-diag") do |dir|
      %w[git tmux gh claude codex node npm sqlite3].each { |name| executable(dir, name) }
      runner = lambda do |argv|
        if argv[1..] == %w[auth status]
          [ "", "not logged in", Status.new(false) ]
        else
          [ "#{File.basename(argv.first)} 9.9.9", "", Status.new(true) ]
        end
      end

      row = Hive::Setup::Diagnostics.new(path: dir, runner: runner, ruby_version: "3.4.1")
                                     .run.results.find { |r| r.name == "gh" }

      assert_equal "unauthenticated", row.status
      assert_equal "gh auth login", row.fix_command
    end
  end

  def test_version_too_old_is_classified
    Dir.mktmpdir("hive-diag") do |dir|
      %w[git tmux gh claude codex node npm sqlite3].each { |name| executable(dir, name) }
      runner = lambda do |argv|
        return [ "", "", Status.new(true) ] if argv[1..] == %w[auth status]
        return [ "tmux 2.9", "", Status.new(true) ] if File.basename(argv.first) == "tmux"

        [ "#{File.basename(argv.first)} 9.9.9", "", Status.new(true) ]
      end

      row = Hive::Setup::Diagnostics.new(path: dir, runner: runner, ruby_version: "3.4.1")
                                     .run.results.find { |r| r.name == "tmux" }

      assert_equal "version_too_old", row.status
      assert_match(/>= 3\.0/, row.detail)
    end
  end

  def test_qmd_missing_is_bootstrappable
    Dir.mktmpdir("hive-diag") do |dir|
      %w[git tmux gh claude codex node npm sqlite3].each { |name| executable(dir, name) }
      runner = ->(argv) { [ "#{File.basename(argv.first)} 9.9.9", "", Status.new(true) ] }

      row = Hive::Setup::Diagnostics.new(path: dir, runner: runner, ruby_version: "3.4.1")
                                     .run.results.find { |r| r.name == "qmd" }

      assert_equal "missing", row.status
      assert row.bootstrappable
      assert_nil row.fix_command
    end
  end

  def test_json_shape_is_stable
    result = Hive::Setup::Diagnostics::Aggregate.new(
      results: [
        Hive::Setup::Diagnostics::Result.new(
          name: "gh", status: "missing", detail: "missing", fix_command: "gh auth login", bootstrappable: false
        )
      ]
    )

    assert_equal(
      {
        "ok" => false,
        "results" => [
          {
            "name" => "gh",
            "status" => "missing",
            "detail" => "missing",
            "fix_command" => "gh auth login",
            "bootstrappable" => false
          }
        ]
      },
      result.to_h
    )
  end
end
