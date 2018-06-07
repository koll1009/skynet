local skynet = require "skynet"
local c = require "skynet.core"

--启动lua服务，返回handle值
function skynet.launch(...)
    --c.command("LAUNCH","snlua lua服务名")，返回:+handle值字符串
	local addr = c.command("LAUNCH", table.concat({...}," ")) 
	if addr then
		return tonumber("0x" .. string.sub(addr , 2))
	end
end

function skynet.kill(name)
	if type(name) == "number" then
		skynet.send(".launcher","lua","REMOVE",name, true)
		name = skynet.address(name)
	end
	c.command("KILL",name)
end

function skynet.abort()
	c.command("ABORT")
end

--检查@name是否为全服服务名
local function globalname(name, handle)
	local c = string.sub(name,1,1) --取第一个字符
	assert(c ~= ':') 
	if c == '.' then   --第一个字符为'.'，表示为local name
		return false
	end

	assert(#name <= 16)	-- GLOBALNAME_LENGTH is 16, defined in skynet_harbor.h
	assert(tonumber(name) == nil)	-- global name can't be number

	--调用skynet.harbor.globalname注册全服服务名
	local harbor = require "skynet.harbor"

	harbor.globalname(name, handle)

	return true
end

--注册服务名name
function skynet.register(name)
	if not globalname(name) then --首先验证是否为全服服务名
		c.command("REG", name)--调用reg cmd注册
	end
end

--给服务命名
function skynet.name(name, handle)
	if not globalname(name, handle) then
		c.command("NAME", name .. " " .. skynet.address(handle)) --
	end
end

local dispatch_message = skynet.dispatch_message

function skynet.forward_type(map, start_func)
	c.callback(function(ptype, msg, sz, ...)
		local prototype = map[ptype]
		if prototype then
			dispatch_message(prototype, msg, sz, ...)
		else
			dispatch_message(ptype, msg, sz, ...)
			c.trash(msg, sz)
		end
	end, true)
	skynet.timeout(0, function()
		skynet.init_service(start_func)
	end)
end

function skynet.filter(f ,start_func)
	c.callback(function(...)
		dispatch_message(f(...))
	end)
	skynet.timeout(0, function()
		skynet.init_service(start_func)
	end)
end

function skynet.monitor(service, query)
	local monitor
	if query then
		monitor = skynet.queryservice(true, service)
	else
		monitor = skynet.uniqueservice(true, service)
	end
	assert(monitor, "Monitor launch failed")
	c.command("MONITOR", string.format(":%08x", monitor))
	return monitor
end

return skynet
