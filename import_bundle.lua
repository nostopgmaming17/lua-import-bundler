#!/usr/bin/env lua
-- import_bundle.lua
-- CLI for bundling Lua files with ES6-style import/export syntax

local ImportBundler = require "ImportBundler"

local function writeFile(path, content)
    local file = io.open(path, "w")
    if not file then
        return false
    end
    file:write(content)
    file:close()
    return true
end

local function main(args)
    if #args < 1 then
        print("Usage: lua import_bundle.lua <entrypoint> [options]")
        print("")
        print("Options:")
        print("  -o <output>        Output file path")
        print("  -minify            Enable minification")
        print("  -d <var>=<val>     Define variable replacement")
        print("  -mangle            Enable variable name mangling")
        print("  -automangle        Enable automatic variable name mangling")
        print("")
        print("Examples:")
        print("  lua import_bundle.lua src/main.lua")
        print("  lua import_bundle.lua src/main.lua -o dist/bundle.lua")
        print("  lua import_bundle.lua src/main.lua -minify -mangle")
        print("  lua import_bundle.lua src/main.lua -d DEBUG=false")
        return 1
    end

    local entrypoint = args[1]

    -- Generate default output name
    local output = "bundled.lua"
    local minify = false
    local define = {}
    local mangle = "none"

    -- Parse arguments
    local i = 2
    while i <= #args do
        if args[i]:lower() == "-o" and i + 1 <= #args then
            output = args[i + 1]
            i = i + 2
        elseif args[i]:lower() == "-minify" then
            minify = true
            i = i + 1
        elseif args[i]:lower() == "-d" and i + 1 <= #args then
            local var, val = args[i + 1]:match("(%w+)%s*=%s*(.-)%s*$")
            if var and val then
                define[var] = val
            end
            i = i + 2
        elseif args[i]:lower() == "-mangle" then
            mangle = "mangle"
            i = i + 1
        elseif args[i]:lower() == "-automangle" then
            mangle = "auto"
            i = i + 1
        else
            i = i + 1
        end
    end

    -- Bundle
    local success, result = pcall(function()
        return ImportBundler.bundle(entrypoint, minify, define, mangle)
    end)

    if not success then
        print("ERROR: " .. tostring(result))
        return 1
    end

    -- Ensure output directory exists
    local outputDir = output:match("(.*/)")
    if outputDir then
        -- Try to create directory silently
        local winDir = outputDir:gsub("/", "\\")
        -- Use pcall to suppress any errors from mkdir
        pcall(function()
            os.execute("mkdir \"" .. winDir .. "\" 2>nul 1>nul")
        end)
    end

    -- Write output
    if writeFile(output, result) then
        print("Bundling completed successfully.")
        return 0
    else
        print("ERROR: Failed to write " .. output)
        return 1
    end
end

local args = {...}
os.exit(main(args))
