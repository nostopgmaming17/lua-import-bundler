-- ImportParser.lua
-- Extended parser that handles import/export syntax using AST manipulation

local Parser = require "ParseLua"
local ParseLua = Parser.ParseLua
local LexLua = Parser.LexLua

local ImportParser = {}

-- Parse import/export from tokenized Lua
function ImportParser.extractImportsExports(src)
    -- Handle shebang lines (# or #!/usr/bin/env lua)
    local shebang = ""
    if src:sub(1, 1) == "#" then
        local shebangEnd = src:find("\n")
        if shebangEnd then
            shebang = src:sub(1, shebangEnd)
            src = src:sub(shebangEnd + 1)
        end
    end

    local st, tok = LexLua(src)
    if not st then
        return false, tok
    end

    local imports = {}
    local exports = {}
    local cleanedTokens = {}

    local function isKeyword(token, kw)
        return (token.Type == 'Ident' or token.Type == 'Keyword') and token.Data == kw
    end

    local tokenList = tok:getTokenList()
    local i = 1

    while i <= #tokenList do
        local token = tokenList[i]

        -- Check for import statement
        if isKeyword(token, 'import') then
            local importData = {
                imports = {},
                source = nil,
                tokens = {}
            }

            table.insert(importData.tokens, token)
            i = i + 1

            -- Parse import list
            while i <= #tokenList do
                token = tokenList[i]

                if token.Type == 'Ident' and token.Data ~= 'from' and token.Data ~= 'as' then
                    local name = token.Data
                    local alias = name
                    table.insert(importData.tokens, token)
                    i = i + 1

                    -- Check for 'as' alias
                    if i <= #tokenList and isKeyword(tokenList[i], 'as') then
                        table.insert(importData.tokens, tokenList[i])
                        i = i + 1
                        if i <= #tokenList and tokenList[i].Type == 'Ident' then
                            alias = tokenList[i].Data
                            table.insert(importData.tokens, tokenList[i])
                            i = i + 1
                        end
                    end

                    table.insert(importData.imports, {name = name, alias = alias})

                    -- Check for comma
                    if i <= #tokenList and tokenList[i].Type == 'Symbol' and tokenList[i].Data == ',' then
                        table.insert(importData.tokens, tokenList[i])
                        i = i + 1
                    end
                elseif isKeyword(token, 'from') then
                    table.insert(importData.tokens, token)
                    i = i + 1

                    -- Get the string path
                    if i <= #tokenList and tokenList[i].Type == 'String' then
                        local pathStr = tokenList[i].Constant or tokenList[i].Data:sub(2, -2)
                        importData.source = pathStr
                        table.insert(importData.tokens, tokenList[i])
                        i = i + 1
                    end
                    break
                else
                    break
                end
            end

            table.insert(imports, importData)

        -- Check for export statement
        elseif isKeyword(token, 'export') then
            local exportData = {
                isLocal = false,
                isFunction = false,
                names = {},
                tokens = {}
            }

            table.insert(exportData.tokens, token)
            i = i + 1

            -- Require 'local' keyword for all exports
            if i <= #tokenList and isKeyword(tokenList[i], 'local') then
                exportData.isLocal = true
                table.insert(cleanedTokens, tokenList[i]) -- Keep 'local'
                i = i + 1
            else
                return false, "Export statement must use 'local' keyword. Use 'export local' instead of 'export'"
            end

            -- Check for 'function'
            if i <= #tokenList and isKeyword(tokenList[i], 'function') then
                exportData.isFunction = true
                table.insert(cleanedTokens, tokenList[i]) -- Keep 'function'
                i = i + 1

                -- Get function name
                if i <= #tokenList and tokenList[i].Type == 'Ident' then
                    table.insert(exportData.names, tokenList[i].Data)
                    table.insert(cleanedTokens, tokenList[i])
                    i = i + 1
                end
            else
                -- It's a variable export
                while i <= #tokenList do
                    token = tokenList[i]
                    if token.Type == 'Ident' then
                        table.insert(exportData.names, token.Data)
                        table.insert(cleanedTokens, token)
                        i = i + 1

                        -- Check for comma
                        if i <= #tokenList and tokenList[i].Type == 'Symbol' and tokenList[i].Data == ',' then
                            table.insert(cleanedTokens, tokenList[i])
                            i = i + 1
                        else
                            break
                        end
                    else
                        break
                    end
                end
            end

            table.insert(exports, exportData)

            -- Copy remaining tokens for this statement
            while i <= #tokenList do
                token = tokenList[i]
                if token.Type == 'Ident' and (token.Data == 'import' or token.Data == 'export') then
                    break
                end
                -- Stop at newline or next statement indicators
                if token.Type == 'Keyword' and (token.Data == 'local' or token.Data == 'function' or token.Data == 'end') then
                    if token.Data ~= 'end' then
                        break
                    end
                end

                table.insert(cleanedTokens, token)
                i = i + 1

                -- Check if we hit an end of statement
                if token.Type == 'Keyword' and token.Data == 'end' then
                    break
                end
            end
        else
            table.insert(cleanedTokens, token)
            i = i + 1
        end
    end

    -- Rebuild source from cleaned tokens
    local cleanedSrc = ""
    for _, token in ipairs(cleanedTokens) do
        if token.LeadingWhite then
            for _, wt in ipairs(token.LeadingWhite) do
                if wt.Type == 'Whitespace' then
                    cleanedSrc = cleanedSrc .. wt.Data
                elseif wt.Type == 'Comment' then
                    cleanedSrc = cleanedSrc .. wt.Data
                end
            end
        end
        if token.Data then
            cleanedSrc = cleanedSrc .. token.Data
        end
    end

    -- Re-add shebang at the beginning if it existed
    if shebang ~= "" then
        cleanedSrc = shebang .. cleanedSrc
    end

    return true, {
        imports = imports,
        exports = exports,
        cleanedSrc = cleanedSrc
    }
end

return ImportParser
