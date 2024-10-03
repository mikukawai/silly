local format = string.format

local M = {}

local setmetatable = setmetatable

M.__index = M
function M.new()
	return setmetatable({
		input_name = {},
		output_name = {},
		handlers = {}
	}, M)
end

function M:register(proto, service)
	local input_name = self.input_name
	local output_name = self.output_name
	local package = proto.package
	local handlers = self.handlers
	for _, v in pairs(proto['service']) do
		local sname = v.name
		for _, y in pairs(v['method']) do
			local name = y.name
			local full_name = format("/%s.%s/%s", package, sname, name)
			local input_type = y.input_type
			local output_type = y.output_type
			input_name[full_name] = input_type
			output_name[full_name] = output_type
			handlers[full_name] = assert(service[name], name)
		end
	end
end

return M