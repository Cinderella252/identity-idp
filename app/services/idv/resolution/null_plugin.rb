# frozen_string_literal: true

module Idv
  module IdentityResolver
    class NullPlugin
      # @param {Idv::IdentityResolver::Input} input Structure containing PII and other inputs to
      #                                             the identity resolution process.
      # @param {Hash} result The result of identity resolution (so far).
      # @param {Lambda} next_plugin Call to envoke the next plugin in the chain.
      # @returns {Hash} An identity resolution result.
      # rubocop:disable Lint/UnusedMethodArgument
      def resolve_identity(
        input:,
        result:,
        next_plugin:
      )
        next_plugin.call
      end
      # rubocop:enable Lint/UnusedMethodArgument
    end
  end
end
