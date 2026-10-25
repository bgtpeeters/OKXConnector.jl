# ---------------------------------------------------------------------------
# auth.jl — Request signing for OKX v5 signed endpoints.
#
# OKX signed-endpoint flow:
#   1. Build prehash = timestamp + METHOD + requestPath + body
#        - timestamp is the ISO 8601 UTC string with millisecond precision
#          (e.g. "2020-12-08T09:08:57.715Z").
#        - METHOD is uppercase ("GET", "POST", "DELETE").
#        - requestPath includes the query string for GET requests
#          (e.g. "/api/v5/account/balance?ccy=BTC").
#        - body is the exact JSON string sent for POST; "" for GET.
#   2. Compute HMAC-SHA256(secret_key, prehash) → raw 32-byte digest.
#   3. Base64-encode the digest. (NOT hex — different from Binance.)
#   4. Send headers:
#        OK-ACCESS-KEY        = api_key
#        OK-ACCESS-SIGN       = base64 signature
#        OK-ACCESS-TIMESTAMP  = the same timestamp used in the prehash
#        OK-ACCESS-PASSPHRASE = passphrase set when the API key was created
# ---------------------------------------------------------------------------

"""
    _iso_timestamp() -> String

Return the current UTC time formatted per OKX's `OK-ACCESS-TIMESTAMP` spec:
ISO 8601 with millisecond precision and a trailing `Z`, e.g.
`"2020-12-08T09:08:57.715Z"`.
"""
function _iso_timestamp()::String
    t  = now(UTC)
    ms = lpad(millisecond(t), 3, '0')
    return Dates.format(t, "yyyy-mm-ddTHH:MM:SS") * "." * ms * "Z"
end

"""
    _hmac_sha256_base64(secret::String, message::String) -> String

Compute HMAC-SHA256 of `message` using `secret` and return the Base64-encoded
digest, as required by `OK-ACCESS-SIGN`.
"""
function _hmac_sha256_base64(secret::String, message::String)::String
    key    = Vector{UInt8}(secret)
    msg    = Vector{UInt8}(message)
    digest = SHA.hmac_sha256(key, msg)
    return base64encode(digest)
end

"""
    _format_number_for_url(v::Real) -> String

Format a numeric value for inclusion in a query string or JSON body sent to
OKX. Integers pass through; floats are rounded to 8 decimal places and rendered
in fixed-point notation (never scientific notation) with trailing zeros
stripped.

This prevents floating-point artifacts such as `"0.0014700000000000002"` that
would otherwise be rejected by OKX with a precision error. Throws
`ArgumentError` for `Inf`/`NaN`.
"""
function _format_number_for_url(v::Real)::String
    v isa Integer && return string(v)
    x = round(Float64(v), digits=8)
    isfinite(x) || throw(ArgumentError("cannot send non-finite number to OKX: $v"))
    x == 0 && return "0"
    # string() gives the shortest round-trip digits, possibly in scientific
    # notation ("1.5e-5", "1.0e20"); shift the decimal point to get fixed-point.
    # Working on digits rather than scaling to an integer avoids overflow.
    s = string(abs(x))
    mant, exp = occursin('e', s) ? (split(s, 'e')[1], parse(Int, split(s, 'e')[2])) : (s, 0)
    int_part, frac_part = split(mant, '.')
    digits = int_part * frac_part
    point = length(int_part) + exp
    if point <= 0
        digits = "0"^(1 - point) * digits
        point = 1
    elseif point > length(digits)
        digits *= "0"^(point - length(digits))
    end
    int_str = lstrip(digits[1:point], '0')
    frac_str = rstrip(digits[point+1:end], '0')
    result = (isempty(int_str) ? "0" : int_str) * (isempty(frac_str) ? "" : "." * frac_str)
    return x < 0 ? "-" * result : result
end

"""
    _urlencode(s::String) -> String

Percent-encode a string for use in a URL query string. Leaves alphanumerics
and `-_.~` unencoded per RFC 3986.
"""
function _urlencode(s::String)::String
    buf = IOBuffer()
    for c in s
        if isletter(c) || isdigit(c) || c in ('-', '_', '.', '~')
            write(buf, c)
        else
            for byte in Vector{UInt8}(string(c))
                write(buf, '%')
                write(buf, uppercase(string(byte, base=16, pad=2)))
            end
        end
    end
    return String(take!(buf))
end

"""
    _build_query(params::AbstractDict) -> String

Encode a dictionary of parameters into a URL query string. Keys and values
are converted to strings; `nothing` values are skipped. Numeric values are
formatted via [`_format_number_for_url`](@ref) to avoid floating-point
artifacts.
"""
function _build_query(params::AbstractDict)::String
    parts = String[]
    for (k, v) in params
        v === nothing && continue
        v_str = v isa Real ? _format_number_for_url(v) : string(v)
        push!(parts, string(k) * "=" * _urlencode(v_str))
    end
    return join(parts, "&")
end

"""
    _json_body(params::AbstractDict) -> String

Render a parameter dictionary as a compact JSON object suitable for an OKX
POST body. `nothing` values are dropped. Numeric values are emitted as JSON
strings via [`_format_number_for_url`](@ref) because OKX's order endpoints
expect quantities and prices as strings (e.g. `"sz":"0.001"`, `"px":"30000.5"`).
"""
function _json_body(params::AbstractDict)::String
    clean = Dict{String,Any}()
    for (k, v) in params
        v === nothing && continue
        clean[string(k)] = v isa Real ? _format_number_for_url(v) : v
    end
    return JSON3.write(clean)
end

"""
    _sign(client, timestamp, method, request_path, body) -> String

Compute the Base64 HMAC-SHA256 signature for an OKX signed request:

    sign = base64( HMAC_SHA256(secret_key, timestamp || method || request_path || body) )

`request_path` must include any query string. `body` must be the exact bytes
sent in the request body (empty string for GET).
"""
function _sign(
    client       ::OKXClient,
    timestamp    ::String,
    method       ::String,
    request_path ::String,
    body         ::String,
)::String
    isempty(client.secret_key) && error(
        "OKXConnector: secret_key is required for signed endpoints. " *
        "Create your client with OKXClient(api_key=..., secret_key=..., passphrase=...)."
    )
    prehash = timestamp * method * request_path * body
    return _hmac_sha256_base64(client.secret_key, prehash)
end
