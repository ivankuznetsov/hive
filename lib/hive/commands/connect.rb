require "json"
require "securerandom"
require "time"
require "hive/config"
require "hive/commands/screenote_envelope"
require "hive/screenote/credential_store"
require "hive/screenote/loopback_server"
require "hive/screenote/mcp_client"
require "hive/screenote/oauth_client"
require "hive/screenote/pkce"

module Hive
  module Commands
    class Connect
      def initialize(service, base_url: nil, json: false, output: $stdout, input: $stdin,
                     credential_store: Hive::Screenote::CredentialStore.new,
                     oauth_client_factory: nil, loopback_factory: nil, mcp_client_factory: nil,
                     browser_opener: nil, project_picker: nil, clock: nil)
        @service = service.to_s
        @base_url = base_url
        @json = json
        @output = output
        @input = input
        @credential_store = credential_store
        @oauth_client_factory = oauth_client_factory || ->(url) { Hive::Screenote::OAuthClient.new(base_url: url) }
        @loopback_factory = loopback_factory || -> { Hive::Screenote::LoopbackServer.new }
        @mcp_client_factory = mcp_client_factory || lambda { |resource:, access_token:|
          Hive::Screenote::McpClient.new(resource: resource, access_token: access_token)
        }
        @browser_opener = browser_opener || ->(url) { self.class.open_browser(url) }
        @project_picker = project_picker
        @clock = clock || -> { Time.now }
      end

      def call
        ensure_screenote!
        do_call
      rescue Hive::Error => e
        emit_error_envelope(e) if @json
        raise
      rescue SystemCallError => e
        # An OS-level failure outside the save path (e.g. an unwritable temp
        # during discovery) is not a Hive::Error, so it would escape bin/hive's
        # rescue as a raw backtrace. Map it to a typed error with the same
        # envelope treatment.
        wrapped = Hive::Error.new("Screenote connect failed: #{e.message}")
        emit_error_envelope(wrapped) if @json
        raise wrapped
      end

      def self.open_browser(url)
        browser = ENV["BROWSER"].to_s.strip
        program = browser.empty? ? "xdg-open" : browser
        system(program, url, out: File::NULL, err: File::NULL)
      end

      private

      def do_call
        base_url = resolved_base_url
        existing = load_existing_credential
        oauth = @oauth_client_factory.call(base_url)
        metadata = oauth.discover
        callback, client_id = run_authorize_flow(oauth, metadata, existing)
        token = oauth.exchange_code(
          code: callback.fetch("code"),
          verifier: @verifier,
          redirect_uri: @redirect_uri,
          client_id: client_id,
          metadata: metadata
        )
        finalize_connection(oauth, metadata, token, client_id, base_url)
      end

      # Bind the loopback, register (if needed), and wait for the callback.
      # The `ensure` closes the loopback even when register/authorize_url/
      # show_authorize_url raises BEFORE wait_for_callback (whose own ensure
      # is otherwise the only close), so an early failure can't leak the bound
      # TCP socket until GC.
      def run_authorize_flow(oauth, metadata, existing)
        loopback = @loopback_factory.call
        @redirect_uri = loopback.redirect_uri
        client_id = existing["client_id"].to_s
        client_id = oauth.register(@redirect_uri, metadata: metadata)["client_id"] if client_id.empty?

        @verifier = Hive::Screenote::PKCE.verifier
        state = SecureRandom.hex(16)
        authorize_url = oauth.authorize_url(
          metadata: metadata,
          client_id: client_id,
          redirect_uri: @redirect_uri,
          code_challenge: Hive::Screenote::PKCE.challenge(@verifier),
          state: state
        )
        show_authorize_url(authorize_url)
        [ loopback.wait_for_callback(expected_state: state), client_id ]
      ensure
        loopback.close if loopback.respond_to?(:close)
      end

      # Everything from minting the token through SAVING the credential
      # (project listing, selection, payload build, save) must best-effort
      # revoke the freshly-issued bearer on failure: otherwise the next connect
      # re-registers (burning the 10/hr DCR limit) and the grant lingers
      # server-side. An OS-level save failure is mapped to a typed error so
      # bin/hive's rescue maps the exit code instead of printing a backtrace.
      #
      # `emit_success` runs AFTER the protected region returns — NOT inside it.
      # Once `save` writes screenote.json the connection is real; a broken
      # stdout pipe (`hive connect screenote --json | head -1` closes the pipe
      # after the authorize line) makes `emit_success`'s puts raise
      # Errno::EPIPE, and revoking from there would kill the persisted bearer,
      # leaving screenote.json advertising a server-revoked token. `emit_success`
      # additionally swallows a closed-pipe write so a successful save still
      # exits cleanly.
      def finalize_connection(oauth, metadata, token, client_id, base_url)
        project, credential = persist_connection(oauth, metadata, token, client_id, base_url)
        emit_success(credential, project)
      end

      def persist_connection(oauth, metadata, token, client_id, base_url)
        projects = @mcp_client_factory.call(
          resource: metadata.mcp_resource, access_token: token.fetch("access_token")
        ).list_projects
        project = choose_project(projects)
        credential = credential_payload(token, metadata: metadata, client_id: client_id,
                                        project: project, base_url: base_url)
        save_credential(credential)
        [ project, credential ]
      rescue StandardError
        best_effort_revoke(oauth, metadata, token, client_id)
        raise
      end

      def save_credential(credential)
        @credential_store.save(credential)
      rescue SystemCallError => e
        raise Hive::Error, "could not write Screenote credential to #{@credential_store.path}: #{e.message}"
      end

      def best_effort_revoke(oauth, metadata, token, client_id)
        access_token = token["access_token"].to_s
        return if access_token.empty?

        oauth.revoke(token: access_token, client_id: client_id, metadata: metadata)
      rescue StandardError => e
        warn "[hive] could not revoke the abandoned Screenote token: #{e.message}"
      end

      def emit_error_envelope(error)
        return if @error_emitted

        @error_emitted = true
        @output.puts JSON.generate(Hive::Commands::ScreenoteEnvelope.error_payload(error))
      rescue Errno::EPIPE, JSON::GeneratorError
        @error_emitted = true
      end

      def ensure_screenote!
        return if @service == "screenote"

        raise Hive::Error, "unsupported connect service #{@service.inspect}; expected screenote"
      end

      # A corrupt local screenote.json must not wedge `connect` (which would
      # otherwise leave the operator unable to re-authorize via the CLI).
      # Treat an unreadable file as "no existing credential": connect
      # re-runs the full OAuth flow and `save` overwrites the bad file.
      def load_existing_credential
        @credential_store.load || {}
      rescue Hive::ConfigError => e
        warn "[hive] ignoring unreadable screenote credential (re-authorizing): #{e.message}"
        {}
      end

      def resolved_base_url
        configured = @base_url.to_s.strip
        return configured unless configured.empty?

        Hive::Config.global_screenote_base_url
      end

      def show_authorize_url(url)
        opened = @browser_opener.call(url)
        if @json
          # Emit the authorize URL as a structured line BEFORE blocking on
          # the loopback callback, so an operator/automation whose browser
          # failed to auto-open still has the fallback URL under --json.
          @output.puts JSON.generate(
            "ok" => true, "service" => "screenote", "stage" => "authorize",
            "authorize_url" => url, "browser_opened" => !opened.nil? && opened != false
          )
          return
        end
        @output.puts "Opening Screenote authorization in your browser..." if opened
        @output.puts "Open this URL to connect Screenote:\n#{url}"
      end

      def choose_project(projects)
        raise Hive::Error, "Screenote returned no projects; create a project in Screenote and reconnect" if projects.empty?

        # Under --json with no injected picker there is no interactive prompt:
        # writing the human "Select a project" prose onto the JSON stream would
        # corrupt it and `@input.gets` would block→EOF→"selection is required".
        # Auto-select a lone project; with several, emit a structured
        # `needs_project_selection` envelope rather than silently defaulting.
        return projects.first if @json && @project_picker.nil? && projects.size == 1
        raise_needs_project_selection(projects) if @json && @project_picker.nil?

        selected = @project_picker ? @project_picker.call(projects) : prompt_for_project(projects)
        project = selected.is_a?(Hash) ? selected : projects.find { |candidate| project_id(candidate) == selected.to_s }
        raise Hive::Error, "Screenote project selection is required" unless project

        project
      end

      def raise_needs_project_selection(projects)
        @error_emitted = true
        # Carry the same `error_kind`/`exit_code` fields every other
        # `{"ok":false}` line does so automation can branch uniformly: a
        # distinct `needs_selection` kind tells "re-run with a project
        # selection" apart from an unrecoverable auth/network failure, and the
        # exit_code matches the GENERIC code bin/hive maps the raised
        # Hive::Error to below.
        @output.puts JSON.generate(
          "ok" => false,
          "service" => "screenote",
          "stage" => "needs_project_selection",
          "error_kind" => "needs_selection",
          "exit_code" => Hive::ExitCodes::GENERIC,
          "projects" => projects.map { |p| { "id" => project_id(p), "name" => project_display_name(p) } }
        )
        raise Hive::Error,
              "Screenote returned multiple projects; re-run connect interactively to choose a default project"
      end

      def prompt_for_project(projects)
        @output.puts "Select a default Screenote project:"
        projects.each_with_index do |project, index|
          @output.puts "#{index + 1}. #{project_label(project)}"
        end
        @output.print "Project number: "
        answer = @input.gets.to_s.strip
        return nil if answer.empty?

        return answer unless answer.match?(/\A\d+\z/)

        # Reject out-of-range numbers (including "0") before indexing.
        # `projects[answer.to_i - 1]` made "0" → projects[-1], silently
        # connecting the LAST project — a typo/cancel became a wrong
        # default. nil falls through to "selection is required".
        index = answer.to_i
        return nil unless index.between?(1, projects.size)

        projects[index - 1]
      end

      def credential_payload(token, metadata:, client_id:, project:, base_url:)
        expires_at = normalized_expires_at(token)
        credential = {
          "access_token" => token.fetch("access_token"),
          "expires_at" => expires_at,
          "token_type" => token["token_type"] || "Bearer",
          "scope" => token["scope"] || Hive::Screenote::OAuthClient::SCOPE,
          "client_id" => client_id,
          "issuer" => metadata.issuer,
          "project_id" => project_id(project),
          "base_url" => base_url,
          "mcp_resource" => metadata.mcp_resource
        }
        credential["refresh_token"] = token["refresh_token"] if token["refresh_token"]
        credential
      end

      # Both the absolute (`expires_at`) and relative (`expires_in`) branches
      # funnel through here so the STORED value is always a guaranteed ISO8601
      # string. The server's raw `expires_at` was previously stored verbatim;
      # if Screenote ever returns it as a Unix-epoch number (a common OAuth
      # shape) `CredentialStore#expired?` would `Time.parse` it, raise
      # ArgumentError, rescue to `true`, and read a fresh token as already
      # expired — silently disabling Screenote uploads. Coerce every shape to
      # ISO8601 here instead.
      def normalized_expires_at(token)
        raw = token["expires_at"]
        return computed_expires_at(token) if raw.nil? || (raw.is_a?(String) && raw.strip.empty?)

        to_iso8601(raw)
      end

      # Derive expires_at from expires_in when the endpoint omits the absolute
      # timestamp. A non-conformant token response that supplies neither used
      # to crash `connect` with a bare KeyError from `token.fetch("expires_in")`;
      # raise a typed Hive::Error instead.
      def computed_expires_at(token)
        expires_in = token["expires_in"]
        if expires_in.nil?
          raise Hive::Error, "Screenote token response omitted both expires_at and expires_in"
        end

        (@clock.call + expires_in.to_i).utc.iso8601
      end

      # Coerce a server-provided absolute expiry to ISO8601. Accepts an
      # ISO8601 string, a Unix-epoch number, or an all-digits epoch string;
      # an unparseable value raises a typed Hive::Error (which triggers the
      # best-effort revoke) rather than being persisted as a never-parses
      # timestamp.
      def to_iso8601(raw)
        return Time.at(raw).utc.iso8601 if raw.is_a?(Numeric)

        text = raw.to_s.strip
        return Time.at(text.to_i).utc.iso8601 if text.match?(/\A\d+\z/)

        Time.parse(text).utc.iso8601
      rescue ArgumentError
        raise Hive::Error, "Screenote token response had an unparseable expires_at: #{raw.inspect}"
      end

      def emit_success(credential, project)
        if @json
          @output.puts JSON.generate(
            "ok" => true,
            "service" => "screenote",
            "base_url" => credential.fetch("base_url"),
            "issuer" => credential.fetch("issuer"),
            "client_id" => credential.fetch("client_id"),
            "project_id" => credential.fetch("project_id"),
            "credential_path" => @credential_store.path
          )
        else
          @output.puts "Connected Screenote project #{project_label(project)}."
        end
      rescue Errno::EPIPE, IOError, JSON::GeneratorError
        # The credential is already on disk (save ran before this). A closed
        # stdout pipe (`hive connect screenote --json | head -1`) must not turn
        # a real, persisted connection into a failure — and must NOT reach the
        # finalize revoke path, which would kill the saved bearer. Swallow the
        # cosmetic success-line write failure.
        nil
      end

      # McpClient#list_projects normalizes raw Screenote projects to a stable
      # `{"id","name"}` shape, so the id lives under one key here.
      def project_id(project)
        project["id"].to_s
      end

      def project_display_name(project)
        project["name"].to_s.empty? ? "Unnamed project" : project["name"].to_s
      end

      def project_label(project)
        "#{project_display_name(project)} (#{project_id(project)})"
      end
    end
  end
end
