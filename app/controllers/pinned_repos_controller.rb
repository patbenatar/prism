# frozen_string_literal: true

# Toggles a pin on a repository from the /repos list.
#
# Create and destroy are keyed by owner+name rather than a PinnedRepo id: the
# client only ever knows a repo's owner/name (that's all GitHub's list gives
# it), never one of our internal ids, so making owner+name the key means the
# view never has to look anything up before it can render the button.
class PinnedReposController < ApplicationController
  include GithubErrorHandling

  def create
    pin = current_user.pinned_repos.find_or_initialize_by(owner: params[:owner], name: params[:repo])
    pin.save! if pin.new_record?

    render_repo_lists
  end

  def destroy
    current_user.pinned_repos.where(owner: params[:owner], name: params[:repo]).delete_all

    render_repo_lists
  end

  private

  # Re-fetches the same repo pages ReposController#index would have loaded
  # (the visitor may have clicked "Load more" before pinning anything) and
  # re-partitions them, so the panels the pin toggle swaps in always reflect a
  # live GitHub fetch rather than something remembered from the last render.
  def render_repo_lists
    page = ReposController.clamp_page(params[:page])
    repos, next_page = ReposController.fetch_repos(github, page)
    pinned, unpinned = PinnedRepo.partition(repos, current_user)

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace(
          "repo-lists",
          partial: "repos/lists",
          locals: { pinned: pinned, unpinned: unpinned, next_page: next_page, page: page }
        )
      end
      format.html { redirect_to repos_path(page: (page if page > 1)) }
    end
  end
end
