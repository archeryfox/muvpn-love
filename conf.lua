function love.conf(t)
    t.identity = "muvpn_love"
    t.version = "11.5"
    t.console = false

    t.window.title = "muVPN LÖVE pilot"
    t.window.width = 640
    t.window.height = 480
    t.window.resizable = false
    t.window.fullscreen = true
    t.window.vsync = 1
    t.window.msaa = 0
    t.window.highdpi = false

    t.modules.physics = false
    t.modules.video = false
end
