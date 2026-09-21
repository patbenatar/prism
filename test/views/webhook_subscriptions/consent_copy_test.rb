# frozen_string_literal: true

require "test_helper"

# The promise Prism makes about editing other people's pull requests is now
# worded twice: `_consent`, asked before anything happens, and
# `_consent_brief`, reporting what is already happening from inside the
# watching menu. They cannot literally be one partial — three paragraphs and
# two present-tense sentences are different prose for different moments —
# but they are the same promise, and two copies of a promise are two copies
# to drift.
#
# So the prose is free and the facts are not. Each of these is something
# someone could reasonably say they were never told: what Prism writes and
# on which pull requests, whose account GitHub records the edit under, and
# how to call it off. A rewrite that drops one fails here rather than
# quietly disagreeing with the other screen.
#
# Matched loosely on purpose — nothing below pins a sentence, only that the
# fact is present in some form.
class ConsentCopyTest < ActionView::TestCase
  LOGIN = "patbenatar"

  PARTIALS = %w[
    webhook_subscriptions/consent
    webhook_subscriptions/consent_brief
  ].freeze

  FACTS = {
    "names the account GitHub will attribute the edit to" => /@#{LOGIN}\b/,
    "says the edit lands on the pull request's description" => /description/i,
    "says only Markdown pull requests are touched" => /markdown/i,
    "says deleting the link calls Prism off" => /delet\w+ (the (link|block)|it)/i
  }.freeze

  PARTIALS.each do |partial|
    FACTS.each do |fact, pattern|
      test "#{partial} #{fact}" do
        copy = text_of(partial)

        assert_match pattern, copy,
                     "#{partial} no longer #{fact} — the other wording still does, " \
                     "so the two screens now promise different things:\n\n#{copy}"
      end
    end
  end

  # Both are rendered by the same screens, so both have to say it in a way a
  # reader sees, not in a comment.
  test "both wordings put the login in the sentence, not only in an attribute" do
    PARTIALS.each do |partial|
      assert_match(/as @#{LOGIN}|account, @#{LOGIN}/, text_of(partial).squish,
                   "#{partial} mentions the login but not as the account being acted as")
    end
  end

  private

  # The rendered partial as a reader meets it: tags stripped, entities back to
  # characters, whitespace collapsed.
  def text_of(partial)
    render partial: partial, locals: { login: LOGIN }
    Nokogiri::HTML5.fragment(rendered).text.squish
  end
end
