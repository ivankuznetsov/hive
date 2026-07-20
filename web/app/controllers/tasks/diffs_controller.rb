require "tempfile"

class Tasks::DiffsController < Tasks::BaseController
  DIFF_TIMEOUT_SEC = Integer(ENV.fetch("HIVEBOX_DIFF_TIMEOUT_SEC", 15))
  DIFF_MAX_BYTES = 512 * 1024

  before_action :load_task

  def show
    worktree = @task.worktree_path
    raise Hive::InvalidTaskPath, "no worktree for #{params[:slug]}" if worktree.empty? || !File.directory?(worktree)

    @diff, @diff_truncated = bounded_diff(worktree)
    render "tasks/diff"
  end

  private

  def bounded_diff(worktree)
    log = Tempfile.create("hivebox-diff")
    pid = Process.spawn("git", "-C", worktree, "diff", "--",
                        pgroup: true, out: log.path, err: log.path)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + DIFF_TIMEOUT_SEC
    status = wait_for_diff(pid, deadline)
    raise Hive::Error, "git diff failed: #{File.read(log.path).strip}" unless status.success?

    out = File.open(log.path, "rb") { |file| file.read(DIFF_MAX_BYTES + 1) }.to_s.force_encoding(Encoding::UTF_8).scrub
    truncated = out.bytesize > DIFF_MAX_BYTES
    [ truncated ? out.byteslice(0, DIFF_MAX_BYTES).scrub : out, truncated ]
  ensure
    log&.close
    File.unlink(log.path) if log && File.exist?(log.path)
  end

  def wait_for_diff(pid, deadline)
    loop do
      _, status = Process.waitpid2(pid, Process::WNOHANG)
      return status if status

      if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        Process.kill("KILL", -pid) rescue nil
        Process.waitpid2(pid) rescue nil
        raise Hive::Error, "git diff timed out after #{DIFF_TIMEOUT_SEC}s"
      end
      sleep 0.1
    end
  end
end
