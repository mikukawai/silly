local c = require "core.c"
local logger = require "core.logger.c"

local core = {}
local type = type
local pairs = pairs
local assert = assert
local xpcall = xpcall
local tostring = tostring
local smatch = string.match
local tremove = table.remove
local tpack = table.pack
local tunpack = table.unpack
local traceback = debug.traceback
local weakmt = {__mode="kv"}

--misc
local log_info = assert(logger.info)
local log_error = assert(logger.error)
local readctrl = assert(c.readctrl)
local trace_new = assert(c.trace_new)
local trace_set = assert(c.trace_set)
local trace_span = assert(c.trace_span)

core.pid = c.getpid()
core.genid = c.genid
core.gitsha1 = c.gitsha1()
core.version = c.version()
core.tostring = c.tostring
core.multipack = assert(c.multipack)
core.sendsize = assert(c.sendsize)
core.socket_read_ctrl = function (sid, ctrl)
	return readctrl(sid, ctrl == "enable")
end

--signal
local signal = c.signal
local signal_map = c.signalmap()
local signal_dispatch = {}

--coroutine
--state migrate(RUN (WAIT->READY)/SLEEP RUN)
local task_status = setmetatable({}, weakmt)
local task_traceid = setmetatable({}, weakmt)
local task_running = "NIL"
local cocreate = coroutine.create
local corunning = coroutine.running
local coyield = coroutine.yield
local coresume = coroutine.resume
local coclose = coroutine.close
local task_yield = coyield
local function task_resume(t, ...)
	local save = task_running
	task_status[t] = "RUN"
	task_running = t
	local traceid = trace_set(t, task_traceid[t])
	local ok, err = coresume(t, ...)
	trace_set(traceid)
	task_running = save
	if not ok then
		task_status[t] = nil
		local ret = traceback(t, tostring(err), 1)
		log_error("[sys.core] task resume", ret)
		local ok, err = coclose(t)
		if not ok then
			log_error("[sys.core] task close", err)
		end
	else
		task_status[t] = err
	end
end

local function errmsg(msg)
	return traceback("error: " .. tostring(msg), 2)
end

local function core_pcall(f, ...)
	return xpcall(f, errmsg, ...)
end

core.tracespan = trace_span
core.tracepropagate = trace_new
function core.tracenew()
	local traceid = task_traceid[task_running]
	if traceid then
		return traceid
	end
	return trace_new()
end

function core.trace(id)
	task_traceid[task_running] = id
	return (trace_set(task_running, id))
end

function core.error(errmsg)
	log_error(errmsg)
	log_error(traceback())
end

core.pcall = core_pcall
function core.running()
	return task_running
end

--coroutine pool will be dynamic size
--so use the weaktable
local copool = {}
setmetatable(copool, weakmt)

local function task_create(f)
	local co = tremove(copool)
	if co then
		coresume(co, "STARTUP", f)
		return co
	end
	co = cocreate(function(...)
		f(...)
		while true do
			local ret
			f = nil
			local co = corunning()
			task_traceid[co] = nil
			copool[#copool + 1] = co
			ret, f = coyield("EXIT")
			if ret ~= "STARTUP" then
				log_error("[sys.core] task create", ret)
				log_error(traceback())
				return
			end
			f(coyield())
		end
	end)
	return co
end

local task_create_origin = task_create
local task_resume_origin = task_resume

function core.task_hook(create, term)
	if create then
		task_create = function(f)
			local t = task_create_origin(f)
			create(t)
			return t
		end
	else
		task_create = task_create_origin
	end
	if term then
		task_resume = function(t, ...)
			local ok, err = task_resume_origin(t, ...)
			if err == "EXIT" then
				term(t)
			end
		end
	else
		task_resume = task_resume_origin
	end
	return task_resume, task_yield
end


local wakeup_task_queue = {}
local wakeup_task_param = {}
local sleep_session_task = {}
local timer_user_data = {}

local dispatch_wakeup

core.exit = function(status)
	c.dispatch(function() end)
	wakeup_task_queue = {}
	wakeup_task_param = {}
	c.exit(status)
	coyield()
end

function dispatch_wakeup()
	while true do
		local co = tremove(wakeup_task_queue, 1)
		if not co then
			return
		end
		local param = wakeup_task_param[co]
		wakeup_task_param[co] = nil
		task_resume(co, param)
	end
end

function core.fork(func)
	local t = task_create(func)
	task_status[t] = "READY"
	wakeup_task_queue[#wakeup_task_queue + 1] = t
	return t
end

function core.wait()
	local t = task_running
	local status = task_status[t]
	assert(status == "RUN", status)
	return task_yield("WAIT")
end

function core.wait2()
	local res = core.wait()
	if not res then
		return
	end
	return tunpack(res, 1, res.n)
end

function core.wakeup(t, res)
	local status = task_status[t]
	assert(status == "WAIT", status)
	task_status[t] = "READY"
	wakeup_task_param[t] = res
	wakeup_task_queue[#wakeup_task_queue + 1] = t
end

function core.wakeup2(t, ...)
	core.wakeup(t, tpack(...))
end

local timeout = c.timeout
local timercancel = c.timercancel
function core.sleep(ms)
	local t = task_running
	local status = task_status[t]
	assert(status == "RUN", status)
	local session = timeout(ms)
	sleep_session_task[session] = t
	task_yield("SLEEP")
end

function core.timeout(ms, func, ud)
	local userid
	if ud then
		userid = #timer_user_data + 1
		timer_user_data[userid] = ud
	end
	local session = timeout(ms, userid)
	sleep_session_task[session] = func
	return session
end

local function nop(s) end
function core.timercancel(session)
	local f = sleep_session_task[session]
	if f then
		assert(type(f) == "function")
		local ud = timercancel(session)
		if ud then
			if ud ~= 0 then
				timer_user_data[ud] = nil
			end
			sleep_session_task[session] = nil
		else
			sleep_session_task[session] = nop
		end
	end
end

function core.signal(sig, f)
	local s = assert(signal_map[sig], sig)
	local err = signal(s)
	assert(not err, err)
	local old = signal_dispatch[s]
	signal_dispatch[s] = f
	return old
end

function core.start(func)
	local t = task_create(func)
	task_resume(t)
	dispatch_wakeup()
end

function core.taskstat()
	return #copool, #wakeup_task_queue
end

function core.tasks()
	local tasks = {}
	for t, status in pairs(task_status) do
		tasks[t] = {
			traceback = traceback(t),
			status = status
		}
	end
	return tasks
end

--socket
local socket_dispatch = {}
local socket_connecting = {}

local ip_pattern = "%[-([0-9A-Fa-f:%.]*)%]-:([0-9a-zA-Z]+)$"

local tcp_listen = assert(c.tcp_listen)
local tcp_connect = assert(c.tcp_connect)
local udp_bind = assert(c.udp_bind)
local udp_connect = assert(c.udp_connect)
local socket_close = assert(c.close)
core.tcp_send = assert(c.tcp_send)
core.udp_send = assert(c.udp_send)
core.tcp_multicast = assert(c.tcp_multicast)
function core.tcp_listen(addr, dispatch, backlog)
	assert(addr)
	assert(dispatch)
	local ip, port = smatch(addr, ip_pattern)
	if ip == "" then
		ip = "0::0"
	end
	if not backlog then
		backlog = 256 --this constant come from linux kernel comment
	end
	local id = tcp_listen(ip, port, backlog);
	if id < 0 then
		local errno = -id
		log_error("[sys.core] listen", port, "error", errno)
		return nil, errno
	end
	socket_dispatch[id] = dispatch
	return id
end

function core.udp_bind(addr, dispatch)
	assert(addr)
	assert(dispatch)
	local ip, port = smatch(addr, ip_pattern)
	if ip == "" then
		ip = "0::0"
	end
	local id = udp_bind(ip, port);
	if id < 0 then
		log_error("[sys.core] udpbind", port, "error",  id)
		return nil
	end
	socket_dispatch[id] = dispatch
	return id

end

function core.tcp_connect(addr, dispatch, bind)
	assert(addr)
	assert(dispatch)
	local ip, port = smatch(addr, ip_pattern)
	assert(ip and port, addr)
	bind = bind or ":0"
	local bip, bport = smatch(bind, ip_pattern)
	assert(bip and bport)
	local fd = tcp_connect(ip, port, bip, bport)
	if fd < 0 then
		return nil
	end
	assert(socket_connecting[fd] == nil)
	socket_connecting[fd] = task_running
	local ok = core.wait()
	socket_connecting[fd] = nil
	if ok ~= true then
		return nil
	end
	socket_dispatch[fd] = assert(dispatch)
	return fd
end

function core.udp_connect(addr, dispatch, bind)
	assert(addr)
	assert(dispatch)
	local ip, port = smatch(addr, ip_pattern)
	assert(ip and port, addr)
	bind = bind or ":0"
	local bip, bport = smatch(bind, ip_pattern)
	assert(bip and bport)
	local fd = udp_connect(ip, port, bip, bport)
	if fd >= 0 then
		socket_dispatch[fd] = dispatch
		return fd
	else
		return nil
	end
end

function core.socket_close(fd)
	local sc = socket_dispatch[fd]
	if sc == nil then
		return false
	end
	socket_dispatch[fd] = nil
	assert(socket_connecting[fd] == nil)
	socket_close(fd)
end

--the message handler can't be yield
local MSG = {
[1] = function(session, userid)				--SILLY_TEXPIRE = 1
	local t = sleep_session_task[session]
	if t then
		sleep_session_task[session] = nil
		if type(t) == "function" then
			t = task_create(t)
		end
		local ud
		if userid == 0 then --has no user data
			ud = session
		else
			ud = timer_user_data[userid]
			timer_user_data[userid] = nil
		end
		task_resume(t, ud)
	end
end,
[2] = function(fd, _, portid, addr)			--SILLY_SACCEPT = 2
	assert(socket_dispatch[fd] == nil)
	assert(socket_connecting[fd] == nil)
	local cb = socket_dispatch[portid]
	assert(cb, portid)
	socket_dispatch[fd] = cb
	local t = task_create(cb)
	task_resume(t, "accept", fd, _, portid,addr)
end,
[3] = function(fd, _, errno)				--SILLY_SCLOSE = 3
	local t = socket_connecting[fd]
	if t then	--connect fail
		core.wakeup(t, false)
		return
	end
	local f = socket_dispatch[fd]
	if f then	--is connected
		socket_dispatch[fd] = nil
		local t = task_create(f)
		task_resume(t, "close", fd, _, errno)
	end
end,
[4] = function(fd)					--SILLY_SCONNECTED = 4
	local t = socket_connecting[fd]
	if t == nil then	--have already closed
		assert(socket_dispatch[fd] == nil)
		return
	end
	task_resume(t, true)
end,
[5] = function(fd, msg)					--SILLY_SDATA = 5
	local f = socket_dispatch[fd]
	if f then
		local t = task_create(f)
		task_resume(t, "data", fd, msg)
	else
		log_info("[sys.core] SILLY_SDATA fd:", fd, "closed")
	end
end,
[6] = function(fd, msg, addr)				--SILLY_UDP = 6
	local f = socket_dispatch[fd]
	if f then
		local t = task_create(f)
		task_resume(t, "udp", fd, msg, addr)
	else
		log_info("[sys.core] SILLY_UDP fd:", fd, "closed")
	end
end,
[7] = function(signum)				--SILLY_ERROR = 7
	local fn = signal_dispatch[signum]
	if fn then
		local t = task_create(fn)
		task_resume(t, signal_map[signum])
		return
	end
	log_info("[sys.core] signal", signum, "received")
	core.exit(0)
end,
}

--fd, message, portid/errno, addr
local function dispatch(typ, fd, message, ...)
	--may run other coroutine here(like connected)
	MSG[typ](fd, message, ...)
	dispatch_wakeup()
end

c.dispatch(dispatch)

core.signal("SIGINT", function(_)
	core.exit(0)
end)

return core
