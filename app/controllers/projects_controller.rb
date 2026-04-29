# frozen_string_literal: true

class ProjectsController < ApplicationController
  before_action :set_project, only: [:show, :edit, :update, :destroy]

  def index
    @projects = Project.all.order(updated_at: :desc)

    counts = Rails.cache.fetch("projects_index_counts", expires_in: 30.seconds) do
      {
        open_issues: Issue.open.group(:project_id).count,
        events: Event.group(:project_id).count,
        last_event: Event.group(:project_id).maximum(:timestamp)
      }
    end
    @open_issue_counts = counts[:open_issues]
    @event_counts = counts[:events]
    @last_event_at = counts[:last_event]
  end

  def show
    @recent_issues = @project.open_issues.limit(20)
    @recent_events = @project.recent_events(limit: 10)
    @recent_transactions = @project.recent_transactions(limit: 10)
    @event_count_24h = @project.event_count(24.hours.ago..Time.current)
    @transaction_count_24h = @project.transaction_count(24.hours.ago..Time.current)
    @avg_response_time = @project.avg_response_time
    @queue_depth = queue_depth
    @open_issue_count = Rails.cache.fetch("project_#{@project.id}_open_issue_count", expires_in: 30.seconds) do
      @project.issues.open.count
    end
  end

  def new
    @project = Project.new
  end

  def create
    @project = Project.new(project_params)

    if @project.save
      redirect_to project_path(@project.slug), notice: "Project created successfully"
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @project.update(project_params)
      redirect_to project_path(@project.slug), notice: "Project updated successfully"
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @project.destroy
    redirect_to root_path, notice: "Project deleted successfully"
  end

  private

  def set_project
    @project = Project.find_by!(slug: params[:slug])
  end

  def project_params
    params.require(:project).permit(:name)
  end
end
