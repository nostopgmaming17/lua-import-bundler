--
-- MangleTableProperties.lua
--
-- This module provides a function that takes a Lua AST, mangles all
-- table property names using a specific character set, and returns the modified AST.
--

local Mangle = {}

-- The visitor table defines functions to be called on specific AST node types.
local visitor = {}

---
-- Recursively walks the AST and applies visitor functions to modify nodes.
-- @param node The current AST node or a table of nodes.
-- @param context A table holding the state for the current transformation pass.
--
function Mangle.traverse(node, context)
    -- VITAL FIX: Prevent infinite recursion from circular references in the AST.
    if type(node) ~= 'table' or context.visited[node] then
        return
    end
    -- Mark the current node as visited BEFORE traversing its children.
    context.visited[node] = true

    -- 1. Apply the visitor function to the current node.
    local visitorFunc = visitor[node.AstType]
    if visitorFunc then
        visitorFunc(node, context)
    end

    -- 2. Recursively traverse the children of the current node.
    for key, child in pairs(node) do
        Mangle.traverse(child, context)
    end
end

---
-- Visitor for Member Expressions (e.g., `table.property` or `table:method`)
--
function visitor.MemberExpr(node, context)
    local originalName = node.Ident.Data
    if originalName then
        node.Ident.Data = context.getMangledName(originalName)
    end
end

---
-- Visitor for Table Constructors (e.g., `t = { key = value }`)
--
function visitor.ConstructorExpr(node, context)
    if not node.EntryList then return end
    for _, entry in ipairs(node.EntryList) do
        -- Handles cases like `{ my_prop = value }`
        if entry.Type == 'KeyString' then
            local originalName = entry.Key
            entry.Key = context.getMangledName(originalName)
        -- Handles cases like `{ ["my_prop"] = value }`
        elseif entry.Type == 'Key' and entry.Key.AstType == 'StringExpr' then
            context.mangleStringNode(entry.Key)
        end
    end
end

---
-- Visitor for Index Expressions (e.g., `table["property"]`)
--
function visitor.IndexExpr(node, context)
    if node.Index and node.Index.AstType == 'StringExpr' then
        context.mangleStringNode(node.Index)
    end
end


---
-- This is the main function that will be returned by the module.
-- It sets up the context and initiates the AST traversal.
--
-- @param ast The Abstract Syntax Tree to be processed.
-- @return The modified Abstract Syntax Tree.
--
local function processAstAndMangleProperties(ast, auto)
    -- Character sets for name generation
    local chars_first = "aAbBcCdDeEfFgGhHiIjJkKlLmMnNoOpPqQrRsStTuUvVwWxXyYzZ_"
    local chars_all = chars_first .. "0123456789"
    local base_first = #chars_first
    local base_all = #chars_all

    local context = {
        nameMap = {},
        nextNameId = 0,
        visited = setmetatable({}, {__mode = "k"}),
    }

    ---
    -- Generates the next mangled name based on the specified character rules.
    --
    function context.generateNextName()
        local n = context.nextNameId
        context.nextNameId = context.nextNameId + 1

        if n < base_first then
            -- For the first 53 names, just return the character directly.
            return chars_first:sub(n + 1, n + 1)
        end
        
        -- For names beyond the first 53
        local name = ""
        -- 1. Determine the first character
        local first_char_index = n % base_first
        name = chars_first:sub(first_char_index + 1, first_char_index + 1)
        n = math.floor(n / base_first)
        
        -- 2. Determine subsequent characters
        while n > 0 do
            local remainder = (n - 1) % base_all
            name = name .. chars_all:sub(remainder + 1, remainder + 1)
            n = math.floor((n - 1) / base_all)
        end
        
        return name
    end

    ---
    -- Gets an existing mangled name or creates a new one for an original property name.
    --
    function context.getMangledName(originalName)
        if originalName:sub(1,2) == "__" then return originalName end
        if not auto and originalName:sub(1,1) ~= "_" then return originalName end
        if auto and originalName:sub(1,1) == "_" then return originalName:sub(2) end
        if not context.nameMap[originalName] then
            context.nameMap[originalName] = context.generateNextName()
        end
        return context.nameMap[originalName]
    end

    ---
    -- Helper function to mangle a StringExpr node used as a table key.
    --
    function context.mangleStringNode(stringNode)
        local fullStringLiteral = stringNode.Value.Data
        local quoteChar = fullStringLiteral:sub(1, 1)

        if quoteChar == "'" or quoteChar == '"' then
            local originalName = fullStringLiteral:sub(2, -2)
            if originalName ~= "" then
                local newName = context.getMangledName(originalName)
                stringNode.Value.Data = quoteChar .. newName .. quoteChar
                context.visited[stringNode.Value] = true
            end
        end
    end

    -- Start the recursive traversal from the root of the AST.
    Mangle.traverse(ast, context)

    -- Return the modified AST.
    return ast
end

return processAstAndMangleProperties