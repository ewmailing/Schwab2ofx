
local m = {}

function m.split_file_components(file_name)
		local file_dir, file_name, file_ext = string.match(file_name, "(.-)([^\\/]-%.?([^%.\\/]*))$")
		--local base_pat = "(^.+)%." .. file_ext .. "$"
		local base_pat = "^(.*)%." .. file_ext .. "$"
		local file_basename = string.match(file_name, base_pat)
		--[[
		print("dir", file_dir)
		print("name", file_name)
		print("ext", file_ext)
		print("base", file_basename)
		--]]
		return file_dir, file_name, file_basename, file_ext
end

return m

