# frozen_string_literal: true

# name: discourse-academic-nav
# about: Syncs resources from Resource Station (Pavlovia + S.H.*.T) into Discourse topics.
# version: 0.1.0
# authors: EnterScholar
# url: https://github.com/yourorg/discourse-academic-nav

enabled_site_setting :acadnav_plugin_enabled

require_relative "lib/discourse_academic_nav/engine"
require_relative "lib/discourse_academic_nav/resource_map"
require_relative "lib/discourse_academic_nav/webhook_receipt"
require_relative "lib/discourse_academic_nav/synchronizer"

register_asset "stylesheets/common/academic-nav.scss"

after_initialize do
  add_admin_route "academic_nav.title", "academic-nav"

  # Resource Station Outbox may burst hundreds of signed POSTs during load tests.
  # Skip Discourse global IP rate limits for this server-to-server endpoint only.
  Middleware::RequestTracker.prepend(
    Module.new do
      def rate_limit(request, cookie)
        path = request.path_info.to_s
        return nil if path == "/academic-nav/webhook"

        super
      end
    end,
  )

  # Mount a small Rails::Engine (same pattern as discourse-poll) so the route is registered
  # reliably; a bare `post` inside `routes.append` was not matching and returned HTML 404.
  Discourse::Application.routes.append { mount DiscourseAcademicNav::Engine, at: "/academic-nav" }
end
