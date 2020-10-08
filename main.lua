local IMGUI = require "mimic"
local ui
local testWindowOptions = {x = 100, y = 100}

function love.load()
	ui = IMGUI()
end

function love.update(dt)
	ui:windowBegin("testWindow", testWindowOptions)

	ui:windowEnd()
end

function love.draw()
	ui:draw()

	love.graphics.setColor(1, 1, 1, 1)
	local stats = love.graphics.getStats()
	love.graphics.print(string.format("Draw calls: %d", stats.drawcalls), 1, 1)
	love.graphics.print(string.format("FPS: %d", love.timer.getFPS()), 1, 20)
	love.graphics.print(string.format("Mem: %d", collectgarbage "count"), 1, 40)
end

function love.keypressed(key, scan)
	if key == "escape" then
		love.event.push "quit"
	end
end