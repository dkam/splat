# frozen_string_literal: true

class IssuesController < ApplicationController
  include Pagy::Backend

  before_action :set_project
  before_action :set_issue, only: [:show, :resolve, :ignore, :reopen]

  def index
    @status = params[:status] || "open"
    issues = case @status
    when "resolved"
      @project.issues.resolved
    when "ignored"
      @project.issues.ignored
    else
      @project.issues.open
    end.recent

    @pagy, @issues = pagy(issues, limit: 25)
  end

  def show
    @events = @issue.events.recent.limit(50)
  end

  def resolve
    @issue.resolved!
    redirect_to project_issue_path(@project.slug, @issue), notice: "Issue marked as resolved"
  end

  def ignore
    @issue.ignored!
    redirect_to project_issue_path(@project.slug, @issue), notice: "Issue ignored"
  end

  def reopen
    @issue.open!
    redirect_to project_issue_path(@project.slug, @issue), notice: "Issue reopened"
  end

  private

  def set_project
    # Accept both slug (e.g., "booko") and ID (e.g., "1")
    @project = Project.find_by(slug: params[:project_slug]) || Project.find(params[:project_slug])
  end

  def set_issue
    @issue = @project.issues.find(params[:id])
  end
end
