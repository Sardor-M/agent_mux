-- examples/tools/inline_calculator.lua
--
-- A trivially safe arithmetic evaluator. Demonstrates the inline tool
-- shape that the registry expects.
--
-- The expression is compiled inside an empty environment — *no* access
-- to globals, no os/io/require — so a malicious model prompt cannot
-- escape into the worker process. Only the math library is exposed.

local _M = {
    name        = "calculator",
    description = "Evaluate a basic arithmetic expression. Supports +, -, *, /, ^, parentheses, and the math.* library (math.sqrt, math.sin, ...).",
    schema = {
        type = "object",
        properties = {
            expr = {
                type        = "string",
                description = "The expression to evaluate. Example: '2 * (3 + 4)' or 'math.sqrt(2)'."
            },
        },
        required = { "expr" },
    },
    timeout_ms = 100,
}

local ALLOWED_ENV = {
    -- Read-only math facilities. Anything not listed here is unreachable
    -- from the loaded chunk because we set _ENV explicitly.
    math = math,
    abs  = math.abs,
    sqrt = math.sqrt,
    pi   = math.pi,
}

function _M.run(input, _ctx)
    if type(input) ~= "table" or type(input.expr) ~= "string" then
        return { is_error = true, content = "expected { expr: string }" }
    end

    local source = "return (" .. input.expr .. ")"
    local chunk, perr = load(source, "calc", "t", ALLOWED_ENV)
    if not chunk then
        return { is_error = true, content = "parse_error: " .. tostring(perr) }
    end

    local ok, val = pcall(chunk)
    if not ok then
        return { is_error = true, content = "eval_error: " .. tostring(val) }
    end

    if type(val) ~= "number" then
        return { is_error = true, content = "result was not a number: " .. type(val) }
    end

    return { content = tostring(val) }
end

return _M
