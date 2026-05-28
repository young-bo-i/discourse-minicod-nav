# frozen_string_literal: true

module DiscourseAcademicNav
  module Admin
    class DashboardsController < ::Admin::AdminController
      requires_plugin "discourse-academic-nav"

      def show
        range = 24.hours.ago..Time.zone.now
        receipts = WebhookReceipt.where(created_at: range)
        render json: {
          plugin_enabled: SiteSetting.acadnav_plugin_enabled,
          target_category_id: SiteSetting.acadnav_target_category_id,
          archived_tag: SiteSetting.acadnav_archived_tag,
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
