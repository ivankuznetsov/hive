require "bubbletea"
require "date"
require "digest"
require "fileutils"
require "set"
require "shellwords"
require "stringio"
require "time"
require "yaml"
require "hive"
require "hive/agent_profiles"
require "hive/config"
require "hive/commands/new"
require "hive/markers"
require "hive/stages"
require "hive/task"
require "hive/usage_db"
require "hive/tui/debug"
require "hive/tui/model"
require "hive/tui/messages"
require "hive/tui/key_map"
require "hive/tui/update"
require "hive/tui/snapshot"
require "hive/tui/text"
require "hive/tui/log_tail"
require "hive/tui/brainstorm_answers"
require "hive/tui/clipboard"
require "hive/tui/composer_staging"
require "hive/tui/subprocess"
require "hive/tui/views/projects_pane"
require "hive/tui/views/tasks_pane"
require "hive/tui/views/log_tail"
require "hive/tui/views/red_status_detail"
require "hive/tui/views/help_overlay"
require "hive/tui/views/filter_prompt"
require "hive/tui/views/idea_preview"
require "hive/tui/views/new_idea_prompt"
require "hive/tui/views/new_idea_project_picker"
require "hive/tui/views/token_stats"
require "hive/tui/views/archive_pane"
require "hive/tui/views/usage_footer"
require "hive/update_check/state"

module Hive
  module Tui
    # Bubbletea::Model adapter that wraps `Hive::Tui::Model` (frozen Data
    # record) and orchestrates the MVU loop. Stateful internally — the
    # `@hive_model` attribute reassigns on every `#update` — but every
    # transition still flows through `Update.apply` so the state changes
    # remain pure-function-tested in isolation.
    #
    # Responsibilities split:
    #   * Translate framework messages (KeyMessage / WindowSizeMessage)
    #     into Hive Messages before delegation.
    #   * Handle messages that need a runner reference (DispatchCommand
    #     wraps takeover_command with `runner.method(:send)` — Update
    #     can't, since it's runner-agnostic).
    #   * Handle messages that perform synchronous I/O (OpenLogTail,
    #     OpenInputEditor) — I/O lands here, not in Update, to keep
    #     Update pure.
    #   * Dispatch view by `model.mode` to one of the Views modules.
    #
    # The `dispatch:` lambda is set externally (App.run_charm wires
    # `runner.method(:send)`) so this class can be unit-tested with a
    # plain capture lambda — same seam as Subprocess.takeover_command.
    class BubbleModel
      include Bubbletea::Model

      attr_reader :hive_model

      # Tasks left with `:error reason=exit_code exit_code=<kill-class>`
      # markers are interrupted, not broken — the file-system state is
      # intact, just the marker says "stopped". The auto-healer in
      # `auto_heal_kill_class_errors` clears these markers in the
      # background so the TUI doesn't permanently display "Error" rows
      # the user can resume by simply re-running. The exact code list
      # lives on `Hive::Markers::KILL_CLASS_EXIT_CODES` so KeyMap's
      # Enter-routing predicate and this auto-healer never drift.
      KILL_CLASS_EXIT_CODES = Hive::Markers::KILL_CLASS_EXIT_CODES
      HELP_WHEEL_SCROLL_LINES = 3
      # Sized for ~32 lines of recent agent output — bounds render-time memory on large logs.
      INFO_PANEL_EXECUTE_TAIL_BYTES = 4 * 1024
      # Lowercase snapshot-row marker keys → uppercase CLI marker names
      # accepted by `hive markers clear --name`. Mirrors the upcase
      # convention in `Hive::Markers::KNOWN_NAMES`. A new recoverable
      # review marker added to the pipeline must land here AND in
      # `Hive::Markers`'s allowlist for recovery to wire up.
      REVIEW_RECOVERY_MARKERS = {
        "review_error" => "REVIEW_ERROR",
        "review_stale" => "REVIEW_STALE",
        "review_ci_stale" => "REVIEW_CI_STALE"
      }.freeze
      # Priority-ordered candidate keys for `hive markers clear
      # --match-attr KEY=VALUE`. The first non-empty attr on the
      # snapshot row wins — so `pass` (most discriminating across
      # review-stage retries) is checked before `reason` (groups
      # adjacent failures), which is checked before `attempts` and
      # `phase` (coarsest). Re-sorting alphabetically would silently
      # change which marker the clear targets and reintroduce the
      # concurrent-writer race the guard exists to prevent.
      REVIEW_RECOVERY_MATCH_ATTRS = %w[pass reason attempts phase].freeze
      # Display-priority order for the success flash detail. Known
      # keys render in this order; unknown keys append after, sorted
      # alphabetically (see `review_recovery_detail`). Order is for
      # display only — the match-attr guard reads
      # `REVIEW_RECOVERY_MATCH_ATTRS` instead.
      REVIEW_RECOVERY_DETAIL_ATTRS = %w[
        phase reason pass attempts elapsed files matches exception_class
      ].freeze

      def initialize(
        hive_model: Hive::Tui::Model.initial,
        dispatch: ->(_msg) { },
        clipboard_probe: ->(pasted_text:) { Hive::Tui::Clipboard.probe(pasted_text: pasted_text) },
        update_state: nil
      )
        @hive_model = hive_model
        @dispatch = dispatch
        @clipboard_probe = clipboard_probe
        # Shared update-check state (written by the daemon). Read on a short
        # TTL so the footer reflects a new nudge without re-reading the file
        # on every render frame. Lazily constructed so tests and non-daemon
        # sessions pay nothing until the footer asks.
        @update_state = update_state
        @update_nudge_cache = nil
        @update_nudge_checked_at = nil
        # `@healed_folders` is touched from the main runner thread
        # (`auto_heal_kill_class_errors` registers folders before
        # spawning heals) AND from heal Threads (which refresh the
        # failure-backoff timestamp). The mutex serializes both —
        # Hash reads/writes are not GVL-atomic across multiple writers
        # under MRI.
        @healed_folders = {} # folder path → Time.now
        @healed_folders_mutex = Mutex.new
        # F8: track in-flight heal Threads so App.run_charm's ensure
        # block can join-with-timeout-then-kill at TUI exit. Without
        # this, heal threads quitting mid-flight became zombies after
        # the runner tore down. Same mutex covers both fields — both
        # are touched from the same paths.
        @heal_threads = []
        # Per-folder dedup for review-recovery: a second Enter on a
        # `recover_review` row whose first clear+rerun is still in
        # flight refuses with a flash instead of firing a duplicate
        # `hive markers clear` + `hive run` pair. Cleared in the
        # spawn-thread's `ensure` block on completion (success or
        # failure) so the user can retry once the first pass settles.
        # Same mutex as @healed_folders / @heal_threads — they all
        # gate background-thread bookkeeping on the same lock.
        @review_recovery_inflight = Set.new
        # Per-folder dedup for ERROR-marker recovery. Same shape as
        # @review_recovery_inflight: a second Enter on an `error` row
        # whose first clear+rerun is still in flight refuses with a
        # flash instead of double-firing the recovery sequence. Cleared
        # in the spawn-thread's `ensure` so retries unblock once the
        # first pass settles. Reuses @healed_folders_mutex so all
        # background-thread bookkeeping fields (@healed_folders,
        # @heal_threads, @review_recovery_inflight,
        # @error_recovery_inflight) share a single lock.
        @error_recovery_inflight = Set.new
        # Once-per-session latch (reset in #stage_image on success).
        @clipboard_tool_hint_shown = false
        # Consecutive `wl-paste`/`xclip` timeouts: a single timeout
        # is plausibly a stalled compositor; two-in-a-row warrants a
        # flash so the operator knows paste is wedged.
        @clipboard_consecutive_timeouts = 0
        @usage_footer_cache_key = nil
        @usage_footer_cache_aggregate = nil
      end

      # Late binding so App.run_charm can wire the runner reference
      # after construction (Bubbletea::Runner.new is called with the
      # model, then we call `runner.method(:send)` to get the dispatcher).
      def dispatch=(callable)
        @dispatch = callable
      end

      # The init Cmd seeds a recurring `YieldTick` so the main loop
      # yields to Ruby threads between input polls — see
      # `Hive::Tui::Messages::YieldTick` for the underlying GVL-starvation
      # rationale. Without this seed, `StateSource#refresh_once` (which
      # runs on a background thread) takes 5-10s per poll under
      # `runner.run`'s tight loop.
      def init
        [ self, yield_tick_cmd ]
      end

      # @api private
      # Recurring 10ms tick. The callback yields the GVL via
      # `Thread.pass` and returns YIELD_TICK; update sees it, returns
      # the same tick again to keep the cycle going.
      def yield_tick_cmd
        Bubbletea.tick(0.01) do
          Thread.pass
          Hive::Tui::Messages::YIELD_TICK
        end
      end

      def update(message)
        hive_message = translate(message)

        # YieldTick is the only message that loops back into a tick
        # — re-schedule on every observation so the GVL-yield cycle
        # never stops.
        return [ self, yield_tick_cmd ] if hive_message.is_a?(Hive::Tui::Messages::YieldTick)

        # Side-effect-bearing messages that need a runner reference or
        # perform synchronous I/O are handled here; everything else
        # delegates to Update.apply.
        cmd_or_model = handle_side_effect(hive_message)
        if cmd_or_model
          new_model, cmd = cmd_or_model
          @hive_model = new_model if new_model
          return [ self, cmd ]
        end

        new_model, cmd = Hive::Tui::Update.apply(@hive_model, hive_message)
        @hive_model = new_model
        [ self, cmd ]
      rescue StandardError => e
        # Last-resort safety net. Every I/O-doing handler in
        # `handle_side_effect` lists its plausible failure modes
        # explicitly (see `open_log_tail`, `open_input_editor`, …) and
        # converts them into a flash. This catches the
        # *unanticipated* ones — a new Errno from a future fs feature,
        # a YAML parse error from a malformed reviewer file, a
        # Bubbletea framework message we don't yet handle. Without
        # this rescue, the exception unwinds out of `Bubbletea::Runner.run`
        # and tears down the alt-screen mid-frame, dumping the user back
        # to the shell. With it: a flash + the TUI keeps going. The
        # exception class + message are written to the debug log so
        # operators with `HIVE_TUI_DEBUG=1` can diagnose without
        # reproducing.
        Hive::Tui::Debug.log("bubble_model", "rescued #{e.class.name}: #{e.message}")
        @hive_model = @hive_model.with(
          flash: "internal error: #{e.class.name.split('::').last}: #{e.message[0, 80]}",
          flash_set_at: Time.now
        )
        [ self, nil ]
      end

      def view
        case @hive_model.mode
        when :grid then compose_two_pane_view
        when :log_tail then Views::LogTail.render(@hive_model)
        when :red_status_detail then Views::RedStatusDetail.render(@hive_model)
        when :token_stats then token_stats_view
        when :archive then archive_view
        when :help then Views::HelpOverlay.render(@hive_model)
        when :filter then compose_filter_view
        when :idea_preview then compose_idea_preview_view
        when :new_idea_project then compose_new_idea_project_view
        when :new_idea then compose_new_idea_view
        else compose_two_pane_view
        end
      end

      private

      # Bubbletea::KeyMessage → Hive Message via KeyMap.message_for.
      # Bubbletea::WindowSizeMessage → Messages::WindowSized.
      # Everything else (Hive Messages we sent ourselves via
      # `runner.send(...)`, or framework messages we don't translate)
      # passes through unchanged.
      def translate(message)
        case message
        when Bubbletea::KeyMessage
          translate_key(message)
        when Bubbletea::WindowSizeMessage
          Hive::Tui::Messages::WindowSized.new(cols: message.width, rows: message.height)
        when Bubbletea::MouseMessage
          translate_mouse(message)
        when Hive::Tui::Messages::RawTextInput
          translate_raw_text_input(message)
        else
          message
        end
      end

      # Translate a Bubbletea::KeyMessage to a Hive Message via the pure
      # KeyMap. Row context is the row currently under the cursor (nil
      # if the visible grid is empty); KeyMap uses it to refuse verbs
      # on stale-pid rows and to synthesize argv from suggested_command.
      def translate_key(key_message)
        key = bubble_key_to_keymap(key_message)
        row = @hive_model.mode == :red_status_detail ? @hive_model.red_status_detail_state&.row : current_row
        Hive::Tui::KeyMap.message_for(
          mode: @hive_model.mode,
          key: key,
          row: row,
          pane_focus: @hive_model.pane_focus
        )
      rescue ArgumentError => e
        # Unknown mode (defensive): treat as Noop. Should never fire
        # since `mode` is constrained by Update transitions; logging
        # here is the only way a regression in Update mode-handling
        # would surface to an operator (otherwise: keystroke silently
        # does nothing, no flash, no signal).
        Hive::Tui::Debug.log(
          "keymap",
          "ArgumentError mode=#{@hive_model.mode.inspect} key=#{key.inspect}: #{e.message}"
        )
        Hive::Tui::Messages::NOOP
      end

      def translate_raw_text_input(message)
        text = message.text.to_s

        case @hive_model.mode
        when :new_idea
          return Hive::Tui::Messages::NewIdeaPasteRequested.new(raw_text: text) if message.paste
          return Hive::Tui::Messages::NOOP if text.empty?

          Hive::Tui::Messages::NewIdeaTextInserted.new(text: text)
        when :filter
          return Hive::Tui::Messages::NOOP if text.empty?

          Hive::Tui::Messages::FilterTextInserted.new(text: text)
        else
          Hive::Tui::Messages::NOOP
        end
      end

      def translate_mouse(message)
        return Hive::Tui::Messages::NOOP unless @hive_model.mode == :help
        return Hive::Tui::Messages::NOOP unless message.wheel?

        case message.button
        when Bubbletea::MouseMessage::BUTTON_WHEEL_UP
          Hive::Tui::Messages::HelpScroll.new(direction: :up, amount: HELP_WHEEL_SCROLL_LINES)
        when Bubbletea::MouseMessage::BUTTON_WHEEL_DOWN
          Hive::Tui::Messages::HelpScroll.new(direction: :down, amount: HELP_WHEEL_SCROLL_LINES)
        else
          Hive::Tui::Messages::NOOP
        end
      end

      # Bubbletea::KeyMessage → KeyMap-shaped key (single-char String or
      # `:key_*` Symbol). Mirror the same surface KeyMap accepts from
      # the curses backend's curses_keys translator.
      def bubble_key_to_keymap(km)
        return :key_enter if km.enter?
        return :key_escape if km.esc?
        return :key_up if km.up?
        return :key_down if km.down?
        return :key_left if km.respond_to?(:left?) && km.left?
        return :key_right if km.respond_to?(:right?) && km.right?
        return :key_backspace if km.backspace?
        return :space if km.space?
        return :key_tab if km.tab?
        return :key_home if defined?(Bubbletea::KeyMessage::KEY_HOME) &&
                            km.key_type == Bubbletea::KeyMessage::KEY_HOME
        return :key_end if defined?(Bubbletea::KeyMessage::KEY_END) &&
                          km.key_type == Bubbletea::KeyMessage::KEY_END
        return :key_pgup if defined?(Bubbletea::KeyMessage::KEY_PGUP) &&
                            km.key_type == Bubbletea::KeyMessage::KEY_PGUP
        return :key_pgdn if defined?(Bubbletea::KeyMessage::KEY_PGDOWN) &&
                            km.key_type == Bubbletea::KeyMessage::KEY_PGDOWN
        return :key_delete if defined?(Bubbletea::KeyMessage::KEY_DELETE) &&
                              km.key_type == Bubbletea::KeyMessage::KEY_DELETE
        return :key_ctrl_a if defined?(Bubbletea::KeyMessage::KEY_CTRL_A) &&
                              km.key_type == Bubbletea::KeyMessage::KEY_CTRL_A
        return :key_ctrl_e if defined?(Bubbletea::KeyMessage::KEY_CTRL_E) &&
                              km.key_type == Bubbletea::KeyMessage::KEY_CTRL_E
        return :key_ctrl_v if defined?(Bubbletea::KeyMessage::KEY_CTRL_V) &&
                              km.key_type == Bubbletea::KeyMessage::KEY_CTRL_V
        # Bubbletea-Ruby v0.1.4 exposes KEY_SHIFT_TAB as a constant but
        # not a `shift_tab?` predicate; compare key_type directly so the
        # v2 two-pane Shift+Tab focus-cycle binding fires. The
        # `defined?` guard keeps the TUI booting on a hypothetical
        # future bubbletea-ruby that renames or drops the constant
        # (without it, every keystroke would raise NameError and the
        # outer rescue would convert it to a flash-spam loop).
        return :key_backtab if defined?(Bubbletea::KeyMessage::KEY_SHIFT_TAB) &&
                               km.key_type == Bubbletea::KeyMessage::KEY_SHIFT_TAB

        char = km.char
        char.is_a?(String) && !char.empty? ? char[0] : Hive::Tui::Messages::NOOP
      end

      # The cursor's current row, derived from snapshot + scope + filter.
      # KeyMap consults this for verb-on-running-agent refusals and for
      # row-driven action_key dispatch (agent_running, needs_input, etc.).
      def current_row
        snap = @hive_model.snapshot
        return nil if snap.nil? || @hive_model.cursor.nil?

        visible = snap.visible_projection(scope: @hive_model.scope, filter: @hive_model.filter)
        visible.row_at(@hive_model.cursor)
      end

      # Returns [new_hive_model, cmd] for the side-effect-bearing
      # messages, or nil to indicate "delegate to Update.apply".
      #
      # `SnapshotArrived` is special-cased here for the kill-class
      # auto-healer (signal-killed tasks shouldn't display as "Error"
      # forever — the file state IS intact, the marker is just stale).
      # We return nil after kicking off the heal so `Update.apply`
      # still applies the snapshot; the next poll picks up the cleared
      # state.
      def handle_side_effect(message)
        case message
        when Hive::Tui::Messages::SnapshotArrived
          auto_heal_kill_class_errors(message.snapshot)
          nil
        when Hive::Tui::Messages::SubprocessExited
          diagnose_subprocess_exit(message)
        when Hive::Tui::Messages::DispatchCommand
          dispatch_command(message)
        when Hive::Tui::Messages::OpenLogTail
          open_log_tail(message.row)
        when Hive::Tui::Messages::OpenRedStatusDetail
          open_red_status_detail(message)
        when Hive::Tui::Messages::OpenTokenStats
          open_token_stats
        when Hive::Tui::Messages::RecoverReview
          recover_review(message.row, force: message.force)
        when Hive::Tui::Messages::RecoverError
          recover_error(message.row)
        when Hive::Tui::Messages::RedStatusAutofix
          dispatch_red_status_autofix_then_close_detail(message.row)
        when Hive::Tui::Messages::OpenInputEditor
          open_input_editor(message.row)
        when Hive::Tui::Messages::OpenTaskFolder
          open_task_folder(message.row)
        when Hive::Tui::Messages::OpenIdeaPreview
          open_idea_preview(message.row)
        when Hive::Tui::Messages::OpenInAgent
          dispatch_open_in_agent_then_close_detail(message.row)
        when Hive::Tui::Messages::AgentSteerExited
          archive_steer(message)
        when Hive::Tui::Messages::OpenSummary
          open_summary(message.row)
        when Hive::Tui::Messages::LogTailPoll
          poll_log_tail
        when Hive::Tui::Messages::Back
          # F6: log_tail dismissal must close the underlying File or
          # every open/dismiss cycle leaks one FD. Side-effect-only —
          # return nil so Update.apply still handles the mode flip
          # and tail_state clearing.
          close_tail_if_log_tail
          nil
        when Hive::Tui::Messages::NewIdeaSubmitted
          submit_new_idea
        when Hive::Tui::Messages::NewIdeaPasteRequested
          handle_new_idea_paste(message.raw_text)
        when Hive::Tui::Messages::NewIdeaCancelled
          cleanup_new_idea_staging
          nil
        when Hive::Tui::Messages::DropFocusedTask
          drop_focused_task(message.row)
        end
      end

      def handle_new_idea_paste(raw_text)
        # Empty-paste short-circuit outside :new_idea: only the
        # composer probes the OS clipboard on an empty paste-burst;
        # other modes have no use for the wl-paste/xclip subprocess
        # round-trip.
        if raw_text.to_s.empty? && @hive_model.mode != :new_idea
          return [ @hive_model, nil ]
        end

        result = @clipboard_probe.call(pasted_text: raw_text)
        # Reset the consecutive-timeout latch on any non-timeout
        # probe outcome so a recovered compositor immediately rearms
        # the flash for the next wedge cycle.
        @clipboard_consecutive_timeouts = 0 unless result.kind == :clipboard_timeout
        case result.kind
        when :image_bytes
          stage_image_bytes(result)
        when :image_file
          stage_image_file(result)
        when :empty_image
          [ flashed("image file is empty — not staged"), nil ]
        when :clipboard_timeout
          @clipboard_consecutive_timeouts += 1
          if @clipboard_consecutive_timeouts >= 2
            @clipboard_consecutive_timeouts = 0
            [ flashed("clipboard probe timed out — check wl-paste/xclip"), nil ]
          else
            [ @hive_model, nil ]
          end
        when :oversize_image
          # Surface a flash for oversize PNG so the literal filesystem
          # path or clipboard byte string doesn't fall through into the
          # text-insertion path and corrupt the title buffer.
          # Ceil-divide the byte cap to MiB so a future tune of
          # `MAX_IMAGE_BYTES` to a non-MiB-aligned value (e.g. 5.5 MiB)
          # doesn't surface as ">5 MiB — not staged"; the displayed
          # boundary should always be ≥ the actual cap, never below.
          mib_cap = (Hive::Tui::Clipboard::MAX_IMAGE_BYTES.to_f / (1024 * 1024)).ceil
          [ flashed("image too large (>#{mib_cap} MiB) — not staged"), nil ]
        else
          if Hive::Tui::Clipboard.non_image_file_path?(pasted_text: raw_text)
            [ flashed("drag-drop ignored (not an image)"), nil ]
          elsif raw_text.to_s.empty? && (hint = missing_clipboard_tool_hint)
            [ flashed(hint), nil ]
          else
            apply_new_idea_text(raw_text)
          end
        end
      rescue Hive::Error, SystemCallError, IOError => e
        # Log the cause class (ENOSPC vs EACCES vs IOError) so an
        # operator with `HIVE_TUI_DEBUG=1` can tell why a paste failed.
        # `Hive::Error` covers `ComposerStaging::WriteError` plus any
        # future Hive-typed subclass intended to be handled here —
        # aligned with the rich-submit rescue list.
        cause_class = e.respond_to?(:cause_class) ? e.cause_class : e.class
        Hive::Tui::Debug.log(
          "new_idea_paste",
          "rescued #{e.class}(cause=#{cause_class || '(unknown cause)'}): #{e.message}"
        )
        [ flashed("image paste failed: #{Hive::Tui::Text.sanitize(e.message)[0, 120]}"), nil ]
      end

      def stage_image_bytes(result)
        stage_image(result.ext) do |path|
          Hive::Tui::ComposerStaging.write_bytes!(path, result.bytes)
        end
      end

      def stage_image_file(result)
        stage_image(result.ext) do |path|
          Hive::Tui::ComposerStaging.copy_file!(result.path, path)
        end
      end

      # Stage an image attachment onto disk, splice the placeholder
      # into the composer buffer, and update the model. The
      # buffer-overflow gate runs BEFORE `ensure_dir!` so a refused
      # paste does not allocate an orphan /tmp directory, and BEFORE
      # the file write so it does not leave an orphan file behind.
      # This gate is the SINGLE SOURCE OF TRUTH for the overflow
      # predicate (the Update-layer apply handler trusts the gate has
      # already passed).
      #
      # `number` comes from a monotonic per-composer counter on the
      # model that never decrements on prune — `attachments.size + 1`
      # would re-use a label after a prune-then-paste cycle and silently
      # overwrite the previously staged asset.
      def stage_image(ext)
        normalized_ext = Hive::Tui::ComposerStaging.normalized_extension(ext)
        number = @hive_model.new_idea_attachment_counter.to_i + 1
        placeholder = "[image#{number}]"
        buffer, _cursor = normalized_composer_buffer_and_cursor(@hive_model)
        if buffer.length + placeholder.length > Hive::Tui::Model::NEW_IDEA_BUFFER_MAX_CHARS
          return [
            @hive_model.with(
              flash: "buffer full - submit or remove text before pasting more images",
              flash_set_at: Time.now
            ),
            nil
          ]
        end

        result = Hive::Tui::ComposerStaging.ensure_dir!(@hive_model)
        # Adopt the dir-bearing model BEFORE the (possibly raising)
        # yield so a write failure leaves the staging dir reachable via
        # `cleanup_new_idea_staging` instead of leaking until process
        # exit.
        @hive_model = result.model
        label, path = Hive::Tui::ComposerStaging.next_label_and_path(
          result.dir, number, ext: normalized_ext
        )

        yield path
        # Reset the "install wl-clipboard" hint latch once we've
        # successfully staged an image — if the user later removes a
        # paste tool the hint should be allowed to surface again
        # instead of staying suppressed for the whole session.
        @clipboard_tool_hint_shown = false
        attachment = Hive::Tui::Model::Attachment.new(
          label: label,
          staging_path: path,
          ext: normalized_ext
        )
        message = Hive::Tui::Messages::NewIdeaImageAttached.new(
          attachment: attachment
        )
        new_model, _cmd = Hive::Tui::Update.apply(@hive_model, message)
        [ new_model, nil ]
      end

      def normalized_composer_buffer_and_cursor(model)
        buffer = model.new_idea_buffer.to_s
        cursor = model.new_idea_cursor.to_i.clamp(0, buffer.length)
        [ buffer, cursor ]
      end

      def apply_new_idea_text(raw_text)
        new_model, _cmd = Hive::Tui::Update.apply(
          @hive_model,
          Hive::Tui::Messages::NewIdeaTextInserted.new(text: raw_text.to_s)
        )
        [ new_model, nil ]
      end

      def missing_clipboard_tool_hint
        return nil if @clipboard_tool_hint_shown

        env = ENV
        if env.fetch("XDG_SESSION_TYPE", "").downcase == "wayland" &&
           !Hive::Tui::Clipboard::DefaultShim.command_available?("wl-paste", env: env)
          @clipboard_tool_hint_shown = true
          "install `wl-clipboard` to paste images"
        elsif !env.fetch("DISPLAY", "").empty? &&
              !Hive::Tui::Clipboard::DefaultShim.command_available?("xclip", env: env)
          @clipboard_tool_hint_shown = true
          "install `xclip` to paste images"
        end
      end

      def cleanup_new_idea_staging
        dir = @hive_model.new_idea_staging_dir
        tmp_root = @hive_model.new_idea_staging_tmp_root
        # Reset the model field BEFORE the actual rm_rf so a subsequent
        # paste after an unhandled exception cannot dispatch against a
        # now-deleted tmpdir (ENOENT on the next write_bytes!).
        unless dir.to_s.empty? && tmp_root.to_s.empty?
          @hive_model = @hive_model.with(
            new_idea_staging_dir: nil,
            new_idea_staging_tmp_root: nil
          )
        end
        cleanup_kwargs = tmp_root.to_s.empty? ? {} : { tmproot: tmp_root }
        Hive::Tui::ComposerStaging.cleanup!(dir, **cleanup_kwargs)
      rescue ArgumentError => e
        # The "refusing to clean outside tmpdir" guard fires when the
        # staging path drifted out of `Dir.tmpdir` between creation
        # and cleanup. That's a correctness-bug indicator and must
        # surface unconditionally to stderr, not stay hidden behind
        # `HIVE_TUI_DEBUG=1`.
        warn "hive tui: staging cleanup refused (#{e.class}: #{e.message})"
        Hive::Tui::Debug.log("new_idea_staging", "cleanup refused: #{e.class}: #{e.message}")
      rescue SystemCallError, IOError => e
        # Cleanup failures are visible only in the debug log by design
        # (the staging tree will be GC'd by the OS), but warn once so
        # an operator hitting `paste never works` has a surfaced clue
        # — mirrors the sibling ArgumentError branch's contract.
        warn "hive tui: staging cleanup failed (#{e.class}: #{e.message[0, 80]})"
        Hive::Tui::Debug.log("new_idea_staging", "cleanup failed: #{e.class}: #{e.message}")
      end

      # Handler for the grid-mode `X` keystroke. The destructive work is
      # delegated to the shared CLI command so TUI and shell drops share
      # one cleanup implementation and one JSON/error surface.
      def drop_focused_task(row)
        return [ flashed("select a task first; press / to filter or 1-9 to scope"), nil ] if row.nil?

        argv = [ "hive", "drop", row.slug, "--project", row.project_name, "--from", row.stage, "--json" ]
        message = Hive::Tui::Messages::DispatchCommand.new(argv: argv, verb: "drop")
        model, cmd = dispatch_command(message)
        [ model.with(flash: "dropping #{row.slug}...", flash_set_at: Time.now), cmd ]
      end

      def close_tail_if_log_tail
        return unless @hive_model.mode == :log_tail

        wrapper = @hive_model.tail_state
        wrapper&.tail&.close!
      end

      # Drain new bytes from the active Tail and reschedule the next
      # poll if the user is still viewing the log. Mode-change-out (Esc
      # / `q` flips back to :grid and clears tail_state) stops the
      # cycle so we don't keep waking the loop for a closed tail.
      def poll_log_tail
        wrapper = @hive_model.tail_state
        return [ @hive_model, nil ] if wrapper.nil? || @hive_model.mode != :log_tail

        wrapper.tail.poll!
        [ @hive_model, log_tail_poll_cmd ]
      end

      # Intercept SubprocessExited to look for known setup errors in
      # the captured stderr and override the generic "exited N — tail …"
      # flash with an actionable diagnostic. Returns nil for the
      # exit-zero (silent) case and for non-matching failures so
      # `Update.apply_subprocess_exited` keeps its existing default
      # flash behavior.
      def diagnose_subprocess_exit(msg)
        return nil if msg.exit_code.nil? || msg.exit_code.zero?

        diagnostic = Hive::Tui::Subprocess.diagnose_recent_failure(msg.verb, spawn_id: msg.spawn_id)
        return nil if diagnostic.nil?

        [ @hive_model.with(flash: diagnostic, flash_set_at: Time.now), nil ]
      end

      # Scan a fresh snapshot for tasks whose `:error` marker came from
      # a signal kill (130 / 137 / 143) and clear the marker in the
      # background. Each folder can claim one heal attempt per
      # HEAL_REPEAT_INTERVAL_SECONDS (`@healed_folders` repeat window),
      # so the loop never thrashes if the background heal is slow or a
      # persistent marker-clear failure survives across snapshots.
      #
      # The heal runs in a Ruby thread — `hive markers clear` is an
      # in-process subprocess via `run_quiet!` which captures
      # stdout/stderr cleanly without touching the alt-screen. The
      # next snapshot poll picks up the cleared marker and the row
      # re-classifies (typically back to "Ready for X" because the
      # agent's pre-kill state is preserved in the task folder).
      def auto_heal_kill_class_errors(snapshot)
        return if snapshot.nil?

        snapshot.rows.each do |row|
          next unless kill_class_error?(row)
          next unless register_heal_attempt(row.folder)

          spawn_heal_thread(row)
        end
      end

      def kill_class_error?(row)
        return false unless row.action_key == "error"

        attrs = row.attrs
        return false if attrs.nil?
        return false unless attrs["reason"] == "exit_code"

        KILL_CLASS_EXIT_CODES.include?(attrs["exit_code"].to_s)
      end

      # Time-bounded repeat window: a previous heal attempt blocks
      # re-heals of the same folder for `HEAL_REPEAT_INTERVAL_SECONDS`,
      # then the slot becomes available again. Without the bound, a
      # later kill-class error on the same folder (theoretically: the
      # same folder/slug pair could be re-killed in the same session)
      # would never re-heal because the cache permanently held the
      # entry. F11 fix.
      HEAL_REPEAT_INTERVAL_SECONDS = 60

      # Atomic claim-or-skip on `@healed_folders`. Returns true when
      # this caller wins the slot (must spawn the heal); false when a
      # prior call claimed it within the last
      # HEAL_REPEAT_INTERVAL_SECONDS.
      def register_heal_attempt(folder)
        @healed_folders_mutex.synchronize do
          claimed_at = @healed_folders[folder]
          return false if claimed_at && (Time.now - claimed_at) <= HEAL_REPEAT_INTERVAL_SECONDS

          @healed_folders[folder] = Time.now
          true
        end
      end

      # On heal failure, refresh the folder timestamp so retries are
      # throttled by HEAL_REPEAT_INTERVAL_SECONDS instead of spawning
      # one new heal thread per snapshot. Transient failures still retry
      # after the same bounded window used for successful heals.
      def record_heal_failure(folder)
        @healed_folders_mutex.synchronize { @healed_folders[folder] = Time.now }
      end

      # Override-able for tests so they can capture the heal
      # invocation without forking a real `hive markers clear`.
      # F8: tracks the spawned Thread on `@heal_threads` so
      # `kill_inflight_heals!` can reap stragglers at TUI exit; the
      # Thread prunes itself once the heal returns to bound the
      # tracking list under long sessions.
      def spawn_heal_thread(row)
        thread = Thread.new do
          heal_marker(row)
        ensure
          @healed_folders_mutex.synchronize { @heal_threads.delete(Thread.current) }
        end
        @healed_folders_mutex.synchronize { @heal_threads << thread }
        thread
      end

      # Reaping protocol for the App.run_charm ensure block. Two
      # phases share a single wall-clock deadline so a long-running
      # heal can't bottleneck the whole batch: phase 1 joins every
      # thread under one collective timeout (well-behaved heals
      # finish here); phase 2 force-kills stragglers and joins each
      # briefly to let their `ensure` block run. Snapshot/join is
      # done outside the mutex (Thread#join releases the GVL so
      # blocking under the lock would freeze the lifecycle); the
      # mutator path (`spawn_heal_thread`'s `ensure`) is still safe
      # to run against an already-empty list. Public because
      # App.run_charm calls it from outside the class on TUI
      # shutdown.
      JOIN_TIMEOUT_SECONDS = 2.0
      KILL_GRACE_SECONDS = 0.1

      public def kill_inflight_heals!
        threads = @healed_folders_mutex.synchronize { @heal_threads.dup }
        deadline = Time.now + JOIN_TIMEOUT_SECONDS
        threads.each do |t|
          remaining = deadline - Time.now
          break if remaining <= 0

          t.join(remaining)
        end
        threads.each do |t|
          next unless t.alive?

          t.kill
          t.join(KILL_GRACE_SECONDS)
        end
      end

      # @api private (test-only)
      # Block until every currently-tracked background thread (auto-heal
      # or review-recovery worker) finishes naturally, with a per-test
      # safety timeout. Tests that dispatch `RecoverReview` (or rely on
      # the auto-healer's spawned threads) need this to assert on
      # async-dispatched `Messages::Flash` payloads or on subprocess
      # stub captures populated inside the worker.
      #
      # Exceptions raised inside a worker (Thread#join re-raises them)
      # are swallowed: the helper's contract is "wait for the work to
      # settle so my assertions can run." Tests that need to verify a
      # programmer-error crashed the worker assert on the absence of a
      # dispatched flash instead of the join's re-raise. Production
      # callers use `kill_inflight_heals!` for shutdown; that path has
      # force-kill semantics this helper deliberately omits.
      public def wait_for_background_threads(timeout: 2.0)
        threads = @healed_folders_mutex.synchronize { @heal_threads.dup }
        deadline = Time.now + timeout
        threads.each do |t|
          remaining = deadline - Time.now
          break if remaining <= 0

          begin
            t.join(remaining)
          rescue StandardError
            # Worker died with a programmer error; the test will
            # detect this via the absence of an expected flash.
          end
        end
      end

      # Calls `hive markers clear` and converts any failure (non-zero
      # exit, exception) into a debug-log entry + backoff timestamp so
      # persistent failures cannot spawn one heal thread per snapshot.
      # Transient failures retry after HEAL_REPEAT_INTERVAL_SECONDS.
      #
      # `--match-attr marker_id=<observed>` ties the clear to the
      # specific kill-class marker we observed. Legacy rows without a
      # marker_id fall back to the observed reason/exit_code attrs so a
      # same-code marker with a different reason is not erased. If a
      # concurrent run writes a different ERROR marker between snapshot
      # and heal, the match refuses, backoff is refreshed, and the next
      # eligible snapshot sees the real failure instead of erasing it.
      def heal_marker(row)
        argv = [ "hive", "markers", "clear", row.folder, "--name", "ERROR" ]
        match_attr = error_recovery_match_attr(row)
        argv += [ "--match-attr", match_attr ] if match_attr
        exit_code, _out, err = Hive::Tui::Subprocess.run_quiet!(argv)
        return if exit_code.zero?

        Hive::Tui::Debug.log(
          "auto_heal",
          "clear failed for #{row.slug}: exit=#{exit_code} err=#{err.lines.first&.chomp.to_s[0, 120]}"
        )
        record_heal_failure(row.folder)
      rescue StandardError => e
        Hive::Tui::Debug.log("auto_heal", "failed for #{row.slug}: #{e.class.name}: #{e.message}")
        record_heal_failure(row.folder)
      end

      def red_status_autofix(row)
        if manual_only_red_status_recovery?(row)
          return [ flashed("Hive has no automatic recovery for this state — try Open in agent"), nil ]
        end

        if row.action_key.to_s == "error" && row.marker.to_s != "error"
          return dispatch_diagnostic_retry(row)
        end

        case row.action_key.to_s
        when "recover_review"
          recover_review(row, force: red_status_autofix_force?(row))
        when "error"
          recover_error(row)
        else
          [ flashed("Hive has no automatic recovery for this state — try Open in agent"), nil ]
        end
      end

      def manual_only_red_status_recovery?(row)
        attrs = row.attrs.to_h.transform_keys(&:to_s)
        marker = row.marker.to_s.downcase

        if marker == "review_error"
          return attrs["phase"] == "fix" &&
            %w[fix_status_check_failed fix_tampered].include?(attrs["reason"].to_s)
        end

        marker == "error" && %w[dirty_worktree ensure_clean_on_exit_failed].include?(attrs["reason"].to_s)
      end

      # Wrap red_status_autofix so the detail screen closes after the
      # keypress (Recover refusal flash still surfaces — the operator's
      # gesture was binary, leaving them on the screen contradicts the
      # plan's "screen closes after the keypress" requirement). The
      # wrapper is also reached from grid mode (Enter routes
      # `RedStatusAutofix` through `handle_side_effect`) — the close
      # branch is mode-guarded so grid-mode invocations are a no-op
      # pass-through.
      def dispatch_red_status_autofix_then_close_detail(row)
        model, cmd = red_status_autofix(row)
        close_red_status_detail_on_dispatch(model, cmd)
      end

      # Wrap open_in_agent so the detail screen closes on dispatch
      # (success and refusal alike). The takeover Cmd is preserved so
      # the foreground takeover still suspends the TUI; on return the
      # operator lands on the grid rather than a stale detail view.
      # Reached from grid mode (`s` key) and detail mode (`o` key); the
      # close branch is mode-guarded so grid-mode `s` is unchanged.
      def dispatch_open_in_agent_then_close_detail(row)
        model, cmd = open_in_agent(row)
        close_red_status_detail_on_dispatch(model, cmd)
      end

      def close_red_status_detail_on_dispatch(model, cmd)
        return [ model, cmd ] unless model
        return [ model, cmd ] unless model.mode == :red_status_detail

        closed = model.with(mode: :grid, red_status_detail_state: nil)
        visible = Hive::Tui::Update.visible_snapshot(closed)
        if visible
          cursor = Hive::Tui::Update.reclamp_cursor(visible, closed.cursor)
          closed = closed.with(cursor: cursor)
        end
        [ closed, cmd ]
      end

      def dispatch_diagnostic_retry(row)
        command = diagnostic_retry_command(row)
        return [ flashed("Hive has no automatic recovery for this state — try Open in agent"), nil ] if command.nil?

        if command.match?(/[;&|]/)
          return [ flashed("diagnostic retry command is not directly dispatchable; run it from a shell or use Open in agent"), nil ]
        end

        argv = Shellwords.split(command)
        return [ flashed("diagnostic retry command is empty"), nil ] if argv.empty?

        dispatch_command(Hive::Tui::Messages::DispatchCommand.new(argv: argv, verb: argv[1]))
      rescue ArgumentError => e
        [ flashed("diagnostic retry command is malformed: #{Hive::Tui::Text.sanitize(e.message)[0, 80]}"), nil ]
      end

      def diagnostic_retry_command(row)
        suggested = row.diagnostic && row.diagnostic["suggested_next_action"]
        return nil unless suggested.is_a?(Hash)
        return nil unless suggested["kind"].to_s == "retry"

        command = suggested["command"].to_s.strip
        command.empty? ? nil : command
      end

      # The `r` grid-mode gesture (PR #72) sets force: true ONLY for
      # max_passes-hit REVIEW_STALE — the case where the operator has
      # presumably edited reviews/escalations-NN.md and wants to retry
      # immediately. The detail-view Enter mirrors that contract: only
      # max_passes-hit REVIEW_STALE rows get force: true. Other
      # review_stale shapes (wall_clock, incomplete-triage) keep the
      # default force: false so retryable_review_stale? still gates them.
      # Non-REVIEW_STALE markers (REVIEW_ERROR, REVIEW_CI_STALE) never
      # need force; they always pass the gate.
      def red_status_autofix_force?(row)
        Hive::TaskAction.max_passes_review_stale_with_escalations?(
          folder: row.folder, marker_name: row.marker, attrs: row.attrs
        )
      end

      # Enter-driven review recovery. Review-stage recovery markers are
      # intentionally explicit gates: the old flow told the operator to
      # leave the TUI, clear a marker, then re-run `hive run`. The TUI
      # keeps that exact command surface but sequences it for the
      # highlighted row so Enter becomes "try again" after the operator
      # has addressed the underlying cause (for example API quota reset).
      #
      # The clear+rerun runs off the bubbletea update thread:
      # `Subprocess.run_quiet!` has a 30 s upper bound (markers-lock
      # contention + commit-lock; see `lib/hive/markers.rb`), and
      # blocking the runner thread for that long freezes rendering.
      # Mirrors the `auto_heal_kill_class_errors`/`spawn_heal_thread`
      # shape so the bubbletea thread returns immediately with a
      # "clearing…" status flash; the worker thread dispatches a
      # follow-up `Messages::Flash` via `@dispatch` on completion.
      def recover_review(row, force: false)
        if row.folder.to_s.strip.empty?
          return [ flashed("review recovery unavailable: task folder missing"), nil ]
        end

        marker_name = review_recovery_marker_name(row)
        unless marker_name
          marker = row.marker.to_s.empty? ? "none" : row.marker
          return [ flashed("review recovery unavailable: marker=#{marker}"), nil ]
        end
        # max_passes-hit REVIEW_STALE: Enter routes to OpenReviewStaleFile
        # (browse the focal escalations file) so the operator can answer
        # the questions in $EDITOR; clearing the marker without edits
        # would just produce the same findings on the next pass. The
        # `r` verb-key path sets `force: true` to declare "edits are
        # done, retry now" — that bypasses the gate below and falls
        # through to the clear+rerun path. Incomplete-triage and
        # wall_clock shapes return true from `retryable_review_stale?`
        # and need no force flag.
        if marker_name == "REVIEW_STALE" && !retryable_review_stale?(row) && !force
          return open_review_stale_file(row)
        end

        unless register_review_recovery_attempt(row.folder)
          return [ flashed("review recovery already in progress for #{row.slug}"), nil ]
        end

        detail = review_recovery_detail(row, marker_name)
        spawn_review_recovery_thread(row, marker_name)
        [ flashed("review recovery: clearing #{Hive::Tui::Text.sanitize(detail)[0, 160]}…"), nil ]
      end

      # Atomic claim-or-skip on @review_recovery_inflight. Prevents
      # two rapid Enter presses from firing two clear+rerun sequences
      # against the same folder. Returns true when this caller wins
      # the slot (must spawn the worker); false when an inflight
      # recovery is still running. The worker's `ensure` block evicts
      # the entry so a second attempt can run once the first settles.
      def register_review_recovery_attempt(folder)
        @healed_folders_mutex.synchronize do
          return false if @review_recovery_inflight.include?(folder)

          @review_recovery_inflight.add(folder)
          true
        end
      end

      def evict_review_recovery_attempt(folder)
        @healed_folders_mutex.synchronize { @review_recovery_inflight.delete(folder) }
      end

      # Tracked on @heal_threads alongside auto-heal threads so
      # `kill_inflight_heals!` (called from App.run_charm's ensure
      # block on TUI exit) reaps inflight recovery workers under the
      # same join-with-timeout-then-kill discipline. The eviction +
      # thread-list cleanup runs in `ensure` so a programmer-error
      # crash inside the worker still releases the dedup slot.
      def spawn_review_recovery_thread(row, marker_name)
        thread = Thread.new do
          perform_review_recovery(row, marker_name)
        ensure
          evict_review_recovery_attempt(row.folder)
          @healed_folders_mutex.synchronize { @heal_threads.delete(Thread.current) }
        end
        @healed_folders_mutex.synchronize { @heal_threads << thread }
        thread
      end

      # Worker body. All operator-visible failures land here as a
      # `Messages::Flash` dispatched through @dispatch — the
      # synchronous return path already flashed "clearing…" and the
      # bubbletea thread has moved on. Two distinct partial-failure
      # surfaces:
      #   1. `markers clear` non-zero — marker is intact, no rerun
      #      fired, operator should fix the cause and retry.
      #   2. `markers clear` succeeded BUT `dispatch_background`
      #      raised — marker is gone, no rerun fired, operator must
      #      run `hive run <folder>` manually. The flash text says so
      #      explicitly instead of misleading them with "failed".
      #
      # Rescue is narrowed to the I/O failure classes the subprocess
      # path can realistically throw (`SystemCallError` covers Errno::*,
      # `IOError` covers pipe/EOF, `Subprocess::TimeoutError` covers the
      # 30 s cap). Programmer errors (NoMethodError/NameError/
      # ArgumentError) are intentionally NOT caught — they crash the
      # worker thread loud so logs surface them instead of presenting
      # them to the operator as a misleading "review recovery failed"
      # flash.
      def perform_review_recovery(row, marker_name)
        clear_argv = review_recovery_clear_argv(row, marker_name)
        exit_code, _out, err = Hive::Tui::Subprocess.run_quiet!(clear_argv)
        unless exit_code.zero?
          reason = err.to_s.lines.first&.chomp.to_s
          reason = "exit #{exit_code}" if reason.empty?
          Hive::Tui::Debug.log(
            "review_recovery",
            "clear failed for #{row.slug}: exit=#{exit_code} err=#{err.to_s.lines.first&.chomp.to_s[0, 200]}"
          )
          flash_async("review recovery failed: #{Hive::Tui::Text.sanitize(reason)[0, 120]}")
          return
        end

        return unless dispatch_recovery_rerun(row, label: "review recovery", debug_scope: "review_recovery")

        detail = review_recovery_detail(row, marker_name)
        flash_async("review recovery: #{Hive::Tui::Text.sanitize(detail)[0, 160]}; running `hive run`…")
      rescue SystemCallError, IOError, Hive::Tui::Subprocess::TimeoutError => e
        Hive::Tui::Debug.log("review_recovery", "failed for #{row.slug}: #{e.class.name}: #{e.message}")
        flash_async(
          "review recovery failed: #{e.class.name}: #{Hive::Tui::Text.sanitize(e.message)[0, 80]}"
        )
      end

      def dispatch_recovery_rerun(row, label:, debug_scope:)
        started = Hive::Tui::Subprocess.dispatch_background(
          [ "hive", "run", row.folder ],
          dispatch: @dispatch
        )
        return true unless started == false

        Hive::Tui::Debug.log(debug_scope, "dispatch returned false for #{row.slug} (marker cleared)")
        flash_async(
          "#{label}: marker cleared, but `hive run` failed to start; " \
          "run `hive run #{row.folder}` manually"
        )
        false
      rescue SystemCallError, IOError, Hive::Tui::Subprocess::TimeoutError => e
        Hive::Tui::Debug.log(
          debug_scope,
          "dispatch failed for #{row.slug} (marker cleared): #{e.class.name}: #{e.message}"
        )
        flash_async(
          "#{label}: marker cleared, but `hive run` failed to start: " \
          "#{Hive::Tui::Text.sanitize(e.message)[0, 80]}; run `hive run #{row.folder}` manually"
        )
        false
      end

      def flash_async(text)
        @dispatch.call(Hive::Tui::Messages::Flash.new(text: text))
      end

      def review_recovery_marker_name(row)
        REVIEW_RECOVERY_MARKERS[row.marker.to_s]
      end

      def review_recovery_clear_argv(row, marker_name)
        argv = [ "hive", "markers", "clear", row.folder, "--name", marker_name ]
        match_attr = review_recovery_match_attr(row)
        match_attr ? argv + [ "--match-attr", match_attr ] : argv
      end

      def review_recovery_match_attr(row)
        attrs = row.attrs || {}
        key = REVIEW_RECOVERY_MATCH_ATTRS.find { |candidate| !attrs[candidate].to_s.empty? }
        key ? "#{key}=#{attrs[key]}" : nil
      end

      def review_recovery_detail(row, marker_name)
        attrs = row.attrs || {}
        keys = REVIEW_RECOVERY_DETAIL_ATTRS.select { |key| attrs.key?(key) }
        keys += (attrs.keys.map(&:to_s) - keys).sort
        attr_text = keys.map { |key| "#{key}=#{attrs[key]}" }.join(" ")
        attr_text.empty? ? marker_name : "#{marker_name} #{attr_text}"
      end

      # Top-level gate: a REVIEW_STALE row is retryable from the TUI
      # (clear+rerun) when ANY of the auto-recoverable shapes hold.
      # Cases that fall through to the manual-cleanup message:
      #   * max_passes hit with completed passes (the "trim reviewer
      #     files" path) — neither sub-predicate matches.
      def retryable_review_stale?(row)
        wall_clock_stale?(row) || retryable_incomplete_triage_pass?(row)
      end

      # `REVIEW_STALE reason=wall_clock` is set by the runner when the
      # aggregate review wall-clock budget elapsed mid-phase. The
      # operator's correct response is "give it more time and retry";
      # the existing reviewer/escalations files (if any) are still
      # valid input. Crucially, wall-clock can fire BEFORE any reviewer
      # files exist (e.g. during Phase 1 CI-fix), and a missing-file
      # state has no operator action to take, so the TUI must NOT
      # require reviewer files to be present before allowing retry.
      def wall_clock_stale?(row)
        (row.attrs || {})["reason"] == "wall_clock"
      end

      def retryable_incomplete_triage_pass?(row)
        attrs = row.attrs || {}
        pass = attrs["pass"].to_i
        return false if pass < 1 || row.folder.to_s.strip.empty?

        suffix = format("%02d", pass)
        reviews_dir = File.join(row.folder, "reviews")
        reviewer_file_present = Dir[File.join(reviews_dir, "*-#{suffix}.md")].any? do |path|
          review_recovery_reviewer_file?(File.basename(path))
        end

        reviewer_file_present && !File.exist?(File.join(reviews_dir, "escalations-#{suffix}.md"))
      rescue SystemCallError, IOError
        false
      end

      def review_recovery_reviewer_file?(name)
        require "hive/stages/review"
        Hive::Stages::Review.reviewer_file?(name)
      end

      # Display-priority order for the ERROR-recovery success flash.
      # Same idea as REVIEW_RECOVERY_DETAIL_ATTRS but ordered for the
      # attrs that ERROR markers actually carry: `reason` (e.g.
      # `exit_code`) and `exit_code` go first because they're what the
      # operator wants to see when reading "marker cleared" feedback.
      ERROR_RECOVERY_DETAIL_ATTRS = %w[reason exit_code phase elapsed].freeze

      # Enter-driven ERROR-marker recovery. Mirrors `recover_review` but
      # targets the generic ERROR marker any stage emits when the agent
      # is not in the explicit signal-kill shape
      # (`reason=exit_code exit_code=130|137|143`). Auto-heal owns that
      # interrupted-task shape; other structured reasons remain
      # recoverable even when they carry the same numeric code. Before
      # this gesture existed those rows sat in "Error" forever and the
      # only recovery path was a shell-level
      # `hive markers clear --name ERROR`.
      #
      # Same threading model as `recover_review`: the bubbletea update
      # thread returns immediately with a "clearing…" flash; the worker
      # thread does the markers-clear + `hive run` so the UI keeps
      # rendering during the sub-second-to-30s window the markers-lock
      # can take.
      def recover_error(row)
        if row.folder.to_s.strip.empty?
          return [ flashed("error recovery unavailable: task folder missing"), nil ]
        end
        unless row.action_key.to_s == "error"
          return [ flashed("error recovery unavailable: action=#{row.action_key}"), nil ]
        end

        attrs = row.attrs || {}
        if kill_class_error?(row)
          return [ flashed("error recovery: kill-class exit_code=#{attrs['exit_code']} auto-heals"), nil ]
        end

        unless register_error_recovery_attempt(row.folder)
          return [ flashed("error recovery already in progress for #{row.slug}"), nil ]
        end

        detail = error_recovery_detail(row)
        spawn_error_recovery_thread(row)
        [ flashed("error recovery: clearing #{Hive::Tui::Text.sanitize(detail)[0, 160]}…"), nil ]
      end

      def register_error_recovery_attempt(folder)
        @healed_folders_mutex.synchronize do
          return false if @error_recovery_inflight.include?(folder)

          @error_recovery_inflight.add(folder)
          true
        end
      end

      def evict_error_recovery_attempt(folder)
        @healed_folders_mutex.synchronize { @error_recovery_inflight.delete(folder) }
      end

      def spawn_error_recovery_thread(row)
        thread = Thread.new do
          # Ruby's default `Thread.report_on_exception = true` would
          # dump a programmer-error backtrace (NoMethodError, NameError)
          # to stderr while the TUI's alt-screen is active, corrupting
          # the visible frame. The narrow rescue below intentionally
          # lets programmer errors escape so we don't silently swallow
          # them — but they need to land in the debug log, not on the
          # operator's screen. Per-thread override scopes this to the
          # worker only; the rest of the process keeps Ruby's default.
          Thread.current.report_on_exception = false
          begin
            perform_error_recovery(row)
          rescue Exception => e # rubocop:disable Lint/RescueException
            Hive::Tui::Debug.log(
              "error_recovery",
              "worker crash for #{row.slug}: #{e.class.name}: #{e.message}\n#{Array(e.backtrace).first(10).join("\n")}"
            )
            raise
          end
        ensure
          evict_error_recovery_attempt(row.folder)
          @healed_folders_mutex.synchronize { @heal_threads.delete(Thread.current) }
        end
        @healed_folders_mutex.synchronize { @heal_threads << thread }
        thread
      end

      # Worker body. Same surface contract as `perform_review_recovery`:
      # narrow rescue around the I/O failure classes the subprocess can
      # realistically raise; programmer errors crash the worker so the
      # debug log surfaces them instead of presenting a misleading
      # "error recovery failed" flash.
      def perform_error_recovery(row)
        clear_argv = error_recovery_clear_argv(row)
        exit_code, _out, err = Hive::Tui::Subprocess.run_quiet!(clear_argv)
        unless exit_code.zero?
          reason = err.to_s.lines.first&.chomp.to_s
          reason = "exit #{exit_code}" if reason.empty?
          Hive::Tui::Debug.log(
            "error_recovery",
            "clear failed for #{row.slug}: exit=#{exit_code} err=#{err.to_s.lines.first&.chomp.to_s[0, 200]}"
          )
          flash_async(error_recovery_failure_flash(row, exit_code, reason))
          return
        end

        return unless dispatch_recovery_rerun(row, label: "error recovery", debug_scope: "error_recovery")

        detail = error_recovery_detail(row)
        flash_async("error recovery: #{Hive::Tui::Text.sanitize(detail)[0, 160]}; running `hive run`…")
      rescue SystemCallError, IOError, Hive::Tui::Subprocess::TimeoutError => e
        Hive::Tui::Debug.log("error_recovery", "failed for #{row.slug}: #{e.class.name}: #{e.message}")
        flash_async(
          "error recovery failed: #{e.class.name}: #{Hive::Tui::Text.sanitize(e.message)[0, 80]}"
        )
      end

      # `hive markers clear --match-attr marker_id=N` ties the clear
      # to the specific ERROR marker observed at snapshot time. Legacy
      # rows without marker_id fall back to the observed reason/exit_code
      # attrs, preserving same-code/different-reason race protection.
      def error_recovery_clear_argv(row)
        argv = [ "hive", "markers", "clear", row.folder, "--name", "ERROR" ]
        match_attr = error_recovery_match_attr(row)
        match_attr ? argv + [ "--match-attr", match_attr ] : argv
      end

      def error_recovery_match_attr(row)
        Hive::Markers.error_recovery_match_attr(row.attrs)
      end

      def error_recovery_detail(row)
        attrs = Hive::Markers.display_attrs(row.attrs)
        keys = ERROR_RECOVERY_DETAIL_ATTRS.select { |key| attrs.key?(key) }
        keys += (attrs.keys.map(&:to_s) - keys).sort
        attr_text = keys.map { |key| "#{key}=#{attrs[key]}" }.join(" ")
        attr_text.empty? ? "ERROR" : "ERROR #{attr_text}"
      end

      # Builds the operator-facing flash for a markers-clear failure.
      # `hive markers clear` exits 124 when the markers-lock can't be
      # acquired within the 30s cap — usually another writer (auto-heal,
      # background `hive run`, daemon) is holding it; surfacing "exit
      # 124" alone left the user with no actionable next step. Map the
      # common exit codes to specific guidance; fall through to the
      # short `reason` we already extracted from stderr for unknown
      # failures.
      def error_recovery_failure_flash(row, exit_code, reason)
        sanitised_reason = Hive::Tui::Text.sanitize(reason)[0, 120]
        case exit_code
        when Hive::Tui::Subprocess::COMMAND_TIMEOUT_EXIT
          "error recovery failed: markers-clear timed out after 30s (lock contention); retry shortly or `hive markers clear #{row.folder} --name ERROR` manually"
        else
          "error recovery failed: #{sanitised_reason}"
        end
      end

      # Workflow verbs route by `Hive::Workflows.interactive?(verb)`:
      #
      #   * Non-interactive (default) → `Subprocess.dispatch_background`
      #     spawns the child in a separate pgroup with stdio captured
      #     to `SUBPROCESS_LOG_PATH`. The TUI render loop keeps going;
      #     multiple agents across multiple projects run concurrently.
      #     A reaper Thread sends `Messages::SubprocessExited` when
      #     each child exits, which surfaces as a flash.
      #
      #   * Interactive → `Subprocess.takeover_command` returns a
      #     `Bubbletea::SequenceCommand(exit_alt, exec, enter_alt)`.
      #     The runner exits alt-screen, runs the child synchronously
      #     with the user's tty (so stdin prompts work), and re-enters
      #     alt-screen on return. Blocks the TUI for the duration —
      #     same trade as the curses-era takeover, opt-in only when
      #     the verb genuinely needs stdin.
      #
      # An immediate flash ("running …") fires synchronously in BOTH
      # paths so the user gets visual confirmation their keypress did
      # something. The flash is overwritten by SubprocessExited's
      # success/failure flash on completion.
      def dispatch_command(message)
        verb = message.verb || message.argv[1] || "verb"
        slug = message.argv[2] || ""

        cmd = if verb_interactive?(verb)
                Hive::Tui::Subprocess.takeover_command(message.argv, dispatch: @dispatch)
        else
                Hive::Tui::Subprocess.dispatch_background(message.argv, dispatch: @dispatch)
                nil
        end

        flash_text = slug.empty? ? "running `hive #{verb}`…" : "running `hive #{verb} #{slug}`…"
        [ @hive_model.with(flash: flash_text, flash_set_at: Time.now), cmd ]
      end

      # Indirection through an instance method (rather than calling
      # `Hive::Workflows.interactive?` directly) so tests can override
      # the predicate per-instance with `define_singleton_method`
      # instead of mutating the module's singleton class. Keeps the
      # test seam narrow and removes ordering/concurrency risk
      # between tests that touch the same global.
      def verb_interactive?(verb)
        Hive::Workflows.interactive?(verb)
      end

      # Open the most recent log file under the task's state log dir
      # or review-local log dir, build a Tail, flip mode.
      # Race-tolerant: if the file disappears
      # between resolve and open, flash instead of crashing.
      #
      # `FileResolver.latest` raises `Hive::NoLogFiles` (not nil) when
      # the dir has no `*.log` entries — must be in the rescue list or
      # the exception unwinds out of `Bubbletea::Runner` and tears the
      # TUI down. Common on tasks that haven't run any agent yet (the
      # `logs/` dir is created lazily by `Hive::Agent`).
      def open_log_tail(row)
        task = Hive::Task.new(row.folder)
        log_path = Hive::Tui::LogTail::FileResolver.latest_in_dirs(
          [ task.log_dir, File.join(task.folder, "logs") ]
        )

        tail = Hive::Tui::LogTail::Tail.new(log_path)
        tail.open!
        wrapper = LogTailContext.new(tail: tail, claude_pid_alive: row.claude_pid_alive)
        [ @hive_model.with(mode: :log_tail, tail_state: wrapper), log_tail_poll_cmd ]
      rescue Hive::NoLogFiles
        [ flashed("no logs yet for #{row.slug}"), nil ]
      rescue Hive::InvalidTaskPath, Errno::ENOENT, Errno::EACCES
        [ flashed("log file gone"), nil ]
      end

      # Resolve the configured development-agent label and capture a
      # bounded latest-log snapshot for the detail screen. Both reads
      # stay in BubbleModel so Update remains filesystem-free.
      def open_red_status_detail(message)
        row = message.row
        label = resolve_agent_label(row)
        log_path, log_lines = red_status_detail_log_snapshot(row)
        new_message = Hive::Tui::Messages::OpenRedStatusDetail.new(
          row: row,
          agent_label: label
        )
        new_model, _cmd = Hive::Tui::Update.apply(@hive_model, new_message)
        state = new_model.red_status_detail_state.with(
          log_path: log_path,
          log_lines: log_lines,
          log_scroll_offset: 0
        )
        [ new_model.with(red_status_detail_state: state), nil ]
      end

      def open_token_stats
        state = token_stats_state_for_current_scope
        [ @hive_model.with(mode: :token_stats, token_stats_state: state), nil ]
      end

      def token_stats_state_for_current_scope
        scope = derive_usage_scope(@hive_model)
        if scope[:task_slug]
          Hive::Tui::Model::TokenStatsState.new(
            scope_level: :task,
            project_slug: scope[:project_slug],
            task_slug: scope[:task_slug]
          )
        elsif scope[:project_slug]
          Hive::Tui::Model::TokenStatsState.new(
            scope_level: :project,
            project_slug: scope[:project_slug]
          )
        else
          Hive::Tui::Model::TokenStatsState.new(scope_level: :all)
        end
      end

      def token_stats_view
        state = @hive_model.token_stats_state || Hive::Tui::Model::TokenStatsState.new(scope_level: :all)
        aggregate = Hive::UsageDb.aggregate(scope: token_stats_scope(state))
        Views::TokenStats.render(@hive_model.with(token_stats_state: state), aggregate: aggregate)
      end

      def archive_view
        usable = [ @hive_model.cols.to_i - 1, 1 ].max
        Views::ArchivePane.render(@hive_model, width: usable)
      end

      def token_stats_scope(state)
        case state.scope_level
        when :task
          { project_slug: state.project_slug, task_slug: state.task_slug }
        when :project
          { project_slug: state.project_slug }
        else
          {}
        end
      end

      # Snapshot, not live tail: open the latest log, read the trailing
      # `LOG_SNAPSHOT_BACKBUFFER_BYTES`, return the last 50 lines. The
      # `R` key triggers a refresh path (`diagnose_subprocess_exit` on
      # success re-runs this) — re-tailing on every render thread would
      # block keystrokes on slow disks (sshfs, network mounts) and the
      # design path prefers stale-but-fast.
      def red_status_detail_log_snapshot(row)
        # Explicit guard so the rescue chain doesn't need to swallow a
        # broad TypeError just to cover the nil-folder case.
        return [ nil, [] ] if row&.folder.to_s.empty?

        task = Hive::Task.new(row.folder)
        log_path = Hive::Tui::LogTail::FileResolver.latest_in_dirs(
          [ task.log_dir, File.join(task.folder, "logs") ]
        )
        tail = Hive::Tui::LogTail::Tail.new(
          log_path,
          ring_capacity: 50,
          backbuffer_bytes: Hive::Tui::RedStatusDetailLayout::LOG_SNAPSHOT_BACKBUFFER_BYTES
        )
        tail.open!
        [ log_path, tail.lines(50) ]
      # Hive::NoLogFiles      → log dir empty / no log files yet.
      # Hive::InvalidTaskPath → row.folder is shaped wrong (Task.new rejects).
      # *LogTail::FILESYSTEM_RESCUE → IO failures opening the resolved log file.
      rescue Hive::NoLogFiles, Hive::InvalidTaskPath, *Hive::Tui::LogTail::FILESYSTEM_RESCUE => e
        Hive::Tui::Debug.log(
          "red_status_detail",
          "log snapshot skipped slug=#{row&.slug} folder=#{row&.folder.inspect} path=#{log_path.inspect} err=#{e.class.name.split('::').last}: #{e.message}"
        )
        [ nil, [] ]
      ensure
        tail&.close!
      end

      # Foreground takeover: open the row's input target in $EDITOR
      # (with $VISUAL preferred over $EDITOR; vi as the final fallback)
      # so the operator can answer inline questions. For brainstorm
      # rows, saving a completed answer round auto-runs the row's
      # suggested command; partial answers and non-brainstorm rows stay
      # manual via the verb keys (b/p/d/P/r/F).
      #
      # mtime is sampled before/after the spawn so InputEditorExited
      # carries a `changed:` flag, distinguishing a saved edit from a
      # cancelled session in the post-edit flash.
      def open_input_editor(row)
        path = input_editor_path(row)
        return [ flashed("no input file for #{row.slug}"), nil ] if path.empty?

        argv = editor_argv
        callable = lambda do
          before_mtime = file_mtime(path)
          before_hash = file_content_hash(path)
          # Capture the file's checkbox state pre-edit (and again
          # post-edit below). Consumed by `review_outcome` for 6-review
          # rows so that path can distinguish "user actually ticked a
          # box" from "opened, looked, hit :wq". Brainstorm and plan
          # outcomes ignore `checkboxes_changed`; the capture is
          # unconditional because for non-review rows the comparison
          # collapses to `{...} == {...}` cheaply.
          before_checkboxes = read_checkbox_state(path)
          exit_code = run_editor(argv, path)
          after_mtime = file_mtime(path)
          after_hash = file_content_hash(path)
          after_checkboxes = read_checkbox_state(path)
          # Wipe whatever the editor left on the main screen before
          # bubbletea re-enters alt-screen. Alt-screen *should* hide
          # the main buffer regardless, but on some terminals the
          # transition flickers if the editor's cursor or partial
          # output is still being painted. Mirror of the pre-spawn
          # clear in `clear_terminal_for_takeover`.
          clear_terminal_for_takeover
          # mtime answers "did the user save at all" (cheap, used as
          # the InputEditorExited `changed:` flag). Hash answers "did
          # the user actually change content" (precise, used by
          # plan-stage auto-advance to distinguish 'approved as-is'
          # from 'added feedback'). mtime samples must both be non-nil
          # to claim a change — a transient ENOENT/EACCES otherwise
          # produces a bogus `nil != Float` true.
          changed = !before_mtime.nil? && !after_mtime.nil? && before_mtime != after_mtime
          content_changed = !before_hash.nil? && !after_hash.nil? && before_hash != after_hash
          checkboxes_changed = before_checkboxes != after_checkboxes
          input_editor_exit_messages(row, path, exit_code, changed, content_changed, checkboxes_changed).each do |message|
            @dispatch.call(message)
          end
        end

        cmd = Hive::Tui::Subprocess.foreground_takeover_command(callable)
        [
          @hive_model.with(
            flash: "editing #{row.slug} in #{File.basename(argv.first)}",
            flash_set_at: Time.now
          ),
          cmd
        ]
      rescue ArgumentError => e
        [ flashed("editor command invalid: #{e.message}"), nil ]
      end

      # Pure browse gesture (R3 in the plan): open the task's hive-state
      # folder in $EDITOR. No mtime/hash/checkbox capture, no auto-
      # continue dispatch, no marker mutation. The editor's exit IS the
      # user's gesture; nothing post-edit is read from disk. Mirrors the
      # spawn/clear shape of `open_input_editor` so terminal handoff
      # works identically; differs only in dropping the input-editor
      # auto-continue plumbing.
      def open_task_folder(row)
        return [ flashed("no task folder for #{row.slug}"), nil ] if row.folder.to_s.empty?

        argv = editor_argv
        callable = lambda do
          run_editor(argv, row.folder)
          # Post-spawn clear: wipe whatever the editor left on the main
          # screen before bubbletea re-enters alt-screen. Mirrors the
          # tail end of `open_input_editor`'s callable.
          clear_terminal_for_takeover
        end

        cmd = Hive::Tui::Subprocess.foreground_takeover_command(callable)
        [
          @hive_model.with(
            flash: "opening #{row.slug} folder in #{File.basename(argv.first)}",
            flash_set_at: Time.now
          ),
          cmd
        ]
      rescue ArgumentError => e
        [ flashed("editor command invalid: #{e.message}"), nil ]
      end

      def open_idea_preview(row)
        return [ flashed("no idea for #{row.slug}"), nil ] if row.folder.to_s.empty?

        idea_path = File.join(row.folder, "idea.md")
        return [ flashed("no idea.md for #{row.slug}"), nil ] unless File.exist?(idea_path)

        contents = File.read(idea_path)
        data = idea_frontmatter(contents)
        original_text = data["original_text"].to_s
        if original_text.empty?
          return [ flashed("idea has no original_text for #{row.slug}"), nil ]
        end

        capped_text = original_text[0, Hive::Tui::Model::NEW_IDEA_BUFFER_MAX_CHARS]
        latest_log_path = latest_log_for(row)
        state = Hive::Tui::Model::InfoPanelState.new(
          slug: row.slug,
          stage: row.stage,
          created_at: idea_created_at(contents, data),
          original_text: capped_text,
          folder_path: File.expand_path(row.folder),
          latest_log_path: latest_log_path,
          stage_extra: stage_extra_for(row)
        )
        [
          @hive_model.with(mode: :idea_preview, info_panel_state: state),
          nil
        ]
      rescue Errno::ENOENT, Errno::EACCES, Errno::EISDIR, Errno::ENOTDIR, Errno::ENAMETOOLONG, Encoding::InvalidByteSequenceError, Psych::Exception
        [ flashed("could not read idea for #{row.slug}"), nil ]
      end

      def idea_frontmatter(contents)
        match = contents.match(/\A---[ \t]*\r?\n(.*?)\r?\n---[ \t]*(?:\r?\n|\z)/m)
        return {} unless match

        parsed = YAML.safe_load(
          match[1],
          permitted_classes: [ Time, Date ],
          permitted_symbols: [],
          aliases: false
        ) || {}
        parsed.is_a?(Hash) ? parsed : {}
      end

      # Verbatim plain scalar preserves non-UTC offsets; YAML-typed fallback normalizes Time to UTC iso8601.
      def idea_created_at(contents, data)
        raw = frontmatter_scalar(contents, "created_at")
        return raw unless raw.to_s.empty?

        value = data["created_at"]
        return nil if value.nil?
        return value.utc.iso8601 if value.is_a?(Time)
        return value.iso8601 if value.respond_to?(:iso8601)

        value.to_s.strip
      end

      # Narrow plain/matched-quote scalar extractor — block scalars and multi-line strings return nil.
      def frontmatter_scalar(contents, key)
        match = contents.match(/\A---[ \t]*\r?\n(.*?)\r?\n---[ \t]*(?:\r?\n|\z)/m)
        return nil unless match

        match[1].lines.each do |line|
          next unless (field = line.match(/\A#{Regexp.escape(key)}:[ \t]*(.*?)\r?\n?\z/))

          raw = field[1].strip
          return nil if raw.empty? || raw == "|" || raw == ">"

          if raw.length >= 2 && [ "\"", "'" ].include?(raw[0])
            quote = raw[0]
            closing = raw.index(quote, 1)
            return closing ? raw[1...closing] : nil
          end

          stripped = raw.sub(/[ \t]+#.*\z/, "").strip
          return stripped.empty? ? nil : stripped
        end
        nil
      end

      # Generic latest log used in the header; 4-execute extra uses `latest_execute_log_for` to avoid stray plan-*.log mtimes.
      def latest_log_for(row)
        latest_log_matching(row) { |_path| true }
      end

      # Restricted to `execute-*` basenames so a fresh plan-*.log mtime cannot masquerade as the execute log.
      def latest_execute_log_for(row)
        latest_log_matching(row) { |path| File.basename(path).start_with?("execute-") }
      end

      def latest_log_matching(row)
        log_dir = task_log_dir_for(row)
        return nil if log_dir.nil? || !File.directory?(log_dir)

        candidates = Dir.glob(File.join(log_dir, "*.log")).select { |path| yield(path) }
        return nil if candidates.empty?

        with_mtimes = candidates.filter_map do |path|
          [ File.expand_path(path), File.mtime(path) ]
        rescue Errno::ENOENT, Errno::EACCES
          nil
        end
        if with_mtimes.empty?
          candidate = candidates.find { |path| File.file?(path) }
          return candidate ? File.expand_path(candidate) : nil
        end

        with_mtimes.max_by(&:last).first
      rescue Errno::ENOENT, Errno::EACCES
        nil
      end

      def task_log_dir_for(row)
        Hive::Task.new(row.folder).log_dir
      rescue Hive::InvalidTaskPath
        nil
      end

      def stage_extra_for(row)
        case row.stage.to_s
        when "2-brainstorm" then read_capped(File.join(row.folder, "brainstorm.md")) # coding-scoped: TUI preview for coding brainstorm artifact
        when "3-plan" then read_capped(File.join(row.folder, "plan.md")) # coding-scoped: TUI preview for coding plan artifact
        when "4-execute" then tail_capped(latest_execute_log_for(row)) # coding-scoped: TUI preview for coding execute logs
        else nil
        end
      rescue Errno::ENOENT, Errno::EACCES, Errno::EISDIR, Errno::ENXIO, SystemCallError
        nil
      end

      def read_capped(path)
        return nil if path.to_s.empty? || !File.file?(path)

        text = File.open(path, "rb") { |file| file.read(Hive::Tui::Model::NEW_IDEA_BUFFER_MAX_CHARS) }
        scrub_utf8(text)
      rescue Errno::ENOENT, Errno::EACCES, Errno::EISDIR, Errno::ENXIO
        nil
      end

      def tail_capped(path)
        return nil if path.to_s.empty? || !File.file?(path)

        # Byte-aligned seek — the first rendered line may begin mid-character; do not add line-aware framing.
        text = File.open(path, "rb") do |file|
          begin
            file.seek(-INFO_PANEL_EXECUTE_TAIL_BYTES, IO::SEEK_END)
            file.read
          rescue Errno::EINVAL
            begin
              file.rewind
              file.read
            rescue Errno::ESPIPE
              nil
            end
          end
        end
        return nil if text.nil?

        scrub_utf8(text)
      rescue Errno::ENOENT, Errno::EACCES, Errno::EISDIR, Errno::ENXIO, Errno::ESPIPE
        nil
      end

      # Dup before force_encoding (callers may share); also strips C0/DEL so ANSI escapes cannot corrupt the panel frame.
      def scrub_utf8(text)
        scrubbed = text.to_s.dup.force_encoding(Encoding::UTF_8).scrub
        scrubbed.gsub(/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/, "")
      end

      def resolve_agent_label(row)
        task = Hive::Task.new(row.folder.to_s)
        cfg = Hive::Config.load(task.project_root)
        agent_name = cfg.dig("execute", "agent") || "claude"
        profile = Hive::AgentProfiles.lookup(agent_name, cfg: cfg)
        basename = File.basename(profile.bin.to_s)
        basename.empty? ? Hive::Tui::Model::RedStatusDetailState::AGENT_FALLBACK : basename
      rescue Hive::ConfigError, Hive::AgentProfiles::UnknownAgent,
             Hive::AgentError, Hive::InvalidTaskPath,
             Psych::Exception, SystemCallError, IOError
        Hive::Tui::Model::RedStatusDetailState::AGENT_FALLBACK
      end

      def open_in_agent(row)
        task = Hive::Task.new(row.folder)

        # Stale-row guard: a snapshot poll that pre-dated a stage advance
        # can leave `row.folder` pointing at an already-moved folder. We
        # must reject before reaching `Markers.set`, which creates the
        # parent dir as a side effect and would otherwise resurrect the
        # moved stage folder while the real task is active elsewhere.
        unless File.directory?(row.folder.to_s)
          return [ flashed("no task folder for #{row.slug}"), nil ]
        end

        # Cheap-check the worktree first so stage-3 rows without a
        # worktree don't pay the version-probe / preflight subprocess
        # cost just to be refused. `profile.check_version!` shells out
        # under a per-agent timeout; running it before the cheap
        # filesystem check makes the refusal flash non-deterministic in
        # latency.
        worktree_path = task.worktree_path
        unless worktree_path && File.directory?(worktree_path)
          return [ flashed("no worktree for #{row.slug} — run `hive develop #{row.slug}` first"), nil ]
        end

        cfg = Hive::Config.load(task.project_root)
        agent_name = cfg.dig("execute", "agent") || "claude"
        profile = Hive::AgentProfiles.lookup(agent_name, cfg: cfg)
        profile.check_version!
        profile.preflight!

        context_paths = agent_context_paths(task)
        argv = agent_steer_argv(profile, context_paths)
        # `agent:` records the logical agent name from config (e.g.
        # "claude"), not the resolved binary path. If `HIVE_CLAUDE_BIN`
        # is set the flash will name a different basename than the
        # marker attr — that divergence is intentional: the marker keys
        # off the agent profile (for U7 classification), the flash
        # tells the operator which binary actually spawned.
        Hive::Markers.set(row.state_file, "MANUAL_STEERING", agent: agent_name, started_at: Time.now.utc.iso8601)

        callable = lambda do
          clear_terminal_for_takeover
          exit_code = Hive::Tui::Subprocess.run_takeover_child_sync(argv, chdir: worktree_path)
          clear_terminal_for_takeover
          @dispatch.call(Hive::Tui::Messages::AgentSteerExited.new(
            slug: row.slug,
            folder: row.folder,
            exit_code: exit_code,
            worktree: worktree_path
          ))
        end

        flash_text = "steering #{row.slug} in #{File.basename(profile.bin)} → #{File.basename(worktree_path)}"
        if context_paths.any? && profile.add_dir_flag.to_s.empty?
          flash_text = "#{flash_text} (no add-dir flag; context not preloaded)"
        end

        [ flashed(flash_text), Hive::Tui::Subprocess.foreground_takeover_command(callable) ]
      rescue Hive::AgentProfiles::UnknownAgent
        [ flashed("unknown agent in config: #{agent_name}"), nil ]
      rescue Hive::ConfigError => e
        [ flashed("agent config invalid: #{Hive::Tui::Text.sanitize(e.message)[0, 120]}"), nil ]
      rescue Hive::AgentError => e
        [ flashed("agent unavailable: #{Hive::Tui::Text.sanitize(e.message)[0, 120]}"), nil ]
      rescue Hive::InvalidTaskPath
        [ flashed("no task folder for #{row.slug}"), nil ]
      rescue SystemCallError, IOError => e
        # Disk-full marker write, permission-denied state-file write, or
        # malformed `.hive-state/config.yml` (Psych::SyntaxError is
        # rescued in Hive::Config and re-raised as ConfigError, but
        # related IOErrors during YAML load can still surface here).
        # Sibling `archive_steer` rescues the same pair for symmetry.
        [ flashed("steer failed for #{row.slug}: #{e.class.name.split('::').last}: #{Hive::Tui::Text.sanitize(e.message)[0, 120]}"), nil ]
      end

      def agent_context_paths(task)
        Hive::Stages::DIRS.filter_map do |stage_dir|
          path = File.join(task.hive_state_path, "stages", stage_dir, task.slug)
          path if File.directory?(path)
        end
      end

      # Build the argv for the manual-steering takeover. Drops every
      # `context_path` when `profile.add_dir_flag` is nil — the agent
      # gets the worktree (via `chdir:`) but no stage-folder context.
      # Assumes context preloading is a CLI-flag affordance only; an
      # agent that wants context via env vars or stdin would need a
      # new profile field (none today). The conditional flash in
      # `open_in_agent` already warns the operator when this branch
      # silently drops paths.
      def agent_steer_argv(profile, context_paths)
        argv = [ profile.bin ]
        add_dir_flag = profile.add_dir_flag
        if add_dir_flag
          context_paths.each do |path|
            argv << add_dir_flag
            argv << path
          end
        end
        argv
      end

      def archive_steer(message)
        task = Hive::Task.new(message.folder)
        archived_root = File.join(task.hive_state_path, "stages", "archived-manual")
        FileUtils.mkdir_p(archived_root)
        target = manual_archive_target(archived_root, task.slug)
        collision = File.basename(target) != task.slug
        File.rename(message.folder, target)

        flash = manual_archive_flash(task.slug, target, message.exit_code, collision)
        [ @hive_model.with(flash: flash, flash_set_at: Time.now), nil ]
      rescue Hive::InvalidTaskPath
        [ flashed("manual archive failed for #{message.slug}: invalid task folder"), nil ]
      rescue SystemCallError, IOError => e
        # Include the sanitized truncated message so the operator has a
        # breadcrumb (path, errno text) — `EACCES` alone leaves no clue
        # whether it was the archived-manual/ permissions, a stale fd,
        # or a cross-fs rename.
        klass = e.class.name.split("::").last
        msg = Hive::Tui::Text.sanitize(e.message)[0, 120]
        [ flashed("manual archive failed for #{message.slug}: #{klass}: #{msg}"), nil ]
      end

      # @api private
      # Upper bound on the suffix collision probe in `manual_archive_target`.
      # Sized large enough to absorb pathological hand-archiving but small
      # enough that a runaway "create `<slug>-N` for every N" script can
      # never hot-loop the main TUI thread inside a single Update tick.
      MANUAL_ARCHIVE_SUFFIX_CEILING = 999

      def manual_archive_target(archived_root, slug)
        target = File.join(archived_root, slug)
        return target unless File.exist?(target)

        (2..MANUAL_ARCHIVE_SUFFIX_CEILING).each do |suffix|
          candidate = File.join(archived_root, "#{slug}-#{suffix}")
          return candidate unless File.exist?(candidate)
        end

        # Fail loudly so the rescue in `archive_steer` surfaces the
        # exhaustion as a flash — better than spinning forever or
        # silently overwriting a pre-existing archive.
        raise Errno::EEXIST, "archived-manual/#{slug}-2..#{MANUAL_ARCHIVE_SUFFIX_CEILING} all taken"
      end

      def manual_archive_flash(slug, target, exit_code, collision)
        target_name = File.basename(target)
        if exit_code.to_i.zero?
          return "archived #{slug} → archived-manual/ (shipped)" unless collision

          "archived #{slug} → archived-manual/#{target_name}/ (collision)"
        elsif exit_code.to_i == 127
          # Exit 127 from `run_takeover_child_sync` means the shell could
          # not invoke the agent binary at all — the cached `check_version!`
          # found it but it disappeared (uninstall, PATH change) between
          # the cache and the spawn. Distinguishing this in the flash
          # avoids the operator chasing a "real" agent run that returned
          # 127.
          dest = collision ? "archived-manual/#{target_name}/" : "archived-manual/"
          "agent binary not found (exit 127); archived #{slug} → #{dest}"
        elsif collision
          "agent exited #{exit_code}; archived #{slug} → archived-manual/#{target_name}/ (collision)"
        else
          "agent exited #{exit_code}; archived #{slug} → archived-manual/"
        end
      end

      def open_summary(row)
        path = summary_editor_path(row)
        return [ flashed("no summary for #{row.slug}"), nil ] if path.empty?

        argv = editor_argv
        callable = lambda do
          run_editor(argv, path)
          clear_terminal_for_takeover
        end

        cmd = Hive::Tui::Subprocess.foreground_takeover_command(callable)
        [
          @hive_model.with(
            flash: "opening summary for #{row.slug} in #{File.basename(argv.first)}",
            flash_set_at: Time.now
          ),
          cmd
        ]
      rescue ArgumentError => e
        [ flashed("editor command invalid: #{e.message}"), nil ]
      end

      def summary_editor_path(row)
        folder = row.folder.to_s
        return "" if folder.empty?

        summary = File.join(folder, "summary.md")
        return summary if File.exist?(summary)

        pr_md = File.join(folder, "pr.md")
        File.exist?(pr_md) ? pr_md : ""
      end

      # Browse-only handler for max_passes-hit REVIEW_STALE rows.
      # Mirrors `open_task_folder` (PR #64) for the spawn/clear shape;
      # differs only in the resolved path (focal escalations file
      # instead of the task folder). Pure browse contract: no marker
      # mutation, no auto-continue dispatch — the editor's `:wq` is
      # the operator's last word, and clearing REVIEW_STALE remains
      # a deliberate `hive markers clear` round-trip.
      def open_review_stale_file(row)
        path = review_stale_editor_path(row)
        return [ flashed("no review files for #{row.slug}"), nil ] if path.empty?

        argv = editor_argv
        callable = lambda do
          run_editor(argv, path)
          # Post-spawn clear mirrors open_task_folder / open_input_editor:
          # wipes whatever the editor left on the main screen before
          # bubbletea re-enters alt-screen.
          clear_terminal_for_takeover
        end

        # Differentiated flash: when we fell back to the reviews/
        # directory (focal `escalations-NN.md` missing), say so
        # explicitly. The operator's status row shows "stale pass=4"
        # but the editor will open a directory that may contain
        # files for OTHER passes — without this distinction the
        # operator could resolve findings against pass-2 thinking
        # they're pass-4's. Pinned by ADV-4 in PR #66's review.
        flash_text = if File.directory?(path)
          "opening reviews/ dir for #{row.slug} (focal escalations-#{format('%02d', pass_for_flash(row))}.md missing)"
        else
          "opening reviews for #{row.slug} in #{File.basename(argv.first)}"
        end

        cmd = Hive::Tui::Subprocess.foreground_takeover_command(callable)
        [
          @hive_model.with(flash: flash_text, flash_set_at: Time.now),
          cmd
        ]
      rescue ArgumentError => e
        [ flashed("editor command invalid: #{e.message}"), nil ]
      end

      # Helper for `open_review_stale_file`'s differentiated flash:
      # returns the pass attr as a parsed integer for display, or 0
      # when it's malformed/absent (the dir-fallback path).
      def pass_for_flash(row)
        attrs = row.attrs || {}
        Integer(Hive::Tui::Text.sanitize(attrs["pass"]).strip, 10)
      rescue ArgumentError
        0
      end

      # Resolve the focal path for a max_passes-hit REVIEW_STALE row:
      # highest-pass `reviews/escalations-NN.md` (the runner's
      # canonical aggregation of unresolved findings). Fall back to
      # the `reviews/` directory when the file is missing — lets the
      # operator browse the individual reviewer files (claude-…-NN.md,
      # codex-…-NN.md, etc.) themselves. Returns "" only when both
      # the file and the directory are absent (corrupted state); the
      # caller flashes a refusal.
      def review_stale_editor_path(row)
        folder = row.folder.to_s
        return "" if folder.empty?

        attrs = row.attrs || {}
        # Sanitize before parsing: stdout-tail or other operator-supplied
        # bytes embedded in a marker reason could carry control sequences;
        # the resolver doesn't render the value, but sanitizing first
        # keeps the parse path symmetric with `tasks_pane.rb`'s status-
        # column rendering (which always sanitizes) so a CSI-loaded
        # `pass` attr resolves to the same outcome on both surfaces.
        pass = Hive::Tui::Text.sanitize(attrs["pass"]).strip
        return "" if pass.empty?

        # Strict-base-10 parse is the load-bearing path-traversal
        # defense — `Integer(pass, 10)` rejects "../../etc/passwd"
        # while `pass.to_i` would silently coerce to 0. Do NOT
        # simplify to `.to_i`. Pass `< 1` is rejected explicitly to
        # mirror `retryable_incomplete_triage_pass?`'s "valid pass"
        # convention; negative/zero values are not legitimate runner
        # output and would build malformed filenames like
        # `escalations--1.md`.
        pass_int = Integer(pass, 10)
        return "" if pass_int < 1

        reviews_dir = File.join(folder, "reviews")
        candidate = File.join(reviews_dir, "escalations-#{format('%02d', pass_int)}.md")
        return candidate if File.exist?(candidate)
        return reviews_dir if File.directory?(reviews_dir)

        ""
      rescue ArgumentError
        # Non-integer `pass` attr (legacy/malformed / corrupted-by-
        # injection-attempt) — fall back to the reviews dir if it
        # exists, else refuse. The fallback is deliberate: gives the
        # operator something to inspect when diagnosing why their row
        # is in this state.
        reviews_dir = File.join(row.folder.to_s, "reviews")
        File.directory?(reviews_dir) ? reviews_dir : ""
      end

      # Resolve the path the editor should open for a given row.
      # Default: the stage's state file (`brainstorm.md` / `plan.md` /
      # `task.md` / `pr.md`). For `:execute_waiting`, use Status's
      # reason-specific action target when it is an edit target. For
      # `:review_waiting`, send the operator
      # to files the resume path actually consumes: the Q&A-style
      # escalations file for the pass, reviewer-authored files for
      # legacy gates, or the reviews directory when there are multiple
      # possible sources / a fix-guardrail inspection gate.
      def input_editor_path(row)
        execute_target = execute_waiting_editor_path(row)
        return execute_target if execute_target
        return review_waiting_editor_path(row) if row.marker.to_s == "review_waiting"

        row.state_file.to_s
      end

      def execute_waiting_editor_path(row)
        return nil unless row.marker.to_s == "execute_waiting"

        next_action = row.respond_to?(:next_action) ? row.next_action : nil
        return nil unless next_action.is_a?(Hash)
        return nil unless next_action["kind"] == Hive::Schemas::NextActionKind::EDIT

        target = next_action["target"].to_s
        target.empty? ? nil : target
      end

      def review_waiting_editor_path(row)
        folder = row.folder.to_s
        return "" if folder.empty?

        reviews_dir = File.join(folder, "reviews")
        pass = review_waiting_pass(row)
        reason = review_waiting_reason(row)

        # U5+U6 fix-guardrail approval gate: open the focal file
        # directly so (a) the user lands on the one file that controls
        # the resume, and (b) `read_checkbox_state` in the editor
        # callback receives a regular file rather than the reviews/
        # directory (Errno::EISDIR rescue would otherwise mask the
        # before/after delta and silently suppress :rerun_review).
        if reason == "fix_guardrail" && pass
          candidate = File.join(reviews_dir, "fix-guardrail-#{format('%02d', pass)}.md")
          return candidate if File.exist?(candidate)
        end

        if reason == "reviewer_partial_failure" && pass
          candidate = File.join(reviews_dir, "errors-#{format('%02d', pass)}.md")
          return candidate if File.exist?(candidate)
        end

        if reason != "fix_guardrail" && pass
          escalations = File.join(reviews_dir, "escalations-#{format('%02d', pass)}.md")
          return escalations if File.exist?(escalations)

          reviewer_files = review_waiting_reviewer_files(reviews_dir, pass)
          return reviewer_files.first if reviewer_files.size == 1
        end

        Dir.exist?(reviews_dir) ? reviews_dir : folder
      end

      def review_waiting_reviewer_files(reviews_dir, pass)
        return [] unless Dir.exist?(reviews_dir)

        reviewer_files = Dir[File.join(reviews_dir, "*-#{format('%02d', pass)}.md")]
                         .sort
                         .select { |path| review_waiting_reviewer_file?(File.basename(path)) }
        unresolved = reviewer_files.select { |path| file_has_unchecked_finding?(path) }
        unresolved.empty? ? reviewer_files : unresolved
      end

      def review_waiting_reviewer_file?(name)
        require "hive/stages/review"
        Hive::Stages::Review.reviewer_file?(name)
      end

      def file_has_unchecked_finding?(path)
        File.readlines(path).any? { |line| line =~ /^\s*-\s+\[\s*\]\s+/ }
      rescue Errno::ENOENT, Errno::EACCES
        false
      end

      def review_waiting_pass(row)
        raw = (row.attrs || {})["pass"]
        return nil unless raw.to_s.match?(/\A\d+\z/)

        pass = raw.to_i
        pass.positive? ? pass : nil
      end

      def review_waiting_reason(row)
        (row.attrs || {})["reason"].to_s
      end

      # Returns the messages to dispatch after the editor exits.
      # Manual path:               [InputEditorExited].
      # Auto-continue (re-run):    [InputEditorExited, DispatchCommand]
      #                            for `:proceed` (brainstorm complete)
      #                            and `:revise_plan` (user added plan
      #                            feedback). Both re-run the same
      #                            stage agent via `row.suggested_command`.
      # Auto-advance (next stage): [InputEditorExited, DispatchCommand]
      #                            for `:advance_to_develop` (plan
      #                            approved as-is — no content changes).
      # Auto-continue suppressed:  [InputEditorExited] OR
      #                            [InputEditorExited, Flash(reason)] for
      #                            race / data-anomaly cases the user
      #                            would otherwise be unable to diagnose
      #                            from the generic post-save flash alone.
      #
      # The rescue around `dispatch_command_for` catches the plain
      # `ArgumentError` raised by `Shellwords.split` on a malformed
      # `suggested_command` without swallowing constructor errors from
      # `InputEditorExited.new` (which lives outside the begin/rescue).
      def input_editor_exit_messages(row, path, exit_code, changed, content_changed, checkboxes_changed = false)
        exited = Hive::Tui::Messages::InputEditorExited.new(
          slug: row.slug,
          exit_code: exit_code,
          changed: changed
        )

        case auto_continue_outcome(row, path, exit_code, changed, content_changed, checkboxes_changed)
        when :proceed, :revise_plan
          dispatch_messages_for(row, exited)
        when :advance_to_develop
          dispatch_develop_for(row, exited)
        when :rerun_review
          dispatch_rerun_review_for(row, exited)
        when :empty_command
          [ exited, suppression_flash(row, "no suggested command on row") ]
        when :marker_changed
          [ exited, suppression_flash(row, "marker changed during edit") ]
        when :marker_unreadable
          # pr-review-toolkit round-5 H3: distinct from :marker_changed
          # so the user sees the real cause (couldn't read task.md)
          # instead of being told the marker drifted when it actually
          # might not have. Operators will look in the debug log
          # (`HIVE_TUI_DEBUG=1`) for the specific Errno class.
          [ exited, suppression_flash(row, "couldn't read marker — check task.md permissions") ]
        else # :silent — expected refusals (parser incomplete, exit nonzero, unchanged, off-stage)
          [ exited ]
        end
      end

      # U6 — dispatch the review verb (row.suggested_command) plus a
      # confirming flash so the user sees immediate feedback that a
      # multi-minute review pass has started. The flash also addresses
      # the UX risk that a snappy save-and-continue gesture sets up
      # the wrong expectation for a slow operation.
      #
      # pr-review-toolkit round-5 M3: scope the ArgumentError rescue
      # narrowly to the Shellwords.split call (which is the only
      # known source of ArgumentError on this path). A wider rescue
      # would falsely attribute a future Flash.new validation error
      # to "malformed suggested command".
      def dispatch_rerun_review_for(row, exited)
        dispatch =
          begin
            Hive::Tui::KeyMap.dispatch_command_for(row.suggested_command)
          rescue ArgumentError => e
            Hive::Tui::Debug.log("input_editor", "rerun-review parse failed for #{row.slug}: #{e.class}: #{e.message}")
            return [ exited, suppression_flash(row, "malformed suggested command: #{e.message}") ]
          end
        flash = Hive::Tui::Messages::Flash.new(
          text: "approved — starting next review pass for #{row.slug}"
        )
        [ exited, flash, dispatch ]
      end

      def dispatch_messages_for(row, exited)
        dispatch = Hive::Tui::KeyMap.dispatch_command_for(row.suggested_command)
        [ exited, dispatch ]
      rescue ArgumentError => e
        Hive::Tui::Debug.log("input_editor", "auto-continue skipped for #{row.slug}: #{e.message}")
        [ exited, suppression_flash(row, "malformed suggested command") ]
      end

      # Build a `hive develop <slug> ...` dispatch by swapping the verb
      # in the row's plan-stage `suggested_command`. Preserves
      # `--project` / `--from` flags so the develop spawn keeps the
      # same idempotency lever the plan command had.
      def dispatch_develop_for(row, exited)
        # The plan-stage `:waiting` marker is "agent finished, user
        # reviewing". `:advance_to_develop` means "user reviewed and
        # approved as-is" — that signal must be reflected on disk by
        # flipping the marker to `:complete` before `hive develop`
        # runs, because `hive develop --from 3-plan` refuses to
        # advance while the marker is `:waiting`. Diagnosed in the
        # `i-want-to-be-able-260507-7682` / `now-we-run-claude-codex-260508-3b8f`
        # bug report.
        #
        # Ordering rationale (post-review P2 #2): build and validate
        # the DispatchCommand FIRST, flip the marker SECOND, return
        # both together. The previous order flipped the marker
        # eagerly and only then validated the command — a malformed
        # `suggested_command` would leave the marker `:complete`
        # with no dispatch, an even worse state than the original
        # bug (the plan looked approved but the next stage never
        # started). Now if `develop_command_from_plan` raises, the
        # marker is still `:waiting` and the user can re-trigger
        # after fixing the row.
        dispatch = develop_command_from_plan(row.suggested_command)
        finalize_plan_marker(row)
        [ exited, dispatch ]
      rescue ArgumentError => e
        Hive::Tui::Debug.log("input_editor", "advance-to-develop skipped for #{row.slug}: #{e.message}")
        [ exited, suppression_flash(row, "couldn't build develop command") ]
      rescue MarkerRaceError => e
        Hive::Tui::Debug.log(
          "input_editor",
          "advance-to-develop marker-race for #{row.slug}: #{e.message}"
        )
        [ exited, suppression_flash(row, "plan marker changed during edit (#{e.observed})") ]
      rescue SystemCallError, IOError => e
        Hive::Tui::Debug.log(
          "input_editor",
          "advance-to-develop marker-finalize failed for #{row.slug}: #{e.class}: #{e.message}"
        )
        [ exited, suppression_flash(row, "couldn't finalize plan marker (#{e.class})") ]
      end

      # Raised by `finalize_plan_marker` when the marker on disk
      # drifted between the editor session and the finalize step —
      # e.g. a concurrent `hive run` advanced the marker. Surfaced
      # to the user as a suppression flash; no dispatch.
      class MarkerRaceError < StandardError
        attr_reader :observed

        def initialize(observed)
          @observed = observed
          super("expected :waiting, observed #{observed.inspect}")
        end
      end

      # Compare-and-set on the marker: re-read right before flipping
      # and refuse if the state drifted (post-review P2 #1). The
      # `marker_still_open_for_input?` check earlier in `plan_outcome`
      # ran when the editor closed; another actor (sibling `hive run`,
      # background daemon, hand-edit on a sync mount) could have
      # advanced the marker in the brief interval between that check
      # and this write. `Hive::Markers.set` is an atomic-rename write
      # and does NOT verify current state; without the CAS here we
      # would silently overwrite a newer marker.
      #
      # There's still a sub-microsecond TOCTOU between this read and
      # the subsequent write — closing that completely would need an
      # advisory flock around both ops, which the rest of the
      # codebase doesn't currently use for marker writes. The
      # observable race window goes from "duration of editor session"
      # down to "one read+rename" — orders of magnitude smaller.
      def finalize_plan_marker(row)
        current = Hive::Markers.current(row.state_file)
        unless current.name == :waiting
          raise MarkerRaceError, current.name
        end

        Hive::Markers.set(row.state_file, :complete)
      end

      def develop_command_from_plan(suggested_command)
        argv = Shellwords.split(suggested_command.to_s)
        unless argv.length >= 3 && argv[0] == "hive" && argv[1] == "plan"
          raise ArgumentError, "expected `hive plan ...`, got #{suggested_command.inspect}"
        end

        argv[1] = "develop"
        Hive::Tui::Messages::DispatchCommand.new(argv: argv, verb: "develop")
      end

      def suppression_flash(row, reason)
        Hive::Tui::Messages::Flash.new(text: "auto-continue skipped for #{row.slug}: #{reason}")
      end

      # Returns one of:
      #   :proceed             — fire DispatchCommand for brainstorm re-run
      #   :revise_plan         — fire DispatchCommand for plan re-run (user added feedback)
      #   :advance_to_develop  — fire DispatchCommand for `hive develop` (plan approved as-is)
      #   :rerun_review        — fire DispatchCommand for `hive run` on a 6-review row (U6 auto-continue)
      #   :silent              — refuse, common-case (user can self-diagnose)
      #   :empty_command       — refuse, surface to user (data anomaly)
      #   :marker_changed      — refuse, surface to user (race with another actor)
      #   :marker_unreadable   — refuse, surface to user (can't read task.md; check perms)
      #
      # `changed` is mtime-based ("did the user save at all"); `content_changed`
      # is hash-based ("did content actually differ"). Brainstorm gates on
      # `changed` (parser then decides). Plan needs `content_changed` to
      # distinguish "approved by saving without edits" (advance) from
      # "added feedback" (revise). 6-review gates on checkbox deltas
      # for legacy checkbox files, and on content changes for the
      # Q&A-style escalations file. A bare `:wq` still doesn't dispatch
      # a multi-minute review pass.
      def auto_continue_outcome(row, path, exit_code, changed, content_changed, checkboxes_changed = false)
        return :silent unless exit_code == 0
        return :silent unless row.action_key == "needs_input"

        case row.stage.to_s
        when "2-brainstorm" # coding-scoped: TUI extra panes are coding presentation work
          brainstorm_outcome(row, path, changed)
        when "3-plan" # coding-scoped: TUI extra panes are coding presentation work
          plan_outcome(row, path, exit_code, changed, content_changed)
        when "6-review" # coding-scoped: TUI extra panes are coding presentation work
          review_outcome(row, path, checkboxes_changed, content_changed)
        else
          :silent
        end
      end

      def brainstorm_outcome(row, path, changed)
        return :silent unless changed
        return :empty_command if row.suggested_command.to_s.empty?
        return :marker_changed unless marker_still_open_for_input?(path)
        return :silent unless Hive::Tui::BrainstormAnswers.complete?(path)

        :proceed
      end

      def plan_outcome(row, path, exit_code, _changed, content_changed)
        # The only safety gate is a clean editor exit. By design, an
        # exit-0 close on a `:waiting` plan row is a "user is done"
        # signal even when nothing was edited — see PR description on
        # advance-on-clean-exit. Aborts (SIGINT/130) take the manual
        # path so a half-typed plan isn't accidentally advanced.
        return :silent unless exit_code == 0
        return :marker_changed unless marker_still_open_for_input?(path)

        if content_changed
          return :empty_command if row.suggested_command.to_s.empty?

          :revise_plan
        else
          :advance_to_develop
        end
      end

      # U6 — auto-continue for 6-review needs_input rows. Review gates
      # have two user-edit surfaces:
      # - legacy checkbox files (reviewer files and fix-guardrail files)
      #   dispatch only when the [x]/[ ] counts changed.
      # - Q&A escalation files dispatch when their content changed so
      #   the user can answer `### A1.` in the same style as brainstorm.
      #
      # The marker must be re-read from row.state_file (NOT the editor
      # path, which is reviews/fix-guardrail-NN.md or
      # reviews/escalations-NN.md after input_editor_path resolution)
      # because the marker lives in task.md, not in the file the user
      # just edited.
      def review_outcome(row, path, checkboxes_changed, content_changed)
        actionable_change = checkboxes_changed || (content_changed && review_escalations_file?(path))
        return :silent unless actionable_change
        return :empty_command if row.suggested_command.to_s.empty?

        case review_marker_state(row)
        when :open then :rerun_review
        when :drifted then :marker_changed
        when :unreadable then :marker_unreadable
        end
      end

      def review_escalations_file?(path)
        File.basename(path.to_s).match?(/\Aescalations-\d{2}\.md\z/)
      end

      # pr-review-toolkit round-5 H3 + #13: tri-state replacement for
      # the round-3-era `review_marker_still_open?` predicate. The
      # old form collapsed "marker drifted to a different pass/reason"
      # and "couldn't read the state file" into the same `false`,
      # which `:marker_changed` then mis-described to the user as
      # "marker changed during edit" when the real failure was an
      # I/O error. Returning the explicit state lets `review_outcome`
      # route the I/O error case to a distinct outcome with an
      # accurate flash. The legacy direct-call shape (pass a path
      # instead of a Row) is dropped — every production and test
      # caller passes a Row.
      def review_marker_state(row)
        marker = Hive::Markers.current(row.state_file)
        return :drifted unless marker.name == :review_waiting

        row_attrs = row.attrs || {}
        marker_attrs = marker.attrs || {}
        return :drifted if row_attrs["pass"].to_s != marker_attrs["pass"].to_s
        return :drifted if row_attrs["reason"].to_s != marker_attrs["reason"].to_s

        :open
      rescue SystemCallError, IOError => e
        Hive::Tui::Debug.log("input_editor", "review marker check failed: #{e.class}: #{e.message}")
        :unreadable
      end

      # U6 — return the multiset of checkbox-line states in the file
      # as a normalized counts-Hash (`{ checked: N, unchecked: M }`).
      # Used pre- and post-edit to detect whether the user actually
      # ticked or cleared a box (vs. e.g. opening + bare :wq, or
      # editing non-checkbox prose). Lines other than `- [ ]` / `- [x]`
      # (title, prose, blank) are ignored — they cannot carry an
      # approval signal.
      #
      # pr-review-toolkit round-5 #5 (set-equivalence): the original
      # form returned `Array<Symbol>` preserving line order, so a user
      # who cut-pasted a `[x]` line to a different position triggered
      # `:rerun_review` even though no `[x]` count changed. Switching
      # to a counts Hash makes the comparison order-insensitive —
      # `{checked: 2, unchecked: 0} == {checked: 2, unchecked: 0}` is
      # true regardless of line position. Cleared boxes still count
      # (the unchecked count differs), so going from `[x] [x]` to
      # `[x] [ ]` still trips.
      #
      # pr-review-toolkit round-5 H2 (distinguish absent from
      # un-openable): ENOENT is normal (pre-edit on a fresh file).
      # EACCES / EISDIR / similar are diagnostic — log via
      # Hive::Tui::Debug and return a sentinel (an empty Hash with no
      # readable flag) the consumer can distinguish from "legitimately
      # zero checkboxes" if it wants. For backward-compat the consumer
      # `review_outcome` only cares about equality, so the EACCES case
      # also returns `{}` — a pre/post comparison still works (both
      # `{}` → no change → `:silent`), and the H2 risk (user's `[x]`
      # silently ignored due to mid-edit perms change) is bounded
      # because `review_marker_state` independently catches the
      # SystemCallError on the marker read.
      def read_checkbox_state(path)
        counts = { checked: 0, unchecked: 0 }
        File.foreach(path) do |line|
          if (m = line.match(/^\s*-\s+\[([ xX])\]\s+/))
            counts[m[1] == " " ? :unchecked : :checked] += 1
          end
        end
        counts
      rescue Errno::ENOENT
        # Pre-edit of a fresh file is the common case here.
        { checked: 0, unchecked: 0 }
      rescue Errno::EACCES, Errno::EISDIR, Errno::EIO, Errno::ENOTDIR => e
        Hive::Tui::Debug.log(
          "input_editor",
          "read_checkbox_state failed for #{path}: #{e.class}: #{e.message}"
        )
        { checked: 0, unchecked: 0 }
      end

      # Re-reads the on-disk marker after the editor exits to defend
      # against a race where another actor (a sibling `hive` process,
      # an editor on a sync mount) advanced the stage to
      # `:agent_working`, `:complete`, or `:error` while the long-lived
      # editor was open. The captured `row.marker` is from the snapshot
      # taken when Enter was pressed; only the freshly-read marker
      # reflects current truth. `:none` is permitted because the first
      # round of a fresh brainstorm/plan may have no marker yet.
      def marker_still_open_for_input?(path)
        marker = Hive::Markers.current(path)
        marker.name == :waiting || marker.name == :none
      rescue SystemCallError, IOError => e
        Hive::Tui::Debug.log("input_editor", "auto-continue marker check failed: #{e.class}: #{e.message}")
        false
      end

      # $VISUAL → $EDITOR → vi. Shellwords.split lets users carry
      # flags ("code --wait") without losing argv structure. An empty
      # split (e.g. quote-only $EDITOR) raises ArgumentError so the
      # caller flashes a setup hint instead of silently spawning vi.
      def editor_argv
        raw = ENV["VISUAL"].to_s
        raw = ENV["EDITOR"].to_s if raw.empty?
        raw = "vi" if raw.empty?
        argv = Shellwords.split(raw)
        raise ArgumentError, "empty $VISUAL/$EDITOR" if argv.empty?

        argv
      end

      # Delegates the spawn/wait/translate/ENOENT-rescue dance to
      # `Hive::Tui::Subprocess.run_takeover_child_sync` so editor
      # takeovers share the same BEGIN(interactive)/END(interactive)
      # / ERRNO(interactive) stamps that workflow-verb takeovers
      # write to `hive-tui-subprocess.log` — useful for diagnosing
      # "I pressed Enter on a needs_input row and the TUI froze"
      # reports. The shared helper also owns the foreground pgrp
      # contract, parent-side signal quiescing, and the ENOENT/EACCES
      # → COMMAND_NOT_FOUND_EXIT (127) translation.
      #
      # The pre-spawn `clear_terminal_for_takeover` stays here: it's
      # specific to the editor handoff and addresses a visual-only
      # bug (Ivan's "tui rendered above the editor, visual mess")
      # that doesn't apply to the workflow-verb takeover path.
      def run_editor(argv, path)
        clear_terminal_for_takeover
        Hive::Tui::Subprocess.run_takeover_child_sync(argv + [ path ])
      end

      # @api private
      # Reset cursor + erase main-screen content so a misbehaved
      # alt-screen exit (or a render-loop tick that fired between
      # exit_alt_screen and exec) cannot leave dashboard glyphs
      # underneath the editor's first paint. Two ANSI sequences:
      #   \e[2J  — clear entire screen
      #   \e[H   — cursor to home (top-left)
      # Stdout flush is explicit because bubbletea-ruby's exec
      # callable runs with the runner's render loop suspended, and
      # without the flush the bytes can sit in libc's buffer past
      # the spawn boundary.
      def clear_terminal_for_takeover
        return unless $stdout.tty?

        $stdout.write("\e[2J\e[H")
        $stdout.flush
      rescue IOError, Errno::EPIPE
        nil
      end

      def file_mtime(path)
        File.mtime(path).to_f
      rescue Errno::ENOENT, Errno::EACCES
        nil
      end

      # Content fingerprint used by the plan-stage auto-continue gate
      # to distinguish "user saved without editing" (advance to next
      # stage) from "user added feedback" (revise plan). SHA1 is
      # cryptographically weak but plenty for change detection on a
      # local file the user just edited; `Digest::SHA1.file` does a
      # single read and never raises on bytes (no encoding work).
      def file_content_hash(path)
        ::Digest::SHA1.file(path).hexdigest
      rescue SystemCallError, IOError
        nil
      end

      # 0.5s tick: long enough that a slow agent log doesn't cost a
      # poll per frame, short enough that fresh bytes feel live.
      # Symmetric with the curses path's per-frame poll cadence.
      LOG_TAIL_POLL_INTERVAL = 0.5

      # @api private
      def log_tail_poll_cmd
        Bubbletea.tick(LOG_TAIL_POLL_INTERVAL) { Hive::Tui::Messages::LOG_TAIL_POLL }
      end

      # Wrapper exposing `path`/`claude_pid_alive`/`lines(n)` to
      # Views::LogTail. Carries the underlying Tail so we can call
      # `close!` on Back without leaking file descriptors.
      class LogTailContext
        attr_reader :tail, :claude_pid_alive

        def initialize(tail:, claude_pid_alive:)
          @tail = tail
          @claude_pid_alive = claude_pid_alive
        end

        def path
          @tail.path
        end

        def lines(count)
          Hive::Tui::LogTail::Formatter.format_lines(@tail.lines(count))
        end
      end

      # `n` submission. Two paths depending on the composer buffer:
      #
      # * Plain text → shell out to `bin/hive new <project> <title>` via
      #   `Subprocess.run_quiet!` so the screen doesn't flash on every
      #   idea entry (the helper captures stdout/stderr cleanly).
      # * Rich (any staged attachments or `[imageN]` placeholders) →
      #   `submit_rich_new_idea` calls `Hive::Commands::New#call!`
      #   in-process and routes its stdout/stderr through `capture_io`
      #   so the success `puts` lines do NOT corrupt the alt-screen
      #   render.
      #
      # Project is resolved from either the explicit chooser target
      # (`new_idea_project_name`, set when `n` starts from ★ All
      # projects) or from a concrete project scope. Empty title or
      # no-projects-registered states flash an
      # error and return to :grid without spawning a child.
      #
      # Staging cleanup policy: every exit path either runs
      # `cleanup_new_idea_staging` before the model resets, or
      # deliberately preserves staging so the operator can retry.
      # See the `cleanup_new_idea_staging` / `apply_new_idea_cancelled`
      # / `submit_rich_new_idea` (rescue + ensure) call-sites for the
      # branch-by-branch contract.
      def submit_new_idea
        buffer = @hive_model.new_idea_buffer.to_s
        if rich_new_idea_buffer?(buffer)
          return submit_rich_new_idea(buffer)
        end

        title = buffer.strip
        # Empty submit is a likely fat-finger Enter; flash and stay in
        # the prompt so the operator can keep typing without re-opening
        # via `n`. The buffer is preserved so any leading whitespace
        # the operator typed isn't lost — strip happens at submit time
        # only for validation. Staging dir (if any) is preserved too
        # so the operator can re-paste images after correcting the
        # title; cleanup runs only when we leave :new_idea mode below.
        if title.empty?
          return [
            @hive_model.with(flash: "title required", flash_set_at: Time.now),
            nil
          ]
        end
        @hive_model = @hive_model.with(new_idea_broken_labels: []) unless @hive_model.new_idea_broken_labels.empty?

        project = Hive::Tui::Views::NewIdeaPrompt.resolve_project_name(@hive_model)
        if project.nil?
          flash = new_idea_resolution_flash(@hive_model)
          # If the operator had picked a concrete project via the picker
          # and it later went stale (snapshot poll dropped it or marked
          # it unhealthy), bounce back to the picker with the typed
          # buffer preserved — the flash advises "choose another
          # project", and Esc still cleanly discards everything. The
          # plain "no-projects" / "no scope" cases (no chosen name in
          # play) fall through to `reset_to_grid_with_flash` because
          # there's nothing to re-pick.
          chosen = @hive_model.new_idea_project_name.to_s
          if !chosen.empty? && @hive_model.scope.zero?
            return [
              @hive_model.with(
                mode: :new_idea_project,
                new_idea_project_name: nil,
                flash: flash,
                flash_set_at: Time.now
              ),
              nil
            ]
          end
          # `reset_to_grid_with_flash` clears `new_idea_staging_dir`
          # on the model; clean the on-disk dir first so orphaned
          # files don't leak after we drop the reference.
          cleanup_new_idea_staging unless @hive_model.new_idea_staging_dir.to_s.empty?
          return [ reset_to_grid_with_flash(flash), nil ]
        end

        # argv[0] must be the executable name. `Subprocess.run_quiet!`
        # invokes Open3.popen3(*cmd) directly, so a missing "hive" prefix
        # would exec a literal "new" binary and ENOENT (exit 127). Mirror
        # the canonical shape used by every other run_quiet! caller in
        # this file.
        argv = [ "hive", "new", project, title ]
        exit_code, _out, err = Hive::Tui::Subprocess.run_quiet!(argv)
        # User may have pasted an image and then deleted every
        # placeholder before submitting plain text. The buffer no
        # longer references the staging dir, but `@hive_model` still
        # carries it — clean both on disk and (via
        # `reset_to_grid_with_flash`) on the model so the orphaned
        # /tmp dir doesn't leak.
        cleanup_new_idea_staging unless @hive_model.new_idea_staging_dir.to_s.empty?
        if exit_code.zero?
          [ reset_to_grid_with_flash("+ #{title.inspect} → #{project}"), nil ]
        else
          msg = err.to_s.lines.first&.chomp || "hive new exit #{exit_code}"
          [ reset_to_grid_with_flash("new failed: #{msg}"), nil ]
        end
      rescue Hive::Error, SystemCallError, IOError => e
        # `Subprocess.run_quiet!` already swallows Errno::ENOENT
        # (returns synthetic [127, ...]), so this rescue covers the
        # narrower set of typed exceptions that escape the bounded
        # child. Aligned with the rich-submit rescue list: programmer-
        # error exceptions (NoMethodError, ArgumentError, NameError)
        # are intentionally not caught here — they bubble to the outer
        # `BubbleModel#update` rescue, which surfaces them as
        # `internal error: ...`. Stay in :new_idea and PRESERVE the
        # typed buffer so the operator can retry without retyping.
        Hive::Tui::Debug.log("submit_new_idea", "rescued #{e.class}: #{e.message}")
        [
          @hive_model.with(
            flash: "new failed: #{e.class.name.split('::').last}: #{e.message}",
            flash_set_at: Time.now
          ),
          nil
        ]
      end

      def rich_new_idea_buffer?(buffer)
        @hive_model.new_idea_attachments.any? || extract_image_labels(buffer).any?
      end

      def submit_rich_new_idea(buffer)
        # Staging-cleanup policy lives in this local flag so the
        # ensure-block has one source of truth: the happy path AND
        # any unexpected (programmer-error) exception both clean up;
        # the validation path and the typed-failure rescue both
        # PRESERVE the staging dir so the operator can retry without
        # re-pasting. Esc/cancel still triggers cleanup via
        # `apply_new_idea_cancelled`'s side-effect path.
        preserve_staging = false
        # Capture the staging dir at method entry so the ensure block
        # is independent of any later `@hive_model.with` reassignment
        # within this method's call tree.
        staging_dir_at_entry = @hive_model.new_idea_staging_dir
        staging_tmp_root_at_entry = @hive_model.new_idea_staging_tmp_root
        if (reason = rich_new_idea_validation_error(buffer))
          preserve_staging = true
          return [
            @hive_model.with(
              flash: reason,
              flash_set_at: Time.now,
              new_idea_broken_labels: rich_new_idea_broken_labels(buffer)
            ),
            nil
          ]
        end
        @hive_model = @hive_model.with(new_idea_broken_labels: []) unless @hive_model.new_idea_broken_labels.empty?

        project = Hive::Tui::Views::NewIdeaPrompt.resolve_project_name(@hive_model)
        if project.nil?
          preserve_staging = true
          flash = new_idea_resolution_flash(@hive_model)
          # Mirror the plain-text path: if the operator's picked project
          # went stale mid-compose, bounce back to the picker so they
          # can re-pick without losing the staged images. The flash
          # tells them what happened; Esc still cleans everything.
          chosen = @hive_model.new_idea_project_name.to_s
          if !chosen.empty? && @hive_model.scope.zero?
            return [
              @hive_model.with(
                mode: :new_idea_project,
                new_idea_project_name: nil,
                flash: flash,
                flash_set_at: Time.now
              ),
              nil
            ]
          end
          return [ @hive_model.with(flash: flash, flash_set_at: Time.now), nil ]
        end

        title = derive_rich_new_idea_title(buffer)
        body = render_rich_new_idea_body(buffer)
        tuples = rich_new_idea_attachment_tuples

        # `Hive::Commands::New#call!` `puts`-es two success lines
        # (`hive: captured …` + `next: mv …`). Swallow them via
        # `capture_io` so the alt-screen render is not corrupted by
        # raw stdout writes between bubbletea frames.
        capture_command_io do
          Hive::Commands::New.new(
            project,
            title,
            body_override: body,
            attachments: tuples
          ).call!
        end
        count = @hive_model.new_idea_attachments.size
        image_word = count == 1 ? "image" : "images"
        if derive_rich_new_idea_title_from_buffer_was_default?(buffer)
          [ reset_to_grid_with_flash(
              "+ #{title.inspect} → #{project} (#{count} #{image_word}); " \
              "titled 'task' — add words for a better slug"
            ), nil ]
        else
          [ reset_to_grid_with_flash("+ #{title.inspect} → #{project} (#{count} #{image_word})"), nil ]
        end
      # `Hive::Error` covers the typed family (ProjectNotFound,
      # InvalidSlugError, InvalidAttachmentError, SlugCollisionError,
      # ComposerStaging::WriteError). `SystemCallError` + `IOError`
      # cover the typed disk failures. `KeyError` from
      # `render_rich_new_idea_body`'s `attachments.fetch(label)` is
      # dead now that `rich_new_idea_validation_error` covers the
      # missing-attachment case before we render the body — listing it
      # here would be theatre that breaks if the validator's contract
      # ever changes.
      rescue Hive::Error, SystemCallError, IOError => e
        preserve_staging = true
        cause_class = e.respond_to?(:cause_class) ? e.cause_class : nil
        cause_label = cause_class || e.cause&.class || "(unknown cause)"
        Hive::Tui::Debug.log(
          "submit_new_idea",
          "rich submit failed #{e.class}(cause=#{cause_label}): #{e.message}"
        )
        sanitized = Hive::Tui::Text.sanitize(e.message)
        truncated = sanitized.length > 160 ? "#{sanitized[0, 159]}…" : sanitized
        # Preserve the buffer, attachments, AND staging dir so the
        # operator can correct the failure cause (register the
        # project, free disk space, etc.) and retry without re-typing
        # or re-pasting. ComposerStaging.ensure_dir! short-circuits
        # to the existing dir on retry, so per-attempt /tmp/ leaks
        # don't accumulate.
        [
          @hive_model.with(
            flash: "new failed: #{truncated}",
            flash_set_at: Time.now
          ),
          nil
        ]
      ensure
        # Programmer-error path: cleanup the disk dir AND clear the
        # model field. Without the model reset, the outer
        # `BubbleModel#update` rescue preserves `new_idea_staging_dir`,
        # so the next paste calls `ensure_dir!` which short-circuits to
        # the now-deleted path and ENOENTs on the first write.
        unless preserve_staging
          if staging_dir_at_entry && !staging_dir_at_entry.empty?
            begin
              cleanup_kwargs =
                if staging_tmp_root_at_entry.to_s.empty?
                  {}
                else
                  { tmproot: staging_tmp_root_at_entry }
                end
              Hive::Tui::ComposerStaging.cleanup!(staging_dir_at_entry, **cleanup_kwargs)
            rescue ArgumentError, SystemCallError, IOError => e
              Hive::Tui::Debug.log("new_idea_staging", "ensure cleanup: #{e.class}: #{e.message}")
            end
            if @hive_model.new_idea_staging_dir == staging_dir_at_entry
              @hive_model = @hive_model.with(
                new_idea_staging_dir: nil,
                new_idea_staging_tmp_root: nil
              )
            end
          end
        end
      end

      # Helper used by the success-flash hint: was the derived title
      # the "task" fallback (images-only / whitespace-only buffer)?
      # Shares `normalize_rich_new_idea_title_text` with
      # `derive_rich_new_idea_title` so the two derivations can't
      # drift apart on a future rewrite.
      def derive_rich_new_idea_title_from_buffer_was_default?(buffer)
        normalize_rich_new_idea_title_text(buffer).empty?
      end

      # Wraps `Hive::Commands::New#call!`'s `puts` lines so they don't
      # corrupt the alt-screen render. Falls back to `$stdout`/`$stderr`
      # redirection — `capture_io` from minitest is not available in
      # production.
      def capture_command_io
        orig_out = $stdout
        orig_err = $stderr
        $stdout = StringIO.new
        $stderr = StringIO.new
        yield
      ensure
        $stdout = orig_out
        $stderr = orig_err
      end

      def rich_new_idea_validation_error(buffer)
        labels = rich_new_idea_broken_labels(buffer)
        return nil if labels.empty?

        return "broken image placeholders: #{labels.join(', ')}" if labels.size > 1

        "broken image placeholder: #{labels.first}"
      end

      def rich_new_idea_broken_labels(buffer)
        placeholder_labels = extract_image_labels(buffer).map { |n| "image#{n}" }.to_set
        attachment_labels = @hive_model.new_idea_attachments.map(&:label).to_set

        broken = (placeholder_labels - attachment_labels).to_a +
                 (attachment_labels - placeholder_labels).to_a
        broken += @hive_model.new_idea_attachments.filter_map do |attachment|
          begin
            attachment.label unless File.exist?(attachment.staging_path)
          rescue SystemCallError
            # `Errno::ENAMETOOLONG` / `Errno::ELOOP` etc on a malformed
            # path — treat as "broken" rather than letting the generic
            # outer rescue swallow the staging-path information.
            attachment.label
          end
        end
        broken.uniq
      end

      def extract_image_labels(buffer)
        buffer.to_s.scan(/\[image(\d+)\]/).flatten.map(&:to_i)
      end

      def derive_rich_new_idea_title(buffer)
        stripped = normalize_rich_new_idea_title_text(buffer)
        stripped.empty? ? "task" : stripped
      end

      # Strip `[imageN]` placeholders and collapse whitespace to derive
      # the "what counts as user-supplied title text?" view of the
      # buffer. Single definition used by both the title-derivation
      # and the "was the default fallback used?" predicate so they
      # can't disagree about what counts as an empty title.
      def normalize_rich_new_idea_title_text(buffer)
        buffer.to_s.gsub(/\[image\d+\]/, " ").gsub(/\s+/, " ").strip
      end

      def render_rich_new_idea_body(buffer)
        attachments = attachments_by_label
        buffer.to_s.gsub(/\[image(\d+)\]/) do
          # Normalize the captured digits the same way
          # `rich_new_idea_validation_error` does (via `.to_i`) so a
          # manually edited zero-padded placeholder like `[image01]`
          # resolves to the canonical `image1` attachment label
          # instead of the literal `image01` (which would miss the
          # attachment map and raise `KeyError` after validation
          # already cleared the buffer for submit).
          number = Regexp.last_match(1).to_i
          label = "image#{number}"
          attachment = attachments.fetch(label)
          ext = attachment_extension(attachment)
          "![](assets/bug-#{number}.#{ext})"
        end
      end

      def rich_new_idea_attachment_tuples
        @hive_model.new_idea_attachments.map do |attachment|
          number = attachment.label.to_s.delete_prefix("image")
          [ attachment.staging_path, "bug-#{number}.#{attachment_extension(attachment)}" ]
        end
      end

      def attachments_by_label
        attachments = @hive_model.new_idea_attachments
        # Defensive guard: the monotonic counter on the model is the
        # primary defense against duplicate labels, but a regression
        # there would otherwise be silently masked by `.to_h` collapse.
        # Raise loudly so the next pass surfaces the drift instead of
        # silently overwriting one of the duplicate staging paths in
        # `copy_attachments!`.
        labels = attachments.map(&:label)
        if labels.uniq.size != labels.size
          dups = labels.tally.select { |_, n| n > 1 }.keys
          raise Hive::Error, "duplicate attachment labels: #{dups.join(', ')}"
        end

        attachments.to_h { |attachment| [ attachment.label, attachment ] }
      end

      # `Attachment.new` canonicalizes `ext` once at construction (see
      # `lib/hive/tui/model.rb`), so the field is already lowercased,
      # leading-dot stripped, and `png`-fallback-ed. Both
      # `render_rich_new_idea_body` and `rich_new_idea_attachment_tuples`
      # route through this single accessor so any future invariant
      # tightening lands in one place.
      def attachment_extension(attachment)
        attachment.ext
      end

      # Shared transition for every submit_new_idea exit path: clear the
      # buffer, return to :grid, set a flash. Three call sites in the
      # success/validation branches plus the rescue all funnel through
      # this so the mode/buffer/flash trio always moves together.
      def reset_to_grid_with_flash(text)
        @hive_model.with(
          mode: :grid,
          new_idea_project_name: nil,
          new_idea_project_cursor: 0,
          new_idea_buffer: "",
          new_idea_cursor: 0,
          new_idea_attachments: [],
          new_idea_staging_dir: nil,
          new_idea_staging_tmp_root: nil,
          new_idea_attachment_counter: 0,
          new_idea_broken_labels: [],
          flash: text,
          flash_set_at: Time.now
        )
      end

      # Build a flash for the case where new-idea resolution returned
      # nil. Distinguishes five reasons:
      # - no registered projects at all → "run `hive init <path>`"
      # - chosen project (via picker) now unhealthy → name the error +
      #   "choose another project" (caller bounces back to picker)
      # - chosen project name no longer present in snapshot → "is not
      #   available" + "choose another project" (caller bounces back)
      # - explicit scope onto an unhealthy project → name the error
      # - scope=0 (★ All) but every registered project is unhealthy
      # so the operator sees the actual cause rather than a generic
      # "no projects" message that doesn't match what they see in the
      # left pane (which shows the project, just broken).
      def new_idea_resolution_flash(model)
        snap = model.snapshot
        return "no projects — run `hive init <path>` first" if snap.nil? || snap.projects.empty?

        chosen = model.new_idea_project_name.to_s
        unless chosen.empty?
          project = snap.projects.find { |p| p.name == chosen }
          if project&.error
            return "project #{project.name.inspect} is #{project.error.gsub('_', ' ')} — choose another project or re-init it"
          end
          return "project #{chosen.inspect} is not available — choose another project" if project.nil?
        end

        if model.scope.between?(1, snap.projects.size)
          project = snap.projects[model.scope - 1]
          if project.error
            return "project #{project.name.inspect} is #{project.error.gsub('_', ' ')} — re-init, `hive forget #{project.name}`, or `hive prune`"
          end
        end

        # scope=0 with all-unhealthy projects, or scope out-of-range.
        # The recovery hint depends on the actual error mix: `hive prune`
        # only works for `missing_project_path` rows, so pointing at it
        # when every broken project is `not_initialised` would steer the
        # operator at a refusal. Branch on the error set so the suggested
        # action matches what's cleanup-eligible.
        broken = snap.projects.select(&:error)
        return "no projects — run `hive init <path>` first" if broken.size != snap.projects.size

        if broken.all? { |p| p.error == "missing_project_path" }
          "all registered projects are unhealthy — run `hive prune` to drop missing entries"
        else
          "all registered projects are unhealthy — re-init the broken ones or `hive forget` per-name"
        end
      end

      def flashed(text)
        @hive_model.with(flash: text, flash_set_at: Time.now)
      end

      # Filter mode: same two-pane composition as :grid mode, but the
      # footer line is replaced by the filter prompt. Bubble Tea diffs
      # against the previous frame so a one-line change paints cheaply.
      # Active flash (paste truncated, paste timed out, etc.) is stacked
      # above the prompt — `default_footer` is bypassed in this mode so
      # the flash would otherwise be invisible.
      def compose_filter_view
        usable = [ @hive_model.cols.to_i - 1, 1 ].max
        compose_two_pane_view(footer: prompt_footer(Views::FilterPrompt.render(@hive_model, width: usable), usable))
      end

      def compose_idea_preview_view
        usable = [ @hive_model.cols.to_i - 1, 1 ].max
        panel_height = [ @hive_model.rows.to_i - 1, 1 ].max
        Lipgloss.join_vertical(
          Lipgloss::TOP,
          Views::IdeaPreview.render(@hive_model, width: usable, height: panel_height),
          default_footer(usable)
        )
      end

      # New-idea mode: same composition; footer = the inline prompt with
      # the project label so the operator sees the resolved target.
      # Width clamps the prompt so long titles don't overflow the
      # terminal — the visible buffer slides to keep the cursor on
      # screen (see Views::NewIdeaPrompt.render).
      def compose_new_idea_view
        usable = [ @hive_model.cols.to_i - 1, 1 ].max
        compose_two_pane_view(footer: prompt_footer(Views::NewIdeaPrompt.render(@hive_model, width: usable), usable))
      end

      def compose_new_idea_project_view
        usable = [ @hive_model.cols.to_i - 1, 1 ].max
        compose_two_pane_view(
          footer: prompt_footer(Views::NewIdeaProjectPicker.render(@hive_model, width: usable), usable)
        )
      end

      # Stack an active flash above the prompt strip so error states
      # raised inside any prompt mode (`:new_idea`, `:new_idea_project`,
      # `:filter`) — paste truncated, title too long, decoder overflow,
      # paste timed out, waiting-for-snapshot, no-healthy-projects —
      # reach the operator. Without this the flash sets `model.flash`
      # but the prompt-mode views replace `default_footer` entirely, so
      # the flash never renders.
      def prompt_footer(prompt_strip, usable_width)
        flash = active_flash_line(usable_width)
        flash ? "#{flash}\n#{prompt_strip}" : prompt_strip
      end

      def active_flash_line(usable_width)
        return nil unless @hive_model.flash_active?

        line = @hive_model.flash.to_s
        line = Views::Format.truncate(line, usable_width) if usable_width
        Hive::Tui::Styles::FLASH.render(line)
      end

      # ---- v2 two-pane composition ----

      # Width threshold for the v2 two-pane layout — defined on Model
      # so render and focus layers share one source of truth. Re-exposed
      # here as a delegating reader so callers (and tests pinning the
      # boundary) keep their `BubbleModel::TWO_PANE_MIN_COLS` reference.
      TWO_PANE_MIN_COLS = Hive::Tui::Model::TWO_PANE_MIN_COLS

      # Compose the v2 two-pane layout: header strip + ProjectsPane |
      # TasksPane | footer strip. Below TWO_PANE_MIN_COLS the project
      # pane is suppressed and only the tasks pane renders; cross-project
      # context isn't lost because `header_strip` always carries the
      # `scope=` label in both width modes.
      def compose_two_pane_view(footer: nil)
        cols = @hive_model.cols.to_i
        rows = @hive_model.rows.to_i
        # Reserve a 1-cell right margin across every section so no row
        # ever lands a glyph in the terminal's last column. Header and
        # footer strips are width-aware — the fixed hint footer was
        # 75 chars regardless of terminal width and overflowed at
        # cols<76 before this clamp.
        usable = [ cols - 1, 1 ].max
        footer ||= default_footer(usable)
        sections = []
        sections << stalled_banner(usable) if stalled?
        pane_height = pane_height_for(rows: rows, fixed_sections: sections, footer: footer)
        if cols < TWO_PANE_MIN_COLS
          sections << Views::TasksPane.render(@hive_model, width: usable, height: pane_height)
        else
          sections << join_panes(cols, height: pane_height)
        end
        sections << footer
        sections.join("\n")
      end

      # Top strip — `hive tui · scope=… · filter=… · generated_at=…`.
      # Same content v1's Views::Grid#header_line carried, lifted to a
      # composer concern so the panes stay focused on their own boxes.
      def header_strip(usable_width = nil)
        scope_label = scope_label_for(@hive_model)
        filter_label = @hive_model.filter.to_s.empty? ? "-" : @hive_model.filter
        generated_at = @hive_model.snapshot&.generated_at || "-"
        line = "hive tui  scope=#{scope_label}  filter=#{filter_label}  generated_at=#{generated_at}"
        line = Views::Format.truncate(line, usable_width) if usable_width
        Hive::Tui::Styles::HEADER.render(line)
      end

      # Resolves model.scope to a human label. scope=0 → "★ All projects";
      # scope=N → the Nth registered project's name (matches TasksPane's
      # title resolution so the two surfaces never disagree). Falls
      # back to the integer if the snapshot is missing or the index is
      # out-of-range — at least the operator sees a non-empty value.
      def scope_label_for(model)
        return "★ All projects" if model.scope.zero?

        project = model.snapshot&.projects&.[](model.scope - 1)
        project ? project.name.to_s : model.scope.to_s
      end

      # Stalled-poll banner — surfaces transient StateSource errors so
      # the operator sees that the displayed snapshot is stale. Without
      # this, deleting v1 Views::Grid silently dropped the visual cue
      # (the previous snapshot stayed on screen with no indication).
      def stalled?
        !@hive_model.last_error.nil?
      end

      def stalled_banner(usable_width = nil)
        err = @hive_model.last_error
        klass = err.class.name.split("::").last
        msg = err.message.to_s.lines.first&.chomp.to_s[0, 60]
        line = msg.empty? ? "[stalled — #{klass}]" : "[stalled — #{klass}: #{msg}]"
        line = Views::Format.truncate(line, usable_width) if usable_width
        Hive::Tui::Styles::STALLED.render(line)
      end

      # Default footer — context-aware key hints + flash decay (the
      # status line). v1 had this in Views::Grid#status_line; lifted here
      # so the panes stay layout-only. `usable_width` clamps the line
      # so the fixed 75-char hint string doesn't overflow narrow
      # terminals (e.g. cols=70 used to wrap onto a second visible row).
      def default_footer(usable_width = nil)
        if @hive_model.flash_active?
          line = @hive_model.flash.to_s
          line = Views::Format.truncate(line, usable_width) if usable_width
          Hive::Tui::Styles::FLASH.render(line)
        else
          aggregate = usage_footer_aggregate
          if usable_width && usable_width < 80
            return Views::UsageFooter.render(aggregate: aggregate, width: usable_width)
          end

          line = "#{footer_hint} · #{Views::UsageFooter.text(aggregate)}"
          nudge = update_nudge
          # Prepend so truncation trims the hint tail, not the higher-priority
          # "you're behind" notice.
          line = "#{update_nudge_label(nudge)} · #{line}" if nudge
          line = Views::Format.truncate(line, usable_width) if usable_width
          Hive::Tui::Styles::HINT.render(line)
        end
      end

      UPDATE_NUDGE_TTL_SEC = 10

      def update_nudge_label(nudge)
        "update #{nudge.latest}: #{nudge.command}"
      end

      # Read the daemon-written nudge at most once per TTL window. Any error
      # (missing/corrupt state) degrades to "no nudge" so the footer never
      # breaks.
      def update_nudge
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        if @update_nudge_checked_at && (now - @update_nudge_checked_at) < UPDATE_NUDGE_TTL_SEC
          return @update_nudge_cache
        end

        @update_nudge_checked_at = now
        @update_nudge_cache = update_check_state&.nudge
      rescue StandardError
        @update_nudge_cache = nil
      end

      def update_check_state
        @update_state ||= Hive::UpdateCheck::State.new
      rescue StandardError
        nil
      end

      def usage_footer_line(usable_width = nil)
        Views::UsageFooter.render(aggregate: usage_footer_aggregate, width: usable_width)
      end

      def usage_footer_aggregate
        scope = derive_usage_scope(@hive_model)
        key = [
          @hive_model.snapshot&.object_id,
          @hive_model.snapshot&.generated_at,
          scope[:project_slug],
          scope[:task_slug]
        ]
        unless key == @usage_footer_cache_key
          @usage_footer_cache_key = key
          @usage_footer_cache_aggregate = Hive::UsageDb.aggregate(scope: scope)
        end
        @usage_footer_cache_aggregate
      end

      def derive_usage_scope(model)
        if model.pane_focus == :left && model.scope.positive?
          project = project_name_for_scope(model)
          return project ? { project_slug: project } : {}
        end

        row = current_row if model.pane_focus == :right
        return { project_slug: row.project_name, task_slug: row.slug } if row

        {}
      end

      def project_name_for_scope(model)
        return nil if model.snapshot.nil? || model.scope.to_i <= 0

        model.snapshot.projects[model.scope - 1]&.name
      end

      def footer_hint
        "[Tab] switch  [Enter] action  [n] new  [/] filter  [?] help  [i] info  [q] quit"
      end

      # Compute pane widths and join horizontally. Left pane is clamped
      # to [18, 28] cells with a soft preference for cols * 0.25 — wide
      # enough for typical project names ("myapp", "appcrawl"),
      # narrow enough not to crowd the tasks table on standard terminals.
      def join_panes(cols, height: nil)
        left_width = pane_widths(cols).first
        right_width = pane_widths(cols).last
        Lipgloss.join_horizontal(
          Lipgloss::TOP,
          Views::ProjectsPane.render(@hive_model, width: left_width, height: height),
          Views::TasksPane.render(@hive_model, width: right_width, height: height)
        )
      end

      def pane_height_for(rows:, fixed_sections:, footer:)
        fixed_lines = fixed_sections.sum { |section| rendered_line_count(section) }
        footer_lines = rendered_line_count(footer)
        [ rows - fixed_lines - footer_lines, 1 ].max
      end

      def rendered_line_count(section)
        section.to_s.lines.count
      end

      # Visible for tests so the width formula stays inspectable without
      # rendering. Returns [left_width, right_width].
      #
      # Right pane gets `cols - left - 1`: leaves a 1-cell right margin
      # so the bordered-box's rightmost glyph (`│` / `╮` / `╯`) lands
      # at column `cols - 2`, not `cols - 1`. Some terminals (and some
      # PTY/tmux configs) don't reliably render the last column —
      # writing the right border one cell shy guarantees it's visible.
      # The alternative (writing border to the last column) loses the
      # right edge on those terminals; the alternative (joining panes
      # with extra spacing) wastes the same cell anyway.
      def pane_widths(cols)
        soft = (cols * 0.25).floor
        left = soft.clamp(18, 28)
        right = [ cols - left - 1, 1 ].max
        [ left, right ]
      end
    end
  end
end
