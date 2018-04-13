--
-- lurker
--
-- Copyright (c) 2018 rxi
--
-- This library is free software; you can redistribute it and/or modify it
-- under the terms of the MIT license. See LICENSE for details.
--
-- Changes by iskolbin:
--   removed lume dependency;
--   rewritten some parts in more imperative manner;
--   updates for Love 0.11;
--   minor changes to make luacheck happy.

local lurker = { _version = "1.11.0" }

local love = assert( _G.love, 'love is not definied' )
local pairs, type, unpack = pairs, type, _G.unpack or table.unpack
local tostring, tonumber = tostring, tonumber

local major, minor = love.getVersion()
local dir = love.filesystem.enumerate or love.filesystem.getDirectoryItems
local isdir = love.filesystem.isDirectory
local time = love.timer.getTime or os.time
local lastmodified = love.filesystem.getLastModified
local rgbmul = 1

-- Changes for Love 0.11
if major > 0 or minor > 11 then
	function isdir( f )
		return love.filesystem.getInfo( f ).type == 'directory'
	end
	function lastmodified( f )
		return love.filesystem.getInfo( f ).modtime
	end
	rgbmul = 1/0xff
end

local function rgb( r, g, b )
	return r * rgbmul, g * rgbmul, b * rgbmul
end

local function lume_smooth(a, b, amount)
	local t = amount < 0 and 0 or (amount > 1 and 1 or amount)
	return a + (b - a) * t * t * (3 - 2 * t)
end

local function lume_pingpong(x)
	return 1 - math.abs(1 - x % 2)
end

local function lume_concat(...)
	local rtn = {}
	for i = 1, select("#", ...) do
		for _, v in pairs(select(i,...)) do
			rtn[#rtn + 1] = v
		end
	end
	return rtn
end

local function lume_trim(str, chars)
	if not chars then return str:match("^[%s]*(.-)[%s]*$") end
	chars = chars:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%1")
	return str:match("^[" .. chars .. "]*(.-)[" .. chars .. "]*$")
end

local function lume_format(str, vars)
	if not vars then return str end
	local f = function(x)
		return tostring(vars[x] or vars[tonumber(x)] or "{" .. x .. "}")
	end
	return (str:gsub("{(.-)}", f))
end

local function lume_hotswap(modname)
	local oldglobal = {}
	for k, v in pairs( _G ) do
		oldglobal[k] = v
	end
	local updated = {}
	local function update(old, new)
		if updated[old] then return end
		updated[old] = true
		local oldmt, newmt = getmetatable(old), getmetatable(new)
		if oldmt and newmt then update(oldmt, newmt) end
		for k, v in pairs(new) do
			if type(v) == "table" then update(old[k], v) else old[k] = v end
		end
	end
	local err = nil
	local function onerror(e)
		for k in pairs(_G) do _G[k] = oldglobal[k] end
		err = lume_trim(e)
	end
	local ok, oldmod = pcall(require, modname)
	oldmod = ok and oldmod or nil
	xpcall(function()
		package.loaded[modname] = nil
		local newmod = require(modname)
		if type(oldmod) == "table" then update(oldmod, newmod) end
		for k, v in pairs(oldglobal) do
			if v ~= _G[k] and type(v) == "table" then
				update(v, _G[k])
				_G[k] = v
			end
		end
	end, onerror)
	package.loaded[modname] = oldmod
	if err then return nil, err end
	return oldmod
end

local lovecallbacknames = {
	"update",
	"load",
	"draw",
	"mousepressed",
	"mousereleased",
	"keypressed",
	"keyreleased",
	"focus",
	"quit",
}

function lurker.init()
	lurker.print("Initing lurker")
	lurker.path = "."
	lurker.preswap = function() end
	lurker.postswap = function() end
	lurker.interval = .5
	lurker.protected = true
	lurker.quiet = false
	lurker.lastscan = 0
	lurker.lasterrorfile = nil
	lurker.files = {}
	lurker.funcwrappers = {}
	lurker.lovefuncs = {}
	lurker.state = "init"
	for _, f in pairs( lurker.getchanged()) do
		lurker.resetfile( f )
	end
	return lurker
end

function lurker.print(...)
	print("[lurker] " .. lume_format(...))
end

function lurker.listdir(path, recursive, skipdotfiles)
	path = (path == ".") and "" or path
	local t = {}
	for _, f in pairs( dir( path )) do
		f = path .. "/" .. f
		if not skipdotfiles or not f:match("/%.[^/]*$") then
			if recursive and isdir(f) then
				t = lume_concat(t, lurker.listdir(f, true, true))
			else
				table.insert(t, lume_trim(f, "/"))
			end
		end
	end
	return t
end

function lurker.initwrappers()
	for _, v in pairs(lovecallbacknames) do
		lurker.funcwrappers[v] = function(...)
			local args = {...}
			xpcall(function()
				return lurker.lovefuncs[v] and lurker.lovefuncs[v](unpack(args))
			end, lurker.onerror)
		end
		lurker.lovefuncs[v] = love[v]
	end
	lurker.updatewrappers()
end

function lurker.updatewrappers()
	for _, v in pairs(lovecallbacknames) do
		if love[v] ~= lurker.funcwrappers[v] then
			lurker.lovefuncs[v] = love[v]
			love[v] = lurker.funcwrappers[v]
		end
	end
end

function lurker.onerror(e, nostacktrace)
	lurker.print("An error occurred; switching to error state")
	lurker.state = "error"

	-- Release mouse
	local setgrab = love.mouse.setGrab or love.mouse.setGrabbed
	setgrab(false)

	-- Set up callbacks
	for _, v in pairs(lovecallbacknames) do
		love[v] = function() end
	end

	love.update = lurker.update

	love.keypressed = function(k)
		if k == "escape" then
			lurker.print("Exiting...")
			love.event.quit()
		end
	end

	local stacktrace = nostacktrace and "" or
	lume_trim((debug.traceback("", 2):gsub("\t", "")))
	local msg = lume_format("{1}\n\n{2}", {e, stacktrace})
	local colors = {
		{ rgb( 0x1e, 0x1e, 0x2c ) },
		{ rgb( 0xf0, 0xa3, 0xa3 ) },
		{ rgb( 0x92, 0xb5, 0xb0 ) },
		{ rgb( 0x66, 0x66, 0x6a ) },
		{ rgb( 0xcd, 0xcd, 0xcd ) },
	}
	love.graphics.reset()
	love.graphics.setFont(love.graphics.newFont(12))

	love.draw = function()
		local pad = 25
		local width = love.graphics.getWidth()

		local function drawhr(pos, color1, color2)
			local animpos = lume_smooth(pad, width - pad - 8, lume_pingpong(time()))
			if color1 then love.graphics.setColor(color1) end
			love.graphics.rectangle("fill", pad, pos, width - pad*2, 1)
			if color2 then love.graphics.setColor(color2) end
			love.graphics.rectangle("fill", animpos, pos, 8, 1)
		end

		local function drawtext(str, x, y, color, limit)
			love.graphics.setColor(color)
			love.graphics[limit and "printf" or "print"](str, x, y, limit)
		end

		love.graphics.setBackgroundColor(colors[1])
		love.graphics.clear()

		drawtext("An error has occurred", pad, pad, colors[2])
		drawtext("lurker", width - love.graphics.getFont():getWidth("lurker") -
		pad, pad, colors[4])
		drawhr(pad + 32, colors[4], colors[5])
		drawtext("If you fix the problem and update the file the program will " ..
		"resume", pad, pad + 46, colors[3])
		drawhr(pad + 72, colors[4], colors[5])
		drawtext(msg, pad, pad + 90, colors[5], width - pad * 2)

		love.graphics.reset()
	end
end

function lurker.exitinitstate()
	lurker.state = "normal"
	if lurker.protected then
		lurker.initwrappers()
	end
end

function lurker.exiterrorstate()
	lurker.state = "normal"
	for _, v in pairs(lovecallbacknames) do
		love[v] = lurker.funcwrappers[v]
	end
end

function lurker.update()
	if lurker.state == "init" then
		lurker.exitinitstate()
	end
	local diff = time() - lurker.lastscan
	if diff > lurker.interval then
		lurker.lastscan = lurker.lastscan + diff
		local changed = lurker.scan()
		if #changed > 0 and lurker.lasterrorfile then
			local f = lurker.lasterrorfile
			lurker.lasterrorfile = nil
			lurker.hotswapfile(f)
		end
	end
end

function lurker.getchanged()
	local dirs = {}
	for _, f in pairs( lurker.listdir( lurker.path, true, true )) do
		if f:match("%.lua$") and lurker.files[f] ~= lastmodified(f) then
			dirs[#dirs+1] = f
		end
	end
	return dirs
end

function lurker.modname(f)
	return (f:gsub("%.lua$", ""):gsub("[/\\]", "."))
end

function lurker.resetfile(f)
	lurker.files[f] = lastmodified(f)
end

local function lume_time(fn, ...)
	local start = os.clock()
	local rtn = {fn(...)}
	return (os.clock() - start), unpack(rtn)
end

function lurker.hotswapfile(f)
	lurker.print("Hotswapping '{1}'...", {f})
	if lurker.state == "error" then
		lurker.exiterrorstate()
	end
	if lurker.preswap(f) then
		lurker.print("Hotswap of '{1}' aborted by preswap", {f})
		lurker.resetfile(f)
		return
	end
	local modname = lurker.modname(f)
	local t, ok, err = lume_time(lume_hotswap, modname)
	if ok then
		lurker.print("Swapped '{1}' in {2} secs", {f, t})
	else
		lurker.print("Failed to swap '{1}' : {2}", {f, err})
		if not lurker.quiet and lurker.protected then
			lurker.lasterrorfile = f
			lurker.onerror(err, true)
			lurker.resetfile(f)
			return
		end
	end
	lurker.resetfile(f)
	lurker.postswap(f)
	if lurker.protected then
		lurker.updatewrappers()
	end
end

function lurker.scan()
	if lurker.state == "init" then
		lurker.exitinitstate()
	end
	local changed = lurker.getchanged()
	for _, f in pairs( changed ) do
		lurker.hotswapfile( f )
	end
	return changed
end

return lurker.init()
