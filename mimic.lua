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
-- Main Callbacks
-------------------------------------------------------------------------------

function mimic:init()
	self.cache = setmetatable({}, {__mode = "v"})
	self.windows = {}
	self.liveWindow = false --the window currently being modified
	self.windowStack = {}

	self.theme = 
	{
		font = gfx.getFont(),
		padding = 5,

		win_bg = {0.1, 0.1, 0.15, 1}
	}
end

function mimic:draw()
	-- love.graphics.print(#self.windowStack, 100, 1)
	gfx.setShader(RECTSHADER)

	for n = #self.windowStack, 1, -1 do
		local window = self.windowStack[n]
		RECT_MESH:attachAttribute("instanceBody", window.instMesh, "perinstance")
		RECT_MESH:attachAttribute("instanceColor", window.instMesh, "perinstance")

		gfx.drawInstanced(RECT_MESH, window.instMax)
		self.windowStack[n] = nil
	end
	gfx.setShader()

end

-------------------------------------------------------------------------------
-- Rect Helpers
-------------------------------------------------------------------------------

--create rect / get rect from cache
--will also set the dirty flag if the rect state has changed
function mimic:_mkRect(id, x, y, w, h, color)
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
		window.instMesh = gfx.newMesh(ATTRIBUTE_TABLE, list, nil, "dynamic")
		window.instDirty = true
	end

	return rect
end
	
-------------------------------------------------------------------------------
-- Windows
-------------------------------------------------------------------------------

function mimic:_mkWindow(id, x, y)
	local window = 
	{
		id = id,
		x = x,
		y = y,
		w = 0,
		h = 0,
		
		--geometry
		instMesh = gfx.newMesh(ATTRIBUTE_TABLE, BUFFER_INIT_LIST, nil, "dynamic"),
		instList = clone(BUFFER_INIT_LIST),
		instMax = BUFFER_INIT_SIZE,
		instIndex = 1,
		instCount = 0,
		lastInstCount = 0,
		instDirty = true,

		--text
		text = gfx.newText(self.theme.font)
	}

	self.windows[id] = window
	
	return window
end

function mimic:_mkWindowHeader(id, label, x, y)
	local bgid = id .. ".bg"
	local bg = self.cache[bgid]
	if not bg then
		bg = {x, y, 100, 25}

	end
	self.cache[bgid] = bg

	return bg
end



function mimic:windowBegin(str, initOptions)
	local label, id = splitLabelId(str)
	
	local window = self.windows[id]
	if not window then
		window = self:_mkWindow(id, initOptions.x, initOptions.y)
	end

	self.liveWindow = window
	insert(self.windowStack, window)

	--construct header and such
	local bg = self:_mkWindowHeader(id .. "head", label, 100, 100)
	self:_addRect(bg)

	for n = 1, 10 do
		local r = self:_mkRect(id .. "head" .. n, 100, 100 + n * 28, 100, 25)
		self:_addRect(r)
	end

	
	-- window.instList[self.instIndex] = self:_mkWindowHeader(id)
	-- self.instIndex = self.instIndex + 1
end

function mimic:windowEnd()
	local window = self.liveWindow
	-- local dirty = window.instDirty

	--zero out unused mesh instances
	for n = window.instIndex , window.instCount do
		window.instList[n] = ATTRIBUTE_ZERO
	end

	--refresh mesh if needed
	if window.instDirty then
		window.instMesh:setVertices(window.instList)
		window.instDirty = false
	end

	--cleanup
	window.instCount = window.instIndex - 1
	window.instIndex = 1
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