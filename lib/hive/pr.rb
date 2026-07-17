require "uri"

module Hive
  # PR helpers shared across surfaces. Two roles live here:
  #   * Display helpers (`number`, `valid_http_url?`, `NUMBER_WIDTH`) shared by
  #     every surface that renders a pull-request link — the `hive status`
  #     command, the TUI tasks pane, and the Telegram bot — so those surfaces
  #     can't drift on how a PR number is parsed or which hrefs are safe.
  #   * The command-input parser `identifier_to_number`, which normalises a
  #     user-supplied PR argument (number, #number, or URL) for ad-hoc review.
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

    # Parse a user-supplied PR argument — a bare number, `#number`, or a
    # GitHub pull-request URL — into an Integer PR number. Unlike `number`
    # (which returns nil for unparseable input, since it scans display URLs),
    # this is a strict command-input parser: it RAISES ArgumentError on junk
    # so `hive review --pr <garbage>` fails loudly as a usage error rather
    # than silently materialising the wrong PR.
    def identifier_to_number(identifier)
      value = identifier.to_s.strip

      parsed =
        if (match = value.match(/\A#?(\d+)\z/))
          match[1].to_i
        elsif (pr_number = number(value))
          pr_number.delete_prefix("#").to_i
        end

      # A real PR number is always >= 1. `0`, `#0`, and `…/pull/0` all parse
      # to a non-positive Integer that would otherwise yield a bogus
      # `adhoc-review-pr-0` slug, a doomed `gh pr view 0`, and a false
      # collision against any pr.md lacking a pr_number (nil.to_i == 0).
      # Reject it here so the parser stays loud on junk rather than
      # materialising the wrong PR.
      return parsed if parsed&.positive?

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

    def canonical_identity(url)
      uri = URI.parse(url.to_s.strip)
      match = uri.path.match(%r{\A/([^/]+)/([^/]+)/pull/(\d+)/?\z})
      unless uri.is_a?(URI::HTTP) && !uri.host.to_s.empty? && match &&
             uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil? && match[3].to_i.positive?
        raise ArgumentError, "invalid canonical pull request URL"
      end

      host = uri.host.downcase
      owner = match[1]
      repository_name = match[2].sub(/\.git\z/i, "")
      number = match[3].to_i
      {
        "repository" => "#{host}/#{owner.downcase}/#{repository_name.downcase}",
        "number" => number,
        "url" => "https://#{host}/#{owner.downcase}/#{repository_name.downcase}/pull/#{number}"
      }
    rescue URI::InvalidURIError
      raise ArgumentError, "invalid canonical pull request URL"
    end
  end
end
