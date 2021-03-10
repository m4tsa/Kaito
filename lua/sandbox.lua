sandbox = sandbox or {tasks = {}}

include("./lib/async.lua")
json = include("./lib/json.lua")

include("./sandbox/utils.lua")
include("./sandbox/env.lua")

local HOOK_EVERY_INSTRUCTION = 32

function sandbox.exec(state, fenv, fn)
    local instructions_run = state:get_instructions_run()
    local max_instructions = state:get_instruction_limit()

    -- Set the function env
    sandbox.utils.setfenv(fn, fenv)

    -- Create the coroutine thread
    local thread = coroutine.create(fn)
    local timeout = os.clock() + 2

    debug.sethook(
        thread,
        function()
            instructions_run = instructions_run + HOOK_EVERY_INSTRUCTION
            state:set_instructions_run(instructions_run)
            if instructions_run >= max_instructions then
                state:terminate("exec")
                error("Execution quota exceeded")
            end

            if os.clock() > timeout then
                state:terminate("time")
                error("Execution time limit reached")
            end
        end,
        "",
        HOOK_EVERY_INSTRUCTION
    )

    return sandbox.run_coroutine(thread)
end

function sandbox.run_coroutine(thread)
    -- Execute the first coroutine resume
    local ret = {pcall(coroutine.resume, thread)}

    local succ, err, res

    -- Check if the coroutine completed, otherwise add it to the pool
    if coroutine.status(thread) == "dead" then
        succ, err = ret[1] and ret[2], ret[1] and ret[3] or ret[2]

        if succ then
            res = {table.unpack(ret, 3, #ret)}

            return true, nil, res
        else
            return false, nil, err
        end
    else
        return true, thread, nil
    end
end

local function update_env(fenv, state)
    fenv.print = function(...)
        local out = ""
        local tbl = {...}

        for k, v in pairs(tbl) do
            out = out .. tostring(v)

            if next(tbl, k) ~= nil then
                out = out .. ", "
            end
        end

        state:print(out)
    end
    sandbox.utils.setfenv(fenv.print, fenv)

    fenv.http = fenv.http or {}
    fenv.http.fetch = function(url, data)
        return state:http_fetch(url, data or {})
    end
    sandbox.utils.setfenv(fenv.http.fetch, fenv)

    local sandbox = sandbox
    fenv.print_table = function(tbl)
        state:print(sandbox.utils.table_to_string(tbl))
    end
    sandbox.utils.setfenv(fenv.print_table, fenv)

    return fenv
end

function sandbox.async_callback(state, future, success, ...)
    local args = {...}
    sandbox.run(state, function()
        if success then
            future:__handle_resolve(true, table.unpack(args))
        else
            future:__handle_reject(true, table.unpack(args))
        end
    end)
end

function sandbox.run(state, source, env)
    local fenv = update_env(sandbox.env.get_env(), state)

    if env then
        for k,v in pairs(json.decode(env)) do
            fenv[k] = v
        end
    end

    local fn, err

    if type(source) == "function" then
        fn = source
    else
        fn, err = load("return " .. source, "", "t", fenv)

        if not fn then
            fn, err = load(source, "", "t", fenv)
        end
    
        if not fn then
            state:error(tostring(err))
            return
        end
    end

    local succ, thread, res = sandbox.exec(state, fenv, fn)

    if succ then
        -- Update the env
        sandbox.env.env = fenv

        if thread then
            local task_fn = function()
                if coroutine.status(thread) == "dead" then
                    return true
                end

                local fenv = sandbox.env.env
                state:set_state() -- Get Rust to set the registry sandbox state variable
                local succ, thread, res = sandbox.run_coroutine(thread)

                if not succ then
                    sandbox.run(state, function()
                        state:error(tostring(res))
                    end)
                    return true
                elseif res then
                    sandbox.exec(state, fenv, function()
                        local out = ""
        
                        for k, v in pairs(res) do
                            out = out .. tostring(v)
                
                            if next(res, k) ~= nil then
                                out = out .. ", "
                            end
                        end
                
                        state:print(out)
                    end)

                    state:terminate("done")
                end

                if not thread or coroutine.status(thread) == "dead" then
                    return true
                end
            end

            sandbox.tasks[task_fn] = task_fn
        elseif res then
            sandbox.exec(state, fenv, function()
                local out = ""
        
                for k, v in pairs(res) do
                    out = out .. tostring(v)
        
                    if next(res, k) ~= nil then
                        out = out .. ", "
                    end
                end
        
                state:print(out)
            end)

            state:terminate("done")
        end
    else
        sandbox.run(state, function()
            state:error(tostring(res))
        end)
    end
end

function sandbox.think()
    for k,v in pairs(sandbox.tasks) do
        if v() then
            sandbox.tasks[k] = nil
        end
    end

    collectgarbage()
end
