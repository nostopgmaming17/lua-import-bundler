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

-- Extract all identifiers from AST node
local function extractIdentifiers(node, identifiers)
    identifiers = identifiers or {}

    if not node then
        return identifiers
    end

    if node.AstType == 'VarExpr' then
        identifiers[node.Name] = true
    elseif node.AstType == 'CallExpr' or node.AstType == 'TableCallExpr' or node.AstType == 'StringCallExpr' then
        extractIdentifiers(node.Base, identifiers)
        if node.Arguments then
            for _, arg in ipairs(node.Arguments) do
                extractIdentifiers(arg, identifiers)
            end
        end
    elseif node.AstType == 'BinopExpr' then
        extractIdentifiers(node.Lhs, identifiers)
        extractIdentifiers(node.Rhs, identifiers)
    elseif node.AstType == 'UnopExpr' then
        extractIdentifiers(node.Rhs, identifiers)
    elseif node.AstType == 'IndexExpr' then
        extractIdentifiers(node.Base, identifiers)
        extractIdentifiers(node.Index, identifiers)
    elseif node.AstType == 'MemberExpr' then
        extractIdentifiers(node.Base, identifiers)
    elseif node.AstType == 'Function' then
        if node.Body and node.Body.Body then
            for _, stmt in ipairs(node.Body.Body) do
                extractIdentifiersFromStatement(stmt, identifiers)
            end
        end
    elseif node.AstType == 'Parentheses' then
        extractIdentifiers(node.Inner, identifiers)
    elseif node.AstType == 'ConstructorExpr' then
        if node.EntryList then
            for _, entry in ipairs(node.EntryList) do
                if entry.Key then extractIdentifiers(entry.Key, identifiers) end
                if entry.Value then extractIdentifiers(entry.Value, identifiers) end
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

    -- Process files (dependencies come first in the files list)
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
            for _, stmt in ipairs(file.ast.Body) do
                local itemId = file.name .. "_" .. itemIdCounter
                itemIdCounter = itemIdCounter + 1

                -- Handle function declarations
                if stmt.AstType == 'Function' and stmt.Name then
                    local originalName = stmt.Name.Name or stmt.Name

                    -- Check if this is an exported function (already has a unique name assigned)
                    local uniqueName
                    if exportedVars[file.path] and exportedVars[file.path][originalName] then
                        uniqueName = exportedVars[file.path][originalName]
                    else
                        -- Non-exported local function
                        uniqueName = getUniqueName(originalName)
                        if uniqueName ~= originalName then
                            globalRenameMap[originalName] = uniqueName
                        end
                    end

                    -- Update the AST
                    if type(stmt.Name) == 'table' then
                        stmt.Name.Name = uniqueName
                    end

                    local deps = extractIdentifiersFromStatement(stmt, {})

                    table.insert(allItems, {
                        id = itemId,
                        type = 'function',
                        name = uniqueName,
                        originalName = originalName,
                        stmt = stmt,
                        dependencies = deps,
                        importedNames = fileImportedNames,
                        importMap = fileImportMap,
                        fileOrder = i,
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
                        isDeclaration = true
                    })

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
                        isDeclaration = false
                    })
                end
            end
        end
    end

    -- Apply global renames and import maps to all AST nodes
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
        elseif node.AstType == 'ConstructorExpr' and node.EntryList then
            for _, entry in ipairs(node.EntryList) do
                if entry.Key then renameInNode(entry.Key, importedNames, importMap) end
                if entry.Value then renameInNode(entry.Value, importedNames, importMap) end
            end
        end
    end

    local function renameInStatement(stmt, importedNames, importMap)
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
        end
    end

    -- Apply renames to all items
    for _, item in ipairs(allItems) do
        renameInStatement(item.stmt, item.importedNames or {}, item.importMap or {})
    end

    -- Topological sort
    local declarations = {}
    local statements = {}
    for _, item in ipairs(allItems) do
        if item.isDeclaration then
            table.insert(declarations, item)
        else
            table.insert(statements, item)
        end
    end

    local sorted = {}
    local visited = {}
    local visiting = {}
    local itemByName = {}

    for _, item in ipairs(declarations) do
        if item.type == 'function' then
            itemByName[item.name] = item
        elseif item.type == 'variable' then
            for _, name in ipairs(item.names) do
                itemByName[name] = item
            end
        end
    end

    local function visit(item)
        if not item or visited[item.id] or visiting[item.id] then
            return
        end

        visiting[item.id] = true

        for depName in pairs(item.dependencies) do
            -- Apply import map to resolve aliases
            local resolvedName = depName
            if item.importMap and item.importMap[depName] then
                resolvedName = item.importMap[depName]
            end

            local depItem = itemByName[resolvedName]
            if depItem and depItem.id ~= item.id then
                visit(depItem)
            end
        end

        visiting[item.id] = nil
        visited[item.id] = true
        table.insert(sorted, item)
    end

    -- Visit all declarations (topological sort will determine order)
    for _, item in ipairs(declarations) do
        visit(item)
    end

    -- Add statements in their original order
    for _, item in ipairs(statements) do
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
