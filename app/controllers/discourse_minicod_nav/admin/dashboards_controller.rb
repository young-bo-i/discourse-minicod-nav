# frozen_string_literal: true

module DiscourseMinicodNav
  module Admin
    class DashboardsController < ::Admin::AdminController
      requires_plugin "discourse-minicod-nav"

      def show
        range = 24.hours.ago..Time.zone.now
        receipts = WebhookReceipt.where(created_at: range)
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
            ok: receipts.where(status: "ok").count,
            skipped: receipts.where(status: "skipped").count,
            total: receipts.count,
          },
          last_receipt_at: WebhookReceipt.maximum(:created_at),
        }
      end
    end
  end
end
