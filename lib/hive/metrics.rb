require "open3"

module Hive
  # Rollback-rate metric for hive fix-agent commits (ADR-020 / U14).
  #
  # Each fix-agent (Phase 4 review-fix and Phase 1 ci-fix) commits with
  # the trailers documented in templates/fix_prompt.md.erb and
  # templates/ci_fix_prompt.md.erb:
  #
  #   Hive-Task-Slug:        <slug>
  #   Hive-Fix-Pass:         <NN>
  #   Hive-Fix-Findings:     <count of [x] items applied>   (review-fix only)
  #   Hive-Triage-Bias:      <courageous|safetyist|custom>  (review-fix only)
  #   Hive-Reviewer-Sources: <comma-separated reviewer names> (review-fix only)
  #   Hive-Fix-Phase:        <ci|fix>
  #
  # `Metrics.rollback_rate(project_root, since:)` walks
  # `git log --since=<N days ago>` for every commit whose body matches
  # `^Hive-Fix-Pass:\s+\d+` and reports how many were later reverted by
  # a `Revert "..."` follower commit on the same branch lineage.
  #
  # A "high" rollback rate (informally >15-20%) signals the triage bias
  # is too courageous for the project; a low rate validates that the
  # autonomous loop is paying off. Closes doc-review PL-2.
  module Metrics
    module_function

    # Returns:
    #   {
    #     total_fix_commits: N,
    #     reverted_commits:  M,
    #     rollback_rate:     M/N (Float, 0.0 when N == 0),
    #     by_bias: { "courageous" => {total:, reverted:, rate:}, ... },
    #     by_phase: { "ci" => {total:, reverted:}, "fix" => {total:, reverted:} },
    #     since: <ISO8601 cutoff>,
    #     project_root: <abs path>
    #   }
    def rollback_rate(project_root, since: nil)
      raise ArgumentError, "project_root #{project_root.inspect} is not a directory" unless File.directory?(project_root)

      log_args = [ "git", "-C", project_root, "log", "--all", "--format=%H%x00%s%x00%b%x00%x01" ]
      log_args.concat([ "--since", since.to_s ]) if since

      out, _err, status = Open3.capture3(*log_args)
      raise Error, "git log failed in #{project_root}" unless status.success?

      commits = parse_commits(out)
      fix_commits = commits.select { |c| c[:trailers]["hive-fix-pass"] }
      revert_subjects = collect_revert_subjects(commits)
      revert_shas = collect_revert_shas(commits)

      reverted_count = 0
      by_bias = Hash.new { |h, k| h[k] = { total: 0, reverted: 0 } }
      by_phase = Hash.new { |h, k| h[k] = { total: 0, reverted: 0 } }

      fix_commits.each do |c|
        bias = c[:trailers]["hive-triage-bias"] || "unknown"
        phase = c[:trailers]["hive-fix-phase"] || "fix"
        was_reverted = reverted?(c, revert_subjects, revert_shas)

        by_bias[bias][:total] += 1
        by_phase[phase][:total] += 1
        if was_reverted
          reverted_count += 1
          by_bias[bias][:reverted] += 1
          by_phase[phase][:reverted] += 1
        end
      end

      total = fix_commits.size
      {
        total_fix_commits: total,
        reverted_commits: reverted_count,
        rollback_rate: total.zero? ? 0.0 : (reverted_count.to_f / total).round(4),
        by_bias: by_bias.transform_values { |h| h.merge(rate: rate_of(h)) },
        by_phase: by_phase.transform_values { |h| h.merge(rate: rate_of(h)) },
        since: since,
        project_root: File.expand_path(project_root)
      }
    end

    # Each commit comes back as <sha>\0<subject>\0<body>\0\x01.
    # The trailing \x01 separator lets us split a body that itself
    # contains newlines without confusing record boundaries.
    def parse_commits(raw)
      raw.split("\x01\n").reject(&:empty?).map do |chunk|
        sha, subject, body = chunk.sub(/\A\n/, "").split("\x00", 3)
        next if sha.nil? || sha.empty?

        {
          sha: sha,
          subject: subject.to_s,
          body: body.to_s,
          trailers: parse_trailers(body.to_s)
        }
      end.compact
    end

    # Lightweight trailer parser: any line of the form `Hive-Foo: bar`
    # near the end of the body. Keys are downcased; values are stripped.
    # We don't shell out to `git interpret-trailers` because hive may
    # be invoked from inside a worktree where running another git
    # subprocess per commit blows up wall time on large histories.
    def parse_trailers(body)
      return {} if body.nil? || body.empty?

      trailers = {}
      body.each_line do |line|
        if (m = line.match(/\A([A-Za-z][A-Za-z0-9-]*):\s*(.+?)\s*\z/))
          trailers[m[1].downcase] = m[2]
        end
      end
      trailers
    end

    # Subjects of every Revert commit, e.g. `Revert "feat(x): foo"`.
    # We collect the inner subject so a fix commit's subject can be
    # matched against it.
    def collect_revert_subjects(commits)
      commits.each_with_object({}) do |c, acc|
        if (m = c[:subject].match(/\ARevert "(.+)"\z/))
          acc[m[1]] ||= []
          acc[m[1]] << c[:sha]
        end
      end
    end

    # SHAs cited inside Revert commit bodies (`This reverts commit
    # <sha>.`). Both the short and full SHA forms are stored.
    def collect_revert_shas(commits)
      commits.each_with_object({}) do |c, acc|
        next unless c[:subject].start_with?("Revert ")

        c[:body].scan(/This reverts commit ([0-9a-f]{7,40})/) do |sha,|
          acc[sha] ||= []
          acc[sha] << c[:sha]
        end
      end
    end

    # A fix commit is "reverted" if any later commit (anywhere in the
    # log) has a Revert subject quoting this commit's subject, OR a
    # `This reverts commit <sha>` body referencing this commit's sha.
    # We don't try to be clever about same-branch lineage in v1 — git
    # log --all is the simplest correct domain, and a stray Revert
    # cross-branch is a rare-enough false positive that the metric
    # remains informative.
    def reverted?(commit, revert_subjects, revert_shas)
      return true if revert_subjects.key?(commit[:subject])

      sha = commit[:sha]
      # Match only the prefix direction: a Revert that cites our sha
      # (`This reverts commit <sha-or-prefix>`) reverts us. The
      # symmetric `cited.start_with?(sha[0, 7])` clause used to fire
      # whenever the cited sha and our sha shared their first 7 chars
      # — a false positive any time two unrelated commits collide on a
      # short hash. Drop it.
      revert_shas.each_key do |cited|
        return true if sha.start_with?(cited)
      end
      false
    end

    def rate_of(bucket)
      bucket[:total].zero? ? 0.0 : (bucket[:reverted].to_f / bucket[:total]).round(4)
    end
  end
end
