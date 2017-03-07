local args = {}
for word in string.gmatch(..., "%S+") do  --�Կո�ָ��ַ�������һ������������һ������Ϊsnlua����Ϣ��data
	table.insert(args, word)
end

SERVICE_NAME = args[1] --������������'bootstrap'

local main, pattern

local err = {}
for pat in string.gmatch(LUA_SERVICE, "([^;]+);*") do    --��;�ָ�luaservice·��
	local filename = string.gsub(pat, "?", SERVICE_NAME) --��"bootstrap"���棿����Ϊlua�ļ�·��
	local f, msg = loadfile(filename)    --���ظ�lua�ļ�
	if not f then
		table.insert(err, msg)
	else
		pattern = pat  --patternΪlua�ļ����·��
		main = f       --mainΪlua�ļ�������LClosure������bootstrap.lua
		break
	end
end

if not main then       --lua�ļ�������
	error(table.concat(err, "\n"))
end

LUA_SERVICE = nil
package.path , LUA_PATH = LUA_PATH   --��������lua���c���·��
package.cpath , LUA_CPATH = LUA_CPATH

local service_path = string.match(pattern, "(.*/)[^/?]+$") --

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

main(select(2, table.unpack(args))) --ִ��bootstrap.lua
