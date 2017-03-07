local skynet = require "skynet"
local harbor = require "skynet.harbor"
require "skynet.manager"	-- import skynet.launch, ...
local memory = require "memory"

skynet.start(function()
	local sharestring = tonumber(skynet.getenv "sharestring" or 4096) --ȡ�����������sharestring�ֶΣ�Ĭ��Ϊ4096
	memory.ssexpand(sharestring) --

	local standalone = skynet.getenv "standalone" --ȡip:port

	local launcher = assert(skynet.launch("snlua","launcher")) --����������������launch���񣬲����������ĵ�handle�ַ���
	skynet.name(".launcher", launcher)--insert handleName

	local harbor_id = tonumber(skynet.getenv "harbor" or 0) --ȡ���������е�harborֵ,Ĭ��Ϊ0
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
		if standalone then --����skynet.newservice
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
