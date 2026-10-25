# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

OKXConnector.jl — a pure Julia client for the OKX v5 REST API (public market data + HMAC-signed
account/trading endpoints). Julia 1.10+. No PyCall, no system libraries; built on HTTP.jl, JSON3.jl,
SHA.jl, Base64, and DataFrames.jl.

## Commands

Run all from the repo root (where `Project.toml` lives).

```julia
# Install/resolve dependencies
julia --project=. -e 'using Pkg; Pkg.instantiate()'

# Run the full test suite
julia --project=. -e 'using Pkg; Pkg.test()'

# Run tests with the REPL for iteration (faster than repeated Pkg.test())
julia --project=.
julia> using Pkg; Pkg.test()
```

There is no separate lint/format command or CI step beyond `julia-runtest` — CI (`.github/workflows/ci.yml`)
just runs `Pkg.test()` on Julia 1.10 and latest stable, Ubuntu only.

### Running a subset of tests

`test/runtests.jl` is one flat file of `@testset` blocks (no per-file test targets, no name filter).
You can skip `Pkg.test()`'s sandbox setup by running the file directly, because `Test` is a stdlib and
`DataFrames`/`Dates` are already package deps:

```bash
julia --project=. test/runtests.jl
```

The file is ordered offline-first: the plain `@testset` blocks at the top (constructor, regional URLs,
`OKXError` display, numeric formatting, cache fields, auth helpers, sign prehash) need no network and
exercise the private `_`-prefixed helpers directly via `OKXConnector._name`. Everything from the first
`@skipable_testset` onward hits live OKX endpoints.

To run a subset, temporarily comment out the other `@testset`/`@skipable_testset` blocks. You can also
`include("test/runtests.jl")` from a `julia --project=.` REPL after editing it.

### Enabling signed-endpoint tests

Most integration tests hit public OKX endpoints and always run. Tests for signed endpoints are
gated on environment variables and skip gracefully (via `@test true` / `@info`) when absent:

- `OKX_API_KEY`, `OKX_SECRET_KEY`, `OKX_PASSPHRASE` — enables the `balance` test.
- Additionally `OKX_DEMO=1` — enables `place_order`, run only against OKX's demo/paper environment
  (never live) even when credentials are present.

CI passes the three `OKX_*` credentials from repo secrets but never sets `OKX_DEMO`, so `place_order`
never runs in CI.

Public integration tests (`candles`, `ticker`, `instruments`, etc.) are wrapped in the
`@skipable_testset` macro (defined at the top of `test/runtests.jl`), which turns OKX geo-restriction
errors (msg containing "restricted"/"not available", or code `"50110"`) into a skipped/broken test
rather than a CI failure, since OKX blocks some endpoints by requester region.

## Architecture

Everything is `include`d into one module (`src/OKXConnector.jl`); there are no submodules. Load order
matters and mirrors the dependency chain:

```
client.jl              → OKXClient struct, OKXError
auth.jl                → request signing (needs OKXClient)
http.jl                → _public_get / _signed_get / _signed_post (needs auth.jl + OKXError)
endpoints/market.jl     → candles, history_candles, ticker, instruments (public, uses http.jl)
endpoints/account.jl    → balance, place_order (signed, uses http.jl + calls instruments() for precision)
```

**Request flow for every endpoint function**: build a params `Dict` → call one of the three `http.jl`
entry points (`_public_get`, `_signed_get`, `_signed_post`) → `_handle_response` unwraps OKX's
`{code, msg, data}` envelope and throws `OKXError` on `code != "0"` or non-2xx HTTP → the endpoint
function reshapes `data` (JSON3 values) into the public return type (`Dict`, `Vector{Dict}`, or
`DataFrame`).

**Candle parsing**: `candles` and `history_candles` (`endpoints/market.jl`) hit different OKX paths
(`/api/v5/market/candles` vs `/api/v5/market/history-candles` — the latter reaches further back in time
but caps at 100 rows/call instead of 300) but share identical response shape, so both funnel through
`_candles_to_dataframe` to build the 9-column `DataFrame`.

**Signing** (`auth.jl`): OKX requires `base64(HMAC_SHA256(secret, timestamp + METHOD + requestPath + body))`
sent as `OK-ACCESS-SIGN`, alongside `OK-ACCESS-KEY`, `OK-ACCESS-TIMESTAMP` (ISO-8601 ms, same string used
in the signature), and `OK-ACCESS-PASSPHRASE`. For GETs, `requestPath` includes the query string and
`body` is `""`; for POSTs, `body` must be byte-identical to what's actually sent, which is why
`_signed_post` builds the JSON body once (`_json_body`) and reuses that exact string for both signing
and the request.

**Numeric formatting** (`auth.jl`): OKX rejects requests with floating-point artifacts (e.g.
`"0.0014700000000000002"`) or scientific notation. `_format_number_for_url` rounds to 8 decimals and
renders fixed-point with trailing zeros stripped; both `_build_query` (query strings) and `_json_body`
(POST bodies — as JSON *strings*, since OKX expects `"sz":"0.001"` not a JSON number) route all `Real`
values through it. Any new endpoint that sends numeric params must go through these helpers, not
`string()` or raw JSON serialization.

**Order-precision rounding** (`endpoints/account.jl`): `place_order` calls `instruments()` internally to
fetch `lotSz`/`tickSz` for the instrument and rounds `sz`/`px` to the nearest valid step
(`_round_to_step_precision`) before sending — otherwise OKX rejects orders with a precision error. This
rounding is skipped for spot market buys quoted in the quote currency (`sz` is a quote-currency amount,
not a base-currency lot count) and for non-cash `tdMode` (margin/futures aren't spot-lot-rounded here).

**Instrument caching**: `OKXClient` holds a mutable `_instruments_cache::Dict{(instType,instId) => (data,
timestamp)}` field (the struct's other fields are `const`). `instruments()` reads/writes this cache when
called with only `instType`/`instId` (not `uly`/`instFamily`) and `cache_ttl > 0`. `place_order` benefits
transparently since it calls `instruments()` for precision lookups. A cache hit returns the cached
`Vector{Dict}` itself, not a copy, so a caller that mutates the result also changes the cache. The
`OKXClient` keyword `cache_ttl` is typed `::Float64`, so pass `0.0` rather than `0` to disable it.

**JSON3 → plain Julia conversion**: OKX responses come back as `JSON3.Object`/`JSON3.Array` (lazy views
over the response buffer). `_json3_to_dict` (in `endpoints/market.jl`) recursively converts these to
plain `Dict{String,Any}`/`Vector`/`String` before returning to the caller — every public-facing endpoint
function does this at its boundary rather than leaking JSON3 types.

**Regions & demo mode**: `GLOBAL_BASE_URL`/`EEA_BASE_URL`/`US_BASE_URL` (in `OKXConnector.jl`) are just
different `base_url` values passed to `OKXClient()` — no other code branches on region. `demo=true` adds
the `x-simulated-trading: 1` header (`_base_headers` in `http.jl`) to route calls to OKX's paper-trading
environment on the same host.

## Adding a new endpoint

Follow the existing pattern in `endpoints/market.jl` (public) or `endpoints/account.jl` (signed):
1. Build a `Dict{String,Any}` of params, skipping `nothing` values (existing endpoints do this manually
   with `x !== nothing && (params["x"] = x)` rather than a generic helper).
2. Call `_public_get`, `_signed_get`, or `_signed_post` from `http.jl`.
3. Convert the returned JSON3 data via `_json3_to_dict`, unwrap single-element arrays OKX uses for
   scalar responses (see `ticker`/`balance`/`place_order`), and add the function to the `export` list in
   `src/OKXConnector.jl`.
