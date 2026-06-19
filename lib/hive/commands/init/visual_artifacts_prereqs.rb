require "net/http"
require "rbconfig"
require "uri"

require "hive/commands/init/capture_tooling_installer"
require "hive/config"
require "hive/visual_artifacts_readiness"

module Hive
  module Commands
    class Init
      class VisualArtifactsPrereqs
        class NullScreenoteConnector
          def run; end
        end

        class ScreenoteConnector
          DEFAULT_BASE_URL = "https://screenote.ai".freeze
          TOKEN_SETTINGS_PATH = "/settings/api-tokens".freeze
          VALIDATION_PATH = "/api/v1/screenshots".freeze
          OPEN_TIMEOUT = 10
          READ_TIMEOUT = 20

          def initialize(input:, output:, readiness: Hive::VisualArtifactsReadiness,
                         config: Hive::Config, http: nil, opener: nil)
            @input = input
            @output = output
            @readiness = readiness
            @config = config
            @http = http || method(:default_request)
            @opener = opener || method(:open_url)
          end

          def run
            status = @readiness.screenote_status
            if status.fetch(:connected)
              @output.puts "screenote: connected ✓"
              return
            end

            explain_screenote
            unless yes?("Connect screenote now? [y/N]: ")
              @output.puts "screenote: skipped; hivebox will still show the committed visual gallery."
              return
            end

            base_url = prompt_base_url
            return skip_invalid_base_url unless valid_base_url?(base_url)

            present_token_instructions(base_url)
            token = prompt_token
            return skip_blank_token if token.empty?

            valid, reason = validate_token(base_url, token)
            unless valid
              @output.puts "screenote: token validation failed (#{reason}); paste a token once more or press Enter to skip."
              token = prompt_token
              return skip_blank_token if token.empty?

              valid, reason = validate_token(base_url, token)
              return skip_invalid_token(reason) unless valid
            end

            persist!(base_url, token)
            @output.puts "screenote: connected; saved credentials to #{@config.global_config_path}"
          end

          private

          def explain_screenote
            @output.puts ""
            @output.puts "Screenote hosting is optional."
            @output.puts "The hivebox web UI already renders the committed visual gallery."
            @output.puts "Connect screenote only if you want hosted links in GitHub PR bodies or an annotate/feedback loop."
          end

          def prompt_base_url
            @output.print "Screenote base URL [#{DEFAULT_BASE_URL}]: "
            @output.flush
            answer = read_line
            (answer.empty? ? DEFAULT_BASE_URL : answer).delete_suffix("/")
          end

          def present_token_instructions(base_url)
            url = token_settings_url(base_url)
            opened = @opener.call(url)
            @output.puts "Opened screenote token settings in your browser." if opened
            @output.puts "Create an API token, then paste it here:"
            @output.puts "  #{url}"
          rescue StandardError
            @output.puts "Create a screenote API token, then paste it here:"
            @output.puts "  #{url}"
          end

          def prompt_token
            @output.print "Screenote API token: "
            @output.flush
            read_line
          end

          def validate_token(base_url, token)
            uri = URI("#{base_url}#{VALIDATION_PATH}")
            request = Net::HTTP::Get.new(uri)
            request["Authorization"] = "Bearer #{token}"

            response = @http.call(uri, request, open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT)
            code = response.code.to_i
            return [ true, nil ] if code.between?(200, 299)

            [ false, "HTTP #{response.code}" ]
          rescue StandardError => e
            [ false, "#{e.class}: #{e.message}" ]
          end

          def persist!(base_url, token)
            @config.update_global_config! do |data|
              data["screenote"] = {
                "base_url" => base_url,
                "api_token" => token
              }
            end
          end

          def token_settings_url(base_url)
            "#{base_url}#{TOKEN_SETTINGS_PATH}"
          end

          def valid_base_url?(base_url)
            base_url.match?(%r{\Ahttps?://})
          end

          def skip_invalid_base_url
            @output.puts "screenote: skipped; base URL must start with http:// or https://."
          end

          def skip_blank_token
            @output.puts "screenote: skipped; no token saved."
          end

          def skip_invalid_token(reason)
            @output.puts "screenote: token validation failed (#{reason}); skipped."
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

          def open_url(url)
            opener = RbConfig::CONFIG["host_os"] =~ /darwin/i ? "open" : "xdg-open"
            return false unless which(opener)

            system(opener, url, out: File::NULL, err: File::NULL)
          rescue StandardError
            false
          end

          def which(name)
            ENV["PATH"].to_s.split(File::PATH_SEPARATOR).any? do |dir|
              path = File.join(dir, name)
              File.file?(path) && File.executable?(path)
            end
          end

          def default_request(uri, request, open_timeout:, read_timeout:)
            Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https",
                                                    open_timeout: open_timeout,
                                                    read_timeout: read_timeout) do |http|
              http.request(request)
            end
          end
        end

        def initialize(input:, output:, readiness: Hive::VisualArtifactsReadiness,
                       installer: CaptureToolingInstaller.new, screenote: nil)
          @input = input
          @output = output
          @readiness = readiness
          @installer = installer
          @screenote = screenote || ScreenoteConnector.new(input: input, output: output, readiness: readiness)
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
