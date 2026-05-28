# frozen_string_literal: true

module DiscourseAcademicNav
  module Admin
    class ReceiptsController < ::Admin::AdminController
      requires_plugin "discourse-academic-nav"

      def index
        limit = params[:limit].to_i
        limit = 100 if limit <= 0 || limit > 500
        receipts = WebhookReceipt.order(created_at: :desc).limit(limit)
        render json: { data: receipts.as_json }
      end
    end
  end
end
