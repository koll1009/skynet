local skynet = require "skynet"
local socket = require "socket"

local function console_main_loop()
	local stdin = socket.stdin()  --
	socket.lock(stdin)
	while true do
		local cmdline = socket.readline(stdin, "\n") --��̬��������
		if cmdline ~= "" then
			local handle = skynet.newservice(cmdline)
			if handle == nil then
				print("Launch error:",cmdline)
			end
		end
	end
	socket.unlock(stdin)
end

skynet.start(function()
	skynet.fork(console_main_loop)
end)
