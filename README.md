# solidus_numeral

Official [Numeral](https://www.numeralhq.com) tax extension for
[Solidus](https://solidus.io/).

- **Live tax calculation** at checkout through Numeral's tax engine
  (US, Canada, EU VAT, and 60+ other countries).
- **Automatic transaction recording**: completed orders are committed to
  Numeral's ledger for filing — the tax charged to the customer is exactly
  what gets filed.
- **Refunds and cancellations**: RMA reimbursements, order cancellations, and
  short-ships are reported as refunds automatically.
- **Customer exemptions** managed per-user from the Solidus admin.

Requires Solidus >= 4.6, Rails >= 7.2, Ruby >= 3.2. The extension targets
[Solidus](https://solidus.io/) specifically: it plugs into
`Spree::Config.tax_calculator_class` and subscribes to `Spree::Bus`, neither
of which exists in [Spree](https://spreecommerce.org/), so it does not run on
Spree stores.

## Installation

Add the gem:

```ruby
# Gemfile
gem "solidus_numeral", github: "NumeralHQ/solidus_numeral"
```

Once the gem is published to rubygems.org, `gem "solidus_numeral"` works too.

Then install:

```bash
bundle install
bin/rails generate solidus_numeral:install
```

The generator creates `config/initializers/solidus_numeral.rb`, copies the
migrations, and offers to run them. If you prefer to wire things up manually:

```ruby
# config/initializers/solidus_numeral.rb
SolidusNumeral.configure do |config|
  config.api_key = ENV["NUMERAL_API_KEY"]
end

Spree.config do |config|
  config.tax_calculator_class = "SolidusNumeral::TaxCalculator"
  config.shipping_rate_tax_calculator_class = "SolidusNumeral::ShippingRateTaxCalculator"
end
```

```bash
bin/rails railties:install:migrations FROM=solidus_numeral
bin/rails db:migrate
```

### API keys

Create your API keys in the Numeral dashboard when connecting your Solidus
store. You get a pair:

- `sk_test_...` — test mode. Calculations and transactions are recorded in
  test mode and never filed. Use this in development/staging.
- `sk_live_...` — live mode, for production.

Which mode the gem runs in is determined entirely by which key you configure —
there is no separate test-mode flag.

### Background jobs

Transaction commits, refunds, and syncs run through ActiveJob. Use a real
ActiveJob backend (Sidekiq, GoodJob, SolidQueue, ...) in production — with the
default inline/async adapters a Numeral outage could impact request handling,
and failed jobs won't be retried. Retries follow your adapter's configuration;
every attempt is also recorded in the `solidus_numeral_sync_logs` table
(action, status, Numeral id, error message) for debugging.

## Configuration reference

```ruby
SolidusNumeral.configure do |config|
  config.api_key = ENV["NUMERAL_API_KEY"] # required
  config.api_base = "https://api.numeralhq.com" # default
  config.enabled = true                   # kill switch for calc + ledger
  config.cache_duration = 3.hours         # calculation response cache TTL
  config.tax_included_in_price = nil      # nil = derive from Spree::TaxRate#included_in_price
  config.logger = nil                     # defaults to Rails.logger

  # Called with any exception raised during checkout tax calculation.
  # The calculator itself NEVER raises (it degrades to zero tax) so an API
  # outage can't break checkout.
  config.exception_handler = ->(e) { ... }

  # Order-level discount proration (see "Discounts" below). Must respond to
  # call(order) and return {line_item_id => BigDecimal discount share}.
  config.discount_calculator = SolidusNumeral::DiscountCalculator.new
end
```

## Mapping tax categories to Numeral product categories

Numeral decides taxability per line from its product taxonomy. The gem sends
each line item's `Spree::TaxCategory#tax_code` (a core Solidus column) as the
Numeral `product_category`, so:

1. Fetch the valid codes from `GET /tax/product_categories` (or see the
   Numeral docs).
2. Set `tax_code` on your tax categories to the matching Numeral code (e.g.
   `CLOTHING`, `FOOD_BEVERAGE_GROCERIES`, ...).

Lines with no mapped code fall back to `GENERAL_MERCHANDISE` — calculations
never fail on an unmapped SKU.

### Product sync (optional, recommended)

Calculations auto-create products from SKUs, so no pre-sync is required. To
make your catalog visible in the Numeral dashboard (and eligible for AI
categorization / ops review), push it once:

```bash
bin/rails numeral:sync_products
```

The task iterates every variant with a SKU, is idempotent (re-runs skip
existing products), and throttles itself under Numeral's rate limit.

## Customer exemptions

Visit `/admin/users/:id/numeral_information` for any user (the screen is not
injected into the admin user tabs — link it wherever fits your admin) to:

- Mark the user **tax exempt**: the gem syncs a customer record to Numeral
  (`is_tax_exempt: true`) and subsequent calculations for that user reference
  it and return zero tax. Unchecking syncs the revocation.
- Store a **VAT identification number**: calculations then send the user as a
  `BUSINESS` customer with the VAT id (typed per the order's destination
  country, e.g. `eu_vat` / `gb_vat`), enabling EU B2B reverse charge. If the
  destination country has no supported tax id type, the id is omitted and a
  warning is logged.

Guests and non-exempt users need no customer sync.

## Behavior notes

- **Caching.** Solidus recalculates taxes on every cart mutation and checkout
  transition (5–15 times per checkout). Responses are cached in `Rails.cache`
  keyed on the serialized calculation request, so identical order states cost
  nothing and any change to lines/address/discounts busts the cache naturally.
  Default TTL 3 hours (Numeral calculations stay valid for 24).
- **Checkout never breaks.** Missing/incomplete addresses, empty carts, the
  kill switch, and API errors all yield zero tax instead of raising. Tax
  appears once the merchant enables collection for a jurisdiction in Numeral
  (until then calculations return 0% "no nexus" results — that's by design).
- **Shipping.** Each shipment is sent as a `SHIPPING` line item, so shipping
  taxability follows each state's rules. The delivery-step *shipping rate*
  tax display is intentionally a no-op (it would cost one API call per
  candidate rate for a display-only number); shipping tax is calculated and
  charged as soon as the order recalculates after rate selection.
- **Discounts.** Numeral has no discount field. Line-level promotions are
  already reflected in `total_before_tax`; order-level promotions are
  prorated across line items (by pre-discount line total) before encoding.
  Amounts are sent as per-unit integer minor units (post-discount), which can
  drift from the exact line total by up to quantity/2 cents on discounted
  lines — the same accepted behavior as every other Numeral integration.
- **Tax-inclusive prices.** `tax_included_in_amount` is decided per order: it
  is true only when an `included_in_price` `Spree::TaxRate`'s zone covers the
  order's tax address (so US-destination orders on a mixed US+VAT store stay
  exclusive); override globally with `config.tax_included_in_price` if that
  heuristic doesn't fit your store.
- **Order lifecycle.** Commit on `:order_finalized`; full refund on
  `:order_canceled` (or the remaining headroom, if partial refunds exist);
  partial refund on `:reimbursement_reimbursed` (grouped per original line
  item); delta partial refund on `:order_short_shipped`. Refund amounts are
  capped against the amounts actually committed to Numeral, so rounding can
  never cause an over-refund rejection. Voided orders are never refunded
  again. Before every refund the gem reconciles its local refund ledger
  against the refunds Numeral already has on record for the transaction, so
  a job retry after a lost response (e.g. a timeout after Numeral recorded
  the refund) is a no-op — or refunds exactly the remainder — instead of
  double-reporting.
- **Placeholder tax rate.** Solidus requires each tax adjustment to reference
  a `Spree::TaxRate`; the gem maintains a single zero-amount rate named
  `"Numeral Tax"` for this. Don't delete it or attach zones/categories to it.

## Development

```bash
bin/rails db:migrate   # in the dummy app, via solidus_dev_support
bundle exec rspec
```

Specs are pure-logic unit tests (payload encoding, refund math, calculator
guards) with stubbed HTTP — no Numeral account needed.
