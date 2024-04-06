require 'rails_helper'

RSpec.describe Idv::Resolution::Input do
  describe '#from_idv_session' do
    let(:idv_session) do
      {
        pii_from_doc:,
        pii_from_user:,
      }
    end

    let(:pii_from_doc) { nil }

    let(:pii_from_user) { nil }

    context 'with drivers license' do
      let(:pii_from_doc) do
        {
          first_name: 'Testy',
          last_name: 'McTesterson',

        }
      end

      subject { described_class.from_idv_session(idv_session) }

      it 'maps to drivers_license' do
        expect(subject.drivers_license.to_h).to eql(
          first_name: 'Testy',
          last_name: 'McTesterson',
        )
      end
    end
  end
end
