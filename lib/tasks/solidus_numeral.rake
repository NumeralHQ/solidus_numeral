# frozen_string_literal: true

namespace :numeral do
  desc "Push the Spree catalog (variants with SKUs) to Numeral as products"
  task sync_products: :environment do
    puts "Syncing products to Numeral..."
    SolidusNumeral::SyncProductsJob.perform_now
    puts "Done. See solidus_numeral_sync_logs (action=product_sync) for the summary."
  end
end
