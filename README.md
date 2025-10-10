# Lua ES6 Import Bundler

A modern JavaScript/TypeScript-style import/export bundler for Lua and Luau. Write modular Lua code with ES6-style `import`/`export` syntax and bundle it into a single optimized file.

[Lua ES6 VSCode Extension](https://github.com/nostopgmaming17/lua-es6-vscode-extension)

## Features

- **ES6-Style Syntax**: Named imports/exports with aliases (`import foo as bar from "./module"`)
- **JavaScript Path Resolution**: `@/` absolute imports, `./` relative, `../` parent, directory/index imports
- **Circular Dependencies**: Automatic handling with topological sorting
- **Minification**: Optional minification with `-minify` flag
- **Variable Mangling**: Reduce output size with `-mangle` or `-automangle`
- **Define Variables**: Replace any string at bundle time with `-d`
- **AST-Based**: Proper Lua parsing, no regex hacks
- **Zero Runtime Overhead**: All imports resolved at bundle time

## Installation & Setup

### Quick Setup (Recommended)

For easier distribution, create a single-file bundler:

```bash
cd luapack
minifybundle.bat
```

This creates a standalone `dist/bundle.lua` containing the entire bundler. You can then copy just this one file to your projects and use it directly:

```bash
lua bundle.lua src/main.lua -o dist/app.lua
```

### Manual Setup

Alternatively, use the modular version directly:

```bash
cd luapack
lua import_bundle.lua src/main.lua -o dist/bundle.lua
```

## Quick Start

**src/math.lua:**
```lua
export local function add(a, b)
    return a + b
end

export local PI = 3.14159
```

**src/main.lua:**
```lua
import add, PI from "./math"

print("2 + 3 =", add(2, 3))
print("PI =", PI)
```

**Bundle it:**
```bash
lua import_bundle.lua src/main.lua -o dist/bundle.lua
```

## Import/Export Syntax

```lua
-- Exports
export local function myFunc() end
export local x, y, z
export local config = { debug = true }

-- Imports
import myFunc from "./module"
import add, multiply from "./math"
import longName as short from "./utils"
import foo, bar as b, baz from "./module"
```

## Path Resolution

### Absolute Imports (`@/`)
```lua
import config from "@/config/settings"   -- From project root
import utils from "@/lib/shared/utils"   -- No ../../../ needed!
```

### Relative Imports
```lua
import helper from "./helper"            -- Same directory
import parent from "../parent"           -- Parent directory
import nested from "./sub/dir/module"    -- Nested path
```

### Directory/Index Imports
```lua
import utils from "./utils"              -- Resolves to ./utils/init.lua
import lib from "@/lib"                  -- Resolves to @/lib/init.lua
```

### Extension Handling
```lua
import mod from "./module"               -- Auto-tries .lua, .luau
import mod from "./module.lua"           -- Explicit also works
```

**Resolution order:** `./utils` → `./utils.lua` → `./utils.luau` → `./utils/init.lua` → `./utils/init.luau`

## CLI Usage

```bash
lua import_bundle.lua <entrypoint> [options]
```

**Options:**
- `-o <output>` - Output file path
- `-minify` - Enable minification (automatically renames local variables)
- `-mangle` - Mangle properties starting with `_` (excludes `__*`)
- `-automangle` - Mangle ALL properties except `__*` (⚠️ Not recommended)
- `-d <var>=<val>` - Define variable replacement

**Examples:**
```bash
# Basic
lua import_bundle.lua src/main.lua

# Custom output
lua import_bundle.lua src/main.lua -o build/app.lua

# Minified
lua import_bundle.lua src/main.lua -minify

# Minified with mangling
lua import_bundle.lua src/main.lua -minify -mangle

# Define variables
lua import_bundle.lua src/main.lua -d DEBUG=false -d VERSION=\"1.0.0\"

# All options
lua import_bundle.lua src/main.lua -o dist/app.min.lua -minify -automangle -d PROD=true
```

## Advanced Features

### Circular Dependencies

Automatically handled - no manual intervention needed:

```lua
// moduleA.lua
import funcB from "./moduleB"
export local function funcA()
    return funcB() + 1
end

// moduleB.lua
import funcA from "./moduleA"
export local function funcB()
    return 10
end
```

### Minification

Minification automatically renames local variables to shorter names:

```bash
lua import_bundle.lua src/main.lua -o dist/app.min.lua -minify
```

**Before (185 bytes):**
```lua
local function helper(value)
    return value * 3 + 7
end
local count = 0
```

**After (134 bytes - 28% smaller):**
```lua
local function a(b)return b*3+7 end;local c=0
```

### Property Mangling

Property mangling renames table properties (e.g., `obj.prop`, `obj:method()`, `obj["key"]`) for smaller output.

**`-mangle`** - Only mangles properties starting with `_` (but not `__`):
```bash
lua import_bundle.lua src/main.lua -minify -mangle
```

```lua
-- Before
obj._privateMethod()
obj._data = 5
obj.__index = x  -- Never mangled

-- After
obj.a()          -- _privateMethod mangled to a
obj.b = 5        -- _data mangled to b
obj.__index = x  -- __index NOT mangled
```

**`-automangle`** - Mangles ALL properties that DON'T start with `_`:

⚠️ **WARNING**: `-automangle` WILL break code using standard libraries or external APIs!

```bash
lua import_bundle.lua src/main.lua -minify -automangle
```

```lua
-- Before
string.sub("hello", 1, 3)
obj.publicMethod()
obj._private = 5

-- After
string.a("hello", 1, 3)  -- ❌ BREAKS! string.sub → string.a
obj.b()                   -- ❌ BREAKS! publicMethod → b
obj.private = 5           -- ✅ _private → private (underscore removed)
```

**Only use `-automangle` if:**
- Your code is completely self-contained
- You don't use ANY standard library functions (`string.*`, `table.*`, `math.*`, etc.)
- You don't call external APIs or engine methods

### Define Variables

Replace any string in your source code at bundle time:

```bash
lua import_bundle.lua src/main.lua -d DEBUG=false -d VERSION=\"1.0.0\"
```

**Source:**
```lua
if DEBUG then
    print("Debug mode")
end
print("Version:", VERSION)
```

**Bundled:**
```lua
if false then
    print("Debug mode")
end
print("Version:", "1.0.0")
```

Great for feature flags, version strings, and build-time configuration!

## How It Works

1. **Lexical Analysis** - Tokenizes Lua source
2. **Import/Export Extraction** - Parses and removes import/export statements
3. **AST Parsing** - Builds Abstract Syntax Tree
4. **Dependency Resolution** - Recursively gathers imported files
5. **Name Conflict Resolution** - Renames conflicting variables
6. **Topological Sorting** - Orders declarations by dependencies
7. **Code Generation** - Outputs beautified or minified code

## vs. `require()`

| Feature | ES6 Imports | `require()` |
|---------|-------------|-------------|
| Static bundling | ✅ | ❌ |
| Named imports | ✅ | ❌ |
| Path aliases (`@/`) | ✅ | ❌ |
| Circular deps | ✅ Auto | Manual |
| Runtime overhead | ❌ None | ✅ Yes |

## Best Practices

**1. Use absolute imports for shared code:**
```lua
import utils from "@/lib/utils"          // ✅ Good
import utils from "../../lib/utils"      // ❌ Brittle
```

**2. Organize with index files:**
```lua
// lib/utils/init.lua
export local utils = { math, string, array }

// Then:
import utils from "@/lib/utils"
```

**3. Group related imports:**
```lua
import foo, bar, baz from "@/lib/core"
import add, subtract from "@/lib/math"
```

**4. Use aliases for conflicts:**
```lua
import process as processData from "@/lib/data"
import process as processEvent from "@/lib/events"
```

## Limitations

- Import/export must be at top level (not inside functions)
- No dynamic imports (all static)
- No default exports (use named exports)
- No destructuring (use explicit names)

## Credits

Uses components from [LuaMinify](https://github.com/stravant/LuaMinify) by stravant for AST parsing and formatting.

---

**Happy bundling!** 🚀
