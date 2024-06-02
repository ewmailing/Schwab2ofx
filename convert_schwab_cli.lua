#!/usr/bin/env lua
local schwab2ofx = require("schwab2ofx")




local function load_source_file(source_file_name)
	--local fh = io.open(source_file_name, "r")
	local fh = assert(io.open(source_file_name, "r"))
	if fh then
		local all_data = fh:read("*all")
		--print(all_data,"\n\n")
		fh:close()


		local decoded_data = schwab2ofx.json_decode(all_data)
		assert(decoded_data, "json.decode failed on the input file")

		return decoded_data
	end

	return nil
end

local function write_ofx_file(target_file_name, file_data)
	local fh = assert(io.open(target_file_name, "w"))
	if fh then
		fh:write(file_data)
		fh:close()
		print("Wrote output to: ", target_file_name)
	end
end



local function main()


	local source_file_name = arg[1]
	local target_file_name = arg[2]

	print("source_file_name", source_file_name)
	print("target_file_name", target_file_name)

	if source_file_name == nil then
		print("Usage: lua " .. arg[0] .. " <source.json> <target.ofx>")
		return
	end
	if target_file_name == nil then
		local helpers = require("helpers")
		local file_dir, file_name, file_basename, file_ext = helpers.split_file_components(source_file_name)
		target_file_name = file_basename .. ".ofx"
	end

	local decoded_data = load_source_file(source_file_name)

	-- TODO: Add command line arguments
	local optional_params = 
	{
		brokerID = tostring( os.getenv("BROKERID") or 0 ),
		accountID = tostring( os.getenv("ACCTID") or 0 ),
	}

	local flattened_ofx_all = schwab2ofx.create_ofx(decoded_data, optional_params)


	write_ofx_file(target_file_name, flattened_ofx_all)


end

main()


