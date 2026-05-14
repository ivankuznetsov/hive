require "test_helper"
require "hive/bot/child_supervisor"

class HiveBotChildSupervisorIntegrationTest < Minitest::Test
  include HiveTestHelper

  def test_three_concurrent_children_are_reaped
    with_tmp_dir do |dir|
      scripts = 3.times.map do |i|
        path = File.join(dir, "child#{i}.rb")
        File.write(path, "#!/usr/bin/env ruby\nputs '{\"ok\":true,\"idx\":#{i}}'\n")
        File.chmod(0o755, path)
        path
      end
      logger = StubLogger.new
      supervisor = Hive::Bot::ChildSupervisor.new(
        logger: logger,
        log_dir_for_task: ->(_project, slug) { File.join(dir, "#{slug}.log") }
      )

      scripts.each_with_index do |script, idx|
        supervisor.dispatch(command_argv: [ RbConfig.ruby, script ],
                            cwd: dir, chat_id: 123, update_id: idx,
                            project: "hive", slug: "slug#{idx}")
      end

      exits = []
      deadline = Time.now + 5
      while exits.size < 3 && Time.now < deadline
        exits.concat(supervisor.reap_all)
        sleep 0.05
      end

      assert_equal 3, exits.size
      assert_equal [ 0, 0, 0 ], exits.map(&:exit_code)
      assert_equal 0, supervisor.in_flight_count
    end
  end

  class StubLogger
    def event(_name, **_attrs)
    end
  end
end
