-- made by me and claudeai
-- Lua Bundler and Minifier
local Parser = require "ParseLua"
local Format_Mini = require "FormatMini"
local ParseLua = Parser.ParseLua
local Mangle = require "Mangle"

local Bundler = {}

-- Get directory from file path
local function getDirectory(path)
    return path:match("(.*/)") or "./" -- Match everything before the last `/`, default to `./`
end

-- Normalize path
local function normalizePath(path)
    path = path:gsub("\\", "/")
    path = path:gsub("//", "/")

    local parts = {}
    for part in path:gmatch("[^/]+") do
        if part == ".." then
            table.remove(parts)
        elseif part ~= "." then
            table.insert(parts, part)
        end
    end

    return table.concat(parts, "/")
end

-- Read file with path resolution
local function readFile(path, baseDir)
    -- Ensure baseDir ends with a slash
    baseDir = baseDir and (baseDir:match("/$") and baseDir or baseDir .. "/") or ""

    local pathVariations = {
        path,
        baseDir .. path,
        baseDir .. path .. ".lua",
        baseDir .. path .. ".luau",
        baseDir .. path:gsub("%.", "/"),
        baseDir .. path:gsub("%.", "/") .. ".lua",
        baseDir .. path:gsub("%.", "/") .. ".luau",
        baseDir .. path:sub(1,1) .. path:sub(2):gsub("%.", "/"),
        baseDir .. path:sub(1,1) .. path:sub(2):gsub("%.", "/") .. ".lua",
        baseDir .. path:sub(1,1) .. path:sub(2):gsub("%.", "/") .. ".luau",
    }

    for _, fullPath in ipairs(pathVariations) do
        local file = io.open(fullPath, "r")
        if file then
            local content = file:read("*all")
            file:close()
            return content, fullPath
        end
    end

    return nil
end

local function getActualPath(path)
    local pathVariations = {
        path .. ".lua",
        path .. ".luau",
        path:gsub("%.", "/"),
        path:gsub("%.", "/") .. ".lua",
        path:gsub("%.", "/") .. ".luau",
        path:sub(1,1) .. path:sub(2):gsub("%.", "/"),
        path:sub(1,1) .. path:sub(2):gsub("%.", "/") .. ".lua",
        path:sub(1,1) .. path:sub(2):gsub("%.", "/") .. ".luau",
    }
    for i = 1,#pathVariations do
        local test = pathVariations[i]
        local f = io.open(test, "r")
        if f ~= nil then
            f:close()
            return test
        end
    end
end

function Bundler.bundle(inputCode, first, parentModule, currentPath, moduleCache, moduleFileCache, modulesTable, cnt,
    define)
    for i, v in next, define do
        inputCode = inputCode:gsub(i, function()
            return v
        end)
    end
    inputCode = Bundler.minifyLua(inputCode);
    first = first or first == nil
    parentModule = parentModule or nil

    moduleCache = moduleCache or {}
    moduleFileCache = moduleFileCache or {}
    local circularRefs = {}
    cnt = cnt or 1
    modulesTable = modulesTable == nil and "__MODULES_" .. Bundler.makeid(25) or modulesTable

    local function transformRequires(code)
        local function replaceRequire(module)
            local actualpath
            local success ,_ = pcall(function()
                actualpath = getActualPath(currentPath .. module)
            end)
            if not success or not actualpath then
                return ("require\"%s\""):format(module)
            end
            local varName = moduleCache[actualpath] or cnt
            if not moduleCache[actualpath] then
                moduleCache[actualpath] = cnt
                cnt = cnt + 1
            end

            if parentModule then
                circularRefs[parentModule] = circularRefs[parentModule] or {}
                table.insert(circularRefs[parentModule], module)
            end

            return modulesTable .. "[" .. varName .. "]()"
        end

        code = code:gsub('require%s*[%(%s]*([%\'"%[])(.-)%1[%)%s]*', function(quote, module)
            return replaceRequire(module)
        end)

        return code
    end

    local code = transformRequires(inputCode)
    -- Process required modules
    for module, _ in pairs(moduleCache) do
        if not moduleFileCache[module] then
            -- Use the directory of the current file as base
            local moduleContent = readFile(module, currentPath)

            if moduleContent then
                moduleFileCache[module] = moduleContent
                local bundled = Bundler.bundle(moduleContent, false, module, currentPath, moduleCache, moduleFileCache,
                    modulesTable, cnt, define)
                moduleFileCache[module] = bundled
            else
                print("WARNING: Failed to read module " .. module)
            end
        end
    end

    -- Rest of the bundling logic (module initialization) remains the same as previous implementation
    if first then
        local moduleInitCode = string.format([[
local %s = {}
]], modulesTable)

        -- Initialize modules with their actual content
        for module, index in pairs(moduleCache) do
            moduleInitCode = moduleInitCode .. string.format([[
do
    local module = function()
        %s
    end
    %s[%d] = function()
        local ret = module()
        %s[%d] = function() return ret end
        return ret
    end
end
]], moduleFileCache[module], modulesTable, index, modulesTable, index)
        end

        code = moduleInitCode .. code
    end

    return code
end

function Bundler.makeid(length)
    local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_"
    local nums = "0123456789"
    local result = ""
    local first = true

    for i = 1, length do
        local characters = first and chars or (chars .. nums)
        local randomIndex = math.random(#characters)
        result = result .. characters:sub(randomIndex, randomIndex)
        first = false
    end

    return result
end

function Bundler.removeComments(code)
    code = code:gsub("%-%-.-\n", "\n")
    code = code:gsub("%-%-%[%[.-%]%]", "")
    return code
end

function Bundler.minifyLua(code, mangle)
    -- Strip shebang if present
    if code:sub(1, 1) == "#" then
        local shebangEnd = code:find("\n")
        if shebangEnd then
            code = code:sub(shebangEnd + 1)
        end
    end

    local st, ast = ParseLua(code)
    if not st then
        error(ast)
        return
    end
    if mangle ~= nil and mangle ~= "none" then
        ast = Mangle(ast, mangle == "auto")
    end
    return Format_Mini(ast)
end

function Bundler.writeFile(path, content)
    local file = io.open(path, "w")
    if not file then
        return false
    end
    file:write(content)
    file:close()
    return true
end

function Bundler.main(inputFile, outputFile, define, mangle)
    inputFile = inputFile or "main.lua"
    outputFile = outputFile or "bundled.min.lua"

    -- Read main Lua file
    local inputCode, inputPath = readFile(inputFile)
    if not inputCode then
        print("ERROR: Cannot read " .. inputFile)
        return false
    end

    -- Bundle the code, passing the full input path
    inputCode = Bundler.minifyLua(inputCode)
    
    local bundledCode = Bundler.bundle(inputCode, true, nil, getDirectory(inputPath), nil, nil, nil, nil, define)

    -- Minify the bundled code
    local minifiedCode = Bundler.minifyLua(bundledCode, mangle)

    -- Write bundled and minified code
    if Bundler.writeFile(outputFile, minifiedCode) then
        print("Bundling and minification completed successfully.")
        return true
    else
        print("Failed to write " .. outputFile)
        return false
    end
end

-- Prepare for execution
math.randomseed(os.time())

-- If run directly, execute main function
local args = {...}
if #args < 1 then
    error("Usage: bundle.lua [entrypoint] [?-o output]")
end
local entrypoint = args[1]
local fname = ""
do
    local split = {}
    for str in entrypoint:gmatch("([^.]+)") do
        table.insert(split, str)
    end
    if #split > 1 and split[#split] == "lua" then
        table.remove(split, #split)
    end
    fname = table.concat(split, ".")
end

local output = fname .. ".min.lua"

local define = {}
local mangle = "none"

for i = 2, #args do
    if args[i]:lower() == "-o" then
        output = args[i + 1]
        i = i + 1
    elseif args[i]:lower() == "-d" then
        local var, val = args[i + 1]:match("(%w+)%s*=%s*(.-)%s*$")
        if type(var) == "string" and type(val) == "string" then
            define[var] = val
        end
    elseif args[i]:lower() == "-mangle" then
        mangle = "mangle"
    elseif args[i]:lower() == "-automangle" then
        mangle = "auto"
    end
end

Bundler.main(entrypoint, output, define, mangle)
