# Mimic

A single-require, pure Lua, Immediate-Mode GUI library for Löve projects.

The API design is inspired by [Dear IMGUI](), adapted for Lua.

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
	mimic:windowBegin("HelloWorld")

	mimic:windowEnd()
end

This creates a draggable, closable window:

[img here]
```

Next, labels/buttons?