local Log = {}

Log.path = nil

function Log.init(path)
    Log.path = path
end

function Log.fallbackPath()
    local source
    if love and love.filesystem and love.filesystem.getSource then
        local ok, value = pcall(love.filesystem.getSource)
        if ok and value then
            source = value
        end
    end
    return (source or os.getenv("PWD") or ".") .. "/debug.log"
end

local MAX_BYTES = 262144

function Log.write(format, ...)
    local path = Log.path or Log.fallbackPath()
    local message = select("#", ...) > 0 and string.format(format, ...) or tostring(format)
    local file = io.open(path, "a")
    if not file then
        return
    end
    local size = file:seek("end")
    if size and size > MAX_BYTES then
        file:close()
        os.remove(path .. ".1")
        os.rename(path, path .. ".1")
        file = io.open(path, "a")
        if not file then
            return
        end
    end
    file:write(string.format("[%s] %s\n", os.date("%Y-%m-%d %H:%M:%S"), message))
    file:close()
end

return Log
