local skynet = require "skynet"
local core = require "skynet.core"
require "skynet.manager"	-- import manager apis
local string = string

local services = {}
local command = {}
local instance = {} -- for confirm (function command.LAUNCH / command.ERROR / command.LAUNCHOK)

local function handle_to_address(handle)
	return tonumber("0x" .. string.sub(handle , 2))
end

local NORET = {}

function command.LIST()
	local list = {}
	for k,v in pairs(services) do
		list[skynet.address(k)] = v
	end
	return list
end

function command.STAT()
	local list = {}
	for k,v in pairs(services) do
		local ok, stat = pcall(skynet.call,k,"debug","STAT")
		if not ok then
			stat = string.format("ERROR (%s)",v)
		end
		list[skynet.address(k)] = stat
	end
	return list
end

function command.KILL(_, handle)
	handle = handle_to_address(handle)
	skynet.kill(handle)
	local ret = { [skynet.address(handle)] = tostring(services[handle]) }
	services[handle] = nil
	return ret
end

function command.MEM()
	local list = {}
	for k,v in pairs(services) do
		local ok, kb, bytes = pcall(skynet.call,k,"debug","MEM")
		if not ok then
			list[skynet.address(k)] = string.format("ERROR (%s)",v)
		else
			list[skynet.address(k)] = string.format("%.2f Kb (%s)",kb,v)
		end
	end
	return list
end

function command.GC()
	for k,v in pairs(services) do
		skynet.send(k,"debug","GC")
	end
	return command.MEM()
end

function command.REMOVE(_, handle, kill)
	services[handle] = nil
	local response = instance[handle]
	if response then
		-- instance is dead
		response(not kill)	-- return nil to caller of newservice, when kill == false
		instance[handle] = nil
	end

	-- don't return (skynet.ret) because the handle may exit
	return NORET
end

--启动lua服务
local function launch_service(service, ...)
	local param = table.concat({...}, " ") 
	local inst = skynet.launch(service, param) --service为服务名，例如cmaster ，param为参数
	local response = skynet.response()         --再次调用coroutine_resume传入的参数为返回值  
	                                           --中断协程，调用coroutine_resume返回true、"RESPONSE"、skynet.pack函数	                                    
	if inst then
		services[inst] = service .. " " .. param  --保存启动的服务信息
		instance[inst] = response
	else
		response(false)
		return
	end
	return inst   --返回新服务的handle值                    
end

--启动命令
function command.LAUNCH(_, service, ...)
	launch_service(service, ...) --启动lua服务,service为服务名
	return NORET
end

function command.LOGLAUNCH(_, service, ...)
	local inst = launch_service(service, ...)
	if inst then
		core.command("LOGON", skynet.address(inst))
	end
	return NORET
end

function command.ERROR(address)
	-- see serivce-src/service_lua.c
	-- init failed
	local response = instance[address]
	if response then
		response(false)
		instance[address] = nil
	end
	services[address] = nil
	return NORET
end

function command.LAUNCHOK(address)
	-- init notice
	local response = instance[address]
	if response then
		response(true, address)
		instance[address] = nil
	end

	return NORET
end

-- for historical reasons, launcher support text command (for C service)

--注册proto.text协议
skynet.register_protocol {
	name = "text",
	id = skynet.PTYPE_TEXT,
	unpack = skynet.tostring,
	dispatch = function(session, address , cmd)
		if cmd == "" then
			command.LAUNCHOK(address)
		elseif cmd == "ERROR" then
			command.ERROR(address)
		else
			error ("Invalid text command " .. cmd)
		end
	end,
}

--重置proto.lua的dispatch函数,变参为拆包后的消息数据
skynet.dispatch("lua", function(session, address, cmd , ...)
	cmd = string.upper(cmd)
	local f = command[cmd] --根据命令字符串，指向相应的函数
	if f then
		local ret = f(address, ...) --执行命令
		if ret ~= NORET then
			skynet.ret(skynet.pack(ret)) --序列化handle值，返回
		end
	else
		skynet.ret(skynet.pack {"Unknown command"} )
	end
end)

skynet.start(function() end)--压入一条空消息，
