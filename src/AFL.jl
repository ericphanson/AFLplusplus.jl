# Based on:
# https://github.com/sevenfourtwo/AFL.jl/blob/d418986d29ae8968067cd6d0b60d6f0f3445e305/src/AFL.jl
module AFL

export init_target,
       run_target

const RPC_RM_ID = 0;
const IPC_CREAT = 0o1000;
const SHM_RW = 0o600;
const MAP_SIZE = 1024 * 64
const EXEC_FAIL_SIG = UInt8[0xad, 0xde, 0xe1, 0xfe]


"""
    Result

Enum representing the return state of the running the target with an input.
"""
@enum Result begin
    Ok=0
    Crash=1
    Timeout=2
    Error=3
end

"""
    Target

Represents a running AFL forkserver and a shared memory segment for the branch bitmap. Create one with
[`init_target`](@ref) and close the handle with `close`.
"""
struct Target
    handle::Base.Process
    shm_id::Int
    trace_bits::Vector{UInt8}
    input_io::IOStream
end


function Base.close(target::Target)
    # detach the shared memory segment used for the branch bitmap
    @ccall shmdt(target.trace_bits::Ptr{UInt8})::Int32
    @ccall shmctl(target.shm_id::Int, RPC_RM_ID::Int32, 0::Int32)::Int32

    # kill the forkserver
    kill(target.handle)
end

function init_shm()
  # flags for the 64kb shared memory segment
  shmflags = IPC_CREAT + SHM_RW

  # create the shared memory segment
  shm_id = @ccall shmget(0::Int, MAP_SIZE::Int, shmflags::Int)::Int32
  if shm_id == -1
      error("Failed to initialise shared memory")
  end
  return shm_id

end

"""
    init_target(target_path::String; qemu=false, memlimit=200)

Start a forkserver for the given target.
"""
function init_target(target_path::String)
    # isfile(target_path) || error("Target '$target_path' does not exist")
    # TODO: check qemu supported on current platform

    shm_id = init_shm()
    # and load it in the address space of the current process
    map_ptr = @ccall shmat(shm_id::Int, 0::Int, 0::Int)::Ptr{UInt8}
    if map_ptr == -1
        error("Failed to allocate shared memory")
    end

    # create a julia array covering the shared memory
    trace_bits = unsafe_wrap(Array, map_ptr, MAP_SIZE)

    # temporary file used for the input
    input_file, input_io = mktemp()

    # start the forkserver, passing the shared memory id as env variable
    env = Dict("__AFL_SHM_ID" => shm_id, "LD_BIND_NOW" => 1)

    dir = abspath(joinpath(@__DIR__, ".."))
    script = """
    using AFLplusplus
    ctx = AFLplusplus.init_context()
    str = read(ARGS[1], String)
    AFLplusplus.trace(ctx, str -> Meta.parse(str; raise=false), str)
    """
    script = "println()"
    # cmd = Cmd(`julia --project=$dir -e $script -- $input_file`; env=env)
    cmd = Cmd(`docker run -ti -v julia -e 'println()' aflplusplus/aflplusplus julia --project=$dir -e $script -- $input_file`)
    # cmd = Cmd(`julia -e $script`)

    handle = open(cmd, write=true, read=true)

    # read the 4 byte hello message from the AFL trampoline
    res = read(handle, 4)
    if length(res) != 4
        if trace_bits[1:4] == EXEC_FAIL_SIG
            error("Forkserver failed to start properly")
        else
            error("Failed handshake with forkserver")
        end
    end

    Target(handle, shm_id, trace_bits, input_io)
end


"""
    run_target(target::Target, input::Vector{UInt8}; timeout=1)

Run the target with the specified input. Times out after `timeout` seconds. Return value is a Result enum.
"""
function run_target(target::Target, input::Vector{UInt8}; timeout::Int=1)::Result
    # reset the branch bitmap
    fill!(target.trace_bits, 0)

    # write input to the temporary input file
    truncate(target.input_io, 0)
    write(target.input_io, input)
    flush(target.input_io)

    # write 4 bytes to the forkserver to trigger a fork
    write(target.handle, Int32(0))

    # get the pid of the child from the forkserver
    pid = read(target.handle, Int32)
    if pid == 0
        error("Did not receive child pid from forkserver")
    end

    # setup timeout
    timed_out = false
    status = 0xFFFF0000

    timeout_task = @async begin
        sleep(timeout)

        if status == 0xFFFF0000
            timed_out = true
            run(pipeline(`kill -9 $pid`, stdout=devnull, stderr=devnull))
        end
    end

    # get the status of the child from the forkserver, this will not return
    # until the target exits
    status = read(target.handle, UInt32)

    if ((status & 0x7f) + 1 >> 1) > 0
        signal = status & 0x7f

        # check if child timed out
        if signal == Base.SIGKILL && timed_out
            return Timeout
        end

        # check if the forkserver reported a failure
        if target.map[1:4] == EXEC_FAIL_SIG
            return Error
        end

        return Crash
    end

    Ok
end
run_target(target::Target, input::Base.CodeUnits{UInt8, String}; kws...) = run_target(target, Vector{UInt8}(input); kws...)



end # module
