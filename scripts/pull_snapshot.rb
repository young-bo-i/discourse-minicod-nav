# frozen_string_literal: true

# 拉一次中台 snapshot,把已发布/已归档的资源全量同步进 Discourse。
# 用法(在 Discourse 容器内):
#   SOURCE=pavlovia sudo -H -E -u discourse bash -lc \
#     'cd /var/www/discourse && bin/rails runner plugins/discourse-minicod-nav/scripts/pull_snapshot.rb'
#   SOURCE=journal  ...

source = ENV["SOURCE"].to_s
unless DiscourseMinicodNav::SnapshotFetcher::SOURCES.include?(source)
  puts "[minicodnav] SOURCE must be one of: #{DiscourseMinicodNav::SnapshotFetcher::SOURCES.join(", ")}"
  exit 1
end

result = DiscourseMinicodNav::SnapshotFetcher.new(source: source).call
puts "[minicodnav] snapshot #{result[:source]} done: applied=#{result[:applied]} skipped=#{result[:skipped]} failed=#{result[:failed]}"
