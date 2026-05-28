# frozen_string_literal: true

# 清空插件映射表，并删除曾由 Minicodhook 同步创建的话题。
# 在 Discourse 容器内执行，例如:
#   sudo -H -E -u discourse bash -lc 'cd /var/www/discourse && bin/rails runner plugins/discourse-minicod-nav/scripts/clear_sync_data.rb'

unless defined?(DiscourseMinicodNav::ResourceMap)
  puts "[minicodnav] plugin tables not found — run plugin migrations first"
  exit 1
end

topic_ids = DiscourseMinicodNav::ResourceMap.pluck(:topic_id).uniq
receipts = DiscourseMinicodNav::WebhookReceipt.count
maps = DiscourseMinicodNav::ResourceMap.count

puts "[minicodnav] maps=#{maps} receipts=#{receipts} topics_to_remove=#{topic_ids.size}"

DiscourseMinicodNav::ResourceMap.delete_all
DiscourseMinicodNav::WebhookReceipt.delete_all

actor = Discourse.system_user
removed = 0
topic_ids.each do |tid|
  topic = Topic.find_by(id: tid)
  next unless topic

  first_post = topic.first_post
  next unless first_post

  PostDestroyer.new(actor, first_post).destroy
  removed += 1
rescue StandardError => e
  puts "[minicodnav] skip topic #{tid}: #{e.message}"
end

puts "[minicodnav] done. removed_topics=#{removed}, maps=0, receipts=0"
