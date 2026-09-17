require "nokogiri"
require "uri"
require "digest"

module HiveDemo
  # Structural hardening for exported fragments. Live controls, remote media,
  # executable content, and unreviewed destinations fail closed or are removed
  # with a visible replacement, never silently reconnected.
  module Static
    ALLOWED_TAGS = %w[
      a article aside blockquote br caption code dd del details div dl dt em
      figcaption h1 h2 h3 h4 h5 h6 header hr li main nav ol p pre section span
      strong summary table tbody td th thead time tr ul button
    ].freeze

    ALLOWED_ATTRIBUTES = %w[
      id class href title role open hidden tabindex colspan scope datetime
      target rel type name value
    ].freeze

    DATA_ATTRIBUTE_ALLOW = /\Adata-(?:project|project-name|workflow|stage|task-slug|primary-artifact|diff-section|workspace-disclosure-key|artifact-name|record-id|module-name|module-state|workflow-origin|workflow-selection|snapshot-action|snapshot-label|change-state|kind|scope|review-id|review-state)\z/
    DATA_ATTRIBUTE_STRIP = /\Adata-(?:controller|action|.*-target|.*-value|turbo(?:-.*)?|kanban-column|project-filter|status-refresh|task-workspace|answers|artifacts|composer|navigation|avatar)\z/

    REMOTE_MEDIA_TAGS = %w[img video audio iframe object embed picture source].freeze
    EXTERNAL_HOSTS = %w[github.com hivecli.sh].freeze
    LIVE_INTERNAL_PATH = %r{\A/(?:agents|telegram|sessions|login|logout|ideas|api)(?:/|\z)}.freeze

    module_function

    def fragment(html)
      node = Nokogiri::HTML.fragment(html)
      unwrap_lazy_frames!(node)
      replace_media!(node)
      normalize_kanban!(node)
      normalize_controls!(node)
      strip_live_attributes!(node)
      rewrite_destinations!(node)
      validate!(node)
      node.to_html
    end

    def normalize_kanban!(node)
      node.css(".kanban-fold-icon").remove
      node.css("button.kanban-column-toggle").each do |button|
        button.replace(button.children)
      end
    end

    def unwrap_lazy_frames!(node)
      node.css("turbo-frame").each do |frame|
        raise "Lazy frame is not static: #{frame['src']}" if frame["src"]

        frame.replace(frame.children)
      end
    end

    def replace_media!(node)
      node.css(REMOTE_MEDIA_TAGS.join(", ")).each do |media|
        label = media["alt"].presence || media["title"].presence || media.name
        media.replace(element(node, "span", "snapshot-media-omitted", "[media omitted from the saved snapshot: #{label}]"))
      end
      node.css("svg").remove
    end

    def normalize_controls!(node)
      node.css("form, select, textarea, input, label, script, style, link, meta").each do |control|
        raise "Unapproved live element in the exported snapshot: #{control.name}"
      end
      node.css("button").each do |button|
        raise "Unapproved button without a snapshot explanation: #{button.text.strip}" unless button["data-snapshot-action"]
      end
    end

    def strip_live_attributes!(node)
      node.css("*").each do |element|
        element.attribute_nodes.each do |attribute|
          next unless attribute.name.start_with?("data-")
          next if DATA_ATTRIBUTE_ALLOW.match?(attribute.name)

          attribute.remove if DATA_ATTRIBUTE_STRIP.match?(attribute.name)
        end
      end
    end

    def rewrite_destinations!(node)
      node.css("a[href]").each do |anchor|
        href = anchor["href"].to_s
        raise "Live application path is not static: #{href}" if LIVE_INTERNAL_PATH.match?(href)
        if href.start_with?("#", "/")
          next
        elsif allowed_external?(href)
          anchor["rel"] = "noopener noreferrer"
          anchor["target"] = "_blank"
        else
          anchor.replace(element(node, "span", "snapshot-link-omitted", "#{anchor.text} (link not exported)"))
        end
      end
    end

    def allowed_external?(href)
      uri = URI.parse(href)
      uri.scheme == "https" && EXTERNAL_HOSTS.include?(uri.host)
    rescue URI::InvalidURIError
      false
    end

    def element(node, name, css_class, text)
      replacement = Nokogiri::XML::Node.new(name, node.document)
      replacement["class"] = css_class
      replacement.content = text
      replacement
    end

    def validate!(node)
      node.css("*").each do |element|
        raise "Unapproved active element: #{element.name}" unless ALLOWED_TAGS.include?(element.name)
        element.attribute_nodes.each do |attribute|
          name = attribute.name
          next if ALLOWED_ATTRIBUTES.include?(name)
          next if name.start_with?("aria-")
          next if DATA_ATTRIBUTE_ALLOW.match?(name)
          raise "Unapproved attribute #{name} on #{element.name}"
        end
        raise "Unapproved src on #{element.name}" if element["src"]
      end
      true
    end
  end
end
