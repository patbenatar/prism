# frozen_string_literal: true

# Support for the opt-in live-GitHub tier (test/e2e/*_test.rb).
#
# Everything here talks to the *real* GitHub API, mutating a *real* scratch
# pull request — never stubbed, never run by default. See docs/testing.md
# for exactly what it creates and how it cleans up after itself.
#
# Required by each e2e test file directly (`require "e2e_helper"`), the way
# `test/support/**` files are auto-required for the stubbed tiers by
# test_helper.rb — this one is deliberately NOT under test/support, so it is
# never pulled in by a normal `bin/rails test` run.
module E2eHelper
  REQUIRED_ENV = %w[E2E_GITHUB_TOKEN E2E_REPO E2E_PR].freeze

  def e2e_configured? = REQUIRED_ENV.all? { |key| ENV[key].present? }

  # Call first thing in `setup`. Every e2e test is a `skip` away from being a
  # no-op in CI and on a machine without live credentials.
  def skip_unless_e2e_configured!
    return if e2e_configured?

    skip "Set #{REQUIRED_ENV.join(', ')} to run the live GitHub e2e tier " \
         "(see docs/testing.md \"Live GitHub tier\")."
  end

  def e2e_owner_and_repo
    owner, repo = ENV.fetch("E2E_REPO").split("/", 2)
    raise "E2E_REPO must be \"owner/name\", got #{ENV['E2E_REPO'].inspect}" if repo.blank?

    [ owner, repo ]
  end

  def e2e_pr_number = Integer(ENV.fetch("E2E_PR"))

  # A User that is never saved — Github::Client only ever reads
  # `user.access_token` off it, so there is no reason to touch the database
  # for a token that came from the environment, not from a sign-in.
  def e2e_user
    User.new(github_id: -1, login: "prism-e2e", access_token: ENV.fetch("E2E_GITHUB_TOKEN"))
  end

  def e2e_client = Github::Client.new(e2e_user)

  # A line certain not to exist in `source`, for proving GitHub 422s (and
  # Github::Client translates that into Github::LineNotCommentable) rather
  # than silently accepting a line outside the diff.
  def e2e_impossible_line(source) = source.to_s.lines.size + 1000

  # The first block whose Review::AnchorResolver-computed anchor satisfies the
  # block given (`&:multi_line?` or `->(a) { !a.multi_line? }`), scanning the
  # PR's real diff — because which lines are "in the diff" depends entirely on
  # what the scratch PR actually changed, so this can't be hardcoded.
  #
  # @return [[Markdown::Block, Review::Anchor], nil] or [nil, nil]
  def e2e_find_commentable(blocks, line_sets, path)
    blocks.each do |block|
      anchor = Review::AnchorResolver.call(block, line_sets, path: path, side: :right)
      next unless anchor.is_a?(Review::Anchor)

      return [ block, anchor ] if yield(anchor)
    end

    [ nil, nil ]
  end
end
