module Hive
  module Commands
    module ServiceInstaller
      # Value object returned by ServiceInstaller::Base#install!. Carries the
      # raw outcome `kind` plus the only two pieces of result state that vary
      # per install (`backup_path`, `restarted`), and centralizes the
      # kind -> wire-string mapping and the success/failure classification
      # that both the bot and daemon command layers consume.
      #
      # Centralizing here kills the duplicated `case` mapping the two callers
      # used to carry independently (which could drift), and an unknown kind
      # raises in the constructor rather than silently degrading to a
      # false-error envelope. `backup_path`/`restarted` are only ever set on
      # an `:upgraded` install, so the "meaningful only on upgrade" invariant
      # is structural — callers read them unconditionally.
      class Outcome
        # kind (symbol) -> wire outcome string emitted in install envelopes.
        # `:autostart_unavailable` deliberately collapses to "unsupported":
        # the unit was written but no service manager could enable it (e.g.
        # Linux without systemd-user), which is a known-platform limitation
        # reported as a success outcome, not a software failure.
        WIRE = {
          written: "written",
          upgraded: "upgraded",
          unchanged: "unchanged",
          autostart_unavailable: "unsupported",
          unsupported: "unsupported",
          drifted: "drifted",
          failed: "failed"
        }.freeze

        # Kinds that exit 0 and emit a success envelope. Everything else
        # (`:drifted`, `:failed`) raises and emits an error envelope.
        SUCCESS_KINDS = %i[written upgraded unchanged autostart_unavailable unsupported].freeze

        attr_reader :kind, :backup_path, :restarted

        def initialize(kind, backup_path: nil, restarted: false)
          unless WIRE.key?(kind)
            raise ArgumentError, "unknown install outcome #{kind.inspect}"
          end

          @kind = kind
          @backup_path = backup_path
          @restarted = restarted
        end

        def wire_outcome
          WIRE.fetch(kind)
        end

        def success?
          SUCCESS_KINDS.include?(kind)
        end

        def drifted?
          kind == :drifted
        end

        def failed?
          kind == :failed
        end
      end
    end
  end
end
