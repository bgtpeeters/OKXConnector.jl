# ---------------------------------------------------------------------------
# endpoints/account.jl — Signed account and trading endpoints.
#
#   balance(client; ccy)                                     GET  /api/v5/account/balance
#   place_order(client, instId, side, ordType; kwargs...)    POST /api/v5/trade/order
#
# Internal helpers (not exported):
#   _get_instrument_filters    — lotSz / tickSz / minSz for a spot instId
#   _round_to_step_precision   — round value to nearest step multiple
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Precision helpers
# ---------------------------------------------------------------------------

function _round_to_step_precision(value::Real, step_size::Real)::Float64
    step_size <= 0.0 && return Float64(value)
    return round(value / step_size) * step_size
end

# Returns (lotSz, tickSz, minSz) as Float64s for the given spot instId, or
# (0.0, 0.0, 0.0) if the instrument is unknown.
function _get_instrument_filters(
    client ::OKXClient,
    instId ::String,
)::NTuple{3, Float64}
    info = instruments(client; instType="SPOT", instId=instId)
    isempty(info) && return (0.0, 0.0, 0.0)
    inst = info[1]
    lot  = haskey(inst, "lotSz")  ? parse(Float64, inst["lotSz"])  : 0.0
    tick = haskey(inst, "tickSz") ? parse(Float64, inst["tickSz"]) : 0.0
    minSz= haskey(inst, "minSz")  ? parse(Float64, inst["minSz"])  : 0.0
    return (lot, tick, minSz)
end

# ---------------------------------------------------------------------------
# balance
# ---------------------------------------------------------------------------

"""
    balance(client; ccy) -> Dict

Return the account balance summary.

Calls `GET /api/v5/account/balance` (signed). OKX returns a single object
wrapping a `"details"` array, one entry per currency.

# Keyword Arguments
- `ccy::Union{String,Nothing}` — Comma-separated currencies to filter,
  e.g. `"BTC"` or `"BTC,ETH,USDT"`. If omitted, returns all currencies with
  a non-zero balance.

# Returns
A `Dict` whose key fields include:
- `"totalEq"`  — Total account equity (USD value).
- `"uTime"`    — Last update time (Unix ms, string).
- `"details"`  — `Vector{Dict}`, one per currency with fields such as
  `"ccy"`, `"eq"`, `"availBal"`, `"frozenBal"`, `"cashBal"`.

# Example

    auth = OKXClient(api_key="...", secret_key="...", passphrase="...")
    bals = balance(auth)
    for d in bals["details"]
        println(d["ccy"], ": ", d["availBal"])
    end
"""
function balance(
    client ::OKXClient;
    ccy    ::Union{String,Nothing} = nothing,
)::Dict
    params = Dict{String,Any}()
    ccy !== nothing && (params["ccy"] = ccy)

    raw = _signed_get(client, "/api/v5/account/balance"; params=params)
    # OKX returns `data` as a single-element array containing the summary.
    if raw isa JSON3.Array && !isempty(raw)
        return _json3_to_dict(raw[1])
    end
    return _json3_to_dict(raw)
end

# ---------------------------------------------------------------------------
# place_order
# ---------------------------------------------------------------------------

"""
    place_order(client, instId, side, ordType; kwargs...) -> Dict

Place a new order on OKX.

Calls `POST /api/v5/trade/order` (signed). For spot trading, `tdMode` defaults
to `"cash"` — set explicitly for margin (`"cross"`, `"isolated"`).

# Arguments
- `client::OKXClient`
- `instId::String`  — Instrument ID, e.g. `"BTC-USDT"`.
- `side::String`    — `"buy"` or `"sell"`.
- `ordType::String` — Order type: `"market"`, `"limit"`, `"post_only"`,
  `"fok"`, `"ioc"`.

# Keyword Arguments
- `tdMode::String` — Trade mode: `"cash"` (spot, default), `"cross"`,
  `"isolated"`.
- `sz::Union{Real,Nothing}`  — Order quantity. Units depend on `tgtCcy`:
  by default, spot `buy market` orders use the quote currency, all other
  spot orders use the base currency. Pass `tgtCcy="base_ccy"` to force
  base-currency units for market buys.
- `px::Union{Real,Nothing}`  — Price. Required for `limit`-style orders.
- `tgtCcy::Union{String,Nothing}` — `"base_ccy"` or `"quote_ccy"`. Only
  applies to spot market orders. See OKX docs for details.
- `clOrdId::Union{String,Nothing}` — Client-supplied order ID (≤32 chars,
  alphanumeric).
- `tag::Union{String,Nothing}`     — Order tag.
- `reduceOnly::Union{Bool,Nothing}`— Margin only.
- `posSide::Union{String,Nothing}` — Position side (futures / swap).
- `ccy::Union{String,Nothing}`     — Margin currency (cross-margin only).

# Returns
A `Dict` with the order acknowledgement. Fields include `"ordId"`,
`"clOrdId"`, `"tag"`, `"sCode"`, `"sMsg"`.

`sz` and `px` are rounded to the instrument's `lotSz` and `tickSz`
respectively before being sent, eliminating "too much precision"
rejections.

# Example

    auth = OKXClient(api_key="K", secret_key="S", passphrase="P")
    # Test on demo first!
    order = place_order(auth, "BTC-USDT", "buy", "limit"; sz=0.001, px=20000)
"""
function place_order(
    client  ::OKXClient,
    instId  ::String,
    side    ::String,
    ordType ::String;
    tdMode     ::String                = "cash",
    sz         ::Union{Real,Nothing}   = nothing,
    px         ::Union{Real,Nothing}   = nothing,
    tgtCcy     ::Union{String,Nothing} = nothing,
    clOrdId    ::Union{String,Nothing} = nothing,
    tag        ::Union{String,Nothing} = nothing,
    reduceOnly ::Union{Bool,Nothing}   = nothing,
    posSide    ::Union{String,Nothing} = nothing,
    ccy        ::Union{String,Nothing} = nothing,
)::Dict
    # Round to instrument precision when we can identify a spot instrument.
    if tdMode == "cash"
        (lotSz, tickSz, _) = _get_instrument_filters(client, instId)
        # Market buys in quote currency: do not round to lotSz (sz is in quote ccy).
        is_quote_market_buy = ordType == "market" && side == "buy" &&
                              (tgtCcy === nothing || tgtCcy == "quote_ccy")
        if sz !== nothing && lotSz > 0.0 && !is_quote_market_buy
            sz = _round_to_step_precision(sz, lotSz)
        end
        if px !== nothing && tickSz > 0.0
            px = _round_to_step_precision(px, tickSz)
        end
    end

    params = Dict{String,Any}(
        "instId"  => instId,
        "tdMode"  => tdMode,
        "side"    => side,
        "ordType" => ordType,
    )
    sz         !== nothing && (params["sz"]         = sz)
    px         !== nothing && (params["px"]         = px)
    tgtCcy     !== nothing && (params["tgtCcy"]     = tgtCcy)
    clOrdId    !== nothing && (params["clOrdId"]    = clOrdId)
    tag        !== nothing && (params["tag"]        = tag)
    reduceOnly !== nothing && (params["reduceOnly"] = reduceOnly)
    posSide    !== nothing && (params["posSide"]    = posSide)
    ccy        !== nothing && (params["ccy"]        = ccy)

    raw = _signed_post(client, "/api/v5/trade/order"; body_params=params)
    # `data` is a single-element array containing the acknowledgement.
    if raw isa JSON3.Array && !isempty(raw)
        return _json3_to_dict(raw[1])
    end
    return _json3_to_dict(raw)
end
