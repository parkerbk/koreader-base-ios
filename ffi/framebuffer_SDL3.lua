-- load common SDL input/video library
local SDL = require("ffi/SDL3")
local BB = require("ffi/blitbuffer")
local util = require("ffi/util")
local ffi = require("ffi")

-- SDL_FRect's struct body isn't in SDL3_h.lua (only the typedef);
-- declare it here so we can construct SDL_RenderTexture dest rects.
ffi.cdef[[
    struct SDL_FRect { float x; float y; float w; float h; };
    bool SDL_SetRenderDrawColor(struct SDL_Renderer *, unsigned char r,
                                unsigned char g, unsigned char b,
                                unsigned char a);
]]
local framebuffer = {
    -- this blitbuffer will be used when we use refresh emulation
    sdl_bb = nil,
}

function framebuffer:init()
    if not self.dummy then
        -- Input dimensions are *window* sizes
        SDL.open(self.w, self.h, self.x, self.y)
        -- Open might fudge them a bit on the emu, so, resync
        self.w, self.h = SDL.win_w, SDL.win_h
        self:_newBB()
    else
        self.bb = BB.new(600, 800)
    end
    if (os.getenv("EMULATE_BW_SCREEN") or "") ~= "" then
        self.device.hasColorScreen = function() return false end
        self.isColorEnabled = function() return false end
    end

    self.bb:fill(BB.COLOR_WHITE)
    self:refreshFull(0, 0, self:getWidth(), self:getHeight())

    framebuffer.parent.init(self)
end

function framebuffer:resize(w, h)
    local output_w = ffi.new("int[1]", 0)
    local output_h = ffi.new("int[1]", 0)

    SDL.SDL.SDL_GetWindowSize(SDL.screen, output_w, output_h)
    SDL.win_w = w or tonumber(output_w[0])
    SDL.win_h = h or tonumber(output_h[0])

    if SDL.SDL.SDL_GetCurrentRenderOutputSize(SDL.renderer, output_w, output_h) then
        -- This is a workaround to obtain a simulacrum of real pixels in scenarios that marketing likes to refer to as "HiDPI".
        -- The utterly deranged idea is to render things at 2x or 3x, so it can subsequently be scaled down in order to assure everything will always be at least a little bit blurry unless you happen to use exactly 2x or 3x, instead of the traditional methods of just rendering at the desired DPI that have worked perfectly fine in Windows and X11 for decades.
        -- Contrary to claims by the blind that macOS is sharp, it's not.
        -- Wayland is a bad derivative of macOS. Everything macOS does wrong it does worse.
        -- tl;dr Use Windows or X11 if you value your eyes and sanity. Or *gulp* Android. And Sailfish of course.
        w = tonumber(output_w[0])
        h = tonumber(output_h[0])
    else
        w = SDL.win_w
        h = SDL.win_h
    end

    -- iOS rotation / status-bar visibility changes both the window
    -- size and the safe-area insets; re-query so the bb is re-sized to
    -- the new safe area in the next _newBB call below.
    SDL.applyIOSSafeArea(w, h)
    if SDL.safe_left ~= 0 or SDL.safe_top ~= 0
            or SDL.safe_right ~= 0 or SDL.safe_bottom ~= 0 then
        w = SDL.w
        h = SDL.h
    end

    if not self.dummy then
        self:_newBB(w, h)
        SDL.w = w
        SDL.h = h
    else
        self.bb:free()
        self.bb = BB.new(600, 800)
    end

    if SDL.texture then SDL.destroyTexture(SDL.texture) end
    SDL.texture = SDL.createTexture(w, h)

    self.bb:fill(BB.COLOR_WHITE)
    self:refreshFull(0, 0, self:getWidth(), self:getHeight())
end

local bb_emu = os.getenv("EMULATE_BB_TYPE")
function framebuffer:_newBB(w, h)
    w = w or SDL.w
    h = h or SDL.h

    local rotation
    local inverse

    if self.sdl_bb then self.sdl_bb:free() end
    if self.invert_scratch_bb then
        self.invert_scratch_bb:free()
        self.invert_scratch_bb = nil
    end
    if self.bb then
        rotation = self.bb:getRotation()
        inverse = self.bb:getInverse() == 1
        self.bb:free()
    end

    -- we present this buffer to the outside
    local sdl_bb_type = BB["TYPE_" .. (bb_emu or "BBRGB32")]
    local bb = BB.new(w, h, sdl_bb_type)
    local flash = os.getenv("EMULATE_READER_FLASH")
    if flash then
        -- in refresh emulation mode, we use a shadow blitbuffer
        -- and blit refresh areas from it.
        self.sdl_bb = bb
        self.bb = BB.new(w, h, bb:getType())
    else
        self.bb = bb
    end

    if rotation then
        self.bb:setRotation(rotation)
    end

    -- reinit inverse mode on resize
    if inverse then
        self.bb:invert()
    end
end

function framebuffer:_render(bb, x, y, w, h)
    -- Coming back to the foreground repaints the whole screen.
    if SDL.isInIOSBackground() then return end

    -- x, y, w, h without rotation for SDL rectangle
    local px, py, pw, ph = bb:getPhysicalRect(x, y, w, h)

    -- A viewport is a Blitbuffer object that works on a rectangular
    -- subset of the underlying memory without allocating new memory.
    local bb_rect = bb:viewport(x, y, w, h)
    local sdl_rect = SDL.rect(px, py, pw, ph)

    -- iOS night mode: bb pixels are non-inverted (CBB has been told to
    -- ignore the inverse flag for performance), so invert the dirty
    -- region into a scratch buffer right before SDL copies it.
    -- invertblitFrom is a fast C XOR; doing this here keeps UI drawing
    -- on the CBB fast path.
    if bb:getInverse() == 1 then
        if not self.invert_scratch_bb
                or self.invert_scratch_bb:getWidth() ~= bb:getWidth()
                or self.invert_scratch_bb:getHeight() ~= bb:getHeight()
                or self.invert_scratch_bb:getType() ~= bb:getType() then
            if self.invert_scratch_bb then self.invert_scratch_bb:free() end
            self.invert_scratch_bb = BB.new(bb:getWidth(), bb:getHeight(), bb:getType())
        end
        local scratch_rect = self.invert_scratch_bb:viewport(x, y, w, h)
        scratch_rect:invertblitFrom(bb_rect)
        bb_rect = scratch_rect
    end

    if not bb_emu then
        SDL.SDL.SDL_UpdateTexture(SDL.texture, sdl_rect, bb_rect.data, bb_rect.stride)
    else
        -- The manual conversion is here deliberately, so as to separate us from possible bugs in the blitter.
        local vbuf = ffi.new("ColorRGB32[?]", pw*ph)
        local pos = 0
        for vy=0, ph-1 do
            for vx=0, pw-1 do
                vbuf[pos] = bb_rect:getPixelP(vx, vy)[0]:getColorRGB32()
                pos = pos+1
            end
        end
        SDL.SDL.SDL_UpdateTexture(SDL.texture, sdl_rect, vbuf, pw * 4)
    end

    -- Match the bezel color to night-mode state so the letterbox
    -- bars blend with KOReader's UI: white in normal mode, black in
    -- night mode. bb:getInverse() == 1 when night mode is on.
    if bb:getInverse() == 1 then
        SDL.SDL.SDL_SetRenderDrawColor(SDL.renderer, 0, 0, 0, 0xFF)
    else
        SDL.SDL.SDL_SetRenderDrawColor(SDL.renderer, 0xFF, 0xFF, 0xFF, 0xFF)
    end
    SDL.SDL.SDL_RenderClear(SDL.renderer)
    if SDL.safe_left ~= 0 or SDL.safe_top ~= 0
            or SDL.safe_right ~= 0 or SDL.safe_bottom ~= 0 then
        -- Render the bb into the safe-area sub-rect of the window so
        -- the iOS notch / home indicator don't sit on top of the UI.
        -- SDL_RenderTexture takes SDL_FRect (floats); RenderClear above
        -- has already painted the bezel area to match night-mode state.
        local dst = ffi.new("SDL_FRect", SDL.safe_left, SDL.safe_top, SDL.w, SDL.h)
        SDL.SDL.SDL_RenderTexture(SDL.renderer, SDL.texture, nil, dst)
    else
        SDL.SDL.SDL_RenderTexture(SDL.renderer, SDL.texture, nil, nil)
    end
    SDL.SDL.SDL_RenderPresent(SDL.renderer)
end

function framebuffer:refreshFullImp(x, y, w, h)
    if self.dummy then return end

    local bb = self.full_bb or self.bb
    x, y, w, h = bb:getBoundedRect(x, y, w, h)
    self.debug(string.format("refresh on logical rectangle %dx%d+%d+%d", w, h, x, y))

    local flash = os.getenv("EMULATE_READER_FLASH")
    if flash then
        -- Match the rotation of the screen buffer now
        self.sdl_bb:setRotation(bb:getRotation())
        self.sdl_bb:setInverse(bb:getInverse())
        -- This ensures invertRect will not paint to now potentially off-screen regions (e.g., because of a viewport)
        self.sdl_bb:invertRect(x, y, w, h)
        self:_render(self.sdl_bb, x, y, w, h)
        util.usleep(tonumber(flash)*1000)
        -- Resync the shadow buffer with the new content
        self.sdl_bb:blitFrom(bb, x, y, x, y, w, h)
    end
    self:_render(bb, x, y, w, h)
end

function framebuffer:setWindowTitle(new_title)
    framebuffer.parent.setWindowTitle(self, new_title)
    SDL.SDL.SDL_SetWindowTitle(SDL.screen, self.window_title)
end

function framebuffer:setWindowIcon(icon)
    SDL.setWindowIcon(icon)
end

function framebuffer:close()
    if self.invert_scratch_bb then
        self.invert_scratch_bb:free()
        self.invert_scratch_bb = nil
    end
    SDL.SDL.SDL_DestroyRenderer(SDL.renderer)
    SDL.SDL.SDL_Quit()
end

return require("ffi/framebuffer"):extend(framebuffer)
