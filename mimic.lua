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

	bg = {0.05, 0.05, 0.1},
	textColor = {1, 1, 1, 1},
	borderColor = {0.5, 0.5, 0.6, 1},
	win_bg = {0.1, 0.1, 0.15, 1},
	win_titleColor = {0.5, 0.5, 0.6, 1},
	win_close = {0.9, 0.1, 0.4, 1},
	btn_color = {0.15, 0.15, 0.2, 1},
	btn_hover = {0.25, 0.25, 0.4, 1}
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

local ATTRIBUTE_TABLE = {{"instanceBody", "float", 4}, {"instanceColor", "float", 4}, {"instanceBorder", "float", 1}}
local ATTRIBUTE_ZERO = {0, 0, 0, 0,    0, 0, 0, 0,    0}
local BUFFER_INIT_SIZE = 64
local BUFFER_INIT_LIST = {}
--fill init tbl with zeros, to be used by new instance meshs
for n=1, BUFFER_INIT_SIZE do
	BUFFER_INIT_LIST[n] = ATTRIBUTE_ZERO
end

local GLSL_FRAG = [[
	uniform vec4 bordercolor;
	varying vec4 passcolor;
	varying float passborder;

	vec4 effect( vec4 color, Image tex, vec2 texture_coords, vec2 screen_coords )
	{
		vec4 texcolor = Texel(tex, texture_coords);
		texcolor *= passcolor;

		// thanks to a13X_B for the help with this
		float du = dFdx(texture_coords.x);
		bool is_in_border = texture_coords.x > du && texture_coords.x < (1. - du);
		texcolor = mix(texcolor, bordercolor, passborder * (1. -float(is_in_border)));

		float dv = dFdy(-texture_coords.y);
		is_in_border = texture_coords.y > dv && texture_coords.y < (1. - dv);
		texcolor = mix(texcolor, bordercolor, passborder * (1. -float(is_in_border)));

		return texcolor;
	}
]]	

local GLSL_VERT = [[
	attribute vec4 instanceBody;
	attribute vec4 instanceColor;
	attribute float instanceBorder;
	uniform vec2 windowpos;
	varying vec4 passcolor;
	varying float passborder;

	vec4 position(mat4 transform_projection, vec4 vertex_position)
	{
		vertex_position.x *= instanceBody.z;
		vertex_position.x += instanceBody.x + windowpos.x;
		vertex_position.y *= instanceBody.w;
		vertex_position.y += instanceBody.y + windowpos.y;

		passcolor = instanceColor;
		passborder = instanceBorder;

		return transform_projection * vertex_position;
	}
]]

local WINDOWPOS = {0, 0}
local RECTSHADER = gfx.newShader(GLSL_FRAG, GLSL_VERT)

local CHECK_VERTS = 
{
	{0.125,0.6, 0,0.75, 1,1,1,1},
	{0,0.75, 0,0.75, 1,1,1,1},
	{0.25,0.75, 0,0.75, 1,1,1,1},
	{0.25,1, 0,0.75, 1,1,1,1},
	{1,0.25, 0,0.75, 1,1,1,1},
	{0.9,0.1, 0,0.75, 1,1,1,1},
	{0.25,0.75, 0,0.75, 1,1,1,1},

}

local KEY_UP = 1
local KEY_RELEASED = 2
local KEY_DOWN = 3
local KEY_PRESSED = 4

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

local function aabb(a, b)
	local x, y, w, h = a.x, a.y, a.w, a.h
	local x2, y2, w2, h2 = b.x, b.y, b.w, b.h
	return not(x + w < x2 or x2 + w2 < x or y + h < y2 and y + h2 < y)
end

local function overlaps(px, py, x, y, w, h)
	return not(px < x or x + w < px or py < y or y + h < py)
end

-------------------------------------------------------------------------------
-- Theming
-------------------------------------------------------------------------------

function mimic:setTheme(theme)
	theme = theme or DEFAULT_THEME
	self.theme = theme
	self:setFont(theme.font, theme.fontSize)
	RECTSHADER:send("bordercolor", theme.borderColor)

	self.titleHeight = self.fontHeight + theme.padding * 2
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
			txt[4] = self.font:getWidth(txt[1][2])
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
	self.windowStack = {} --sorted list used for drawing
	self.windowStackMap = {} --LUT used to avoid looping over windowStack
	
	--input
	self.hoverWindow = false --the upper-most (z) window the mouse is over
	self.activeWindow = false --the window last clicked on
	self.activeControl = false --the control under the mouse during a press
	self.absoluteMousex = 0 --window-space mouse
	self.absoluteMousey = 0
	self.mousex = 0 --adjusted mouse, relative to liveWindow
	self.mousey = 0

	self.oldMouseLeft = KEY_UP
	self.mouseLeft = KEY_UP

	--dragging
	self.titleHeight = 0
	self.dragWindow = false
	self.dragx = 0
	self.dragy = 0

	self:setTheme(theme or DEFAULT_THEME)
end

function mimic:update()
	if self.oldMouseLeft % 2 == 0 then
		self.mouseLeft = self.mouseLeft - 1
	end
	if self.oldMouseLeft == KEY_RELEASED then
		self.activeControl = false
	end

	self.oldMouseLeft = self.mouseLeft

	--update active window
	local count = #self.windowStack
	local hover = false
	local x, y = self.absoluteMousex, self.absoluteMousey
	for n = count, 1, -1 do
		local window = self.windowStack[n]
		if overlaps(x, y, window.x, window.y, window.w, window.h) then
			hover = not hover and window or hover
			if self.mouseLeft == KEY_PRESSED then
				window.z = count + 1
				self.activeWindow = window
				goto done
			end
		end
	end
	goto skipsort

	::done::
	self:_sortWindowStack()

	::skipsort::
	self.hoverWindow = hover
end

function mimic:draw()
	gfx.clear(self.theme.bg)
	-- love.graphics.print(#self.windowStack, 100, 1)
	
	for n = 1, #self.windowStack do
		local window = self.windowStack[n]
		love.graphics.push()
		love.graphics.translate(window.x, window.y)
		gfx.setShader(RECTSHADER)
		RECTSHADER:send("windowpos", WINDOWPOS)
		RECT_MESH:attachAttribute("instanceBody", window.instMesh, "perinstance")
		RECT_MESH:attachAttribute("instanceColor", window.instMesh, "perinstance")
		RECT_MESH:attachAttribute("instanceBorder", window.instMesh, "perinstance")
		gfx.drawInstanced(RECT_MESH, window.instMax)
		gfx.setShader()

		gfx.draw(window.text)
		love.graphics.pop()
		-- love.graphics.setLineWidth(0.5)
		-- gfx.setColor(self.theme.win_titleColor)
		-- gfx.rectangle("line", window.x+0.5, window.y+0.5, window.w-1, window.h-1)
		-- gfx.print(window.z, window.x, window.y-20)
		-- gfx.print(window.sortingCoef, window.x, window.y-40)

		-- self.windowStack[n] = nil
		-- love.graphics.print(self.mouseLeft, 1, 300)
	end
	-- gfx.push()
	-- love.graphics.clear()
	-- gfx.rotate(0.7853981634)
	-- gfx.rectangle("fill", 100, 0, 80, 40)
	-- gfx.rotate(-0.7853981634 * 2)
	-- gfx.rectangle("fill", 0, 140, 160, 40)
	-- -- gfx.draw(check, 1, 1)
	-- gfx.pop()
end

function mimic:mousemoved(x, y, dx, dy, istouch)
	self.absoluteMousex = x
	self.absoluteMousey = y

	if self.dragWindow then
		local window = self.dragWindow
		window.x = x - self.dragx
		window.y = y - self.dragy
	end
end

function mimic:mousepressed(x, y, btn, istouch, presses)
	local count = #self.windowStack
	for n = count, 1, -1 do
		local window = self.windowStack[n]
		if overlaps(x, y, window.x, window.y, window.w, window.h) then
			window.z = count + 1
			self.activeWindow = window
			goto done
		end
	end

	::done::
	self:_sortWindowStack()

	if btn == 1 then
		self.mouseLeft = KEY_PRESSED
	end
end

function mimic:mousereleased(x, y, btn, istouch, presses)
	if btn == 1 then
		self.mouseLeft = KEY_RELEASED

		self.dragWindow = false
	end
end

function mimic:wheelmoved(x, y)
end

-------------------------------------------------------------------------------
-- Rect Helpers
-------------------------------------------------------------------------------

--create rect / get rect from cache
--will also set the dirty flag if the rect state has changed
--
--! X/Y RELVATIVE TO WINDOW !
--
function mimic:_mkRect(id, x, y, w, h, color, border)
	border = border and 1 or 0

	color = color or self.theme.win_bg
	--get/make the rect
	local rect = self.cache[id]
	if not rect then
		rect = {x, y, w, h, color[1], color[2], color[3], color[4], border}
		self.cache[id] = rect

		--this is a new rect, so dirty and return
		self.liveWindow.instDirty = true
		return rect
	end

	--check whether the dirty flag needs to be set
	if rect[1] == x and rect[2] == y and rect[3] == w and rect[4] == h and
	   rect[5] == color[1] and rect[6] == color[2] and rect[7] == color[3] and rect[8] == color[4] and
	   rect[9] == border then
		return rect
	end

	rect[1] = x
	rect[2] = y
	rect[3] = w
	rect[4] = h
	rect[5] = color[1]
	rect[6] = color[2]
	rect[7] = color[3]
	rect[8] = color[4]
	rect[9] = border

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

	return rect
end

-------------------------------------------------------------------------------
-- Text Helpers
-------------------------------------------------------------------------------	

--create text / get text from cache
--will also set the dirty flag if the text state has changed
function mimic:_mkText(id, str, x, y, color)
	color = color or self.theme.textColor

	--get/create txt
	local txt = self.cache[id]
	if not txt then
		txt = {{color, str}, x, y, self.font:getWidth(str)}
		self.cache[id] = txt
		self.liveWindow.textDirty = true

		return txt
	end

	--check whether dirty flag needs to be set
	--no need to check [4] as it relies on [1]
	if txt[1][2] == str and txt[2] == x and txt[3] == y then
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
		z = 1,
		sortingCoef = 0,
		
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

	window.sortingCoef = initOptions.alwaysOnTop and 1 or 0
	window.sortingCoef = initOptions.alwaysOnBottom and -1 or window.sortingCoef

	if not self.windowStackMap[id] then
		self.windowStackMap[id] = window
		insert(self.windowStack, window)
		window.z = #self.windowStack
		self:_sortWindowStack()
		self.activeWindow = window
	end
	self.liveWindow = window

	--mouse interactions
	local mx, my = self.absoluteMousex, self.absoluteMousey
	self.mousex, self.mousey = mx - window.x, my - window.y

	if self.mouseLeft == KEY_PRESSED and window == self.activeWindow and overlaps(mx, my, window.x, window.y, window.w, self.titleHeight) then
		self.dragx = mx - window.x
		self.dragy = my - window.y
		self.dragWindow = window
	end

	--construct header and such
	local bg = self:_mkRect(id, 0, 0, window.w, window.h, nil, true)
	self:_addRect(bg)

	local pad = self.theme.padding
	local txt = self:_mkText(id .. ">headtxt", label, pad, pad)
	local header = self:_mkRect(id .. ">head", 0, 0, window.w, self.fontHeight + pad * 2, self.theme.win_titleColor)

	local closebg = self:_mkRect(id ..">close", window.w-32 - pad, 0, 33, self.fontHeight + pad, self.theme.win_close)
	local closetxt = self:_mkText(id .. ">closttxt", "X", window.w-26, pad * 0.5)

	self:_addRect(header)
	self:_addText(txt)
	self:_addRect(closebg)
	self:_addText(closetxt)


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

function mimic:_sortWindowStack()
	local count = #self.windowStack
	table.sort(self.windowStack, function(a, b)
		local offa, offb = 0, 0
		if a.sortingCoef ~= 0 and a.sortingCoef == b.sortingCoef then
			if self.activeWindow == a then
				offa = 1
			else
				offb = 1
			end
		end

		return a.z + offa + count * a.sortingCoef < b.z + offb + count * b.sortingCoef
	end)

	for k, v in ipairs(self.windowStack) do
		v.z = k
	end
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
	local clicked
	local label, id = splitLabelId(str)
	local x, y = self.liveWindow.nextx, self.liveWindow.nexty
	local pad = self.theme.padding
	local height = self.fontHeight + pad * 2

	--text is static, and we need it's width first
	local txt = self:_mkText(id .. ".txt", label, x + pad * 2, y + pad * 2)
	local width = txt[4] + pad * 2
	
	--mouse interactions
	local color = self.theme.btn_color
	if self.liveWindow == self.hoverWindow and overlaps(self.mousex, self.mousey, x, y, width, height) then
		if not self.activeControl then
			if self.mouseLeft == KEY_PRESSED then
				self.activeControl = id
				color = self.theme.btn_down
			else
				color = self.theme.btn_hover
			end
		elseif self.activeControl == id then
			color = self.theme.btn_down
			if self.mouseLeft == KEY_RELEASED then
				clicked = true	
			end
		end
	end
	
	--now we can create the button rect
	local bg = self:_mkRect(id, x + pad, y + pad, width, height, color)

	self:_addRect(bg)
	self:_addText(txt)

	self.liveWindow.nexty = self.liveWindow.nexty + height + pad

	return clicked
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