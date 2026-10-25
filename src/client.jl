# ---------------------------------------------------------------------------
# OKXClient — holds connection configuration for every API call.
# ---------------------------------------------------------------------------

"""
    OKXClient(; base_url, api_key, secret_key, passphrase, demo, cache_ttl)

Configuration object passed to every API function.

# Keyword Arguments
- `base_url::String`   — Base URL of the OKX REST API.
                         Default: `"https://www.okx.com"`.
                         For the EEA entity use `OKXConnector.EEA_BASE_URL`
                         (`"https://eea.okx.com"`).
- `api_key::String`    — OKX API key. Required for signed endpoints.
                         Default: `""` (public endpoints only).
- `secret_key::String` — OKX secret key used for HMAC-SHA256 signing.
                         Required for signed endpoints. Default: `""`.
- `passphrase::String` — Passphrase set when the API key was created.
                         Required for signed endpoints. Default: `""`.
- `demo::Bool`         — If `true`, send `x-simulated-trading: 1` on every
                         request so OKX routes the call to its demo-trading
                         environment. Default: `false`.
- `cache_ttl::Float64` — Seconds to cache `instruments` responses per
                         (instType, instId). Default: `3600.0` (1 hour).
                         Set to `0.0` to disable.

# Examples

    # Public client — market data only, no credentials needed
    client = OKXClient()

    # Authenticated client — required for account and trading endpoints
    auth = OKXClient(
        api_key    = "abc123",
        secret_key = "xyz789",
        passphrase = "my-passphrase",
    )

    # European Economic Area entity
    eea = OKXClient(
        base_url   = OKXConnector.EEA_BASE_URL,
        api_key    = "...", secret_key = "...", passphrase = "...",
    )

    # Demo (paper) trading on the same host
    demo = OKXClient(
        api_key="...", secret_key="...", passphrase="...", demo=true,
    )
"""
mutable struct OKXClient
    const base_url   ::String
    const api_key    ::String
    const secret_key ::String
    const passphrase ::String
    const demo       ::Bool
    const cache_ttl  ::Float64
    _instruments_cache ::Dict{Tuple{String,String}, Tuple{Vector, Float64}}
end

function OKXClient(;
    base_url   ::String  = "https://www.okx.com",
    api_key    ::String  = "",
    secret_key ::String  = "",
    passphrase ::String  = "",
    demo       ::Bool    = false,
    cache_ttl  ::Float64 = 3600.0,
)
    return OKXClient(
        base_url, api_key, secret_key, passphrase, demo, cache_ttl,
        Dict{Tuple{String,String}, Tuple{Vector, Float64}}(),
    )
end

# ---------------------------------------------------------------------------
# OKXError — thrown when the API returns a non-2xx response or an error
# payload in the JSON body.
# ---------------------------------------------------------------------------

"""
    OKXError(code, msg)

Exception thrown when the OKX API returns an error.

Fields:
- `code::String` — OKX error code (e.g. `"50011"` for rate-limit exceeded).
                   Kept as `String` because OKX returns codes as strings.
- `msg::String`  — Human-readable error message from the API.
"""
struct OKXError <: Exception
    code ::String
    msg  ::String
end

function Base.showerror(io::IO, e::OKXError)
    print(io, "OKXError($(e.code)): $(e.msg)")
end
