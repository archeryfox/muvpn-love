local Log = require("log")

local WIDTH, HEIGHT = 640, 480

local COLORS = {
    background = {0.055, 0.078, 0.110},
    header = {0.075, 0.105, 0.140},
    panel = {0.090, 0.125, 0.165},
    row = {0.105, 0.145, 0.190},
    cursor = {0.145, 0.245, 0.315},
    white = {0.95, 0.97, 1.00},
    muted = {0.62, 0.68, 0.76},
    accent = {0.30, 0.80, 0.64},
    checking = {1.00, 0.80, 0.25},
    warn = {1.00, 0.68, 0.22},
    fail = {1.00, 0.38, 0.38}
}

local CONFIG_DIR = os.getenv("MUVPN_CONFIG_DIR") or "/root/.config/muvpn_love"
local SERVER_LIST = os.getenv("TGMUOS_SERVERS_FILE") or (CONFIG_DIR .. "/servers.tsv")
local SELECTION_FILE = os.getenv("TGMUOS_SUBSCRIPTION_CONFIG")
    or (CONFIG_DIR .. "/subscription.conf")
local function mockRequested()
    if os.getenv("MUVPN_LOVE_MOCK") == "1" then
        return true
    end
    local marker = io.open("/tmp/muvpn_love_mock", "r")
    if marker then
        marker:close()
        return true
    end
    return false
end

local MOCK = mockRequested()

local VISIBLE_ROWS = 6
local ROW_HEIGHT = 40
local ROW_GAP = 4
local LIST_X, LIST_Y, LIST_WIDTH = 16, 100, WIDTH - 32
local LIST_HEIGHT = VISIBLE_ROWS * (ROW_HEIGHT + ROW_GAP) - ROW_GAP + 8

local fonts = {}
local worker
local commandChannel
local resultChannel
local baseDir = "."

local servers = {}
local selectedId = ""
local cursor = 0
local firstRow = 0

local connection = "unknown"
local busy = false
local statusLine = "Проверка состояния..."
local errorUntil = 0
local lastPoll = 0
local pollInterval = 2
local lastLoggedState = nil

local MESSAGES = {
    ["bundled sing-box engine is missing"] = "движок sing-box не найден в libexec",
    ["VLESS subscription is not installed"] = "подписка VLESS не установлена",
    ["VLESS subscription refresh failed"] = "не удалось обновить подписку",
    ["sing-box rejected the VPN configuration"] = "sing-box отклонил конфигурацию TUN",
    ["VPN engine failed to start; see private log"] = "движок VPN не запустился",
    ["VPN is already connected"] = "VPN уже подключён",
    ["VPN is already disconnected"] = "VPN уже отключён"
}

local function setColor(color, alpha)
    love.graphics.setColor(color[1], color[2], color[3], alpha or 1)
end

local function loadFont(path, size)
    local ok, font = pcall(love.graphics.newFont, path, size)
    if ok and font then
        return font
    end
    return love.graphics.newFont(size)
end

local function trim(text)
    return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function translate(message)
    local text = trim(message)
    if text == "" then
        return "неизвестная ошибка"
    end
    if MESSAGES[text] then
        return MESSAGES[text]
    end
    if text:match("^%[Errno") then
        return "файл состояния muVPN не найден — нажмите Y для обновления"
    end
    return text
end

local function loadServers()
    local rows = {}
    local file = io.open(SERVER_LIST, "r")
    if file then
        for line in file:lines() do
            local id, ping, name = line:match("^(%x+)\t(%-?%d+)\t([^\t]*)")
            if id and #id == 16 then
                rows[#rows + 1] = {
                    id = id:lower(),
                    ping = tonumber(ping) or -1,
                    name = (name ~= "" and name) or ("Узел " .. (#rows + 1))
                }
            end
        end
        file:close()
    end
    if #rows == 0 and MOCK then
        rows = {
            {id = "aaaaaaaaaaaaaaaa", ping = 42, name = "Москва"},
            {id = "bbbbbbbbbbbbbbbb", ping = 58, name = "Санкт-Петербург"},
            {id = "cccccccccccccccc", ping = 94, name = "Амстердам"},
            {id = "dddddddddddddddd", ping = -1, name = "Франкфурт"}
        }
    end
    servers = rows
end

local function loadSelection()
    selectedId = ""
    local file = io.open(SELECTION_FILE, "r")
    if not file then
        return
    end
    for line in file:lines() do
        local value = line:match("^selected=(%x*)%s*$")
        if value then
            selectedId = value:lower()
            break
        end
    end
    file:close()
end

local function rowCount()
    return #servers + 1
end

local function cursorForSelection()
    if selectedId == "" then
        return 0
    end
    for index, server in ipairs(servers) do
        if server.id == selectedId then
            return index
        end
    end
    return 0
end

local function clampScroll()
    local last = rowCount() - 1
    if cursor < 0 then
        cursor = 0
    elseif cursor > last then
        cursor = last
    end
    if cursor < firstRow then
        firstRow = cursor
    elseif cursor >= firstRow + VISIBLE_ROWS then
        firstRow = cursor - VISIBLE_ROWS + 1
    end
    if firstRow < 0 then
        firstRow = 0
    end
end

local function stateName()
    if busy then
        return "working"
    end
    if love.timer.getTime() < errorUntil then
        return "error"
    end
    return connection
end

local function quitApp()
    if commandChannel then
        commandChannel:push({action = "quit"})
    end
    love.event.quit()
end

local function beginAction(action, id, label)
    if busy then
        Log.write("action ignored (busy): %s", action)
        return
    end
    Log.write("action begin: %s id=%s", action, tostring(id))
    busy = true
    statusLine = label
    resultChannel:clear()
    commandChannel:push({action = action, id = id})
end

local function selectCurrent()
    local id = "auto"
    if cursor > 0 and servers[cursor] then
        id = servers[cursor].id
    end
    beginAction("select", id, "Сохранение выбора...")
end

local function toggleConnection()
    if connection == "connected" then
        beginAction("stop", nil, "Отключение VPN...")
    else
        beginAction("start", nil, "Подключение VPN...")
    end
end

local function refreshSubscription()
    beginAction("refresh", nil, "Обновление подписки...")
end

local function pollStatus()
    local now = love.timer.getTime()
    if busy or now < lastPoll then
        return
    end
    if now < errorUntil then
        return
    end
    lastPoll = now + pollInterval
    commandChannel:push({action = "status"})
end

local function fail(message)
    busy = false
    statusLine = "Ошибка: " .. translate(message)
    errorUntil = love.timer.getTime() + 5
end

local function handleResult(result)
    if type(result) ~= "table" then
        Log.write("bad result: %s", type(result))
        return
    end
    Log.write("result: kind=%s ok=%s connected=%s action=%s message=%s",
        tostring(result.kind), tostring(result.ok), tostring(result.connected),
        tostring(result.action), tostring(result.message))

    if result.kind == "status" then
        if busy then
            return
        end
        connection = result.connected and "connected" or "disconnected"
        statusLine = result.connected and "VPN подключён" or "VPN отключён"
    elseif result.kind == "select" then
        if not result.ok then
            fail(result.message)
            return
        end
        busy = false
        selectedId = (result.id == "auto") and "" or (result.id or "")
        statusLine = "Выбор сохранён"
        lastPoll = 0
    elseif result.kind == "action" then
        if not result.ok then
            fail(result.message)
            return
        end
        busy = false
        if result.action == "start" then
            connection = "connected"
            statusLine = "VPN подключён"
        else
            connection = "disconnected"
            statusLine = "VPN отключён"
        end
        lastPoll = 0
    elseif result.kind == "refresh" then
        if not result.ok then
            fail(result.message)
            return
        end
        busy = false
        loadServers()
        loadSelection()
        cursor = cursorForSelection()
        clampScroll()
        connection = result.connected and "connected" or "disconnected"
        statusLine = "Подписка обновлена: узлов " .. #servers
        lastPoll = 0
    end
end

local function statusLabel()
    if stateName() == "connected" then
        return "ПОДКЛЮЧЕНО", COLORS.accent
    elseif stateName() == "disconnected" then
        return "ОТКЛЮЧЕНО", COLORS.muted
    elseif stateName() == "working" then
        local dots = string.rep(".", 1 + math.floor(love.timer.getTime() * 3) % 3)
        return "РАБОТА" .. dots, COLORS.checking
    elseif stateName() == "error" then
        return "ОШИБКА", COLORS.fail
    end
    return "ПРОВЕРКА...", COLORS.warn
end

local function drawHeader()
    setColor(COLORS.header)
    love.graphics.rectangle("fill", 0, 0, WIDTH, 64)

    setColor(COLORS.white)
    love.graphics.setFont(fonts.title)
    love.graphics.print("muVPN", 20, 8)

    setColor(COLORS.muted)
    love.graphics.setFont(fonts.small)
    love.graphics.print("системный VLESS / TUN  ·  LÖVE pilot", 20, 43)

    local label, color = statusLabel()
    local x, y, w, h = WIDTH - 210, 15, 190, 34
    setColor(COLORS.panel)
    love.graphics.rectangle("fill", x, y, w, h, 8, 8)
    setColor(color)
    love.graphics.setFont(fonts.hint)
    love.graphics.printf(label, x, y + 7, w, "center")
end

local function drawInfoLine()
    setColor(COLORS.muted)
    love.graphics.setFont(fonts.small)
    love.graphics.print("Узлов: " .. #servers, 20, 72)

    local choice = selectedId == "" and "Автоматически" or selectedId:sub(1, 8)
    love.graphics.printf("Выбор: " .. choice, WIDTH - 320, 72, 300, "right")
end

local function drawRow(index, y)
    local isAuto = index == 0
    local server = servers[index]
    local isSelected = (isAuto and selectedId == "")
        or (server and server.id == selectedId)
    local isCursor = index == cursor

    setColor(isCursor and COLORS.cursor or COLORS.row)
    love.graphics.rectangle("fill", LIST_X + 4, y, LIST_WIDTH - 8, ROW_HEIGHT, 6, 6)

    if isCursor then
        setColor(COLORS.accent)
        love.graphics.setLineWidth(2)
        love.graphics.rectangle("line", LIST_X + 4, y, LIST_WIDTH - 8, ROW_HEIGHT, 6, 6)
    end

    if isSelected then
        setColor(COLORS.accent)
        love.graphics.rectangle("fill", LIST_X + 10, y + 10, 4, ROW_HEIGHT - 20, 2, 2)
    end

    setColor(isSelected and COLORS.accent or COLORS.white)
    love.graphics.setFont(fonts.row)
    local name = isAuto and "Автоматически (urltest)" or (server and server.name) or ""
    local nameX = LIST_X + 24
    local nameWidth = LIST_WIDTH - 190
    if love.graphics.setScissor then
        love.graphics.setScissor(nameX, y, nameWidth, ROW_HEIGHT)
    end
    love.graphics.printf(name, nameX, y + 9, nameWidth, "left")
    if love.graphics.setScissor then
        love.graphics.setScissor()
    end

    setColor(COLORS.muted)
    love.graphics.setFont(fonts.small)
    local ping = "—"
    if not isAuto and server then
        ping = server.ping >= 0 and (server.ping .. " мс") or "—"
    end
    love.graphics.printf(ping, LIST_X + LIST_WIDTH - 150, y + 12, 120, "right")
end

local function drawList()
    setColor(COLORS.panel)
    love.graphics.rectangle("fill", LIST_X, LIST_Y, LIST_WIDTH, LIST_HEIGHT, 10, 10)

    local total = rowCount()
    local last = math.min(firstRow + VISIBLE_ROWS, total) - 1
    for index = firstRow, last do
        local y = LIST_Y + 4 + (index - firstRow) * (ROW_HEIGHT + ROW_GAP)
        drawRow(index, y)
    end

    if total > VISIBLE_ROWS then
        setColor(COLORS.muted)
        love.graphics.setFont(fonts.small)
        if firstRow > 0 then
            love.graphics.print("▲", WIDTH - 32, LIST_Y + LIST_HEIGHT - 18)
        end
        if last < total - 1 then
            love.graphics.print("▼", WIDTH - 32, LIST_Y + 2)
        end
    end
end

local function drawFooter()
    local panelY = 388
    setColor(COLORS.header)
    love.graphics.rectangle("fill", 0, panelY, WIDTH, HEIGHT - panelY)

    setColor(COLORS.white)
    love.graphics.setFont(fonts.hint)
    love.graphics.printf("[A] Выбрать   [X] Подключить / Отключить   [R1] Обновить   [B] Выход",
        16, panelY + 8, WIDTH - 32, "center")

    local color = COLORS.muted
    local current = stateName()
    if current == "connected" then
        color = COLORS.accent
    elseif current == "working" then
        color = COLORS.checking
    elseif current == "error" then
        color = COLORS.fail
    end
    setColor(color)
    love.graphics.setFont(fonts.status)
    love.graphics.printf(statusLine, 16, panelY + 30, WIDTH - 32, "center")

    setColor(COLORS.muted)
    love.graphics.setFont(fonts.small)
    love.graphics.printf("Клавиатура: стрелки, Enter — выбрать, X — VPN, R — обновить, Esc — выход",
        16, panelY + 60, WIDTH - 32, "center")
    love.graphics.printf("FPS: " .. love.timer.getFPS(), WIDTH - 90, panelY + 60, 76, "right")
end

function love.load(args)
    love.graphics.setBackgroundColor(COLORS.background)
    love.graphics.setDefaultFilter("linear", "linear")

    fonts.title = loadFont("AdwaitaSans-Regular.ttf", 30)
    fonts.row = loadFont("AdwaitaSans-Regular.ttf", 20)
    fonts.hint = loadFont("AdwaitaSans-Regular.ttf", 15)
    fonts.status = loadFont("AdwaitaSans-Regular.ttf", 17)
    fonts.small = loadFont("AdwaitaSans-Regular.ttf", 13)

    baseDir = (love.filesystem and love.filesystem.getSource
        and love.filesystem.getSource()) or os.getenv("PWD") or "."
    Log.init(baseDir .. "/debug.log")
    Log.write("start: base=%s config=%s subscription=%s servers=%s mock=%s",
        baseDir, CONFIG_DIR, SELECTION_FILE, SERVER_LIST, tostring(MOCK))

    loadServers()
    loadSelection()
    cursor = cursorForSelection()
    clampScroll()

    resultChannel = love.thread.getChannel("muvpn_service_out")
    commandChannel = love.thread.getChannel("muvpn_service_in")
    Log.write("loaded %d servers, selection=%s", #servers,
        selectedId == "" and "auto" or selectedId)

    worker = love.thread.newThread("service_worker.lua")
    worker:start(baseDir, CONFIG_DIR, SELECTION_FILE, SERVER_LIST, MOCK)
    Log.write("worker started")
end

function love.update(dt)
    local result = resultChannel:pop()
    while result do
        handleResult(result)
        result = resultChannel:pop()
    end

    if worker then
        local threadError = worker:getError()
        if threadError then
            Log.write("worker error: %s", tostring(threadError))
            worker = nil
            busy = false
            statusLine = "Поток сервиса: " .. tostring(threadError)
            errorUntil = love.timer.getTime() + 5
        end
    end

    local current = stateName()
    if current ~= lastLoggedState then
        Log.write("state: %s (%s)", current, statusLine)
        lastLoggedState = current
    end

    pollStatus()
end

function love.draw()
    drawHeader()
    drawInfoLine()
    drawList()
    drawFooter()
end

function love.keypressed(key)
    Log.write("key: %s", key)
    if key == "escape" or key == "backspace" or key == "s" then
        quitApp()
    elseif key == "up" then
        cursor = cursor - 1
        clampScroll()
    elseif key == "down" then
        cursor = cursor + 1
        clampScroll()
    elseif key == "return" or key == "kpenter" or key == "space" then
        selectCurrent()
    elseif key == "x" or key == "c" then
        toggleConnection()
    elseif key == "r" then
        refreshSubscription()
    end
end

function love.gamepadpressed(_, button)
    Log.write("gamepad: %s", button)
    if button == "dpup" or button == "up" then
        cursor = cursor - 1
        clampScroll()
    elseif button == "dpdown" or button == "down" then
        cursor = cursor + 1
        clampScroll()
    elseif button == "a" then
        selectCurrent()
    elseif button == "x" then
        toggleConnection()
    elseif button == "rightshoulder" then
        refreshSubscription()
    elseif button == "b" or button == "start" or button == "back" then
        quitApp()
    end
end

function love.quit()
    Log.write("quit")
    if commandChannel then
        commandChannel:push({action = "quit"})
    end
end

local defaultErrorHandler = love.errorhandler
function love.errorhandler(message)
    Log.write("unhandled error: %s", tostring(message))
    if defaultErrorHandler then
        return defaultErrorHandler(message)
    end
    return message
end
