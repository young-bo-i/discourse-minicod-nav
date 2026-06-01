# frozen_string_literal: true

module DiscourseMinicodNav
  module Admin
    class DashboardsController < ::Admin::AdminController
      requires_plugin "discourse-minicod-nav"

      def show
        range = 24.hours.ago..Time.zone.now

        # One indexed scan over (status, created_at) instead of three separate
        # COUNTs. Status buckets may include "queued" / "ok" / "skipped" /
        # "error" — sum gives the total.
        by_status = WebhookReceipt.where(created_at: range).group(:status).count
        ok = by_status["ok"].to_i
        skipped = by_status["skipped"].to_i
        queued = by_status["queued"].to_i
        errored = by_status["error"].to_i
        total = by_status.values.sum

        base = Discourse.base_url
        render json: {
          plugin_enabled: SiteSetting.minicodnav_plugin_enabled,
          webhook_urls: {
            pavlovia: "#{base}/minicod-nav/webhook/pavlovia",
            journal: "#{base}/minicod-nav/webhook/journal",
          },
          secret_configured: {
            pavlovia: SiteSetting.minicodnav_webhook_secret_pavlovia.to_s.present?,
            journal: SiteSetting.minicodnav_webhook_secret_journal.to_s.present?,
          },
          map_count: ResourceMap.count,
          receipts_24h: {
            ok: ok,
            skipped: skipped,
            queued: queued,
            error: errored,
            total: total,
          },
          last_receipt_at: WebhookReceipt.maximum(:created_at),
        }
      end
    end
  end
end
