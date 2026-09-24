# frozen_string_literal: true
require "test_helper"

class GraphQLProbeTest < ActiveSupport::TestCase
  def client = Github::Client.new(users(:prism_dev))

  def probe(label, status:, body:, headers: { "Content-Type" => "application/json; charset=utf-8" })
    stub_request(:post, "https://api.github.com/graphql").to_return(status: status, body: body, headers: headers)
    result = client.reply_in_review(review_node_id: "PRR_1", thread_node_id: "PRRT_1", body: "hi")
    puts "#{label}: returned #{result.inspect[0, 120]}"
  rescue StandardError => e
    puts "#{label}: raised #{e.class}: #{e.message[0, 120]}"
  ensure
    WebMock.reset!
  end

  test "probe" do
    probe("empty 200 body", status: 200, body: "")
    probe("204 no content", status: 204, body: "")
    probe("data with null mutation payload + errors", status: 200,
          body: { data: { addPullRequestReviewThreadReply: nil },
                  errors: [ { message: "Could not resolve to a node", type: "NOT_FOUND" } ] }.to_json)
    probe("data with null comment, no errors", status: 200,
          body: { data: { addPullRequestReviewThreadReply: { comment: nil } } }.to_json)
    probe("data empty object", status: 200, body: { data: {} }.to_json)
    probe("errors only, no data key", status: 200,
          body: { errors: [ { message: "boom" } ] }.to_json)
    probe("200 but html body", status: 200, body: "<html>nope</html>",
          headers: { "Content-Type" => "text/html; charset=utf-8" })
    probe("good comment", status: 200,
          body: { data: { addPullRequestReviewThreadReply: { comment: {
            id: "PRRC_1", databaseId: 1, body: "hi", bodyHTML: "<p>hi</p>", state: "PENDING",
            createdAt: "2026-09-24T10:00:00Z", url: "https://github.com/x", diffHunk: "",
            outdated: false, viewerCanUpdate: true, viewerCanDelete: true, viewerCanReact: false,
            author: { login: "prism-dev", avatarUrl: "a", url: "u" }, replyTo: { id: "PRRC_0" },
            reactionGroups: [] } } } }.to_json)
  end
end
