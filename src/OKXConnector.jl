"""
    OKXConnector

A pure Julia connector to the OKX v5 REST API.

Provides native Julia bindings via HTTP.jl — no PyCall, no system libraries.
Supports both public (unauthenticated) and signed (HMAC-SHA256 + Base64) endpoints.

# Quick start

    using OKXConnector

    # Public client — no credentials needed
    client = OKXClient()

    # Candlestick data — returns a DataFrame, most recent row last
    df = candles(client, "BTC-USDT", "1H"; limit=100)

    # Latest price for one instrument
    t = ticker(client, "BTC-USDT")

    # Instrument trading rules
    info = instruments(client; instType="SPOT", instId="BTC-USDT")

    # Authenticated client — passphrase is the one you chose when creating the key
    auth = OKXClient(
        api_key    = "YOUR_KEY",
        secret_key = "YOUR_SECRET",
        passphrase = "YOUR_PASSPHRASE",
    )

    # Account balances
    bals = balance(auth)

    # Place a spot market order (live — use demo first!)
    order = place_order(auth, "BTC-USDT", "buy", "market"; sz=0.001)

# European (EEA) users

OKX serves the European Economic Area through its EEA entity. Point the
client at the EEA host:

    eea = OKXClient(
        base_url   = OKXConnector.EEA_BASE_URL,
        api_key    = "...", secret_key = "...", passphrase = "...",
    )

# Demo trading

OKX provides a paper-trading environment on the same hosts. Enable it with
`demo=true` — the client will add `x-simulated-trading: 1` to every request.

    demo = OKXClient(
        api_key="DEMO_KEY", secret_key="DEMO_SECRET", passphrase="DEMO_PASS",
        demo=true,
    )
"""
module OKXConnector

using HTTP
using JSON3
using SHA
using Base64
using Dates
using DataFrames

include("client.jl")
include("auth.jl")
include("http.jl")
include("endpoints/market.jl")
include("endpoints/account.jl")

export OKXClient
export OKXError
export candles
export history_candles
export ticker
export orderbook
export instruments
export balance
export place_order

# Convenience constants for OKX regional hosts.
const GLOBAL_BASE_URL = "https://www.okx.com"
const EEA_BASE_URL    = "https://eea.okx.com"
const US_BASE_URL     = "https://us.okx.com"

end # module OKXConnector
