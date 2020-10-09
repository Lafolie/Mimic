--[[
Copyright © 2020 Dale Longshaw

Permission is hereby granted, free of charge, to any person obtaining a copy of 
this software and associated documentation files (the “Software”), to deal in 
the Software without restriction, including without limitation the rights to 
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies 
of the Software, and to permit persons to whom the Software is furnished to do 
so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all 
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR 
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, 
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE 
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER 
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, 
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE 
SOFTWARE.
]]

local mimic = {}

-------------------------------------------------------------------------------
-- Constants & private methods
-------------------------------------------------------------------------------

local DEFAULT_THEME = 
{
	font = nil,
	fontSize = 12,
	padding = 5,

	textColor = {1, 1, 1, 1},
	win_bg = {0.1, 0.1, 0.15, 1},
	win_titleColor = {0.5, 0.5, 0.6, 1},
	btn_color = {0.15, 0.15, 0.2, 1}
}


local insert, gfx = table.insert, love.graphics

--unit rect
local RECT_VERTS = 
{
	{0,0, 0,0, 1,1,1,1},
	{1,0, 1,0, 0,1,1,1},
	{1,1, 1,1, 1,0,1,1},
	{0,1, 0,1, 1,1,0,1},
}

local RECT_MESH = gfx.newMesh(RECT_VERTS) --mesh to be instanced

local ATTRIBUTE_TABLE = {{"instanceBody", "float", 4}, {"instanceColor", "float", 4}}
local ATTRIBUTE_ZERO = {0, 0, 0, 0,    0, 0, 0, 0}
local BUFFER_INIT_SIZE = 64
local BUFFER_INIT_LIST = {}
--fill init tbl with zeros, to be used by new instance meshs
for n=1, BUFFER_INIT_SIZE do
	BUFFER_INIT_LIST[n] = ATTRIBUTE_ZERO
end

local GLSL_FRAG = [[
	varying vec4 passColor;

	vec4 effect( vec4 color, Image tex, vec2 texture_coords, vec2 screen_coords )
	{
		vec4 texcolor = Texel(tex, texture_coords);
		return texcolor * passColor;
	}
]]

local GLSL_VERT = [[
	attribute vec4 instanceBody;
	attribute vec4 instanceColor;
	varying vec4 passColor;

	vec4 position(mat4 transform_projection, vec4 vertex_position)
	{
		vertex_position.x *= instanceBody.z;
		vertex_position.x += instanceBody.x;
		vertex_position.y *= instanceBody.w;
		vertex_position.y += instanceBody.y;

		passColor = instanceColor;

		return transform_projection * vertex_position;
	}
]]

local RECTSHADER = gfx.newShader(GLSL_FRAG, GLSL_VERT)

local function splitLabelId(str)
	local lbl = str:match("^(.+)##.*") or str
	return lbl, str
end

local function clone(tbl)
	local t = {}
	for k, v in ipairs(tbl) do
		t[k] = v
	end
	return t
end

-------------------------------------------------------------------------------
-- Theming
-------------------------------------------------------------------------------

function mimic:setTheme(theme)
	theme = theme or DEFAULT_THEME
	self.theme = theme
	self:setFont(theme.font, theme.fontSize)

	self.cache = {} --purge the cache, everything needs to be rebuilt anyway
end

function mimic:setFont(path, size)
	self.font = path and gfx.newFont(path, size) or gfx.getFont()

	--regenerate text batches
	for id, window in pairs(self.windows) do
		window.text:release()
		window.text = gfx.newText(self.font)
		window.textDirty = true
		
		--in some cases we also need to update the string widths
		for k, txt in ipairs(window.textList) do
			txt[4] = self.font:getWidth(txt[1])
		end
	end

	self.fontHeight = self.font:getHeight()
end

-------------------------------------------------------------------------------
-- Main Callbacks
-------------------------------------------------------------------------------

function mimic:init(theme)
	self.cache = setmetatable({}, {__mode = "v"})
	self.windows = {}
	self.liveWindow = false --the window currently being modified
	self.windowStack = {}

	self:setTheme(theme or DEFAULT_THEME)
end

function mimic:draw()
	-- love.graphics.print(#self.windowStack, 100, 1)
	
	for n = #self.windowStack, 1, -1 do
		local window = self.windowStack[n]
		gfx.setShader(RECTSHADER)
		RECT_MESH:attachAttribute("instanceBody", window.instMesh, "perinstance")
		RECT_MESH:attachAttribute("instanceColor", window.instMesh, "perinstance")
		gfx.drawInstanced(RECT_MESH, window.instMax)
		gfx.setShader()

		gfx.draw(window.text, window.x, window.y)
		self.windowStack[n] = nil
	end

end

-------------------------------------------------------------------------------
-- Rect Helpers
-------------------------------------------------------------------------------

--create rect / get rect from cache
--will also set the dirty flag if the rect state has changed
--
--! X/Y RELVATIVE TO WINDOW !
--
function mimic:_mkRect(id, x, y, w, h, color)
	x = x + self.liveWindow.x
	y = y + self.liveWindow.y

	color = color or self.theme.win_bg
	--get/make the rect
	local rect = self.cache[id]
	if not rect then
		rect = {x, y, w, h, color[1], color[2], color[3], color[4]}
		self.cache[id] = rect

		--this is a new rect, so dirty and return
		self.liveWindow.instDirty = true
		return rect
	end

	--check whether the dirty flag needs to be set
	if rect[1] == x and rect[2] == y and rect[3] == w and rect[4] == h then
		return rect
	end

	rect[1] = x
	rect[2] = y
	rect[3] = w
	rect[4] = h

	self.liveWindow.instDirty = true
	return rect
end

--add a rect instance to the live window, and return it
function mimic:_addRect(rect)
	local window = self.liveWindow
	local i = window.instIndex
	local list = window.instList

	--check to see if we need to set the dirty flag
	--(whether the draw list differs from last frame)
	if (not window.instDirty) and list[i] ~= rect then
		window.instDirty = true
	end

	list[i] = rect
	window.instIndex = i + 1

	--if the vert index exceeds the buffer size, we need to make a new mesh
	--and expand the instance list
	if i > window.instMax then
		--[[
			Here we add the initial buffer size, so the vertex buffer increases
			in 'blocks' of the initial size.

			An alternative worth trying is the Lua table method of doubling
			the size each time it is recreated
		]]
		window.instMax = window.instMax + BUFFER_INIT_SIZE

		for n = #list, window.instMax do
			list[n] = ATTRIBUTE_ZERO
		end
		window.instMesh:release()
		window.instMesh = gfx.newMesh(ATTRIBUTE_TABLE, list, nil, "dynamic")
		window.instDirty = true
	end

	-- --expand the window bg if required
	-- local h = rect[2] - window.y + rect[4]
	-- if window.h < h then
	-- 	window.h = h + self.theme.padding
	-- 	self.instDirty = true
	-- end

	return rect
end

-------------------------------------------------------------------------------
-- Text Helpers
-------------------------------------------------------------------------------	

--create text / get text from cache
--will also set the dirty flag if the text state has changed
function mimic:_mkText(id, str, x, y)
	--get/create txt
	local txt = self.cache[id]
	if not txt then
		txt = {str, x, y, self.font:getWidth(str)}
		self.cache[id] = txt
		self.liveWindow.textDirty = true

		return txt
	end

	--check whether dirty flag needs to be set
	--no need to check [4] as it relies on [1]
	if txt[1] == str and txt[2] == x and txt[3] == y then
		return txt
	end

	txt[1] = str
	txt[2] = x
	txt[3] = y
	txt[4] = self.font:getWidth(str)

	self.liveWindow.textDirty = true
	return txt
end

--add text to the live window text object, and return it
function mimic:_addText(txt)
	local window = self.liveWindow
	local i = window.textIndex
	local list = window.textList

	--check to see if we need to set the dirty flag
	--(whether the draw list differs from last frame)
	if (not window.textDirty) and list[i] ~= txt then
		window.textDirty = true
	end

	list[i] = txt
	window.textIndex = i + 1

	return txt
end

-------------------------------------------------------------------------------
-- Windows
-------------------------------------------------------------------------------

--internal helper for window creation
function mimic:_mkWindow(id, x, y, w)
	local window = 
	{
		id = id,
		x = x,
		y = y,
		w = w,
		h = 0,
		
		--layout control
		nextx = 0,
		nexty = 0,

		--geometry
		instMesh = gfx.newMesh(ATTRIBUTE_TABLE, BUFFER_INIT_LIST, nil, "dynamic"),
		instList = clone(BUFFER_INIT_LIST),
		instMax = BUFFER_INIT_SIZE,
		instIndex = 1,
		instCount = 0,
		instDirty = true,

		--text
		text = gfx.newText(self.font),
		textDirty = true,
		textList = {},
		textIndex = 1,
		textCount = 0,
	}

	self.windows[id] = window
	
	return window
end

function mimic:windowBegin(str, initOptions)
	local label, id = splitLabelId(str)
	
	local window = self.windows[id]
	if not window then
		window = self:_mkWindow(id, initOptions.x, initOptions.y, initOptions.w or 256)
	end

	self.liveWindow = window
	insert(self.windowStack, window)

	--construct header and such
	local bg = self:_mkRect(id, 0, 0, window.w, window.h)
	self:_addRect(bg)

	local pad = self.theme.padding
	local txt = self:_mkText(id .. ">headtxt", label, pad, pad)
	local header = self:_mkRect(id .. ">head", 0, 0, window.w, self.fontHeight + pad * 2, self.theme.win_titleColor)

	self:_addRect(header)
	self:_addText(txt)

	window.nexty = self.fontHeight + pad * 2
end

function mimic:windowEnd()
	local window = self.liveWindow
	--zero out unused mesh instances
	if window.instIndex - 1 ~= window.instCount then
		for n = window.instIndex , window.instCount do
			window.instList[n] = ATTRIBUTE_ZERO
		end
		window.instDirty = true
	end

	--refresh mesh if needed
	if window.instDirty then
		--update the bg dimensions first
		window.h = window.nexty + self.theme.padding
		window.instList[1][4] = window.h

		--send verts
		window.instMesh:setVertices(window.instList)
		window.instDirty = false
		-- print "rebuilt mesh"
	end

	--zero out unused text instances
	if window.textIndex - 1 ~= window.textCount then
		for n = window.textIndex, window.textCount do
			window.textList[n] = nil
		end
		window.textDirty = true
	end

	--refresh text if needed
	if window.textDirty then
		local text = window.text
		local list = window.textList
		text:clear()
		for n = 1, #list do
			local txt = list[n]
			text:add(txt[1], txt[2], txt[3])
		end
		window.textDirty = false
		-- print "rebuilt text"
	end

	--cleanup
	window.instCount = window.instIndex - 1
	window.instIndex = 1
	window.textCount = window.textIndex - 1
	window.textIndex = 1
	window.nextx = 0
	window.nexty = 0
	self.liveWindow = false
end


-------------------------------------------------------------------------------
-- Controls
-------------------------------------------------------------------------------

function mimic:text(str, ...)
	if (...) then
		str = str:format(...)
	end

	print(str)
end

function mimic:button(str)
	local label, id = splitLabelId(str)
	local x, y = self.liveWindow.nextx, self.liveWindow.nexty
	local pad = self.theme.padding
	local font = self.font
	local height = font:getHeight() + pad * 2

	local txt = self:_mkText(id .. ".txt", label, x + pad * 2, y + pad * 2)
	local bg = self:_mkRect(id, x + pad, y + pad, txt[4] + pad * 2, height, self.theme.btn_color)

	self:_addRect(bg)
	self:_addText(txt)

	self.liveWindow.nexty = self.liveWindow.nexty + height + pad
end

function mimic:rect(str, x, y, w, h)
	local label, id = splitLabelId(str)
	local rect = self:_mkRect(id, x, y, w, h)
	self:_addRect(rect)
end

return function(id)
	local inst = setmetatable({}, {__index = mimic})
	inst:init(id)
	return inst
end