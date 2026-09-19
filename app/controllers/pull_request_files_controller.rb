# frozen_string_literal: true

# The rendered Markdown file view — the screen Prism exists for.
#
# Everything this needs is loaded and joined by Review::Page, so the action is
# three decisions: is this file part of the pull request, is it Markdown, and if
# not, where on GitHub should we send the reviewer instead.
class PullRequestFilesController < ApplicationController
  include GithubErrorHandling

  rescue_from Review::Page::FileNotFound, with: :file_not_found

  # The path ends in ".md", and when a request arrives without an Accept header
  # Rails falls back to the path's extension to pick a format — so this action
  # would be asked for text/markdown and 406 for want of a template. The route
  # already says `format: false`; this says the same thing to the renderer.
  before_action { request.format = :html }

  def show
    @owner = params[:owner]
    @name = params[:repo]
    @number = params[:number].to_i
    @path = params[:path].to_s

    @page = Review::Page.load(github: github, owner: @owner, repo: @name,
                              number: @number, path: @path)

    # Prism renders Markdown. Anything else is GitHub's job, and sending the
    # reviewer straight there beats a page explaining that we won't.
    return redirect_to(@page.github_blob_url, allow_other_host: true) unless @page.markdown?

    @result = @page.result
    @pull_request = @page.pull_request
    @file = @page.file
  end

  private

  def file_not_found(_error)
    render "shared/not_found", status: :not_found, formats: :html
  end
end
