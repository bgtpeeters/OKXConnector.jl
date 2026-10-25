using Test
using OKXConnector
using DataFrames
using Dates

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

const HAS_CREDENTIALS = get(ENV, "OKX_API_KEY", "")    != "" &&
                        get(ENV, "OKX_SECRET_KEY", "") != "" &&
                        get(ENV, "OKX_PASSPHRASE", "") != ""

function auth_client(; demo::Bool=false)
    OKXClient(
        api_key    = ENV["OKX_API_KEY"],
        secret_key = ENV["OKX_SECRET_KEY"],
        passphrase = ENV["OKX_PASSPHRASE"],
        demo       = demo,
    )
end

# OKX restricts certain endpoints by region. Translate the common geo-block
# error codes into a graceful skip so CI does not fail for infra reasons.
_is_geo_blocked(e::OKXError) =
    occursin("restricted", lowercase(e.msg)) ||
    occursin("not available", lowercase(e.msg)) ||
    e.code == "50110"   # IP not in the allow-list for the region
_is_geo_blocked(e) = false

macro skipable_testset(name, body)
    quote
        @testset $name begin
            try
                $(esc(body))
            catch e
                if _is_geo_blocked(e)
                    @warn "Skipping \"" * $name * "\": OKX geo-restriction ($(e.code))"
                    @test_broken false
                else
                    rethrow()
                end
            end
        end
    end
end

# ---------------------------------------------------------------------------
# Unit tests — no network required
# ---------------------------------------------------------------------------

@testset "OKXClient constructor" begin
    c = OKXClient()
    @test c.base_url   == "https://www.okx.com"
    @test c.api_key    == ""
    @test c.secret_key == ""
    @test c.passphrase == ""
    @test c.demo       == false
    @test c.cache_ttl  == 3600.0

    c2 = OKXClient(
        base_url   = OKXConnector.EEA_BASE_URL,
        api_key    = "key",
        secret_key = "secret",
        passphrase = "passphrase",
        demo       = true,
    )
    @test c2.base_url   == "https://eea.okx.com"
    @test c2.api_key    == "key"
    @test c2.secret_key == "secret"
    @test c2.passphrase == "passphrase"
    @test c2.demo       == true
end

@testset "Regional base-URL constants" begin
    @test OKXConnector.GLOBAL_BASE_URL == "https://www.okx.com"
    @test OKXConnector.EEA_BASE_URL    == "https://eea.okx.com"
    @test OKXConnector.US_BASE_URL     == "https://us.okx.com"
end

@testset "OKXError display" begin
    err = OKXError("50011", "Rate limit exceeded.")
    msg = sprint(showerror, err)
    @test occursin("50011", msg)
    @test occursin("Rate limit exceeded.", msg)
end

@testset "Numeric formatting" begin
    fmt = OKXConnector._format_number_for_url

    # The root problem case: floating-point artifact must be cleaned up
    @test fmt(0.0014700000000000002) == "0.00147"

    # Integers pass through unchanged
    @test fmt(10)  == "10"
    @test fmt(100) == "100"

    # Clean floats strip trailing zeros
    @test fmt(0.001)      == "0.001"
    @test fmt(10.0)       == "10"
    @test fmt(100.5)      == "100.5"
    @test fmt(0.00001)    == "0.00001"
    @test fmt(0.00000001) == "0.00000001"

    # No scientific notation for large or small values
    @test !occursin('e', fmt(50000.0))
    @test !occursin('e', fmt(0.00000001))

    # Large floats must not overflow (previously scaled to Int64 by 1e8)
    @test fmt(1.0e11)          == "100000000000"
    @test fmt(1.0e11 + 0.5)    == "100000000000.5"
    @test fmt(1.0e20)          == "100000000000000000000"
    @test fmt(-1234.5678)      == "-1234.5678"
    @test fmt(-0.0)            == "0"
    @test fmt(0.000000004)     == "0"
    @test_throws ArgumentError fmt(Inf)
    @test_throws ArgumentError fmt(NaN)

    # _build_query uses _format_number_for_url for Real values
    q = OKXConnector._build_query(Dict("sz" => 0.0014700000000000002))
    @test occursin("sz=0.00147", q)

    # _json_body emits numerics as strings (OKX expects "sz":"0.001")
    body = OKXConnector._json_body(Dict("sz" => 0.001, "instId" => "BTC-USDT"))
    @test occursin("\"sz\":\"0.001\"", body)
    @test occursin("\"instId\":\"BTC-USDT\"", body)
end

@testset "Instruments cache fields" begin
    client = OKXClient()
    @test isempty(client._instruments_cache)
    @test client.cache_ttl == 3600.0

    client2 = OKXClient(cache_ttl=0.0)
    @test client2.cache_ttl == 0.0
end

@testset "Auth helpers" begin
    # _iso_timestamp() should be ISO 8601 with ms precision and a trailing Z
    ts = OKXConnector._iso_timestamp()
    @test endswith(ts, "Z")
    @test length(ts) == length("2020-12-08T09:08:57.715Z")
    @test occursin(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$", ts)

    # HMAC-SHA256 + Base64 — verified against `openssl dgst -sha256 -hmac ... | base64`.
    # Input matches the prehash format OKX docs describe.
    sig = OKXConnector._hmac_sha256_base64(
        "22582BD0CFF14C41EDBF1AB98506286D",
        "2020-12-08T09:08:57.715ZGET/users/self/verify",
    )
    @test sig == "vPTGlFn/TNqBMlYCAIlx+GAQO0sl7Iz8OyCpDrUUcbk="

    # _build_query — nothing values are skipped
    q = OKXConnector._build_query(Dict("b" => "2", "a" => "1", "c" => nothing))
    @test occursin("a=1", q)
    @test occursin("b=2", q)
    @test !occursin("c=", q)

    # _urlencode — spaces and special chars
    @test OKXConnector._urlencode("hello world") == "hello%20world"
    @test OKXConnector._urlencode("a+b=c")       == "a%2Bb%3Dc"
end

@testset "Sign prehash construction" begin
    # _sign should sign exactly timestamp+method+path+body and refuse to run
    # without a secret_key.
    nokey = OKXClient()
    @test_throws ErrorException OKXConnector._sign(nokey, "t", "GET", "/x", "")

    c = OKXClient(secret_key = "22582BD0CFF14C41EDBF1AB98506286D")
    sig = OKXConnector._sign(
        c, "2020-12-08T09:08:57.715Z", "GET", "/users/self/verify", "",
    )
    @test sig == "vPTGlFn/TNqBMlYCAIlx+GAQO0sl7Iz8OyCpDrUUcbk="
end

# ---------------------------------------------------------------------------
# Integration tests — hit OKX public endpoints
# ---------------------------------------------------------------------------

@skipable_testset "candles — BTC-USDT 1H last 10 candles" begin
    client = OKXClient()
    df = candles(client, "BTC-USDT", "1H"; limit=10)

    @test df isa DataFrame
    @test nrow(df) == 10
    @test ncol(df) == 9

    expected_cols = [
        :open_time, :open, :high, :low, :close,
        :volume, :quote_volume, :volume_usd, :confirm,
    ]
    for col in expected_cols
        @test col in propertynames(df)
    end

    @test eltype(df.open_time) == DateTime
    @test eltype(df.open)      == Float64
    @test eltype(df.confirm)   == Bool

    # Sorted oldest → newest
    @test issorted(df.open_time)

    # OHLC sanity
    @test all(df.high .>= df.low)
    @test all(df.high .>= df.open)
    @test all(df.high .>= df.close)
    @test all(df.volume .>= 0)
end

@skipable_testset "candles — single candle returns 1-row DataFrame" begin
    client = OKXClient()
    df = candles(client, "ETH-USDT", "1D"; limit=1)
    @test nrow(df) == 1
end

@skipable_testset "history_candles — BTC-USDT 1H last 10 candles" begin
    client = OKXClient()
    df = history_candles(client, "BTC-USDT", "1H"; limit=10)

    @test df isa DataFrame
    @test nrow(df) == 10
    @test ncol(df) == 9

    expected_cols = [
        :open_time, :open, :high, :low, :close,
        :volume, :quote_volume, :volume_usd, :confirm,
    ]
    for col in expected_cols
        @test col in propertynames(df)
    end

    @test eltype(df.open_time) == DateTime
    @test eltype(df.open)      == Float64
    @test eltype(df.confirm)   == Bool

    # Sorted oldest → newest
    @test issorted(df.open_time)

    # OHLC sanity
    @test all(df.high .>= df.low)
    @test all(df.high .>= df.open)
    @test all(df.high .>= df.close)
    @test all(df.volume .>= 0)
end

@skipable_testset "history_candles — pagination reaches further back than candles" begin
    client = OKXClient()
    recent = candles(client, "BTC-USDT", "1D"; limit=1)
    cutoff = Int(round(datetime2unix(recent.open_time[1]) * 1000))

    df = history_candles(client, "BTC-USDT", "1D"; after=cutoff, limit=5)
    @test df isa DataFrame
    @test nrow(df) >= 1
    @test all(df.open_time .< recent.open_time[1])
end

@skipable_testset "ticker — BTC-USDT" begin
    client = OKXClient()
    t = ticker(client, "BTC-USDT")
    @test t isa Dict
    @test t["instId"] == "BTC-USDT"
    @test haskey(t, "last")
    @test parse(Float64, t["last"]) > 0
end

@skipable_testset "instruments — single SPOT instrument" begin
    client = OKXClient()
    info = instruments(client; instType="SPOT", instId="BTC-USDT")
    @test info isa Vector
    @test length(info) == 1
    @test info[1]["instId"]   == "BTC-USDT"
    @test info[1]["baseCcy"]  == "BTC"
    @test info[1]["quoteCcy"] == "USDT"
end

@skipable_testset "OKXError thrown for invalid instrument" begin
    client = OKXClient()
    @test_throws OKXError candles(client, "INVALID-XYZ-PAIR", "1H"; limit=1)
end

@skipable_testset "instruments caching" begin
    client = OKXClient(cache_ttl=3600.0)
    @test isempty(client._instruments_cache)

    info1 = instruments(client; instType="SPOT", instId="BTC-USDT")
    @test haskey(client._instruments_cache, ("SPOT", "BTC-USDT"))

    info2 = instruments(client; instType="SPOT", instId="BTC-USDT")
    @test info1 === info2

    client_nocache = OKXClient(cache_ttl=0.0)
    instruments(client_nocache; instType="SPOT", instId="BTC-USDT")
    @test isempty(client_nocache._instruments_cache)
end

# ---------------------------------------------------------------------------
# Integration tests — signed endpoints (skip without credentials)
# ---------------------------------------------------------------------------

@testset "balance — requires credentials" begin
    if !HAS_CREDENTIALS
        @info "Skipping balance test: OKX_API_KEY / OKX_SECRET_KEY / OKX_PASSPHRASE not set"
        @test true
    else
        client = auth_client()
        bals   = balance(client)
        @test bals isa Dict
        @test haskey(bals, "details")
        @test bals["details"] isa Vector
        for d in bals["details"]
            @test d isa Dict
            @test haskey(d, "ccy")
            @test haskey(d, "availBal")
        end
    end
end

@testset "place_order — requires demo credentials" begin
    # We only exercise the live POST against the demo environment to avoid
    # accidentally moving real funds. Set OKX_DEMO=1 to opt in.
    if !HAS_CREDENTIALS || get(ENV, "OKX_DEMO", "") != "1"
        @info "Skipping place_order test: set OKX_DEMO=1 and OKX_* demo credentials to run"
        @test true
    else
        client = auth_client(demo=true)
        # Tiny far-from-market limit buy — won't fill, easy to cancel.
        order = place_order(
            client, "BTC-USDT", "buy", "limit";
            tdMode="cash", sz=0.001, px=1.0,
        )
        @test order isa Dict
        @test haskey(order, "ordId") || haskey(order, "sCode")
    end
end
