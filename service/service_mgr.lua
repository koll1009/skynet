local skynet = require "skynet"

local cmd = {}
local service = {}


function cmd.LAUNCH(service_name, ...)
	local s = service[service_name]
	if type(s) == "number" then
		return s
	end

	if s == nil then --保存服务
		s = { launch = true }
		service[service_name] = s
	elseif s.launch then --已保存的服务
		assert(type(s) == "table")
		local co = coroutine.running()
		table.insert(s, co)
		skynet.wait()
		s = service[service_name]
		assert(type(s) == "number")
		return s
	end

	local handle = skynet.newservice(service_name, ...) --启动服务
	for _,v in ipairs(s) do --当服务在处理一个启动请求未结束时，又接收到了另外一个启动请求，则在消息处理时执行等待
		skynet.wakeup(v)
	end

	service[service_name] = handle

	return handle
end

function cmd.QUERY(service_name)
	local s = service[service_name]
	if type(s) == "number" then
		return s
	end
	if s == nil then
		s = {}
		service[service_name] = s
	end
	assert(type(s) == "table")
	local co = coroutine.running()
	table.insert(s, co)
	skynet.wait()
	s = service[service_name]
	assert(type(s) == "number")
	return s
end

--启动service_mgr服务
skynet.start(function()
    -- 设置服务的PTYPE_RESERVED_LUA（10）消息的处理函数
	skynet.dispatch("lua", function(session, address, command, service_name , ...)
		local f = cmd[command] --命令处理函数
		if f == nil then
			skynet.ret(skynet.pack(nil))
			return
		end

		local ok, r = pcall(f, service_name, ...) --调用命令函数，服务名为参数
		if ok then
			skynet.ret(skynet.pack(r))
		else
			skynet.ret(skynet.pack(nil))
		end
	end)
	skynet.register(".service") --把服务命名为.service
	if skynet.getenv "standalone" then
		skynet.register("SERVICE") --如果是master服务器，也命名为SERVICE
	end
end)
