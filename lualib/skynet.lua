local c = require "skynet.core" --����
local tostring = tostring
local tonumber = tonumber
local coroutine = coroutine
local assert = assert
local pairs = pairs
local pcall = pcall

local profile = require "profile"

local coroutine_resume = profile.resume
local coroutine_yield = profile.yield

local proto = {}
local skynet = {
	-- read skynet.h
	PTYPE_TEXT = 0,
	PTYPE_RESPONSE = 1,--响应类型的消息，当向一个服务发送请求内容并等待响应结果时使用
	PTYPE_MULTICAST = 2,
	PTYPE_CLIENT = 3,
	PTYPE_SYSTEM = 4,
	PTYPE_HARBOR = 5,
	PTYPE_SOCKET = 6,
	PTYPE_ERROR = 7,
	PTYPE_QUEUE = 8,	-- used in deprecated mqueue, use skynet.queue instead
	PTYPE_DEBUG = 9,
	PTYPE_LUA = 10,
	PTYPE_SNAX = 11,
}

-- code cache
skynet.cache = require "skynet.codecache"

--注册消息处理原型，保存在proto表中
function skynet.register_protocol(class)
	local name = class.name --消息类型名
	local id = class.id     --消息类型标识
	assert(proto[name] == nil)
	assert(type(name) == "string" and type(id) == "number" and id >=0 and id <=255)
	proto[name] = class
	proto[id] = class
end

local session_id_coroutine = {}
local session_coroutine_id = {}      --ƥ��Э����session
local session_coroutine_address = {} --ƥ��Э����handle
local session_response = {}
local unresponse = {}

local wakeup_session = {}
local sleep_session = {}

local watching_service = {}
local watching_session = {}
local dead_service = {}
local error_queue = {}
local fork_queue = {}

-- suspend is function
local suspend

--把字符串转换成int类型的handle值
local function string_to_handle(str)
	return tonumber("0x" .. string.sub(str , 2))
end

----- monitor exit

local function dispatch_error_queue()
	local session = table.remove(error_queue,1)
	if session then
		local co = session_id_coroutine[session]
		session_id_coroutine[session] = nil
		return suspend(co, coroutine_resume(co, false))
	end
end

local function _error_dispatch(error_session, error_source)
	if error_session == 0 then
		-- service is down
		--  Don't remove from watching_service , because user may call dead service
		if watching_service[error_source] then
			dead_service[error_source] = true
		end
		for session, srv in pairs(watching_session) do
			if srv == error_source then
				table.insert(error_queue, session)
			end
		end
	else
		-- capture an error for error_session
		if watching_session[error_session] then
			table.insert(error_queue, error_session)
		end
	end
end

-- coroutine reuse

local coroutine_pool = setmetatable({}, { __mode = "kv" })


--创建一个协程，执行函数f，协程可以重复利用，使用table coroutine_pool存储空闲的协程
local function co_create(f)
	local co = table.remove(coroutine_pool)--取一个free lua thread
	if co == nil then
	    --没有空闲的则新创建一个
		co = coroutine.create(function(...)
			f(...) --执行协程函数f，执行完毕后，把协程保存到table coroutine_pool中
			while true do
				f = nil 
				coroutine_pool[#coroutine_pool+1] = co --保存协程co
				f = coroutine_yield "EXIT"             --向主协程返回“EXIT” ，主协程会在suspend函数里处理
				f(coroutine_yield())                   -- 先把协程co挂起，然后把f函数的参数通过resume传入
			end
		end)
	else
		--有空闲的协程，则通过coroutine.resume把要执行的函数以参数的形式传递给协程co，此时协程co正挂起在
		--语句f=coroutine_yield "EXIT"处
		coroutine_resume(co, f)                        
	end
	return co
end


local function dispatch_wakeup()
	local co = next(wakeup_session) --ȡwakeup_session�ĵ�һ����nilֵ
	if co then
		wakeup_session[co] = nil
		local session = sleep_session[co]
		if session then
			session_id_coroutine[session] = "BREAK"
			return suspend(co, coroutine_resume(co, false, "BREAK"))
		end
	end
end

local function release_watching(address)
	local ref = watching_service[address]
	if ref then
		ref = ref - 1
		if ref > 0 then
			watching_service[address] = ref
		else
			watching_service[address] = nil
		end
	end
end

-- suspend is local function 
--co:执行挂起的协程 result
function suspend(co, result, command, param, size)
	if not result then                         --Э�����г���
		local session = session_coroutine_id[co]
		if session then -- coroutine may fork by others (session is nil)
			local addr = session_coroutine_address[co]
			if session ~= 0 then
				-- only call response error
				c.send(addr, skynet.PTYPE_ERROR, session, "")
			end
			session_coroutine_id[co] = nil
			session_coroutine_address[co] = nil
		end
		error(debug.traceback(co,tostring(command)))
	end
	if command == "CALL" then                 --"CALL"命令，param此时为session id，暂存该协程，等到消息相应执行回调
		session_id_coroutine[param] = co  
	elseif command == "SLEEP" then            --"SLEEP"������±���Э��paramΪsessionֵ
		session_id_coroutine[param] = co
		sleep_session[co] = param

	elseif command == "RETURN" then           --"RETURN" command,向协程co处理的消息的发送方返回数据
		local co_session = session_coroutine_id[co] --消息的session和source handle
		local co_address = session_coroutine_address[co]
		if param == nil or session_response[co] then
			error(debug.traceback(co))
		end
		session_response[co] = true
		local ret
		if not dead_service[co_address] then
			--发送消息，返回数据
			ret = c.send(co_address, skynet.PTYPE_RESPONSE, co_session, param, size) ~= nil
			if not ret then
				-- If the package is too large, returns nil. so we should report error back
				c.send(co_address, skynet.PTYPE_ERROR, co_session, "")
			end
		elseif size ~= nil then
			c.trash(param, size)
			ret = false
		end
		return suspend(co, coroutine_resume(co, ret))
	elseif command == "RESPONSE" then                   --response command
		local co_session = session_coroutine_id[co]     --ȡsession
		local co_address = session_coroutine_address[co]--ȡsource handle
		if session_response[co] then
			error(debug.traceback(co))
		end
		local f = param                                 --paramΪpack����
		local function response(ok, ...)
			if ok == "TEST" then
				if dead_service[co_address] then
					release_watching(co_address)
					unresponse[response] = nil
					f = false
					return false
				else
					return true
				end
			end
			if not f then
				if f == false then
					f = nil
					return false
				end
				error "Can't response more than once"
			end

			local ret
			if not dead_service[co_address] then
				if ok then
					ret = c.send(co_address, skynet.PTYPE_RESPONSE, co_session, f(...)) ~= nil
					if not ret then
						-- If the package is too large, returns false. so we should report error back
						c.send(co_address, skynet.PTYPE_ERROR, co_session, "")
					end
				else
					ret = c.send(co_address, skynet.PTYPE_ERROR, co_session, "") ~= nil
				end
			else
				ret = false
			end
			release_watching(co_address)
			unresponse[response] = nil
			f = nil
			return ret
		end
		watching_service[co_address] = watching_service[co_address] + 1
		session_response[co] = true
		unresponse[response] = true
		return suspend(co, coroutine_resume(co, response))--
	elseif command == "EXIT" then             --EXIT����            
		-- coroutine exit
		local address = session_coroutine_address[co]
		release_watching(address)
		session_coroutine_id[co] = nil
		session_coroutine_address[co] = nil
		session_response[co] = nil
	elseif command == "QUIT" then
		-- service exit
		return
	elseif command == "USER" then
		-- See skynet.coutine for detail
		error("Call skynet.coroutine.yield out of skynet.coroutine.resume\n" .. debug.traceback(co))
	elseif command == nil then
		-- debug trace
		return
	else
		error("Unknown command : " .. command .. "\n" .. debug.traceback(co))
	end
	dispatch_wakeup()
	dispatch_error_queue()
end

--定时器函数,时间ti到期后，会执行func
function skynet.timeout(ti, func)
	--先调用skynet.core.intcommand函数往定时器中插入一个节点，到期后，定时器线程会向本服务发送一条
	--PTYPE_RESPONSE类型的消息
	local session = c.intcommand("TIMEOUT",ti)  
	assert(session)
	local co = co_create(func)                  
	assert(session_id_coroutine[session] == nil)
	session_id_coroutine[session] = co          --把要执行函数func的协程保存在session-coroutine表中，当定时器消息返回时，用session进行识别
end

function skynet.sleep(ti)
	local session = c.intcommand("TIMEOUT",ti)
	assert(session)
	local succ, ret = coroutine_yield("SLEEP", session)
	sleep_session[coroutine.running()] = nil
	if succ then
		return
	end
	if ret == "BREAK" then
		return "BREAK"
	else
		error(ret)
	end
end

function skynet.yield()
	return skynet.sleep(0)
end

--Э��cou����
function skynet.wait(co)
	local session = c.genid()  --����һ��sessionֵ
	local ret, msg = coroutine_yield("SLEEP", session) --�ó�ִ��
	co = co or coroutine.running()
	sleep_session[co] = nil
	session_id_coroutine[session] = nil
end

local self_handle
function skynet.self()
	if self_handle then
		return self_handle
	end
	self_handle = string_to_handle(c.command("REG"))
	return self_handle
end

--查询名为name的服务，有则query cmd返回的addr为16进制字符形式，先转换成handle值再返回
function skynet.localname(name)
	local addr = c.command("QUERY", name)--查询名为name的服务是否已启动
	if addr then
		return string_to_handle(addr)
	end
end

skynet.now = c.now

local starttime

function skynet.starttime()
	if not starttime then
		starttime = c.intcommand("STARTTIME")
	end
	return starttime
end

function skynet.time()
	return skynet.now()/100 + (starttime or skynet.starttime())
end

function skynet.exit()
	fork_queue = {}	-- no fork coroutine can be execute after skynet.exit
	skynet.send(".launcher","lua","REMOVE",skynet.self(), false)
	-- report the sources that call me
	for co, session in pairs(session_coroutine_id) do
		local address = session_coroutine_address[co]
		if session~=0 and address then
			c.redirect(address, 0, skynet.PTYPE_ERROR, session, "")
		end
	end
	for resp in pairs(unresponse) do
		resp(false)
	end
	-- report the sources I call but haven't return
	local tmp = {}
	for session, address in pairs(watching_session) do
		tmp[address] = true
	end
	for address in pairs(tmp) do
		c.redirect(address, 0, skynet.PTYPE_ERROR, 0, "")
	end
	c.command("EXIT")
	-- quit service
	coroutine_yield "QUIT"
end

--取环境变量
function skynet.getenv(key)
	return (c.command("GETENV",key))
end

--设置环境变量
function skynet.setenv(key, value)
	c.command("SETENV",key .. " " ..value)
end

--向服务@addr发送消息
function skynet.send(addr, typename, ...)
	local p = proto[typename]
	return c.send(addr, p.id, 0 , p.pack(...))
end

skynet.genid = assert(c.genid)

skynet.redirect = function(dest,source,typename,...)
	return c.redirect(dest, source, proto[typename].id, ...)
end

skynet.pack = assert(c.pack)
skynet.packstring = assert(c.packstring)
skynet.unpack = assert(c.unpack)
skynet.tostring = assert(c.tostring)
skynet.trash = assert(c.trash)

--挂起协程，向主协程返回"CALL" cmd，等到响应
local function yield_call(service, session)
	watching_session[session] = service  --���Ϊsession����Ϣ�����͵���service�����ȴ�service����Ӧ
	local succ, msg, sz = coroutine_yield("CALL", session) --profile.yield���ж�Э�̣�����true��"CALL"��session
	watching_session[session] = nil
	if not succ then
		error "call failed"
	end
	return msg,sz
end

--向服务addr发送一条消息，typename为消息类型，变参为数据
function skynet.call(addr, typename, ...)
	local p = proto[typename]
	local session = c.send(addr, p.id , nil , p.pack(...))  --向服务addr发送p.id类型的消息，需要数据序列化
	if session == nil then
		error("call to invalid address " .. skynet.address(addr))
	end
	return p.unpack(yield_call(addr, session))
end

function skynet.rawcall(addr, typename, msg, sz)
	local p = proto[typename]
	local session = assert(c.send(addr, p.id , nil , msg, sz), "call to invalid address")
	return yield_call(addr, session)
end

--返回“RETURN”命令到主协程，并且返回数据msg、sz
function skynet.ret(msg, sz)
	msg = msg or ""
	return coroutine_yield("RETURN", msg, sz)
end

--返回响应的处理函数以及序列化函数
function skynet.response(pack)
	pack = pack or skynet.pack
	return coroutine_yield("RESPONSE", pack)
end

function skynet.retpack(...)
	return skynet.ret(skynet.pack(...))
end

function skynet.wakeup(co)
	if sleep_session[co] and wakeup_session[co] == nil then
		wakeup_session[co] = true
		return true
	end
end


--设置消息类型typename的处理函数
function skynet.dispatch(typename, func)
	local p = proto[typename]
	if func then
		local ret = p.dispatch
		p.dispatch = func
		return ret   --设置dispatch函数，并返回old one
	else
		return p and p.dispatch
	end
end

local function unknown_request(session, address, msg, sz, prototype)
	skynet.error(string.format("Unknown request (%s): %s", prototype, c.tostring(msg,sz)))
	error(string.format("Unknown session : %d from %x", session, address))
end

function skynet.dispatch_unknown_request(unknown)
	local prev = unknown_request
	unknown_request = unknown
	return prev
end

local function unknown_response(session, address, msg, sz)
	skynet.error(string.format("Response message : %s" , c.tostring(msg,sz)))
	error(string.format("Unknown session : %d from %x", session, address))
end

function skynet.dispatch_unknown_response(unknown)
	local prev = unknown_response
	unknown_response = unknown
	return prev
end

--使用独立的协程执行func
function skynet.fork(func,...)
	local args = table.pack(...)
	local co = co_create(function()
		func(table.unpack(args,1,args.n))
	end)
	table.insert(fork_queue, co)
	return co
end

--参数依次为@1消息type @2:msg指针 @3:msg‘s length @4：session @5：source handle
local function raw_dispatch_message(prototype, msg, sz, session, source)
	-- skynet.PTYPE_RESPONSE = 1, read skynet.h
	if prototype == 1 then--PTYPE_RESPONSE类型消息的处理
		local co = session_id_coroutine[session] --
		if co == "BREAK" then
			session_id_coroutine[session] = nil
		elseif co == nil then
			unknown_response(session, source, msg, sz)
		else
			session_id_coroutine[session] = nil 
			suspend(co, coroutine_resume(co, true, msg, sz)) -- coroutine_resume����true "CALL" session,suspend���ٴΰ�co�洢��session_id_coroutine��
		end
	else
		--其他类型的消息处理，首先定义了一个proto表，里面包含了消息处理的原型对象
		local p = proto[prototype] 
		if p == nil then
			if session ~= 0 then
				c.send(source, skynet.PTYPE_ERROR, session, "")
			else
				unknown_request(session, source, msg, sz, prototype)
			end
			return
		end
		local f = p.dispatch     --取出本服务中消息类型对应的处理函数
		if f then
			local ref = watching_service[source]
			if ref then
				watching_service[source] = ref + 1
			else
				watching_service[source] = 1
			end
			local co = co_create(f)--取一个协程执行消息处理
			session_coroutine_id[co] = session --以协程为key，保存协程处理的消息对应消息源服务和session
			session_coroutine_address[co] = source
			suspend(co, coroutine_resume(co, session,source, p.unpack(msg,sz))) 
		else
			unknown_request(session, source, msg, sz, proto[prototype].name)
		end
	end
end

--[[ lua服务的消息处理函数，在skynet.start函数中设置
     参数依次为@1消息type @2:msg指针 @3:msg‘s length @4：session @5：source handle
--]] 
function skynet.dispatch_message(...)
	local succ, err = pcall(raw_dispatch_message,...)
	while true do
		local key,co = next(fork_queue)
		if co == nil then
			break
		end
		fork_queue[key] = nil
		local fork_succ, fork_err = pcall(suspend,co,coroutine_resume(co))
		if not fork_succ then
			if succ then
				succ = false
				err = tostring(fork_err)
			else
				err = tostring(err) .. "\n" .. tostring(fork_err)
			end
		end
	end
	assert(succ, tostring(err))
end

--启动新服务name
function skynet.newservice(name, ...)
	return skynet.call(".launcher", "lua" , "LAUNCH", "snlua", name, ...)
end

--service_mgr服务启动服务，唯一启动
function skynet.uniqueservice(global, ...)
	if global == true then
		return assert(skynet.call(".service", "lua", "GLAUNCH", ...))
	else
		return assert(skynet.call(".service", "lua", "LAUNCH", global, ...))
	end
end

function skynet.queryservice(global, ...)
	if global == true then
		return assert(skynet.call(".service", "lua", "GQUERY", ...))
	else
		return assert(skynet.call(".service", "lua", "QUERY", global, ...))
	end
end

function skynet.address(addr)
	if type(addr) == "number" then
		return string.format(":%08x",addr)
	else
		return tostring(addr)
	end
end

function skynet.harbor(addr)
	return c.harbor(addr)
end

skynet.error = c.error --skynet.core.error,往日志服务发送消息

----- register protocol
do
	local REG = skynet.register_protocol

	REG {
		name = "lua",
		id = skynet.PTYPE_LUA, -- 10
		pack = skynet.pack,
		unpack = skynet.unpack,
	}

	REG {
		name = "response",
		id = skynet.PTYPE_RESPONSE,
	}

	REG {
		name = "error",
		id = skynet.PTYPE_ERROR,
		unpack = function(...) return ... end,
		dispatch = _error_dispatch,
	}
end

local init_func = {}

function skynet.init(f, name)
	assert(type(f) == "function")
	if init_func == nil then
		f()
	else
		table.insert(init_func, f)
		if name then
			assert(type(name) == "string")
			assert(init_func[name] == nil)
			init_func[name] = f
		end
	end
end

--依次执行服务的初始化函数
local function init_all()
	local funcs = init_func
	init_func = nil
	if funcs then
		for _,f in ipairs(funcs) do
			f()
		end
	end
end

local function ret(f, ...)
	f()
	return ...
end

--服务初始化模板函数，先依次调用
local function init_template(start, ...)
	init_all()                      
	init_func = {}
	return ret(init_all, start(...)) --ִ��start����������start�ķ���ֵ
end


function skynet.pcall(start, ...)
	return xpcall(init_template, debug.traceback, start, ...)--����init_template����
end


--执行服务初始化函数start，然后通知到.launcher服务
function skynet.init_service(start)
	local ok, err = skynet.pcall(start) --����init_template(start) 
	if not ok then
		skynet.error("init service failed: " .. tostring(err))
		skynet.send(".launcher","lua", "ERROR")
		skynet.exit()
	else
		skynet.send(".launcher","lua", "LAUNCHOK") --��.launcher������һ��"��ɹ�"����Ϣ
	end
end

--设置服务开始时的执行函数start_func
function skynet.start(start_func)
	c.callback(skynet.dispatch_message) --设置服务的消息的处理函数 skynet.core.callback(skynet.dispatch_message)������skynet_context�Ļص�����
	skynet.timeout(0, function()        --ѹ��һ������Ϣ��������һ��Э����ִ��start_func
		skynet.init_service(start_func)
	end)
end

function skynet.endless()
	return c.command("ENDLESS")~=nil
end

function skynet.mqlen()
	return c.intcommand "MQLEN"
end

function skynet.task(ret)
	local t = 0
	for session,co in pairs(session_id_coroutine) do
		if ret then
			ret[session] = debug.traceback(co)
		end
		t = t + 1
	end
	return t
end

function skynet.term(service)
	return _error_dispatch(0, service)
end

function skynet.memlimit(bytes)
	debug.getregistry().memlimit = bytes
	skynet.memlimit = nil	-- set only once
end

-- Inject internal debug framework
local debug = require "skynet.debug"
debug.init(skynet, {
	dispatch = skynet.dispatch_message,
	suspend = suspend,
})

return skynet
