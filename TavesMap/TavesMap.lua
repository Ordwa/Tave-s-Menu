-- TavesMap: personalizzazione della minimappa.
-- Comandi: /tmap (opzioni)  /tmap reset (ripristina)  /tmap debug (elenca le texture della minimappa)
--
-- Layout "compatto" (attivo di default):
--  * l'header (zona, tracking...) e la minimappa stanno nell'angolo in alto a destra
--  * un SOLO pulsante nell'header, dove prima c'era l'icona del tracking, apre un menu a tendina
--    con Calendario, Tracciamento, Mappa, Zoom e gli Addon (i loro pulsanti sulla minimappa vengono raccolti)

local DEFAULTS = {
    clock = true,
    clock24 = true,    -- true = formato 24 ore, false = 12 ore (AM/PM)
    wheelZoom = true,
    compact = true,    -- header in alto a destra + pulsante unico con menu
}

local db

-- Texture decorative di Blizzard sempre nascoste (il bordo lo disegna TavesMap)
local BLIZZ_BORDER = { "MinimapBorder", "MinimapBorderTop", "MinimapCompassTexture" }

-- La minimappa e' solo quadrata
local MASK_SQUARE = "Interface\\Buttons\\WHITE8X8"

---------------------------------------------------------------------
-- Utilita'
---------------------------------------------------------------------
local hookedRegions = {}

-- nasconde un frame/texture e lo tiene nascosto anche se Blizzard lo rimostra
-- Lo sposto sotto un contenitore sempre nascosto: anche se Blizzard chiama Show/SetShown/SetAlpha
-- il frame non si vede. Se Blizzard lo riaggancia altrove, lo rimetto nel contenitore.
local hiddenParent = CreateFrame("Frame")
hiddenParent:Hide()

local function ForceHide(r)
    if not r then return end
    if not hookedRegions[r] then
        hookedRegions[r] = true
        if r.SetParent then
            hooksecurefunc(r, "SetParent", function(self, p)
                if db and db.__hide and p ~= hiddenParent and not self.tavesBusy then
                    self.tavesBusy = true
                    self:SetParent(hiddenParent)
                    self.tavesBusy = false
                end
            end)
        end
        if r.Show then
            hooksecurefunc(r, "Show", function(self) if db and db.__hide then self:Hide() end end)
        end
    end
    r.tavesBusy = true
    if r.SetParent then r:SetParent(hiddenParent) end
    r.tavesBusy = false
    r:Hide()
end

local function HideTextures(frame)
    if not frame or not frame.GetRegions then return end
    for _, r in ipairs({ frame:GetRegions() }) do
        if r.GetObjectType and r:GetObjectType() == "Texture" then
            if not hookedRegions[r] then
                hookedRegions[r] = true
                hooksecurefunc(r, "Show", function(self) self:Hide() end)
            end
            r:Hide()
            r:SetAlpha(0)
        end
    end
end

---------------------------------------------------------------------
-- Bordo sottile e scuro (dietro la minimappa, 2 px), tondo o quadrato
---------------------------------------------------------------------
local ring = CreateFrame("Frame", "TavesMapRing", MinimapCluster)
ring:SetFrameStrata(Minimap:GetFrameStrata())
ring:SetPoint("TOPLEFT", Minimap, "TOPLEFT", -2, 2)
ring:SetPoint("BOTTOMRIGHT", Minimap, "BOTTOMRIGHT", 2, -2)

local RING_COLOR = { 0.06, 0.06, 0.06, 1 }

local ringSquare = ring:CreateTexture(nil, "BACKGROUND")
ringSquare:SetAllPoints(ring)
ringSquare:SetColorTexture(unpack(RING_COLOR))

-- il bordo deve stare sotto la minimappa
local function FixRingLevel()
    local lvl = Minimap:GetFrameLevel()
    if lvl < 1 then
        Minimap:SetFrameLevel(2)
        lvl = 2
    end
    ring:SetFrameLevel(lvl - 1)
end

---------------------------------------------------------------------
-- Coordinate (piccole, dentro la mappa) e orologio (quadratino sveglia)
---------------------------------------------------------------------
local infoFrame = CreateFrame("Frame", nil, Minimap)
infoFrame:SetAllPoints(Minimap)
infoFrame:SetFrameLevel(Minimap:GetFrameLevel() + 5)

-- l'orologio sta nell'header (accanto al nome della zona), non dentro la mappa
local headFrame = CreateFrame("Frame", nil, MinimapCluster)
headFrame:SetAllPoints(MinimapCluster)
headFrame:SetFrameStrata("MEDIUM")
headFrame:SetFrameLevel(MinimapCluster:GetFrameLevel() + 30)

local clockBox = CreateFrame("Button", "TavesMapClock", headFrame, BackdropTemplateMixin and "BackdropTemplate" or nil)
clockBox:SetSize(52, 20)
clockBox:RegisterForClicks("LeftButtonUp")

local function PlaceClock()
    -- dentro l'header, a destra
    local ref = MinimapCluster.ZoneTextButton or _G.MinimapZoneTextButton
    clockBox:ClearAllPoints()
    if ref then
        -- figlio della barra stessa, cosi' sta sempre sopra ed e' dentro l'header
        if clockBox:GetParent() ~= ref then clockBox:SetParent(ref) end
        clockBox:SetFrameLevel(ref:GetFrameLevel() + 10)
        clockBox:SetPoint("RIGHT", ref, "RIGHT", -4, 0)
    else
        clockBox:SetPoint("BOTTOMRIGHT", Minimap, "TOPRIGHT", -4, 4)
    end
end
-- nessuna cornice: l'orario e' solo testo dentro il box dell'header

local clockText = clockBox:CreateFontString(nil, "OVERLAY")
clockText:SetFont("Fonts\\ARIALN.TTF", 15, "")
clockText:SetPoint("CENTER", 0, 0)
clockText:SetTextColor(1, 1, 1, 1)

local function ClockString()
    local on = math.floor(GetTime()) % 2 == 0
    local colon = on and ":" or "|c00ffffff:|r"
    if db.clock24 then
        return date("%H") .. colon .. date("%M")
    end
    -- 12 ore: ora senza zero davanti + AM/PM
    local h = tonumber(date("%I")) or 12
    return h .. colon .. date("%M") .. " " .. date("%p")
end

local function UpdateInfo()
    if not db then return end
    clockBox:SetShown(db.clock)
    if db.clock then
        clockBox:SetWidth(db.clock24 and 52 or 84)
        clockText:SetText(ClockString())
    end
end

---------------------------------------------------------------------
-- Menu a tendina compatto (con sottomenu)
---------------------------------------------------------------------
local ROW_H, MENU_W = 18, 150
local menus = {}   -- [1] principale, [2] sottomenu
local catcher

local function MakeMenu(level)
    local m = CreateFrame("Frame", "TavesMapMenu" .. level, UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    m:SetFrameStrata("FULLSCREEN_DIALOG")
    m:SetFrameLevel(20 + level * 5)
    m:SetClampedToScreen(true)
    m:EnableMouse(true)
    if m.SetBackdrop then
        m:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Buttons\\WHITE8X8",
            edgeSize = 1,
        })
        m:SetBackdropColor(0.05, 0.05, 0.05, 0.95)
        m:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
    end
    m.rows = {}
    m:Hide()
    return m
end

local function CloseMenus()
    for _, m in ipairs(menus) do m:Hide() end
    if catcher then catcher:Hide() end
end

local ShowMenu

local function GetRow(m, i)
    local r = m.rows[i]
    if r then return r end
    r = CreateFrame("Button", nil, m)
    r:SetHeight(ROW_H)
    r:SetPoint("TOPLEFT", 3, -3 - (i - 1) * ROW_H)
    r:SetPoint("TOPRIGHT", -3, -3 - (i - 1) * ROW_H)
    r:SetHighlightTexture("Interface\\Buttons\\WHITE8X8", "ADD")
    r:GetHighlightTexture():SetVertexColor(1, 1, 1, 0.15)
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(14, 14)
    r.icon:SetPoint("LEFT", 2, 0)
    r.text = r:CreateFontString(nil, "OVERLAY")
    r.text:SetFont("Fonts\\ARIALN.TTF", 11, "")
    r.text:SetPoint("LEFT", r.icon, "RIGHT", 4, 0)
    r.text:SetPoint("RIGHT", -12, 0)
    r.text:SetJustifyH("LEFT")
    r.arrow = r:CreateFontString(nil, "OVERLAY")
    r.arrow:SetFont("Fonts\\ARIALN.TTF", 11, "")
    r.arrow:SetPoint("RIGHT", -3, 0)
    r.arrow:SetText(">")
    r:SetScript("OnEnter", function(self)
        if self.level == 1 then
            if self.sub then
                ShowMenu(2, self, self.sub())
            elseif menus[2] then
                menus[2]:Hide()
            end
        end
    end)
    r:SetScript("OnClick", function(self)
        if self.sub then
            ShowMenu(2, self, self.sub())
        else
            CloseMenus()
            if self.func then self.func() end
        end
    end)
    m.rows[i] = r
    return r
end

-- items = lista di { text, icon, func, sub = function() return items end, checked }
function ShowMenu(level, anchor, items)
    if not menus[level] then menus[level] = MakeMenu(level) end
    local m = menus[level]
    if level == 1 then
        if not catcher then
            catcher = CreateFrame("Button", nil, UIParent)
            catcher:SetAllPoints(UIParent)
            catcher:SetFrameStrata("FULLSCREEN_DIALOG")
            catcher:SetFrameLevel(10)
            catcher:RegisterForClicks("AnyUp")
            catcher:SetScript("OnClick", CloseMenus)
        end
        catcher:Show()
        if menus[2] then menus[2]:Hide() end
    end
    items = items or {}
    for i, it in ipairs(items) do
        local r = GetRow(m, i)
        r.level = level
        r.func = it.func
        r.sub = it.sub
        r.text:SetText(it.text)
        if it.checked then r.text:SetTextColor(1, 0.82, 0) else r.text:SetTextColor(1, 1, 1) end
        if it.icon then
            r.icon:SetTexture(it.icon)
            local c = it.coords or { 0.08, 0.92, 0.08, 0.92 }
            r.icon:SetTexCoord(c[1], c[2], c[3], c[4])
            r.icon:Show()
            r.text:SetPoint("LEFT", r.icon, "RIGHT", 4, 0)
        else
            r.icon:Hide()
            r.text:SetPoint("LEFT", r, "LEFT", 4, 0)
        end
        r.arrow:SetShown(it.sub ~= nil)
        r:Show()
    end
    for i = #items + 1, #m.rows do m.rows[i]:Hide() end
    m:SetSize(MENU_W, 6 + math.max(1, #items) * ROW_H)
    m:ClearAllPoints()
    if level == 1 then
        m:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
    else
        -- sottomenu: a destra della riga; se non c'e' spazio il gioco lo tiene dentro lo schermo
        m:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 3, 3)
    end
    m:Show()
end

-- elenco tracciamento
local function TrackingItems()
    local items = {}
    local cm = C_Minimap
    if not (cm and cm.GetNumTrackingTypes) then return items end
    for id = 1, cm.GetNumTrackingTypes() do
        local info = cm.GetTrackingInfo(id)
        if info and info.name then
            local active = info.active
            items[#items + 1] = {
                text = info.name,
                icon = info.texture,
                checked = active,
                func = function() cm.SetTracking(id, not active) end,
            }
        end
    end
    if #items == 0 then items[1] = { text = "Nessun tracciamento" } end
    return items
end

-- pulsanti degli addon attorno alla minimappa (LibDBIcon & simili)
local collected = {}

local function IsAddonButton(c)
    local n = c.GetName and c:GetName()
    return n and (n:find("^LibDBIcon10_") or n:find("^MinimapButton") or n:find("Minimap$") and n ~= "Minimap")
end

local function CollectAddonButtons()
    if not db or not db.compact then return end
    local found = {}
    for _, c in ipairs({ Minimap:GetChildren() }) do
        if IsAddonButton(c) then found[#found + 1] = c end
    end
    -- LibDBIcon puo' creare i pulsanti anche come figli di UIParent
    if LibStub then
        local ok, ldbi = pcall(LibStub, "LibDBIcon-1.0", true)
        if ok and ldbi and ldbi.objects then
            for _, b in pairs(ldbi.objects) do
                if b and not tContains(found, b) then found[#found + 1] = b end
            end
        end
    end
    for _, b in ipairs(found) do
        if not collected[b] then
            collected[b] = true
            hooksecurefunc(b, "Show", function(self)
                if db and db.compact then self:Hide() end
            end)
        end
        b:Hide()
    end
end

local function AddonItems()
    local items = {}
    for b in pairs(collected) do
        local n = b:GetName() or "?"
        local label = n:gsub("^LibDBIcon10_", "")
        local tex = b.icon and b.icon.GetTexture and b.icon:GetTexture()
        items[#items + 1] = {
            text = label,
            icon = tex,
            func = function()
                -- simula un clic sinistro sul pulsante originale
                local fn = b:GetScript("OnClick")
                if fn then fn(b, "LeftButton") end
            end,
        }
    end
    table.sort(items, function(a, b) return a.text < b.text end)
    return items
end

local function MainItems()
    local items = {}
    items[#items + 1] = {
        text = "Calendario", icon = "Interface\\Calendar\\UI-Calendar-Button",
        coords = { 0, 0.390625, 0, 0.78125 },
        func = function()
            if ToggleCalendar then ToggleCalendar()
            elseif GameTimeFrame then GameTimeFrame:Click() end
        end,
    }
    items[#items + 1] = {
        text = "Tracciamento", icon = "Interface\\Icons\\Ability_Tracking",
        sub = TrackingItems,
    }
    items[#items + 1] = {
        text = "Mappa", icon = "Interface\\Icons\\INV_Misc_Map_01",
        func = function() if ToggleWorldMap then ToggleWorldMap() elseif WorldMapFrame then ToggleFrame(WorldMapFrame) end end,
    }
    items[#items + 1] = {
        text = "Zoom +", icon = "Interface\\Icons\\INV_Misc_Spyglass_02",
        func = function() Minimap:SetZoom(math.min(Minimap:GetZoomLevels() - 1, Minimap:GetZoom() + 1)) end,
    }
    items[#items + 1] = {
        text = "Zoom -", icon = "Interface\\Icons\\INV_Misc_Spyglass_03",
        func = function() Minimap:SetZoom(math.max(0, Minimap:GetZoom() - 1)) end,
    }
    if next(collected) then
        items[#items + 1] = {
            text = "Addon", icon = "Interface\\Icons\\INV_Gizmo_01",
            sub = AddonItems,
        }
    end
    items[#items + 1] = {
        text = "Opzioni TavesMap", icon = "Interface\\Icons\\Trade_Engineering",
        func = function() if TavesMap_ToggleOptions then TavesMap_ToggleOptions() end end,
    }
    return items
end

---------------------------------------------------------------------
-- Pulsante unico nell'header (dove c'era l'icona del tracking)
---------------------------------------------------------------------
local menuBtn = CreateFrame("Button", "TavesMapMenuButton", UIParent)
-- aspetto di un pulsante delle action bar: icona quadrata con la cornice di Blizzard
local BTN = 30
menuBtn:SetSize(BTN, BTN)
menuBtn:SetFrameStrata("HIGH")
menuBtn:SetFrameLevel(30)
local menuIcon = menuBtn:CreateTexture(nil, "ARTWORK")
menuIcon:SetAllPoints(menuBtn)
menuIcon:SetTexture("Interface\\Icons\\Trade_Engineering")
menuIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
-- sottile bordo dorato attorno all'icona (4 linee da 1 px, nitide a qualsiasi scala)
local GOLD = { 0.85, 0.68, 0.18, 1 }
local function GoldLine(p1, p2, w, h)
    local t = menuBtn:CreateTexture(nil, "OVERLAY")
    t:SetColorTexture(unpack(GOLD))
    t:SetPoint(p1, menuBtn, p1, 0, 0)
    t:SetPoint(p2, menuBtn, p2, 0, 0)
    if w then t:SetWidth(w) end
    if h then t:SetHeight(h) end
end
GoldLine("TOPLEFT", "TOPRIGHT", nil, 1)
GoldLine("BOTTOMLEFT", "BOTTOMRIGHT", nil, 1)
GoldLine("TOPLEFT", "BOTTOMLEFT", 1, nil)
GoldLine("TOPRIGHT", "BOTTOMRIGHT", 1, nil)
menuBtn:SetPushedTexture("Interface\\Buttons\\WHITE8X8")
menuBtn:GetPushedTexture():SetVertexColor(0, 0, 0, 0.35)
menuBtn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
menuBtn:Hide()
menuBtn:SetScript("OnClick", function(self)
    if menus[1] and menus[1]:IsShown() then
        CloseMenus()
    else
        CollectAddonButtons()
        ShowMenu(1, self, MainItems())
    end
end)
menuBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:SetText("TavesMap")
    GameTooltip:AddLine("Clic per aprire il menu", 1, 1, 1)
    GameTooltip:Show()
end)
menuBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

-- clic sull'orologio: scelta del formato (24 ore / 12 ore AM-PM)
clockBox:SetScript("OnClick", function(self)
    if menus[1] and menus[1]:IsShown() then
        CloseMenus()
        return
    end
    ShowMenu(1, self, {
        { text = "24 ore", checked = db.clock24, func = function() db.clock24 = true; UpdateInfo() end },
        { text = "12 ore (AM/PM)", checked = not db.clock24, func = function() db.clock24 = false; UpdateInfo() end },
    })
end)
clockBox:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:SetText("Orologio")
    GameTooltip:AddLine("Clic per scegliere 24 ore o 12 ore (AM/PM)", 1, 1, 1)
    GameTooltip:Show()
end)
clockBox:SetScript("OnLeave", function() GameTooltip:Hide() end)

---------------------------------------------------------------------
-- Header e pulsanti di Blizzard
---------------------------------------------------------------------
local function BlizzardButtons()
    -- pulsanti che confluiscono nel menu: tracking, calendario, zoom, mappa
    return {
        MinimapCluster.Tracking, _G.MiniMapTracking, _G.GameTimeFrame,
        Minimap.ZoomIn, Minimap.ZoomOut, _G.MinimapZoomIn, _G.MinimapZoomOut,
        _G.MiniMapWorldMapButton,
        -- icona sole/luna e pulsante degli addon di Blizzard
        MinimapCluster.DielFrame, _G.AddonCompartmentFrame, Minimap.AddonCompartment,
        -- orologio di Blizzard: l'orario lo mostra solo TavesMap
        _G.TimeManagerClockButton, MinimapCluster.Clock,
    }
end

-- Nasconde anche per nome: calendario, zoom, addon, sole/luna, orologio e tracking di Blizzard,
-- cercati tra le chiavi dei frame della minimappa e tra i globali.
local KEY_PATTERNS = { "calendar", "gametime", "zoomin", "zoomout", "compartment", "diel", "clock", "tracking", "worldmapbutton" }
local KEY_SKIP = { ZoneTextButton = true, IndicatorFrame = true, InstanceDifficulty = true, Minimap = true }

local function MatchesPattern(name)
    local l = name:lower()
    for _, p in ipairs(KEY_PATTERNS) do
        if l:find(p, 1, true) then return true end
    end
    return false
end

local function IsFrameLike(v)
    return type(v) == "table" and type(v.Hide) == "function" and type(v.GetObjectType) == "function"
end

local function HideByName()
    for _, container in ipairs({ MinimapCluster, Minimap, _G.MinimapBackdrop }) do
        if container then
            for k, v in pairs(container) do
                if type(k) == "string" and not KEY_SKIP[k] and IsFrameLike(v)
                    and v ~= Minimap and v ~= MinimapCluster and MatchesPattern(k) then
                    ForceHide(v)
                end
            end
        end
    end
    for _, name in ipairs({ "GameTimeFrame", "TimeManagerClockButton", "AddonCompartmentFrame",
        "MinimapZoomIn", "MinimapZoomOut", "MiniMapTracking", "MiniMapWorldMapButton" }) do
        if IsFrameLike(_G[name]) then ForceHide(_G[name]) end
    end
    for name, v in pairs(_G) do
        if type(name) == "string" and (name:find("^GameTime") or name:find("^MinimapZoom")
            or name:find("^TimeManagerClock")) and IsFrameLike(v) then
            ForceHide(v)
        end
    end
end

local HEADER_H = 34 -- almeno quanto il pulsante a ingranaggio (30) piu' un po' di margine

-- barra del nome della zona (header)
local function HeaderBar()
    return MinimapCluster.ZoneTextButton or _G.MinimapZoneTextButton
end

local function PlaceMenuButton()
    -- ingranaggio dentro l'header, a sinistra (dov'era l'icona del tracking)
    local bar = HeaderBar()
    menuBtn:ClearAllPoints()
    if bar then
        menuBtn:SetPoint("LEFT", bar, "LEFT", 3, 0)
    else
        menuBtn:SetPoint("TOPLEFT", Minimap, "TOPLEFT", 3, 22)
    end
end

local function ApplyCompact()
    if not db then return end
    if db.compact then
        db.__hide = true
        PlaceMenuButton()
        PlaceClock()
        for _, b in ipairs(BlizzardButtons()) do ForceHide(b) end
        HideByName()
        CollectAddonButtons()
        menuBtn:SetShown(true)
    else
        db.__hide = false
        menuBtn:Hide()
    end
end

local function InEditMode()
    return EditModeManagerFrame and EditModeManagerFrame:IsShown()
end

-- header: stessa larghezza della minimappa, sopra di essa
local function LayoutHeader()
    local bar = HeaderBar()
    if not bar then return end
    local p, rel = bar:GetPoint(1)
    if bar:GetNumPoints() ~= 2 or rel ~= Minimap or p ~= "BOTTOMLEFT" then
        bar:ClearAllPoints()
        bar:SetPoint("BOTTOMLEFT", Minimap, "TOPLEFT", 0, 2)
        bar:SetPoint("BOTTOMRIGHT", Minimap, "TOPRIGHT", 0, 2)
    end
    bar:SetHeight(HEADER_H)
    -- il testo della zona parte dopo l'ingranaggio e finisce prima dell'orologio
    local zt = bar.ZoneText or _G.MinimapZoneText
    if zt and zt.SetPoint then
        zt:ClearAllPoints()
        zt:SetPoint("LEFT", bar, "LEFT", 40, 0)
        zt:SetPoint("RIGHT", bar, "RIGHT", -(clockBox:GetWidth() + 10), 0)
        zt:SetJustifyH("LEFT")
        local path = zt:GetFont()
        if path then zt:SetFont(path, 15, "") end
    end
end

local function HeaderHeight()
    return HEADER_H + 2
end

-- Spazio a disposizione del blocco minimappa (l'area gialla della Modalita' Modifica):
-- e' la "Selection" di Blizzard se esiste, altrimenti il frame MinimapCluster.
-- Le misure sono convertite nelle unita' del MinimapCluster.
-- Le misure le faccio in PIXEL DI SCHERMO (rettangolo x scala effettiva), perche' la
-- minimappa, l'header e il blocco possono avere scale diverse tra loro.
local function RectPx(f)
    local _, _, w, h = f:GetRect()
    if not w then return 0, 0 end
    local s = f:GetEffectiveScale()
    return w * s, h * s
end

local function Area()
    local w, h = RectPx(MinimapCluster)
    local anchor = MinimapCluster
    local sel = MinimapCluster.Selection
    if sel and sel.GetRect then
        local sw, sh = RectPx(sel)
        if sw > w and sh > h then w, h, anchor = sw, sh, sel end
    end
    return w, h, anchor
end

local function Layout()
    if not db or not db.compact then return end
    -- NON tocco la posizione del blocco: la decide la Modalita' Modifica di WoW.

    -- la minimappa e' un QUADRATO perfetto (cosi' il giocatore e' sempre al centro):
    -- il lato e' il piu' grande che entra nell'area gialla, sotto l'header, centrato in orizzontale
    local ms = Minimap:GetEffectiveScale()
    if not ms or ms <= 0 then return end
    local bar = HeaderBar()
    local bs = bar and bar:GetEffectiveScale() or ms
    local hhPx = HeaderHeight() * bs
    local aw, ah, anchor = Area()
    local side = math.floor(math.min(aw - 4, ah - hhPx - 3) / ms)
    if side > 20 then
        local offY = -(hhPx / ms)
        local mp, mrel, mrp, mx, my = Minimap:GetPoint(1)
        if Minimap:GetNumPoints() ~= 1 or mp ~= "TOP" or mrel ~= anchor
            or math.abs((my or 0) - offY) > 0.5
            or math.abs(Minimap:GetWidth() - side) > 0.5 or math.abs(Minimap:GetHeight() - side) > 0.5 then
            Minimap:ClearAllPoints()
            Minimap:SetPoint("TOP", anchor, "TOP", 0, offY)
            Minimap:SetSize(side, side)
        end
    end
    LayoutHeader()
end

-- aree di missioni/ricerca: resta solo l'alone del bordo, l'interno (retino/riempimento) e' trasparente
local BLANK = "Interface\\AddOns\\TavesMap\\blank.tga"
local blobBusy, blobHooked = false, false
local function ApplyBlobs()
    blobBusy = true
    for _, kind in ipairs({ "Quest", "Arch", "Task" }) do
        -- niente texture trasparente: veniva disegnata come riempimento verde. Solo opacita' a zero
        local fn = Minimap["Set" .. kind .. "BlobInsideAlpha"]
        if fn then pcall(fn, Minimap, 0) end
        fn = Minimap["Set" .. kind .. "BlobRingAlpha"]
        if fn then pcall(fn, Minimap, 0) end
        fn = Minimap["Set" .. kind .. "BlobRingScalar"]
        if fn then pcall(fn, Minimap, 0) end
    end
    blobBusy = false
    -- quando Blizzard le rimette (es. selezionando una missione) le correggo subito
    if not blobHooked then
        blobHooked = true
        for _, kind in ipairs({ "Quest", "Arch", "Task" }) do
            for _, part in ipairs({ "Alpha" }) do
                local name = "Set" .. kind .. "BlobInside" .. part
                if Minimap[name] then
                    hooksecurefunc(Minimap, name, function()
                        if not blobBusy then ApplyBlobs() end
                    end)
                end
            end
            local rname = "Set" .. kind .. "BlobRingAlpha"
            if Minimap[rname] then
                hooksecurefunc(Minimap, rname, function()
                    if not blobBusy then ApplyBlobs() end
                end)
            end
        end
        local evf = CreateFrame("Frame")
        for _, e in ipairs({ "SUPER_TRACKING_CHANGED", "QUEST_POI_UPDATE", "QUEST_LOG_UPDATE", "QUEST_WATCH_UPDATE" }) do
            pcall(evf.RegisterEvent, evf, e)
        end
        evf:SetScript("OnEvent", function() ApplyBlobs() C_Timer.After(0.2, ApplyBlobs) end)
    end
end

local acc, slowAcc = 0, 0
infoFrame:SetScript("OnUpdate", function(_, elapsed)
    acc = acc + elapsed
    slowAcc = slowAcc + elapsed
    if acc >= 0.25 then
        acc = 0
        UpdateInfo()
    end
    if slowAcc >= 1 then
        slowAcc = 0
        Layout()
        if db then ApplyBlobs() end
        if db and db.compact then
            PlaceMenuButton()
            PlaceClock()
            CollectAddonButtons()
        end
    end
end)

---------------------------------------------------------------------
-- Applicazione impostazioni
---------------------------------------------------------------------
local function HideBlizzBorder()
    for _, name in ipairs(BLIZZ_BORDER) do
        local r = _G[name]
        if r then
            if not hookedRegions[r] then
                hookedRegions[r] = true
                hooksecurefunc(r, "Show", function(self) self:Hide() end)
            end
            r:Hide()
        end
    end
    HideTextures(_G.MinimapBackdrop)
    HideTextures(MinimapCluster)
    -- barra superiore dell'header: la nascondo solo come texture decorativa
    if MinimapCluster.BorderTop and MinimapCluster.BorderTop.Hide then
        MinimapCluster.BorderTop:Hide()
    end
end

local function ApplyShape()
    Minimap:SetMaskTexture(MASK_SQUARE)
    GetMinimapShape = function() return "SQUARE" end
    ringSquare:Show()
    HideBlizzBorder()
    ApplyBlobs()
end

local function Apply()
    if not db then return end
    FixRingLevel()
    ApplyShape()
    ApplyCompact()
    Layout()
    Minimap:EnableMouseWheel(db.wheelZoom)
    UpdateInfo()
end

Minimap:SetScript("OnMouseWheel", function(self, delta)
    if not db or not db.wheelZoom then return end
    local z = self:GetZoom()
    local max = self:GetZoomLevels() - 1
    if delta > 0 then
        self:SetZoom(math.min(max, z + 1))
    else
        self:SetZoom(math.max(0, z - 1))
    end
end)

---------------------------------------------------------------------
-- Clic sulla minimappa: sinistro = niente, destro = menu (Ping per primo)
---------------------------------------------------------------------
local cursorAnchor = CreateFrame("Frame", nil, UIParent)
cursorAnchor:SetSize(1, 1)

-- il menu del tasto destro ha solo il Ping: il resto e' nell'ingranaggio
local function MinimapMenuItems(pingX, pingY)
    return {
        {
            text = "Ping", icon = "Interface\\Icons\\Ability_Hunter_MarkedForDeath",
            func = function() Minimap:PingLocation(pingX, pingY) end,
        },
    }
end

Minimap:SetScript("OnMouseUp", function(self, button)
    -- il tasto sinistro non fa niente (niente ping, niente menu)
    if button ~= "RightButton" then return end
    -- posizione del clic rispetto al centro della minimappa: il ping parte da li'
    local cx, cy = GetCursorPosition()
    local s = self:GetEffectiveScale()
    local mx, my = self:GetCenter()
    local ox, oy = cx / s - mx, cy / s - my
    -- il menu si apre sotto il cursore
    local us = UIParent:GetEffectiveScale()
    cursorAnchor:ClearAllPoints()
    cursorAnchor:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", cx / us, cy / us)
    ShowMenu(1, cursorAnchor, MinimapMenuItems(ox, oy))
end)

---------------------------------------------------------------------
-- Finestra opzioni
---------------------------------------------------------------------
local opt

local function ResetAll()
    TavesMapDB = {}
    for k, v in pairs(DEFAULTS) do TavesMapDB[k] = v end
    db = TavesMapDB
    Apply()
    if opt and opt:IsShown() then opt.Refresh() end
end

local function BuildOptions()
    opt = CreateFrame("Frame", "TavesMapOptions", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    opt:SetSize(320, 170)
    opt:SetPoint("CENTER")
    opt:SetFrameStrata("DIALOG")
    opt:SetMovable(true)
    opt:EnableMouse(true)
    opt:SetClampedToScreen(true)
    opt:RegisterForDrag("LeftButton")
    opt:SetScript("OnDragStart", opt.StartMoving)
    opt:SetScript("OnDragStop", opt.StopMovingOrSizing)
    if opt.SetBackdrop then
        opt:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 32,
            insets = { left = 11, right = 12, top = 12, bottom = 11 },
        })
    end
    opt:Hide()
    tinsert(UISpecialFrames, "TavesMapOptions")

    local title = opt:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -16)
    title:SetText("TavesMap")

    local close = CreateFrame("Button", nil, opt, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -6, -6)

    local y = -48

    local hint = opt:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", 24, y)
    hint:SetWidth(270)
    hint:SetJustifyH("LEFT")
    hint:SetText("Posizione e dimensione del blocco minimappa si cambiano dalla Modalita' Modifica di WoW: la mappa riempie l'area gialla.")

    local reset = CreateFrame("Button", nil, opt, "UIPanelButtonTemplate")
    reset:SetSize(150, 24)
    reset:SetPoint("BOTTOM", 0, 20)
    reset:SetText("Ripristina tutto")
    reset:SetScript("OnClick", ResetAll)

    function opt.Refresh()
    end
    opt:SetScript("OnShow", opt.Refresh)
end

local function ToggleOptions()
    if not db then return end
    if not opt then BuildOptions() end
    if opt:IsShown() then opt:Hide() else opt:Show() end
end
TavesMap_ToggleOptions = ToggleOptions

if TavesMenu then
    TavesMenu.Register("map", "TavesMap", "Interface\\Icons\\INV_Misc_Map_01", ToggleOptions)
end

---------------------------------------------------------------------
-- Init e comandi
---------------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("ZONE_CHANGED_NEW_AREA")
ev:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        TavesMapDB = TavesMapDB or {}
        db = TavesMapDB
        for k, v in pairs(DEFAULTS) do
            if db[k] == nil then db[k] = v end
        end
        -- opzioni delle versioni precedenti
        db.pos, db.locked = nil, nil
        db.hideZoom, db.hideCalendar, db.hideWorldMap = nil, nil, nil
        db.shape = nil -- ora solo quadrata
        db.coords = nil -- coordinate rimosse
        db.scale = nil  -- dimensione: ora la decide la Modalita' Modifica
        db.__hide = nil
        -- queste tre non sono piu' nelle opzioni: sempre attive
        db.compact, db.clock, db.wheelZoom = true, true, true
    end
    Apply()
end)

SLASH_TAVESMAP1 = "/tmap"
SlashCmdList["TAVESMAP"] = function(msg)
    msg = (msg or ""):lower():match("^%s*(.-)%s*$")
    if msg == "debug" then
        -- elementi di MinimapCluster per chiave (calendario, orologio, header...)
        print("|cffffd100TavesMap debug:|r chiavi di MinimapCluster")
        for k, v in pairs(MinimapCluster) do
            if type(v) == "table" and type(v.IsShown) == "function" then
                print(string.format("  .%s shown=%s", tostring(k), tostring(v:IsShown())))
            end
        end
        for _, name in ipairs({ "MinimapBackdrop", "MinimapCluster", "Minimap" }) do
            local fr = _G[name]
            if fr then
                print("|cffffd100TavesMap debug:|r " .. name)
                for _, r in ipairs({ fr:GetRegions() }) do
                    print(string.format("  region %s [%s] shown=%s", tostring(r:GetName()),
                        r:GetObjectType(), tostring(r:IsShown())))
                end
                for _, c in ipairs({ fr:GetChildren() }) do
                    print(string.format("  frame  %s shown=%s", tostring(c:GetName()), tostring(c:IsShown())))
                end
            end
        end
    elseif msg:match("^blob") then
        -- prova: /tmap blob inside|outside|ring  azzera quella parte per tutte le blob; /tmap blob on = valori di Blizzard
        local part = msg:match("^blob%s+(%a+)")
        if part == "notex" then
            -- prova: sostituisce le texture delle blob (il retino/anello) con una trasparente
            local n = 0
            for _, kind in ipairs({ "Quest", "Arch", "Task" }) do
                for _, tp in ipairs({ "Inside", "Outside", "Ring" }) do
                    local fn = Minimap["Set" .. kind .. "Blob" .. tp .. "Texture"]
                    if fn then
                        n = n + 1
                        pcall(fn, Minimap, "Interface\\AddOns\\TavesMap\\blank.tga")
                    end
                end
            end
            print("|cffffd100TavesMap blob:|r texture sostituite: " .. n .. " (l'effetto sparisce al /reload)")
            return
        end
        local names = { inside = "Inside", outside = "Outside", ring = "Ring" }
        for _, kind in ipairs({ "Quest", "Arch", "Task" }) do
            for p, n in pairs(names) do
                local fn = Minimap["Set" .. kind .. "Blob" .. n .. "Alpha"]
                if fn then
                    local v = (part == "on") and (p == "inside" and 0.25 or p == "outside" and 0.6 or 1) or (part == p and 0 or nil)
                    if v ~= nil then pcall(fn, Minimap, v) end
                end
            end
        end
        print("|cffffd100TavesMap blob:|r " .. tostring(part) .. " (l'effetto sparisce al /reload)")
    elseif msg == "glow" or msg == "api" then
        -- elenca le texture visibili dentro la minimappa (per trovare il cerchio bianco sfumato)
        local seen, lines = {}, {}
        local function Scan(f, depth)
            if seen[f] or depth > 4 then return end
            seen[f] = true
            for _, r in ipairs({ f:GetRegions() }) do
                if r.GetObjectType and r:GetObjectType() == "Texture" and r:IsShown() and r:GetAlpha() > 0 then
                    local w, h = r:GetSize()
                    lines[#lines + 1] = string.format("%s > %s  tex=%s  %.0fx%.0f", tostring(f:GetName() or "?"),
                        tostring(r:GetName() or "-"), tostring(r:GetTexture()), w or 0, h or 0)
                end
            end
            for _, c in ipairs({ f:GetChildren() }) do Scan(c, depth + 1) end
        end
        if msg == "api" then
            -- tutte le funzioni della minimappa legate a blob, POI, frecce, texture
            local mt = getmetatable(Minimap)
            local idx = mt and mt.__index
            local names = {}
            if type(idx) == "table" then
                for k in pairs(idx) do
                    if type(k) == "string" and k:find("Blob") or (type(k) == "string" and (k:find("POI") or k:find("Arrow") or k:find("Texture") or k:find("Alpha") or k:find("Ring"))) then
                        names[#names + 1] = k
                    end
                end
            end
            table.sort(names)
            lines = names
            if #lines == 0 then lines[1] = "nessuna funzione trovata" end
        else
            Scan(Minimap, 0)
        end
        local fns = {}
        for _, k in ipairs({ "Quest", "Arch", "Task" }) do
            fns[#fns + 1] = k .. "BlobInsideAlpha=" .. tostring(Minimap["Set" .. k .. "BlobInsideAlpha"] ~= nil)
        end
        table.insert(lines, 1, table.concat(fns, " "))
        -- finestra con testo selezionabile: Ctrl+A, Ctrl+C e poi incolla qui
        local w = _G.TavesMapGlowBox
        if not w then
            w = CreateFrame("Frame", "TavesMapGlowBox", UIParent, "BackdropTemplate")
            w:SetSize(520, 260); w:SetPoint("CENTER"); w:SetFrameStrata("FULLSCREEN_DIALOG")
            w:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
            w:SetBackdropColor(0, 0, 0, 0.95); w:SetBackdropBorderColor(0.85, 0.68, 0.18, 1)
            local eb = CreateFrame("EditBox", nil, w)
            eb:SetMultiLine(true); eb:SetFontObject(ChatFontNormal); eb:SetWidth(496); eb:SetAutoFocus(false)
            local sf = CreateFrame("ScrollFrame", nil, w, "UIPanelScrollFrameTemplate")
            sf:SetPoint("TOPLEFT", 8, -8); sf:SetPoint("BOTTOMRIGHT", -28, 8)
            sf:SetScrollChild(eb)
            eb:SetScript("OnEscapePressed", function() w:Hide() end)
            w.eb = eb
        end
        w.eb:SetText(table.concat(lines, "\n"))
        w:Show(); w.eb:SetFocus(); w.eb:HighlightText()
        print("|cffffd100TavesMap glow:|r finestra aperta: Ctrl+C per copiare, poi incolla qui (Esc chiude).")
    elseif msg == "zoom" then
        local levels = Minimap:GetZoomLevels()
        print(string.format("|cffffd100TavesMap zoom:|r livello attuale %d, livelli totali %d (da 0 a %d), al chiuso: %s, cvar esterno=%s interno=%s",
            Minimap:GetZoom(), levels, levels - 1, tostring(IsIndoors and IsIndoors() or false),
            tostring(GetCVar("minimapZoom")), tostring(GetCVar("minimapInsideZoom"))))
    elseif msg == "size" then
        local aw, ah, anchor = Area()
        local sel = MinimapCluster.Selection
        local cw, ch = RectPx(MinimapCluster)
        local sw, sh = 0, 0
        if sel and sel.GetRect then sw, sh = RectPx(sel) end
        local mw, mh = RectPx(Minimap)
        print(string.format("|cffffd100TavesMap (pixel):|r cluster %.0fx%.0f | selection %.0fx%.0f | area %.0fx%.0f | minimappa %.0fx%.0f | scale cluster %.2f minimappa %.2f",
            cw, ch, sw, sh, aw, ah, mw, mh,
            MinimapCluster:GetEffectiveScale(), Minimap:GetEffectiveScale()))
    elseif msg == "who" then
        -- passa il mouse sopra un elemento e scrivi /tmap who: ne stampa il nome
        local f = (GetMouseFoci and GetMouseFoci()[1]) or (GetMouseFocus and GetMouseFocus())
        if not f then print("|cffffd100TavesMap:|r nessun elemento sotto il mouse.") return end
        local depth = 0
        while f and depth < 5 do
            local key
            local par = f.GetParent and f:GetParent()
            if par then
                for k, v in pairs(par) do
                    if v == f and type(k) == "string" then key = k break end
                end
            end
            print(string.format("|cffffd100TavesMap who:|r %s  nome=%s  chiave=%s",
                f.GetObjectType and f:GetObjectType() or "?", tostring(f.GetName and f:GetName()), tostring(key)))
            f = par
            depth = depth + 1
        end
    elseif msg == "reset" and db then
        ResetAll()
        print("|cffffd100TavesMap:|r impostazioni ripristinate.")
    else
        ToggleOptions()
    end
end
