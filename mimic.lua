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

--we only support Löve 11.3 upwards
assert(love.getVersion() >= 11, "Mimic Error: Incompatible Löve version. Version 11.3+ is required to use this library.")

local mimic = {}

-------------------------------------------------------------------------------
-- Constants & private methods
-------------------------------------------------------------------------------
print(...)
local DEFAULT_THEME = 
{
	font = nil,
	fontSize = 12,
	padding = 5,
	scrollSize = 32,

	bg = {0.05, 0.05, 0.1},
	textColor = {1, 1, 1, 1},
	borderColor = {0.5, 0.5, 0.6, 1},
	win_bg = {0.1, 0.1, 0.15, 1},
	win_titleColor = {0.5, 0.5, 0.6, 1},
	win_close = {0.9, 0.1, 0.4, 1},
	btn_color = {0.15, 0.15, 0.2, 1},
	btn_hover = {0.25, 0.25, 0.4, 1},
}

local MIMIC_VERSION = "0.1"

local insert, remove, concat, gfx = table.insert, table.remove, table.concat, love.graphics

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

local BUFFER_INIT_SIZE = 64 --control instance count
local BUFFER_INIT_LIST = {} --control instance buffer (elements inside a window)

local BUFFER_WINDOW_INIT_SIZE = 4 --main window count
local BUFFER_WINDOW_INIT_LIST = {} --main window buffer (bg & head: non-scrolling)

--fill init tbls with zeros, to be used by new instance meshs
for n=1, BUFFER_INIT_SIZE do
	BUFFER_INIT_LIST[n] = ATTRIBUTE_ZERO
end

for n=1, BUFFER_WINDOW_INIT_SIZE do
	BUFFER_WINDOW_INIT_LIST[n] = ATTRIBUTE_ZERO
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

local KEY_UP = 1
local KEY_RELEASED = 2
local KEY_DOWN = 3
local KEY_PRESSED = 4

local BTN_UP = 1
local BTN_HOVER = 2
local BTN_DOWN = 3
local BTN_CLICK = 4

local COLOR_WHITE = {1, 1, 1, 1}
local COLOR_WHITE_HALF = {1, 1, 1, 0.5}
local COLOR_BLACK = {0, 0, 0, 1}

local function splitLabelId(str)
	local lbl, id = str:match("^(.*)(###.*)")
	if id then
		return lbl, id
	end

	lbl = str:match("^(.+)##.*") or str
	return lbl, str
end

-- print(splitLabelId("No ID"))
-- print(splitLabelId("Static ID##Hello"))
-- print(splitLabelId("##Only Static"))
-- print(splitLabelId("Dynamic ID###World"))
-- print(splitLabelId("###Only Dynamic"))

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

--API functions set pending theme, as it can't be changed mid-frame
--e.g. from a mimic:button() callback
function mimic:setTheme(theme)
	--we check against nil, so or false is required here
	self.pendingTheme = theme or false
end

function mimic:setFont(path, size)
	self.pendingFontPath = path or false
	self.pendingFontSize = size
end

function mimic:_setTheme(theme)
	theme = theme or DEFAULT_THEME
	if theme ~= DEFAULT_THEME then
		theme = setmetatable(theme, {__index = DEFAULT_THEME})
	end
	self.theme = theme
	self:_setFont(theme.font, theme.fontSize)
	RECTSHADER:send("bordercolor", theme.borderColor)

	self.titleHeight = self.fontHeight + theme.padding * 2
	self:_buildAtlas()
	self:_regenSpriteBatches()
	self.cache = setmetatable({}, {__mode = "v"}) --purge the cache, everything needs to be rebuilt anyway
end

function mimic:_setFont(path, size)
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

function mimic:_buildAtlas()
	local radius = self.fontHeight + self.theme.padding
	local rot = 0.7853981634
	local push, pop = gfx.push, gfx.pop
	local size = self.fontHeight
	local dimensions = size * 3
	local canvas = gfx.newCanvas(dimensions, dimensions)

	--[[
		checkbox
		radio
		tri
		X
	]]

	-- local size = (self.theme.fontSize) * 1

	gfx.setCanvas(canvas)
		-- gfx.clear(0.1, 0.1, 0.1, 1)
	push()

	--[[
		THIS NEEDS TO BE REDONE WITHOUT GFX.SCALE:
		PRODUCES UGLY RESULTS
		SCALE PARAMETERS INSTEAD
	]]

	--begin checkbox
	gfx.setColor(0.05, 0.05, 0.05)
	gfx.scale(size)
	gfx.translate(1, 0)
	-- gfx.rectangle("fill", 0, 0, 1, 1)
	--draw the checkbox check
	--wtf, but it works
	push()
		gfx.translate(0.2, 0.5)
		gfx.rotate(rot)
		gfx.setColor(1, 1, 1, 1)
		gfx.rectangle("fill", 0, 0, 0.25, 0.2)

		gfx.rotate(-rot)
		gfx.translate(0, 0.28)
		gfx.rotate(-rot)
		gfx.rectangle("fill", 0, 0, 0.85, 0.2)
	pop()

	--draw the radio empty
	gfx.translate(1, 0)
	gfx.setColor(0.05, 0.05, 0.05)
	-- gfx.rectangle("fill", 0, 0, 1, 1)

	gfx.setColor(0, 0, 0, 0.5)
	-- gfx.circle("fill", 0.5, 0.5, 0.45)
	gfx.setColor(1, 1, 1, 1)
	gfx.setLineWidth(0.75/size)
	gfx.circle("line", 0.5, 0.5, 0.45)
	gfx.setLineWidth(1)

	--draw the radio full
	gfx.translate(-2, 1)
	gfx.setColor(0.05, 0.05, 0.05)
	-- gfx.rectangle("fill", 0, 0, 1, 1)
	
	gfx.setColor(0, 0, 0, 0.5)
	-- gfx.circle("fill", 0.5, 0.5, 0.45)
	gfx.setColor(1, 1, 1, 1)
	gfx.setLineWidth(0.5/size)
	gfx.circle("line", 0.5, 0.5, 0.45)
	gfx.setLineWidth(1)

	gfx.setColor(1, 1, 1, 1)
	gfx.circle("fill", 0.5, 0.5, 0.275)

	--draw the right tri
	gfx.translate(1, 0)
	gfx.setColor(0.05, 0.05, 0.05)
	-- gfx.rectangle("fill", 0, 0, 1, 1)

	gfx.setColor(1, 1, 1, 1)
	gfx.polygon("fill", 0.1, 0.1, 0.1, 0.9, 0.9, 0.5)

	--draw the down tri
	gfx.translate(1, 0)
	gfx.setColor(0.05, 0.05, 0.05)
	-- gfx.rectangle("fill", 0, 0, 1, 1)

	gfx.setColor(1, 1, 1, 1)
	gfx.polygon("fill", 0.1, 0.1, 0.9, 0.1, 0.5, 0.9)

	--draw the x
	gfx.translate(-2, 1)
	gfx.setColor(0.05, 0.05, 0.05)
	-- gfx.rectangle("fill", 0, 0, 1, 1)

	gfx.setColor(1, 1, 1, 1)
	gfx.polygon("fill", 0.25, 0.1, 0.9, 0.75, 0.75, 0.9, 0.1, 0.25)
	gfx.polygon("fill", 0.1, 0.75, 0.75, 0.1, 0.9, 0.25, 0.25, 0.9)

	--end operations
	pop()
	gfx.setCanvas()
	
	self.atlas = gfx.newImage(canvas:newImageData())
	canvas:release()

	--generate quads
	local quads = {}
	for y = 0, 2 do
		local yy = y * size
		for x = 0, 2 do
			local quad = gfx.newQuad(x * size, yy, size, size, dimensions, dimensions)
			insert(quads, quad)
		end
	end
	self.atlasQuads = quads
end

local function _regenPanelSpriteBatches(panel)
	panel.spriteBatch:release()
	panel.spriteBatch = gfx.newSpriteBatch(self.atlas)
	panel.quadDirty = true
	for _, child in ipairs(panel.children) do
		_regenPanelSpriteBatches(child)
	end
end

function mimic:_regenSpriteBatches()
	for _, window in ipairs(self.windows) do
		_regenPanelSpriteBatches(window)
	end
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
	self.panelStack = {}
	self.livePanel = false
	self.idStack = {}
	self.idPrefix = ""

	--input
	self.hoverWindow = false --the upper-most (z) window the mouse is over
	self.activeWindow = false --the window last clicked on
	self.activeControl = false --the control under the mouse during a press
	self.hoverPanel = false --the inner-most panel of the hoverWindow the mouse is over
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

	self:_setTheme(theme or DEFAULT_THEME)
end

local function checkPanelHover(panel, x, y)
	if overlaps(x, y, panel.w, panel.h) then

	end
end

function mimic:update()

	--false is a valid arg, so check explicitly for nil
	if self.pendingTheme ~= nil then
		self:_setTheme(self.pendingTheme)
		self.pendingTheme = nil
	end

	if self.pendingFontPath ~= nil then
		self:_setFont(self.pendingFontPath, self.pendingFontSize)
		self.pendingFontPath = nil
		self.pendingFontSize = nil
	end

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

	-- --update hover panel
	-- if hover then

	-- end
end

-- local function _drawPanel(instMesh, instCount, text, spriteBatch)
-- 	gfx.setShader(RECTSHADER)
-- 	RECTSHADER:send("windowpos", WINDOWPOS)
-- 	RECT_MESH:attachAttribute("instanceBody", instMesh, "perinstance")
-- 	RECT_MESH:attachAttribute("instanceColor", instMesh, "perinstance")
-- 	RECT_MESH:attachAttribute("instanceBorder", instMesh, "perinstance")
-- 	gfx.drawInstanced(RECT_MESH, instCount)
-- 	gfx.setShader()
-- 	gfx.draw(text)
-- 	gfx.setBlendMode("alpha", "premultiplied")
-- 	gfx.draw(spriteBatch)
-- 	gfx.setBlendMode("alpha", "alphamultiply")
-- end

local function _drawPanel(panel)
	gfx.push()
	gfx.translate(panel.x, panel.y + panel.scrolly)

	gfx.setShader(RECTSHADER)
	RECTSHADER:send("windowpos", WINDOWPOS)
	RECT_MESH:attachAttribute("instanceBody", panel.instMesh, "perinstance")
	RECT_MESH:attachAttribute("instanceColor", panel.instMesh, "perinstance")
	RECT_MESH:attachAttribute("instanceBorder", panel.instMesh, "perinstance")
	gfx.drawInstanced(RECT_MESH, panel.instCount)
	gfx.setShader()
	gfx.draw(panel.text)
	gfx.setBlendMode("alpha", "premultiplied")
	gfx.draw(panel.spriteBatch)
	gfx.setBlendMode("alpha", "alphamultiply")

	for _, child in ipairs(panel.children) do
		_drawPanel(child)
	end
	gfx.pop()
end

function mimic:draw()
	gfx.clear(self.theme.bg)
	-- love.graphics.print(#self.windowStack, 100, 1)
	
	for n = 1, #self.windowStack do
		local window = self.windowStack[n]
		_drawPanel(window)


		-- gfx.print(window.sortingCoef, window.x, window.y-40)
		-- gfx.print(window.quadCount, window.x, window.y-40)

	end

	gfx.draw(self.atlas, 0, 100)
end

function mimic:mousemoved(x, y, dx, dy, istouch)
	self.absoluteMousex = x
	self.absoluteMousey = y

	if self.dragWindow then
		local window = self.dragWindow
		local w, h = gfx.getDimensions()
		window.x = math.max(-window.w + 16, math.min(x - self.dragx, w - 16))
		window.y = math.max(0, math.min(y - self.dragy, h - 16))
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

	goto skipsort

	::done::
	self:_sortWindowStack()

	::skipsort::

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
	local window = self.activeWindow
	if window then
		window.scrolly = window.scrolly + y
	end
end

-------------------------------------------------------------------------------
-- ID Stack
-------------------------------------------------------------------------------

function mimic:pushID(id)
	insert(self.idStack, id)
	self.idPrefix = concat(self.idStack, ">")
end

function mimic:popID(id)
	remove(self.idStack, #self.idStack)
	self.idPrefix = concat(self.idStack, ">")
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
		self.livePanel.instDirty = true

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

	self.livePanel.instDirty = true
	return rect
end

--add a rect instance to the live window, and return it
function mimic:_addRect(rect)
	-- do return end
	local panel = self.livePanel
	local i = panel.instIndex
	local list = panel.instList

	--check to see if we need to set the dirty flag
	--(whether the draw list differs from last frame)
	if (not panel.instDirty) and list[i] ~= rect then
		panel.instDirty = true
	end

	list[i] = rect
	panel.instIndex = i + 1

	--if the vert index exceeds the buffer size, we need to make a new mesh
	--and expand the instance list
	if i > panel.instMax then
		--[[
			Here we add the initial buffer size, so the vertex buffer increases
			in 'blocks' of the initial size.

			An alternative worth trying is the Lua table method of doubling
			the size each time it is recreated
		]]
		panel.instMax = panel.instMax + BUFFER_INIT_SIZE

		for n = #list, panel.instMax do
			list[n] = ATTRIBUTE_ZERO
		end
		panel.instMesh:release()
		panel.instMesh = gfx.newMesh(ATTRIBUTE_TABLE, list, nil, "dynamic")
		panel.instDirty = true
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
		self.livePanel.textDirty = true

		return txt
	end

	--check whether dirty flag needs to be set
	--no need to check [4] as it relies on [1]
	if txt[1][2] == str and txt[2] == x and txt[3] == y then
		return txt
	end

	txt[1][1] = color
	txt[1][2] = str
	txt[2] = x
	txt[3] = y
	txt[4] = self.font:getWidth(str)

	self.livePanel.textDirty = true
	return txt
end

--add text to the live window text object, and return it
function mimic:_addText(txt)
	-- do return end
	local panel = self.livePanel
	local i = panel.textIndex
	local list = panel.textList

	--check to see if we need to set the dirty flag
	--(whether the draw list differs from last frame)
	if (not panel.textDirty) and list[i] ~= txt then
		panel.textDirty = true
	end

	list[i] = txt
	panel.textIndex = i + 1

	return txt
end

-------------------------------------------------------------------------------
-- Quad Helpers
-------------------------------------------------------------------------------

function mimic:_mkQuad(id, spr, x, y, color)
	color = color or COLOR_WHITE
	local quad = self.cache[id]
	if not quad then
		quad = {self.atlasQuads[spr], x, y, color}
		self.cache[id] = quad
		self.livePanel.quadDirty = true
		return quad
	end

	--check to see whether we need to set the dirty flag
	if quad[1] == self.atlasQuads[spr] and quad[2] == x and quad[3] == y and quad[4] == color then
		return quad
	end

	quad[1] = self.atlasQuads[spr]
	quad[2] = x
	quad[3] = y
	quad[4] = color

	self.livePanel.quadDirty = true

	return quad
end

function mimic:_addQuad(quad)
	-- do return end
	local panel = self.livePanel
	local i = panel.quadIndex
	local list = panel.quadList

	--check to see if we need to set the dirty flag
	--(whether the draw list differs from last frame)
	if (not panel.quadDirty) and list[i] ~= quad then
		panel.quadDirty = true
	end

	list[i] = quad
	panel.quadIndex = i + 1

	return quad
end

-------------------------------------------------------------------------------
-- Panels
-------------------------------------------------------------------------------

function mimic:_mkPanel(id, x, y, w, h)
	local panel = self.cache[id]
	if not panel then
		panel =
		{
			id = id,
			--render properties
			x = x, --render offset
			y = y,
			w = w, --render size
			h = h,
			--scroll properties
			canScroll = false,
			scrollx = 0, --scroll offset
			scrolly = 0,
			sw = w, --scroll size (passed to scissor)
			sh = h,
			scrollBarx = false, --scroll bar reference
			scrollBary = false,

			--layout control
			children = {}, --child panels
			childIndex = 1,
			childCount = 0,
			nextx = 0,
			nexty = 0,
			treeStates = {},

			--non-scrolling visuals
			bgRect = false,

			--geometry
			instMesh = gfx.newMesh(ATTRIBUTE_TABLE, BUFFER_INIT_LIST, nil, "dynamic"),
			instDirty = true,
			instList = clone(BUFFER_INIT_LIST),
			instMax = BUFFER_INIT_SIZE,
			instIndex = 1,
			instCount = 0,
			
			--text
			text = gfx.newText(self.font),
			textDirty = true,
			textList = {},
			textIndex = 1,
			textCount = 0,
			
			--quads
			spriteBatch = gfx.newSpriteBatch(self.atlas, 99),
			quadDirty = false,
			quadList = {},
			quadIndex = 1,
			quadCount = 0
		}
		
		self.cache[id] = panel
	end
	
	return panel
end

function mimic:_addPanel(panel)
	local parent = self.livePanel
	parent.children[parent.childIndex] = panel
	parent.childIndex = parent.childIndex + 1
end

function mimic:childBegin(id, drawBorder, w, h)
	local parent = self.livePanel
	local pad = self.theme.padding
	local x, y = parent.nextx, parent.nexty
	local scrollSize = self.theme.scrollSize

	--create the panel
	local panel = self:_mkPanel(id, x, y, parent.w - scrollSize - pad, parent.h - scrollSize - pad)

	--create the border if required
	local bgRect
	if drawBorder then
		bgRect = self:_mkRect(id .. ">panelBorder", x, y, panel.w, panel.h, nil, true)
		self:_addRect(bgRect)
	end

	panel.bgRect = bgRect
	self:_addPanel(panel)
	
	--push the panel stack
	insert(self.panelStack, panel)
	self.livePanel = panel

	self.mousex = self.mousex - panel.x
	self.mousey = self.mousey - panel.y
end

function mimic:childEnd()
	local panel = self.livePanel

	--zero out unused text instances
	if panel.textIndex - 1 ~= panel.textCount then
		for n = panel.textIndex, panel.textCount do
			panel.textList[n] = nil
		end
		panel.textDirty = true
	end
	
	--refresh text if needed
	if panel.textDirty then
		local text = panel.text
		local list = panel.textList
		text:clear()
		for n = 1, #list do
			local txt = list[n]
			text:add(txt[1], txt[2], txt[3])
		end
		panel.textDirty = false
		print "rebuilt text"
	end
	
	--zero out unused quads
	if panel.quadIndex - 1 ~= panel.quadCount then
		for n = panel.quadIndex, panel.quadCount do
			panel.quadList[n] = nil
		end
		panel.quadDirty = true
	end
	
	--refresh quads if needed
	if panel.quadDirty then
		local batch = panel.spriteBatch
		local list = panel.quadList
		batch:clear()
		for n = 1, #list do
			local quad = list[n]
			batch:setColor(quad[4])
			batch:add(quad[1], quad[2], quad[3])

		end
		panel.quadDirty = false
		print "rebuilt batch"
	end
	
	--zero out unused mesh instances
	if panel.instIndex - 1 ~= panel.instCount then
		for n = panel.instIndex , panel.instCount do
			panel.instList[n] = ATTRIBUTE_ZERO
		end
		panel.instDirty = true
	end

	--refresh mesh if needed
	if panel.instDirty then
		-- panel.instList[1][4] = panel.h

		--send verts
		panel.instMesh:setVertices(panel.instList)
		panel.instDirty = false
		print(frame, panel.id, "rebuilt mesh")
	end
	
	--zero out unused children
	if panel.childIndex - 1 ~= panel.childCount then
		for n = panel.childIndex, panel.childCount do
			panel.children[n] = nil
		end
	end

	--update parent stuff
	local parentInstDirty
	if panel.nexty + self.theme.padding ~= panel.h then
		-- update the bg dimensions first
		panel.h = panel.nexty + self.theme.padding
		if panel.bgRect then
			panel.bgRect[4] = panel.h
			parentInstDirty = true
			print "adjust bgRect"
		end
	end
	-- panel.h = panel.nexty + self.theme.padding
	local numPanels = #self.panelStack
	local parent = self.panelStack[numPanels - 1]
	if parent then
		parent.nexty = parent.nexty + panel.h
		parent.instDirty = parent.instDirty or parentInstDirty
	end

	--cleanup
	panel.instCount = panel.instIndex - 1
	panel.instIndex = 1
	panel.textCount = panel.textIndex - 1
	panel.textIndex = 1
	panel.quadCount = panel.quadIndex - 1
	panel.quadIndex = 1
	panel.childCount = panel.childIndex - 1
	panel.childIndex = 1
	panel.nextx = 0
	panel.nexty = 0

	self.mousex = self.mousex + panel.x
	self.mousey = self.mousey + panel.y

	--pop the panel stack
	remove(self.panelStack, numPanels)
	self.livePanel = self.panelStack[numPanels - 1]
end

-------------------------------------------------------------------------------
-- Windows
-------------------------------------------------------------------------------

--internal helper for window creation
function mimic:_mkWindow(id, x, y, w, isTransient)
	--a window is a specialised panel
	local window = self:_mkPanel(id, x, y, w or 0, h or 0)
	-- local window = 
	-- {
	-- 	id = id,
	-- 	x = x,
	-- 	y = y,
	-- 	w = w or 0,
	-- 	h = h or 0,
	-- 	z = 1,
	-- 	sortingCoef = 0,
	-- 	scrollx = 0,
	-- 	scrolly = 0,
		
	-- 	--layout control
	-- 	nextx = 0,
	-- 	nexty = 0,
	-- 	treeStates = {}, --transient, will reset when app closes


	--add additional properties
	window.z = 1
	window.sortingCoef = 0

	-- local mainPanel = self:_mkPanel(id .. ">main", 0, 0, w, h)
	-- window.mainPanel = mainPanel
	-- insert(window.children, mainPanel)

	self.windows[id] = window

	return window
end

function mimic:windowBegin(str, initOptions)
	local label, id = splitLabelId(str)
	
	local window = self.windows[id]
	if not window then
		window = self:_mkWindow(id, initOptions.x, initOptions.y, initOptions.w or 256)
		window.isTransient = initOptions.isTransient
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
	
	local pad = self.theme.padding

	--setup main panel
	insert(self.panelStack, window)
	self.livePanel = window

	local bg = self:_mkRect(id, 0, 0, window.w, window.h, nil, true)
	self:_addRect(bg)

	local txt = self:_mkText(id .. ">headtxt", label, pad, pad)
	local header = self:_mkRect(id .. ">head", 0, 0, window.w, self.fontHeight + pad * 2, self.theme.win_titleColor)

	local closew = self.fontHeight * 2
	local closebg = self:_mkRect(id ..">close", window.w-closew - 1, 0, closew, self.fontHeight + pad, self.theme.win_close)
	-- local closetxt = self:_mkText(id .. ">closttxt", "X", window.w-26, pad * 0.5)
	local xquad = self:_mkQuad(id .. ">closex", 7, window.w-closew + self.fontHeight * 0.5 -1, pad * 0.5, COLOR_WHITE)

	self:_addRect(header)
	self:_addText(txt)
	self:_addRect(closebg)
	self:_addQuad(xquad)


	window.nexty = self.fontHeight + pad * 2
	self:childBegin(id .. ">contentPanel", false, 0, window.nexty, window.w, window.h) --EDIT THIS
end

function mimic:windowEnd()
	self:childEnd() --content panel

	--[[
		update the main panel height and set dirty flag.
		this isn't needed, but prevents a 1-frame visual artefact
		whereby the content shows with no background
	]]
	local window = self.liveWindow
	if window.h ~= window.nexty + self.theme.padding then
		window.h = window.nexty + self.theme.padding
		window.instList[1][4] = window.h
		window.instDirty = true
		-- print("window height refreshed", window.h)
	end

	self:childEnd() --main panel

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

function mimic:_isActive(id, x, y, w, h)
	local state = BTN_UP
	local panel = self.livePanel
	if self.liveWindow == self.hoverWindow and overlaps(self.mousex, self.mousey, x, y, w, h) then
		if not self.activeControl then
			if self.mouseLeft == KEY_PRESSED then
				self.activeControl = id
				state = BTN_DOWN
			else
				state = BTN_HOVER
			end
		elseif self.activeControl == id then
			-- color = self.theme.btn_down
			state = BTN_DOWN
			if self.mouseLeft == KEY_RELEASED then
				state = BTN_CLICK
			end
		end
	end

	return state
end

function mimic:text(str, ...)
	if (...) then
		str = str:format(...)
	end
	local label, id = splitLabelId(str)
	local pad = self.theme.padding
	-- print(label, id)

	local txt = self:_mkText(id, label, self.livePanel.nextx + pad + 2, self.livePanel.nexty + pad)
	self:_addText(txt)
	self.livePanel.nexty = self.livePanel.nexty + self.fontHeight + pad
end

function mimic:button(str)
	local label, id = splitLabelId(str)
	local pad = self.theme.padding
	local x, y = self.livePanel.nextx + pad, self.livePanel.nexty + pad --+ self.liveWindow.scrolly
	local height = self.fontHeight + pad * 2

	--text is static, and we need it's width first
	local txt = self:_mkText(id .. ">txt", label, x + pad, y + pad)
	local width = txt[4] + pad * 2
	
	--mouse interactions
	local color
	local state = self:_isActive(id, x, y, width, height)
	if state == BTN_HOVER then
		color = self.theme.btn_hover
	elseif state == BTN_DOWN then
		color = self.theme.btn_down
	else
		color =  self.theme.btn_color
	end
	
	--now we can create the button rect
	local bg = self:_mkRect(id, x, y, width, height, color)

	self:_addRect(bg)
	self:_addText(txt)

	self.livePanel.nexty = self.livePanel.nexty + height + pad

	return state == BTN_CLICK
end

function mimic:checkBox(str, isChecked)
	local label, id = splitLabelId(str)
	local pad = self.theme.padding
	local x, y = self.livePanel.nextx + pad, self.livePanel.nexty + pad
	local height = self.fontHeight
	local clicked

	local txt = self:_mkText(id .. ">txt", label, x + height + pad, y)

	--mouse interactions
	local color
	local state = self:_isActive(id, x, y, height + pad + txt[4], height)
	if state == BTN_HOVER then
		color = self.theme.btn_hover
	elseif state == BTN_DOWN then
		color = self.theme.btn_down
	else
		color =  self.theme.btn_color
	end

	local box = self:_mkRect(id, x, y, height, height, color, true)
	local check = self:_mkQuad(id .. ">quad", isChecked and 2 or 1, x, y, self.theme.textColor)

	self:_addRect(box)
	self:_addText(txt)
	self:_addQuad(check)

	-- if isChecked then
	-- end

	self.livePanel.nexty = self.livePanel.nexty + height + pad
	return state == BTN_CLICK
end

function mimic:radioButton(str, selected)
	local label, id = splitLabelId(str)
	local pad = self.theme.padding
	local x, y = self.livePanel.nextx + pad, self.livePanel.nexty + pad
	local height = self.fontHeight
	
	local txt = self:_mkText(id .. ">txt", label, x + height + pad, y)

	--mouse interactions
	local color
	local state = self:_isActive(id, x, y, height + pad + txt[4], height)
	if state == BTN_HOVER then
		color = self.theme.btn_hover
	elseif state == BTN_DOWN then
		color = self.theme.btn_down
	else
		color =  self.theme.btn_color
	end

	local radio = self:_mkQuad(id, selected and 4 or 3 , x, y, self.theme.textColor)

	self:_addQuad(radio)
	self:_addText(txt)

	self.livePanel.nexty = self.livePanel.nexty + height + pad
	return state == BTN_CLICK
end

function mimic:rect(str, x, y, w, h)
	local label, id = splitLabelId(str)
	local rect = self:_mkRect(id, x, y, w, h)
	self:_addRect(rect)
end

function mimic:cacheBrowser()
	self:windowBegin("Cache Browser##__cache_browser__", {x=love.graphics.getWidth()-256, y=0})
		-- self.liveWindow.cacheCopy = self.liveWindow.cacheCopy or {}

		-- if self:button("Refresh##__cache_browser_btn__>browse") then
			local copy = {}
			for k, v in pairs(self.cache) do
				if not k:match(".+>browse$") then
					insert(copy, tostring(k))
				end
				-- assert()
			end
			table.sort(copy)
			-- self.liveWindow.cacheCopy = copy
		-- end

		self:text("Cache size: %d##__cache_sizetxt__>browse", #copy)
		for k, v in ipairs(copy) do
			self:text(v .. "##>browse")
		end
	self:windowEnd()
	-- collectgarbage "collect"
end

function mimic:header(str)
	local label, id = splitLabelId(str)
	local pad = self.theme.padding
	local x, y = self.livePanel.nextx + pad, self.livePanel.nexty + pad
	local height = self.fontHeight
	local width = self.livePanel.w

	local expand = self.livePanel.treeStates[id]
	if expand == nil then
		expand = false
	end
	
	if self:_isActive(id, x, y, width, height) == BTN_CLICK then
		expand = not expand
	end

	self.livePanel.treeStates[id] = expand

	local rect = self:_mkRect(id, x - pad, y, width, height + pad * 2, self.theme.win_titleColor)
	local quad = self:_mkQuad(id .. ">tri", expand and 6 or 5, x + pad, y + pad + math.floor(height /10))
	local txt = self:_mkText(id .. ">txt", label, x + height + pad * 2, y + pad)
	self:_addRect(rect)
	self:_addQuad(quad)
	self:_addText(txt)

	self.liveWindow.nexty = y + height + pad * 2
	return expand
end

function mimic:tree(str)

end

function mimic:pairs(str, tbl)

end

return function(id)
	local inst = setmetatable({}, {__index = mimic})
	inst:init(id)
	return inst
end