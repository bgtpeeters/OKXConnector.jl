# ---------------------------------------------------------------------------
# http.jl — Low-level HTTP helpers for the OKX v5 REST API.
#
# Three entry-points used by endpoint files:
#   _public_get(client, path; params)             unauthenticated GET
#   _signed_get(client, path; params)             signed GET
#   _signed_post(client, path; body_params)       signed POST with JSON body
#
# All three return the parsed `data` field of OKX's response envelope.
#
# OKX wraps every response as:
#     { "code": "0", "msg": "", "data": [...] }
# When `code != "0"` we throw `OKXError(code, msg)`.
# ---------------------------------------------------------------------------

"""
    _handle_response(resp) -> Any

Parse the HTTP response body as JSON and return the `data` payload from
OKX's standard `{code, msg, data}` envelope. Throws [`OKXError`](@ref) if
`code != "0"` or if the HTTP status is not 2xx.
"""
function _handle_response(resp::HTTP.Response)
    body = String(resp.body)

    # Use codeunits(body) so JSON3 v1.14+ doesn't mistake the string for a
    # filename and call stat() on it. String(resp.body) consumes resp.body —
    # we must not re-read resp.body afterwards.
    parsed = try
        JSON3.read(codeunits(body))
    catch
        if resp.status < 200 || resp.status >= 300
            throw(OKXError("HTTP_$(resp.status)", body))
        end
        rethrow()
    end

    # OKX always wraps successful and most error responses in {code, msg, data}.
    if parsed isa JSON3.Object && haskey(parsed, :code)
        code = String(parsed[:code])
        if code != "0"
            # `data` may carry per-item errors (e.g. for /trade/order on
            # invalid orders OKX returns code="1" with data[0].sCode = real error).
            msg = haskey(parsed, :msg) ? String(parsed[:msg]) : ""
            if isempty(msg) && haskey(parsed, :data)
                d = parsed[:data]
                if d isa JSON3.Array && !isempty(d)
                    first_item = d[1]
                    if first_item isa JSON3.Object && haskey(first_item, :sMsg)
                        code = haskey(first_item, :sCode) ? String(first_item[:sCode]) : code
                        msg  = String(first_item[:sMsg])
                    end
                end
            end
            throw(OKXError(code, msg))
        end
    end

    if resp.status < 200 || resp.status >= 300
        throw(OKXError("HTTP_$(resp.status)", body))
    end

    return parsed
end

"""
    _extract_data(parsed)

Return `parsed.data` for the standard OKX envelope, or `parsed` itself for
the rare endpoint that does not wrap its payload.
"""
function _extract_data(parsed)
    if parsed isa JSON3.Object && haskey(parsed, :data)
        return parsed[:data]
    end
    return parsed
end

# Common headers shared by every request.
function _base_headers(client::OKXClient)
    headers = ["Accept" => "application/json"]
    client.demo && push!(headers, "x-simulated-trading" => "1")
    return headers
end

"""
    _public_get(client, path; params=Dict()) -> JSON3.Value

Send an unauthenticated GET to `client.base_url * path`. Returns the parsed
`data` payload.
"""
function _public_get(
    client ::OKXClient,
    path   ::String;
    params ::AbstractDict = Dict{String,Any}(),
)
    qs = _build_query(params)
    request_path = isempty(qs) ? path : path * "?" * qs
    url = client.base_url * request_path

    headers = _base_headers(client)
    resp    = HTTP.get(url, headers; status_exception=false)
    return _extract_data(_handle_response(resp))
end

"""
    _signed_get(client, path; params=Dict()) -> JSON3.Value

Send an HMAC-SHA256–signed GET request. Builds the signed `request_path`
(with query string) and the four `OK-ACCESS-*` headers OKX requires.
"""
function _signed_get(
    client ::OKXClient,
    path   ::String;
    params ::AbstractDict = Dict{String,Any}(),
)
    isempty(client.api_key)    && error("OKXConnector: api_key is required for signed endpoints.")
    isempty(client.passphrase) && error("OKXConnector: passphrase is required for signed endpoints.")

    qs = _build_query(params)
    request_path = isempty(qs) ? path : path * "?" * qs
    url = client.base_url * request_path

    timestamp = _iso_timestamp()
    signature = _sign(client, timestamp, "GET", request_path, "")

    headers = _base_headers(client)
    push!(headers,
        "OK-ACCESS-KEY"        => client.api_key,
        "OK-ACCESS-SIGN"       => signature,
        "OK-ACCESS-TIMESTAMP"  => timestamp,
        "OK-ACCESS-PASSPHRASE" => client.passphrase,
    )
    resp = HTTP.get(url, headers; status_exception=false)
    return _extract_data(_handle_response(resp))
end

"""
    _signed_post(client, path; body_params=Dict()) -> JSON3.Value

Send an HMAC-SHA256–signed POST request with a JSON body. The body is
serialized via [`_json_body`](@ref) and signed exactly as sent so the
server-side hash matches.
"""
function _signed_post(
    client      ::OKXClient,
    path        ::String;
    body_params ::AbstractDict = Dict{String,Any}(),
)
    isempty(client.api_key)    && error("OKXConnector: api_key is required for signed endpoints.")
    isempty(client.passphrase) && error("OKXConnector: passphrase is required for signed endpoints.")

    body = _json_body(body_params)
    url  = client.base_url * path

    timestamp = _iso_timestamp()
    signature = _sign(client, timestamp, "POST", path, body)

    headers = _base_headers(client)
    push!(headers,
        "Content-Type"         => "application/json",
        "OK-ACCESS-KEY"        => client.api_key,
        "OK-ACCESS-SIGN"       => signature,
        "OK-ACCESS-TIMESTAMP"  => timestamp,
        "OK-ACCESS-PASSPHRASE" => client.passphrase,
    )
    resp = HTTP.post(url, headers, body; status_exception=false)
    return _extract_data(_handle_response(resp))
end
