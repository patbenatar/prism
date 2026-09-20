# frozen_string_literal: true

# The rendered Markdown view — the screen Prism exists for.
#
# `index` is the screen: every renderable `.md` file in the pull request on one
# page, in the file list's order, each under its own sticky heading.
# Review::PullRequestPage loads and joins all of it, so the action is thin.
#
# `show` is the old per-file screen's URL, kept alive as a redirect into that
# page's anchor. Links and bookmarks from before the Markdown tab existed still
# land on the file they named, and every write action's no-JS fallback still
# has somewhere honest to go.
class PullRequestFilesController < ApplicationController
  include GithubErrorHandling

  rescue_from Review::Page::FileNotFound, with: :file_not_found

  # A path ending in ".md" makes Rails fall back to the extension to pick a
  # response format when the request carries no Accept header, so this action
  # would be asked for text/markdown and 406 for want of a template. The route
  # already says `format: false`; this says the same thing to the renderer.
  before_action { request.format = :html }
  before_action :set_scope

  def index
    @page = Review::PullRequestPage.load(github: github, owner: @owner, repo: @name, number: @number)

    @pull_request = @page.pull_request
    @pages = @page.pages
    @pending_review = @page.pending_review
  end

  # Deliberately does not build a Review::PullRequestPage: a redirect needs to
  # know two things — does this file exist in the pull request, and is it
  # Markdown — and both come from the file list, which is already cached by
  # head sha. Rendering the whole page here just to throw it away would double
  # the cost of every old link.
  def show
    @path = params[:path].to_s

    pull_request = github.pull_request(@owner, @name, @number)
    files = github.pull_request_files(@owner, @name, @number, head_sha: pull_request.head_sha)
    file = files.find { |candidate| candidate.path == @path }
    raise Review::Page::FileNotFound, "#{@path} is not part of pull request ##{@number}" if file.nil?

    # Prism renders Markdown. Anything else is GitHub's job, and sending the
    # reviewer straight there beats a page explaining that we won't.
    return redirect_to(blob_url(file, pull_request), allow_other_host: true) unless file.markdown?

    redirect_to repo_pull_markdown_path(owner: @owner, repo: @name, number: @number,
                                        anchor: Review::Page.file_key(@path))
  end

  private

  def set_scope
    @owner = params[:owner]
    @name = params[:repo]
    @number = params[:number].to_i
  end

  def blob_url(file, pull_request)
    return file.blob_url if file.blob_url.present?

    ref = file.removed? ? pull_request.base_sha : pull_request.head_sha
    "https://github.com/#{@owner}/#{@name}/blob/#{ref}/#{file.path}"
  end

  def file_not_found(_error)
    render "shared/not_found", status: :not_found, formats: :html
  end
end
