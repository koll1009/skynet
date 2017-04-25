local table = table
local type = type

local M = {}

local LIMIT = 8192

--[[chunked编码方式
  16进制的数据长度
  \r\n
  数据内容
  \r\n
  16进制的数据长度
  \r\n
  数据内容
  \r\n
  0
  \r\n
  \r\n
]]
local function chunksize(readbytes, body)
	while true do
		local f,e = body:find("\r\n",1,true) 
		if f then
			return tonumber(body:sub(1,f-1),16), body:sub(e+1)
		end
		if #body > 128 then
			-- pervent the attacker send very long stream without \r\n
			return
		end
		body = body .. readbytes()
	end
end

local function readcrln(readbytes, body)
	if #body >= 2 then
		if body:sub(1,2) ~= "\r\n" then
			return
		end
		return body:sub(3)
	else
		body = body .. readbytes(2-#body)
		if body ~= "\r\n" then
			return
		end
		return ""
	end
end

--接收http head
function M.recvheader(readbytes, lines, header)
	if #header >= 2 then
		if header:find "^\r\n" then
			return header:sub(3)
		end
	end
	local result
	local e = header:find("\r\n\r\n", 1, true)
	if e then
		result = header:sub(e+4)
	else
		while true do
			local bytes = readbytes() --读取http数据
			header = header .. bytes
			if #header > LIMIT then   --超过数据大小限制
				return
			end
			e = header:find("\r\n\r\n", -#bytes-3, true) 
			if e then
				result = header:sub(e+4)
				break
			end
			if header:find "^\r\n" then
				return header:sub(3)
			end
		end
	end
	for v in header:gmatch("(.-)\r\n") do
		if v == "" then
			break
		end
		table.insert(lines, v) --把请求头全部保存到lines里
	end
	return result              --result为请求body
end

function M.parseheader(lines, from, header)
	local name, value
	for i=from,#lines do
		local line = lines[i]
		if line:byte(1) == 9 then	-- tab, append last line
			if name == nil then
				return
			end
			header[name] = header[name] .. line:sub(2)
		else
			name, value = line:match "^(.-):%s*(.*)"
			if name == nil or value == nil then
				return
			end
			name = name:lower()
			if header[name] then
				local v = header[name]
				if type(v) == "table" then
					table.insert(v, value)
				else
					header[name] = { v , value }
				end
			else
				header[name] = value
			end
		end
	end
	return header
end

function M.recvchunkedbody(readbytes, bodylimit, header, body)
	local result = ""
	local size = 0

	while true do
		local sz
		sz , body = chunksize(readbytes, body) --sz为chunk的数据长度
		if not sz then
			return
		end
		if sz == 0 then                        --数据接收完毕
			break
		end
		size = size + sz
		if bodylimit and size > bodylimit then
			return
		end
		if #body >= sz then
			result = result .. body:sub(1,sz)
			body = body:sub(sz+1)
		else
			result = result .. body .. readbytes(sz - #body)
			body = ""
		end
		body = readcrln(readbytes, body)
		if not body then
			return
		end
	end

	local tmpline = {}
	body = M.recvheader(readbytes, tmpline, body)
	if not body then
		return
	end

	header = M.parseheader(tmpline,1,header)

	return result, header
end

return M
