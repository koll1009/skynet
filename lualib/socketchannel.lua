local skynet = require "skynet"
local socket = require "socket"
local socketdriver = require "socketdriver"

-- channel support auto reconnect , and capture socket error in request/response transaction
-- { host = "", port = , auth = function(so) , response = function(so) session, data }

local socket_channel = {}
local channel = {}
local channel_socket = {}
local channel_meta = { __index = channel }
local channel_socket_meta = {
	__index = channel_socket,
	__gc = function(cs)
		local fd = cs[1]
		cs[1] = false
		if fd then
			socket.shutdown(fd)
		end
	end
}

local socket_error = setmetatable({}, {__tostring = function() return "[Error: socket]" end })	-- alias for error object
socket_channel.error = socket_error

--创建一个channel表，初始化了状态
function socket_channel.channel(desc)
	local c = {
		__host = assert(desc.host),--ip
		__port = assert(desc.port),--port
		__backup = desc.backup,
		__auth = desc.auth,        --autn函数
		__response = desc.response,	-- It's for session mode
		__request = {},	-- request seq { response func or session }	-- It's for order mode
		__thread = {}, -- coroutine seq or session->coroutine map
		__result = {}, -- response result { coroutine -> result }
		__result_data = {},
		__connecting = {},
		__sock = false,
		__closed = false,
		__authcoroutine = false,
		__nodelay = desc.nodelay,
	}

	return setmetatable(c, channel_meta) --返回table c
end

local function close_channel_socket(self)
	if self.__sock then
		local so = self.__sock
		self.__sock = false
		-- never raise error
		pcall(socket.close,so[1])
	end
end

local function wakeup_all(self, errmsg)
	if self.__response then
		for k,co in pairs(self.__thread) do
			self.__thread[k] = nil
			self.__result[co] = socket_error
			self.__result_data[co] = errmsg
			skynet.wakeup(co)
		end
	else
		for i = 1, #self.__request do
			self.__request[i] = nil
		end
		for i = 1, #self.__thread do
			local co = self.__thread[i]
			self.__thread[i] = nil
			if co then	-- ignore the close signal
				self.__result[co] = socket_error
				self.__result_data[co] = errmsg
				skynet.wakeup(co)
			end
		end
	end
end

local function exit_thread(self)
	local co = coroutine.running()
	if self.__dispatch_thread == co then
		self.__dispatch_thread = nil
		local connecting = self.__connecting_thread
		if connecting then
			skynet.wakeup(connecting)
		end
	end
end

local function dispatch_by_session(self)
	local response = self.__response
	-- response() return session
	while self.__sock do
		local ok , session, result_ok, result_data, padding = pcall(response, self.__sock)
		if ok and session then
			local co = self.__thread[session]
			if co then
				if padding and result_ok then
					-- If padding is true, append result_data to a table (self.__result_data[co])
					local result = self.__result_data[co] or {}
					self.__result_data[co] = result
					table.insert(result, result_data)
				else
					self.__thread[session] = nil
					self.__result[co] = result_ok
					if result_ok and self.__result_data[co] then
						table.insert(self.__result_data[co], result_data)
					else
						self.__result_data[co] = result_data
					end
					skynet.wakeup(co)
				end
			else
				self.__thread[session] = nil
				skynet.error("socket: unknown session :", session)
			end
		else
			close_channel_socket(self)
			local errormsg
			if session ~= socket_error then
				errormsg = session
			end
			wakeup_all(self, errormsg)
		end
	end
	exit_thread(self)
end

local function pop_response(self)
	while true do
		local func,co = table.remove(self.__request, 1), table.remove(self.__thread, 1)
		if func then
			return func, co
		end
		self.__wait_response = coroutine.running()
		skynet.wait(self.__wait_response)
	end
end

--保存响应回调函数
local function push_response(self, response, co)
	if self.__response then
		-- response is session
		self.__thread[response] = co
	else
		-- response is a function, push it to __request
		table.insert(self.__request, response)
		table.insert(self.__thread, co)
		if self.__wait_response then
			skynet.wakeup(self.__wait_response)
			self.__wait_response = nil
		end
	end
end

--按序调度响应
local function dispatch_by_order(self)
	while self.__sock do
		local func, co = pop_response(self)
		if not co then
			-- close signal
			wakeup_all(self, errmsg)
			break
		end
		local ok, result_ok, result_data, padding = pcall(func, self.__sock)
		if ok then
			if padding and result_ok then
				-- if padding is true, wait for next result_data
				-- self.__result_data[co] is a table
				local result = self.__result_data[co] or {}
				self.__result_data[co] = result
				table.insert(result, result_data)
			else
				self.__result[co] = result_ok
				if result_ok and self.__result_data[co] then
					table.insert(self.__result_data[co], result_data)
				else
					self.__result_data[co] = result_data
				end
				skynet.wakeup(co)--唤醒
			end
		else
			close_channel_socket(self)
			local errmsg
			if result_ok ~= socket_error then
				errmsg = result_ok
			end
			self.__result[co] = socket_error
			self.__result_data[co] = errmsg
			skynet.wakeup(co)
			wakeup_all(self, errmsg)
		end
	end
	exit_thread(self)
end

--取调度函数
local function dispatch_function(self)
	if self.__response then
		return dispatch_by_session
	else
		return dispatch_by_order
	end
end

local function connect_backup(self)
	if self.__backup then
		for _, addr in ipairs(self.__backup) do
			local host, port
			if type(addr) == "table" then
				host, port = addr.host, addr.port
			else
				host = addr
				port = self.__port
			end
			skynet.error("socket: connect to backup host", host, port)
			local fd = socket.open(host, port)
			if fd then
				self.__host = host
				self.__port = port
				return fd
			end
		end
	end
end

--实际连接操作，只连接一次
local function connect_once(self)
	if self.__closed then --状态检查
		return false
	end
	assert(not self.__sock and not self.__authcoroutine)
	local fd,err = socket.open(self.__host, self.__port) --连接，并返回sock id
	if not fd then
		fd = connect_backup(self)
		if not fd then
			return false, err
		end
	end
	if self.__nodelay then --设置nodelay option
		socketdriver.nodelay(fd)
	end

	--连接成功，设置_sock
	self.__sock = setmetatable( {fd} , channel_socket_meta )

	--新fork一个协程执行response函数（此处为dispatch_by_order（self）），并保存协程
	self.__dispatch_thread = skynet.fork(dispatch_function(self), self)

	--有认证函数
	if self.__auth then
		self.__authcoroutine = coroutine.running() --保存认证协程
		--执行认证操作
		local ok , message = pcall(self.__auth, self) --mysql中__auth指向_mysql_login的返回函数
		if not ok then
			close_channel_socket(self)
			if message ~= socket_error then
				self.__authcoroutine = false
				skynet.error("socket: auth failed", message)
			end
		end
		self.__authcoroutine = false
		if ok and not self.__sock then
			-- auth may change host, so connect again
			return connect_once(self)
		end
		return ok
	end

	return true
end

local function try_connect(self , once)
	local t = 0
	while not self.__closed do
		local ok, err = connect_once(self) --连接一次
		if ok then
			if not once then
				skynet.error("socket: connect to", self.__host, self.__port)
			end
			return
		elseif once then
			return err
		else
			skynet.error("socket: connect", err)
		end
		if t > 1000 then
			skynet.error("socket: try to reconnect", self.__host, self.__port)
			skynet.sleep(t)
			t = 0
		else
			skynet.sleep(t)
		end
		t = t + 100
	end
end

--检查连接状态 
local function check_connection(self)
	if self.__sock then --__sock字段已赋值，表示已经连接
		local authco = self.__authcoroutine 
		if not authco then --不需要认证，返回true
			return true
		end
		if authco == coroutine.running() then --正在认证，返回true
			-- authing
			return true
		end
	end
	if self.__closed then --
		return false
	end
	--默认返回nil，表示尚未连接
end

--阻塞式连接函数，@once为true表示只连接一次，返回是否成功
local function block_connect(self, once)
	local r = check_connection(self) --检查连接状态
	if r ~= nil then --已连接，true表示连接成功或者正在认证，false表示已关闭
		return r
	end
	local err

	if #self.__connecting > 0 then --其他协程已经发起连接操作
		-- connecting in other coroutine
		local co = coroutine.running() 
		table.insert(self.__connecting, co) --把当前协程保存，并睡眠
		skynet.wait(co) 
	else
		self.__connecting[1] = true --有一个连接
		err = try_connect(self, once)--实际的连接操作
		self.__connecting[1] = nil
		for i=2, #self.__connecting do
			local co = self.__connecting[i]
			self.__connecting[i] = nil
			skynet.wakeup(co)
		end
	end

	r = check_connection(self)
	if r == nil then
		skynet.error(string.format("Connect to %s:%d failed (%s)", self.__host, self.__port, err))
		error(socket_error)
	else
		return r
	end
end

--连接方法，@once标记是否只连接一次，self为socketchannel:channel方法的返回值
function channel:connect(once)
	if self.__closed then  --__closed初始状态为false
		if self.__dispatch_thread then
			-- closing, wait
			assert(self.__connecting_thread == nil, "already connecting")
			local co = coroutine.running()
			self.__connecting_thread = co
			skynet.wait(co)
			self.__connecting_thread = nil
		end
		self.__closed = false
	end

	return block_connect(self, once)--阻塞性连接
end

--等待响应
local function wait_for_response(self, response)
	local co = coroutine.running()
	push_response(self, response, co)--把响应函数和协程保存起来，执行睡眠
	skynet.wait(co) --当fork的协程执行完dispatch_by_order后唤醒

	--读取响应的数据，并返回
	local result = self.__result[co]
	self.__result[co] = nil
	local result_data = self.__result_data[co]
	self.__result_data[co] = nil

	if result == socket_error then
		if result_data then
			error(result_data)
		else
			error(socket_error)
		end
	else
		assert(result, result_data)
		return result_data
	end
end

local socket_write = socket.write
local socket_lwrite = socket.lwrite

function channel:request(request, response, padding)
	assert(block_connect(self, true))	-- connect once
	local fd = self.__sock[1]

	if padding then
		-- padding may be a table, to support multi part request
		-- multi part request use low priority socket write
		-- socket_lwrite returns nothing
		socket_lwrite(fd , request)
		for _,v in ipairs(padding) do
			socket_lwrite(fd, v)
		end
	else
		if not socket_write(fd , request) then
			close_channel_socket(self)
			wakeup_all(self)
			error(socket_error)
		end
	end

	if response == nil then
		-- no response
		return
	end

	return wait_for_response(self, response)
end

--异步响应，@response为回调的响应函数
function channel:response(response)
	assert(block_connect(self)) --确保已连接

	return wait_for_response(self, response)
end

function channel:close()
	if not self.__closed then
		local thread = self.__dispatch_thread
		self.__closed = true
		close_channel_socket(self)
		if not self.__response and self.__dispatch_thread == thread and thread then
			-- dispatch by order, send close signal to dispatch thread
			push_response(self, true, false)	-- (true, false) is close signal
		end
	end
end

function channel:changehost(host, port)
	self.__host = host
	if port then
		self.__port = port
	end
	if not self.__closed then
		close_channel_socket(self)
	end
end

function channel:changebackup(backup)
	self.__backup = backup
end

channel_meta.__gc = channel.close

local function wrapper_socket_function(f)
	return function(self, ...)
		local result = f(self[1], ...)
		if not result then
			error(socket_error)
		else
			return result
		end
	end
end

channel_socket.read = wrapper_socket_function(socket.read)
channel_socket.readline = wrapper_socket_function(socket.readline)

return socket_channel
