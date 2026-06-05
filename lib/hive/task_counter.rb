require "fileutils"
require "securerandom"
require "yaml"
require "hive/lock"
require "hive/paths"

module Hive
  module TaskCounter
    module_function

    DEFAULT_NEXT_ID = 1
    LOCK_TIMEOUT_SEC = 30
    LOCK_POLL_SEC = 0.2

    def next!(timeout_sec: LOCK_TIMEOUT_SEC)
      with_lock(timeout_sec: timeout_sec) do
        id = peek
        write_next_id(id + 1)
        id
      end
    end

    def peek
      data = YAML.safe_load(File.read(Hive::Paths.task_counter_path)) || {}
      value = data.is_a?(Hash) ? data["next_id"] : nil
      [ Integer(value || DEFAULT_NEXT_ID), DEFAULT_NEXT_ID ].max
    rescue StandardError
      DEFAULT_NEXT_ID
    end

    def seed_at_least!(next_id)
      floor = [ Integer(next_id), DEFAULT_NEXT_ID ].max
      with_lock do
        current = peek
        write_next_id(floor) if current < floor
        [ current, floor ].max
      end
    end

    def with_lock(timeout_sec: LOCK_TIMEOUT_SEC)
      FileUtils.mkdir_p(Hive::Paths.state_home)
      File.open(Hive::Paths.task_counter_lock_path, File::RDWR | File::CREAT, 0o644) do |file|
        deadline = Time.now + timeout_sec
        until file.flock(File::LOCK_EX | File::LOCK_NB)
          if Time.now >= deadline
            raise Hive::ConcurrentRunError.new(
              "task counter lock at #{Hive::Paths.task_counter_lock_path} held longer than #{timeout_sec}s",
              lock_path: Hive::Paths.task_counter_lock_path
            )
          end

          sleep LOCK_POLL_SEC
        end
        yield
      end
    end

    def write_next_id(next_id)
      FileUtils.mkdir_p(Hive::Paths.state_home)
      path = Hive::Paths.task_counter_path
      tmp = "#{path}.tmp.#{Process.pid}.#{SecureRandom.hex(4)}"
      File.write(tmp, { "next_id" => next_id }.to_yaml)
      File.rename(tmp, path)
    ensure
      File.delete(tmp) if tmp && File.exist?(tmp)
    end
  end
end
