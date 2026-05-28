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
require_relative "lib/discourse_minicod_nav/synchronizer"
require_relative "lib/discourse_minicod_nav/snapshot_fetcher"

register_asset "stylesheets/common/minicod-nav.scss"

after_initialize do
  add_admin_route "minicod_nav.title", "minicod-nav"

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

  # Mount a small Rails::Engine (same pattern as discourse-poll) so the route is registered
  # reliably; a bare `post` inside `routes.append` was not matching and returned HTML 404.
  Discourse::Application.routes.append { mount DiscourseMinicodNav::Engine, at: "/minicod-nav" }
end
