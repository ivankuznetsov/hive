require "tempfile"
require "hive/process_kill"

module Hive
  module Stages
    module Council
      module CommandRunner
        TERM_GRACE_SEC = 0.5
        STDERR_EXCERPT_CHARS = 200

        module_function

        def run(env, command, chdir:, timeout_sec:, label:)
          Tempfile.create("hive-council-stderr") do |stderr|
            pid = Process.spawn(
              env, "sh", "-c", command,
              chdir: chdir,
              in: File::NULL,
              out: File::NULL,
              err: stderr,
              pgroup: true
            )
            waiter = Process.detach(pid)
            unless waiter.join(timeout_sec)
              Hive::ProcessKill.safe_kill("TERM", -pid)
              unless waiter.join(TERM_GRACE_SEC)
                Hive::ProcessKill.safe_kill("KILL", -pid)
                waiter.join(Hive::ProcessKill::KILL_GRACE_SECONDS)
              end
              raise Hive::StageError, "#{label} timed out after #{timeout_sec}s"
            end

            stderr.flush
            stderr.rewind
            excerpt = stderr.each_char.take(STDERR_EXCERPT_CHARS).join
            [ excerpt, waiter.value ]
          end
        end
      end
    end
  end
end
