# Mimic

A single-require, pure Lua, Immediate-Mode GUI library for Löve projects.

The API design is inspired by [Dear IMGUI](), adapted for Lua.

## Features

[name] has been designed with these goals in mind:

 * Single file to add to your project
 * Efficient rendering using mesh instancing
 * Low number of draw calls *per window*
 * Minimal garbage generation
 * Designed primarily for development tools

 ## Additional Materials

*Todo*
Some extras such as themes and examples can also be found in the repo.

## Quickstart

To get started, simply drop `mimic.lua` into your project files, require it, and instantiate an instance, like so:

```Lua
Mimic = require "mimic"

mimic = Mimic()
```

All controls must be displayed within a window. Windows are declared by a pair of function calls:

```Lua
function love.update()
	mimic:windowBegin("HelloWorld")

	mimic:windowEnd()
end
```

Next, labels/buttons?