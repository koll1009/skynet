local args = {}
for word in string.gmatch(..., "%S+") do --传入的第一个参数为'bootstrap'
	table.insert(args, word)
end

SERVICE_NAME = args[1] --服务名为'bootstrap'

local main, pattern

local err = {}
for pat in string.gmatch(LUA_SERVICE, "([^;]+);*") do  --以;分割luaservice路径
	local filename = string.gsub(pat, "?", SERVICE_NAME) --用"bootstrap"代替？
	local f, msg = loadfile(filename)    --加载该lua文件
	if not f then
		table.insert(err, msg)
	else
		pattern = pat 
		main = f --main为bootstrap.lua文件编译后的LClosure
		break
	end
end

if not main then
	error(table.concat(err, "\n"))
end

LUA_SERVICE = nil
package.path , LUA_PATH = LUA_PATH   --重新设置lua库和c库的路径
package.cpath , LUA_CPATH = LUA_CPATH

local service_path = string.match(pattern, "(.*/)[^/?]+$")

if service_path then
	service_path = string.gsub(service_path, "?", args[1])
	package.path = service_path .. "?.lua;" .. package.path
	SERVICE_PATH = service_path
else
	local p = string.match(pattern, "(.*/).+$")
	SERVICE_PATH = p
end

if LUA_PRELOAD then
	local f = assert(loadfile(LUA_PRELOAD))
	f(table.unpack(args))
	LUA_PRELOAD = nil
end

main(select(2, table.unpack(args))) --执行bootstrap.lua
