# frozen_string_literal: true

# name: discourse-minicod-nav
# about: Syncs resources from Resource Station (Pavlovia + Journal) into Discourse topics.
# version: 0.1.0
# authors: EnterScholar
# url: https://github.com/young-bo-i/discourse-minicod-nav

enabled_site_setting :minicodnav_plugin_enabled

require_relative "lib/discourse_minicod_nav/engine"
require_relative "lib/discourse_minicod_nav/resource_map"
require_relative "lib/discourse_minicod_nav/webhook_receipt"
require_relative "lib/discourse_minicod_nav/snapshot_run"
require_relative "lib/discourse_minicod_nav/synchronizer"
require_relative "lib/discourse_minicod_nav/snapshot_fetcher"

register_asset "stylesheets/common/minicod-nav.scss"

SEO_CUSTOM_FIELDS = %w[
  minicodnav_meta_description
  minicodnav_og_title
  minicodnav_og_image
  minicodnav_meta_keywords
].freeze

after_initialize do
  add_admin_route "minicod_nav.title", "minicod-nav"

  # register_custom_field_type — typed access on the model.
  # register_topic_preloaded_custom_field — adds the field to TopicView's eager
  # custom-fields preload so the html_builder hook below reads them off the
  # already-loaded topic. Without this, every topic page view (synced or not)
  # issued an extra SELECT FROM topic_custom_fields just for the hook to find
  # that the topic doesn't have any of these keys.
  SEO_CUSTOM_FIELDS.each do |f|
    Topic.register_custom_field_type(f, :string)
    register_topic_preloaded_custom_field(f) if respond_to?(:register_topic_preloaded_custom_field)
  end

  # Resource Station Outbox may burst hundreds of signed POSTs during load tests.
  # Skip Discourse global IP rate limits for this server-to-server endpoint only.
  Middleware::RequestTracker.prepend(
    Module.new do
      def rate_limit(request, cookie)
        path = request.path_info.to_s
        return nil if path.start_with?("/minicod-nav/webhook/")

        super
      end
    end,
  )

  # Per-IP allowlist for upstream openscholay hosts. Parsed once at register
  # time + cached in a thread-local lambda so the per-request callback is just
  # a single Array#any? on parsed IPAddr objects (no SiteSetting hit, no
  # IPAddr.new on the hot path). Operator updates the setting → operator
  # rebuilds / restarts to pick it up (this matches Discourse's own
  # STATIC_IP_SKIPPER lifecycle from DISCOURSE_MAX_REQS_PER_IP_EXCEPTIONS).
  begin
    raw = SiteSetting.minicodnav_upstream_ip_allowlist.to_s
    entries = raw.split(/[,\s]+/).reject(&:blank?)
    parsed = entries.filter_map do |entry|
      begin
        IPAddr.new(entry)
      rescue IPAddr::InvalidAddressError
        Rails.logger.warn("[minicodnav] invalid upstream IP allowlist entry: #{entry}")
        nil
      end
    end

    if parsed.any? && !Middleware::RequestTracker.ip_skipper
      Middleware::RequestTracker.register_ip_skipper do |ip|
        begin
          addr = IPAddr.new(ip)
          parsed.any? { |range| range.include?(addr) }
        rescue StandardError
          false
        end
      end
    end
  rescue StandardError => e
    Rails.logger.warn("[minicodnav] could not register upstream IP skipper: #{e.class}: #{e.message}")
  end

  # Mount a small Rails::Engine (same pattern as discourse-poll) so the route is registered
  # reliably; a bare `post` inside `routes.append` was not matching and returned HTML 404.
  Discourse::Application.routes.append { mount DiscourseMinicodNav::Engine, at: "/minicod-nav" }

  # Contract v1.6 §4.6: emit upstream-curated SEO meta tags into <head> for
  # synced topics. Discourse generates its own default og:* tags; the duplicates
  # we add here come after those in source order, and search engines / scrapers
  # generally take the more specific value. No-op for topics without these
  # custom fields, so non-synced topics are unaffected.
  register_html_builder("server:before-head-close") do |controller|
    topic = controller.instance_variable_get(:@topic_view)&.topic
    next "" unless topic

    cf = topic.custom_fields
    parts = []

    if (desc = cf["minicodnav_meta_description"].to_s).strip.present?
      esc = CGI.escapeHTML(desc)
      parts << %(<meta name="description" content="#{esc}">)
      parts << %(<meta property="og:description" content="#{esc}">)
    end

    if (otitle = cf["minicodnav_og_title"].to_s).strip.present?
      parts << %(<meta property="og:title" content="#{CGI.escapeHTML(otitle)}">)
    end

    if (oimg = cf["minicodnav_og_image"].to_s).strip.present?
      parts << %(<meta property="og:image" content="#{CGI.escapeHTML(oimg)}">)
    end

    if (kw = cf["minicodnav_meta_keywords"].to_s).strip.present?
      parts << %(<meta name="keywords" content="#{CGI.escapeHTML(kw)}">)
    end

    parts.join("\n")
  end
end
