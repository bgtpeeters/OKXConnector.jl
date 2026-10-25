# ---------------------------------------------------------------------------
# endpoints/market.jl — Public market-data endpoints (no auth required).
#
#   candles(client, instId, bar; kwargs...)          GET /api/v5/market/candles
#   history_candles(client, instId, bar; kwargs...)  GET /api/v5/market/history-candles
#   ticker(client, instId)                           GET /api/v5/market/ticker
#   orderbook(client, instId; depth)                 GET /api/v5/market/books
#   instruments(client; instType, ...)               GET /api/v5/public/instruments
# ---------------------------------------------------------------------------

# Internal — recursively convert JSON3 values to plain Julia types.
function _json3_to_dict(obj)
    if obj isa JSON3.Object
        return Dict{String,Any}(String(k) => _json3_to_dict(v) for (k, v) in obj)
    elseif obj isa JSON3.Array
        return [_json3_to_dict(v) for v in obj]
    elseif obj isa AbstractString
        return String(obj)
    else
        return obj
    end
end

# Internal — convert OKX's raw candle rows ([ts, o, h, l, c, vol, volCcy,
# volCcyQuote, confirm], newest-first, each value a string) into the 9-column
# DataFrame shared by `candles` and `history_candles`. Rows are reversed so
# the result is oldest → newest.
function _candles_to_dataframe(raw)::DataFrame
    n = length(raw)
    open_time    = Vector{DateTime}(undef, n)
    open         = Vector{Float64}(undef,  n)
    high         = Vector{Float64}(undef,  n)
    low          = Vector{Float64}(undef,  n)
    close        = Vector{Float64}(undef,  n)
    volume       = Vector{Float64}(undef,  n)
    quote_volume = Vector{Float64}(undef,  n)
    volume_usd   = Vector{Float64}(undef,  n)
    confirm      = Vector{Bool}(undef,     n)

    for (k, row) in enumerate(raw)
        i = n - k + 1
        open_time[i]    = unix2datetime(parse(Int64, String(row[1])) / 1000)
        open[i]         = parse(Float64, String(row[2]))
        high[i]         = parse(Float64, String(row[3]))
        low[i]          = parse(Float64, String(row[4]))
        close[i]        = parse(Float64, String(row[5]))
        volume[i]       = parse(Float64, String(row[6]))
        quote_volume[i] = parse(Float64, String(row[7]))
        volume_usd[i]   = parse(Float64, String(row[8]))
        confirm[i]      = String(row[9]) == "1"
    end

    return DataFrame(
        open_time    = open_time,
        open         = open,
        high         = high,
        low          = low,
        close        = close,
        volume       = volume,
        quote_volume = quote_volume,
        volume_usd   = volume_usd,
        confirm      = confirm,
    )
end

# ---------------------------------------------------------------------------
# candles
# ---------------------------------------------------------------------------

"""
    candles(client, instId, bar; after, before, limit) -> DataFrame

Return candlestick data for the spot instrument `instId` at the given `bar`
size.

Calls `GET /api/v5/market/candles` and returns a `DataFrame` with 9 typed
columns, sorted oldest → newest (most recent row last).

# Arguments
- `client::OKXClient`
- `instId::String` — Instrument ID, e.g. `"BTC-USDT"` (note: hyphen-separated).
- `bar::String`    — Candle size. Minutes use lowercase, hours/days uppercase:
  `"1m"`, `"3m"`, `"5m"`, `"15m"`, `"30m"`, `"1H"`, `"2H"`, `"4H"`,
  `"6H"`, `"12H"`, `"1D"`, `"1W"`, `"1M"`.

# Keyword Arguments
- `after::Union{Int,Nothing}`  — Pagination: return data older than this
  Unix-ms timestamp (exclusive).
- `before::Union{Int,Nothing}` — Pagination: return data newer than this
  Unix-ms timestamp (exclusive).
- `limit::Union{Int,Nothing}`  — Number of candles, max 300, default 100.

# Columns
| Column         | Type     | Description                            |
|----------------|----------|----------------------------------------|
| `open_time`    | DateTime | Bar open time (UTC)                    |
| `open`         | Float64  |                                        |
| `high`         | Float64  |                                        |
| `low`          | Float64  |                                        |
| `close`        | Float64  |                                        |
| `volume`       | Float64  | Volume in the base currency (`vol`)    |
| `quote_volume` | Float64  | Volume in the quote currency (`volCcy`)|
| `volume_usd`   | Float64  | Volume valued in USD (`volCcyQuote`)   |
| `confirm`      | Bool     | `true` once the bar is closed          |

# Example

    client = OKXClient()
    df = candles(client, "BTC-USDT", "1H"; limit=100)
"""
function candles(
    client ::OKXClient,
    instId ::String,
    bar    ::String;
    after  ::Union{Int,Nothing} = nothing,
    before ::Union{Int,Nothing} = nothing,
    limit  ::Union{Int,Nothing} = nothing,
)::DataFrame
    params = Dict{String,Any}(
        "instId" => instId,
        "bar"    => bar,
    )
    after  !== nothing && (params["after"]  = after)
    before !== nothing && (params["before"] = before)
    limit  !== nothing && (params["limit"]  = limit)

    raw = _public_get(client, "/api/v5/market/candles"; params=params)
    return _candles_to_dataframe(raw)
end

# ---------------------------------------------------------------------------
# history_candles
# ---------------------------------------------------------------------------

"""
    history_candles(client, instId, bar; after, before, limit) -> DataFrame

Return historical candlestick data for `instId` at the given `bar` size,
reaching further back in time than [`candles`](@ref).

Calls `GET /api/v5/market/history-candles` and returns a `DataFrame` with the
same 9 typed columns as `candles`, sorted oldest → newest (most recent row
last).

# Arguments
- `client::OKXClient`
- `instId::String` — Instrument ID, e.g. `"BTC-USDT"` (note: hyphen-separated).
- `bar::String`    — Candle size. Minutes use lowercase, hours/days uppercase:
  `"1m"`, `"3m"`, `"5m"`, `"15m"`, `"30m"`, `"1H"`, `"2H"`, `"4H"`,
  `"6H"`, `"12H"`, `"1D"`, `"1W"`, `"1M"`.

# Keyword Arguments
- `after::Union{Int,Nothing}`  — Pagination: return data older than this
  Unix-ms timestamp (exclusive).
- `before::Union{Int,Nothing}` — Pagination: return data newer than this
  Unix-ms timestamp (exclusive). Without `after` set too, OKX returns only
  the most recent 100 rows regardless of `limit`.
- `limit::Union{Int,Nothing}`  — Number of candles, max 100, default 100.
  (Unlike `candles`, this endpoint caps at 100 rather than 300.)

# Columns

Same as [`candles`](@ref): `open_time`, `open`, `high`, `low`, `close`,
`volume`, `quote_volume`, `volume_usd`, `confirm`.

# Example

    client = OKXClient()
    # Candles from ~30 days ago, paginating backward with `after`.
    cutoff = Int(round(datetime2unix(now(UTC) - Day(30)) * 1000))
    df = history_candles(client, "BTC-USDT", "1H"; after=cutoff, limit=100)
"""
function history_candles(
    client ::OKXClient,
    instId ::String,
    bar    ::String;
    after  ::Union{Int,Nothing} = nothing,
    before ::Union{Int,Nothing} = nothing,
    limit  ::Union{Int,Nothing} = nothing,
)::DataFrame
    params = Dict{String,Any}(
        "instId" => instId,
        "bar"    => bar,
    )
    after  !== nothing && (params["after"]  = after)
    before !== nothing && (params["before"] = before)
    limit  !== nothing && (params["limit"]  = limit)

    raw = _public_get(client, "/api/v5/market/history-candles"; params=params)
    return _candles_to_dataframe(raw)
end

# ---------------------------------------------------------------------------
# ticker
# ---------------------------------------------------------------------------

"""
    ticker(client, instId) -> Dict

Return the latest 24-hour ticker for `instId`.

Calls `GET /api/v5/market/ticker?instId=...`. Returns a `Dict` with fields
including `"instId"`, `"last"`, `"askPx"`, `"bidPx"`, `"open24h"`,
`"high24h"`, `"low24h"`, `"vol24h"`, `"volCcy24h"`, `"ts"`.

# Example

    client = OKXClient()
    t = ticker(client, "BTC-USDT")
    parse(Float64, t["last"])
"""
function ticker(client::OKXClient, instId::String)::Dict
    raw = _public_get(client, "/api/v5/market/ticker";
                      params=Dict{String,Any}("instId" => instId))
    # OKX returns `data` as a single-element array.
    if raw isa JSON3.Array && !isempty(raw)
        return _json3_to_dict(raw[1])
    end
    return _json3_to_dict(raw)
end

# ---------------------------------------------------------------------------
# orderbook
# ---------------------------------------------------------------------------

# Internal — convert OKX book levels ([px, sz, deprecated, numOrders], each
# value a string) into a 3-column DataFrame, keeping OKX's level order.
function _book_side_to_dataframe(levels)::DataFrame
    n = length(levels)
    price  = Vector{Float64}(undef, n)
    size   = Vector{Float64}(undef, n)
    orders = Vector{Int}(undef,     n)

    for (i, level) in enumerate(levels)
        price[i]  = parse(Float64, String(level[1]))
        size[i]   = parse(Float64, String(level[2]))
        orders[i] = parse(Int,     String(level[4]))
    end

    return DataFrame(price = price, size = size, orders = orders)
end

"""
    orderbook(client, instId; depth) -> NamedTuple

Return the current order book for `instId`.

Calls `GET /api/v5/market/books` and returns `(asks, bids, ts)`:
- `asks::DataFrame` — best (lowest) price first.
- `bids::DataFrame` — best (highest) price first.
- `ts::DateTime`    — book snapshot time (UTC).

Each side has columns `price`, `size` (in the base currency for spot) and
`orders` (number of orders at that level). Either side may be empty for an
illiquid instrument.

# Keyword Arguments
- `depth::Union{Int,Nothing}` — Levels per side (OKX `sz`), max 400,
  default 1.

# Example

    client = OKXClient()
    book = orderbook(client, "BTC-USDT"; depth=20)
    spread = book.asks.price[1] - book.bids.price[1]
"""
function orderbook(
    client ::OKXClient,
    instId ::String;
    depth  ::Union{Int,Nothing} = nothing,
)::NamedTuple
    params = Dict{String,Any}("instId" => instId)
    depth !== nothing && (params["sz"] = depth)

    raw  = _public_get(client, "/api/v5/market/books"; params=params)
    # OKX returns `data` as a single-element array.
    book = raw[1]

    return (
        asks = _book_side_to_dataframe(book[:asks]),
        bids = _book_side_to_dataframe(book[:bids]),
        ts   = unix2datetime(parse(Int64, String(book[:ts])) / 1000),
    )
end

# ---------------------------------------------------------------------------
# instruments
# ---------------------------------------------------------------------------

"""
    instruments(client; instType, instId, uly, instFamily) -> Vector{Dict}

Return trading rules and metadata for instruments matching the given filters.

Calls `GET /api/v5/public/instruments`. The OKX endpoint requires `instType`;
`instId` and the other filters narrow the result.

# Keyword Arguments
- `instType::String` — Instrument type. One of `"SPOT"` (default), `"MARGIN"`,
  `"SWAP"`, `"FUTURES"`, `"OPTION"`.
- `instId::Union{String,Nothing}`     — Filter to a single instrument.
- `uly::Union{String,Nothing}`        — Underlying (futures / options / swap).
- `instFamily::Union{String,Nothing}` — Instrument family.

# Returns
A `Vector{Dict}`. Each dict carries fields including `"instId"`, `"baseCcy"`,
`"quoteCcy"`, `"minSz"`, `"lotSz"`, `"tickSz"`, `"state"`.

Results are cached per `(instType, instId)` for `client.cache_ttl` seconds.

# Example

    client = OKXClient()
    info = instruments(client; instType="SPOT", instId="BTC-USDT")
    info[1]["baseCcy"]   # => "BTC"
"""
function instruments(
    client     ::OKXClient;
    instType   ::String                 = "SPOT",
    instId     ::Union{String,Nothing}  = nothing,
    uly        ::Union{String,Nothing}  = nothing,
    instFamily ::Union{String,Nothing}  = nothing,
)::Vector
    # Cache only the simple (instType, instId|"") form; calls with uly /
    # instFamily are rare and skip the cache.
    cacheable = uly === nothing && instFamily === nothing
    cache_key = (instType, instId === nothing ? "" : instId)

    if cacheable && client.cache_ttl > 0.0
        entry = get(client._instruments_cache, cache_key, nothing)
        if entry !== nothing
            (cached_data, cached_at) = entry
            if time() - cached_at < client.cache_ttl
                return cached_data
            end
        end
    end

    params = Dict{String,Any}("instType" => instType)
    instId     !== nothing && (params["instId"]     = instId)
    uly        !== nothing && (params["uly"]        = uly)
    instFamily !== nothing && (params["instFamily"] = instFamily)

    raw    = _public_get(client, "/api/v5/public/instruments"; params=params)
    result = [_json3_to_dict(item) for item in raw]

    if cacheable && client.cache_ttl > 0.0
        client._instruments_cache[cache_key] = (result, time())
    end

    return result
end
