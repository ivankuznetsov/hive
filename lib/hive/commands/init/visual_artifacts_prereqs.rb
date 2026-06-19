require "hive/commands/init/capture_tooling_installer"
require "hive/visual_artifacts_readiness"

module Hive
  module Commands
    class Init
      class VisualArtifactsPrereqs
        class NullScreenoteConnector
          def run; end
        end

        def initialize(input:, output:, readiness: Hive::VisualArtifactsReadiness,
                       installer: CaptureToolingInstaller.new, screenote: NullScreenoteConnector.new)
          @input = input
          @output = output
          @readiness = readiness
          @installer = installer
          @screenote = screenote
        end

        def run
          status = @readiness.capture_tooling_status
          if status.fetch(:satisfied)
            print_capture_ready(status)
            run_screenote
            return
          end

          explain_capture(status)
          unless yes?("Enable visual capture tooling now? [y/N]: ")
            @output.puts "visual capture tooling: skipped; re-run `hive init` on a fresh project or see `hive doctor` to enable later."
            return
          end

          install_capture_tooling(status.fetch(:missing))
          refreshed = @readiness.capture_tooling_status
          if refreshed.fetch(:satisfied)
            print_capture_ready(refreshed)
            run_screenote
          else
            print_manual_command(refreshed.fetch(:missing))
          end
        end

        private

        def explain_capture(status)
          @output.puts ""
          @output.puts "Visual artifact capture is optional."
          @output.puts "When enabled, artifacts can commit screenshots and a GIF that render inline in the hivebox web UI."
          @output.puts "Skipping is safe: hive still produces text artifacts, and `hive doctor` will show how to enable capture later."
          @output.puts "Missing capture tools: #{status.fetch(:missing).join(', ')}"
        end

        def install_capture_tooling(missing)
          if @installer.package_manager
            result = @installer.install!(missing: missing)
            return if result == :installed

            @output.puts "visual capture tooling: install #{result}; run this command manually:"
            @output.puts "  #{@installer.command_for(missing: missing)}"
            if @installer.package_manager.name == :apt
              @output.puts "  If apt reports stale package indexes, run `sudo apt-get update` first."
            end
          else
            print_manual_command(missing)
          end
        end

        def print_manual_command(missing)
          @output.puts "visual capture tooling: install manually and re-run `hive doctor`:"
          @output.puts "  #{@installer.command_for(missing: missing)}"
        end

        def print_capture_ready(status)
          ffmpeg = status.dig(:ffmpeg, :present) ? "✓" : "missing"
          asciinema = status.dig(:asciinema, :present) ? "✓" : "missing"
          @output.puts "visual capture tooling: ffmpeg #{ffmpeg} asciinema #{asciinema}"
        end

        def run_screenote
          @screenote.run
        end

        def yes?(prompt)
          @output.print prompt
          @output.flush
          answer = read_line.downcase
          answer == "y" || answer == "yes"
        end

        def read_line
          line = @input.gets
          return "" if line.nil?

          line.chomp.strip
        end
      end
    end
  end
end
