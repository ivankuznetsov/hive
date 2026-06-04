require "hive/config"

module Hive
  module Web
    class Supervisor
      Child = Struct.new(:name, :argv, :pid, keyword_init: true)

      def initialize
        @children = []
        @stopping = false
      end

      def run
        trap_signals
        start_child("daemon", %w[hive daemon start])
        start_child("web", %w[hive web --bind 0.0.0.0])
        start_child("bot", %w[hive bot start --foreground]) if Hive::Config.load_global_bot["enabled"]
        loop do
          break if @stopping
          reap_once
          sleep 1
        end
      ensure
        terminate_all
      end

      private

      def trap_signals
        %w[TERM INT].each do |signal|
          Signal.trap(signal) { @stopping = true }
        end
      end

      def start_child(name, argv)
        pid = Process.spawn(*argv, pgroup: true)
        @children << Child.new(name: name, argv: argv, pid: pid)
      end

      def reap_once
        @children.each do |child|
          next unless child.pid

          pid, status = Process.waitpid2(child.pid, Process::WNOHANG)
          next unless pid

          child.pid = nil
          start_child(child.name, child.argv) if child.name == "web" && !@stopping && !status.success?
        rescue Errno::ECHILD
          child.pid = nil
        end
      end

      def terminate_all
        @children.each do |child|
          next unless child.pid

          Process.kill("TERM", -child.pid)
        rescue Errno::ESRCH
          nil
        end
        deadline = Time.now + Hive::Config.load_global_daemon.fetch("shutdown_grace_sec", 60)
        @children.each do |child|
          next unless child.pid

          begin
            sleep 0.2 while Time.now < deadline && Process.waitpid(child.pid, Process::WNOHANG).nil?
          rescue Errno::ECHILD
            nil
          end
        end
      end
    end
  end
end
