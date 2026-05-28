# frozen_string_literal: true

module DiscourseAcademicNav
  class WebhookReceipt < ActiveRecord::Base
    self.table_name = "academic_nav_webhook_receipts"
  end
end
