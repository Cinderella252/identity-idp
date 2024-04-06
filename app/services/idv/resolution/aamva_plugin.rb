module Idv
  module IdentityResolver
    class AamvaPlugin
      attr_reader :supported_jurisdictions

      def initialize(
          supported_jurisdictions: IdentityConfig.store.aamva_supported_jurisdictions
        )
        @supported_jurisdictions = supported_jurisdictions
      end

      def resolve_identity(
        pii_from_doc:,
        pii_from_user:,
        result:,
        next_plugin:
      )

        if unsupported_jurisdiction?(pii_from_doc:)
          return next_plugin.call(
            result: result.merge(
              aamva: 'UnsupportedJurisdiction',
            ),
          )
        end
      end

      def unsupported_jurisdiction?(pii_from_doc:)
        !supported_jurisdictions.include?(pii_from_doc[:state_id_jurisdiction])
      end

      # Given an in-progress
      def needs_aamva?(result:, pii_from_doc:, pii_from_user:)
      end
    end
  end
end
