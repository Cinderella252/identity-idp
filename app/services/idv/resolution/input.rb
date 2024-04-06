# frozen_string_literal: true

module Idv
  module Resolution
    # Captures PII attributes contained in a state-issued identity document
    # (that is, a drivers license or state ID).
    StateId = Data.define(
      *%i[
        first_name
        middle_name
        last_name
        address
        dob
        number
        issuing_jurisdiction
      ],
    ).freeze

    Input = Data.define(
      *%i[
        state_id
      ],
    ) do
      # Convert data from an idv_session into an Input.
      def self.from_idv_session(
        pii_from_doc: nil,
        pii_from_user: nil,
        **_kwargs
      )
        state_id = StateId.new

        Input.new(
          state_id:,
        )
      end
    end.freeze
  end
end
