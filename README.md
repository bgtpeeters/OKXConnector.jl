# OKXConnector.jl

[![CI](https://github.com/bgtpeeters/OKXConnector.jl/actions/workflows/ci.yml/badge.svg)](https://github.com/bgtpeeters/OKXConnector.jl/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A pure Julia connector to the [OKX v5 REST API](https://www.okx.com/docs-v5/en/).

No PyCall. No system libraries. Just HTTP.jl.

---

## Features

- Public market-data endpoints — no credentials required
- Signed (HMAC-SHA256 + Base64) account and trading endpoints
- `candles` returns a fully typed `DataFrame` (9 columns, oldest → newest)
- Regional hosts built in — `GLOBAL_BASE_URL`, `EEA_BASE_URL`, `US_BASE_URL`
- Demo (paper) trading via a single `demo=true` flag
- Clean error handling — API and non-2xx responses throw `OKXError`

## Installation

```julia
using Pkg
Pkg.add(url="https://github.com/bgtpeeters/OKXConnector.jl")
```

## Quick start

```julia
using OKXConnector

# Public client — no credentials needed
client = OKXClient()

# Candlestick data — returns a DataFrame, most recent row last
df = candles(client, "BTC-USDT", "1H"; limit=100)

# Latest 24-hour ticker
t = ticker(client, "BTC-USDT")

# Order book — asks/bids DataFrames, best price first
book = orderbook(client, "BTC-USDT"; depth=20)

# Instrument trading rules
info = instruments(client; instType="SPOT", instId="BTC-USDT")
```

## Authenticated usage

OKX signed endpoints need three credentials: API key, secret, and the
passphrase you chose when creating the key.

```julia
auth = OKXClient(
    api_key    = "YOUR_KEY",
    secret_key = "YOUR_SECRET",
    passphrase = "YOUR_PASSPHRASE",
)

# Account balances
bals = balance(auth)

# Place a spot market buy (live — use demo first!)
order = place_order(auth, "BTC-USDT", "buy", "market"; sz=0.001)
```

## EEA (European Economic Area)

OKX serves the EEA through a separate entity on a different host. Point the
client at it with the bundled constant:

```julia
eea = OKXClient(
    base_url   = OKXConnector.EEA_BASE_URL,
    api_key    = "...", secret_key = "...", passphrase = "...",
)
```

## Demo trading

OKX exposes paper trading on the same hosts. Pass `demo=true` and the client
will add the `x-simulated-trading: 1` header to every request.

```julia
demo = OKXClient(
    api_key="DEMO_KEY", secret_key="DEMO_SECRET", passphrase="DEMO_PASS",
    demo=true,
)
```

## API reference

### `OKXClient`

```julia
OKXClient(;
    base_url   = "https://www.okx.com",  # or EEA_BASE_URL / US_BASE_URL
    api_key    = "",
    secret_key = "",
    passphrase = "",
    demo       = false,
    cache_ttl  = 3600.0,   # seconds to cache instruments per (instType, instId); 0.0 disables
)
```

`OKXClient` caches `instruments` responses per `(instType, instId)` for
`cache_ttl` seconds (default 1 hour). `place_order` reuses this cache to fetch
`lotSz` and `tickSz` so it can round `sz` and `px` to the instrument's
allowed precision before sending — without this OKX rejects orders with a
precision error.

### `candles`

```julia
df = candles(client, instId, bar;
    after  = nothing,   # Unix ms — return data older than this (exclusive)
    before = nothing,   # Unix ms — return data newer than this (exclusive)
    limit  = nothing,   # max 300, default 100
)
```

Returns a `DataFrame` with columns:
`open_time`, `open`, `high`, `low`, `close`, `volume`, `quote_volume`,
`volume_usd`, `confirm`.

`bar` is the OKX candle size — minutes use lowercase, hours/days uppercase:
`"1m"`, `"3m"`, `"5m"`, `"15m"`, `"30m"`, `"1H"`, `"2H"`, `"4H"`, `"6H"`,
`"12H"`, `"1D"`, `"1W"`, `"1M"`.

### `history_candles`

```julia
df = history_candles(client, instId, bar;
    after  = nothing,   # Unix ms — return data older than this (exclusive)
    before = nothing,   # Unix ms — return data newer than this (exclusive)
    limit  = nothing,   # max 100, default 100
)
```

Same shape and arguments as `candles`, but calls
`GET /api/v5/market/history-candles`, which reaches further back in time.
The per-call cap is 100 rows (vs. 300 for `candles`) — paginate with `after`
to pull older windows.

### `ticker`

```julia
ticker(client, instId)
```

Returns a `Dict` with the latest 24-hour ticker for the instrument. Key
fields include `"instId"`, `"last"`, `"askPx"`, `"bidPx"`, `"open24h"`,
`"high24h"`, `"low24h"`, `"vol24h"`, `"volCcy24h"`, `"ts"`.

### `orderbook`

```julia
book = orderbook(client, instId;
    depth = nothing,   # levels per side, max 400, default 1
)
```

Returns a `NamedTuple` `(asks, bids, ts)`. `asks` and `bids` are
`DataFrame`s with columns `price`, `size`, `orders`, best price first;
`ts` is the snapshot time as a UTC `DateTime`.

### `instruments`

```julia
instruments(client;
    instType   = "SPOT",          # SPOT | MARGIN | SWAP | FUTURES | OPTION
    instId     = nothing,
    uly        = nothing,
    instFamily = nothing,
)
```

Returns a `Vector{Dict}` of instrument metadata: `"instId"`, `"baseCcy"`,
`"quoteCcy"`, `"minSz"`, `"lotSz"`, `"tickSz"`, `"state"`, ...

### `balance` *(signed)*

```julia
balance(client; ccy=nothing)
```

Returns a `Dict` with account equity and a `"details"` vector of per-currency
balances. `ccy` accepts a single currency or a comma-separated list, e.g.
`"BTC,ETH,USDT"`.

### `place_order` *(signed)*

```julia
place_order(client, instId, side, ordType;
    tdMode     = "cash",        # cash | cross | isolated
    sz         = nothing,
    px         = nothing,        # required for limit orders
    tgtCcy     = nothing,        # base_ccy | quote_ccy  (spot market only)
    clOrdId    = nothing,
    tag        = nothing,
    reduceOnly = nothing,
    posSide    = nothing,
    ccy        = nothing,
)
```

`side` is `"buy"` or `"sell"`. `ordType` is `"market"`, `"limit"`,
`"post_only"`, `"fok"`, or `"ioc"`.

`sz` and `px` are automatically rounded to the instrument's `lotSz` /
`tickSz` before being sent.

## Error handling

All non-2xx responses and OKX error payloads throw an `OKXError`:

```julia
try
    candles(client, "INVALID-XYZ-PAIR", "1H")
catch e
    e isa OKXError && println("Code $(e.code): $(e.msg)")
end
```

OKX returns error codes as strings (e.g. `"50011"` for rate-limit exceeded);
`OKXError.code` preserves that.

## License

MIT — see [LICENSE](LICENSE).
