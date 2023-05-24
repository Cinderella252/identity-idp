class IdvController < ApplicationController
  include IdvSession
  include AccountReactivationConcern
  include FraudReviewConcern

  before_action :confirm_two_factor_authenticated
  before_action :profile_needs_reactivation?, only: [:index]
  before_action :handle_fraud

  def index
    if decorated_session.requested_more_recent_verification? ||
       current_user.reproof_for_irs?(service_provider: current_sp)
      verify_identity
    elsif active_profile?
      redirect_to idv_activated_url
    elsif idv_attempter_throttled?
      analytics.throttler_rate_limit_triggered(
        throttle_type: :idv_resolution,
      )
      redirect_to idv_session_errors_failure_url
    else
      verify_identity
    end
  end

  def activated
    redirect_to idv_url unless active_profile?
    idv_session.clear
  end

  private

  def verify_identity
    analytics.idv_intro_visit
    redirect_to idv_doc_auth_url
  end

  def profile_needs_reactivation?
    return unless reactivate_account_session.started?
    confirm_password_reset_profile
    redirect_to reactivate_account_url
  end

  def active_profile?
    current_user.active_profile.present?
  end
end
