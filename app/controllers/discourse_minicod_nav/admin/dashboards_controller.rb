# frozen_string_literal: true

module DiscourseMinicodNav
  module Admin
    class DashboardsController < ::Admin::AdminController
      requires_plugin "discourse-minicod-nav"

      def show
        range = 24.hours.ago..Time.zone.now
        receipts = WebhookReceipt.where(created_at: range)
        render json: {
          plugin_enabled: SiteSetting.minicodnav_plugin_enabled,
          target_category_id: SiteSetting.minicodnav_target_category_id,
          archived_tag: SiteSetting.minicodnav_archived_tag,
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
