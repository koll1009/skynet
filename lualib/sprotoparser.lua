local lpeg = require "lpeg"
local table = require "table"

local packbytes
local packvalue

if _VERSION == "Lua 5.3" then
	function packbytes(str)
		return string.pack("<s4",str)
	end

	--
	function packvalue(id)
		id = (id + 1) * 2
		return string.pack("<I2",id)
	end
else
    --四个字节的串长度+串
	function packbytes(str)
		local size = #str
		local a = size % 256
		size = math.floor(size / 256)
		local b = size % 256
		size = math.floor(size / 256)
		local c = size % 256
		size = math.floor(size / 256)
		local d = size
		return string.char(a)..string.char(b)..string.char(c)..string.char(d) .. str
	end

	function packvalue(id)
		id = (id + 1) * 2
		assert(id >=0 and id < 65536)
		local a = id % 256
		local b = math.floor(id / 256)
		return string.char(a) .. string.char(b)
	end
end

local P = lpeg.P --
local S = lpeg.S --anything in a set
local R = lpeg.R --anything in a range
local C = lpeg.C --capture
local Ct = lpeg.Ct --capture into a lua table
local Cg = lpeg.Cg
local Cc = lpeg.Cc --将所有的匹配value作为捕获的值
local V = lpeg.V --变量
--lpeg.Cmt(patt,func) 将整个subject，当前index，捕获的值作为参数传递给function

local function count_lines(_,pos, parser_state)
	if parser_state.pos < pos then
		parser_state.line = parser_state.line + 1
		parser_state.pos = pos
	end
	return pos
end

local exception = lpeg.Cmt( lpeg.Carg(1) , function ( _ , pos, parser_state)
	error(string.format("syntax error at [%s] line (%d)", parser_state.file or "", parser_state.line))
	return pos
end)

local eof = P(-1) --文件尾，只有一个字符
local newline = lpeg.Cmt((P"\n" + "\r\n") * lpeg.Carg(1) ,count_lines) --行计数
local line_comment = "#" * (1 - newline) ^0 * (newline + eof) --行注释
local blank = S" \t" + newline + line_comment --空格
local blank0 = blank ^ 0 --0或者多个空格
local blanks = blank ^ 1 --1或多个空额
local alpha = R"az" + R"AZ" + "_" --字母
local alnum = alpha + R"09" --字母+数字
local word = alpha * alnum ^ 0 --字母+多个（字母或数字组合）
local name = C(word) --捕获word
local typename = C(word * ("." * word) ^ 0) 
local tag = R"09" ^ 1 / tonumber
local mainkey = "(" * blank0 * name * blank0 * ")"

local function multipat(pat)
	return Ct(blank0 * (pat * blanks) ^ 0 * pat^0 * blank0)
end

--Cc(name),捕获的name的value值，Cg(Cc(name),"type") type=Cc(name),
local function namedpat(name, pat)
	return Ct(Cg(Cc(name), "type") * Cg(pat)) --{type=name,字段名，*，类型名 }
end

--安语法进行解析
local typedef = P {
	"ALL",
	--capture后为table，{type="field",[1]=name,[2]=index(tag),[3]='*',[4]=string(type类型)，[5]=mainkey}
	FIELD = namedpat("field", (name * blanks * tag * blank0 * ":" * blank0 * (C"*")^-1 * typename * mainkey^0)),
	STRUCT = P"{" * multipat(V"FIELD" + V"TYPE") * P"}",--capture后为table，{ [1][2][3]={ field table } or { type table },}
	TYPE = namedpat("type", P"." * name * blank0 * V"STRUCT" ), --type name以.开头，capture后为table，{ type="type",[1]=name,[2]={ struct table } }
	
	--子协议只有request和response两种
	SUBPROTO = Ct((C"request" + C"response") * blanks * (typename + V"STRUCT")),--{ [1]="request" or "response",[2]=name or { struct table } }
	PROTOCOL = namedpat("protocol", name * blanks * tag * blank0 * P"{" * multipat(V"SUBPROTO") * P"}"),--{type="protocol",[1]=name ,[2]=index,[3]={SUBPROTO table}}
	ALL = multipat(V"TYPE" + V"PROTOCOL"), --table {[0]={ type table },[1]={ protocol table }  }
}

local proto = blank0 * typedef * blank0

local convert = {}

--定义的protocol的转换，@all为捕获的{type，protocol}表，@obj为protocol table，protocol table的构成{type="protocol",[1]=name ,[2]=index,[3]={SUBPROTO table}}
function convert.protocol(all, obj)
	local result = { tag = obj[2] } --保存protocol的索引
	for _, p in ipairs(obj[3]) do   --取子协议，子协议table { [1]="request" or "response",[2]=name or { struct table } }
		assert(result[p[1]] == nil)
		local typename = p[2]       --子协议名或者协议的定义table
		if type(typename) == "table" then
			local struct = typename
			typename = obj[1] .. "." .. p[1] --protocolname.request 或者protocolname.response
			all.type[typename] = convert.type(all, { typename, struct }) --all.type[procolname.request]={name="age" ,tag=1,filedtype="interger",array=nil,mainkey=nil}
		end
		result[p[1]] = typename 
	end
	return result
end

--定义的type的转换，@all为捕获的{type，protocol}表，@obj为type table，typetable的构成{ type="type",[1]=name,[2]={ struct table } }
function convert.type(all, obj)
	local result = {}
	local typename = obj[1]
	local tags = {}
	local names = {}
	for _, f in ipairs(obj[2]) do --遍历 struct table，
		if f.type == "field" then --如果f为field table，构成为 {type="field",[1]=name,[2]=index(tag),[3]='*',[4]=string(type类型)，[5]=mainkey}
			local name = f[1]   --取filed name
			if names[name] then --字段名重复定义
				error(string.format("redefine %s in type %s", name, typename))
			end
			names[name] = true --缓存字段名

			local tag = f[2]  --取field index
			if tags[tag] then
				error(string.format("redefine tag %d in type %s", tag, typename))
			end
			tags[tag] = true

			local field = { name = name, tag = tag }
			table.insert(result, field) 
			local fieldtype = f[3]
			if fieldtype == "*" then --如果有字符"*",说明为数组
				field.array = true  --标记数组
				fieldtype = f[4]    --数组类型
			end
			local mainkey = f[5]
			if mainkey then
				assert(field.array)
				field.key = mainkey  --有key则保存key 
			end
			field.typename = fieldtype --保存filed的类型，此时filed表转换成{name="age" ,tag=1,filedtype="interger",array=nil,mainkey=nil}
		else --嵌套的type
			assert(f.type == "type")	-- nest type
			local nesttypename = typename .. "." .. f[1] --类似package.subpackage
			f[1] = nesttypename
			assert(all.type[nesttypename] == nil, "redefined " .. nesttypename)
			all.type[nesttypename] = convert.type(all, f) --递归转换
		end
	end
	table.sort(result, function(a,b) return a.tag < b.tag end) --把字段表按照索引排序
	
	return result
end

--调整捕获的{ type，protocol }表
local function adjust(r)
	local result = { type = {} , protocol = {} }

	for _, obj in ipairs(r) do --取类型
		local set = result[obj.type] --"type" or "protocol"
		local name = obj[1] --取type或者protocol的name
		assert(set[name] == nil , "redefined " .. name)
		set[name] = convert[obj.type](result,obj) --set["package"] or set["login"] ,name为定义的 type 名，例如.package {}中的package；也可以为定义的protocol名，例如 login 1 { request {}}中的login
	end

	return result
end

--内置类型
local buildin_types = {
	integer = 0,
	boolean = 1,
	string = 2,
}

--类型检查
local function checktype(types, ptype, t)
	if buildin_types[t] then
		return t
	end
	local fullname = ptype .. "." .. t
	if types[fullname] then
		return fullname
	else
		ptype = ptype:match "(.+)%..+$"
		if ptype then
			return checktype(types, ptype, t)
		elseif types[t] then
			return t
		end
	end
end

--检查protocol的合法性
local function check_protocol(r)
	local map = {}
	local type = r.type
	for name, v in pairs(r.protocol) do
		local tag = v.tag
		local request = v.request
		local response = v.response
		local p = map[tag]

		if p then
			error(string.format("redefined protocol tag %d at %s", tag, name))
		end

		if request and not type[request] then
			error(string.format("Undefined request type %s in protocol %s", request, name))
		end

		if response and not type[response] then
			error(string.format("Undefined response type %s in protocol %s", response, name))
		end

		map[tag] = v
	end
	return r
end

--type名补全
local function flattypename(r)
	for typename, t in pairs(r.type) do --遍历type表
		for _, f in pairs(t) do --遍历filed表
			local ftype = f.typename --file type
			local fullname = checktype(r.type, typename, ftype) --typename例如login.request
			if fullname == nil then
				error(string.format("Undefined type %s in type %s", ftype, typename))
			end
			f.typename = fullname
		end
	end

	return r
end

local function parser(text,filename)
	local state = { file = filename, pos = 0, line = 1 }
	local r = lpeg.match(proto * -1 + exception , text , 1, state ) --按照协议串，通过匹配，捕获一张{ type,protocol }表
	return  flattypename(check_protocol(adjust(r)))
end

--[[
-- The protocol of sproto
.type {
	.field {
		name 0 : string
		buildin	1 :	integer
		type 2 : integer
		tag	3 :	integer
		array 4	: boolean
		key 5 : integer # If key exists, array must be true, and it's a map.
	}
	name 0 : string
	fields 1 : *field
}

.protocol {
	name 0 : string
	tag	1 :	integer
	request	2 :	integer	# index
	response 3 : integer # index
}

.group {
	type 0 : *type
	protocol 1 : *protocol
}
]]

--字段打包
local function packfield(f)
	local strtbl = {}
	if f.array then
		if f.key then
			table.insert(strtbl, "\6\0")  -- 6 fields，6表示从6个维度描述filed
		else
			table.insert(strtbl, "\5\0")  -- 5 fields
		end
	else
		table.insert(strtbl, "\4\0")	-- 4 fields                                                                                                                                                                                                                                         
	end
	table.insert(strtbl, "\0\0")	-- name	(tag = 0, ref an object)
	if f.buildin then
		table.insert(strtbl, packvalue(f.buildin))	-- buildin (tag = 1) 两个字节的内置类型
		table.insert(strtbl, "\1\0")	-- skip (tag = 2)                两个字节的对齐字符
		table.insert(strtbl, packvalue(f.tag))		-- tag (tag = 3)     两个字节的filed在type table中的index
	else
		table.insert(strtbl, "\1\0")	-- skip (tag = 1)
		table.insert(strtbl, packvalue(f.type))		-- type (tag = 2)
		table.insert(strtbl, packvalue(f.tag))		-- tag (tag = 3)
	end
	if f.array then
		table.insert(strtbl, packvalue(1))	-- array = true (tag = 4)    两个字节的array标志
	end
	if f.key then
		table.insert(strtbl, packvalue(f.key)) -- key tag (tag = 5)      两个字节的数组类型字段index
	end
	table.insert(strtbl, packbytes(f.name)) -- external object (name)    n个字节的filed name
	return packbytes(table.concat(strtbl)) --使用string.pack打包，打包后，前四个字节为len 后跟len个字节的串
end

--类型打包,name为类型名，t为name对应的table，alltypes为各类型的定义，定义了filedname以及index
local function packtype(name, t, alltypes)
	local fields = {}
	local tmp = {}
	for _, f in ipairs(t) do --遍历各filed
		tmp.array = f.array --是否数组
		tmp.name = f.name   --field name
		tmp.tag = f.tag     --字段index

		tmp.buildin = buildin_types[f.typename] --字段的内置类型
		local subtype
		if not tmp.buildin then --如果不属于内置类型，则从定义的type中取
			subtype = assert(alltypes[f.typename])
			tmp.type = subtype.id  --alltypes中的index
		else
			tmp.type = nil
		end
		if f.key then
			tmp.key = subtype.fields[f.key] --取子类型字段中名为key的index
			if not tmp.key then
				error("Invalid map index :" .. f.key)
			end
		else
			tmp.key = nil
		end

		table.insert(fields, packfield(tmp))--添加到filed table，
	end
	local data
	if #fields == 0 then --如果没定义字段
		data = {
			"\1\0",	-- 1 fields
			"\0\0",	-- name	(id = 0, ref = 0)
			packbytes(name),-- type name
		}
	else
		data = {
			"\2\0",	-- 2 fields
			"\0\0",	-- name	(tag = 0, ref = 0)
			"\0\0", -- field[]	(tag = 1, ref = 1)
			packbytes(name),
			packbytes(table.concat(fields)),
		}
	end

	return packbytes(table.concat(data)) --这样一个一个type对应的fields就被描述为了 header+type name+filed array的字节流
end

--协议打包，协议会打包成\4\0 \0\0 index request id response id protocolname
local function packproto(name, p, alltypes)
	if p.request then
		local request = alltypes[p.request]
		if request == nil then
			error(string.format("Protocol %s request type %s not found", name, p.request))
		end
		request = request.id
	end
	local tmp = {
		"\4\0",	-- 4 fields
		"\0\0",	-- name (id=0, ref=0)
		packvalue(p.tag),	-- tag (tag=1)
	}
	if p.request == nil and p.response == nil then
		tmp[1] = "\2\0"
	else
		if p.request then
			table.insert(tmp, packvalue(alltypes[p.request].id)) -- request typename (tag=2)
		else
			table.insert(tmp, "\1\0")
		end
		if p.response then
			table.insert(tmp, packvalue(alltypes[p.response].id)) -- request typename (tag=3)
		else
			tmp[1] = "\3\0"
		end
	end

	table.insert(tmp, packbytes(name))

	return packbytes(table.concat(tmp))
end


local function packgroup(t,p)
	if next(t) == nil then --type表为空
		assert(next(p) == nil)
		return "\0\0"
	end
	local tt, tp
	local alltypes = {}
	for name in pairs(t) do
		table.insert(alltypes, name) --保存type name
	end
	table.sort(alltypes)	-- make result stable
	for idx, name in ipairs(alltypes) do
		local fields = {}
		for _, type_fields in ipairs(t[name]) do 
			if buildin_types[type_fields.typename] then --属于内置类型
				fields[type_fields.name] = type_fields.tag --field.age=2 字段名-index对
			end
		end
		alltypes[name] = { id = idx - 1, fields = fields }  --{ [1] = "get.request", [2] = "get.response", ["get.response"] = { ["id"] = 1, ["fields"] = { ["result"] = 0 }}, ["get.request"] = { ["id"] = 0,["fields"] = {["what"] = 0} }
}

	end

	tt = {}
	for _,name in ipairs(alltypes) do
		table.insert(tt, packtype(name, t[name], alltypes)) --依次打包types
	end
	tt = packbytes(table.concat(tt)) --把所有类型打包成了字节流

	--协议不为空
	if next(p) then
		local tmp = {}
		for name, tbl in pairs(p) do
			table.insert(tmp, tbl)
			tbl.name = name
		end
		table.sort(tmp, function(a,b) return a.tag < b.tag end)
		logger.debug("test")
		logger.debug(dump.dump(tmp))
		tp = {}
		for _, tbl in ipairs(tmp) do
			table.insert(tp, packproto(tbl.name, tbl, alltypes)) --把协议打包成字节流描述
		end
		tp = packbytes(table.concat(tp))
	end
	local result
	if tp == nil then
		result = {
			"\1\0",	-- 1 field
			"\0\0",	-- type[] (id = 0, ref = 0)
			tt,
		}
	else
		result = {
			"\2\0",	-- 2fields
			"\0\0",	-- type array	(id = 0, ref = 0)
			"\0\0",	-- protocol array	(id = 1, ref =1)

			tt,
			tp,
		}
	end

	return table.concat(result)
end

--编码
local function encodeall(r)
	return packgroup(r.type, r.protocol)
end

local sparser = {}

function sparser.dump(str)
	local tmp = ""
	for i=1,#str do
		tmp = tmp .. string.format("%02X ", string.byte(str,i))
		if i % 8 == 0 then
			if i % 16 == 0 then
				print(tmp)
				tmp = ""
			else
				tmp = tmp .. "- "
			end
		end
	end
	print(tmp)
end

function sparser.parse(text, name)
	local r = parser(text, name or "=text")--先解析原型串
	local data = encodeall(r) --编码
	return data
end

return sparser
