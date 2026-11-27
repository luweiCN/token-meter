package tokenmeter

import _ "embed"

//go:embed Sources/TokenMeterCore/Resources/litellm-pricing.json
var BundledPricing []byte

//go:embed Sources/TokenMeterCore/Resources/account-providers.json
var BundledAccountProviders []byte
