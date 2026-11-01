require "test_helper"
require "hive/review_publication_recovery"
require "hive/markers"

class ReviewPublicationRecoveryTest < Minitest::Test
  include HiveTestHelper
  Recovery = Hive::ReviewPublicationRecovery

  def test_readiness_is_conditional_and_commands_are_not_silently_redacted
    base = { "publication" => "published", "verification" => "pending", "pr_state" => "OPEN",
      "is_draft" => true, "ready_command" => "gh pr ready 42" }
    draft = Recovery.project(Recovery.encode(base))
    assert_includes draft["readiness_guidance"], "normal finalize"
    assert_includes draft["readiness_guidance"], "Manual ready requires"
    [ false, nil ].each do |state|
      refute Recovery.project(Recovery.encode(base.merge("is_draft" => state))).key?("ready_command")
    end
    refute Recovery.project(Recovery.encode(base.merge("pr_state" => "MERGED"))).key?("ready_command")
    hostile = Recovery.project(Recovery.encode("push_command" => "echo \e[31msecret"))
    assert_nil hostile["push_command"], "never turn a redacted command into a different executable command"
    unknown = Recovery.project({}, marker: "review_complete")
    assert_equal "unknown", unknown["publication"]
  end

  def test_lossless_marker_round_trip_for_commands_and_paths
    with_tmp_dir do |dir|
      path = File.join(dir, "state.md")
      File.write(path, "# Task\n")
      evidence = { "worktree" => "/tmp/a b;'\"$(false)",
                   "push_command" => "printf '%s' \"<!-- x -->\"",
                   "unpushed_shas" => [ "a" * 40, "b" * 40 ], "is_draft" => nil }
      Hive::Markers.set(path, :review_stale, reason: "final_fix_unverified", **Recovery.encode(evidence))
      marker = Hive::Markers.current(path)
      assert_equal evidence, Recovery.decode(marker.attrs)
      assert_equal "final_fix_unverified", marker.attrs["reason"]
    end
  end

  def test_commit_classification_uses_explicit_pr_reference_and_preserves_full_shas
    with_tmp_git_repo do |repo|
      base = run!("git", "-C", repo, "rev-parse", "HEAD").strip
      heads = 2.times.map do |n|
        File.write(File.join(repo, "fix"), n.to_s)
        run!("git", "-C", repo, "add", "fix")
        run!("git", "-C", repo, "commit", "-qm", "fix #{n}")
        run!("git", "-C", repo, "rev-parse", "HEAD").strip
      end
      result = Recovery.classify(worktree: repo, reference_oid: base)
      assert_equal "ahead", result["classification"]
      assert_equal heads, result["unpushed_shas"]
      unknown = Recovery.classify(worktree: repo, reference_oid: "e" * 40)
      assert_equal "unknown", unknown["classification"]
      assert_nil unknown["unpushed_shas"]
      assert_equal [ heads.last ], unknown["candidate_shas"]
    end
  end

  def test_recipe_executes_only_current_canonical_retry_for_exact_task
    with_tmp_dir do |dir|
      bin = File.join(dir, "bin")
      FileUtils.mkdir_p(bin)
      File.symlink(RbConfig.ruby, File.join(bin, "ruby"))
      fake = File.join(bin, "hive")
      File.write(fake, <<~'SH')
        #!/bin/sh
        if [ "$1" = status ]; then cat "$SNAPSHOT"; else ruby -rjson -e 'File.write(ENV.fetch("CAPTURE"), JSON.generate(ARGV))' -- "$@"; fi
      SH
      File.chmod(0o755, fake)
      snapshot = File.join(dir, "snapshot")
      capture = File.join(dir, "capture")
      action = { "action_id" => "workflow.retry", "target" => "app:task", "observation_token" => "a" * 64 }
      row = { "identity" => { "project" => "app", "slug" => "task" }, "action" => action }
      recipe = Recovery.retry_recipe(target: "app:task", worktree: dir)
      env = { "RUBYOPT" => nil, "RUBYLIB" => nil, "PATH" => "#{bin}:#{File.dirname(RbConfig.ruby)}:/usr/bin:/bin", "SNAPSHOT" => snapshot, "CAPTURE" => capture }
      ENV.keys.grep(/\ABUNDL/).each { |key| env[key] = nil }
      File.write(snapshot, JSON.generate("ok" => true, "tasks" => [ row ]))
      _out, err, status = Open3.capture3(env, "/usr/bin/bash", "-c", recipe)
      assert status.success?, err
      assert_equal [ "act", "workflow.retry", "app:task", "--observation", "a" * 64, "--json" ], JSON.parse(File.read(capture))
      File.unlink(capture)
      row["action"] = action.merge("action_id" => "workflow.advance")
      File.write(snapshot, JSON.generate("ok" => true, "tasks" => [ row ]))
      _out, _err, status = Open3.capture3(env, "/usr/bin/bash", "-c", recipe)
      refute status.success?
      refute File.exist?(capture)
    end
  end
end
