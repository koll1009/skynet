local skynet = require "skynet"

local clusterd
local cluster = {}

--远程调用，返回响应
function cluster.call(node, address, ...)
	-- skynet.pack(...) will free by cluster.core.packrequest
	return skynet.call(clusterd, "lua", "req", node, address, skynet.pack(...))
end

--开启该远程端口
function cluster.open(port)
	if type(port) == "string" then
		skynet.call(clusterd, "lua", "listen", port)
	else
		skynet.call(clusterd, "lua", "listen", "0.0.0.0", port)
	end
end

--重新加载，会重置node_address表
function cluster.reload()
	skynet.call(clusterd, "lua", "reload")
end

function cluster.proxy(node, name)
	return skynet.call(clusterd, "lua", "proxy", node, name)
end

function cluster.snax(node, name, address)
	local snax = require "snax"
	if not address then
		address = cluster.call(node, ".service", "QUERY", "snaxd" , name)
	end
	local handle = skynet.call(clusterd, "lua", "proxy", node, address)
	return snax.bind(handle, name)
end

function cluster.register(name, addr)
	assert(type(name) == "string")
	assert(addr == nil or type(addr) == "number")
	return skynet.call(clusterd, "lua", "register", name, addr)
end

function cluster.query(node, name)
	return skynet.call(clusterd, "lua", "req", node, 0, skynet.pack(name))
end

skynet.init(function()
	clusterd = skynet.uniqueservice("clusterd")
end)

return cluster
