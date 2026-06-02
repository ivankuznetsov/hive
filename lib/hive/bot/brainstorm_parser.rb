# frozen_string_literal: true

require "hive/brainstorm_parser"

module Hive
  module Bot
    # Back-compat alias. The parser moved to the top-level
    # `Hive::BrainstormParser` so the daemon can share it (gating
    # auto-resume until every brainstorm question is answered). All
    # existing `Hive::Bot::BrainstormParser.*` call sites and
    # `BrainstormParser::Question` references resolve through this alias.
    BrainstormParser = Hive::BrainstormParser
  end
end
