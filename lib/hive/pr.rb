require "uri"

module Hive
  # PR-URL helpers shared by every surface that displays a pull-request
  # link: the `hive status` command, the TUI tasks pane, and the Telegram
  # bot. Keeping `number`/`valid_http_url?` here is what stops those
  # surfaces from drifting apart on how a PR number is parsed or which
  # hrefs are considered safe.
  module Pr
    module_function

    # Visible width of the `#NNN` PR column, shared by every surface that
    # renders the PR cell (`hive status` text mode via
    # `Hive::Commands::Status::TEXT_PR_WIDTH` and the TUI tasks pane via
    # `Hive::Tui::Views::TasksPane::PR_WIDTH`). Sourcing both from this one
    # constant makes a one-sided width change — which would silently
    # misalign the two surfaces — structurally impossible. PR numbers
    # ≥ 100000 (7+ chars) exceed this cell on purpose; the plan accepts that
    # cap. The two surfaces handle the overflow differently — text mode
    # overflows the cell (`String#rjust` keeps the full token) while the TUI
    # truncates it (`#1000…` via `rjust_cells`) — see the sibling
    # `Hive::Tui::Views::TasksPane::PR_WIDTH` "overflow/truncate" note.
    NUMBER_WIDTH = 6

    # Extract the `#NNN` PR number from a URL whose path ends in
    # `/pull/<digits>`, or nil otherwise. Host-agnostic (any host, or none),
    # and tolerant of a single trailing slash plus a `?query`/`#fragment`
    # suffix — e.g. `…/pull/12`, `…/pull/12/`, and `…/pull/12?diff=split`
    # all yield `#12`. Returns nil for a missing URL or any other path,
    # including deeper pull-request sub-views like `…/pull/12/files`.
    def number(url)
      match = url.to_s.strip.match(%r{(?:\A|/)pull/(\d+)/?(?:[?#].*)?\z})
      match ? "##{match[1]}" : nil
    end

    def identifier_to_number(identifier)
      value = identifier.to_s.strip

      match = value.match(/\A#?(\d+)\z/)
      return match[1].to_i if match

      pr_number = number(value)
      return pr_number.delete_prefix("#").to_i if pr_number

      raise ArgumentError,
            "invalid PR identifier #{identifier.inspect}; pass a PR number, #number, or GitHub pull request URL"
    end

    # Injection-gating predicate shared by the OSC 8 (TUI) and HTML (bot)
    # link builders: true only for a parseable http(s) URL with a non-empty
    # host. This is the check that rejects `javascript:` and other non-http
    # schemes, so a future hardening (e.g. host allow-listing) tightens both
    # link surfaces at once instead of one silently lagging the other.
    # `url.to_s` keeps this total and symmetric with `number` — a nil or
    # non-String argument degrades to false rather than raising TypeError.
    def valid_http_url?(url)
      uri = URI.parse(url.to_s)
      uri.is_a?(URI::HTTP) && !uri.host.to_s.empty?
    rescue URI::InvalidURIError
      false
    end
  end
end
