# frozen_string_literal: true

# Run only as a disposable judge or sentinel. Each process opens its own
# lifeline and liveness writer after forking so neither leaks to a sibling.
module BenchJudgeFixture
  module_function

  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def watch(root, role)
    stop = File.open(File.join(root, "stop"), File::RDONLY | File::NONBLOCK)
    live = File.open(File.join(root, "#{role}.live"), File::WRONLY | File::NONBLOCK)
    # The OS closes this descriptor at exit. Ruby GC must never close it early.
    live.autoclose = false
    Thread.new do
      IO.select([ stop ], nil, nil, 20)
      exit!(0)
    end
    File.write(File.join(root, "#{role}.ready"), now.to_s)
  end

  def run(root, mode)
    if %w[orphan family helper closed escaped].include?(mode)
      fork do
        Process.setsid if mode == "escaped"
        if %w[helper closed].include?(mode)
          STDIN.reopen(File::NULL)
          STDOUT.reopen(File::NULL, "w")
          STDERR.reopen(File::NULL, "w")
        end
        Signal.trap("TERM") { File.write(File.join(root, "child.term"), now.to_s) }
        watch(root, "child")
        if mode == "helper"
          sleep 0.005 until File.exist?(File.join(root, "finish"))
          File.write(File.join(root, "finished"), "ok")
          exit! 0
        end
        sleep
      end
    end

    watch(root, "judge")
    STDOUT.sync = STDERR.sync = true
    puts('{"score":9,"reason":"partial"}')
    case mode
    when "orphan", "helper", "escaped"
      sleep 0.005 until File.exist?(File.join(root, "child.ready"))
      exit 0
    when "flood"
      loop do
        STDOUT.write("o" * 8192)
        STDERR.write("e" * 8192)
        sleep 0.001
      end
    when "quota"
      warn "quota exceeded"
    end
    sleep
  end
end

BenchJudgeFixture.run(ENV.fetch("FIXTURE_ROOT"), ENV.fetch("FIXTURE_MODE")) if $PROGRAM_NAME == __FILE__
