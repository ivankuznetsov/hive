require "test_helper"
require "fileutils"
require "open3"
require "thread"
require "hive/commands/adhoc_review"
require "hive/internal_pr_checkout"

class AdhocReviewCommandTest < Minitest::Test
  include HiveTestHelper

  class Barrier
    def initialize(count)
      @count = count
      @arrived = 0
      @mutex = Mutex.new
      @cv = ConditionVariable.new
    end

    def wait
      @mutex.synchronize do
        @arrived += 1
        if @arrived >= @count
          @cv.broadcast
        else
          @cv.wait(@mutex) while @arrived < @count
        end
      end
    end
  end

  def metadata(number: 197, head:, fork: false, head_ref_name: "feature/demo", head_repository: nil)
    Hive::Gh::PrMetadata.new(
      number: number,
      url: "https://github.com/o/r/pull/#{number}",
      base_ref_name: "main",
      head_ref_oid: head,
      is_cross_repository: fork,
      state: "OPEN",
      is_draft: false,
      head_ref_name: head_ref_name,
      head_repository: head_repository || (fork ? "contributor/r" : "o/r"),
      host: "github.com",
      repository: "o/r"
    )
  end

  def with_registered_pr_repo(pr_number: 197)
    with_tmp_global_config do
      with_tmp_dir do |root|
        remote = File.join(root, "remote.git")
        repo = File.join(root, "repo")
        worktree_root = File.join(root, "adhoc-worktrees")
        git(root, "init", "--bare", remote)
        git(root, "clone", remote, repo)
        git(repo, "config", "user.name", "Test")
        git(repo, "config", "user.email", "test@example.com")

        File.write(File.join(repo, "app.rb"), "puts 'base'\n")
        git(repo, "add", ".")
        git(repo, "commit", "-m", "base")
        git(repo, "branch", "-M", "main")
        git(repo, "push", "-u", "origin", "main")

        git(repo, "checkout", "-b", "pr-branch")
        File.write(File.join(repo, "app.rb"), "puts 'pr-#{pr_number}'\n")
        git(repo, "add", ".")
        git(repo, "commit", "-m", "PR #{pr_number}")
        head_oid = git(repo, "rev-parse", "HEAD").strip
        git(repo, "push", "origin", "#{head_oid}:refs/pull/#{pr_number}/head")
        git(repo, "checkout", "main")
        git(repo, "branch", "-D", "pr-branch")

        hive_state = File.join(repo, ".hive-state")
        FileUtils.mkdir_p(File.join(hive_state, "stages", "6-review"))
        File.write(File.join(hive_state, "config.yml"), { "worktree_root" => worktree_root }.to_yaml)
        Hive::Config.register_project(name: "demo", path: repo)
        Dir.chdir(repo) { yield(repo, hive_state, worktree_root, head_oid, remote) }
      end
    end
  end

  def stub_gh(value_or_proc)
    gh = Object.new
    gh.define_singleton_method(:validated_pr_metadata) do |*args, **kwargs|
      if value_or_proc.respond_to?(:call)
        value_or_proc.call(*args, **kwargs)
      elsif value_or_proc.is_a?(Exception)
        raise value_or_proc
      else
        value_or_proc
      end
    end
    gh
  end

  def frontmatter(path)
    Hive::Gh.pr_frontmatter(path)
  end

  def write_frontmatter(path, data)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#{data.to_yaml}---\n\nbody\n")
  end

  def test_new_creation_persists_canonical_head_oid_generation_one_fork_metadata_and_reuse_delegates_to_domain
    with_registered_pr_repo(pr_number: 197) do |repo, hive_state, worktree_root, head_oid, _remote|
      now = Time.utc(2026, 8, 29, 12, 0, 0)
      pr_meta = metadata(number: 197, head: head_oid, fork: true, head_ref_name: "fork-fix", head_repository: "alice/r")
      gh_calls = 0
      gh = stub_gh(lambda { |*_args, **_kwargs|
        gh_calls += 1
        pr_meta
      })

      first = Hive::Commands::AdhocReview.new(pr: "#197", gh: gh, allow_local_transport: true).enqueue(now: now)
      second = Hive::Commands::AdhocReview.new(pr: "https://github.com/o/r/pull/197", gh: gh, allow_local_transport: true).enqueue(now: now)
      called_slug = Hive::Commands::AdhocReview.new(pr: "197", gh: gh, allow_local_transport: true).call

      assert_equal "adhoc-review-pr-197", first.fetch(:slug)
      assert_equal "adhoc-review-pr-197", second.fetch(:slug)
      assert_equal "adhoc-review-pr-197", called_slug
      assert_equal false, first.fetch(:reused)
      assert_equal true, second.fetch(:reused)
      assert_equal 1, gh_calls, "reuse must return task identity without repeating creation fetch"
      assert_equal 2, Hive::TaskCounter.peek, "reuse must not allocate another task ID"

      task_folder = File.join(hive_state, "stages", "6-review", "adhoc-review-pr-197")
      worktree_path = File.join(worktree_root, "adhoc-review-pr-197")

      pr = frontmatter(File.join(task_folder, "pr.md"))
      assert_equal "ad-hoc", pr.fetch("source")
      assert_equal 197, pr.fetch("pr_number")
      assert_equal "https://github.com/o/r/pull/197", pr.fetch("pr_url")
      assert_equal "main", pr.fetch("base_ref_name")
      assert_equal head_oid, pr.fetch("head_oid")
      refute pr.key?("head_ref_oid"), "canonical creation must emit head_oid only"
      assert_equal true, pr.fetch("is_cross_repository")
      assert_equal "fork-fix", pr.fetch("head_ref_name")
      assert_equal "alice/r", pr.fetch("head_repository")
      assert_equal "OPEN", pr.fetch("state")

      wt_yml = YAML.safe_load_file(File.join(task_folder, "worktree.yml"))
      assert_equal worktree_path, wt_yml.fetch("path")
      assert_equal "hive/review/pr-197", wt_yml.fetch("branch")
      assert_equal head_oid, wt_yml.fetch("execute_base_head")
      assert_equal "main", wt_yml.fetch("base_branch")
      assert_equal head_oid, git(worktree_path, "rev-parse", "HEAD").strip

      # Generation 1 initialized cleanly in controller-owned store!
      store = Hive::InternalPrCheckout::Store.new(task_folder)
      current = store.read_current
      assert_equal 1, current.fetch("generation")
      assert_equal head_oid, current.fetch("reviewed_oid")
      assert_equal head_oid, current.fetch("candidate_oid")
      assert_nil current["head_transition_digest"]
      assert_equal true, current.fetch("is_cross_repository")
      assert_equal "fork-fix", current.fetch("head_ref_name")
      assert_equal "alice/r", current.fetch("head_repository")
      assert store.verify_history_integrity!

      # Quarantine ref cleaned up; no lingering claim file.
      assert_empty git(repo, "for-each-ref", "refs/hive/internal-pr-checkout/").strip
      refute File.exist?(File.join(hive_state, ".adhoc-review-claims", "adhoc-review-pr-197.json"))

      # Reuse does NOT enforce checkout policy (e.g. if worktree is deleted,
      # AdhocReview still returns the owned task so U2 reports pointer_unowned).
      FileUtils.rm_rf(worktree_path)
      reused = Hive::Commands::AdhocReview.new(pr: "197", gh: gh, allow_local_transport: true).enqueue(now: now)
      assert_equal true, reused.fetch(:reused)
      assert_equal "adhoc-review-pr-197", reused.fetch(:slug)
    end
  end

  def test_concurrent_first_opens_race_at_claim_barrier_and_during_materialization
    with_registered_pr_repo(pr_number: 197) do |repo, hive_state, worktree_root, head_oid, _remote|
      pr_meta = metadata(number: 197, head: head_oid)
      gh = stub_gh(pr_meta)

      # Race 1: two threads hit a barrier right before the claim lock;
      # winner creates once, loser waits and reuses winner!
      barrier1 = Barrier.new(2)
      fp = ->(phase, _ctx) { barrier1.wait if phase == :before_claim_lock }
      threads = 2.times.map do
        Thread.new do
          Hive::Commands::AdhocReview.new(
            pr: "197", gh: gh, allow_local_transport: true, failpoint: fp
          ).enqueue
        end
      end
      results = threads.map(&:value)
      assert_equal %w[false true], results.map { |r| r.fetch(:reused).to_s }.sort
      assert_equal 2, Hive::TaskCounter.peek, "concurrent opens must allocate exactly one task ID"
      task_folder = File.join(hive_state, "stages", "6-review", "adhoc-review-pr-197")
      assert_equal 1, Hive::InternalPrCheckout::Store.new(task_folder).read_current.fetch("generation")
      assert_equal head_oid, git(File.join(worktree_root, "adhoc-review-pr-197"), "rev-parse", "HEAD").strip

      # Race 2: winner pauses during materialization while loser arrives;
      # loser failure (short timeout) MUST NOT clean up winner's resources!
      # Reset for a fresh PR #198 in same repo.
      git(repo, "push", "origin", "#{head_oid}:refs/pull/198/head")
      pr_meta_198 = metadata(number: 198, head: head_oid)
      gh198 = stub_gh(pr_meta_198)
      in_materialize = Queue.new
      release_owner = Queue.new

      owner_thread = Thread.new do
        Hive::Commands::AdhocReview.new(
          pr: "198",
          gh: gh198,
          allow_local_transport: true,
          failpoint: lambda { |phase, _ctx|
            if phase == :after_materialize
              in_materialize << true
              release_owner.pop
            end
          }
        ).enqueue
      end

      in_materialize.pop
      # Loser fails with ConcurrentRunError after short wait; must leave winner's worktree intact!
      assert_raises(Hive::ConcurrentRunError) do
        Hive::Commands::AdhocReview.new(
          pr: "198", gh: gh198, allow_local_transport: true, claim_wait_timeout: 0.06
        ).enqueue
      end
      assert Dir.exist?(File.join(worktree_root, "adhoc-review-pr-198")),
             "loser failure must never remove the active owner's worktree"

      release_owner << true
      winner_res = owner_thread.value
      assert_equal false, winner_res.fetch(:reused)
      assert_equal head_oid, git(File.join(worktree_root, "adhoc-review-pr-198"), "rev-parse", "HEAD").strip
    end
  end

  def test_owner_failure_rolls_back_only_owned_resources_and_retry_succeeds
    with_registered_pr_repo(pr_number: 197) do |repo, hive_state, worktree_root, head_oid, _remote|
      pr_meta = metadata(number: 197, head: head_oid)
      gh = stub_gh(pr_meta)
      boom = Class.new(Hive::Error)

      assert_raises(boom) do
        Hive::Commands::AdhocReview.new(
          pr: "197",
          gh: gh,
          allow_local_transport: true,
          failpoint: ->(phase, _ctx) { raise boom, "crash before publish" if phase == :before_publish }
        ).enqueue
      end

      task_folder = File.join(hive_state, "stages", "6-review", "adhoc-review-pr-197")
      worktree_path = File.join(worktree_root, "adhoc-review-pr-197")
      refute Dir.exist?(task_folder)
      refute Dir.exist?(worktree_path)
      refute Hive::Worktree.local_branch_ref_exists?(repo, "hive/review/pr-197")
      assert_empty git(repo, "for-each-ref", "refs/hive/internal-pr-checkout/").strip
      refute File.exist?(File.join(hive_state, ".adhoc-review-claims", "adhoc-review-pr-197.json"))

      # Retry succeeds cleanly with intact generation 1.
      res = Hive::Commands::AdhocReview.new(pr: "197", gh: gh, allow_local_transport: true).enqueue
      assert_equal false, res.fetch(:reused)
      assert Dir.exist?(task_folder)
      assert_equal 1, Hive::InternalPrCheckout::Store.new(task_folder).read_current.fetch("generation")
    end
  end

  def test_preexisting_unexplained_worktree_or_branch_blocks_without_deleting_it
    with_registered_pr_repo(pr_number: 197) do |repo, hive_state, worktree_root, head_oid, _remote|
      wt_path = File.join(worktree_root, "adhoc-review-pr-197")
      FileUtils.mkdir_p(wt_path)
      File.write(File.join(wt_path, "precious.txt"), "do not delete\n")

      gh = stub_gh(metadata(number: 197, head: head_oid))
      err = assert_raises(Hive::WorktreeError) do
        Hive::Commands::AdhocReview.new(pr: "197", gh: gh, allow_local_transport: true).enqueue
      end
      assert_match(/unexplained preexisting worktree/, err.message)
      assert_equal "do not delete\n", File.read(File.join(wt_path, "precious.txt"))
      refute Dir.exist?(File.join(hive_state, "stages", "6-review", "adhoc-review-pr-197"))
      FileUtils.rm_rf(wt_path)

      # Preexisting branch also blocks without deleting it!
      git(repo, "branch", "hive/review/pr-197", "HEAD")
      err2 = assert_raises(Hive::WorktreeError) do
        Hive::Commands::AdhocReview.new(pr: "197", gh: gh, allow_local_transport: true).enqueue
      end
      assert_match(/unexplained preexisting branch/, err2.message)
      assert Hive::Worktree.local_branch_ref_exists?(repo, "hive/review/pr-197")
    end
  end

  def test_missing_provider_head_fails_closed_with_no_published_result
    with_registered_pr_repo(pr_number: 197) do |repo, hive_state, worktree_root, _head_oid, _remote|
      bad_meta = metadata(number: 197, head: "")
      gh = stub_gh(bad_meta)
      assert_raises(Hive::GhError) do
        Hive::Commands::AdhocReview.new(pr: "197", gh: gh, allow_local_transport: true).enqueue
      end
      refute Dir.exist?(File.join(hive_state, "stages", "6-review", "adhoc-review-pr-197"))
      refute Dir.exist?(File.join(worktree_root, "adhoc-review-pr-197"))
      refute Hive::Worktree.local_branch_ref_exists?(repo, "hive/review/pr-197")
    end
  end

  def test_collision_guards_refuse_wrong_source_wrong_pr_other_stage_and_unreadable_identity_sidecar
    with_registered_pr_repo(pr_number: 197) do |_repo, hive_state, _worktree_root, head_oid, _remote|
      gh = stub_gh(metadata(number: 197, head: head_oid))

      # 1. Wrong task source at same deterministic slug
      slug_dir = File.join(hive_state, "stages", "6-review", "adhoc-review-pr-197")
      write_frontmatter(File.join(slug_dir, "pr.md"), "pr_number" => 197, "pr_url" => "https://github.com/o/r/pull/197", "source" => "telegram")
      err = assert_raises(Hive::Commands::AdhocReview::CollisionError) do
        Hive::Commands::AdhocReview.new(pr: "197", gh: gh, allow_local_transport: true).enqueue
      end
      assert_match(/not an ad-hoc review for PR #197/, err.message)

      # 2. Wrong PR number at same deterministic slug
      write_frontmatter(File.join(slug_dir, "pr.md"), "pr_number" => 198, "pr_url" => "https://github.com/o/r/pull/198", "source" => "ad-hoc")
      err = assert_raises(Hive::Commands::AdhocReview::CollisionError) do
        Hive::Commands::AdhocReview.new(pr: "197", gh: gh, allow_local_transport: true).enqueue
      end
      assert_match(/pr_number=198/, err.message)

      # 3. Unreadable / missing pr.md at deterministic slug
      File.unlink(File.join(slug_dir, "pr.md"))
      err = assert_raises(Hive::Commands::AdhocReview::CollisionError) do
        Hive::Commands::AdhocReview.new(pr: "197", gh: gh, allow_local_transport: true).enqueue
      end
      assert_match(/missing pr\.md/, err.message)
      FileUtils.rm_rf(slug_dir)

      # 4. Same slug occupied in another stage
      other_stage = File.join(hive_state, "stages", "7-artifacts", "adhoc-review-pr-197")
      FileUtils.mkdir_p(other_stage)
      err = assert_raises(Hive::Commands::AdhocReview::CollisionError) do
        Hive::Commands::AdhocReview.new(pr: "197", gh: gh, allow_local_transport: true).enqueue
      end
      assert_match(/adhoc-review-pr-197 at 7-artifacts/, err.message)
      FileUtils.rm_rf(other_stage)

      # 5. Different task owning PR 197
      write_frontmatter(
        File.join(hive_state, "stages", "5-open-pr", "owned-task", "pr.md"),
        "pr_number" => 197, "pr_url" => "https://github.com/o/r/pull/197"
      )
      err = assert_raises(Hive::Commands::AdhocReview::CollisionError) do
        Hive::Commands::AdhocReview.new(pr: "197", gh: gh, allow_local_transport: true).enqueue
      end
      assert_match(/owned by hive task owned-task at 5-open-pr/, err.message)
    end
  end

  def test_invalid_pr_identifier_maps_to_usage_error
    with_registered_pr_repo(pr_number: 197) do
      err = assert_raises(Hive::InvalidTaskPath) do
        Hive::Commands::AdhocReview.new(pr: "not-a-pr", allow_local_transport: true).enqueue
      end
      assert_match(/invalid PR identifier/, err.message)
    end
  end

  def test_source_casing_drift_reuses_and_preserves_id_counter
    with_registered_pr_repo(pr_number: 197) do |_repo, hive_state, _worktree_root, head_oid, _remote|
      slug = "adhoc-review-pr-197"
      folder = File.join(hive_state, "stages", "6-review", slug)
      write_frontmatter(
        File.join(folder, "pr.md"),
        "pr_number" => 197, "source" => "Ad-Hoc", "pr_url" => "https://github.com/o/r/pull/197", "head_oid" => head_oid
      )
      gh = stub_gh(->(*_args, **_kwargs) { flunk "reuse must not query gh" })
      res = Hive::Commands::AdhocReview.new(pr: "197", gh: gh, allow_local_transport: true).enqueue
      assert_equal slug, res.fetch(:slug)
      assert_equal true, res.fetch(:reused)
    end
  end

  private

  def git(dir, *args)
    out, err, status = Open3.capture3("git", "-C", dir, *args)
    raise "git #{args.join(' ')} failed: #{err}" unless status.success?

    out
  end
end
