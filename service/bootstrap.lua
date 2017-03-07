local skynet = require "skynet"
local harbor = require "skynet.harbor"
require "skynet.manager"	-- import skynet.launch, ...
local memory = require "memory"

skynet.start(function()
	local sharestring = tonumber(skynet.getenv "sharestring" or 4096) --取环境变量里的sharestring字段，默认为4096
	memory.ssexpand(sharestring) --

	local standalone = skynet.getenv "standalone" --取ip:port

	local launcher = assert(skynet.launch("snlua","launcher")) --该上下文用于启动launch服务，并返回上下文的handle字符串
	skynet.name(".launcher", launcher)--insert handleName

	local harbor_id = tonumber(skynet.getenv "harbor" or 0) --取环境变量中的harbor值,默认为0
	if harbor_id == 0 then
		assert(standalone ==  nil)
		standalone = true
		skynet.setenv("standalone", "true")

		local ok, slave = pcall(skynet.newservice, "cdummy")
		if not ok then
			skynet.abort()
		end
		skynet.name(".cslave", slave)

	else
		if standalone then --调用skynet.newservice
			if not pcall(skynet.newservice,"cmaster") then
				skynet.abort()
			end
		end

		local ok, slave = pcall(skynet.newservice, "cslave")
		if not ok then
			skynet.abort()
		end
		skynet.name(".cslave", slave)
	end

	if standalone then
		local datacenter = skynet.newservice "datacenterd"
		skynet.name("DATACENTER", datacenter)
	end
	skynet.newservice "service_mgr"
	pcall(skynet.newservice,skynet.getenv "start" or "main")
	skynet.exit()
end)
