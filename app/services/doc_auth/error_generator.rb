# frozen_string_literal: true

module DocAuth
  # Non document authentication related error
  class ErrorHandler
    def handle(response_info)
      raise NotImplementedError, "#{self.class} has not implemented method '#{__method__}'"
    end
  end

  class IdTypeErrorHandler < ErrorHandler
    SUPPORTED_ID_CLASSNAME = ['Identification Card', 'Drivers License'].freeze
    ACCEPTED_ISSUER_TYPES = [DocAuth::LexisNexis::IssuerTypes::STATE_OR_PROVINCE.name,
                             DocAuth::LexisNexis::IssuerTypes::UNKNOWN.name].freeze
    def handle(response_info)
      get_id_type_errors(response_info[:classification_info])
    end

    private

    def get_id_type_errors(classification_info)
      return unless classification_info.present?
      error_result = ErrorResult.new
      both_side_ok = true
      %w[Front Back].each do |side|
        side_class = classification_info.with_indifferent_access.dig(side, 'ClassName')
        side_country = classification_info.with_indifferent_access.dig(side, 'CountryCode')
        side_issuer_type = classification_info.with_indifferent_access.dig(side, 'IssuerType')

        side_ok = !side_class.present? ||
                  SUPPORTED_ID_CLASSNAME.include?(side_class) ||
                  side_class == 'Unknown'
        country_ok = !side_country.present? || supported_country_codes.include?(side_country)
        issuer_type_ok = !side_issuer_type.present? ||
                         ACCEPTED_ISSUER_TYPES.include?(side_issuer_type)
        both_side_ok &&= issuer_type_ok && side_ok && country_ok
        error_result.add_side(side.downcase.to_sym) unless side_ok && issuer_type_ok && country_ok
      end
      unless both_side_ok
        error_result.set_error(Errors::DOC_TYPE_CHECK)
      end
      error_result
    end

    def supported_country_codes
      IdentityConfig.store.doc_auth_supported_country_codes
    end
  end

  class ImageMetricsErrorHandler < ErrorHandler
    def initialize(config)
      @config = config
    end

    def handle(response_info)
      get_image_metric_errors(response_info[:image_metrics])
    end

    private

    def get_image_metric_errors(processed_image_metrics)
      dpi_threshold = @config&.dpi_threshold&.to_i || 290
      sharpness_threshold = @config&.sharpness_threshold&.to_i || 40
      glare_threshold = @config&.glare_threshold&.to_i || 40

      dpi_metrics, sharp_metrics, glare_metrics = {}, {}, {}
      error_result = ErrorResult.new

      processed_image_metrics.each do |side, img_metrics|
        dpi_metrics[side] = img_metrics.slice('HorizontalResolution', 'VerticalResolution')
        sharp_metrics[side] = img_metrics.slice('SharpnessMetric')
        glare_metrics[side] = img_metrics.slice('GlareMetric')
      end

      dpi_metrics.each do |side, img_metrics|
        hdpi = img_metrics['HorizontalResolution']&.to_i || 0
        vdpi = img_metrics['VerticalResolution']&.to_i || 0
        if hdpi < dpi_threshold || vdpi < dpi_threshold
          error_result.set_error(Errors::DPI_LOW)
          error_result.add_side(side)
        end
      end
      return error_result unless error_result.empty?

      sharp_metrics.each do |side, img_metrics|
        sharpness = img_metrics['SharpnessMetric']&.to_i
        if sharpness.present? && sharpness < sharpness_threshold
          error_result.set_error(Errors::SHARP_LOW)
          error_result.add_side(side)
        end
      end
      return error_result unless error_result.empty?

      glare_metrics.each do |side, img_metrics|
        glare = img_metrics['GlareMetric']&.to_i
        if glare.present? && glare < glare_threshold
          error_result.set_error(Errors::GLARE_LOW)
          error_result.add_side(side)
        end
      end

      error_result
    end
  end

  class SelfieErrorHandler < ErrorHandler
    include SelfieConcern
    def handle(response_info)
      liveness_enabled = response_info[:liveness_enabled]
      get_selfie_error(liveness_enabled, response_info)
    end

    def is_generic_selfie_error?(error)
      error == Errors::SELFIE_FAILURE
    end

    def selfie_general_failure_error
      {
        general: [Errors::SELFIE_FAILURE],
        front: [Errors::MULTIPLE_FRONT_ID_FAILURES],
        back: [Errors::MULTIPLE_BACK_ID_FAILURES],
        selfie: [Errors::SELFIE_FAILURE],
        hints: false,
      }
    end

    private

    def get_selfie_error(liveness_enabled, response_info)
      # The part of the response that contains information about the selfie
      portrait_match_results = response_info[:portrait_match_results] || {}
      # The overall result of the selfie, 'Pass' or 'Fail'
      face_match_result = portrait_match_results.dig(:FaceMatchResult)
      # The reason for failure (if it failed), also sometimes contains success info
      face_match_error = portrait_match_results.dig(:FaceErrorMessage)

      # No error if liveness is not enabled or if there's no failure
      if !liveness_enabled || !face_match_result || face_match_result == 'Pass'
        return nil
      end

      # Error when the image on the id does not match the selfie image, but the image was acceptable
      if error_is_success(face_match_error)
        return Errors::SELFIE_FAILURE
      end
      # Error when the image on the id is poor quality
      if error_is_poor_quality(face_match_error)
        return Errors::SELFIE_POOR_QUALITY
      end
      # Error when the image on the id is not live
      if error_is_not_live(face_match_error)
        return Errors::SELFIE_NOT_LIVE
      end
      # Fallback, we don't expect this to happen
      Errors::SELFIE_FAILURE
    end
  end

  class AlertErrorHandler < ErrorHandler
    def initialize(config:, liveness_enabled:)
      @config = config
      @liveness_enabled = liveness_enabled
    end

    def handle(known_alert_error_count, response_info, selfie_error)
      alert_errors = get_error_messages(response_info)
      # take non general selfie error into account
      if @liveness_enabled && !!selfie_error
        alert_errors[ErrorGenerator::SELFIE] << selfie_error
      end
      known_alert_error_count += 1 if alert_errors.include?(ErrorGenerator::SELFIE)

      # consolidate error based on count
      if known_alert_error_count < 1
        process_unknown_alert_error(response_info)
      elsif known_alert_error_count == 1
        process_single_alert_error(alert_errors)
      elsif known_alert_error_count > 1
        # Simplify multiple errors into a single error for the user
        consolidate_multiple_alert_errors(alert_errors)
      else
        # default fall back
        ErrorResult.new(error, side)
      end
    end

    private

    def get_error_messages(response_info)
      errors = Hash.new { |hash, key| hash[key] = Set.new }

      if response_info[:doc_auth_result] != 'Passed'
        response_info[:processed_alerts][:failed]&.each do |alert|
          alert_msg_hash = ErrorGenerator::ALERT_MESSAGES[alert[:name].to_sym]

          if alert_msg_hash.present?
            field_type = alert[:side] || alert_msg_hash[:type]
            errors[field_type.to_sym] << alert_msg_hash[:msg_key]
          end
        end
      end
      errors
    end

    ##
    # Return ErrorResult as hash, there is error but known_error_count = 0
    ##
    def process_unknown_alert_error(response_info)
      @config.warn_notifier&.call(
        message: 'DocAuth failure escaped without useful errors',
        response_info: response_info,
      )

      error = Errors::GENERAL_ERROR
      side = ErrorGenerator::ID
      ErrorResult.new(error, side)
    end

    def process_single_alert_error(alert_errors)
      error = alert_errors.values[0].to_a.pop
      side = alert_errors.keys[0]
      ErrorResult.new(error, side)
    end

    def consolidate_multiple_alert_errors(alert_errors)
      error_fields = alert_errors.keys
      if error_fields.length == 1
        side = error_fields.first
        case side
        when ErrorGenerator::ID
          error = Errors::GENERAL_ERROR
        when ErrorGenerator::FRONT
          error = Errors::MULTIPLE_FRONT_ID_FAILURES
        when ErrorGenerator::BACK
          error = Errors::MULTIPLE_BACK_ID_FAILURES
        end
      elsif error_fields.length > 1
        error = Errors::GENERAL_ERROR
        side = ErrorGenerator::ID
      end
      ErrorResult.new(error, side)
    end
  end

  class ErrorGenerator
    attr_reader :config

    # These constants are the key names for the TrueID errors hash that is returned
    ID = :id
    FRONT = :front
    BACK = :back
    SELFIE = :selfie
    GENERAL = :general

    ACCEPTED_ISSUER_TYPES = [DocAuth::LexisNexis::IssuerTypes::STATE_OR_PROVINCE.name,
                             DocAuth::LexisNexis::IssuerTypes::UNKNOWN.name].freeze

    ERROR_KEYS = [
      ID,
      FRONT,
      BACK,
      SELFIE,
      GENERAL,
    ].to_set.freeze

    ALERT_MESSAGES = {
      '1D Control Number Valid': { type: BACK, msg_key: Errors::REF_CONTROL_NUMBER_CHECK },
      '2D Barcode Content': { type: BACK, msg_key: Errors::BARCODE_CONTENT_CHECK },
      '2D Barcode Read': { type: BACK, msg_key: Errors::BARCODE_READ_CHECK },
      'Birth Date Crosscheck': { type: ID, msg_key: Errors::BIRTH_DATE_CHECKS },
      'Birth Date Valid': { type: ID, msg_key: Errors::BIRTH_DATE_CHECKS },
      'Control Number Crosscheck': { type: BACK, msg_key: Errors::CONTROL_NUMBER_CHECK },
      'Document Classification': { type: ID, msg_key: Errors::ID_NOT_RECOGNIZED },
      'Document Crosscheck Aggregation': { type: ID, msg_key: Errors::DOC_CROSSCHECK },
      'Document Expired': { type: ID, msg_key: Errors::DOCUMENT_EXPIRED_CHECK },
      'Document Number Crosscheck': { type: ID, msg_key: Errors::DOC_NUMBER_CHECKS },
      'Expiration Date Crosscheck': { type: ID, msg_key: Errors::EXPIRATION_CHECKS },
      'Expiration Date Valid': { type: ID, msg_key: Errors::EXPIRATION_CHECKS },
      'Full Name Crosscheck': { type: ID, msg_key: Errors::FULL_NAME_CHECK },
      'Issue Date Crosscheck': { type: ID, msg_key: Errors::ISSUE_DATE_CHECKS },
      'Issue Date Valid': { type: ID, msg_key: Errors::ISSUE_DATE_CHECKS },
      'Layout Valid': { type: ID, msg_key: Errors::ID_NOT_VERIFIED },
      'Near-Infrared Response': { type: ID, msg_key: Errors::ID_NOT_VERIFIED },
      'Photo Printing': { type: FRONT, msg_key: Errors::VISIBLE_PHOTO_CHECK },
      'Physical Document Presence': { type: ID, msg_key: Errors::ID_NOT_VERIFIED },
      'Sex Crosscheck': { type: ID, msg_key: Errors::SEX_CHECK },
      'Visible Color Response': { type: ID, msg_key: Errors::VISIBLE_COLOR_CHECK },
      'Visible Pattern': { type: ID, msg_key: Errors::ID_NOT_VERIFIED },
      'Visible Photo Characteristics': { type: FRONT, msg_key: Errors::VISIBLE_PHOTO_CHECK },
    }.freeze

    SUPPORTED_ID_CLASSNAME = ['Identification Card', 'Drivers License'].freeze

    def initialize(config)
      @config = config
    end

    def generate_doc_auth_errors(response_info)
      # when entered here, it's decided the doc auth is not successful

      # scan unknown(handled) error, make sure `warn_notify` it
      # if unhandled error found
      unknown_fail_count = scan_for_unknown_alerts(response_info)

      # check whether ID type supported
      id_type_error_handler = IdTypeErrorHandler.new
      id_type_error = id_type_error_handler.handle(response_info)
      return id_type_error.to_h if id_type_error.present? && !id_type_error.empty?

      # check Image metrics error
      metrics_error_handler = ImageMetricsErrorHandler.new(config)
      metrics_error = metrics_error_handler.handle(response_info)
      return metrics_error.to_h if metrics_error.present? && !metrics_error.empty?

      # check selfie error
      selfie_error_handler = SelfieErrorHandler.new
      selfie_error = selfie_error_handler.handle(response_info)

      # if selfie itself is ok, but we have selfie related error
      if selfie_error_handler.is_generic_selfie_error?(selfie_error)
        return selfie_error_handler.selfie_general_failure_error
      end

      # other vendor response detail error
      liveness_enabled = response_info[:liveness_enabled]
      alert_error_count = response_info[:doc_auth_result] == 'Passed' ?
                            0 : response_info[:alert_failure_count]

      known_alert_error_count = alert_error_count - unknown_fail_count
      alert_error_handler = AlertErrorHandler.new(
        config: config,
        liveness_enabled: liveness_enabled,
      )
      alert_error = alert_error_handler.handle(known_alert_error_count, response_info, selfie_error)
      alert_error.to_h
    end

    def scan_for_unknown_alerts(response_info)
      all_alerts = [
        *response_info[:processed_alerts][:failed],
        *response_info[:processed_alerts][:passed],
      ]
      unknown_fail_count = 0

      unknown_alerts = []
      all_alerts.each do |alert|
        if ErrorGenerator::ALERT_MESSAGES[alert[:name].to_sym].blank?
          unknown_alerts.push(alert[:name])

          unknown_fail_count += 1 if alert[:result] != 'Passed'
        end
      end

      return 0 if unknown_alerts.empty?

      config.warn_notifier&.call(
        message: 'DocAuth vendor responded with alert name(s) we do not handle',
        unknown_alerts: unknown_alerts,
        response_info: response_info,
      )

      unknown_fail_count
    end

    def self.general_error(_liveness_enabled)
      Errors::GENERAL_ERROR
    end

    def self.wrapped_general_error(liveness_enabled)
      { general: [ErrorGenerator.general_error(liveness_enabled)], hints: true }
    end
  end
end
