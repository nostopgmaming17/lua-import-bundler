-- ImportBundler.lua
-- Bundles Lua files with ES6-style import/export syntax

local Parser = require "ParseLua"
local ParseLua = Parser.ParseLua
local ImportParser = require "ImportParser"
local Format_Mini = require "FormatMini"
local Format_Beautiful = require "FormatBeautiful"
local Mangle = require "Mangle"

local ImportBundler = {}

-- Strip shebang from source if present
local function stripShebang(src)
    if src:sub(1, 1) == "#" then
        local shebangEnd = src:find("\n")
        if shebangEnd then
            return src:sub(shebangEnd + 1)
        end
    end
    return src
end

-- File reading with JavaScript-style path resolution
local function readFile(path, baseDir)
    baseDir = baseDir and (baseDir:match("/$") and baseDir or baseDir .. "/") or ""

    local pathVariations = {
        path,
        baseDir .. path,
        baseDir .. path .. ".lua",
        baseDir .. path .. ".luau",
        -- Index file resolution (like JavaScript)
        baseDir .. path .. "/init.lua",
        baseDir .. path .. "/init.luau",
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

-- Get directory from file path
local function getDirectory(path)
    return path:match("(.*/)") or "./"
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

-- Get full member path from an expression
local function getMemberPath(node)
    if not node then return nil end

    if node.AstType == 'VarExpr' then
        return node.Name
    elseif node.AstType == 'MemberExpr' then
        local base = getMemberPath(node.Base)
        if base then
            -- Handle both string idents and table idents
            local ident = type(node.Ident) == 'table' and node.Ident.Data or node.Ident
            if ident then
                return base .. "." .. ident
            end
        end
    elseif node.AstType == 'IndexExpr' then
        local base = getMemberPath(node.Base)
        -- Only handle string literal indices
        if base and node.Index and node.Index.AstType == 'StringExpr' then
            local value = type(node.Index.Value) == 'table' and node.Index.Value.Data or node.Index.Value
            if value then
                return base .. "." .. value
            end
        end
    end
    return nil
end

-- Extract all identifiers from AST node
local function extractIdentifiers(node, identifiers, isCallBase)
    identifiers = identifiers or {}
    isCallBase = isCallBase or false

    if not node then
        return identifiers
    end

    if node.AstType == 'VarExpr' then
        identifiers[node.Name] = true
    elseif node.AstType == 'CallExpr' or node.AstType == 'TableCallExpr' or node.AstType == 'StringCallExpr' then
        -- For calls, track the full member path if it's a method/property call
        local memberPath = getMemberPath(node.Base)
        if memberPath and memberPath:find("%.") then
            -- It's a method/property call like table.method()
            identifiers[memberPath] = true
        end

        -- Special handling for setmetatable(x, Table) - depend on Table's member assignments
        local baseName = getMemberPath(node.Base)
        if baseName == "setmetatable" and node.Arguments and #node.Arguments >= 2 then
            local metatableName = getMemberPath(node.Arguments[2])
            if metatableName and not metatableName:find("%.") then
                -- Mark dependency on Table.__index, Table.__newindex, etc.
                -- This ensures they come before functions that use setmetatable
                identifiers[metatableName .. ".__index"] = true
                identifiers[metatableName .. ".__newindex"] = true
                identifiers[metatableName .. ".__metatable"] = true
            end
        end

        -- Also extract from base and arguments
        extractIdentifiers(node.Base, identifiers, true)
        if node.Arguments then
            for _, arg in ipairs(node.Arguments) do
                extractIdentifiers(arg, identifiers, false)
            end
        end
    elseif node.AstType == 'BinopExpr' then
        extractIdentifiers(node.Lhs, identifiers, false)
        extractIdentifiers(node.Rhs, identifiers, false)
    elseif node.AstType == 'UnopExpr' then
        extractIdentifiers(node.Rhs, identifiers, false)
    elseif node.AstType == 'IndexExpr' then
        -- Track the full path if accessing a member
        if not isCallBase then
            local memberPath = getMemberPath(node)
            if memberPath and memberPath:find("%.") then
                identifiers[memberPath] = true
            end
        end
        extractIdentifiers(node.Base, identifiers, false)
        extractIdentifiers(node.Index, identifiers, false)
    elseif node.AstType == 'MemberExpr' then
        -- Track the full path if accessing a member
        if not isCallBase then
            local memberPath = getMemberPath(node)
            if memberPath and memberPath:find("%.") then
                identifiers[memberPath] = true
            end
        end
        extractIdentifiers(node.Base, identifiers, false)
    elseif node.AstType == 'Function' then
        if node.Body and node.Body.Body then
            for _, stmt in ipairs(node.Body.Body) do
                extractIdentifiersFromStatement(stmt, identifiers)
            end
        end
    elseif node.AstType == 'Parentheses' then
        extractIdentifiers(node.Inner, identifiers, isCallBase)
    elseif node.AstType == 'ConstructorExpr' then
        if node.EntryList then
            for _, entry in ipairs(node.EntryList) do
                if entry.Key then extractIdentifiers(entry.Key, identifiers, false) end
                if entry.Value then extractIdentifiers(entry.Value, identifiers, false) end
            end
        end
    end

    return identifiers
end

function extractIdentifiersFromStatement(stmt, identifiers)
    identifiers = identifiers or {}

    if stmt.AstType == 'CallStatement' then
        extractIdentifiers(stmt.Expression, identifiers)
    elseif stmt.AstType == 'AssignmentStatement' or stmt.AstType == 'LocalStatement' then
        if stmt.InitList then
            for _, expr in ipairs(stmt.InitList) do
                extractIdentifiers(expr, identifiers)
            end
        end
        if stmt.Rhs then
            for _, expr in ipairs(stmt.Rhs) do
                extractIdentifiers(expr, identifiers)
            end
        end
    elseif stmt.AstType == 'ReturnStatement' then
        if stmt.Arguments then
            for _, arg in ipairs(stmt.Arguments) do
                extractIdentifiers(arg, identifiers)
            end
        end
    elseif stmt.AstType == 'Function' then
        if stmt.Body and stmt.Body.Body then
            for _, s in ipairs(stmt.Body.Body) do
                extractIdentifiersFromStatement(s, identifiers)
            end
        end
    end

    return identifiers
end

-- Bundle files with import/export
function ImportBundler.bundle(entryPath, minify, define, mangle)
    local files = {}
    local fileData = {}
    local processed = {}
    minify = minify or false
    define = define or {}
    mangle = mangle or "none"

    -- Determine project root (directory containing entry file)
    local projectRoot = getDirectory(entryPath)

    -- Recursively gather all files
    local function gatherFiles(filePath, baseDir)
        local fullPath = normalizePath(baseDir .. filePath)

        if processed[fullPath] then
            return
        end
        processed[fullPath] = true

        local content, resolvedPath = readFile(filePath, baseDir)
        if not content then
            error("Could not read file: " .. filePath)
        end

        -- Apply define replacements to raw content FIRST
        for varName, value in pairs(define) do
            content = content:gsub(varName, function()
                return value
            end)
        end

        -- Extract imports and exports
        local st, result = ImportParser.extractImportsExports(content)
        if not st then
            error("Parse error in " .. filePath .. ": " .. tostring(result))
        end

        -- Parse the cleaned source (strip shebang for ParseLua)
        local cleanedForParsing = stripShebang(result.cleanedSrc)
        local st2, ast = ParseLua(cleanedForParsing)
        if not st2 then
            error("Parse error in " .. filePath .. ": " .. tostring(ast))
        end

        local fileInfo = {
            path = fullPath,
            name = filePath:match("([^/]+)$"),
            imports = result.imports,
            exports = result.exports,
            ast = ast,
            dir = getDirectory(resolvedPath)
        }

        table.insert(files, fileInfo)
        fileData[fullPath] = fileInfo

        -- Process dependencies
        for _, imp in ipairs(result.imports) do
            local depPath = imp.source
            local depDir = fileInfo.dir

            -- Handle different import path styles (JavaScript-like)
            if depPath:sub(1, 2) == "@/" then
                -- Absolute from project root: @/module.lua
                depPath = depPath:sub(3)
                depDir = projectRoot
            elseif depPath:sub(1, 2) == "./" then
                -- Relative to current file: ./module.lua
                depPath = depPath:sub(3)
                -- depDir already set to fileInfo.dir
            elseif depPath:sub(1, 3) == "../" then
                -- Parent directory: ../module.lua
                -- Keep the ../ in path, will be resolved by normalizePath
                -- depDir already set to fileInfo.dir
            else
                -- No prefix, treat as relative: module.lua → ./module.lua
                -- depDir already set to fileInfo.dir
            end

            gatherFiles(depPath, depDir)
        end
    end

    -- Start gathering from entry
    local entryDir = getDirectory(entryPath)
    local entryName = entryPath:match("([^/]+)$")
    local entryFullPath = normalizePath(entryDir .. entryName)
    gatherFiles(entryName, entryDir)

    -- Build items list with declarations and statements
    local allItems = {}
    local itemIdCounter = 0
    local usedNames = {}
    local globalRenameMap = {}
    local exportedVars = {} -- Maps file.path -> varName -> renamedVarName

    local function getUniqueName(baseName)
        if not usedNames[baseName] then
            usedNames[baseName] = true
            return baseName
        end
        local counter = 2
        while usedNames[baseName .. counter] do
            counter = counter + 1
        end
        local newName = baseName .. counter
        usedNames[newName] = true
        return newName
    end

    -- Entry file path is the one specified in entryPath
    local entryFilePath = entryFullPath

    -- PRIORITY: Imported file exports get priority for original names
    -- Entry file variables are renamed if they conflict

    -- Step 1: For imported files, exports get UNIQUE global names (first gets priority)
    -- The first file that exports 'maid' gets to keep 'maid', second gets 'maid2', etc.
    -- IMPORTANT: Process imported files FIRST to claim names
    local fileSpecificRenames = {}  -- Maps file.path -> originalName -> uniqueName

    for i = 1, #files do
        local file = files[i]
        exportedVars[file.path] = {}
        fileSpecificRenames[file.path] = {}
    end

    -- Process imported files first to claim their export names
    for i = 1, #files do
        local file = files[i]
        if file.path ~= entryFilePath then
            -- Imported files: exports get unique names (priority to first occurrence)
            for _, exp in ipairs(file.exports) do
                for _, name in ipairs(exp.names) do
                    local uniqueName = getUniqueName(name)
                    exportedVars[file.path][name] = uniqueName
                    -- Track this in fileSpecificRenames
                    fileSpecificRenames[file.path][name] = uniqueName
                end
            end
        end
    end

    -- Step 2: Entry file exports (if any) get renamed to avoid conflicts
    -- Entry file locals will be handled during AST processing (no pre-scan needed)
    local entryFileVarNames = {}
    for i = 1, #files do
        local file = files[i]
        if file.path == entryFilePath then
            -- Process exports only (not locals - those will be processed during AST processing)
            for _, exp in ipairs(file.exports) do
                for _, name in ipairs(exp.names) do
                    if not entryFileVarNames[name] then
                        local uniqueName = getUniqueName(name)  -- Will be renamed if conflicts exist
                        entryFileVarNames[name] = uniqueName
                        exportedVars[file.path][name] = uniqueName
                    end
                end
            end
        end
    end

    -- Process files and track which file is the entry point
    local fileOrderIndex = {}  -- Track original file order
    for i = 1, #files do
        fileOrderIndex[files[i].path] = i
    end

    -- Track exports that need to be renamed due to conflicts with non-imported usage
    local exportsNeedingRename = {} -- Maps filePath -> originalName -> true

    for i = 1, #files do
        local file = files[i]
        local fileImportMap = {} -- Maps alias -> {sourcePath, originalName, renamedName}
        local fileImportedNames = {}
        local fileAllowedExports = {} -- Track which exports this file can access (via imports)

        -- Build import map for this file
        for _, imp in ipairs(file.imports) do
            -- Find the source file with same path resolution as gatherFiles
            local sourcePath = imp.source
            local sourceDir = file.dir

            -- Handle different import path styles (JavaScript-like)
            if sourcePath:sub(1, 2) == "@/" then
                -- Absolute from project root
                sourcePath = sourcePath:sub(3)
                sourceDir = projectRoot
            elseif sourcePath:sub(1, 2) == "./" then
                -- Relative to current file
                sourcePath = sourcePath:sub(3)
            elseif sourcePath:sub(1, 3) == "../" then
                -- Parent directory - keep as is for normalizePath
            else
                -- No prefix, treat as relative
            end

            local sourceFullPath = normalizePath(sourceDir .. sourcePath)

            for _, item in ipairs(imp.imports) do
                -- Find the actual renamed variable from the source file
                local actualName = exportedVars[sourceFullPath] and exportedVars[sourceFullPath][item.name]
                if actualName then
                    fileImportMap[item.alias] = actualName
                    fileImportedNames[item.alias] = true
                    -- Only allow direct access to the export if NO alias is used
                    -- If "import b as d" is used, the file can only use "d", not "b"
                    if item.alias == item.name then
                        fileAllowedExports[actualName] = true
                    end
                end
            end
        end

        -- Build a set of all exports from OTHER files that this file can access
        -- If a file uses an export name without importing it, we need to rename that export
        local exportNamesToCheck = {}
        for otherFilePath, exports in pairs(exportedVars) do
            if otherFilePath ~= file.path then
                for originalName, exportName in pairs(exports) do
                    if not fileAllowedExports[exportName] then
                        -- Track this export so we can check if it's used
                        exportNamesToCheck[exportName] = {
                            filePath = otherFilePath,
                            originalName = originalName
                        }
                    end
                end
            end
        end

        -- Process AST statements
        if file.ast.Body then
            local stmtIndexInFile = 0
            for _, stmt in ipairs(file.ast.Body) do
                stmtIndexInFile = stmtIndexInFile + 1
                local itemId = file.name .. "_" .. itemIdCounter
                itemIdCounter = itemIdCounter + 1

                -- Calculate statement index: entry file items get low numbers (0-999),
                -- imported files get high numbers based on their file order
                local stmtIndex
                if file.path == entryFilePath then
                    stmtIndex = stmtIndexInFile  -- 1, 2, 3, ... for entry file
                else
                    -- Imported files: use file order * 100000 + statement position
                    -- This puts them after entry file items in the sort
                    stmtIndex = fileOrderIndex[file.path] * 100000 + stmtIndexInFile
                end

                -- Handle function declarations (including method definitions)
                if stmt.AstType == 'Function' and stmt.Name then
                    local originalName = stmt.Name.Name or stmt.Name
                    local isMethod = false
                    local methodPath = nil

                    -- Check if this is a method definition (e.g., function Table:method() or Table.method())
                    if type(stmt.Name) == 'table' and stmt.Name.AstType then
                        methodPath = getMemberPath(stmt.Name)
                        if methodPath and methodPath:find("%.") then
                            isMethod = true
                            originalName = methodPath
                        end
                    end

                    -- Check if this is an exported function (already has a unique name assigned)
                    local uniqueName
                    if not isMethod and exportedVars[file.path] and exportedVars[file.path][originalName] then
                        -- Exported function: use the assigned name (for imported files, this is the original name)
                        uniqueName = exportedVars[file.path][originalName]
                        -- Don't add to globalRenameMap - we want to keep the original name
                    elseif not isMethod and file.path == entryFilePath and entryFileVarNames[originalName] then
                        -- Entry file's function: use pre-assigned name
                        uniqueName = entryFileVarNames[originalName]
                    elseif not isMethod then
                        -- Non-exported local function (from any file)
                        uniqueName = getUniqueName(originalName)
                        -- Only add to globalRenameMap if this is from the entry file OR if it actually got renamed
                        if uniqueName ~= originalName then
                            globalRenameMap[originalName] = uniqueName
                        end
                    else
                        -- Method definition - keep the original path structure but rename if needed
                        uniqueName = originalName
                    end

                    -- Update the AST for non-method functions
                    if not isMethod and type(stmt.Name) == 'table' then
                        stmt.Name.Name = uniqueName
                    end

                    local deps = extractIdentifiersFromStatement(stmt, {})

                    -- Check if this statement uses any exports without importing them
                    -- Mark those exports for renaming
                    for depName in pairs(deps) do
                        if exportNamesToCheck[depName] then
                            local exportInfo = exportNamesToCheck[depName]
                            if not exportsNeedingRename[exportInfo.filePath] then
                                exportsNeedingRename[exportInfo.filePath] = {}
                            end
                            exportsNeedingRename[exportInfo.filePath][exportInfo.originalName] = true
                        end
                    end

                    table.insert(allItems, {
                        id = itemId,
                        type = isMethod and 'method' or 'function',
                        name = uniqueName,
                        originalName = originalName,
                        methodPath = methodPath,
                        stmt = stmt,
                        dependencies = deps,
                        importedNames = fileImportedNames,
                        importMap = fileImportMap,
                        fileRenameMap = fileSpecificRenames[file.path] or {},
                        fileOrder = i,
                        filePath = file.path,
                        stmtIndex = stmtIndex,
                        isDeclaration = true
                    })

                -- Handle local declarations
                elseif stmt.AstType == 'LocalStatement' then
                    local originalNames = {}
                    local uniqueNames = {}

                    for _, localVar in ipairs(stmt.LocalList) do
                        local originalName = localVar.Name
                        table.insert(originalNames, originalName)

                        -- Check if this is an exported variable (already has a unique name assigned)
                        local uniqueName
                        if exportedVars[file.path] and exportedVars[file.path][originalName] then
                            -- Exported variable: use the assigned name (for imported files, this is the original name)
                            uniqueName = exportedVars[file.path][originalName]
                            -- Don't add to globalRenameMap - we want to keep the original name
                        elseif file.path == entryFilePath and entryFileVarNames[originalName] then
                            -- Entry file's variable: use pre-assigned name
                            uniqueName = entryFileVarNames[originalName]
                        else
                            -- Non-exported local variable (from any file)
                            uniqueName = getUniqueName(originalName)
                            -- Only add to globalRenameMap if it actually got renamed
                            if uniqueName ~= originalName then
                                globalRenameMap[originalName] = uniqueName
                            end
                        end

                        table.insert(uniqueNames, uniqueName)

                        -- Update the AST
                        localVar.Name = uniqueName
                    end

                    local deps = extractIdentifiersFromStatement(stmt, {})

                    -- Check if this statement uses any exports without importing them
                    -- Mark those exports for renaming
                    for depName in pairs(deps) do
                        if exportNamesToCheck[depName] then
                            local exportInfo = exportNamesToCheck[depName]
                            if not exportsNeedingRename[exportInfo.filePath] then
                                exportsNeedingRename[exportInfo.filePath] = {}
                            end
                            exportsNeedingRename[exportInfo.filePath][exportInfo.originalName] = true
                        end
                    end

                    table.insert(allItems, {
                        id = itemId,
                        type = 'variable',
                        names = uniqueNames,
                        originalNames = originalNames,
                        stmt = stmt,
                        dependencies = deps,
                        importedNames = fileImportedNames,
                        importMap = fileImportMap,
                        fileRenameMap = fileSpecificRenames[file.path] or {},
                        fileOrder = i,
                        fileIndex = i,
                        filePath = file.path,
                        stmtIndex = stmtIndex,
                        isDeclaration = true
                    })

                -- Handle assignment statements (check for method assignments and member assignments)
                elseif stmt.AstType == 'AssignmentStatement' and stmt.Lhs and #stmt.Lhs == 1 and stmt.Rhs and #stmt.Rhs == 1 then
                    local lhs = stmt.Lhs[1]
                    local rhs = stmt.Rhs[1]

                    local memberPath = getMemberPath(lhs)

                    -- Check if this is assigning a function to a table member (e.g., Table.method = function())
                    if memberPath and memberPath:find("%.") and rhs.AstType == 'Function' then
                        -- This is a method definition via assignment
                        local deps = extractIdentifiersFromStatement(stmt, {})

                        -- Check if this statement uses any exports without importing them
                        for depName in pairs(deps) do
                            if exportNamesToCheck[depName] then
                                local exportInfo = exportNamesToCheck[depName]
                                if not exportsNeedingRename[exportInfo.filePath] then
                                    exportsNeedingRename[exportInfo.filePath] = {}
                                end
                                exportsNeedingRename[exportInfo.filePath][exportInfo.originalName] = true
                            end
                        end

                        table.insert(allItems, {
                            id = itemId,
                            type = 'method',
                            name = memberPath,
                            originalName = memberPath,
                            methodPath = memberPath,
                            stmt = stmt,
                            dependencies = deps,
                            importedNames = fileImportedNames,
                            importMap = fileImportMap,
                            fileRenameMap = fileSpecificRenames[file.path] or {},
                            fileOrder = i,
                            filePath = file.path,
                            stmtIndex = stmtIndex,
                            isDeclaration = true
                        })
                    -- Check if this is a table member assignment (e.g., Table.__index = Table, Table.prototype = {})
                    -- Treat these as declarations so dependency ordering recognizes them
                    elseif memberPath and memberPath:find("%.") then
                        -- This is a member assignment (not a function, but still important for ordering)
                        local deps = extractIdentifiersFromStatement(stmt, {})

                        -- Check if this statement uses any exports without importing them
                        for depName in pairs(deps) do
                            if exportNamesToCheck[depName] then
                                local exportInfo = exportNamesToCheck[depName]
                                if not exportsNeedingRename[exportInfo.filePath] then
                                    exportsNeedingRename[exportInfo.filePath] = {}
                                end
                                exportsNeedingRename[exportInfo.filePath][exportInfo.originalName] = true
                            end
                        end

                        table.insert(allItems, {
                            id = itemId,
                            type = 'member_assignment',
                            name = memberPath,
                            originalName = memberPath,
                            stmt = stmt,
                            dependencies = deps,
                            importedNames = fileImportedNames,
                            importMap = fileImportMap,
                            fileRenameMap = fileSpecificRenames[file.path] or {},
                            fileOrder = i,
                            filePath = file.path,
                            stmtIndex = stmtIndex,
                            isDeclaration = true  -- Mark as declaration so it can be found by dependency tracker
                        })
                    else
                        -- Regular assignment
                        local deps = extractIdentifiersFromStatement(stmt, {})

                        -- Check if this statement uses any exports without importing them
                        for depName in pairs(deps) do
                            if exportNamesToCheck[depName] then
                                local exportInfo = exportNamesToCheck[depName]
                                if not exportsNeedingRename[exportInfo.filePath] then
                                    exportsNeedingRename[exportInfo.filePath] = {}
                                end
                                exportsNeedingRename[exportInfo.filePath][exportInfo.originalName] = true
                            end
                        end

                        table.insert(allItems, {
                            id = itemId,
                            type = 'statement',
                            stmt = stmt,
                            dependencies = deps,
                            importedNames = fileImportedNames,
                            importMap = fileImportMap,
                            fileRenameMap = fileSpecificRenames[file.path] or {},
                            fileOrder = i,
                            filePath = file.path,
                            stmtIndex = stmtIndex,
                            isDeclaration = false
                        })
                    end

                -- Handle other statements
                else
                    local deps = extractIdentifiersFromStatement(stmt, {})

                    -- Check if this statement uses any exports without importing them
                    for depName in pairs(deps) do
                        if exportNamesToCheck[depName] then
                            local exportInfo = exportNamesToCheck[depName]
                            if not exportsNeedingRename[exportInfo.filePath] then
                                exportsNeedingRename[exportInfo.filePath] = {}
                            end
                            exportsNeedingRename[exportInfo.filePath][exportInfo.originalName] = true
                        end
                    end

                    table.insert(allItems, {
                        id = itemId,
                        type = 'statement',
                        stmt = stmt,
                        dependencies = deps,
                        importedNames = fileImportedNames,
                        importMap = fileImportMap,
                        fileRenameMap = fileSpecificRenames[file.path] or {},
                        fileOrder = i,
                        filePath = file.path,
                        stmtIndex = stmtIndex,
                        isDeclaration = false
                    })
                end
            end
        end
    end

    -- Apply the renames to exports that were used without imports
    -- This ensures each file's local variables don't conflict with exports
    for filePath, exports in pairs(exportsNeedingRename) do
        for originalName in pairs(exports) do
            if exportedVars[filePath] and exportedVars[filePath][originalName] then
                local currentName = exportedVars[filePath][originalName]

                -- Keep renaming until we find a name that doesn't conflict
                -- This handles cases like: module exports 'config', entry has 'config' and 'config2'
                -- First rename: config -> config2 (conflict!)
                -- Second rename: config2 -> config3 (no conflict, done)

                -- Extract base name and starting counter
                local baseName = currentName
                local counter = 2
                -- Check if currentName already has a number suffix (e.g., "config2")
                local nameWithoutNumber = currentName:match("^(.-)%d+$")
                if nameWithoutNumber then
                    baseName = nameWithoutNumber
                    local numberPart = currentName:match("%d+$")
                    if numberPart then
                        counter = tonumber(numberPart) + 1
                    end
                end

                local newName = baseName .. counter
                -- Make sure this new name is registered as used
                usedNames[newName] = true

                local needsAnotherRename = true
                local maxIterations = 100  -- Safety limit to prevent infinite loops
                local iterations = 0

                while needsAnotherRename and iterations < maxIterations do
                    iterations = iterations + 1
                    needsAnotherRename = false

                    -- Check if the new name conflicts with any variables in ANY file
                    for _, item in ipairs(allItems) do
                        -- Check dependencies of each item
                        for depName in pairs(item.dependencies) do
                            if depName == newName then
                                -- This new name is used somewhere! Need to rename again
                                -- But only if it's in a different file or not from an import
                                if item.filePath ~= filePath or not (item.importMap and item.importMap[depName]) then
                                    counter = counter + 1
                                    newName = baseName .. counter
                                    usedNames[newName] = true
                                    needsAnotherRename = true
                                    break
                                end
                            end
                        end
                        if needsAnotherRename then break end
                    end
                end

                -- Update exportedVars to use the new name
                exportedVars[filePath][originalName] = newName

                -- Update fileSpecificRenames
                if fileSpecificRenames[filePath] then
                    fileSpecificRenames[filePath][originalName] = newName
                end

                -- Update all items that use this export
                for _, item in ipairs(allItems) do
                    -- Update items from the same file (the file that exports it)
                    if item.filePath == filePath then
                        if item.type == 'function' and item.name == currentName then
                            item.name = newName
                            -- Update AST
                            if item.stmt.Name and type(item.stmt.Name) == 'table' then
                                item.stmt.Name.Name = newName
                            end
                        elseif item.type == 'variable' then
                            for i, name in ipairs(item.names) do
                                if name == currentName then
                                    item.names[i] = newName
                                    -- Update AST
                                    if item.stmt.LocalList and item.stmt.LocalList[i] then
                                        item.stmt.LocalList[i].Name = newName
                                    end
                                end
                            end
                        end

                        -- Update fileRenameMap for this item
                        if item.fileRenameMap then
                            item.fileRenameMap[originalName] = newName
                        end
                    end

                    -- Update import maps in other files that import this
                    if item.importMap then
                        for alias, importedName in pairs(item.importMap) do
                            if importedName == currentName then
                                item.importMap[alias] = newName
                            end
                        end
                    end
                end
            end
        end
    end

    -- Apply global renames and import maps to all AST nodes
    local renameInStatement  -- Forward declaration

    local function renameInNode(node, importedNames, importMap, fileRenameMap)
        if not node then return end

        if node.AstType == 'VarExpr' then
            -- First check import map (e.g., rpgstingermaid -> maid)
            if importMap[node.Name] then
                node.Name = importMap[node.Name]
                if node.Variable then
                    node.Variable.Name = node.Name
                end
            -- Then check file-specific renames (e.g., maid -> maid2 within this specific file)
            elseif not importedNames[node.Name] and fileRenameMap and fileRenameMap[node.Name] then
                node.Name = fileRenameMap[node.Name]
                if node.Variable then
                    node.Variable.Name = node.Name
                end
            -- Finally apply global renames if not imported
            elseif not importedNames[node.Name] then
                node.Name = globalRenameMap[node.Name] or node.Name
                if node.Variable then
                    node.Variable.Name = node.Name
                end
            end
        elseif node.AstType == 'CallExpr' or node.AstType == 'TableCallExpr' or node.AstType == 'StringCallExpr' then
            renameInNode(node.Base, importedNames, importMap, fileRenameMap)
            if node.Arguments then
                for _, arg in ipairs(node.Arguments) do
                    renameInNode(arg, importedNames, importMap, fileRenameMap)
                end
            end
        elseif node.AstType == 'BinopExpr' then
            renameInNode(node.Lhs, importedNames, importMap, fileRenameMap)
            renameInNode(node.Rhs, importedNames, importMap, fileRenameMap)
        elseif node.AstType == 'UnopExpr' then
            renameInNode(node.Rhs, importedNames, importMap, fileRenameMap)
        elseif node.AstType == 'IndexExpr' then
            renameInNode(node.Base, importedNames, importMap, fileRenameMap)
            renameInNode(node.Index, importedNames, importMap, fileRenameMap)
        elseif node.AstType == 'MemberExpr' then
            renameInNode(node.Base, importedNames, importMap, fileRenameMap)
        elseif node.AstType == 'Parentheses' then
            renameInNode(node.Inner, importedNames, importMap, fileRenameMap)
        elseif node.AstType == 'Function' then
            -- Rename inside function bodies
            if node.Body and node.Body.Body then
                for _, s in ipairs(node.Body.Body) do
                    renameInStatement(s, importedNames, importMap, fileRenameMap)
                end
            end
        elseif node.AstType == 'ConstructorExpr' and node.EntryList then
            for _, entry in ipairs(node.EntryList) do
                if entry.Key then renameInNode(entry.Key, importedNames, importMap, fileRenameMap) end
                if entry.Value then renameInNode(entry.Value, importedNames, importMap, fileRenameMap) end
            end
        end
    end

    renameInStatement = function(stmt, importedNames, importMap, fileRenameMap)
        importMap = importMap or {}
        fileRenameMap = fileRenameMap or {}
        if stmt.AstType == 'CallStatement' then
            renameInNode(stmt.Expression, importedNames, importMap, fileRenameMap)
        elseif stmt.AstType == 'AssignmentStatement' then
            if stmt.Lhs then
                for _, expr in ipairs(stmt.Lhs) do
                    renameInNode(expr, importedNames, importMap, fileRenameMap)
                end
            end
            if stmt.Rhs then
                for _, expr in ipairs(stmt.Rhs) do
                    renameInNode(expr, importedNames, importMap, fileRenameMap)
                end
            end
        elseif stmt.AstType == 'LocalStatement' then
            if stmt.InitList then
                for _, expr in ipairs(stmt.InitList) do
                    renameInNode(expr, importedNames, importMap, fileRenameMap)
                end
            end
        elseif stmt.AstType == 'ReturnStatement' and stmt.Arguments then
            for _, arg in ipairs(stmt.Arguments) do
                renameInNode(arg, importedNames, importMap, fileRenameMap)
            end
        elseif stmt.AstType == 'Function' and stmt.Body and stmt.Body.Body then
            for _, s in ipairs(stmt.Body.Body) do
                renameInStatement(s, importedNames, importMap, fileRenameMap)
            end
        elseif stmt.AstType == 'IfStatement' then
            -- Rename condition
            if stmt.Clauses then
                for _, clause in ipairs(stmt.Clauses) do
                    if clause.Condition then
                        renameInNode(clause.Condition, importedNames, importMap, fileRenameMap)
                    end
                    if clause.Body and clause.Body.Body then
                        for _, s in ipairs(clause.Body.Body) do
                            renameInStatement(s, importedNames, importMap, fileRenameMap)
                        end
                    end
                end
            end
        elseif stmt.AstType == 'WhileStatement' then
            if stmt.Condition then
                renameInNode(stmt.Condition, importedNames, importMap, fileRenameMap)
            end
            if stmt.Body and stmt.Body.Body then
                for _, s in ipairs(stmt.Body.Body) do
                    renameInStatement(s, importedNames, importMap, fileRenameMap)
                end
            end
        elseif stmt.AstType == 'RepeatStatement' then
            if stmt.Condition then
                renameInNode(stmt.Condition, importedNames, importMap, fileRenameMap)
            end
            if stmt.Body and stmt.Body.Body then
                for _, s in ipairs(stmt.Body.Body) do
                    renameInStatement(s, importedNames, importMap, fileRenameMap)
                end
            end
        elseif stmt.AstType == 'NumericForStatement' or stmt.AstType == 'GenericForStatement' then
            -- Rename loop expressions
            if stmt.Start then renameInNode(stmt.Start, importedNames, importMap, fileRenameMap) end
            if stmt.End then renameInNode(stmt.End, importedNames, importMap, fileRenameMap) end
            if stmt.Step then renameInNode(stmt.Step, importedNames, importMap, fileRenameMap) end
            if stmt.Generators then
                for _, gen in ipairs(stmt.Generators) do
                    renameInNode(gen, importedNames, importMap, fileRenameMap)
                end
            end
            if stmt.Body and stmt.Body.Body then
                for _, s in ipairs(stmt.Body.Body) do
                    renameInStatement(s, importedNames, importMap, fileRenameMap)
                end
            end
        elseif stmt.AstType == 'DoStatement' then
            if stmt.Body and stmt.Body.Body then
                for _, s in ipairs(stmt.Body.Body) do
                    renameInStatement(s, importedNames, importMap, fileRenameMap)
                end
            end
        end
    end

    -- Apply renames to all items
    for _, item in ipairs(allItems) do
        renameInStatement(item.stmt, item.importedNames or {}, item.importMap or {}, item.fileRenameMap or {})
    end

    -- Build dependency lookup for just-in-time insertion
    local itemByName = {}
    local itemById = {}
    for _, item in ipairs(allItems) do
        itemById[item.id] = item
        if item.isDeclaration then
            if item.type == 'function' then
                itemByName[item.name] = item
            elseif item.type == 'method' then
                itemByName[item.methodPath or item.name] = item
            elseif item.type == 'member_assignment' then
                -- Register member assignments (e.g., TargetSquare.__index)
                itemByName[item.name] = item
            elseif item.type == 'variable' then
                for _, name in ipairs(item.names) do
                    itemByName[name] = item
                end
            end
        end
    end

    -- Separate entry file items from imported items
    local entryItems = {}
    local importedItems = {}

    for _, item in ipairs(allItems) do
        if item.filePath == entryFilePath then
            table.insert(entryItems, item)
        else
            table.insert(importedItems, item)
        end
    end

    -- Sort each group by their statement index within their file
    table.sort(entryItems, function(a, b)
        return a.stmtIndex < b.stmtIndex
    end)
    table.sort(importedItems, function(a, b)
        return a.stmtIndex < b.stmtIndex
    end)

    -- Build output: order files by dependencies, within each file only reorder when needed
    local sorted = {}
    local addedFiles = {}
    local added = {}
    local inProgress = {}  -- Track files currently being added (for cycle detection)

    -- Build file-level dependency map
    local fileDeps = {}  -- Maps filePath -> set of dependent file paths
    for _, item in ipairs(importedItems) do
        if not fileDeps[item.filePath] then
            fileDeps[item.filePath] = {}
        end

        -- Track which files this file depends on
        if item.importMap then
            for alias, actualName in pairs(item.importMap) do
                -- Find which file provides this name
                local depItem = itemByName[actualName]
                if depItem and depItem.filePath ~= item.filePath and depItem.filePath ~= entryFilePath then
                    fileDeps[item.filePath][depItem.filePath] = true
                end
            end
        end
    end

    -- Detect circular dependencies at file level
    local circularFiles = {}  -- Set of files involved in circular dependencies
    local function detectCircularDeps(filePath, visited, stack)
        if circularFiles[filePath] then return end  -- Already processed
        if stack[filePath] then
            -- Found a cycle! Mark all files in the cycle
            circularFiles[filePath] = true
            return
        end
        if visited[filePath] then return end

        visited[filePath] = true
        stack[filePath] = true

        if fileDeps[filePath] then
            for depFilePath in pairs(fileDeps[filePath]) do
                detectCircularDeps(depFilePath, visited, stack)
                if circularFiles[depFilePath] then
                    circularFiles[filePath] = true
                end
            end
        end

        stack[filePath] = nil
    end

    -- Run cycle detection on all imported files
    for _, item in ipairs(importedItems) do
        detectCircularDeps(item.filePath, {}, {})
    end

    -- For files with circular dependencies, just track them (no forward declarations)
    local forwardDecls = {}  -- Maps varName -> true for variables in circular files
    for filePath in pairs(circularFiles) do
        for _, item in ipairs(importedItems) do
            if item.filePath == filePath and item.isDeclaration then
                if item.type == 'variable' then
                    for _, name in ipairs(item.names) do
                        forwardDecls[name] = true
                    end
                elseif item.type == 'function' then
                    forwardDecls[item.name] = true
                end
            end
        end
    end

    -- Recursive function to add items with dependencies
    local addingStack = {}  -- Track items currently being added (for circular dependency detection)

    local function addItemWithDeps(item, skipForwardDecls)
        if added[item.id] then return end
        if addingStack[item.id] then
            -- Circular dependency within statements - the forward declaration will handle this
            return
        end

        addingStack[item.id] = true

        -- Add dependencies first
        for depName in pairs(item.dependencies) do
            local resolvedName = depName
            -- Resolve through import map
            if item.importMap and item.importMap[depName] then
                resolvedName = item.importMap[depName]
            end
            local depItem = itemByName[resolvedName]

            -- Add dependency if:
            -- 1. It's in the same file (always reorder within file)
            -- 2. OR it's a forward-declared item (cross-file circular dependency)
            if depItem and depItem.id ~= item.id and not added[depItem.id] then
                if depItem.filePath == item.filePath then
                    -- Same file - always add dependency first
                    addItemWithDeps(depItem, skipForwardDecls)
                elseif forwardDecls[resolvedName] then
                    -- Cross-file circular dependency - add the dependency before this item
                    -- Find the file and add it if not already added
                    local depIsCircular = circularFiles[depItem.filePath]
                    addItemWithDeps(depItem, depIsCircular)
                end
            end
        end

        addingStack[item.id] = nil

        -- For circular dependencies, just add the statements as-is (they stay as local function/local var)
        -- The dependency ordering already ensures correct order

        table.insert(sorted, item)
        added[item.id] = true
    end

    -- Recursive function to add entire files (with cycle detection)
    local function addFile(filePath)
        if addedFiles[filePath] then return end
        if inProgress[filePath] then
            -- Circular dependency detected - skip for now
            return
        end

        inProgress[filePath] = true

        -- Add dependent files first (but skip if they create cycles)
        if fileDeps[filePath] then
            for depFilePath in pairs(fileDeps[filePath]) do
                addFile(depFilePath)
            end
        end

        addedFiles[filePath] = true
        inProgress[filePath] = nil

        -- Add all items from this file, reordering only when there are dependencies
        local isCircular = circularFiles[filePath]
        for _, item in ipairs(importedItems) do
            if item.filePath == filePath then
                addItemWithDeps(item, isCircular)
            end
        end
    end

    -- Add all imported files in dependency order
    for _, item in ipairs(importedItems) do
        addFile(item.filePath)
    end

    -- Add all entry file items in their original order (no reordering for entry file)
    for _, item in ipairs(entryItems) do
        table.insert(sorted, item)
    end

    -- Generate output AST
    local outputBody = {}
    for _, item in ipairs(sorted) do
        table.insert(outputBody, item.stmt)
    end

    local outputAst = {
        AstType = 'Statlist',
        Scope = files[1].ast.Scope,
        Body = outputBody
    }

    -- Generate code with or without minification
    local output
    if minify then
        -- First format without minification
        local unminified = Format_Beautiful(outputAst)
        -- Then parse to rebuild scope and minify
        local st, ast = ParseLua(unminified)
        if not st then
            error("Failed to reparse for minification: " .. tostring(ast))
        end
        -- Apply mangling if requested
        if mangle ~= "none" then
            ast = Mangle(ast, mangle == "auto")
        end
        output = Format_Mini(ast)
    else
        -- Format_Beautiful preserves original variable names with nice formatting
        output = Format_Beautiful(outputAst)
    end

    return output
end

return ImportBundler
