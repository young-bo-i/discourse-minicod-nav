# frozen_string_literal: true

module DiscourseMinicodNav
  class WebhookReceipt < ActiveRecord::Base
    self.table_name = "minicod_nav_webhook_receipts"
  end
end
