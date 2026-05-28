# frozen_string_literal: true

# 清空插件映射表，并删除曾由 Academic Nav 同步创建的话题。
# 在 Discourse 容器内执行，例如:
#   sudo -H -E -u discourse bash -lc 'cd /var/www/discourse && bin/rails runner plugins/discourse-academic-nav/scripts/clear_sync_data.rb'

unless defined?(DiscourseAcademicNav::ResourceMap)
  puts "[acadnav] plugin tables not found — run plugin migrations first"
  exit 1
end

topic_ids = DiscourseAcademicNav::ResourceMap.pluck(:topic_id).uniq
receipts = DiscourseAcademicNav::WebhookReceipt.count
maps = DiscourseAcademicNav::ResourceMap.count

puts "[acadnav] maps=#{maps} receipts=#{receipts} topics_to_remove=#{topic_ids.size}"

DiscourseAcademicNav::ResourceMap.delete_all
DiscourseAcademicNav::WebhookReceipt.delete_all

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
  puts "[acadnav] skip topic #{tid}: #{e.message}"
end

puts "[acadnav] done. removed_topics=#{removed}, maps=0, receipts=0"
