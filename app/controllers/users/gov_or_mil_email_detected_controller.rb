module Users
    class GovOrMilEmailDetectedController < ApplicationController
      include TwoFactorAuthenticatableMethods
      include MfaSetupConcern
      include SecureHeadersConcern
      include ReauthenticationRequiredConcern
  
      before_action :authenticate_user!
      before_action :confirm_user_authenticated_for_2fa_setup
      before_action :apply_secure_headers_override
      before_action :user_email_is_gov_or_mil?
  
      helper_method :in_multi_mfa_selection_flow?
  
      def show
        @email_type = email_type
        analytics.gov_or_mil_email_detected_visited
      end


      private 

      def user_email_is_gov_or_mil?
        redirect_to after_sign_in_path_for(current_user) unless current_user.has_gov_or_mil_email?
      end

      def email_type
        address = current_user.confirmed_email_addresses.select {|address| address.gov_or_mil? }
        case address.first.email.end_with?('.gov')
        when true
          '.gov'
        else
          '.mil'
        end
      end
    end
  end
  