local skynet = require "skynet"

local max_client = 64

skynet.start(function()
	print("Server start")
	local service = skynet.newservice("service_mgr") --��������service_mgr
	skynet.monitor "simplemonitor"                   --��������simplemonitor,���ұ�����service_mgr��service����
	local console = skynet.newservice("console")     --��������console
--	skynet.newservice("debug_console",8000)          
	skynet.newservice("simpledb")					 --��������simpledb
	local watchdog = skynet.newservice("watchdog")   --��������watchdog
	skynet.call(watchdog, "lua", "start", {          --��watchdog������Ϣ
		port = 8888,
		maxclient = max_client,
	})

	skynet.exit()
end)
