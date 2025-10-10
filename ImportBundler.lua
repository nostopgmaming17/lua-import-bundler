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

    -- First pass: collect all exports and assign unique names
    for i = 1, #files do
        local file = files[i]
        exportedVars[file.path] = {}

        for _, exp in ipairs(file.exports) do
            for _, name in ipairs(exp.names) do
                local uniqueName = getUniqueName(name)
                exportedVars[file.path][name] = uniqueName
                if uniqueName ~= name then
                    globalRenameMap[name] = uniqueName
                end
            end
        end
    end

    -- Process files and track which file is the entry point
    local entryFilePath = files[#files].path  -- Entry file is last (gathered last)
    local fileOrderIndex = {}  -- Track original file order
    for i = 1, #files do
        fileOrderIndex[files[i].path] = i
    end

    for i = 1, #files do
        local file = files[i]
        local fileImportMap = {} -- Maps alias -> {sourcePath, originalName, renamedName}
        local fileImportedNames = {}

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
                        uniqueName = exportedVars[file.path][originalName]
                    elseif not isMethod then
                        -- Non-exported local function
                        uniqueName = getUniqueName(originalName)
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
                            uniqueName = exportedVars[file.path][originalName]
                        else
                            -- Non-exported local variable
                            uniqueName = getUniqueName(originalName)
                            if uniqueName ~= originalName then
                                globalRenameMap[originalName] = uniqueName
                            end
                        end

                        table.insert(uniqueNames, uniqueName)

                        -- Update the AST
                        localVar.Name = uniqueName
                    end

                    local deps = extractIdentifiersFromStatement(stmt, {})

                    table.insert(allItems, {
                        id = itemId,
                        type = 'variable',
                        names = uniqueNames,
                        originalNames = originalNames,
                        stmt = stmt,
                        dependencies = deps,
                        importedNames = fileImportedNames,
                        importMap = fileImportMap,
                        fileOrder = i,
                        fileIndex = i,
                        filePath = file.path,
                        stmtIndex = stmtIndex,
                        isDeclaration = true
                    })

                -- Handle assignment statements (check for method assignments)
                elseif stmt.AstType == 'AssignmentStatement' and stmt.Lhs and #stmt.Lhs == 1 and stmt.Rhs and #stmt.Rhs == 1 then
                    local lhs = stmt.Lhs[1]
                    local rhs = stmt.Rhs[1]

                    -- Check if this is assigning a function to a table member (e.g., Table.method = function())
                    local memberPath = getMemberPath(lhs)
                    if memberPath and memberPath:find("%.") and rhs.AstType == 'Function' then
                        -- This is a method definition via assignment
                        local deps = extractIdentifiersFromStatement(stmt, {})

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
                            fileOrder = i,
                            filePath = file.path,
                            stmtIndex = stmtIndex,
                            isDeclaration = true
                        })
                    else
                        -- Regular assignment
                        local deps = extractIdentifiersFromStatement(stmt, {})

                        table.insert(allItems, {
                            id = itemId,
                            type = 'statement',
                            stmt = stmt,
                            dependencies = deps,
                            importedNames = fileImportedNames,
                            importMap = fileImportMap,
                            fileOrder = i,
                            filePath = file.path,
                            stmtIndex = stmtIndex,
                            isDeclaration = false
                        })
                    end

                -- Handle other statements
                else
                    local deps = extractIdentifiersFromStatement(stmt, {})

                    table.insert(allItems, {
                        id = itemId,
                        type = 'statement',
                        stmt = stmt,
                        dependencies = deps,
                        importedNames = fileImportedNames,
                        importMap = fileImportMap,
                        fileOrder = i,
                        filePath = file.path,
                        stmtIndex = stmtIndex,
                        isDeclaration = false
                    })
                end
            end
        end
    end

    -- Apply global renames and import maps to all AST nodes
    local renameInStatement  -- Forward declaration

    local function renameInNode(node, importedNames, importMap)
        if not node then return end

        if node.AstType == 'VarExpr' then
            -- First check import map (e.g., d -> b)
            if importMap[node.Name] then
                node.Name = importMap[node.Name]
                if node.Variable then
                    node.Variable.Name = node.Name
                end
            -- Then apply global renames if not imported
            elseif not importedNames[node.Name] then
                node.Name = globalRenameMap[node.Name] or node.Name
                if node.Variable then
                    node.Variable.Name = node.Name
                end
            end
        elseif node.AstType == 'CallExpr' or node.AstType == 'TableCallExpr' or node.AstType == 'StringCallExpr' then
            renameInNode(node.Base, importedNames, importMap)
            if node.Arguments then
                for _, arg in ipairs(node.Arguments) do
                    renameInNode(arg, importedNames, importMap)
                end
            end
        elseif node.AstType == 'BinopExpr' then
            renameInNode(node.Lhs, importedNames, importMap)
            renameInNode(node.Rhs, importedNames, importMap)
        elseif node.AstType == 'UnopExpr' then
            renameInNode(node.Rhs, importedNames, importMap)
        elseif node.AstType == 'IndexExpr' then
            renameInNode(node.Base, importedNames, importMap)
            renameInNode(node.Index, importedNames, importMap)
        elseif node.AstType == 'MemberExpr' then
            renameInNode(node.Base, importedNames, importMap)
        elseif node.AstType == 'Parentheses' then
            renameInNode(node.Inner, importedNames, importMap)
        elseif node.AstType == 'Function' then
            -- Rename inside function bodies
            if node.Body and node.Body.Body then
                for _, s in ipairs(node.Body.Body) do
                    renameInStatement(s, importedNames, importMap)
                end
            end
        elseif node.AstType == 'ConstructorExpr' and node.EntryList then
            for _, entry in ipairs(node.EntryList) do
                if entry.Key then renameInNode(entry.Key, importedNames, importMap) end
                if entry.Value then renameInNode(entry.Value, importedNames, importMap) end
            end
        end
    end

    renameInStatement = function(stmt, importedNames, importMap)
        importMap = importMap or {}
        if stmt.AstType == 'CallStatement' then
            renameInNode(stmt.Expression, importedNames, importMap)
        elseif stmt.AstType == 'AssignmentStatement' then
            if stmt.Lhs then
                for _, expr in ipairs(stmt.Lhs) do
                    renameInNode(expr, importedNames, importMap)
                end
            end
            if stmt.Rhs then
                for _, expr in ipairs(stmt.Rhs) do
                    renameInNode(expr, importedNames, importMap)
                end
            end
        elseif stmt.AstType == 'LocalStatement' then
            if stmt.InitList then
                for _, expr in ipairs(stmt.InitList) do
                    renameInNode(expr, importedNames, importMap)
                end
            end
        elseif stmt.AstType == 'ReturnStatement' and stmt.Arguments then
            for _, arg in ipairs(stmt.Arguments) do
                renameInNode(arg, importedNames, importMap)
            end
        elseif stmt.AstType == 'Function' and stmt.Body and stmt.Body.Body then
            for _, s in ipairs(stmt.Body.Body) do
                renameInStatement(s, importedNames, importMap)
            end
        elseif stmt.AstType == 'IfStatement' then
            -- Rename condition
            if stmt.Clauses then
                for _, clause in ipairs(stmt.Clauses) do
                    if clause.Condition then
                        renameInNode(clause.Condition, importedNames, importMap)
                    end
                    if clause.Body and clause.Body.Body then
                        for _, s in ipairs(clause.Body.Body) do
                            renameInStatement(s, importedNames, importMap)
                        end
                    end
                end
            end
        elseif stmt.AstType == 'WhileStatement' then
            if stmt.Condition then
                renameInNode(stmt.Condition, importedNames, importMap)
            end
            if stmt.Body and stmt.Body.Body then
                for _, s in ipairs(stmt.Body.Body) do
                    renameInStatement(s, importedNames, importMap)
                end
            end
        elseif stmt.AstType == 'RepeatStatement' then
            if stmt.Condition then
                renameInNode(stmt.Condition, importedNames, importMap)
            end
            if stmt.Body and stmt.Body.Body then
                for _, s in ipairs(stmt.Body.Body) do
                    renameInStatement(s, importedNames, importMap)
                end
            end
        elseif stmt.AstType == 'NumericForStatement' or stmt.AstType == 'GenericForStatement' then
            -- Rename loop expressions
            if stmt.Start then renameInNode(stmt.Start, importedNames, importMap) end
            if stmt.End then renameInNode(stmt.End, importedNames, importMap) end
            if stmt.Step then renameInNode(stmt.Step, importedNames, importMap) end
            if stmt.Generators then
                for _, gen in ipairs(stmt.Generators) do
                    renameInNode(gen, importedNames, importMap)
                end
            end
            if stmt.Body and stmt.Body.Body then
                for _, s in ipairs(stmt.Body.Body) do
                    renameInStatement(s, importedNames, importMap)
                end
            end
        elseif stmt.AstType == 'DoStatement' then
            if stmt.Body and stmt.Body.Body then
                for _, s in ipairs(stmt.Body.Body) do
                    renameInStatement(s, importedNames, importMap)
                end
            end
        end
    end

    -- Apply renames to all items
    for _, item in ipairs(allItems) do
        renameInStatement(item.stmt, item.importedNames or {}, item.importMap or {})
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

    -- Build output by processing entry file in order and inserting dependencies just-in-time
    local sorted = {}
    local added = {}

    local function addItem(item)
        if added[item.id] then
            return
        end

        -- Add dependencies first (just-in-time)
        for depName in pairs(item.dependencies) do
            local resolvedName = depName
            if item.importMap and item.importMap[depName] then
                resolvedName = item.importMap[depName]
            end

            local depItem = itemByName[resolvedName]
            if depItem and depItem.id ~= item.id and not added[depItem.id] then
                addItem(depItem)
            end
        end

        -- Add this item
        table.insert(sorted, item)
        added[item.id] = true
    end

    -- Process entry file items first (they'll pull in dependencies as needed)
    for _, item in ipairs(entryItems) do
        addItem(item)
    end

    -- Process any remaining imported items that weren't pulled in as dependencies
    for _, item in ipairs(importedItems) do
        addItem(item)
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
