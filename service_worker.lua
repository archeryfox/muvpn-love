local baseDir, configDir, subscriptionFile, serverList, mock = ...

local Log = require("log")
Log.init((baseDir or ".") .. "/debug.log")

local outChannel = love.thread.getChannel("muvpn_service_out")
local inChannel = love.thread.getChannel("muvpn_service_in")

local mockConnected = false
local sequence = 0

local function shellQuote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function runShell(command)
    local a, b, c = os.execute(command)
    if type(a) == "number" then
        return a == 0, a
    end
    if a == true then
        return true, c or 0
    end
    return false, c or b or 1
end

local function readFile(path)
    local file = io.open(path, "r")
    if not file then
        return nil
    end
    local contents = file:read("*a")
    file:close()
    return contents
end

local function trim(text)
    return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function runService(action, identifier)
    sequence = sequence + 1
    local outputPath = string.format(
        "/tmp/muvpn_love_%d_%d.out", os.time(), sequence)
    local arguments = {
        "python3",
        shellQuote(baseDir .. "/tools/muvpn.py"),
        shellQuote(action)
    }
    if identifier then
        arguments[#arguments + 1] = shellQuote(identifier)
    end
    local environment = table.concat({
        "MUVPN_CONFIG_DIR=" .. shellQuote(configDir),
        "TGMUOS_CONFIG_DIR=" .. shellQuote(configDir),
        "TGMUOS_SUBSCRIPTION_CONFIG=" .. shellQuote(subscriptionFile),
        "TGMUOS_SERVERS_FILE=" .. shellQuote(serverList),
        "TGMUOS_SINGBOX_MODE=tun"
    }, " ")
    local command = string.format(
        "cd %s && env %s %s > %s 2>&1",
        shellQuote(baseDir),
        environment,
        table.concat(arguments, " "),
        shellQuote(outputPath))
    local ok, status = runShell(command)
    local text = readFile(outputPath) or ""
    os.remove(outputPath)
    Log.write("service %s id=%s exit=%s status=%s output=%s",
        tostring(action), tostring(identifier), tostring(ok), tostring(status),
        trim(text))
    return ok, trim(text)
end

local function messageFrom(text)
    return (trim(text):gsub("^muVPN:%s*", ""))
end

local function handleMock(request)
    Log.write("mock action: %s id=%s connected=%s", tostring(request.action),
        tostring(request.id), tostring(mockConnected))
    if request.action == "status" then
        outChannel:push({kind = "status", connected = mockConnected})
    elseif request.action == "start" then
        os.execute("sleep 0.6")
        mockConnected = true
        outChannel:push({kind = "action", action = "start", ok = true})
    elseif request.action == "stop" then
        os.execute("sleep 0.4")
        mockConnected = false
        outChannel:push({kind = "action", action = "stop", ok = true})
    elseif request.action == "select" then
        os.execute("sleep 0.3")
        outChannel:push({kind = "select", ok = true, id = request.id})
    elseif request.action == "refresh" then
        os.execute("sleep 0.8")
        outChannel:push({
            kind = "refresh",
            ok = true,
            connected = mockConnected
        })
    end
end

local function handleReal(request)
    Log.write("real action: %s id=%s", tostring(request.action), tostring(request.id))
    local ok, text = runService(request.action, request.id)

    if request.action == "status" then
        outChannel:push({
            kind = "status",
            connected = ok and text == "connected"
        })
    elseif request.action == "start" or request.action == "stop" then
        outChannel:push({
            kind = "action",
            action = request.action,
            ok = ok,
            message = messageFrom(text)
        })
    elseif request.action == "select" then
        outChannel:push({
            kind = "select",
            ok = ok,
            id = request.id,
            message = messageFrom(text)
        })
    elseif request.action == "refresh" then
        local connected = false
        if ok then
            local _, statusText = runService("status")
            connected = trim(statusText) == "connected"
        end
        outChannel:push({
            kind = "refresh",
            ok = ok,
            connected = connected,
            message = messageFrom(text)
        })
    end
end

Log.write("worker init: base=%s config=%s subscription=%s servers=%s mock=%s",
    tostring(baseDir), tostring(configDir), tostring(subscriptionFile),
    tostring(serverList), tostring(mock))

while true do
    local request = inChannel:demand()
    if type(request) == "table" then
        Log.write("request: %s id=%s", tostring(request.action), tostring(request.id))
    end
    if type(request) ~= "table" then
        if request == "quit" then
            break
        end
    elseif request.action == "quit" then
        break
    elseif mock then
        handleMock(request)
    else
        local ok, errorMessage = pcall(handleReal, request)
        if not ok then
            Log.write("worker handler error: %s", tostring(errorMessage))
            local kind = request.action
            if kind == "start" or kind == "stop" then
                kind = "action"
            end
            outChannel:push({
                kind = kind,
                action = request.action,
                ok = false,
                message = tostring(errorMessage)
            })
        end
    end
end
