require "open3"

module Hive
  module Metrics
    module_function

    def rollback_rate(project_root, since: nil)
      raise ArgumentError, "project_root #{project_root.inspect} is not a directory" unless
        File.directory?(project_root)

      argv = [ "git", "-C", project_root, "log", "--all", "--format=%H%x00%s%x00%b%x00%x01" ]
      argv.concat([ "--since", since.to_s ]) if since
      out, _err, status = Open3.capture3(*argv)
      raise Error, "git log failed in #{project_root}" unless status.success?

      commits = parse_commits(out)
      fixes = commits.select { |commit| commit[:trailers]["hive-fix-pass"] }
      subjects = collect_revert_subjects(commits)
      shas = collect_revert_shas(commits)
      by_bias = buckets
      by_phase = buckets
      reverted = fixes.count do |commit|
        rolled_back = reverted?(commit, subjects, shas)
        count!(by_bias, commit[:trailers]["hive-triage-bias"] || "unknown", rolled_back)
        count!(by_phase, commit[:trailers]["hive-fix-phase"] || "fix", rolled_back)
        rolled_back
      end
      {
        "total_fix_commits" => fixes.size,
        "reverted_commits" => reverted,
        "rollback_rate" => rate(reverted, fixes.size),
        "by_bias" => rates(by_bias),
        "by_phase" => rates(by_phase),
        "since" => since,
        "project_root" => File.expand_path(project_root)
      }
    end

    def parse_commits(raw)
      raw.split("\x01\n").filter_map do |chunk|
        sha, subject, body = chunk.sub(/\A\n/, "").split("\x00", 3)
        next if sha.to_s.empty?

        { sha: sha, subject: subject.to_s, body: body.to_s, trailers: parse_trailers(body.to_s) }
      end
    end

    def parse_trailers(body)
      body.to_s.each_line.filter_map do |line|
        match = line.match(/\A([A-Za-z][A-Za-z0-9-]*):\s*(.+?)\s*\z/)
        [ match[1].downcase, match[2] ] if match
      end.to_h
    end

    def collect_revert_subjects(commits)
      commits.filter_map { |commit| commit[:subject][/\ARevert "(.+)"\z/, 1] }.to_h { |value| [ value, true ] }
    end

    def collect_revert_shas(commits)
      commits.select { |commit| commit[:subject].start_with?("Revert ") }
             .flat_map { |commit| commit[:body].scan(/This reverts commit ([0-9a-f]{7,40})/).flatten }
             .to_h { |sha| [ sha, true ] }
    end

    def reverted?(commit, revert_subjects, revert_shas)
      revert_subjects.key?(commit[:subject]) || revert_shas.any? { |sha,| commit[:sha].start_with?(sha) }
    end

    def buckets = Hash.new { |hash, key| hash[key] = { "total" => 0, "reverted" => 0 } }

    def count!(groups, key, reverted)
      groups[key]["total"] += 1
      groups[key]["reverted"] += 1 if reverted
    end

    def rates(groups)
      groups.transform_values do |counts|
        counts.merge("rate" => rate(counts["reverted"], counts["total"]))
      end
    end

    def rate(reverted, total) = total.zero? ? 0.0 : (reverted.to_f / total).round(4)
    def rate_of(bucket) = rate(bucket["reverted"], bucket["total"])
  end
end
