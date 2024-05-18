module AFLplusplus

# https://github.com/sevenfourtwo/AFL.jl/blob/d418986d29ae8968067cd6d0b60d6f0f3445e305/src/AFL.jl#L13C1-L18C1
const RPC_RM_ID = 0
const IPC_CREAT = 0o1000
const SHM_RW = 0o600
const EXEC_FAIL_SIG = UInt8[0xad, 0xde, 0xe1, 0xfe]
const MAP_SIZE = 1 << 16

# https://github.com/jwilk/python-afl/blob/9388a5ad4f6ea1d74370fb265178f41d1e8417ef/afl.pyx#L66-L79
function lhash(key::String, offset::UInt32)
    h = UInt32(0x811C9DC5)

    for c in key
        h ⊻= UInt32(c)
        h *= 0x01000193
    end

    while offset > 0
        h ⊻= UInt32(offset & 0xff)
        h *= 0x01000193
        offset >>= 8
    end

    return h
end

function _which(@nospecialize(tt::Type), world=Base.get_world_counter())
    match, _ = Core.Compiler._findsup(tt, nothing, world)
    return match
end

function trywhich(@nospecialize(f), @nospecialize(t))
    tt = Base.signature_type(f, t)
    ret = _which(tt)
    if ret !== nothing && ret.method.file !== Symbol("")
        @debug string(ret.method.file, ":", ret.method.line)
        return lhash(string(ret.method.file), ret.method.line % UInt32)
    else
        return UInt32(0)
    end
end

using Cassette
Cassette.@context TracingCtx

function update!(ctx, f, args...)
    location = trywhich(f, typeof(args)) % MAP_SIZE
    offset = location ⊻ ctx.metadata.prev_location[]
    ctx.metadata.prev_location[] = fld(location, 2)
    if offset == 0
        offset = one(offset)
    end
    T = eltype(ctx.metadata.afl_area)
    ctx.metadata.afl_area[offset] += one(T)
    return nothing
end

function Cassette.prehook(ctx::TracingCtx, f, args...)
    update!(ctx, f, args...)
    # @debug string("prehook: ", f, " ", map(typeof, args))
    return nothing
end

function Cassette.fallback(ctx::TracingCtx, f, args...)
    update!(ctx, f, args...)
    # @debug string("fallback: ", f, " ", map(typeof, args))
    return f(args...)
end

function init_context()
    shm_id = parse(Int, ENV["__AFL_SHM_ID"])

    # and load it in the address space of the current process
    map_ptr = @ccall shmat(shm_id::Int, 0::Int, 0::Int)::Ptr{UInt8}

    if map_ptr == -1
        error("Failed to allocate shared memory")
    end

    # create a julia array covering the shared memory
    trace_bits = unsafe_wrap(Array, map_ptr, MAP_SIZE)

    return TracingCtx(metadata=(; prev_location=Ref{UInt32}(0),
                                  afl_area=trace_bits))
end

function trace(ctx, f, args...)
    Cassette.overdub(ctx, f, args...)
end

include("AFL.jl")
using .AFL

end
