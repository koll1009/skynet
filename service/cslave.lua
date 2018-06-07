local skynet = require "skynet"
local socket = require "socket"
require "skynet.manager"	-- import skynet.launch, ...
local table = table

local slaves = {}
local connect_queue = {}
local globalname = {}
local queryname = {}
local harbor = {}
local harbor_service
local monitor = {}
local monitor_master_set = {}

--读包
local function read_package(fd)
	local sz = socket.read(fd, 1)--读一个字节的长度
	assert(sz, "closed")
	sz = string.byte(sz) --因为在pack_package的时候，把256以下的数字转成了一个char类型的字节，所以此处要拆解成长度
	local content = assert(socket.read(fd, sz), "closed") --读取socket message的内容
	return skynet.unpack(content) --拆包
end

--数据打包，组成socket消息包 为size+message
local function pack_package(...)
	local message = skynet.packstring(...)
	local size = #message --计算包的长度
	assert(size <= 255 , "too long")
	return string.char(size) .. message --组包
end

local function monitor_clear(id)
	local v = monitor[id]
	if v then
		monitor[id] = nil
		for _, v in ipairs(v) do
			v(true)
		end
	end
end

local function connect_slave(slave_id, address)
	local ok, err = pcall(function()
		if slaves[slave_id] == nil then
			local fd = assert(socket.open(address), "Can't connect to "..address)
			skynet.error(string.format("Connect to harbor %d (fd=%d), %s", slave_id, fd, address))
			slaves[slave_id] = fd
			monitor_clear(slave_id)
			socket.abandon(fd)
			skynet.send(harbor_service, "harbor", string.format("S %d %d",fd,slave_id))
		end
	end)
	if not ok then
		skynet.error(err)
	end
end

local function ready()
	local queue = connect_queue
	connect_queue = nil
	for k,v in pairs(queue) do
		connect_slave(k,v)
	end
	for name,address in pairs(globalname) do
		skynet.redirect(harbor_service, address, "harbor", 0, "N " .. name)
	end
end

--
local function response_name(name)
	local address = globalname[name] --取服务地址
	if queryname[name] then
		local tmp = queryname[name]
		queryname[name] = nil
		for _,resp in ipairs(tmp) do
			resp(true, address)
		end
	end
end

--监听master服务器的命令请求 
local function monitor_master(master_fd)
	while true do
		local ok, t, id_name, address = pcall(read_package,master_fd) --读取master服务器的数据，并unpack
		if ok then
			if t == 'C' then 
				if connect_queue then
					connect_queue[id_name] = address
				else
					connect_slave(id_name, address)
				end
			elseif t == 'N' then
				globalname[id_name] = address
				response_name(id_name)
				if connect_queue == nil then
					skynet.redirect(harbor_service, address, "harbor", 0, "N " .. id_name)
				end
			elseif t == 'D' then
				local fd = slaves[id_name]
				slaves[id_name] = false
				if fd then
					monitor_clear(id_name)
					socket.close(fd)
				end
			end
		else
			skynet.error("Master disconnect")
			for _, v in ipairs(monitor_master_set) do
				v(true)
			end
			socket.close(master_fd)
			break
		end
	end
end

local function accept_slave(fd)
	socket.start(fd)
	local id = socket.read(fd, 1)
	if not id then
		skynet.error(string.format("Connection (fd =%d) closed", fd))
		socket.close(fd)
		return
	end
	id = string.byte(id)
	if slaves[id] ~= nil then
		skynet.error(string.format("Slave %d exist (fd =%d)", id, fd))
		socket.close(fd)
		return
	end
	slaves[id] = fd
	monitor_clear(id)
	socket.abandon(fd)
	skynet.error(string.format("Harbor %d connected (fd = %d)", id, fd))
	skynet.send(harbor_service, "harbor", string.format("A %d %d", fd, id))
end

skynet.register_protocol {
	name = "harbor",
	id = skynet.PTYPE_HARBOR,
	pack = function(...) return ... end,
	unpack = skynet.tostring,
}

skynet.register_protocol {
	name = "text",
	id = skynet.PTYPE_TEXT,
	pack = function(...) return ... end,
	unpack = skynet.tostring,
}

local function monitor_harbor(master_fd)
	return function(session, source, command)
		local t = string.sub(command, 1, 1)
		local arg = string.sub(command, 3)
		if t == 'Q' then
			-- query name
			if globalname[arg] then
				skynet.redirect(harbor_service, globalname[arg], "harbor", 0, "N " .. arg)
			else
				socket.write(master_fd, pack_package("Q", arg))
			end
		elseif t == 'D' then
			-- harbor down
			local id = tonumber(arg)
			if slaves[id] then
				monitor_clear(id)
			end
			slaves[id] = false
		else
			skynet.error("Unknown command ", command)
		end
	end
end

--注册全局服务名的lua命令处理
function harbor.REGISTER(fd, name, handle)
	assert(globalname[name] == nil)
	globalname[name] = handle --先在服务中保存name-handle对
	response_name(name)
	socket.write(fd, pack_package("R", name, handle)) --通过tcp协议，发送内容
	skynet.redirect(harbor_service, handle, "harbor", 0, "N " .. name) --转到harbor服务
end

function harbor.LINK(fd, id)
	if slaves[id] then
		if monitor[id] == nil then
			monitor[id] = {}
		end
		table.insert(monitor[id], skynet.response())
	else
		skynet.ret()
	end
end

function harbor.LINKMASTER()
	table.insert(monitor_master_set, skynet.response())
end

function harbor.CONNECT(fd, id)
	if not slaves[id] then
		if monitor[id] == nil then
			monitor[id] = {}
		end
		table.insert(monitor[id], skynet.response())
	else
		skynet.ret()
	end
end

function harbor.QUERYNAME(fd, name)
	if name:byte() == 46 then	-- "." , local name
		skynet.ret(skynet.pack(skynet.localname(name)))
		return
	end
	local result = globalname[name]
	if result then
		skynet.ret(skynet.pack(result))
		return
	end
	local queue = queryname[name]
	if queue == nil then
		socket.write(fd, pack_package("Q", name))
		queue = { skynet.response() }
		queryname[name] = queue
	else
		table.insert(queue, skynet.response())
	end
end

skynet.start(function()
	local master_addr = skynet.getenv "master"  --取master主机地址
	local harbor_id = tonumber(skynet.getenv "harbor") --取harbor id
	local slave_address = assert(skynet.getenv "address") --取slave地址
	local slave_fd = socket.listen(slave_address) --监听
	skynet.error("slave connect to master " .. tostring(master_addr))
	local master_fd = assert(socket.open(master_addr), "Can't connect to master") --连接master主机

	--lua消息处理
	skynet.dispatch("lua", function (_,_,command,...)
		local f = assert(harbor[command]) --取命令
		f(master_fd, ...)
	end)

	--text消息处理
	skynet.dispatch("text", monitor_harbor(master_fd))

	--启动harbor服务，传入harborid，以及本服务号
	harbor_service = assert(skynet.launch("harbor", harbor_id, skynet.self()))

	local hs_message = pack_package("H", harbor_id, slave_address)--使用harborid:slave地址组一个socket message包
	socket.write(master_fd, hs_message)--发送给master主机
	local t, n = read_package(master_fd)--读取master主机的返回内容，并解析，返回W+一个数字(标识服务器数量)
	assert(t == "W" and type(n) == "number", "slave shakehand failed")
	skynet.error(string.format("Waiting for %d harbors", n))
	skynet.fork(monitor_master, master_fd) --使用独立协程执行monitor_master(master_fd)
	if n > 0 then
		local co = coroutine.running()
		socket.start(slave_fd, function(fd, addr)
			skynet.error(string.format("New connection (fd = %d, %s)",fd, addr))
			if pcall(accept_slave,fd) then
				local s = 0
				for k,v in pairs(slaves) do
					s = s + 1
				end
				if s >= n then
					skynet.wakeup(co)
				end
			end
		end)
		skynet.wait()
	end
	socket.close(slave_fd)
	skynet.error("Shakehand ready")
	skynet.fork(ready)
end)
