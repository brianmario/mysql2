require 'spec_helper'

RSpec.describe 'unsigned decimal field precision' do
  [false, true].each do |prepared|
    it "reports declared signed and unsigned precision with and without a scale (prepared: #{prepared})" do
      @client.query('CREATE TEMPORARY TABLE decimal_precision (a DECIMAL(10,2) UNSIGNED, b DECIMAL(10,0) UNSIGNED, c DECIMAL(10,2), d DECIMAL(10,0))')
      sql = 'SELECT * FROM decimal_precision'
      result = prepared ? @client.prepare(sql).execute : @client.query(sql)
      expect(result.field_types).to eq(['decimal(10,2)', 'decimal(10,0)', 'decimal(10,2)', 'decimal(10,0)'])
    end

    it "retains maximum unsigned precision (prepared: #{prepared})" do
      @client.query('CREATE TEMPORARY TABLE decimal_max_precision (a DECIMAL(65,0) UNSIGNED, b DECIMAL(65,30) UNSIGNED)')
      sql = 'SELECT * FROM decimal_max_precision'
      result = prepared ? @client.prepare(sql).execute : @client.query(sql)
      expect(result.field_types).to eq(['decimal(65,0)', 'decimal(65,30)'])
    end
  end
end
