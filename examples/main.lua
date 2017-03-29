local skynet = require "skynet"

local max_client = 64

skynet.start(function()
	print("Server start")
	local service = skynet.newservice("service_mgr") --启动服务service_mgr
	skynet.monitor "simplemonitor"                   --启动服务simplemonitor,并且保存在service_mgr的service表中
	local console = skynet.newservice("console")     --启动服务console
--	skynet.newservice("debug_console",8000)          
	skynet.newservice("simpledb")					 --启动服务simpledb
	local watchdog = skynet.newservice("watchdog")   --启动服务watchdog
	skynet.call(watchdog, "lua", "start", {          --向watchdog发送消息
		port = 8888,
		maxclient = max_client,
	})

	skynet.exit()
end)
