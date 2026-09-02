# frozen_string_literal: true

require "test_helper"
require "find"
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
    rendered_aliases = first.help_commands & metadata.aliases.keys
    assert_equal metadata.visible, (first.help_commands - rendered_aliases).sort
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
    metadata.aliases.each do |alias_name, canonical|
      if first.help_commands.include?(alias_name)
        assert_includes first.index_commands, alias_name
        assert_equal first.owners.fetch(canonical), first.owners.fetch(alias_name)
      else
        refute_includes first.index_commands, alias_name
      end
    end

    canonical_version = render_hive("version")
    [ "--version", "-v" ].each do |wrapper_alias|
      assert_equal canonical_version, render_hive(wrapper_alias),
        "bin/hive #{wrapper_alias} diverged from the version command"
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
      %w[.gitignore ignored.txt tracked.txt untracked.txt].each do |relative|
        assert_includes before.map(&:first), relative
      end

      File.write(File.join(root, "ignored.txt"), "changed\n")
      refute_equal before, repository_snapshot(root)

      before = repository_snapshot(root)
      FileUtils.mkdir_p(File.join(root, "empty"))
      refute_equal before, repository_snapshot(root)

      FileUtils.rmdir(File.join(root, "empty"))
      before = repository_snapshot(root)
      transient = File.join(root, "transient.txt")
      File.write(transient, "transient\n")
      File.unlink(transient)
      refute_equal before, repository_snapshot(root)

      before = repository_snapshot(root)
      _stdout, stderr, status = Open3.capture3(
        "git", "config", "wiki-command-index.probe", "changed", chdir: root
      )
      assert status.success?, stderr
      refute_equal before, repository_snapshot(root)
    end
  end

  private

  def render_public_help
    render_hive("help")
  end

  def render_hive(*argv)
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
        # The read-only assertion snapshots ignored files too. A coverage
        # instrumented child would write its own resultset into this checkout.
        "HIVE_COVERAGE" => nil,
        "HIVE_COVERAGE_ROOT" => nil,
        "HIVE_COVERAGE_RUN_ID" => nil,
        "RUBYOPT" => nil,
        "HIVE_SKIP_LLM_WIKI_SCHEDULER" => "1",
        "HIVE_SKIP_LLM_WIKI_SYSTEMCTL" => "1",
        "HIVE_SKIP_LLM_WIKI_POST_COMMIT" => "1",
        "HIVE_ATTEMPT_INTERNAL" => nil,
        "NO_COLOR" => "1",
        "TERM" => "dumb",
        # Thor pads and then truncates usage banners to the terminal width.
        # Forty columns is the narrowest pinned width that preserves complete
        # command tokens while still exercising wrapped descriptions.
        "COLUMNS" => "40"
      }

      Open3.capture3(
        environment,
        RbConfig.ruby,
        File.join(ROOT, "bin/hive"),
        *argv,
        chdir: ROOT
      )
    end
  end

  def repository_snapshot(root = ROOT)
    repository_paths(root).map do |path|
      relative = path == root ? "." : path.delete_prefix("#{root}/")
      begin
        stat = File.lstat(path)
        digest = if stat.symlink?
          Digest::SHA256.hexdigest(File.readlink(path))
        elsif stat.file?
          Digest::SHA256.file(path).hexdigest
        else
          stat.ftype
        end
        [ relative, stat.ftype, stat.mode, stat.size, stat.mtime.to_r, stat.ctime.to_r, digest ]
      rescue Errno::ENOENT
        [ relative, :missing ]
      end
    end
  end

  def repository_paths(root = ROOT)
    paths = []
    Find.find(root) do |path|
      if path == File.join(root, ".git")
        paths << path
        Find.prune
      else
        paths << path
      end
    end
    paths.concat(git_control_paths(root)).uniq.sort
  end

  def git_control_paths(root)
    stdout, _stderr, status = Open3.capture3(
      "git", "rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir", chdir: root
    )
    return [] unless status.success?

    worktree_dir, common_dir = stdout.lines.map(&:strip)
    paths = %w[HEAD index commondir gitdir config.worktree].map { |name| File.join(worktree_dir, name) }
    paths.concat(%w[config packed-refs refs].map { |name| File.join(common_dir, name) })
    refs = File.join(common_dir, "refs")
    Find.find(refs) { |path| paths << path } if File.directory?(refs)
    paths
  end
end
