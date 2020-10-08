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

local ATTRIBUTE_TABLE = {{"instance", "float", 4}}
local ATTRIBUTE_ZERO = {0, 0, 0, 0}
local BUFFER_INIT_SIZE = 64
local BUFFER_INIT_LIST = {}
--fill init tbl with zeros, to be used by new instance meshs
for n=1, BUFFER_INIT_SIZE do
	BUFFER_INIT_LIST[n] = ATTRIBUTE_ZERO
end

local pixelcode = [[
    vec4 effect( vec4 color, Image tex, vec2 texture_coords, vec2 screen_coords )
    {
        vec4 texcolor = Texel(tex, texture_coords);
        return texcolor * color;
    }
]]

local vertexcode = [[
	attribute vec4 instance;

	vec4 position(mat4 transform_projection, vec4 vertex_position)
	{
		vertex_position.x *= instance.z;
		vertex_position.x += instance.x;
		vertex_position.y *= instance.w;
		vertex_position.y += instance.y;

		return transform_projection * vertex_position;
	}
]]

local uishader = gfx.newShader(pixelcode, vertexcode)

local inst = {}
for n= 1, 10 do
	insert(inst, {n * 48, 48, 32, 32})
end
-- inst[3][1] = 0
-- inst[3][2] = 0
inst[3][3] = 0
inst[3][4] = 0


local function splitLabelId(str)
	local lbl, id = str:match("^(.+)(##.*)")
	if not lbl then
		lbl = str
		id = str
	end
	return lbl, id
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

	self.attributeMesh = gfx.newMesh(ATTRIBUTE_TABLE, inst)
	RECT_MESH:attachAttribute("instance", self.attributeMesh, "perinstance")

	self.theme = 
	{
		font = gfx.getFont(),
		padding = 5,
	}
end

function mimic:draw()
	-- love.graphics.print(#self.windowStack, 100, 1)
	gfx.setShader(uishader)
	-- gfx.drawInstanced(RECT_MESH, 10)
	for n = #self.windowStack, 1, -1 do
		local window = self.windowStack[n]
		RECT_MESH:attachAttribute("instance", window.instMesh, "perinstance")
		gfx.drawInstanced(RECT_MESH, window.instMax)
		self.windowStack[n] = nil
		-- table.remove(self.windowStack, n)
	end
	gfx.setShader()

end

-------------------------------------------------------------------------------
-- Rect Helpers
-------------------------------------------------------------------------------

function mimic:_mkRect()

end

--add a rect instance to the live window
function mimic:_addRect(rect)
	local window = self.liveWindow
	local i = window.instIndex
	local list = window.instList

	--check to see if we need to set the dirty flag
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
	local id, label = splitLabelId(str)
	
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
		local r = self:_mkWindowHeader(id .. "head" .. n, label, 100, 100 + n * 28)
		self:_addRect(r)
	end

	
	-- window.instList[self.instIndex] = self:_mkWindowHeader(id)
	-- self.instIndex = self.instIndex + 1
end

function mimic:windowEnd()
	local window = self.liveWindow

	local dirty = window.instDirty
	--zero out unused mesh instances
	for n = window.instIndex , window.instCount do
		window.instList[n] = ATTRIBUTE_ZERO
	end

	--refresh mesh if needed
	if dirty then
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

return function(id)
	local inst = setmetatable({}, {__index = mimic})
	inst:init(id)
	return inst
end