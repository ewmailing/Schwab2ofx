--[[
Copyright (c) Eric Wing

This software is provided 'as-is', without any express or implied
warranty. In no event will the authors be held liable for any damages
arising from the use of this software.

Permission is granted to anyone to use this software for any purpose,
including commercial applications, and to alter it and redistribute it
freely, subject to the following restrictions:

1. The origin of this software must not be misrepresented; you must not
   claim that you wrote the original software. If you use this software
   in a product, an acknowledgment in the product documentation would be
   appreciated but is not required.
2. Altered source versions must be plainly marked as such, and must not be
   misrepresented as being the original software.
3. This notice may not be removed or altered from any source distribution.
--]]

local m = {}

--[[
TIP: Set the environmental variables BROKERID and ACCTID to get those values written into the .ofx output. Default will be 0 for both.
export BROKERID=123456789
export ACCTID=1234567890
--]]

-- I'm struggling to understand what these events do.
-- Maybe I should be using JRNLFUND or JRNLSEC instead of TRANSFER.
-- But Schwab doesn't give me any data about subaccounts.
--[[
local DISABLE_INTERNAL_TRANSFER 	= true
local DISABLE_JOURNALED_SHARES 		= true
local DISABLE_JOURNAL 				= true
--]]
-- [[
local DISABLE_INTERNAL_TRANSFER 	= false
local DISABLE_JOURNALED_SHARES 		= false
local DISABLE_JOURNAL 				= false
--]]


local TICKER_TO_COMPANY_NAME_FILE = "MyCombinedStockList.lua"



--[[
https://financialdataexchange.org/common/Uploaded%20files/OFX%20files/OFX%20Banking%20Specification%20v2.3.pdf
https://github.com/reubano/csv2ofx/issues/32
https://github.com/gbjbaanb/ft2ofx/blob/master/csv2ofx.cpp
https://github.com/csingley/ofxtools/blob/master/tests/data/invstmtrs.ofx
https://www.lemonfool.co.uk/viewtopic.php?t=9446
https://community.quicken.com/discussion/7949886/understanding-qfx-file-structure
https://community.quicken.com/discussion/7930862/creating-an-ofx-file-which-an-be-opened-by-quicken-v6-12-3-for-macos
https://lists.gnucash.org/pipermail/gnucash-user/2005-January/012588.html
--]]



-- Splits a symbol string such as "JNJ 03/17/2023 150.00 P"
-- Assumes date is always MM/DD/YYYY with no omitted digits (i.e. has leading zeros)
-- note return order for date is year, month, day
local function split_option_components(cur_transaction)
	local symbol_str = cur_transaction["Symbol"]
	local ticker, exp_month_str, exp_day_str, exp_year_str, strike_price_str, put_or_call_str = string.match(symbol_str, "(%w+) (%d%d)/(%d%d)/(%d%d%d%d) (%d+%.%d+) ([CP])")
	return ticker, exp_year_str, exp_month_str, exp_day_str, strike_price_str, put_or_call_str
end

-- convenience function to decide if the provided symbol string is an option
local function is_symbol_string_an_option(cur_transaction)
	local ticker, exp_year_str, exp_month_str, exp_day_str, strike_price_str, put_or_call_str = split_option_components(cur_transaction)

	if ticker and ticker ~= ""
		and exp_year_str and exp_year_str ~= ""
		and exp_month_str and exp_month_str ~= ""
		and exp_day_str and exp_day_str ~= ""
		and strike_price_str and strike_price_str ~= ""
		and put_or_call_str and put_or_call_str ~= ""
	then
		return true
	else
		return false
	end
end

-- canonical option format:
-- KGC250117C00005500
-- for KGC 2025 Jan 17 Call $5.50 strike
local function compute_option_symbol(ticker, exp_year_str, exp_month_str, exp_day_str, strike_price_str, put_or_call_str)
	local strike_price_num = tonumber(strike_price_str)
	local shifted_num = 1000 * strike_price_num
	local padded_strike_str = string.format("%08d", shifted_num)

	-- Assumption: I got 4 digit year. Canonical format uses only last 2 digits.
	--assert(#exp_year_str == 4, "This code has been written to assume 4-digit years. Something is broken.")
	--print("exp_year_str", exp_year_str)
	
	local lower_year_digits
	if #exp_year_str == 2 then
		lower_year_digits = exp_year_str
	else
		lower_year_digits = string.match(exp_year_str, "%d%d(%d%d)")
	end
	--print("lower_year_digits", lower_year_digits)

	local option_symbol = ticker .. lower_year_digits .. exp_month_str .. exp_day_str .. put_or_call_str .. padded_strike_str

	return option_symbol
end

-- Assumes date is always YYYY MM DD with no omitted digits (i.e. has leading zeros)
local function compute_transaction_date_YYYYMMDD(year_str, month_str, day_str)
	local date_str = year_str .. month_str .. day_str
	return date_str
end

local function extract_transaction_date(cur_transaction)
	local date_field = cur_transaction["Date"]

	-- There are two forms:
    -- "Date": "05/20/2024 as of 05/17/2024",
    -- "Date": "05/21/2024",
	-- The first form might only come up for options expiration. But it's hard to know.
	local month, day, year = string.match(date_field, "%d%d/%d%d/%d%d%d%d as of (%d%d)/(%d%d)/(%d%d%d%d)")
	if not month then
		month, day, year = string.match(date_field, "(%d%d)/(%d%d)/(%d%d%d%d)")
	end

	return year, month, day
end

-- Originally I was going to try to chop off the currency marker.
-- But I noticed Schwab also uses commas and negative signs for numbers, which makes the pattern matching more complicated.
-- SEE Finance seems to handle me just passing the values straight through, so I'm doing that instead.
--[[
local function get_price_str(cur_transaction)
	-- $0.28
	local price_str = cur_transaction["Price"]
	local extract_price = string.match("%p*(%d+%.%d+)%p*")
	return extract_price
end
--]]


-- TODO: Build up a database for cases (e.g. Futures) where the answer is not 100.
local function get_shares_per_contract(underlying_ticker)
	return 100
end


local function create_position_for_underlying_from_option(cur_transaction, underlying_ticker_symbol, option_description, option_type_str, inout_position_map, ticker_company_map)

	local ticker_symbol = underlying_ticker_symbol

	if nil ~= inout_position_map[ticker_symbol] then
		return
	end



	-- PUT EXXON MOBIL CORP $105 EXP 07/19/24 
	-- option_type_str is either PUT or CALL
	local security_name = string.match(option_description, option_type_str .. " (.+) %$(%d+) EXP %d+/%d+/%d+")
	if security_name == nil then
		security_name = ""
	end
	-- Lookup the company name by ticker in our outside database.
	-- If the entry exists, prefer the database entry because the Schwab data isn't very good.
	local db_entry = ticker_company_map[ticker_symbol]
	if db_entry then
		local company_name = db_entry.name
		if company_name and company_name ~= "" then
			security_name = company_name
--			print("Found ticker: " .. ticker_symbol .. " with company name: " .. company_name .. " in database")
		else
--			print("Did not find company_name for ticker: " .. ticker_symbol .. " in database")
		end
	else
--		print("Did not find database entry for ticker: " .. ticker_symbol)
	end


	local position = [[
					<STOCKINFO>
						<SECINFO>
							<SECID> <!--Security ID-->
								<UNIQUEID>]] .. ticker_symbol .. [[</UNIQUEID>
							</SECID>
							<SECNAME>]] .. security_name .. [[</SECNAME> 
							<TICKER>]] .. ticker_symbol .. [[</TICKER>
						</SECINFO>
							<!--
								<ASSETCLASS>LARGESTOCK</ASSETCLASS>
							-->

					</STOCKINFO>       
]]


	inout_position_map[ticker_symbol] = position



end

local function generate_option_buy(cur_transaction, is_to_open, inout_transaction_list, inout_position_map, ticker_company_map)

	local ticker, exp_year_str, exp_month_str, exp_day_str, strike_price_str, put_or_call_str = split_option_components(cur_transaction)


	-- 20240102
	local trade_date_str = compute_transaction_date_YYYYMMDD( extract_transaction_date(cur_transaction) )
	-- XOM20240719P00105000
	local option_symbol = compute_option_symbol(ticker, exp_year_str, exp_month_str, exp_day_str, strike_price_str, put_or_call_str)
	-- PUT EXXON MOBIL CORP $105 EXP 07/19/24
	local description_name =  cur_transaction["Description"]

	-- Quantity may have commas and negative signs. SEE Finance seems to be okay with me passing these straight through.
	local units_str = cur_transaction["Quantity"]
	-- This has the currency symbol, and potentially commas, and periods. Again, SEE Finance seems to handle that fine.
	local unit_price_str = cur_transaction["Price"]
	local fee_str = cur_transaction["Fees & Comm"]
	local total_amount_str = cur_transaction["Amount"]

	local opt_buy_type = "BUYTOCLOSE"
	if is_to_open then
		opt_buy_type = "BUYTOOPEN"
	end

	local human_friendly_symbol = cur_transaction["Symbol"]

	local transaction = [[
					<BUYOPT>
						<INVBUY>
							<INVTRAN>
								<DTTRADE>]] .. trade_date_str .. [[</DTTRADE>
								<MEMO>]] .. description_name .. [[</MEMO>
                            </INVTRAN>							
							<SECID>
								<UNIQUEID>]] .. option_symbol .. [[</UNIQUEID>
							</SECID>

							<UNITS>]] .. units_str .. [[</UNITS>
							<UNITPRICE>]] .. unit_price_str .. [[</UNITPRICE>
							<COMMISSION>]] .. fee_str .. [[</COMMISSION>
							<TOTAL>]] .. total_amount_str .. [[</TOTAL>
						</INVBUY>
						<OPTBUYTYPE>]] .. opt_buy_type .. [[</OPTBUYTYPE>
					</BUYOPT>
]]


	local option_type_str
	if put_or_call_str == "P" then
		option_type_str = "PUT"
	elseif put_or_call_str == "C" then
		option_type_str = "CALL"
	else
		assert(false, "Value in string should have been C or P")
	end

	local expire_date = exp_year_str .. exp_month_str .. exp_day_str

	local shares_per_contract_str = get_shares_per_contract(ticker)


	-- I have 2 problems with specifying the underlying:
	-- 1. The OFX specfication wants me to to:
	-- <SECID> <UNIQUEID>123456789</UNIQUEID> <UNIQUETYPE>CUSIP</UNIQUETYPE> </SECID>
	-- But Schwab isn't giving the CUSIPs in their files, and there doesn't seem to be a public database with all the CUSIPs.
	-- It looks like you are expected to pay money to get access to the CUSIPs.
	-- The docs don't show any other supported values for <UNIQUETYPE> other than CUSIP.
	-- I searched hard, and I found somebody using OTHER, and somebody using TICKER, but I presume it will be extremely implementation dependent.
	--
	-- 2. If I use the underyling ticker, SEE Finance seems to have a weird bug where if I do this, the underlying will not get imported into the Portfolio->Stocks list.
	-- I was banging my head on this for hours, trying to figure out why none of my stocks were getting imported.
	-- Ironically, SEE Finance does actually list the stock's ticker in the option's underlying Info. So it almost works.
	-- But it is still too broken for me to do this. Maybe I can ask SEE Finance to fix this?
	-- For now, I will leave the underlying blank.

	--						<UNIQUEID>]] .. ticker .. [[</UNIQUEID><!--CUSIP for the underlying stock -->
	
	local position = [[
					<OPTINFO>
						<SECINFO>
							<SECID>
								<UNIQUEID>]] .. option_symbol .. [[</UNIQUEID>
							</SECID>
							<SECNAME>]] .. human_friendly_symbol .. [[</SECNAME> 

							<!-- The docs imply that is might be the ticker of the underlying, but SEE Finance using it as the option identifer. -->
							<TICKER>]] .. option_symbol .. [[</TICKER>
						</SECINFO>
						<OPTTYPE>]] .. option_type_str .. [[</OPTTYPE> 
						<STRIKEPRICE>]] .. strike_price_str .. [[</STRIKEPRICE>

						<DTEXPIRE>]] .. expire_date .. [[</DTEXPIRE> 
						<SHPERCTRCT>]] .. shares_per_contract_str .. [[</SHPERCTRCT> 

						<!-- I think this section is supposed to be for the underlying -->
						<SECID>
							<UNIQUEID>]] .. ticker .. [[</UNIQUEID>
						</SECID>
					</OPTINFO>       
]]


	inout_transaction_list[#inout_transaction_list+1] = transaction
	inout_position_map[option_symbol] = position

	create_position_for_underlying_from_option(cur_transaction, ticker, description_name, option_type_str, inout_position_map, ticker_company_map)
end



local function generate_option_sell(cur_transaction, is_to_open, inout_transaction_list, inout_position_map, ticker_company_map)

	local ticker, exp_year_str, exp_month_str, exp_day_str, strike_price_str, put_or_call_str = split_option_components(cur_transaction)


	-- 20240102
	local trade_date_str = compute_transaction_date_YYYYMMDD( extract_transaction_date(cur_transaction) )
	-- XOM20240719P00105000
	local option_symbol = compute_option_symbol(ticker, exp_year_str, exp_month_str, exp_day_str, strike_price_str, put_or_call_str)
	-- PUT EXXON MOBIL CORP $105 EXP 07/19/24
	local description_name =  cur_transaction["Description"]

	-- Quantity may have commas and negative signs. SEE Finance seems to be okay with me passing these straight through.
	local units_str = cur_transaction["Quantity"]
	-- This has the currency symbol, and potentially commas, and periods. Again, SEE Finance seems to handle that fine.
	local unit_price_str = cur_transaction["Price"]
	local fee_str = cur_transaction["Fees & Comm"]
	local total_amount_str = cur_transaction["Amount"]

	local opt_sell_type = "SELLTOCLOSE"
	if is_to_open then
		opt_sell_type = "SELLTOOPEN"
	end

	local human_friendly_symbol = cur_transaction["Symbol"]	

	local transaction = [[
					<SELLOPT>
						<INVSELL>
							<INVTRAN>
								<DTTRADE>]] .. trade_date_str .. [[</DTTRADE>
								<MEMO>]] .. description_name .. [[</MEMO>
                            </INVTRAN>							
							<SECID>
								<UNIQUEID>]] .. option_symbol .. [[</UNIQUEID>
							</SECID>

							<UNITS>]] .. units_str .. [[</UNITS>
							<UNITPRICE>]] .. unit_price_str .. [[</UNITPRICE>
							<COMMISSION>]] .. fee_str .. [[</COMMISSION>
							<TOTAL>]] .. total_amount_str .. [[</TOTAL>
						</INVSELL>
						<OPTSELLTYPE>]] .. opt_sell_type .. [[</OPTSELLTYPE>
					</SELLOPT>
]]

	local option_type_str
	if put_or_call_str == "P" then
		option_type_str = "PUT"
	elseif put_or_call_str == "C" then
		option_type_str = "CALL"
	else
		assert(false, "Value in string should have been C or P")
	end

	local expire_date = exp_year_str .. exp_month_str .. exp_day_str

	local shares_per_contract_str = get_shares_per_contract(ticker)


	-- I have 2 problems with specifying the underlying:
	-- 1. The OFX specfication wants me to to:
	-- <SECID> <UNIQUEID>123456789</UNIQUEID> <UNIQUETYPE>CUSIP</UNIQUETYPE> </SECID>
	-- But Schwab isn't giving the CUSIPs in their files, and there doesn't seem to be a public database with all the CUSIPs.
	-- It looks like you are expected to pay money to get access to the CUSIPs.
	-- The docs don't show any other supported values for <UNIQUETYPE> other than CUSIP.
	-- I searched hard, and I found somebody using OTHER, and somebody using TICKER, but I presume it will be extremely implementation dependent.
	--
	-- 2. If I use the underyling ticker, SEE Finance seems to have a weird bug where if I do this, the underlying will not get imported into the Portfolio->Stocks list.
	-- I was banging my head on this for hours, trying to figure out why none of my stocks were getting imported.
	-- Ironically, SEE Finance does actually list the stock's ticker in the option's underlying Info. So it almost works.
	-- But it is still too broken for me to do this. Maybe I can ask SEE Finance to fix this?
	-- For now, I will leave the underlying blank.

	--						<UNIQUEID>]] .. ticker .. [[</UNIQUEID> <!--CUSIP for the underlying stock -->

	local position = [[
					<OPTINFO>
						<SECINFO>
							<SECID>
								<UNIQUEID>]] .. option_symbol .. [[</UNIQUEID>
							</SECID>
							<SECNAME>]] .. human_friendly_symbol .. [[</SECNAME> 

							<!-- The docs imply that is might be the ticker of the underlying, but SEE Finance using it as the option identifer. -->
							<TICKER>]] .. option_symbol .. [[</TICKER>
						</SECINFO>
						<OPTTYPE>]] .. option_type_str .. [[</OPTTYPE> 
						<STRIKEPRICE>]] .. strike_price_str .. [[</STRIKEPRICE>

						<DTEXPIRE>]] .. expire_date .. [[</DTEXPIRE> 
						<SHPERCTRCT>]] .. shares_per_contract_str .. [[</SHPERCTRCT> 

						<!-- I think this section is supposed to be for the underlying -->
						<SECID>
							<UNIQUEID>]] .. ticker .. [[</UNIQUEID>
						</SECID>
					</OPTINFO>       
]]

	inout_transaction_list[#inout_transaction_list+1] = transaction
	inout_position_map[option_symbol] = position


	create_position_for_underlying_from_option(cur_transaction, ticker, description_name, option_type_str, inout_position_map, ticker_company_map)

end



local function generate_option_assigned_exercised_expired(cur_transaction, which_action, inout_transaction_list, inout_position_map, ticker_company_map)

	local ticker, exp_year_str, exp_month_str, exp_day_str, strike_price_str, put_or_call_str = split_option_components(cur_transaction)


	-- 20240102
	local trade_date_str = compute_transaction_date_YYYYMMDD( extract_transaction_date(cur_transaction) )
	-- XOM20240719P00105000
	local option_symbol = compute_option_symbol(ticker, exp_year_str, exp_month_str, exp_day_str, strike_price_str, put_or_call_str)
	-- PUT EXXON MOBIL CORP $105 EXP 07/19/24
	local description_name =  cur_transaction["Description"]

	-- Quantity may have commas and negative signs. SEE Finance seems to be okay with me passing these straight through.
	local units_str = cur_transaction["Quantity"]

	local opt_action
	if which_action == "Assigned" then
		opt_action = "ASSIGN"
	elseif which_action == "Exchange or Exercise" then
		opt_action = "EXERCISE"
	elseif which_action == "Expired" then
		opt_action = "EXPIRE"
	else
		assert(false, "Unexpected value for which_action")
	end

	local human_friendly_symbol = cur_transaction["Symbol"]	


	local transaction = [[
					<CLOSUREOPT>
							<INVTRAN>
								<DTTRADE>]] .. trade_date_str .. [[</DTTRADE>
								<MEMO>]] .. which_action .. ": " .. description_name .. [[</MEMO>
                            </INVTRAN>							
							<SECID>
								<UNIQUEID>]] .. option_symbol .. [[</UNIQUEID>
							</SECID>

							<UNITS>]] .. units_str .. [[</UNITS>
							<OPTACTION>]] .. opt_action .. [[</OPTACTION>
					</CLOSUREOPT>
]]


	local option_type_str
	if put_or_call_str == "P" then
		option_type_str = "PUT"
	elseif put_or_call_str == "C" then
		option_type_str = "CALL"
	else
		assert(false, "Value in string should have been C or P")
	end

	local expire_date = exp_year_str .. exp_month_str .. exp_day_str

	local shares_per_contract_str = get_shares_per_contract(ticker)


	-- I originally commented this out because I worried the data might be missing since this is a close-out case.
	-- I speculated that this data would get filled in better during the initial order creation.
	-- But I in actual testing, I had data sets where the creation was missing, ultimately leading to missing positions.
	-- So check for nil and only add if not already in the map. 
	if nil == inout_position_map[option_symbol] then
		local position = [[
					<OPTINFO>
						<SECINFO>
							<SECID> <!--Security ID-->
								<UNIQUEID>]] .. option_symbol .. [[</UNIQUEID><!--CUSIP for the option -->
							</SECID>
							<SECNAME>]] .. human_friendly_symbol .. [[</SECNAME> 

							<!-- The docs imply that is might be the ticker of the underlying, but SEE Finance using it as the option identifer. -->
							<TICKER>]] .. option_symbol .. [[</TICKER> <!--Ticker symbol-->
						</SECINFO>
						<OPTTYPE>]] .. option_type_str .. [[</OPTTYPE> 
						<STRIKEPRICE>]] .. strike_price_str .. [[</STRIKEPRICE>

						<DTEXPIRE>]] .. expire_date .. [[</DTEXPIRE> 
						<SHPERCTRCT>]] .. shares_per_contract_str .. [[</SHPERCTRCT> <!--100 shares per contract--> 

						<!-- I think this section is supposed to be for the underlying -->
						<SECID> <!--Security ID-->
							<UNIQUEID>]] .. ticker .. [[</UNIQUEID><!--CUSIP for the underlying stock -->
							<!--
								<ASSETCLASS>LARGESTOCK</ASSETCLASS>
							-->

						</SECID>
					</OPTINFO>       
]]
		inout_position_map[option_symbol] = position
		create_position_for_underlying_from_option(cur_transaction, ticker, description_name, option_type_str, inout_position_map, ticker_company_map)
	end

	inout_transaction_list[#inout_transaction_list+1] = transaction

end

local function generate_bond_buy(cur_transaction, inout_transaction_list, inout_position_map, ticker_company_map)
	-- 20240102
	local trade_date_str = compute_transaction_date_YYYYMMDD( extract_transaction_date(cur_transaction) )
	-- 912797KP1
	local ticker_symbol = cur_transaction["Symbol"]

	-- US TREASURY BILL24U S T BILL DUE 07/16/24
	-- TDA TRAN - BUY TRADE (912797KN6), UNITED STATES TREASURY BILLS, 0%, due 07/09/2024 Bought 10M @99.1794
	local description_name =  cur_transaction["Description"]



	-- 20240102
	local trade_date_str = compute_transaction_date_YYYYMMDD( extract_transaction_date(cur_transaction) )
	-- XOM
	local ticker_symbol = cur_transaction["Symbol"]

	-- Quantity may have commas and negative signs. SEE Finance seems to be okay with me passing these straight through.
	local units_str = cur_transaction["Quantity"]
	-- This has the currency symbol, and potentially commas, and periods. Again, SEE Finance seems to handle that fine.
	local unit_price_str = cur_transaction["Price"]
	local fee_str = cur_transaction["Fees & Comm"]
	local total_amount_str = cur_transaction["Amount"]

	local buy_type = "BUY"
	-- If the description contains Bought to Cover
	-- "TDA TRAN - Bought to Cover 100 (HOG) @45.0000"
	-- then BUYTOCOVER
	if string.match(description_name, "Bought to Cover") then
		buy_type = "BUYTOCOVER"
	end

	local debt_type = "COUPON"
	if string.match(description_name, "BILL") then
		debt_type = "ZERO"
	end

	local par_value = ""
	local debt_class = ""
	local asset_class = ""
	-- US TREASURY or UNITED STATES TREASURY
	if string.match(description_name, "S TREASURY") then
		par_value = "100.0"
		debt_class = "TREASURY"
		asset_class = "DOMESTICBOND"

		-- I think Schwab has messed up the quantity.
		-- But this is confusing.
		-- Example: If you buy $10,000 worth of T-Bills
		-- 1. The first confusing thing is that T-Bills must be bought in increments of $1000 (at auction).
		-- So this would imply you need to buy 10 quantity ($10,000/$1,000 = 10).
		-- 2. But the par value of a T-Bill seems to be $100 (i.e. the reported price per unit is something like $99.17).
		-- So this would imply that the quantity shoud be $10,000/$100 = 100.
		-- 3. But Schwab reports the quantity as 10,000 in this case.
		-- I think Schwab's value is the most wrong.
		-- Since finance software likes to compute their own values and bases everything on the price per unit,
		-- I think the correct value needs to be #2 (divide by 100).
		-- use string.gsub to remove the commas. It returns two values, one is the converted string, and the other is the count of conversions.
		-- UPDATE2: I've disabled the adjustment because I think once I define PARVALUE, SEE Finance automatically adjusts everything correctly,
		-- and my adjustment after that screws up everything.
		-- So I think the real solution is I need to define PARVALUE for all bonds, but Schwab doesn't give me that information.
		-- I suspect the SEE Finance implicit default is $1.00.
		--[[
		local units_str_without_comma = string.gsub(units_str, ",", "")
		local units_num = tonumber(units_str_without_comma)
		local fixed_units = units_num / 100.0
		units_str = tostring(fixed_units)
		--]]
	end

	local maturity_date = ""

	local security_name
	-- US TREASURY BILL24U S T BILL DUE 07/16/24
	-- or
	-- TDA TRAN - BUY TRADE (912797JV0), UNITED STATES TREASURY BILLS, 0%, due 05/07/2024 Bought 10M @99.1787
	local lead_in_str = "TDA TRAN %- BUY TRADE %(" .. ticker_symbol .. "%)%, "
	--print("lead in", lead_in_str)
	--print("description_name", description_name)
	local extracted_security_name = string.match(description_name, lead_in_str .. "(.*) Bought ")
	--local extracted_security_name = string.match(description_name, "TDA TRAN %- BUY TRADE %(%w+%)%, (.*) Bought ")
	--print("bond name", extracted_security_name)

	if extracted_security_name then
		security_name = extracted_security_name
		--print("extracted_security_name", security_name)
		local m,d,y = string.match(security_name, "due (%d%d)/(%d%d)/(%d%d%d%d)")
		maturity_date = compute_transaction_date_YYYYMMDD(y,m,d)
		
	else
		security_name = description_name
		--print("security_name", security_name)
		local m,d,y = string.match(security_name, "DUE (%d%d)/(%d%d)/(%d%d)")
		y="20"..y
		maturity_date = compute_transaction_date_YYYYMMDD(y,m,d)
	end
	
	-- Lookup the company name by ticker in our outside database.
	-- If the entry exists, prefer the database entry because the Schwab data isn't very good.
	local db_entry = ticker_company_map[ticker_symbol]
	if db_entry then
		local company_name = db_entry.name
		if company_name and company_name ~= "" then
			security_name = company_name
--			print("Found ticker: " .. ticker_symbol .. " with company name: " .. company_name .. " in database")
		else
--			print("Did not find company_name for ticker: " .. ticker_symbol .. " in database")
		end
	else
--		print("Did not find database entry for ticker: " .. ticker_symbol)
	end
	

	local transaction = [[
					<BUYDEBT>
						<INVBUY>
							<INVTRAN>
								<DTTRADE>]] .. trade_date_str .. [[</DTTRADE>
								<MEMO>]] ..  "Buy bond: " .. description_name .. [[</MEMO>
                            </INVTRAN>							
							<SECID>
								<UNIQUEID>]] .. ticker_symbol .. [[</UNIQUEID>
							</SECID>

							<UNITS>]] .. units_str .. [[</UNITS>
							<UNITPRICE>]] .. unit_price_str .. [[</UNITPRICE>
							<COMMISSION>]] .. fee_str .. [[</COMMISSION>
							<TOTAL>]] .. total_amount_str .. [[</TOTAL>
						</INVBUY>
						<BUYTYPE>]] .. buy_type .. [[</BUYTYPE>
					</BUYDEBT>
]]

	local position = [[
					<DEBTINFO>
						<SECINFO>
							<SECID> <!--Security ID-->
								<UNIQUEID>]] .. ticker_symbol .. [[</UNIQUEID>
							</SECID>
							<SECNAME>]] .. security_name .. [[</SECNAME> 
							<TICKER>]] .. ticker_symbol .. [[</TICKER>
						</SECINFO>
						<DEBTTYPE>]] .. debt_type .. [[</DEBTTYPE>
						<PARVALUE>]] .. par_value .. [[</PARVALUE>
						<DTMAT>]] .. maturity_date .. [[</DTMAT>
						<DEBTCLASS>]] .. debt_class .. [[</DEBTCLASS>
						<ASSETCLASS>]] .. asset_class .. [[</ASSETCLASS>

					</DEBTINFO>       
]]


	inout_transaction_list[#inout_transaction_list+1] = transaction
	inout_position_map[ticker_symbol] = position

end

local function generate_equity_buy(cur_transaction, inout_transaction_list, inout_position_map, ticker_company_map)
	-- EXXON MOBIL CORP
	local description_name =  cur_transaction["Description"]

	-- The Schwab schema doesn't have seperate types for bonds vs. equities.
	-- T-Bills are popular right now since yields are the highest they've been in decades and the yield curve is inverted, so I want to handle those.
	-- This heuristic may provide incorrect results if a stock or ETF matches this filter.
	if string.match(description_name, "UNITED STATES TREASURY BILL")
		or string.match(description_name, "US TREASURY BILL") 
		or string.match(description_name, "UNITED STATES TREASURY BOND")
		or string.match(description_name, "US TREASURY BOND") 
		or string.match(description_name, "UNITED STATES TREASURY NOTE")
		or string.match(description_name, "US TREASURY NOTE") 
	then
		generate_bond_buy(cur_transaction, inout_transaction_list, inout_position_map, ticker_company_map)
		return
	end


	-- 20240102
	local trade_date_str = compute_transaction_date_YYYYMMDD( extract_transaction_date(cur_transaction) )
	-- XOM
	local ticker_symbol = cur_transaction["Symbol"]

	-- Quantity may have commas and negative signs. SEE Finance seems to be okay with me passing these straight through.
	local units_str = cur_transaction["Quantity"]
	-- This has the currency symbol, and potentially commas, and periods. Again, SEE Finance seems to handle that fine.
	local unit_price_str = cur_transaction["Price"]
	local fee_str = cur_transaction["Fees & Comm"]
	local total_amount_str = cur_transaction["Amount"]

	local buy_type = "BUY"
	-- If the description contains Bought to Cover
	-- "TDA TRAN - Bought to Cover 100 (HOG) @45.0000"
	-- then BUYTOCOVER
	if string.match(description_name, "Bought to Cover") then
		buy_type = "BUYTOCOVER"
	end


	local transaction = [[
					<BUYSTOCK>
						<INVBUY>
							<INVTRAN>
								<DTTRADE>]] .. trade_date_str .. [[</DTTRADE>
                            </INVTRAN>							
							<SECID>
								<UNIQUEID>]] .. ticker_symbol .. [[</UNIQUEID>
							</SECID>

							<UNITS>]] .. units_str .. [[</UNITS>
							<UNITPRICE>]] .. unit_price_str .. [[</UNITPRICE>
							<COMMISSION>]] .. fee_str .. [[</COMMISSION>
							<TOTAL>]] .. total_amount_str .. [[</TOTAL>
						</INVBUY>
						<BUYTYPE>]] .. buy_type .. [[</BUYTYPE>
					</BUYSTOCK>
]]


	-- Description for SNSXX is not good. Might be because a mutual fund or money market.
	-- "TDA TRAN - Bought 75000 (SNSXX) @1.0000"
	-- Don't allow this to be used. I rather have blank.
	local security_name = description_name
	if string.match(description_name, "Bought %d+") then
		--print("override name", description_name)
		security_name = ticker_symbol
	end

	-- Lookup the company name by ticker in our outside database.
	-- If the entry exists, prefer the database entry because the Schwab data isn't very good.
	local db_entry = ticker_company_map[ticker_symbol]
	if db_entry then
		local company_name = db_entry.name
		if company_name and company_name ~= "" then
			security_name = company_name
--			print("Found ticker: " .. ticker_symbol .. " with company name: " .. company_name .. " in database")
		else
--			print("Did not find company_name for ticker: " .. ticker_symbol .. " in database")
		end
	else
--		print("Did not find database entry for ticker: " .. ticker_symbol)
	end


	local position = [[
					<STOCKINFO>
						<SECINFO>
							<SECID> <!--Security ID-->
								<UNIQUEID>]] .. ticker_symbol .. [[</UNIQUEID>
							</SECID>
							<SECNAME>]] .. security_name .. [[</SECNAME> 
							<TICKER>]] .. ticker_symbol .. [[</TICKER>
						</SECINFO>
							<!--
								<ASSETCLASS>LARGESTOCK</ASSETCLASS>
							-->

					</STOCKINFO>       
]]


	inout_transaction_list[#inout_transaction_list+1] = transaction
	inout_position_map[ticker_symbol] = position

end





local function generate_bond_sell(cur_transaction, inout_transaction_list, inout_position_map, ticker_company_map)
	--[[
    {
      "Date": "01/16/2024",
      "Action": "Sell",
      "Symbol": "912797HZ3",
      "Description": "TDA TRAN - BONDS - REDEMPTION (912797HZ3), UNITED STATES TREASURY BILLS, 0%, due 01/16/2024 Sold 10M @100.0000",
      "Quantity": "10,000",
      "Price": "$100.00",
      "Fees & Comm": "",
      "Amount": "$10,000.00"
    },
--]]
	local description_name =  cur_transaction["Description"]



	-- 20240102
	local trade_date_str = compute_transaction_date_YYYYMMDD( extract_transaction_date(cur_transaction) )
	-- XOM
	local ticker_symbol = cur_transaction["Symbol"]

	-- Quantity may have commas and negative signs. SEE Finance seems to be okay with me passing these straight through.
	local units_str = cur_transaction["Quantity"]
	-- This has the currency symbol, and potentially commas, and periods. Again, SEE Finance seems to handle that fine.
	local unit_price_str = cur_transaction["Price"]
	local fee_str = cur_transaction["Fees & Comm"]
	local total_amount_str = cur_transaction["Amount"]

	-- SELLSHORT is now handled separately in its own function.
	local sell_type = "SELL"



	local debt_type = "COUPON"
	if string.match(description_name, "BILL") then
		debt_type = "ZERO"
	end

	local par_value = ""
	local debt_class = ""
	local asset_class = ""
	-- US TREASURY or UNITED STATES TREASURY
	if string.match(description_name, "S TREASURY") then
		par_value = "100.0"
		debt_class = "TREASURY"
		asset_class = "DOMESTICBOND"

		-- I think Schwab has messed up the quantity.
		-- But this is confusing.
		-- Example: If you buy $10,000 worth of T-Bills
		-- 1. The first confusing thing is that T-Bills must be bought in increments of $1000 (at auction).
		-- So this would imply you need to buy 10 quantity ($10,000/$1,000 = 10).
		-- 2. But the par value of a T-Bill seems to be $100 (i.e. the reported price per unit is something like $99.17).
		-- So this would imply that the quantity shoud be $10,000/$100 = 100.
		-- 3. But Schwab reports the quantity as 10,000 in this case.
		-- I think Schwab's value is the most wrong.
		-- Since finance software likes to compute their own values and bases everything on the price per unit,
		-- I think the correct value needs to be #2 (divide by 100).
		-- use string.gsub to remove the commas. It returns two values, one is the converted string, and the other is the count of conversions.
		-- UPDATE2: I've disabled the adjustment because I think once I define PARVALUE, SEE Finance automatically adjusts everything correctly,
		-- and my adjustment after that screws up everything.
		-- So I think the real solution is I need to define PARVALUE for all bonds, but Schwab doesn't give me that information.
		-- I suspect the SEE Finance implicit default is $1.00.
		--[[
		local units_str_without_comma = string.gsub(units_str, ",", "")
		local units_num = tonumber(units_str_without_comma)
		local fixed_units = units_num / 100.0
		units_str = tostring(fixed_units)
		--]]
	end

	local maturity_date = ""

	local security_name
	-- FIXME: I don't have any examples of selling a treasury before maturity.
	-- TDA TRAN - BONDS - REDEMPTION (912797HZ3), UNITED STATES TREASURY BILLS, 0%, due 01/16/2024 Sold 10M @100.0000
	local lead_in_str = "TDA TRAN %- BONDS %- %w+ %(" .. ticker_symbol .. "%)%, "
	--print("lead in", lead_in_str)
	--print("description_name", description_name)
	local extracted_security_name = string.match(description_name, lead_in_str .. "(.*) Sold ")
	--print("bond name", extracted_security_name)

	if extracted_security_name then
		security_name = extracted_security_name
		--print("extracted_security_name", security_name)
		local m,d,y = string.match(security_name, "due (%d%d)/(%d%d)/(%d%d%d%d)")
		maturity_date = compute_transaction_date_YYYYMMDD(y,m,d)
	end
	
	

	local transaction = [[
					<SELLDEBT>
						<INVSELL>
							<INVTRAN>
								<DTTRADE>]] .. trade_date_str .. [[</DTTRADE>
								<MEMO>]] ..  "Sell bond: " .. description_name .. [[</MEMO>
                            </INVTRAN>							
							<SECID>
								<UNIQUEID>]] .. ticker_symbol .. [[</UNIQUEID>
							</SECID>

							<UNITS>]] .. units_str .. [[</UNITS>
							<UNITPRICE>]] .. unit_price_str .. [[</UNITPRICE>
							<COMMISSION>]] .. fee_str .. [[</COMMISSION>
							<TOTAL>]] .. total_amount_str .. [[</TOTAL>
						</INVSELL>
						<SELLTYPE>]] .. sell_type .. [[</SELLTYPE>
					</SELLDEBT>
]]




	-- There are a few cases where the description isn't a clean equity identifier, so I don't want to add it to the database.
	-- My assumption is that the buy should have already created the entry.
	-- And since I now have a separate SELLSHORT function, I don't need to worry about that case here.
	-- UPDATE: I originally commented this out because I worried the data might be missing since this is a close-out case.
	-- I speculated that this data would get filled in better during the initial order creation.
	-- But I in actual testing, I had data sets where the creation was missing, ultimately leading to missing positions.
	-- So check for nil and only add if not already in the map. 
	if nil == inout_position_map[ticker_symbol] then
		local db_entry = ticker_company_map[ticker_symbol]
		if db_entry then
			local company_name = db_entry.name
			if company_name and company_name ~= "" then
				security_name = company_name
				--	print("Found ticker: " .. ticker_symbol .. " with company name: " .. company_name .. " in database")
			else
				--	print("Did not find company_name for ticker: " .. ticker_symbol .. " in database")
			end
		else
			--	print("Did not find database entry for ticker: " .. ticker_symbol)
		end

		local position = [[
					<DEBTINFO>
						<SECINFO>
							<SECID> <!--Security ID-->
								<UNIQUEID>]] .. ticker_symbol .. [[</UNIQUEID>
							</SECID>
							<SECNAME>]] .. security_name .. [[</SECNAME> 
							<TICKER>]] .. ticker_symbol .. [[</TICKER>
						</SECINFO>
						<DEBTTYPE>]] .. debt_type .. [[</DEBTTYPE>
						<PARVALUE>]] .. par_value .. [[</PARVALUE>
						<DTMAT>]] .. maturity_date .. [[</DTMAT>
						<DEBTCLASS>]] .. debt_class .. [[</DEBTCLASS>
						<ASSETCLASS>]] .. asset_class .. [[</ASSETCLASS>

					</DEBTINFO>       
]]
   
		inout_position_map[ticker_symbol] = position
	end

	inout_transaction_list[#inout_transaction_list+1] = transaction
end


local function generate_equity_sell(cur_transaction, inout_transaction_list, inout_position_map, ticker_company_map)
	-- EXXON MOBIL CORP
	local description_name =  cur_transaction["Description"]

	-- The Schwab schema doesn't have seperate types for bonds vs. equities.
	-- T-Bills are popular right now since yields are the highest they've been in decades and the yield curve is inverted, so I want to handle those.
	-- This heuristic may provide incorrect results if a stock or ETF matches this filter.
	if string.match(description_name, "UNITED STATES TREASURY BILL")
		or string.match(description_name, "US TREASURY BILL") 
		or string.match(description_name, "UNITED STATES TREASURY BOND")
		or string.match(description_name, "US TREASURY BOND") 
		or string.match(description_name, "UNITED STATES TREASURY NOTE")
		or string.match(description_name, "US TREASURY NOTE") 
	then
		generate_bond_sell(cur_transaction, inout_transaction_list, inout_position_map, ticker_company_map)
		return
	end




	-- 20240102
	local trade_date_str = compute_transaction_date_YYYYMMDD( extract_transaction_date(cur_transaction) )
	-- XOM
	local ticker_symbol = cur_transaction["Symbol"]

	-- Quantity may have commas and negative signs. SEE Finance seems to be okay with me passing these straight through.
	local units_str = cur_transaction["Quantity"]
	-- This has the currency symbol, and potentially commas, and periods. Again, SEE Finance seems to handle that fine.
	local unit_price_str = cur_transaction["Price"]
	local fee_str = cur_transaction["Fees & Comm"]
	local total_amount_str = cur_transaction["Amount"]

	-- SELLSHORT is now handled separately in its own function.
	local sell_type = "SELL"

	local transaction = [[
					<SELLSTOCK>
						<INVSELL>
							<INVTRAN>
								<DTTRADE>]] .. trade_date_str .. [[</DTTRADE>
                            </INVTRAN>							
							<SECID>
								<UNIQUEID>]] .. ticker_symbol .. [[</UNIQUEID>
							</SECID>

							<UNITS>]] .. units_str .. [[</UNITS>
							<UNITPRICE>]] .. unit_price_str .. [[</UNITPRICE>
							<COMMISSION>]] .. fee_str .. [[</COMMISSION>
							<TOTAL>]] .. total_amount_str .. [[</TOTAL>
						</INVSELL>
						<SELLTYPE>]] .. sell_type .. [[</SELLTYPE>
					</SELLSTOCK>
]]

	-- There are a few cases where the description isn't a clean equity identifier, so I don't want to add it to the database.
	-- My assumption is that the buy should have already created the entry.
	-- And since I now have a separate SELLSHORT function, I don't need to worry about that case here.
	-- UPDATE: I originally commented this out because I worried the data might be missing since this is a close-out case.
	-- I speculated that this data would get filled in better during the initial order creation.
	-- But I in actual testing, I had data sets where the creation was missing, ultimately leading to missing positions.
	-- So check for nil and only add if not already in the map. 
	if nil == inout_position_map[ticker_symbol] then
		local sec_name = ""
		local db_entry = ticker_company_map[ticker_symbol]
		if db_entry then
			local company_name = db_entry.name
			if company_name and company_name ~= "" then
				sec_name = company_name
				--	print("Found ticker: " .. ticker_symbol .. " with company name: " .. company_name .. " in database")
			else
				--	print("Did not find company_name for ticker: " .. ticker_symbol .. " in database")
			end
		else
			--	print("Did not find database entry for ticker: " .. ticker_symbol)
		end

		local position = [[
					<STOCKINFO>
						<SECINFO>
							<SECID> <!--Security ID-->
								<UNIQUEID>]] .. ticker_symbol .. [[</UNIQUEID><!--CUSIP for the option -->
							</SECID>
							<SECNAME>]] .. sec_name .. [[</SECNAME> 
							<TICKER>]] .. ticker_symbol .. [[</TICKER> <!--Ticker symbol-->
						</SECINFO>
							<!--
								<ASSETCLASS>LARGESTOCK</ASSETCLASS>
							-->

					</STOCKINFO>       
]]
		inout_position_map[ticker_symbol] = position
	end

	inout_transaction_list[#inout_transaction_list+1] = transaction

end


local function generate_equity_sellshort(cur_transaction, inout_transaction_list, inout_position_map, ticker_company_map)

	-- 20240102
	local trade_date_str = compute_transaction_date_YYYYMMDD( extract_transaction_date(cur_transaction) )
	-- XOM
	local ticker_symbol = cur_transaction["Symbol"]
	-- EXXON MOBIL CORP
	local description_name =  cur_transaction["Description"]

	-- Quantity may have commas and negative signs. SEE Finance seems to be okay with me passing these straight through.
	local units_str = cur_transaction["Quantity"]
	-- This has the currency symbol, and potentially commas, and periods. Again, SEE Finance seems to handle that fine.
	local unit_price_str = cur_transaction["Price"]
	local fee_str = cur_transaction["Fees & Comm"]
	local total_amount_str = cur_transaction["Amount"]

	-- This could be SELLSHORT, but I don't know if Schwab gives that info.
	local sell_type = "SELLSHORT"


	-- Description for SNSXX is not good. Might be because a mutual fund or money market.
	-- "TDA TRAN - Sold Short 100 (DIS) @92.0000"
	-- Don't allow this to be used. I rather have blank.
	local security_name = description_name
--	print("generate_equity_sellshort description_name", description_name)
	if string.match(description_name, "Sold Short %d+") then
--		print("override name", description_name)
		security_name = ticker_symbol
--		print("security_name", security_name)		
	end


	-- Lookup the company name by ticker in our outside database.
	-- If the entry exists, prefer the database entry because the Schwab data isn't very good.
	local db_entry = ticker_company_map[ticker_symbol]
	if db_entry then
		local company_name = db_entry.name
		if company_name and company_name ~= "" then
			security_name = company_name
--			print("Found ticker: " .. ticker_symbol .. " with company name: " .. company_name .. " in database")
		else
--			print("Did not find company_name for ticker: " .. ticker_symbol .. " in database")
		end
	else
--		print("Did not find database entry for ticker: " .. ticker_symbol)
	end


	local transaction = [[
					<SELLSTOCK>
						<INVSELL>
							<INVTRAN>
								<DTTRADE>]] .. trade_date_str .. [[</DTTRADE>
                            </INVTRAN>							
							<SECID>
								<UNIQUEID>]] .. ticker_symbol .. [[</UNIQUEID>
							</SECID>

							<UNITS>]] .. units_str .. [[</UNITS>
							<UNITPRICE>]] .. unit_price_str .. [[</UNITPRICE>
							<COMMISSION>]] .. fee_str .. [[</COMMISSION>
							<TOTAL>]] .. total_amount_str .. [[</TOTAL>
						</INVSELL>
						<SELLTYPE>]] .. sell_type .. [[</SELLTYPE>
					</SELLSTOCK>
]]

	local position = [[
					<STOCKINFO>
						<SECINFO>
							<SECID> <!--Security ID-->
								<UNIQUEID>]] .. ticker_symbol .. [[</UNIQUEID>
							</SECID>
							<SECNAME>]] .. security_name .. [[</SECNAME> 
							<TICKER>]] .. ticker_symbol .. [[</TICKER>
						</SECINFO>
					</STOCKINFO>       
]]


	inout_transaction_list[#inout_transaction_list+1] = transaction
	inout_position_map[ticker_symbol] = position

end


local function generate_cash_dividend_capitalgain(cur_transaction, gain_type, inout_transaction_list, inout_position_map, ticker_company_map)


	-- 20240102
	local trade_date_str = compute_transaction_date_YYYYMMDD( extract_transaction_date(cur_transaction) )

	-- TDA TRAN - ORDINARY DIVIDEND (SNSXX)
	local description_name =  cur_transaction["Description"]

	local ticker_symbol = cur_transaction["Symbol"]
	if ticker_symbol == "" or ticker_symbol == nil then
		-- Strip out the ticker from the Description
		ticker_symbol = string.match(description_name, "%((%w+)%)")
	end

	if ticker_symbol == nil or ticker_symbol == "" then
		print("WARNING: ticker_symbol is nil in generate_cash_dividend_capitalgain, description_name:", description_name)
		ticker_symbol = ""
	else

		-- I originally commented this out because I worried the data might be missing since this is a close-out case.
		-- I speculated that this data would get filled in better during the initial order creation.
		-- But I in actual testing, I had data sets where the creation was missing, ultimately leading to missing positions.
		-- So check for nil and only add if not already in the map. 
		if nil == inout_position_map[ticker_symbol] then
			local sec_name = ""
			local db_entry = ticker_company_map[ticker_symbol]
			if db_entry then
				local company_name = db_entry.name
				if company_name and company_name ~= "" then
					sec_name = company_name
					--	print("Found ticker: " .. ticker_symbol .. " with company name: " .. company_name .. " in database")
				else
					--	print("Did not find company_name for ticker: " .. ticker_symbol .. " in database")
				end
			else
				--	print("Did not find database entry for ticker: " .. ticker_symbol)
			end

			local position = [[
						<STOCKINFO>
							<SECINFO>
								<SECID> <!--Security ID-->
									<UNIQUEID>]] .. ticker_symbol .. [[</UNIQUEID><!--CUSIP for the option -->
								</SECID>
								<SECNAME>]] .. sec_name .. [[</SECNAME> 
								<TICKER>]] .. ticker_symbol .. [[</TICKER> <!--Ticker symbol-->
							</SECINFO>
								<!--
									<ASSETCLASS>LARGESTOCK</ASSETCLASS>
								-->

						</STOCKINFO>       
			]]
			inout_position_map[ticker_symbol] = position
		end
	end



	-- This has the currency symbol, and potentially commas, and periods. Again, SEE Finance seems to handle that fine.
	local total_amount_str = cur_transaction["Amount"]


	local transaction = [[
					<INCOME>
							<INVTRAN>
								<DTTRADE>]] .. trade_date_str .. [[</DTTRADE>
								<MEMO>]] .. gain_type .. ": " .. description_name .. [[</MEMO>
							</INVTRAN>							
							<SECID>
								<UNIQUEID>]] .. ticker_symbol .. [[</UNIQUEID>
							</SECID>

							<INCOMETYPE>]] .. gain_type .. [[</INCOMETYPE>
							<TOTAL>]] .. total_amount_str .. [[</TOTAL>
					</INCOME>
]]
	inout_transaction_list[#inout_transaction_list+1] = transaction




end


local function generate_bond_interest(cur_transaction, inout_transaction_list, inout_position_map, ticker_company_map)
	-- 20240102
	local trade_date_str = compute_transaction_date_YYYYMMDD( extract_transaction_date(cur_transaction) )
	-- TDA TRAN - ORDINARY DIVIDEND (SNSXX)
	local description_name =  cur_transaction["Description"]
	-- This has the currency symbol, and potentially commas, and periods. Again, SEE Finance seems to handle that fine.
	local total_amount_str = cur_transaction["Amount"]
	local action_field = cur_transaction["Action"]

	local transaction = [[
					<INCOME>
							<INVTRAN>
								<DTTRADE>]] .. trade_date_str .. [[</DTTRADE>
								<MEMO>]] .. action_field .. ": " .. description_name .. [[</MEMO>
                            </INVTRAN>							

							<INCOMETYPE>INTEREST</INCOMETYPE>
							<TOTAL>]] .. total_amount_str .. [[</TOTAL>
					</INCOME>
]]

	inout_transaction_list[#inout_transaction_list+1] = transaction
end




local function generate_reinvest_dividend(cur_transaction, inout_transaction_list, inout_position_map, ticker_company_map)

	-- 20240102
	local trade_date_str = compute_transaction_date_YYYYMMDD( extract_transaction_date(cur_transaction) )
	-- XOM
	local ticker_symbol = cur_transaction["Symbol"]
	-- EXXON MOBIL CORP
	local description_name =  cur_transaction["Description"]


	local total_amount_str = cur_transaction["Amount"]

	local action_field = cur_transaction["Action"]

	-- REINVEST was not working well for me. I get 2 events, Reinvest Dividend and Reinvest Shares.
	-- Both ignore the ticker, and the latter ignores the negative amount, so I get a double dividend.
	-- I found a couple of threads that say don't use REINVEST if you don't have a monolithic transaction.
	-- Split into INCOME and INVBUY instead.
	-- https://www.fundmanagersoftware.com/forum/viewtopic.php?f=3&t=1061
--[=[
	local transaction = [[
					<REINVEST>
							<INVTRAN>
								<DTTRADE>]] .. trade_date_str .. [[</DTTRADE>
								<MEMO>]] .. action_field .. ": " .. description_name .. [[</MEMO>
                            </INVTRAN>							
							<SECID>
								<UNIQUEID>]] .. ticker_symbol .. [[</UNIQUEID>
							</SECID>

							<TOTAL>]] .. total_amount_str .. [[</TOTAL>
					</REINVEST>
]]
--]=]

	local transaction = [[
					<INCOME>
							<INVTRAN>
								<DTTRADE>]] .. trade_date_str .. [[</DTTRADE>
								<MEMO>]] .. action_field .. ": " .. description_name .. [[</MEMO>
                            </INVTRAN>
							<SECID>
								<UNIQUEID>]] .. ticker_symbol .. [[</UNIQUEID>
							</SECID>
							<INCOMETYPE>DIV</INCOMETYPE>

							<TOTAL>]] .. total_amount_str .. [[</TOTAL>
					</INCOME>
]]

	-- I originally commented this out because I worried the data might be missing since this is a close-out case.
	-- I speculated that this data would get filled in better during the initial order creation.
	-- But I in actual testing, I had data sets where the creation was missing, ultimately leading to missing positions.
	-- So check for nil and only add if not already in the map. 
	if nil == inout_position_map[ticker_symbol] then
		local sec_name = ""
		local db_entry = ticker_company_map[ticker_symbol]
		if db_entry then
			local company_name = db_entry.name
			if company_name and company_name ~= "" then
				sec_name = company_name
				--	print("Found ticker: " .. ticker_symbol .. " with company name: " .. company_name .. " in database")
			else
				--	print("Did not find company_name for ticker: " .. ticker_symbol .. " in database")
			end
		else
			--	print("Did not find database entry for ticker: " .. ticker_symbol)
		end

		local position = [[
					<STOCKINFO>
						<SECINFO>
							<SECID> <!--Security ID-->
								<UNIQUEID>]] .. ticker_symbol .. [[</UNIQUEID><!--CUSIP for the option -->
							</SECID>
							<SECNAME>]] .. sec_name .. [[</SECNAME> 
							<TICKER>]] .. ticker_symbol .. [[</TICKER> <!--Ticker symbol-->
						</SECINFO>
							<!--
								<ASSETCLASS>LARGESTOCK</ASSETCLASS>
							-->

					</STOCKINFO>       
]]
		inout_position_map[ticker_symbol] = position
	end


	inout_transaction_list[#inout_transaction_list+1] = transaction

end

local function generate_reinvest_shares(cur_transaction, inout_transaction_list, inout_position_map, ticker_company_map)

	-- 20240102
	local trade_date_str = compute_transaction_date_YYYYMMDD( extract_transaction_date(cur_transaction) )
	-- XOM
	local ticker_symbol = cur_transaction["Symbol"]
	-- TDA TRAN - QUALIFIED DIVIDEND (PAAS)
	local description_name =  cur_transaction["Description"]

	-- Quantity may have commas and negative signs. SEE Finance seems to be okay with me passing these straight through.
	local units_str = cur_transaction["Quantity"]
	-- This has the currency symbol, and potentially commas, and periods. Again, SEE Finance seems to handle that fine.
	local unit_price_str = cur_transaction["Price"]
	local total_amount_str = cur_transaction["Amount"]

	-- This could be BUYTOCOVER, but I don't know if Schwab gives that info.
	local buy_type = "BUY"

	local action_field = cur_transaction["Action"]

	
	-- REINVEST was not working well for me. I get 2 events, Reinvest Dividend and Reinvest Shares.
	-- Both ignore the ticker, and the latter ignores the negative amount, so I get a double dividend.
	-- I found a couple of threads that say don't use REINVEST if you don't have a monolithic transaction.
	-- Split into INCOME and INVBUY instead.
	-- https://www.fundmanagersoftware.com/forum/viewtopic.php?f=3&t=1061
--[=[
	local transaction = [[
					<REINVEST>
							<INVTRAN>
								<DTTRADE>]] .. trade_date_str .. [[</DTTRADE>
								<MEMO>]] .. action_field .. ": " .. description_name .. [[</MEMO>
                            </INVTRAN>							
							<SECID>
								<UNIQUEID>]] .. ticker_symbol .. [[</UNIQUEID>
							</SECID>

							<UNITS>]] .. units_str .. [[</UNITS>
							<UNITPRICE>]] .. unit_price_str .. [[</UNITPRICE>
							<TOTAL>]] .. total_amount_str .. [[</TOTAL>
					</REINVEST>
]]
--]=]

	local transaction = [[
					<BUYSTOCK>
						<INVBUY>
							<INVTRAN>
								<DTTRADE>]] .. trade_date_str .. [[</DTTRADE>
								<MEMO>]] .. action_field .. ": " .. description_name .. [[</MEMO>
                            </INVTRAN>							
							<SECID>
								<UNIQUEID>]] .. ticker_symbol .. [[</UNIQUEID>
							</SECID>

							<UNITS>]] .. units_str .. [[</UNITS>
							<UNITPRICE>]] .. unit_price_str .. [[</UNITPRICE>
							<TOTAL>]] .. total_amount_str .. [[</TOTAL>
							<BUYTYPE>BUY</BUYTYPE>
						</INVBUY>
					</BUYSTOCK>
]]


	-- I originally commented this out because I worried the data might be missing since this is a close-out case.
	-- I speculated that this data would get filled in better during the initial order creation.
	-- But I in actual testing, I had data sets where the creation was missing, ultimately leading to missing positions.
	-- So check for nil and only add if not already in the map. 
	if nil == inout_position_map[ticker_symbol] then
		local sec_name = ""
		local db_entry = ticker_company_map[ticker_symbol]
		if db_entry then
			local company_name = db_entry.name
			if company_name and company_name ~= "" then
				sec_name = company_name
				--	print("Found ticker: " .. ticker_symbol .. " with company name: " .. company_name .. " in database")
			else
				--	print("Did not find company_name for ticker: " .. ticker_symbol .. " in database")
			end
		else
			--	print("Did not find database entry for ticker: " .. ticker_symbol)
		end

		local position = [[
					<STOCKINFO>
						<SECINFO>
							<SECID> <!--Security ID-->
								<UNIQUEID>]] .. ticker_symbol .. [[</UNIQUEID><!--CUSIP for the option -->
							</SECID>
							<SECNAME>]] .. sec_name .. [[</SECNAME> 
							<TICKER>]] .. ticker_symbol .. [[</TICKER> <!--Ticker symbol-->
						</SECINFO>
							<!--
								<ASSETCLASS>LARGESTOCK</ASSETCLASS>
							-->

					</STOCKINFO>       
]]
		inout_position_map[ticker_symbol] = position
	end


	inout_transaction_list[#inout_transaction_list+1] = transaction

end

--[[
    {
      "Date": "03/15/2023",
      "Action": "Foreign Tax Reclaim",
      "Symbol": "",
      "Description": "TDA TRAN - FOREIGN TAX WITHHELD (GOLD)",
      "Quantity": "",
      "Price": "",
      "Fees & Comm": "",
      "Amount": "-$1.50"
    },
    {
      "Date": "06/17/2024",
      "Action": "Foreign Tax Paid",
      "Symbol": "GOLD",
      "Description": "BARRICK GOLD CORP F",
      "Quantity": "",
      "Price": "",
      "Fees & Comm": "",
      "Amount": "-$1.50"
    },
--]]
local function generate_foreign_tax(cur_transaction, inout_transaction_list, inout_position_map, ticker_company_map)
	-- 20240102
	local trade_date_str = compute_transaction_date_YYYYMMDD( extract_transaction_date(cur_transaction) )
	-- TDA TRAN - FOREIGN TAX WITHHELD (PAAS)
	local description_name =  cur_transaction["Description"]
	-- This has the currency symbol, and potentially commas, and periods. Again, SEE Finance seems to handle that fine.
	local total_amount_str = cur_transaction["Amount"]

	local ticker_symbol = cur_transaction["Symbol"]
	if ticker_symbol == "" or ticker_symbol == nil then
		-- Strip out the ticker from the Description
		ticker_symbol = string.match(description_name, "%((%w+)%)")
	end

	local action_field = cur_transaction["Action"]



	local transaction = [[
					<INVEXPENSE>
							<INVTRAN>
								<DTTRADE>]] .. trade_date_str .. [[</DTTRADE>
								<MEMO>]] .. action_field .. ": " .. description_name .. [[</MEMO>
                            </INVTRAN>							
							<SECID>
								<UNIQUEID>]] .. ticker_symbol .. [[</UNIQUEID>
							</SECID>

							<INCOMETYPE>MISC</INCOMETYPE>
							<TOTAL>]] .. total_amount_str .. [[</TOTAL>
							<TAXES>]] .. total_amount_str .. [[</TAXES>
					</INVEXPENSE>
]]

	inout_transaction_list[#inout_transaction_list+1] = transaction


	if ticker_symbol == nil or ticker_symbol == "" then
		print("WARNING: ticker_symbol is nil in generate_foreign_tax, description_name:", description_name)
		ticker_symbol = ""
	else

		-- I originally commented this out because I worried the data might be missing since this is a close-out case.
		-- I speculated that this data would get filled in better during the initial order creation.
		-- But I in actual testing, I had data sets where the creation was missing, ultimately leading to missing positions.
		-- So check for nil and only add if not already in the map. 
		if nil == inout_position_map[ticker_symbol] then
			local sec_name = ""
			local db_entry = ticker_company_map[ticker_symbol]
			if db_entry then
				local company_name = db_entry.name
				if company_name and company_name ~= "" then
					sec_name = company_name
					--	print("Found ticker: " .. ticker_symbol .. " with company name: " .. company_name .. " in database")
				else
					--	print("Did not find company_name for ticker: " .. ticker_symbol .. " in database")
				end
			else
				--	print("Did not find database entry for ticker: " .. ticker_symbol)
			end

			local position = [[
						<STOCKINFO>
							<SECINFO>
								<SECID> <!--Security ID-->
									<UNIQUEID>]] .. ticker_symbol .. [[</UNIQUEID><!--CUSIP for the option -->
								</SECID>
								<SECNAME>]] .. sec_name .. [[</SECNAME> 
								<TICKER>]] .. ticker_symbol .. [[</TICKER> <!--Ticker symbol-->
							</SECINFO>
								<!--
									<ASSETCLASS>LARGESTOCK</ASSETCLASS>
								-->

						</STOCKINFO>       
			]]
			inout_position_map[ticker_symbol] = position
		end
	end



end


local function generate_return_of_capital(cur_transaction, inout_transaction_list, inout_position_map, ticker_company_map)


	-- 20240102
	local trade_date_str = compute_transaction_date_YYYYMMDD( extract_transaction_date(cur_transaction) )

	-- TDA TRAN - ORDINARY DIVIDEND (SNSXX)
	local description_name =  cur_transaction["Description"]
	-- Strip out the ticker from the Description
	local ticker_symbol = string.match(description_name, "%(%w+%)")


	-- This has the currency symbol, and potentially commas, and periods. Again, SEE Finance seems to handle that fine.
	local total_amount_str = cur_transaction["Amount"]


	


	local transaction = [[
					<RETOFCAP>
							<INVTRAN>
								<DTTRADE>]] .. trade_date_str .. [[</DTTRADE>
								<MEMO>]] .. description_name .. [[</MEMO>
                            </INVTRAN>							
                            <SECID>
                                <UNIQUEID>]] .. ticker_symbol .. [[</UNIQUEID>
                            </SECID>

							<TOTAL>]] .. total_amount_str .. [[</TOTAL>
					</RETOFCAP>
]]


	inout_transaction_list[#inout_transaction_list+1] = transaction

	-- I'm very worried about the reliability of this ticker symbol.
	if ticker_symbol ~= nil and ticker_symbol ~= "" then

		-- I originally commented this out because I worried the data might be missing since this is a close-out case.
		-- I speculated that this data would get filled in better during the initial order creation.
		-- But I in actual testing, I had data sets where the creation was missing, ultimately leading to missing positions.
		-- So check for nil and only add if not already in the map. 
		if nil == inout_position_map[ticker_symbol] then
		local sec_name = ""
		local db_entry = ticker_company_map[ticker_symbol]
		if db_entry then
			local company_name = db_entry.name
			if company_name and company_name ~= "" then
				sec_name = company_name
				--	print("Found ticker: " .. ticker_symbol .. " with company name: " .. company_name .. " in database")
			else
				--	print("Did not find company_name for ticker: " .. ticker_symbol .. " in database")
			end
		else
			--	print("Did not find database entry for ticker: " .. ticker_symbol)
		end

			local position = [[
						<STOCKINFO>
							<SECINFO>
								<SECID> <!--Security ID-->
									<UNIQUEID>]] .. ticker_symbol .. [[</UNIQUEID><!--CUSIP for the option -->
								</SECID>
								<SECNAME>]] .. sec_name .. [[</SECNAME> 
								<TICKER>]] .. ticker_symbol .. [[</TICKER> <!--Ticker symbol-->
							</SECINFO>
								<!--
									<ASSETCLASS>LARGESTOCK</ASSETCLASS>
								-->

						</STOCKINFO>       
]]
			inout_position_map[ticker_symbol] = position
		end
	end
end



local function generate_full_redemption(cur_transaction, inout_transaction_list, inout_position_map, ticker_company_map)

	-- 20240102
	local trade_date_str = compute_transaction_date_YYYYMMDD( extract_transaction_date(cur_transaction) )
	-- 912797JX6
	local ticker_symbol = cur_transaction["Symbol"]
	-- US TREASURY BILXXX**MATURED**
	local description_name =  cur_transaction["Description"]

	-- Quantity may have commas and negative signs. SEE Finance seems to be okay with me passing these straight through.
	local units_str = cur_transaction["Quantity"]
	-- This has the currency symbol, and potentially commas, and periods. Again, SEE Finance seems to handle that fine.


	local action_field = cur_transaction["Action"]


	-- US TREASURY or UNITED STATES TREASURY
	if string.match(description_name, "S TREASURY") then

		-- I think Schwab has messed up the quantity.
		-- But this is confusing.
		-- Example: If you buy $10,000 worth of T-Bills
		-- 1. The first confusing thing is that T-Bills must be bought in increments of $1000 (at auction).
		-- So this would imply you need to buy 10 quantity ($10,000/$1,000 = 10).
		-- 2. But the par value of a T-Bill seems to be $100 (i.e. the reported price per unit is something like $99.17).
		-- So this would imply that the quantity shoud be $10,000/$100 = 100.
		-- 3. But Schwab reports the quantity as 10,000 in this case.
		-- I think Schwab's value is the most wrong.
		-- Since finance software likes to compute their own values and bases everything on the price per unit,
		-- I think the correct value needs to be #2 (divide by 100).
		-- use string.gsub to remove the commas. It returns two values, one is the converted string, and the other is the count of conversions.
		-- UPDATE: I disabled this on the redemptions because my numbers are getting screwed up again.
		-- My theory is that once I reported the par-value in the position info, SEE Finance may be auto-calculating the adjustment on the redemption.
		-- Thus my shares of 200.00 are getting converted to 2.
		-- So I need to disable the adjustment here. I don't understand why Buy doesn't get the same adjustment.
		-- UPDATE2: I've disabled the adjustment because I think once I define PARVALUE, SEE Finance automatically adjusts everything correctly,
		-- and my adjustment after that screws up everything.
		-- So I think the real solution is I need to define PARVALUE for all bonds, but Schwab doesn't give me that information.
		-- I suspect the SEE Finance implicit default is $1.00.
		--[[
		local units_str_without_comma = string.gsub(units_str, ",", "")
		local units_num = tonumber(units_str_without_comma)
		local fixed_units = units_num / 100.0
		units_str = tostring(fixed_units)
		--]]

	end



	local transaction = [[
					<SELLDEBT>
						<INVSELL>
							<INVTRAN>
								<DTTRADE>]] .. trade_date_str .. [[</DTTRADE>
								<MEMO>]] .. action_field .. ": " .. description_name .. [[</MEMO>
                            </INVTRAN>							
							<SECID>
								<UNIQUEID>]] .. ticker_symbol .. [[</UNIQUEID>
							</SECID>

							<UNITS>]] .. units_str .. [[</UNITS>
						</INVSELL>
						<SELLREASON>MATURITY</SELLREASON>
					</SELLDEBT>
]]


	-- I originally commented this out because I worried the data might be missing since this is a close-out case.
	-- I speculated that this data would get filled in better during the initial order creation.
	-- But I in actual testing, I had data sets where the creation was missing, ultimately leading to missing positions.
	-- So check for nil and only add if not already in the map. 
	if nil == inout_position_map[ticker_symbol] then
		local debt_type = "COUPON"
		if string.match(description_name, "BIL") then
			debt_type = "ZERO"
		end

		local par_value = ""
		local debt_class = ""
		local asset_class = ""
		-- US TREASURY or UNITED STATES TREASURY
		if string.match(description_name, "S TREASURY") then
			par_value = "100.0"
			debt_class = "TREASURY"
			asset_class = "DOMESTICBOND"
		end

		-- This is the redemption event, which means it is the maturity date
		local maturity_date = trade_date_str


		--[[
    {
      "Date": "05/21/2024",
      "Action": "Full Redemption",
      "Symbol": "912797JX6",
      "Description": "US TREASURY BILXXX**MATURED**",
      "Quantity": "-1,000",
      "Price": "",
      "Fees & Comm": "",
      "Amount": ""
    },
	--]]

			local security_name = description_name
			-- "US TREASURY BILXXX**MATURED**"
			--print("description_name", description_name)
			local extracted_security_name = string.match(description_name, "(.+)%*%*MATURED%*%*")
			--print("bond name", extracted_security_name)

			if extracted_security_name then
				security_name = extracted_security_name
			end

		local position = [[
					<DEBTINFO>
						<SECINFO>
							<SECID> <!--Security ID-->
								<UNIQUEID>]] .. ticker_symbol .. [[</UNIQUEID>
							</SECID>
							<SECNAME>]] .. security_name .. [[</SECNAME> 
							<TICKER>]] .. ticker_symbol .. [[</TICKER>
						</SECINFO>
						<DEBTTYPE>]] .. debt_type .. [[</DEBTTYPE>
						<PARVALUE>]] .. par_value .. [[</PARVALUE>
						<DTMAT>]] .. maturity_date .. [[</DTMAT>
						<DEBTCLASS>]] .. debt_class .. [[</DEBTCLASS>
						<ASSETCLASS>]] .. asset_class .. [[</ASSETCLASS>

					</DEBTINFO>       
]]
		inout_position_map[ticker_symbol] = position
	end

	inout_transaction_list[#inout_transaction_list+1] = transaction

end


local function generate_full_redemption_adj(cur_transaction, inout_transaction_list, inout_position_map, ticker_company_map)

	-- 20240102
	local trade_date_str = compute_transaction_date_YYYYMMDD( extract_transaction_date(cur_transaction) )
	-- 912797JX6
	local ticker_symbol = cur_transaction["Symbol"]
	-- US TREASURY BILXXX**MATURED**
	local description_name =  cur_transaction["Description"]

	local total_amount_str = cur_transaction["Amount"]

	local transaction = [[
					<SELLDEBT>
						<INVSELL>
							<INVTRAN>
								<DTTRADE>]] .. trade_date_str .. [[</DTTRADE>
								<MEMO>]] .. description_name .. [[</MEMO>
                            </INVTRAN>							
							<SECID>
								<UNIQUEID>]] .. ticker_symbol .. [[</UNIQUEID>
							</SECID>

							<TOTAL>]] .. total_amount_str .. [[</TOTAL>
						</INVSELL>
						<SELLREASON>MATURITY</SELLREASON>
					</SELLDEBT>
]]

	-- I originally commented this out because I worried the data might be missing since this is a close-out case.
	-- I speculated that this data would get filled in better during the initial order creation.
	-- But I in actual testing, I had data sets where the creation was missing, ultimately leading to missing positions.
	-- So check for nil and only add if not already in the map. 
	if nil == inout_position_map[ticker_symbol] then
			local debt_type = "COUPON"
			if string.match(description_name, "BIL") then
				debt_type = "ZERO"
			end

			local par_value = ""
			local debt_class = ""
			local asset_class = ""
			if string.match(description_name, "US TREASURY") then
				par_value = "100.0"
				debt_class = "TREASURY"
				asset_class = "DOMESTICBOND"
			end
			--[[
    {
      "Date": "05/21/2024",
      "Action": "Full Redemption Adj",
      "Symbol": "912797JX6",
      "Description": "US TREASURY BILXXX**MATURED**",
      "Quantity": "",
      "Price": "",
      "Fees & Comm": "",
      "Amount": "$1,000.00"
    },

		--]]
	
			-- This is the redemption event, which means it is the maturity date
			local maturity_date = trade_date_str


			local security_name = description_name
			-- "US TREASURY BILXXX**MATURED**"
			--print("description_name", description_name)
			local extracted_security_name = string.match(description_name, "(.+)%*%*MATURED%*%*")
			--print("bond name", extracted_security_name)

			if extracted_security_name then
				security_name = extracted_security_name
			end
	

			position = [[
					<DEBTINFO>
						<SECINFO>
							<SECID> <!--Security ID-->
								<UNIQUEID>]] .. ticker_symbol .. [[</UNIQUEID>
							</SECID>
							<SECNAME>]] .. security_name .. [[</SECNAME> 
							<TICKER>]] .. ticker_symbol .. [[</TICKER>
						</SECINFO>
						<DEBTTYPE>]] .. debt_type .. [[</DEBTTYPE>
						<PARVALUE>]] .. par_value .. [[</PARVALUE>
						<DTMAT>]] .. maturity_date .. [[</DTMAT>
						<DEBTCLASS>]] .. debt_class .. [[</DEBTCLASS>
						<ASSETCLASS>]] .. asset_class .. [[</ASSETCLASS>

					</DEBTINFO>       
]]
		inout_position_map[ticker_symbol] = position
	end

	inout_transaction_list[#inout_transaction_list+1] = transaction

end



		-- HACK: Special case handling.
		-- Schwab is generating 2 separate events for bond maturity.
		-- I first see "Full Redemption Adj", followed immediately by "Full Redemption"
		--[[     {
      "Date": "06/11/2024",
      "Action": "Full Redemption Adj",
      "Symbol": "912797KE6",
      "Description": "US TREASURY BILXXX**MATURED**",
      "Quantity": "",
      "Price": "",
      "Fees & Comm": "",
      "Amount": "$10,000.00"
    },
    {
      "Date": "06/11/2024",
      "Action": "Full Redemption",
      "Symbol": "912797KE6",
      "Description": "US TREASURY BILXXX**MATURED**",
      "Quantity": "-10,000",
      "Price": "",
      "Fees & Comm": "",
      "Amount": ""
    },
	--]]
		-- The former has an amount, the latter has a quantity.
		-- In addition, I think Schwab is putting the incorrect quantity because it is not adjusting for par value.
		-- All this combined is leading to errors when I import into SEE Finance.
		-- I think the solution is to try to merge these two events.
		-- Since I do not have any guarantees that both these events will appear and will be back-to-back,
		-- I need to test for back-to-back, and if not, fall back to the original indivual handling.
-- cur_transaction is the "Full Redemption"
-- prev_transaction is the "Full Redemption Adj" 
local function generate_full_redemption_combined_paired_transaction(cur_transaction, prev_transaction, inout_transaction_list, inout_position_map, ticker_company_map)

	-- 20240102
	local trade_date_str = compute_transaction_date_YYYYMMDD( extract_transaction_date(cur_transaction) )
	-- 912797JX6
	local ticker_symbol = cur_transaction["Symbol"]
	-- US TREASURY BILXXX**MATURED**
	local description_name =  cur_transaction["Description"]

	-- Quantity may have commas and negative signs. SEE Finance seems to be okay with me passing these straight through.
	local units_str = cur_transaction["Quantity"]
	-- This has the currency symbol, and potentially commas, and periods. Again, SEE Finance seems to handle that fine.


	local action_field = cur_transaction["Action"]

	local total_amount_str = prev_transaction["Amount"]

	local unit_price_str = ""
	-- US TREASURY or UNITED STATES TREASURY
	if string.match(description_name, "S TREASURY") then

		-- I think Schwab has messed up the quantity.
		-- But this is confusing.
		-- Example: If you buy $10,000 worth of T-Bills
		-- 1. The first confusing thing is that T-Bills must be bought in increments of $1000 (at auction).
		-- So this would imply you need to buy 10 quantity ($10,000/$1,000 = 10).
		-- 2. But the par value of a T-Bill seems to be $100 (i.e. the reported price per unit is something like $99.17).
		-- So this would imply that the quantity shoud be $10,000/$100 = 100.
		-- 3. But Schwab reports the quantity as 10,000 in this case.
		-- I think Schwab's value is the most wrong.
		-- Since finance software likes to compute their own values and bases everything on the price per unit,
		-- I think the correct value needs to be #2 (divide by 100).
		-- use string.gsub to remove the commas. It returns two values, one is the converted string, and the other is the count of conversions.
		-- UPDATE: I disabled this on the redemptions because my numbers are getting screwed up again.
		-- My theory is that once I reported the par-value in the position info, SEE Finance may be auto-calculating the adjustment on the redemption.
		-- Thus my shares of 200.00 are getting converted to 2.
		-- So I need to disable the adjustment here. I don't understand why Buy doesn't get the same adjustment.
		-- UPDATE2: I've disabled the adjustment because I think once I define PARVALUE, SEE Finance automatically adjusts everything correctly,
		-- and my adjustment after that screws up everything.
		-- So I think the real solution is I need to define PARVALUE for all bonds, but Schwab doesn't give me that information.
		-- I suspect the SEE Finance implicit default is $1.00.
		--[[
		local units_str_without_comma = string.gsub(units_str, ",", "")
		local units_num = tonumber(units_str_without_comma)
		local fixed_units = units_num / 100.0
		units_str = tostring(fixed_units)
		--]]

		unit_price_str = "100.00"

	end


	local transaction = [[
					<SELLDEBT>
						<INVSELL>
							<INVTRAN>
								<DTTRADE>]] .. trade_date_str .. [[</DTTRADE>
								<MEMO>]] .. "Full Redemption+Adj: " .. description_name .. [[</MEMO>
                            </INVTRAN>							
							<SECID>
								<UNIQUEID>]] .. ticker_symbol .. [[</UNIQUEID>
							</SECID>

							<UNITS>]] .. units_str .. [[</UNITS>
							<UNITPRICE>]] .. unit_price_str .. [[</UNITPRICE>
							<TOTAL>]] .. total_amount_str .. [[</TOTAL>
						</INVSELL>
						<SELLREASON>MATURITY</SELLREASON>
					</SELLDEBT>
]]


	-- I originally commented this out because I worried the data might be missing since this is a close-out case.
	-- I speculated that this data would get filled in better during the initial order creation.
	-- But I in actual testing, I had data sets where the creation was missing, ultimately leading to missing positions.
	-- So check for nil and only add if not already in the map. 
	if nil == inout_position_map[ticker_symbol] then
		local debt_type = "COUPON"
		if string.match(description_name, "BIL") then
			debt_type = "ZERO"
		end

		local par_value = ""
		local debt_class = ""
		local asset_class = ""
		-- US TREASURY or UNITED STATES TREASURY
		if string.match(description_name, "S TREASURY") then
			par_value = "100.0"
			debt_class = "TREASURY"
			asset_class = "DOMESTICBOND"
		end

		-- This is the redemption event, which means it is the maturity date
		local maturity_date = trade_date_str


		--[[
    {
      "Date": "05/21/2024",
      "Action": "Full Redemption",
      "Symbol": "912797JX6",
      "Description": "US TREASURY BILXXX**MATURED**",
      "Quantity": "-1,000",
      "Price": "",
      "Fees & Comm": "",
      "Amount": ""
    },
	--]]

			local security_name = description_name
			-- "US TREASURY BILXXX**MATURED**"
			--print("description_name", description_name)
			local extracted_security_name = string.match(description_name, "(.+)%*%*MATURED%*%*")
			--print("bond name", extracted_security_name)

			if extracted_security_name then
				security_name = extracted_security_name
			end

		local position = [[
					<DEBTINFO>
						<SECINFO>
							<SECID> <!--Security ID-->
								<UNIQUEID>]] .. ticker_symbol .. [[</UNIQUEID>
							</SECID>
							<SECNAME>]] .. security_name .. [[</SECNAME> 
							<TICKER>]] .. ticker_symbol .. [[</TICKER>
						</SECINFO>
						<DEBTTYPE>]] .. debt_type .. [[</DEBTTYPE>
						<PARVALUE>]] .. par_value .. [[</PARVALUE>
						<DTMAT>]] .. maturity_date .. [[</DTMAT>
						<DEBTCLASS>]] .. debt_class .. [[</DEBTCLASS>
						<ASSETCLASS>]] .. asset_class .. [[</ASSETCLASS>

					</DEBTINFO>       
]]
		inout_position_map[ticker_symbol] = position
	end

	inout_transaction_list[#inout_transaction_list+1] = transaction

end



local function generate_funds(cur_transaction, action_name, inout_transaction_list, inout_position_map, ticker_company_map)


	-- 20240102
	local trade_date_str = compute_transaction_date_YYYYMMDD( extract_transaction_date(cur_transaction) )

	-- TDA TRAN - ORDINARY DIVIDEND (SNSXX)
	local description_name =  cur_transaction["Description"]


	-- This has the currency symbol, and potentially commas, and periods. Again, SEE Finance seems to handle that fine.
	local total_amount_str = cur_transaction["Amount"]


	


--[=[

	local in_or_out = "OUT"
	if string.match(total_amount_str, "%-") then
		in_or_out = "IN"
	end


	local transaction = [[
					<TRANSFER>
							<INVTRAN>
								<DTTRADE>]] .. trade_date_str .. [[</DTTRADE>
								<MEMO>]] .. action_name .. ": " .. description_name .. [[</MEMO>
                            </INVTRAN>							
							<TFERACTION>]] .. in_or_out .. [[</TFERACTION>
							<UNITTYPE>CURRENCY</UNITTYPE>
							<UNITPRICE>1.0</UNITPRICE>
							<UNITS>]] .. total_amount_str .. [[</UNITS>

							<TOTAL>]] .. total_amount_str .. [[</TOTAL>
					</TRANSFER>
]]
--]=]

--[=[
	local transaction = [[
					<INCOME>
							<INVTRAN>
								<DTTRADE>]] .. trade_date_str .. [[</DTTRADE>
								<MEMO>]] .. action_name .. ": " .. description_name .. [[</MEMO>
                            </INVTRAN>							

							<INCOMETYPE>MISC</INCOMETYPE>
							<TOTAL>]] .. total_amount_str .. [[</TOTAL>
					</INCOME>
]]
--]=]
	local transaction = [[
					<INVBANKTRAN>
					<STMTTRN>
							<INVTRAN>
								<DTTRADE>]] .. trade_date_str .. [[</DTTRADE>
								<MEMO>]] .. action_name .. ": " .. description_name .. [[</MEMO>
                            </INVTRAN>							
								<DTPOSTED>]] .. trade_date_str .. [[</DTPOSTED>
								<DTUSER>]] .. trade_date_str .. [[</DTUSER>

							<TRNTYPE>XFER</TRNTYPE>
							<TRNAMT>]] .. total_amount_str .. [[</TRNAMT>
							<TOTAL>]] .. total_amount_str .. [[</TOTAL>
					</STMTTRN>
					</INVBANKTRAN>
]]


	inout_transaction_list[#inout_transaction_list+1] = transaction




end

local function generate_internal_transfer_with_symbol_and_quantity(cur_transaction, inout_transaction_list, inout_position_map, ticker_company_map)



	-- 20240102
	local trade_date_str = compute_transaction_date_YYYYMMDD( extract_transaction_date(cur_transaction) )
	-- XOM, CCJ 01/17/2025 40.00 C, 912797KN6
	local ticker_symbol = cur_transaction["Symbol"]
	
	local is_an_option = false
	-- If the ticker symbol is an option, we need to convert it into canonical form so it remains consistent with the other uses elsewhere.
	local ticker, exp_year_str, exp_month_str, exp_day_str, strike_price_str, put_or_call_str = split_option_components(cur_transaction)
	if ticker and exp_year_str and exp_month_str and exp_day_str and strike_price_str and put_or_call_str then
		ticker_symbol = compute_option_symbol(ticker, exp_year_str, exp_month_str, exp_day_str, strike_price_str, put_or_call_str)
		is_an_option = true
	end


	local description_name =  cur_transaction["Description"]

	-- Quantity may have commas and negative signs. SEE Finance seems to be okay with me passing these straight through.
	local units_str = cur_transaction["Quantity"]

	local action_field = cur_transaction["Action"]
	
	local in_or_out = "IN"
	if string.match(units_str, "%-") then
		in_or_out = "OUT"
	end



	-- The Schwab schema doesn't have seperate types for bonds vs. equities.
	-- T-Bills are popular right now since yields are the highest they've been in decades and the yield curve is inverted, so I want to handle those.
	-- This heuristic may provide incorrect results if a stock or ETF matches this filter.
	if string.match(description_name, "UNITED STATES TREASURY BILL")
		or string.match(description_name, "US TREASURY BILL") 
		or string.match(description_name, "UNITED STATES TREASURY BOND")
		or string.match(description_name, "US TREASURY BOND") 
		or string.match(description_name, "UNITED STATES TREASURY NOTE")
		or string.match(description_name, "US TREASURY NOTE") 
	then

		-- I think Schwab has messed up the quantity.
		-- But this is confusing.
		-- Example: If you buy $10,000 worth of T-Bills
		-- 1. The first confusing thing is that T-Bills must be bought in increments of $1000 (at auction).
		-- So this would imply you need to buy 10 quantity ($10,000/$1,000 = 10).
		-- 2. But the par value of a T-Bill seems to be $100 (i.e. the reported price per unit is something like $99.17).
		-- So this would imply that the quantity shoud be $10,000/$100 = 100.
		-- 3. But Schwab reports the quantity as 10,000 in this case.
		-- I think Schwab's value is the most wrong.
		-- Since finance software likes to compute their own values and bases everything on the price per unit,
		-- I think the correct value needs to be #2 (divide by 100).
		-- use string.gsub to remove the commas. It returns two values, one is the converted string, and the other is the count of conversions.
		-- UPDATE2: I've disabled the adjustment because I think once I define PARVALUE, SEE Finance automatically adjusts everything correctly,
		-- and my adjustment after that screws up everything.
		-- So I think the real solution is I need to define PARVALUE for all bonds, but Schwab doesn't give me that information.
		-- I suspect the SEE Finance implicit default is $1.00.
		--[[
		local units_str_without_comma = string.gsub(units_str, ",", "")
		local units_num = tonumber(units_str_without_comma)
		local fixed_units = units_num / 100.0
		units_str = tostring(fixed_units)
		--]]
	end



	local transaction = [[
					<TRANSFER>
							<INVTRAN>
								<DTTRADE>]] .. trade_date_str .. [[</DTTRADE>
								<MEMO>]] .. action_field .. ": " .. description_name .. [[</MEMO>
                            </INVTRAN>							
							<SECID>
								<UNIQUEID>]] .. ticker_symbol .. [[</UNIQUEID>
							</SECID>
							<TFERACTION>]] .. in_or_out .. [[</TFERACTION>

							<UNITS>]] .. units_str .. [[</UNITS>

					</TRANSFER>
]]


	inout_transaction_list[#inout_transaction_list+1] = transaction




	-- I originally commented this out because I worried the data might be missing since this is a close-out case.
	-- I speculated that this data would get filled in better during the initial order creation.
	-- But I in actual testing, I had data sets where the creation was missing, ultimately leading to missing positions.
	-- So check for nil and only add if not already in the map.
	if nil == inout_position_map[ticker_symbol] then
		local sec_name = ""
		local db_entry = ticker_company_map[ticker_symbol]
		if db_entry then
			local company_name = db_entry.name
			if company_name and company_name ~= "" then
				sec_name = company_name
				--	print("Found ticker: " .. ticker_symbol .. " with company name: " .. company_name .. " in database")
			else
				--	print("Did not find company_name for ticker: " .. ticker_symbol .. " in database")
			end
		else
			--	print("Did not find database entry for ticker: " .. ticker_symbol)
		end



		-- This case is harder because I don't know if I have a stock, option, or bond.
		-- I read that stock tickers are max 5 characters.
		-- I know options are of the format: ticker 2024 01 31 C 8-digits-for-strike
		-- That means at [1-5] + 8 + 1 + 8
		-- [1-5] + 17
		-- min 18 characters, max 22 characters
		-- US treasuries seem to have 9 characters. But looking up bonds in general, there don't seem to be any rules I can depend on.
		

		local position

		if #ticker_symbol <= 5 then
			position = [[
					<STOCKINFO>
						<SECINFO>
							<SECID> <!--Security ID-->
								<UNIQUEID>]] .. ticker_symbol .. [[</UNIQUEID>
							</SECID>
							<SECNAME>]] .. sec_name .. [[</SECNAME> 
							<TICKER>]] .. ticker_symbol .. [[</TICKER>
						</SECINFO>
							<!--
								<ASSETCLASS>LARGESTOCK</ASSETCLASS>
							-->

					</STOCKINFO>       
]]
		elseif is_an_option then
			--elseif #ticker_symbol >= 18 
			--and string.match(ticker_symbol, "^%w+%d%d%d%d%d%d%d%d[CP]%d%d%d%d%d%d%d%d%$") then

				local option_symbol = ticker_symbol
				local human_friendly_symbol = cur_transaction["Symbol"]
				local option_type_str
				if put_or_call_str == "P" then
					option_type_str = "PUT"
				elseif put_or_call_str == "C" then
					option_type_str = "CALL"
				else
					assert(false, "Value in string should have been C or P")
				end
				local expire_date = exp_year_str .. exp_month_str .. exp_day_str
				local shares_per_contract_str = get_shares_per_contract(ticker)



				position = [[
					<OPTINFO>
						<SECINFO>
							<SECID> <!--Security ID-->
								<UNIQUEID>]] .. option_symbol .. [[</UNIQUEID><!--CUSIP for the option -->
							</SECID>
							<SECNAME>]] .. human_friendly_symbol .. [[</SECNAME> 

							<!-- The docs imply that is might be the ticker of the underlying, but SEE Finance using it as the option identifer. -->
							<TICKER>]] .. option_symbol .. [[</TICKER> <!--Ticker symbol-->
						</SECINFO>
						<OPTTYPE>]] .. option_type_str .. [[</OPTTYPE> 
						<STRIKEPRICE>]] .. strike_price_str .. [[</STRIKEPRICE>

						<DTEXPIRE>]] .. expire_date .. [[</DTEXPIRE> 
						<SHPERCTRCT>]] .. shares_per_contract_str .. [[</SHPERCTRCT> <!--100 shares per contract--> 

						<!-- I think this section is supposed to be for the underlying -->
						<SECID> <!--Security ID-->
							<UNIQUEID>]] .. ticker .. [[</UNIQUEID><!--CUSIP for the underlying stock -->
							<!--
								<ASSETCLASS>LARGESTOCK</ASSETCLASS>
							-->

						</SECID>
					</OPTINFO>       
]]
				create_position_for_underlying_from_option(cur_transaction, ticker, description_name, option_type_str, inout_position_map, ticker_company_map)


		else
			local debt_type = "COUPON"
			if string.match(description_name, "BILL") then
				debt_type = "ZERO"
			end

			local par_value = ""
			local debt_class = ""
			local asset_class = ""
			if string.match(description_name, "US TREASURY") then
				par_value = "100.0"
				debt_class = "TREASURY"
				asset_class = "DOMESTICBOND"
			end
			--[[
		{
		  "Date": "05/13/2024",
		  "Action": "Journaled Shares",
		  "Symbol": "912797KE6",
		  "Description": "TDA TRAN - TRANSFER OF SECURITY OR OPTION OUT (912797KE6), UNITED STATES TREASURY BILLS, 0%, due 06/11/2024",
		  "Quantity": "-1,000",
		  "Price": "",
		  "Fees & Comm": "",
		  "Amount": ""
		},
		--]]

			local maturity_date = ""
			local security_name = description_name
			-- "TDA TRAN - TRANSFER OF SECURITY OR OPTION OUT (912797KE6), UNITED STATES TREASURY BILLS, 0%, due 06/11/2024"
			local lead_in_str = "TDA TRAN %- TRANSFER OF SECURITY OR OPTION OUT %(" .. ticker_symbol .. "%)%, "
			--print("lead in", lead_in_str)
			--print("description_name", description_name)
			local extracted_security_name = string.match(description_name, lead_in_str .. "(.*)")
			--print("bond name", extracted_security_name)

			if extracted_security_name then
				security_name = extracted_security_name
				local m,d,y = string.match(security_name, "due (%d%d)/(%d%d)/(%d%d%d%d)")
				maturity_date = compute_transaction_date_YYYYMMDD(y,m,d)
			end
	

			position = [[
					<DEBTINFO>
						<SECINFO>
							<SECID> <!--Security ID-->
								<UNIQUEID>]] .. ticker_symbol .. [[</UNIQUEID>
							</SECID>
							<SECNAME>]] .. security_name .. [[</SECNAME> 
							<TICKER>]] .. ticker_symbol .. [[</TICKER>
						</SECINFO>
						<DEBTTYPE>]] .. debt_type .. [[</DEBTTYPE>
						<PARVALUE>]] .. par_value .. [[</PARVALUE>
						<DTMAT>]] .. maturity_date .. [[</DTMAT>
						<DEBTCLASS>]] .. debt_class .. [[</DEBTCLASS>
						<ASSETCLASS>]] .. asset_class .. [[</ASSETCLASS>

					</DEBTINFO>       
]]



		end




		inout_position_map[ticker_symbol] = position
	end




end

local function generate_internal_transfer_with_amount(cur_transaction, inout_transaction_list, inout_position_map, ticker_company_map)


	-- 20240102
	local trade_date_str = compute_transaction_date_YYYYMMDD( extract_transaction_date(cur_transaction) )
	local description_name =  cur_transaction["Description"]
	local total_amount_str = cur_transaction["Amount"]

	local action_field = cur_transaction["Action"]


	local transaction = [[
					<INVBANKTRAN>
					<STMTTRN>
							<INVTRAN>
								<DTTRADE>]] .. trade_date_str .. [[</DTTRADE>
								<MEMO>]] .. action_field .. ": " .. description_name .. [[</MEMO>
                            </INVTRAN>							
								<DTPOSTED>]] .. trade_date_str .. [[</DTPOSTED>
								<DTUSER>]] .. trade_date_str .. [[</DTUSER>

							<TRNTYPE>XFER</TRNTYPE>
							<TRNAMT>]] .. total_amount_str .. [[</TRNAMT>
							<TOTAL>]] .. total_amount_str .. [[</TOTAL>
					</STMTTRN>
					</INVBANKTRAN>
]]


	inout_transaction_list[#inout_transaction_list+1] = transaction



end

local function generate_internal_transfer(cur_transaction, inout_transaction_list, inout_position_map, ticker_company_map)

	if DISABLE_INTERNAL_TRANSFER then
		return
	end

	--[[ 
		There seem to be 2 cases with this type:
    {
      "Date": "05/13/2024",
      "Action": "Internal Transfer",
      "Symbol": "",
      "Description": "TDA TO CS&CO TRANSFER",
      "Quantity": "",
      "Price": "",
      "Fees & Comm": "",
      "Amount": "$38,187.85"
    },

	and
	{
      "Date": "05/13/2024",
      "Action": "Internal Transfer",
      "Symbol": "PAAS",
      "Description": "PAN AMERN SILVER CORP F",
      "Quantity": "100",
      "Price": "",
      "Fees & Comm": "",
      "Amount": ""
    },
    {
      "Date": "05/13/2024",
      "Action": "Internal Transfer",
      "Symbol": "SNSXX",
      "Description": "SCHWAB US TREASURY MONEY INVESTOR",
      "Quantity": "139,662.13",
      "Price": "",
      "Fees & Comm": "",
      "Amount": ""
    },

	In the first case, Amount is defined and Symbol is missing.
	In the second case, Symbol and Quantity are defined, but Amount is missing.
	--]]
	local ticker_symbol = cur_transaction["Symbol"]

	if ticker_symbol ~= "" then
		generate_internal_transfer_with_symbol_and_quantity(cur_transaction, inout_transaction_list, inout_position_map, ticker_company_map)
	else
		generate_internal_transfer_with_amount(cur_transaction, inout_transaction_list, inout_position_map, ticker_company_map)
	end

end



local function generate_journaled_shares_symbol_quantity(cur_transaction, inout_transaction_list, inout_position_map, ticker_company_map)
		generate_internal_transfer_with_symbol_and_quantity(cur_transaction, inout_transaction_list, inout_position_map, ticker_company_map)

end

local function generate_journaled_shares_amount(cur_transaction, inout_transaction_list, inout_position_map, ticker_company_map)
		generate_internal_transfer_with_amount(cur_transaction, inout_transaction_list, inout_position_map, ticker_company_map)
end

local function generate_journaled_shares(cur_transaction, inout_transaction_list, inout_position_map, ticker_company_map)

	if DISABLE_JOURNALED_SHARES then
		return
	end

	--[[
	Ugh, there are multiple different cases with this name.


    {
      "Date": "12/18/2023",
      "Action": "Journaled Shares",
      "Symbol": "GOLD 12/15/2023 19.00 C",
      "Description": "TDA TRAN - REMOVAL OF OPTION DUE TO EXPIRATION (0GOLD.LF30019000)",
      "Quantity": "1",
      "Price": "",
      "Fees & Comm": "",
      "Amount": ""
    },
    {
      "Date": "12/04/2023",
      "Action": "Journaled Shares",
      "Symbol": "GLD 12/01/2023 176.50 P",
      "Description": "TDA TRAN - REMOVAL OF OPTION DUE TO EXPIRATION (0GLD..X130176500)",
      "Quantity": "-1",
      "Price": "",
      "Fees & Comm": "",
      "Amount": ""
    },



    {
      "Date": "03/20/2023",
      "Action": "Journaled Shares",
      "Symbol": "IPI 03/17/2023 35.00 P",
      "Description": "TDA TRAN - REMOVAL OF OPTION DUE TO ASSIGNMENT (0IPI..OH30035000)",
      "Quantity": "1",
      "Price": "",
      "Fees & Comm": "",
      "Amount": ""
    },




	{
      "Date": "12/11/2023",
      "Action": "Journaled Shares",
      "Symbol": "",
      "Description": "TDA TRAN - INTRA-ACCOUNT TRANSFER",
      "Quantity": "",
      "Price": "",
      "Fees & Comm": "",
      "Amount": "$75,000.00"
    },
    {
      "Date": "12/11/2023",
      "Action": "Journaled Shares",
      "Symbol": "",
      "Description": "TDA TRAN - INTRA-ACCOUNT TRANSFER",
      "Quantity": "",
      "Price": "",
      "Fees & Comm": "",
      "Amount": "-$75,000.00"
    },



    {
      "Date": "11/21/2023",
      "Action": "Journaled Shares",
      "Symbol": "",
      "Description": "TDA TRAN - CASH ALTERNATIVES PURCHASE (MMDA1) BANK SWEEP DEPOSIT",
      "Quantity": "",
      "Price": "",
      "Fees & Comm": "",
      "Amount": "$12,499.89"
    },
    {
      "Date": "11/20/2023",
      "Action": "Journaled Shares",
      "Symbol": "",
      "Description": "TDA TRAN - CASH ALTERNATIVES REDEMPTION (MMDA1) BANK SWEEP WITHDRAWAL",
      "Quantity": "",
      "Price": "",
      "Fees & Comm": "",
      "Amount": "-$918.30"
    },




    {
      "Date": "10/31/2023",
      "Action": "Journaled Shares",
      "Symbol": "MMDA1",
      "Description": "TDA TRAN - CASH ALTERNATIVES INTEREST (MMDA1)",
      "Quantity": "56.32",
      "Price": "",
      "Fees & Comm": "",
      "Amount": ""
    },



	{
      "Date": "07/28/2023",
      "Action": "Journaled Shares",
      "Symbol": "SNSXX",
      "Description": "TDA TRAN - INTERNAL TRANSFER BETWEEN ACCOUNTS OR ACCOUNT TYPES (SNSXX)",
      "Quantity": "10,500",
      "Price": "",
      "Fees & Comm": "",
      "Amount": ""
    },
    {
      "Date": "07/28/2023",
      "Action": "Journaled Shares",
      "Symbol": "SNSXX",
      "Description": "TDA TRAN - INTERNAL TRANSFER BETWEEN ACCOUNTS OR ACCOUNT TYPES (SNSXX)",
      "Quantity": "-10,500",
      "Price": "",
      "Fees & Comm": "",
      "Amount": ""
    },



	{
      "Date": "07/03/2023",
      "Action": "Journaled Shares",
      "Symbol": "",
      "Description": "TDA TRAN - MARK TO THE MARKET",
      "Quantity": "",
      "Price": "",
      "Fees & Comm": "",
      "Amount": "$122.00"
    },
    {
      "Date": "07/03/2023",
      "Action": "Journaled Shares",
      "Symbol": "",
      "Description": "TDA TRAN - MARK TO THE MARKET",
      "Quantity": "",
      "Price": "",
      "Fees & Comm": "",
      "Amount": "-$122.00"
    },




    {
      "Date": "04/04/2023",
      "Action": "Journaled Shares",
      "Symbol": "IWM",
      "Description": "TDA TRAN - INTERNAL TRANSFER BETWEEN LOCATION CODES (IWM)",
      "Quantity": "50",
      "Price": "",
      "Fees & Comm": "",
      "Amount": ""
    },
    {
      "Date": "04/04/2023",
      "Action": "Journaled Shares",
      "Symbol": "IWM",
      "Description": "TDA TRAN - INTERNAL TRANSFER BETWEEN LOCATION CODES (IWM)",
      "Quantity": "-50",
      "Price": "",
      "Fees & Comm": "",
      "Amount": ""
    },
    {
      "Date": "04/04/2023",
      "Action": "Journaled Shares",
      "Symbol": "IWM",
      "Description": "TDA TRAN - TRANSFER OF SECURITY OR OPTION IN (IWM)",
      "Quantity": "50",
      "Price": "",
      "Fees & Comm": "",
      "Amount": ""
    },



	Commonalities:

	Symbol + Quantity (only)

		TDA TRAN - REMOVAL OF OPTION DUE TO EXPIRATION (0GOLD.LF30019000)
		TDA TRAN - REMOVAL OF OPTION DUE TO ASSIGNMENT (0IPI..OH30035000)
		TDA TRAN - CASH ALTERNATIVES INTEREST (MMDA1)
		TDA TRAN - INTERNAL TRANSFER BETWEEN ACCOUNTS OR ACCOUNT TYPES (SNSXX)
		TDA TRAN - INTERNAL TRANSFER BETWEEN LOCATION CODES (IWM)

	Amount (only)
		TDA TRAN - INTRA-ACCOUNT TRANSFER
		TDA TRAN - CASH ALTERNATIVES PURCHASE (MMDA1) BANK SWEEP DEPOSIT
		TDA TRAN - CASH ALTERNATIVES REDEMPTION (MMDA1) BANK SWEEP WITHDRAWAL
		TDA TRAN - MARK TO THE MARKET



	I'm wondering if I should special case CASH ALTERNATIVES INTEREST as interest.
	Argument against is I hope/expect interest to get a regular category handled elsewhere.

--]]
	local ticker_symbol = cur_transaction["Symbol"]

	if ticker_symbol ~= "" then
		generate_journaled_shares_symbol_quantity(cur_transaction, inout_transaction_list, inout_position_map, ticker_company_map)
	else
		generate_journaled_shares_amount(cur_transaction, inout_transaction_list, inout_position_map, ticker_company_map)
	end



end

local function generate_journal(cur_transaction, inout_transaction_list, inout_position_map, ticker_company_map)

	if DISABLE_JOURNAL then
		return
	end

	-- always seems to have symbol + quantity, so reuse
	generate_journaled_shares_symbol_quantity(cur_transaction, inout_transaction_list, inout_position_map, ticker_company_map)
end


local function generate_ofx_brokerage_transaction(cur_transaction, inout_transaction_list, inout_position_map, ticker_company_map, array_of_brokerage_transactions, cur_idx)

	local action_field = cur_transaction["Action"]
	local symbol_field = cur_transaction["Symbol"]
	local date_field = cur_transaction["Date"]

	-- There are two forms:
    -- "Date": "05/20/2024 as of 05/17/2024",
    -- "Date": "05/21/2024",
	-- The first form might only come up for options expiration. But it's hard to know.
	local month, day, year = string.match(date_field, "%d%d/%d%d/%d%d%d%d as of (%d%d)/(%d%d)/(%d%d%d%d)")
	if not month then
		month, day, year = string.match(date_field, "(%d%d)/(%d%d)/(%d%d%d%d)")
	end

	-- For debugging	
--[[
	print("action_field", action_field)
	print("symbol_field", symbol_field)
	print("date_field", date_field)
--]]

	-- Options
	if action_field == "Buy to Close" then
		generate_option_buy(cur_transaction, false, inout_transaction_list, inout_position_map, ticker_company_map)
	elseif action_field == "Buy to Open" then
		generate_option_buy(cur_transaction, true, inout_transaction_list, inout_position_map, ticker_company_map)
	elseif action_field == "Sell to Close" then
		generate_option_sell(cur_transaction, false, inout_transaction_list, inout_position_map, ticker_company_map)
	elseif action_field == "Sell to Open" then
		generate_option_sell(cur_transaction, true, inout_transaction_list, inout_position_map, ticker_company_map)

	elseif action_field == "Assigned" then
		generate_option_assigned_exercised_expired(cur_transaction, action_field, inout_transaction_list, inout_position_map, ticker_company_map)
	elseif action_field == "Exchange or Exercise" then
		-- I hit an edge case. Originally I thought this only got hit for exercising options.
		-- But with the sanctioned Lukoil, two exchange events happened.
		-- The transactions I found seem to be no-ops (don't accomplish anything),
		-- but they are enough to break my code.
		-- The first event has a "" for symbol.
		-- The second says "LUKOY".
		--[=[
   {
      "Date": "10/11/2024",
      "Action": "Exchange or Exercise",
      "Symbol": "",
      "Description": "OIL CO LUKOIL PJSC XXXOFAC ESCROW",
      "Quantity": "92",
      "Price": "",
      "Fees & Comm": "",
      "Amount": ""
    },
    {
      "Date": "10/11/2024",
      "Action": "Exchange or Exercise",
      "Symbol": "LUKOY",
      "Description": "OIL CO LUKOIL PJSC F",
      "Quantity": "-92",
      "Price": "",
      "Fees & Comm": "",
      "Amount": ""
    },
		--]=]
		-- The easiest thing to skip this case.
		if is_symbol_string_an_option(cur_transaction) then
			generate_option_assigned_exercised_expired(cur_transaction, action_field, inout_transaction_list, inout_position_map, ticker_company_map)
		else
			print("WARNING: 'Exchange or Exercise' for non-options is UNHANDLED", date_field, symbol_field, cur_transaction["Description"])
		end
		
	elseif action_field == "Expired" then
		generate_option_assigned_exercised_expired(cur_transaction, action_field, inout_transaction_list, inout_position_map, ticker_company_map)
		

	-- Equities, bonds
	elseif action_field == "Buy" then
		generate_equity_buy(cur_transaction, inout_transaction_list, inout_position_map, ticker_company_map)		
	elseif action_field == "Sell" then
		generate_equity_sell(cur_transaction, inout_transaction_list, inout_position_map, ticker_company_map)
	elseif action_field == "Sell Short" then
		generate_equity_sellshort(cur_transaction, inout_transaction_list, inout_position_map, ticker_company_map)


	elseif action_field == "Cash Dividend" then
		generate_cash_dividend_capitalgain(cur_transaction, "DIV", inout_transaction_list, inout_position_map, ticker_company_map)
	elseif action_field == "Qualified Dividend" then
		generate_cash_dividend_capitalgain(cur_transaction, "DIV", inout_transaction_list, inout_position_map, ticker_company_map)
	elseif action_field == "Long Term Cap Gain" then
		generate_cash_dividend_capitalgain(cur_transaction, "CGLONG", inout_transaction_list, inout_position_map, ticker_company_map)
	elseif action_field == "Short Term Cap Gain" then
		generate_cash_dividend_capitalgain(cur_transaction, "CGSHORT", inout_transaction_list, inout_position_map, ticker_company_map)
	elseif action_field == "Qual Div Reinvest" then
		generate_cash_dividend_capitalgain(cur_transaction, "DIV", inout_transaction_list, inout_position_map, ticker_company_map)
	elseif action_field == "Qual Div Reinvest Adj" then
		generate_cash_dividend_capitalgain(cur_transaction, "DIV", inout_transaction_list, inout_position_map, ticker_company_map)
	elseif action_field == "Div Adjustment" then
		generate_cash_dividend_capitalgain(cur_transaction, "DIV", inout_transaction_list, inout_position_map, ticker_company_map)


	elseif action_field == "Bond Interest" then
		generate_bond_interest(cur_transaction, inout_transaction_list, inout_position_map, ticker_company_map)

	-- This one might be new to Schwab because I never got it prior to the TD/Schwab switchover.
	elseif action_field == "Credit Interest" then
		generate_bond_interest(cur_transaction, inout_transaction_list, inout_position_map, ticker_company_map)
		

	elseif action_field == "Reinvest Dividend" then
		generate_reinvest_dividend(cur_transaction, inout_transaction_list, inout_position_map, ticker_company_map)
	elseif action_field == "Reinvest Shares" then
		generate_reinvest_shares(cur_transaction, inout_transaction_list, inout_position_map, ticker_company_map)

	-- ADR taxes/fees
	elseif action_field == "Foreign Tax Reclaim" then
		generate_foreign_tax(cur_transaction, inout_transaction_list, inout_position_map, ticker_company_map)
	elseif action_field == "Foreign Tax Reclaim Adj" then
		generate_foreign_tax(cur_transaction, inout_transaction_list, inout_position_map, ticker_company_map)
	elseif action_field == "Foreign Tax Paid" then
		generate_foreign_tax(cur_transaction, inout_transaction_list, inout_position_map, ticker_company_map)


	-- bond maturity
	elseif action_field == "Full Redemption Adj" then

		-- HACK: Special case handling.
		-- Schwab is generating 2 separate events for bond maturity.
		-- I first see "Full Redemption Adj", followed immediately by "Full Redemption"
		--[[     {
      "Date": "06/11/2024",
      "Action": "Full Redemption Adj",
      "Symbol": "912797KE6",
      "Description": "US TREASURY BILXXX**MATURED**",
      "Quantity": "",
      "Price": "",
      "Fees & Comm": "",
      "Amount": "$10,000.00"
    },
    {
      "Date": "06/11/2024",
      "Action": "Full Redemption",
      "Symbol": "912797KE6",
      "Description": "US TREASURY BILXXX**MATURED**",
      "Quantity": "-10,000",
      "Price": "",
      "Fees & Comm": "",
      "Amount": ""
    },
	--]]
		-- The former has an amount, the latter has a quantity.
		-- In addition, I think Schwab is putting the incorrect quantity because it is not adjusting for par value.
		-- All this combined is leading to errors when I import into SEE Finance.
		-- I think the solution is to try to merge these two events.
		-- Since I do not have any guarantees that both these events will appear and will be back-to-back,
		-- I need to test for back-to-back, and if not, fall back to the original indivual handling.
		local next_transaction = array_of_brokerage_transactions[cur_idx+1]

		if next_transaction ~= nil then
			local next_action_field = next_transaction["Action"]
			if next_action_field == "Full Redemption" then
				-- We will do the combined pair handling on the next loop
				return
			end
		end

		-- Else: we fallback and do the original individual item handling
		generate_full_redemption_adj(cur_transaction, inout_transaction_list, inout_position_map, ticker_company_map)
	elseif action_field == "Full Redemption" then

		local prev_transaction = array_of_brokerage_transactions[cur_idx-1]
		
		if prev_transaction ~= nil then
			local prev_action_field = prev_transaction["Action"]
			if prev_action_field == "Full Redemption Adj" then
				-- We will do the combined pair handling on the prev loop

				generate_full_redemption_combined_paired_transaction(cur_transaction, prev_transaction, inout_transaction_list, inout_position_map, ticker_company_map)

				return
			end
		end

		-- Else: we fallback and do the original individual item handling
		generate_full_redemption(cur_transaction, inout_transaction_list, inout_position_map, ticker_company_map)
		

	elseif action_field == "Return Of Capital" then
		generate_return_of_capital(cur_transaction, inout_transaction_list, inout_position_map, ticker_company_map)


	elseif action_field == "Funds Received" then
		generate_funds(cur_transaction, action_field, inout_transaction_list, inout_position_map, ticker_company_map)
	elseif action_field == "MoneyLink Transfer" then
		generate_funds(cur_transaction, action_field, inout_transaction_list, inout_position_map, ticker_company_map)

	elseif action_field == "Futures MM Sweep" then
		generate_funds(cur_transaction, action_field, inout_transaction_list, inout_position_map, ticker_company_map)

	elseif action_field == "Internal Transfer" then
		generate_internal_transfer(cur_transaction, inout_transaction_list, inout_position_map, ticker_company_map)
	elseif action_field == "Journaled Shares" then
		generate_journaled_shares(cur_transaction, inout_transaction_list, inout_position_map, ticker_company_map)

	elseif action_field == "Journal" then
		generate_journal(cur_transaction, inout_transaction_list, inout_position_map, ticker_company_map)



	-- Other possibilities I haven't seen: 
		-- stock split
		-- mutual fund to ETF exchanges
		-- margin stuff
	
	else
		print("WARNING: UNHANDLED action case", action_field)

	end
end


local function check_for_pair_transaction(cur_transaction, inout_transaction_list, inout_position_map, ticker_company_map, i)

end


-- decoded_data is after the Schwab JSON data has been decoded and converted into a Lua table.
-- optional_params is a table, with string keys. 
	-- Only brokerID & accountID are defined right now.
function m.create_ofx(decoded_data, optional_params)

	local array_of_brokerage_transactions = decoded_data["BrokerageTransactions"]

	print("#array_of_brokerage_transactions", #array_of_brokerage_transactions)

	local ticker_company_file = optional_params["tickerToCompanyFile"] or TICKER_TO_COMPANY_NAME_FILE
	--print("ticker_company_file")
	local ticker_company_map = dofile(ticker_company_file)



	local inout_transaction_list = {}
	local inout_position_map = {}


	for i=1, #array_of_brokerage_transactions do

		local cur_transaction = array_of_brokerage_transactions[i]

		generate_ofx_brokerage_transaction(cur_transaction, inout_transaction_list, inout_position_map, ticker_company_map, array_of_brokerage_transactions, i)


	end


	local broker_id = tostring( optional_params["brokerID"] or "0" )
	local account_id = tostring( optional_params["accountID"] or "0" )


	local ofx_header = [[
<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<?OFX OFXHEADER="200" VERSION="200" SECURITY="NONE" OLDFILEUID="NONE" NEWFILEUID="NONE"?>

<OFX>
    <INVSTMTMSGSRSV1>
		<INVSTMTTRNRS>

			<TRNUID>1001</TRNUID>
			<STATUS>
			<CODE>0</CODE>
			<SEVERITY>INFO</SEVERITY>
			</STATUS>
			<INVSTMTRS>
				<DTASOF>20050827010000</DTASOF>
				<CURDEF>USD</CURDEF>
				<INVACCTFROM>
					<BROKERID>]] .. broker_id .. [[</BROKERID>
					<ACCTID>]] .. account_id .. [[</ACCTID>
				</INVACCTFROM>

				<INVTRANLIST>
]]

	local flattened_transactions = table.concat(inout_transaction_list, "\n")
	local flattened_positions

	do
		local position_list = {}
		for k,v in pairs(inout_position_map) do
			position_list[#position_list+1] = v
		end
		flattened_positions = table.concat(position_list, "\n")
	end

	local ofx_middle = [[
				</INVTRANLIST>

				<SECLISTMSGSRSV1>
					<SECLIST>

]]
	local ofx_tail = [[

					</SECLIST>
				</SECLISTMSGSRSV1>
			</INVSTMTRS>
		</INVSTMTTRNRS>
    </INVSTMTMSGSRSV1>
</OFX>
]]


	local combined_table =
	{
		ofx_header,
		flattened_transactions,
		ofx_middle,
		flattened_positions,
		ofx_tail,
	}
	local flattened_ofx_all = table.concat(combined_table, "\n")


	return flattened_ofx_all

end

function m.json_decode(all_data)

	local haslpeg, lpeg = pcall(require,"lpeg")
	local json
	if haslpeg then
--		lpeg.locale(lpeg)
		json = require("dkjson").use_lpeg()
	else
		print("Notice: LPEG not detected. Using fallback mode, which may be slower.")
		json = require("dkjson")
	end

	local decoded_data = json.decode(all_data)

		--assert(decoded_data, "json.decode failed on the input file")



	return decoded_data
end

return m

