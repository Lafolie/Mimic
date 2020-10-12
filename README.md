![mimiBanner](/wiki/banner.png)

# Mimic

A single-require, pure Lua, Immediate-Mode GUI library for Löve projects.

The API design is inspired by [Dear IMGUI](https://github.com/ocornut/imgui), adapted for Lua.

## Features

Mimic has been designed with these goals in mind:

 * Easy to use
 * Lövely (follows typical Löve design patterns)
 * Single file to add to your project
 * Efficient rendering using mesh instancing & draw batching
 * Low number of draw calls *per window*
 * Minimal garbage generation
 * Designed primarily for development tools

 ## Additional Materials

*Todo*
Some extras such as themes and examples can also be found in the repo.

## Quickstart

To get started, simply drop `mimic.lua` into your project files, require it, and instantiate an instance, like so:

```Lua
mimic = require "mimic" ()
```

All controls must be displayed within a window. Windows are declared by a pair of function calls:

```Lua
function love.update()
	mimic:windowBegin "Hello World"

	mimic:windowEnd()
end
```

This creates a draggable, closable window:

[img here]

You can add controls to your window which return values you can use to manipulate objects or control flow:

```Lua
function love.update()
	mimic:windowBegin "Quit Window"
		if mimic:button "Quit" then
			love.event.push "quit"
		end
	mimic:windowEnd()
end
```

This way, your code can react to changes in the UI in a readable manner that allows for quick iteration and rapid development. This method of qorking is particularly well suited for the creation of tools for a game project.

### Integration

There is actually some additional boilerplate code required to get the above up and running, but the required code follows the familiar Löve callback scheme so it should be easy to integrate into your project.

```Lua
mimic = require "mimic" ()

--main callbacks
function love.update(dt)
	mimic:update(dt)
end

function love.draw()
	mimic:draw()
end

function love.quit()
	mimic:quit()
end

--keyboard
function love.keypressed(key, scancode)
	mimic:keypressed(key, scancode)
end

function love.keyreleased(key, scancode)
	mimic:keyreleased(key, scancode)
end

function love.textinput(text)
	mimic:textinput(text)
end

--mouse
function love.mousemoved(x, y, dx, dy, istouch)
	mimic:mousemoved(x, y, dx, dy, istouch)
end

function love.mousepressed(x, y, btn, istouch, presses)
	mimic:mousepressed(x, y, btn, istouch, presses)
end

function love.mousereleased(x, y, button, istouch, presses)
	mimic:mousereleased(x, y, button, istouch, presses)
end

function love.wheelmoved(x, y)
	mimic:wheelmoved(x, y)
end

```


Next, labels/buttons?

## Credits & Thanks

 * [@DaleJ_Dev](https://twitter.com/DaleJ_Dev) - core development
 * TunaNoot - Mimic creature logo
 * [Löve Community](https://love2d.org/) - For their awesome support in developing this project

 ![logo](/wiki/mimicLogo.png)