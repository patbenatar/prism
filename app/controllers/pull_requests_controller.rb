# frozen_string_literal: true

# A repository's pull requests, and one pull request's overview.
class PullRequestsController < ApplicationController
  include GithubErrorHandling

  STATES = %w[open closed all].freeze

  before_action :set_repo_params

  def index
    @state = STATES.include?(params[:state]) ? params[:state] : "open"
    @page = params[:page].to_i.clamp(1, 20)
    @page = 1 if @page.zero?

    @repo = github.repo(@owner, @name)
    @pull_requests = github.pull_requests(@owner, @name, state: @state, page: @page)
    @next_page = (@page + 1 if @pull_requests.size >= Github::Client::PER_PAGE)
  end

  def show
    @number = params[:number].to_i
    @pull_request = github.pull_request(@owner, @name, @number)

    # The Markdown-file count is what Prism is for, and it needs the files
    # endpoint. That is too expensive to do per row on the list screen, so the
    # count is computed here, once, where we are already loading the files.
    files = github.pull_request_files(@owner, @name, @number, head_sha: @pull_request.head_sha)
    @markdown_files, @other_files = files.partition(&:markdown?)

    @reviews = github.reviews(@owner, @name, @number)
    @body_html = rendered_description
  end

  private

  def set_repo_params
    @owner = params[:owner]
    @name = params[:repo]
  end

  # GitHub renders the description for us, so it matches what the PR looks like
  # on github.com. Workstream B's Markdown::Sanitizer replaces the fallback
  # safelist in `github_html`; nothing here changes when it does.
  def rendered_description
    return nil if @pull_request.body.blank?

    github.render_markdown(@pull_request.body, context: "#{@owner}/#{@name}")
  rescue Github::Error => e
    Rails.logger.warn("Rendering the PR description failed: #{e.class} #{e.message}")
    nil
  end
end
