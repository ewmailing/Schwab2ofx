# Schwab2ofx

This converts the transaction history you can download while logged into your Schwab account from JSON to OFX. 

The core functionality is written as a library in Lua. This also comes with an accompanying command line tool (that uses the library) to convert files, as well as a simple web browser client-only front-end tool (leveraging Fengari to use the Lua-based library).

# Usage

## Command Line Tool
- Install Lua if you don't already have it. Tested with Lua 5.3 & 5.4, but I think any 5.x should work.

```bash
lua convert_schwab_cli.lua input.json output.ofx
```

## Web Browser Front-End UI

- A live demo is hosted on a GitHub static page [here](https://ewmailing.github.io/Schwab2ofx/).
- Click the Choose File button and select your .json file you downloaded from Schwab. The output file will be written to your browser's download directory.



# Background Story

I wrote this because I was happily using DirectConnect/OFX at TD Ameritrade with SEE Finance, and then Schwab took over and terminated support for both DirectConnect and OFX in 2024. I learned Schwab killed these features for their own customers about 4 years ago.

I was looking for some workaround. You can download Schwab transactions in CSV, JSON, or XML if you directly log into your account. I looked for other tools that could convert this to OFX, but the only one that came close was csv2ofx, but it doesn't support brokerage transactions, only banking.
I didn't know OFX, but I decided I would try to learn it and convert from JSON to OFX.

I learned basic OFX and wrote the schwab2ofx library in 2 days, and spent another half-day learning Fengari and how to build a UI with it. So there is a lot of room for this program to be better.

I tested this exclusively with SEE Finance, but it will probably work with other personal financial software that support OFX, such as GnuCash and MoneyDance.

I tested with a lot of transaction types, including more exotic things such as options trades, short sales, and foreign taxes. But since I only have access to my own data sets and Schwab does not document their schema, there may be transaction types that are unimplemented.


# Key Files:
* schwab2ofx.lua: The main library for converting to OFX
* convert_schwab_cli.lua: Command line tool
* index.html: Web Browser front end using Fengari
* helpers.lua: Misc helper functions
* MyCombinedStockList.lua: File containing map between ticker symbols and company names
* UNIT_EXPERIMENTS: Just a bunch of little test OFX files I wrote trying to figure out how to write working OFX

