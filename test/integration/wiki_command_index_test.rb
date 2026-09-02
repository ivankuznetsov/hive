# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"
require "hive/cli"
require_relative "../support/wiki_command_index"

class WikiCommandIndexIntegrationTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  WIKI_ROOT = File.join(ROOT, "wiki")

  def test_public_help_metadata_and_owner_index_are_one_read_only_contract
    before = repository_snapshot
    stdout, stderr, status = render_public_help

    assert status.success?, "bin/hive help failed (#{status.exitstatus}): #{stderr}"

    guard = WikiCommandIndex::Guard.new(wiki_root: WIKI_ROOT)
    index_text = File.read(File.join(WIKI_ROOT, "cli.md"))
    first = guard.evaluate(help_text: stdout, index_text: index_text)
    second = guard.evaluate(help_text: stdout, index_text: index_text)

    assert first.success?, first.diagnostics.map(&:to_s).join("\n")
    assert_equal first, second, "guard result or diagnostic ordering changed across identical runs"

    metadata = guard.metadata(
      all_commands: Hive::CLI.all_commands,
      command_map: Hive::CLI.map
    )
    assert_empty metadata.diagnostics, metadata.diagnostics.map(&:to_s).join("\n")
    assert_equal metadata.visible, first.help_commands.sort
    assert_empty metadata.hidden & first.help_commands
    assert_empty metadata.hidden & first.index_commands

    assert_includes first.help_commands, "help"
    assert_includes first.help_commands, "tree"
    assert_equal "commands/help", first.owners.fetch("help")
    assert_equal "commands/tree", first.owners.fetch("tree")
    assert_equal "commands/stage_action", first.owners.fetch("review")
    assert_equal "modules/plan_review", first.owners.fetch("plan-review")
    assert_equal "modules/plan_review", first.owners.fetch("plan-review-run")
    assert_equal "modules/worktree", first.owners.fetch("worktree")

    assert_equal "open-pr", metadata.aliases.fetch("pr")
    assert_equal "version", metadata.aliases.fetch("--version")
    assert_equal "version", metadata.aliases.fetch("-v")
    %w[pr --version -v].each do |alias_name|
      refute_includes first.index_commands, alias_name
    end

    assert_equal before, repository_snapshot,
      "public help or the command-index guard modified the repository"
  end

  def test_repository_snapshot_covers_tracked_untracked_and_ignored_files
    Dir.mktmpdir("wiki-command-index-repository") do |root|
      File.write(File.join(root, ".gitignore"), "ignored.txt\n")
      File.write(File.join(root, "tracked.txt"), "tracked\n")
      File.write(File.join(root, "untracked.txt"), "untracked\n")
      File.write(File.join(root, "ignored.txt"), "ignored\n")
      _stdout, stderr, status = Open3.capture3("git", "init", "--quiet", chdir: root)
      assert status.success?, stderr
      _stdout, stderr, status = Open3.capture3(
        "git", "add", ".gitignore", "tracked.txt", chdir: root
      )
      assert status.success?, stderr

      before = repository_snapshot(root)
      assert_equal %w[.gitignore ignored.txt tracked.txt untracked.txt], before.map(&:first)

      File.write(File.join(root, "ignored.txt"), "changed\n")
      refute_equal before, repository_snapshot(root)
    end
  end

  private

  def render_public_help
    Dir.mktmpdir("hive-public-help") do |sandbox|
      home = File.join(sandbox, "home")
      hive_home = File.join(sandbox, "hive")
      xdg = %w[config data state cache bin].to_h do |kind|
        [ kind, File.join(sandbox, "xdg", kind) ]
      end
      ([ home, hive_home ] + xdg.values).each { |path| FileUtils.mkdir_p(path) }

      environment = {
        "HOME" => home,
        "HIVE_HOME" => hive_home,
        "HIVE_WORKTREE_BASE" => File.join(sandbox, "worktrees"),
        "XDG_CONFIG_HOME" => xdg.fetch("config"),
        "XDG_DATA_HOME" => xdg.fetch("data"),
        "XDG_STATE_HOME" => xdg.fetch("state"),
        "XDG_CACHE_HOME" => xdg.fetch("cache"),
        "XDG_BIN_HOME" => xdg.fetch("bin"),
        "CLAUDE_CONFIG_DIR" => File.join(sandbox, "claude"),
        "CODEX_HOME" => File.join(sandbox, "codex"),
        "PI_CODING_AGENT_DIR" => File.join(sandbox, "pi"),
        "GH_CONFIG_DIR" => File.join(sandbox, "gh"),
        "GIT_CONFIG_GLOBAL" => File.join(sandbox, "gitconfig"),
        # HOME is deliberately disposable, so preserve the already activated
        # bundle's exact gem search path instead of falling back to that empty
        # home's RubyGems user directory.
        "GEM_HOME" => Gem.dir,
        "GEM_PATH" => Gem.path.join(File::PATH_SEPARATOR),
        "HIVE_SKIP_LLM_WIKI_SCHEDULER" => "1",
        "HIVE_SKIP_LLM_WIKI_SYSTEMCTL" => "1",
        "HIVE_SKIP_LLM_WIKI_POST_COMMIT" => "1",
        "HIVE_ATTEMPT_INTERNAL" => nil,
        "NO_COLOR" => "1",
        "TERM" => "dumb",
        "COLUMNS" => "40"
      }

      Open3.capture3(
        environment,
        RbConfig.ruby,
        File.join(ROOT, "bin/hive"),
        "help",
        chdir: ROOT
      )
    end
  end

  def repository_snapshot(root = ROOT)
    repository_paths(root).map do |relative|
      path = File.join(root, relative)
      begin
        stat = File.lstat(path)
        digest = if stat.symlink?
          Digest::SHA256.hexdigest(File.readlink(path))
        elsif stat.file?
          Digest::SHA256.file(path).hexdigest
        else
          stat.ftype
        end
        [ relative, stat.mode, stat.size, stat.mtime.to_r, digest ]
      rescue Errno::ENOENT
        [ relative, :missing ]
      end
    end
  end

  def repository_paths(root = ROOT)
    commands = [
      [ "git", "ls-files", "--cached", "--others", "--exclude-standard", "-z" ],
      [ "git", "ls-files", "--others", "--ignored", "--exclude-standard", "-z" ]
    ]
    commands.flat_map do |command|
      stdout, stderr, status = Open3.capture3(*command, chdir: root)
      raise "#{command.join(' ')} failed: #{stderr}" unless status.success?
      stdout.split("\0")
    end.sort
  end
end
