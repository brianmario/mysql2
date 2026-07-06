require "spec_helper"

RSpec.describe Mysql2::Result do
  it "does not raise on fields/field_types for cached empty results" do
    new_client do |client|
      result = client.query("SELECT 1 AS only_col WHERE 1 = 0")
      expect(result.to_a).to eql([])

      expect { result.fields }.not_to raise_error
      expect(result.fields).to eql(["only_col"])
      expect { result.field_types }.not_to raise_error
      expect(result.field_types.length).to eql(1)
    end
  end
end
