-- TavesBar: box spostabili con un elenco di barre a scelta.
--   * Box principale: Vita, Mana (attive di default), Rabbia, Energia con livello combo
--   * Box debuff (agganciato sotto al principale): una barra per ogni debuff scelto,
--     sul bersaglio e lanciato da te.
-- Per spostare un box: tieni premuto SHIFT e trascina con il tasto sinistro.
-- Opzioni: /tbar  (oppure dal menu TavesMenu)
--
-- NB: in Midnight/Forever le aure sono "secret" per gli addon: il Lua non puo' leggerle.
-- Le barre debuff usano quindi i widget nativi del client (AuraContainer, come
-- NeedToKnow): l'addon li crea e li stila, e' il gioco a riempirli (barra, secondi, icona).
-- Servono gli ID dell'aura: nome (risolto dal gioco), ID numerico, o appresi fuori combattimento.

local DEFAULTS = {
    ver = 4,
    locked = false,
    width = 220,
    height = 18,
    bars = { health = true, mana = true, rage = false, energy = false },
    debuffs = {},  -- { { name=, spellId=, ids={}, enabled=, color=, flat= }, ... }
    colors = {},   -- colori personalizzati per barra (vuoto = predefiniti)
    flat = {},     -- barre senza sfumatura (vuoto = tutte con sfumatura)
}
local SPACING = 0
local MAX_DEBUFFS = 6
local TEXTURE = "Interface\\TargetingFrame\\UI-StatusBar"   -- con sfumatura (effetto 3D)
local FLAT_TEXTURE = "Interface\\Buttons\\WHITE8X8"          -- colore piatto
local AURA_FILTER = "HARMFUL|PLAYER"

local FIXED = {
    { key = "health", label = "Vita" },
    { key = "mana",   label = "Mana" },
    { key = "rage",   label = "Rabbia" },
    { key = "energy", label = "Energia" },
}
local POWER = { mana = 0, rage = 1, energy = 3 }
local ALWAYS = { health = true, mana = true }
local COLORS = {
    health = { 0.20, 0.80, 0.20 },
    mana   = { 0.10, 0.35, 1.00 },
    rage   = { 0.90, 0.15, 0.15 },
    energy = { 1.00, 0.85, 0.10 },
    debuff = { 0.65, 0.25, 0.90 },
}

local db
local specs = {}
local fixedPool, debuffPool = {}, {}
local pendingApply = false

---------------------------------------------------------------------
-- Utilita'
---------------------------------------------------------------------
local function IsSecret(v)
    return issecretvalue and issecretvalue(v) or false
end

local function Num(v)
    if IsSecret(v) or type(v) ~= "number" then return nil end
    return v
end

local function InCombat()
    return InCombatLockdown and InCombatLockdown() or false
end

local function Short(n)
    if n >= 1000000 then return string.format("%.1fM", n / 1000000) end
    if n >= 10000 then return string.format("%.1fk", n / 1000) end
    return tostring(math.floor(n))
end

local function ValueText(v)
    local n = Num(v)
    if n then return Short(n) end
    if AbbreviateLargeNumbers then
        local ok, s = pcall(AbbreviateLargeNumbers, v)
        if ok then return s end
    end
    return ""
end

local function HasPower(kind)
    local t = POWER[kind]
    if UnitHasPowerType then
        local ok, r = pcall(UnitHasPowerType, "player", t)
        if ok and r ~= nil then return r end
    end
    local n = Num(UnitPowerMax("player", t))
    return n == nil or n > 0
end

local function GetCombo()
    if GetComboPoints then
        local ok, c = pcall(GetComboPoints, "player", "target")
        if ok and c then return c end
    end
    return UnitPower("player", 4)
end

local lastErr
local function Report(where, err)
    local msg = where .. ": " .. tostring(err)
    if msg ~= lastErr then
        lastErr = msg
        print("|cffffd100TavesBar:|r errore " .. msg)
    end
end

-- Libro degli incantesimi: nome minuscolo -> { [id]=true } (come fa NeedToKnow, con i ranghi)
local bookIDs
local function BookIDs(name)
    if not bookIDs then
        bookIDs = {}
        local function put(n, ...)
            if type(n) ~= "string" then return end
            local k = n:lower()
            bookIDs[k] = bookIDs[k] or {}
            for i = 1, select("#", ...) do
                local id = select(i, ...)
                if type(id) == "number" then bookIDs[k][id] = true end
            end
        end
        local book = C_SpellBook
        if book and book.GetNumSpellBookSkillLines and book.GetSpellBookSkillLineInfo
            and book.GetSpellBookItemInfo then
            local bank = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player or 0
            local ok, lines = pcall(book.GetNumSpellBookSkillLines)
            if ok and type(lines) == "number" then
                for line = 1, lines do
                    local lok, info = pcall(book.GetSpellBookSkillLineInfo, line)
                    if lok and type(info) == "table" and type(info.itemIndexOffset) == "number"
                        and type(info.numSpellBookItems) == "number" then
                        for slot = info.itemIndexOffset + 1, info.itemIndexOffset + info.numSpellBookItems do
                            local iok, item = pcall(book.GetSpellBookItemInfo, slot, bank)
                            if iok and type(item) == "table" then
                                put(item.name, item.actionID, item.spellID)
                            end
                        end
                    end
                end
            end
        elseif GetNumSpellTabs and GetSpellTabInfo and GetSpellBookItemName and GetSpellBookItemInfo then
            local ok, tabs = pcall(GetNumSpellTabs)
            if ok and type(tabs) == "number" then
                for tab = 1, tabs do
                    local tok, _, _, offset, num = pcall(GetSpellTabInfo, tab)
                    if tok and type(offset) == "number" and type(num) == "number" then
                        for slot = offset + 1, offset + num do
                            local nok, n = pcall(GetSpellBookItemName, slot, BOOKTYPE_SPELL or "spell")
                            local iok, t, id = pcall(GetSpellBookItemInfo, slot, BOOKTYPE_SPELL or "spell")
                            if nok and iok and t == "SPELL" then put(n, id) end
                        end
                    end
                end
            end
        end
    end
    return type(name) == "string" and bookIDs[name:lower()] or nil
end

-- unita' e filtro in base al tipo: debuff sul bersaglio, buff su di me
-- (come nel menu di NeedToKnow: Tipo = Buff/Debuff, Unita', "solo miei")
local UNIT_LABEL = { player = "Me", target = "Bers.", focus = "Focus", pet = "Pet" }
local function AuraUnit(d)
    return d.unit or (d.kind == "buff" and "player" or "target")
end
local function AuraParams(d)
    local suffix = d.any and "" or "|PLAYER"   -- d.any: anche gli effetti di altri / dell'ambiente
    return AuraUnit(d), (d.kind == "buff" and "HELPFUL" or "HARMFUL") .. suffix
end
local function RowSummary(d)
    return (d.kind == "buff" and "Buff" or "Debuff") .. " · " ..
        (UNIT_LABEL[AuraUnit(d)] or "?") .. (d.any and "*" or "")
end

-- ID candidati: ID dell'abilita' trascinata, ID scritti/appresi, libro incantesimi, ID dal nome
local function CandidateIDs(d)
    local ids, list = {}, {}
    local function add(id)
        if type(id) == "number" and id > 0 and not ids[id] then
            ids[id] = true
            list[#list + 1] = id
        end
    end
    add(d.spellId)
    for _, id in ipairs(d.ids or {}) do add(id) end
    for id in pairs(BookIDs(d.name) or {}) do add(id) end
    if C_Spell and C_Spell.GetSpellIDForSpellIdentifier then
        local ok, id = pcall(C_Spell.GetSpellIDForSpellIdentifier, d.name)
        if ok and not IsSecret(id) then add(id) end
    end
    if C_Spell and C_Spell.GetSpellInfo then
        local ok, info = pcall(C_Spell.GetSpellInfo, d.name)
        if ok and type(info) == "table" and not IsSecret(info.spellID) then add(info.spellID) end
    end
    table.sort(list)
    return ids, table.concat(list, ",")
end

---------------------------------------------------------------------
-- Box contenitori (SHIFT + trascina per spostare)
---------------------------------------------------------------------
local function MakeContainer(name, kx, ky, offX, offY, attachTo)
    local c = CreateFrame("Frame", name, UIParent)
    c:SetSize(220, 20)
    c:SetMovable(true)
    c:SetClampedToScreen(true)
    c:SetFrameStrata("MEDIUM")
    c:RegisterForDrag("LeftButton")
    function c.Place()
        c:ClearAllPoints()
        -- posizione salvata fuori dallo schermo (es. risoluzione cambiata): la scarto
        if db and db[kx] then
            local w, h = UIParent:GetWidth(), UIParent:GetHeight()
            if db[kx] < -50 or db[kx] > w - 30 or db[ky] > 0 or db[ky] < -(h - 30) then
                db[kx], db[ky] = nil, nil
            end
        end
        if db and db[kx] then
            c:SetPoint("TOPLEFT", UIParent, "TOPLEFT", db[kx], db[ky])
        elseif attachTo then
            c:SetPoint("TOPLEFT", attachTo, "BOTTOMLEFT", 0, 0)   -- agganciato sotto
        else
            c:SetPoint("TOPLEFT", UIParent, "CENTER", offX, offY)
        end
    end
    c:SetScript("OnDragStart", function(self)
        if db and not db.locked and IsShiftKeyDown() then self:StartMoving() end
    end)
    c:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        if not db then return end
        db[kx] = self:GetLeft()
        db[ky] = self:GetTop() - UIParent:GetTop()
        c.Place()
    end)
    return c
end

local container = MakeContainer("TavesBarFrame", "x", "y", -110, -120)
local debuffContainer = MakeContainer("TavesBarDebuffFrame", "dx", "dy", -110, -250, container)
-- contatore combo: elemento a parte, spostabile con SHIFT + trascina
local comboFrame = MakeContainer("TavesBarComboFrame", "cx", "cy", 130, -120)
comboFrame:SetSize(44, 44)
comboFrame.bg = comboFrame:CreateTexture(nil, "BACKGROUND")
comboFrame.bg:SetAllPoints()
comboFrame.bg:SetColorTexture(0, 0, 0, 0.5)
comboFrame.bg:Hide()
comboFrame.text = comboFrame:CreateFontString(nil, "OVERLAY")
comboFrame.text:SetFont(STANDARD_TEXT_FONT, 32, "OUTLINE")
comboFrame.text:SetTextColor(1, 1, 1)
comboFrame.text:SetPoint("CENTER", 0, 0)
local containers = { container, debuffContainer, comboFrame }

local function PlaceContainer()
    for _, c in ipairs(containers) do c.Place() end
end

-- i box catturano il mouse solo mentre SHIFT e' premuto: altrimenti i clic passano al gioco
local function UpdateMouse()
    local on = db ~= nil and not db.locked and IsShiftKeyDown()
    for _, c in ipairs(containers) do c:EnableMouse(on) end
    comboFrame.bg:SetShown(on)   -- con SHIFT premuto si vede il riquadro da afferrare
    if on and comboFrame.text:GetText() == "" then comboFrame.text:SetText("0") end
end

---------------------------------------------------------------------
-- Barra normale (vita, mana, ...)
---------------------------------------------------------------------
local function CreateBar()
    local b = CreateFrame("Frame", nil, container)
    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetAllPoints()
    b.bg:SetColorTexture(0, 0, 0, 0.85)

    b.sb = CreateFrame("StatusBar", nil, b)
    b.sb:SetStatusBarTexture(TEXTURE)
    b.sb:SetMinMaxValues(0, 1)

    b.ov = CreateFrame("Frame", nil, b.sb)
    b.ov:SetAllPoints()
    b.ov:SetFrameLevel(b.sb:GetFrameLevel() + 2)

    b.right = b.ov:CreateFontString(nil, "OVERLAY")
    b.right:SetPoint("CENTER", 0, 0)   -- i valori numerici stanno al centro
    b.right:SetJustifyH("CENTER")
    b.center = b.ov:CreateFontString(nil, "OVERLAY")  -- livello combo: a sinistra
    b.center:SetPoint("LEFT", 6, 0)
    b.center:SetJustifyH("LEFT")
    return b
end

local function ConfigureBar(b, spec)
    b:SetParent(spec.cont)
    local h = db.height
    b:SetSize(db.width, h)
    local small = math.max(9, math.min(14, h - 6))
    b.right:SetFont(STANDARD_TEXT_FONT, small, "OUTLINE")
    b.center:SetFont(STANDARD_TEXT_FONT, math.max(11, h - 2), "OUTLINE")
    b.center:SetTextColor(1, 1, 1)   -- numeri sempre bianchi con contorno nero
    b.right:SetTextColor(1, 1, 1)

    b.sb:ClearAllPoints()
    b.sb:SetPoint("TOPLEFT", 1, -1)
    b.sb:SetPoint("BOTTOMRIGHT", -1, 1)

    b.sb:SetStatusBarTexture(spec.flat and FLAT_TEXTURE or TEXTURE)
    local c = spec.color or COLORS[spec.kind]
    b.sb:SetStatusBarColor(c[1], c[2], c[3])
    b.spec = spec
end

---------------------------------------------------------------------
-- Barra debuff: widget nativi del client (AuraContainer)
---------------------------------------------------------------------
local function CreateDebuffBar()
    local f = CreateFrame("Frame", nil, debuffContainer)
    return f
end

local function MakeCountFormatter()
    if not C_StringUtil or not C_StringUtil.CreateNumericRuleFormatter then return nil end
    local ok, formatter = pcall(C_StringUtil.CreateNumericRuleFormatter)
    if not ok or not formatter or not formatter.SetBreakpoints then return nil end
    local success = pcall(formatter.SetBreakpoints, formatter, {
        { threshold = 0, format = "" },
        { threshold = 2, format = "%d", step = 1 },
    })
    return success and formatter or nil
end

-- Tutto va creato qui dentro: il client applica le restrizioni DOPO questa funzione.
local function InitDebuffButton(container_, button, spec)
    local h = db.height
    local small = math.max(9, math.min(14, h - 6))
    local function Font(fs)
        pcall(fs.SetFont, fs, STANDARD_TEXT_FONT, small, "OUTLINE")
        fs:SetTextColor(1, 1, 1, 1)
    end

    button:SetAllPoints(container_)
    if button.EnableMouse then pcall(button.EnableMouse, button, false) end

    -- lo sfondo e' dentro il bottone: compare solo quando il debuff e' presente
    local bg = button:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(button)
    bg:SetTexture("Interface\\Buttons\\WHITE8x8")
    bg:SetVertexColor(0, 0, 0, 0.85)

    local fill = CreateFrame("StatusBar", nil, button)
    fill:SetPoint("TOPLEFT", button, "TOPLEFT", 1, -1)
    fill:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -1, 1)
    fill:SetStatusBarTexture(spec.flat and FLAT_TEXTURE or TEXTURE)
    local c = spec.color or COLORS.debuff
    fill:SetStatusBarColor(c[1], c[2], c[3], 1)
    local direction = Enum and Enum.StatusBarTimerDirection and
        Enum.StatusBarTimerDirection.RemainingTime or 1
    button:SetDurationBar(fill, { direction = direction })

    local layer = CreateFrame("Frame", nil, button)
    layer:SetAllPoints(button)
    layer:SetFrameLevel(fill:GetFrameLevel() + 1)

    -- icona dentro la barra, a sinistra
    local iconFrame = CreateFrame("Frame", nil, layer)
    iconFrame:SetSize(h - 4, h - 4)
    iconFrame:SetPoint("LEFT", button, "LEFT", 3, 0)
    local icon = iconFrame:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints(iconFrame)
    button:SetIcon(icon)
    pcall(icon.SetTexCoord, icon, 0.08, 0.92, 0.08, 0.92)

    -- secondi al centro
    local time = layer:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    time:SetPoint("CENTER", button, "CENTER", 0, 0)
    time:SetJustifyH("CENTER")
    Font(time)
    button:SetDurationText(time)

    -- nome dell'aura, dopo l'icona
    local label = layer:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("LEFT", iconFrame, "RIGHT", 4, 0)
    label:SetPoint("RIGHT", time, "LEFT", -4, 0)
    label:SetJustifyH("LEFT")
    if label.SetMaxLines then label:SetMaxLines(1) elseif label.SetWordWrap then label:SetWordWrap(false) end
    Font(label)
    button:SetSpellName(label)

    -- eventuali cariche, a destra
    local count = layer:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    count:SetPoint("RIGHT", button, "RIGHT", -4, 0)
    count:SetJustifyH("RIGHT")
    Font(count)
    local formatter = MakeCountFormatter()
    button:SetApplicationCount(count, formatter and { formatter = formatter } or nil)
end

local function BuildDebuffContainer(f, spec, ids)
    local ok, c = pcall(CreateFrame, "AuraContainer", nil, f, "CustomAuraContainerTemplate")
    if not ok or not c or type(c.AddAuraSlot) ~= "function" or
        type(c.SetUnit) ~= "function" or type(c.SetEnabled) ~= "function" then
        return nil, ok and "API AuraContainer non disponibile" or c
    end
    c:SetAllPoints(f)
    c:SetFrameLevel(f:GetFrameLevel() + 1)
    local initialized, initErr
    local created, err = pcall(function()
        local unit, filter = AuraParams(spec.d)
        c:SetUnit(unit)
        c:AddAuraSlot("tracked", filter, {
            candidateFilters = { includeSpellIDs = ids },
            initializeFrame = function(newButton)
                initialized, initErr = pcall(InitDebuffButton, c, newButton, spec)
            end,
        })
        if not initialized then error(initErr or "inizializzazione del bottone non eseguita") end
    end)
    if not created then
        c:Hide()
        return nil, err
    end
    return c
end

local function ConfigureDebuffBar(f, spec)
    f:SetParent(spec.cont)
    f:SetSize(db.width, db.height)
    f.spec = spec

    local ids, idKey = CandidateIDs(spec.d)
    spec.idKey = idKey
    local c = spec.color or COLORS.debuff
    local styleKey = table.concat({
        db.width, db.height, spec.flat and "f" or "g", spec.d.kind or "debuff", spec.d.any and "any" or "mine",
        string.format("%.3f,%.3f,%.3f", c[1], c[2], c[3]),
    }, "|")

    if idKey == "" then   -- nessun ID noto: niente da mostrare
        if f.aura then f.aura:Hide() end
        f.idKey, f.styleKey = nil, nil
        return
    end
    if f.aura and f.styleKey == styleKey then
        if f.idKey ~= idKey then
            if InCombat() then
                pendingApply = true
            else
                local ok, err = pcall(f.aura.SetAuraSlotCandidateFilters, f.aura, "tracked",
                    { includeSpellIDs = ids })
                if ok then f.idKey = idKey else Report("filtro", err) end
            end
        end
        f.aura:Show()
        return
    end
    if InCombat() then   -- in combattimento non si ricostruisce: lo faccio all'uscita
        pendingApply = true
        return
    end
    local newC, err = BuildDebuffContainer(f, spec, ids)
    if not newC then
        Report("barra debuff", err)
        return
    end
    if f.aura then f.aura:Hide() end
    f.aura, f.idKey, f.styleKey = newC, idKey, styleKey
end

-- l'unita' e' compatibile col tipo? (come NeedToKnow: un debuff non puo' stare su un amico,
-- un buff non su un nemico, salvo membri del gruppo). In dubbio: compatibile.
local function UnitCompatible(d)
    local unit = AuraUnit(d)
    if unit == "player" or not UnitCanAssist then return true end
    local ok, canAssist = pcall(UnitCanAssist, "player", unit, true, true)
    if not ok or IsSecret(canAssist) or type(canAssist) ~= "boolean" then return true end
    if d.kind == "buff" then
        if canAssist then return true end
        if UnitIsPlayerControlledOrGroupMember then
            local gok, member = pcall(UnitIsPlayerControlledOrGroupMember, unit)
            if gok and not IsSecret(member) and member == true then return true end
        end
        return false
    end
    return not canAssist
end

local function RefreshAuras()
    for _, f in ipairs(debuffPool) do
        local spec = f.spec
        if f.aura and f.idKey and f:IsShown() and spec then
            if UnitCompatible(spec.d) then
                local ok, err = pcall(function()
                    f.aura:Show()
                    f.aura:UpdateAllAuras()
                end)
                if not ok then Report("aggiornamento aure", err) end
            else
                pcall(f.aura.Hide, f.aura)
            end
        end
    end
end

---------------------------------------------------------------------
-- Apprendimento degli ID (solo fuori combattimento, tre passaggi come NeedToKnow)
---------------------------------------------------------------------
local Apply

local function Pub(t, key)
    local ok, v = pcall(function() return t[key] end)
    if ok and not IsSecret(v) then return v end
end

-- legge i valori classici di UnitAura/UnitBuff/UnitDebuff: nome e spell ID
local function ClassicIdentity(v1, v2, v3, v4, v5, v6, v7, v8, v9, v10, v11)
    if not v1 or IsSecret(v1) then return nil end
    local id
    if type(v5) == "number" then
        id = (type(v10) == "number" and v10) or (type(v11) == "number" and v11) or nil
    else
        id = (type(v11) == "number" and v11) or (type(v10) == "number" and v10) or nil
    end
    return v1, id
end

-- registra l'ID se l'aura corrisponde alla riga; ritorna true se e' un ID nuovo
local function Remember(d, ids, name, id)
    if type(id) ~= "number" or id <= 0 or IsSecret(id) then return false end
    local match = ids[id]
    if not match and type(name) == "string" and not IsSecret(name) then
        match = name:lower() == d.name:lower()
    end
    if not match then return false end
    d.ids = d.ids or {}
    for _, x in ipairs(d.ids) do
        if x == id then return false end
    end
    d.ids[#d.ids + 1] = id
    return true
end

local function LearnOne(d)
    local unit, filter = AuraParams(d)
    if not UnitExists(unit) then return false end
    local ids = CandidateIDs(d)
    local api = C_UnitAuras
    -- 1) per nome
    if api and api.GetAuraDataBySpellName then
        local ok, aura = pcall(api.GetAuraDataBySpellName, unit, d.name, filter)
        if ok and type(aura) == "table"
            and Remember(d, ids, Pub(aura, "name"), Pub(aura, "spellId")) then return true end
    end
    -- 2) scansione per indice
    if api and api.GetAuraDataByIndex then
        for i = 1, 80 do
            local ok, aura = pcall(api.GetAuraDataByIndex, unit, i, filter)
            if not ok or type(aura) ~= "table" then break end
            if Remember(d, ids, Pub(aura, "name"), Pub(aura, "spellId")) then return true end
        end
    end
    -- 3) UnitAura classico, poi UnitBuff/UnitDebuff
    if _G.UnitAura then
        for i = 1, 80 do
            local ok, v1, v2, v3, v4, v5, v6, v7, v8, v9, v10, v11 = pcall(_G.UnitAura, unit, i, filter)
            if not ok or not v1 then break end
            local name, id = ClassicIdentity(v1, v2, v3, v4, v5, v6, v7, v8, v9, v10, v11)
            if Remember(d, ids, name, id) then return true end
        end
    end
    local legacy = (d.kind == "buff") and _G.UnitBuff or _G.UnitDebuff
    if legacy then
        for i = 1, 40 do
            local ok, v1, v2, v3, v4, v5, v6, v7, v8, v9, v10, v11 = pcall(legacy, unit, i)
            if not ok or not v1 then break end
            local name, id = ClassicIdentity(v1, v2, v3, v4, v5, v6, v7, v8, v9, v10, v11)
            if Remember(d, ids, name, id) then return true end
        end
    end
    return false
end

local lastLearn, learnPending = 0, false
local function LearnIDs()
    if not db or InCombat() then return end
    local now = GetTime()
    if now - lastLearn < 1 then
        -- evento arrivato troppo presto: ne programmo uno alla fine, cosi' non si perde
        if not learnPending and C_Timer and C_Timer.After then
            learnPending = true
            C_Timer.After(1.1, function()
                learnPending = false
                LearnIDs()
            end)
        end
        return
    end
    lastLearn = now
    local changed = false
    for _, d in ipairs(db.debuffs) do
        if d.enabled then
            local ok, learned = pcall(LearnOne, d)
            if ok and learned then changed = true end
        end
    end
    -- nuovi ID: ricostruisce i filtri nativi (SetAuraSlotCandidateFilters)
    if changed then Apply() end
end

---------------------------------------------------------------------
-- Layout e aggiornamento
---------------------------------------------------------------------
local lastSig

local function Layout()
    local ys = { [container] = 0, [debuffContainer] = 0 }
    for _, spec in ipairs(specs) do
        local b = spec.frame
        if b and spec.visible then
            local c = spec.cont
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", c, "TOPLEFT", 0, -ys[c])
            b:Show()
            ys[c] = ys[c] + db.height + SPACING
        elseif b then
            b:Hide()
        end
    end
    for _, c in ipairs(containers) do
        c:SetWidth(db.width)
        c:SetHeight(math.max(db.height, ys[c] - SPACING))
    end
end

local function UpdateOne(spec, b)
    local kind = spec.kind
    if kind == "health" then
        local cur, max = UnitHealth("player"), UnitHealthMax("player")
        spec.visible = true
        b.sb:SetMinMaxValues(0, max)
        b.sb:SetValue(cur)
        b.center:SetText("")
        b.right:SetText(ValueText(cur) .. " / " .. ValueText(max))
    elseif POWER[kind] then
        local t = POWER[kind]
        if ALWAYS[kind] then
            spec.visible = true
        else
            spec.visible = HasPower(kind)
            if not spec.visible then return end
        end
        local cur, max = UnitPower("player", t), UnitPowerMax("player", t)
        b.sb:SetMinMaxValues(0, max)
        b.sb:SetValue(cur)
        b.right:SetText(ValueText(cur))
        b.center:SetText("")
    end
end

local function UpdateCombo()
    local combo = GetCombo()
    local n = Num(combo)
    local txt = ""
    if n then
        txt = n > 0 and tostring(n) or ""
    elseif combo ~= nil then
        txt = combo
    end
    if txt == "" and not comboFrame:IsMouseEnabled() then
        comboFrame.text:SetText("")
    elseif txt ~= "" then
        comboFrame.text:SetText(txt)
    end
end

local function Refresh()
    local ok, err = pcall(UpdateCombo)
    if not ok then Report("combo", err) end
    local sig = {}
    for i, spec in ipairs(specs) do
        if spec.kind ~= "debuff" then
            local ok, err = pcall(UpdateOne, spec, spec.frame)
            if not ok then Report("aggiornamento", err) end
        else
            spec.visible = true
        end
        sig[i] = spec.visible and "1" or "0"
    end
    sig = table.concat(sig)
    if sig ~= lastSig then
        lastSig = sig
        Layout()
    end
end

local acc, accAura = 0, 0
local ticker = CreateFrame("Frame")
ticker:SetScript("OnUpdate", function(_, dt)
    acc = acc + dt
    accAura = accAura + dt
    if acc >= 0.05 then
        acc = 0
        if db then Refresh() end
    end
    if accAura >= 1 then   -- ripasso periodico delle aure (come NeedToKnow)
        accAura = 0
        if db then RefreshAuras() end
    end
end)

function Apply()
    if not db then return end
    pendingApply = false
    wipe(specs)
    for _, f in ipairs(fixedPool) do f:Hide() end
    for _, f in ipairs(debuffPool) do f:Hide() end
    local nFixed, nDebuff = 0, 0

    for _, f in ipairs(FIXED) do
        if db.bars[f.key] then
            specs[#specs + 1] = {
                kind = f.key, visible = true, cont = container,
                color = db.colors[f.key], flat = db.flat[f.key],
            }
        end
    end
    for _, d in ipairs(db.debuffs) do
        if d.enabled then
            specs[#specs + 1] = {
                kind = "debuff", d = d, name = d.name,
                visible = true, cont = debuffContainer,
                color = d.color, flat = d.flat,
            }
        end
    end
    for _, spec in ipairs(specs) do
        if spec.kind == "debuff" then
            nDebuff = nDebuff + 1
            debuffPool[nDebuff] = debuffPool[nDebuff] or CreateDebuffBar()
            spec.frame = debuffPool[nDebuff]
            local ok, err = pcall(ConfigureDebuffBar, spec.frame, spec)
            if not ok then Report("configurazione debuff", err) end
        else
            nFixed = nFixed + 1
            fixedPool[nFixed] = fixedPool[nFixed] or CreateBar()
            spec.frame = fixedPool[nFixed]
            ConfigureBar(spec.frame, spec)
        end
    end
    -- le barre debuff non usate nascondono anche il loro contenitore nativo
    for i = nDebuff + 1, #debuffPool do
        local f = debuffPool[i]
        if f.aura then f.aura:Hide() end
    end
    lastSig = nil
    UpdateMouse()
    Refresh()
    Layout()
    RefreshAuras()
end

---------------------------------------------------------------------
-- Finestra opzioni
---------------------------------------------------------------------
local opt

local function MakeCheck(parent, x, y, label, onClick)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT", x, y)
    cb:SetSize(24, 24)
    cb.label = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    cb.label:SetPoint("LEFT", cb, "RIGHT", 2, 0)
    cb.label:SetText(label)
    cb:SetScript("OnClick", function(self) onClick(self:GetChecked() and true or false) end)
    return cb
end

local function MakeSection(parent, y, text)
    local s = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    s:SetPoint("TOPLEFT", 20, y)
    s:SetText(text)
    return s
end

-- selettore di colore (nuova API di Midnight, con ripiego sulla vecchia)
local function PickColor(r, g, b, onChange)
    if ColorPickerFrame.SetupColorPickerAndShow then
        ColorPickerFrame:SetupColorPickerAndShow({
            r = r, g = g, b = b, hasOpacity = false,
            swatchFunc = function() onChange(ColorPickerFrame:GetColorRGB()) end,
            cancelFunc = function() onChange(r, g, b) end,
        })
    else
        ColorPickerFrame.hasOpacity = false
        ColorPickerFrame.func = function() onChange(ColorPickerFrame:GetColorRGB()) end
        ColorPickerFrame.cancelFunc = function() onChange(r, g, b) end
        ColorPickerFrame:SetColorRGB(r, g, b)
        ColorPickerFrame:Show()
    end
end

local function Tip(frame, text)
    frame:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(text, 1, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    frame:HookScript("OnLeave", function() GameTooltip:Hide() end)
end

-- campione colore + casella "piatta". ref() restituisce:
--   tabellaColori, chiaveColore, tabellaPiatta, chiavePiatta, coloreDiDefault
local function MakeStyle(parent, ref)
    local sw = CreateFrame("Button", nil, parent)
    sw:SetSize(18, 18)
    sw:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    local border = sw:CreateTexture(nil, "BACKGROUND")
    border:SetAllPoints()
    border:SetColorTexture(1, 1, 1, 1)
    sw.tex = sw:CreateTexture(nil, "ARTWORK")
    sw.tex:SetPoint("TOPLEFT", 1, -1)
    sw.tex:SetPoint("BOTTOMRIGHT", -1, 1)

    local fl = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    fl:SetSize(22, 22)

    function sw.Update()
        local ct, ck, ft, fk, def = ref()
        if not ct then return end
        local c = ct[ck] or def
        sw.tex:SetColorTexture(c[1], c[2], c[3])
        fl:SetChecked(ft[fk] and true or false)
    end
    sw:SetScript("OnClick", function(self, button)
        local ct, ck, _, _, def = ref()
        if not ct then return end
        if button == "RightButton" then
            ct[ck] = nil
            self.Update()
            Apply()
            return
        end
        local c = ct[ck] or def
        PickColor(c[1], c[2], c[3], function(r, g, b)
            local ct2, ck2 = ref()
            if ct2 then ct2[ck2] = { r, g, b } end
            sw.Update()
            Apply()
        end)
    end)
    fl:SetScript("OnClick", function(self)
        local _, _, ft, fk = ref()
        if ft then
            ft[fk] = self:GetChecked() and true or nil
            Apply()
        end
    end)
    Tip(sw, "Colore della barra\nClic destro: colore predefinito")
    Tip(fl, "Barra piatta (senza sfumatura)")
    return sw, fl
end

local function ResetPosition()
    if not db then return end
    db.x, db.y, db.dx, db.dy, db.cx, db.cy = nil, nil, nil, nil, nil, nil
    PlaceContainer()
end

local function BuildOptions()
    opt = CreateFrame("Frame", "TavesBarOptions", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    opt:SetSize(380, 556)
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
    tinsert(UISpecialFrames, "TavesBarOptions")

    local title = opt:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -16)
    title:SetText("TavesBar")
    local close = CreateFrame("Button", nil, opt, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -6, -6)

    MakeSection(opt, -44, "Barre da mostrare")
    local fixedChecks, fixedStyles = {}, {}
    for i, f in ipairs(FIXED) do
        local cb = MakeCheck(opt, 24, -62 - (i - 1) * 24, f.label, function(v)
            db.bars[f.key] = v
            Apply()
        end)
        cb.key = f.key
        fixedChecks[#fixedChecks + 1] = cb

        local sw, fl = MakeStyle(opt, function()
            return db.colors, f.key, db.flat, f.key, COLORS[f.key]
        end)
        sw:SetPoint("TOPLEFT", 196, -65 - (i - 1) * 24)
        fl:SetPoint("LEFT", sw, "RIGHT", 10, 0)
        local t = opt:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        t:SetPoint("LEFT", fl, "RIGHT", 0, 0)
        t:SetText("Piatta")
        fixedStyles[#fixedStyles + 1] = sw
    end

    MakeSection(opt, -166, "Barre debuff (sul bersaglio, tuoi)")
    local hint = opt:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", 24, -184)
    hint:SetText("Nome del debuff, ID numerico, o trascina l'abilita' qui")

    local edit = CreateFrame("EditBox", nil, opt, "InputBoxTemplate")
    edit:SetSize(190, 22)
    edit:SetPoint("TOPLEFT", 30, -200)
    edit:SetAutoFocus(false)
    edit:SetMaxLetters(60)

    local rows = {}
    local function RefreshList()
        for i = 1, MAX_DEBUFFS do
            local r, d = rows[i], db.debuffs[i]
            if d then
                r.check:SetChecked(d.enabled)
                local _, idKey = CandidateIDs(d)
                r.text:SetText(d.name .. (idKey == "" and " |cffff4040(ID?)|r" or ""))
                r.sw.Update()
                r.cfg:SetText(RowSummary(d))
                r:Show()
            else
                r:Hide()
            end
        end
    end

    local function AddDebuff()
        local name = (edit:GetText() or ""):match("^%s*(.-)%s*$")
        if name == "" then return end
        if #db.debuffs >= MAX_DEBUFFS then
            print("|cffffd100TavesBar:|r massimo " .. MAX_DEBUFFS .. " barre debuff.")
            return
        end
        local spellId = (edit.dropName == name) and edit.dropId or nil
        local ids
        local asId = tonumber(name)
        if asId then   -- numero: e' direttamente l'ID dell'aura
            ids = { asId }
            local n = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(asId)
            name = n or ("ID " .. asId)
        end
        for _, d in ipairs(db.debuffs) do
            if d.name:lower() == name:lower() then
                edit:SetText("")
                return
            end
        end
        db.debuffs[#db.debuffs + 1] = {
            name = name, enabled = true, spellId = spellId, ids = ids,
        }
        edit.dropName, edit.dropId = nil, nil
        edit:SetText("")
        edit:ClearFocus()
        RefreshList()
        Apply()
    end

    -- trascina un'abilita' (dal libro degli incantesimi o dalla barra) sulla casella:
    -- ne scrive il nome. L'abilita' resta sul cursore: rimettila dove l'hai presa.
    local function OnDrop()
        local t, a, b, c, d = GetCursorInfo()
        if t ~= "spell" then return end
        local list = { c, d, a }
        for i = 1, 3 do
            local id = list[i]
            if type(id) == "number" then
                local n = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(id)
                if n then
                    edit:SetText(n)
                    edit.dropName, edit.dropId = n, id
                    edit:SetCursorPosition(0)
                    return
                end
            end
        end
    end
    edit:SetScript("OnReceiveDrag", OnDrop)
    edit:HookScript("OnMouseUp", OnDrop)
    edit:SetScript("OnEnterPressed", AddDebuff)
    edit:SetScript("OnEscapePressed", edit.ClearFocus)

    local add = CreateFrame("Button", nil, opt, "UIPanelButtonTemplate")
    add:SetSize(80, 24)
    add:SetPoint("LEFT", edit, "RIGHT", 8, 0)
    add:SetText("Aggiungi")
    add:SetScript("OnClick", AddDebuff)

    -- menu a comparsa per riga (stile NeedToKnow: Tipo / Su chi / Solo miei)
    local menu, menuIndex
    local menuChecks = {}
    local function MenuRefresh()
        local d = menuIndex and db.debuffs[menuIndex]
        if not d then return end
        for _, cb in ipairs(menuChecks) do
            local on
            if cb.group == "kind" then on = ((d.kind == "buff") and "buff" or "debuff") == cb.value
            elseif cb.group == "unit" then on = AuraUnit(d) == cb.value
            else on = (cb.value == (not d.any)) end
            cb:SetChecked(on)
        end
    end
    local function MenuSet(group, value)
        local d = menuIndex and db.debuffs[menuIndex]
        if not d then return end
        if group == "kind" then
            d.kind = value
            -- il bersaglio/me stesso seguono il tipo, a meno di una scelta diversa (focus, pet)
            if d.unit == "player" or d.unit == "target" then d.unit = nil end
            d.ids = nil   -- gli ID appresi valevano per l'altro tipo
        elseif group == "unit" then
            local default = (d.kind == "buff") and "player" or "target"
            d.unit = (value ~= default) and value or nil
        else
            d.any = (not value) or nil
        end
        MenuRefresh()
        RefreshList()
        Apply()
    end
    local function BuildMenu()
        menu = CreateFrame("Frame", "TavesBarRowMenu", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
        menu:SetSize(200, 234)
        menu:SetFrameStrata("FULLSCREEN_DIALOG")
        menu:SetFrameLevel(20)
        menu:SetClampedToScreen(true)
        menu:EnableMouse(true)
        if menu.SetBackdrop then
            menu:SetBackdrop({
                bgFile = "Interface\\Buttons\\WHITE8X8",
                edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                tile = true, tileSize = 16, edgeSize = 14,
                insets = { left = 4, right = 4, top = 4, bottom = 4 },
            })
            menu:SetBackdropColor(0, 0, 0, 1)
        end
        menu:Hide()
        -- un clic fuori dal menu lo chiude
        local catcher = CreateFrame("Button", nil, UIParent)
        catcher:SetAllPoints(UIParent)
        catcher:SetFrameStrata("FULLSCREEN_DIALOG")
        catcher:SetFrameLevel(1)
        catcher:RegisterForClicks("AnyUp")
        catcher:Hide()
        catcher:SetScript("OnClick", function() menu:Hide() end)
        menu:SetScript("OnShow", function() catcher:Show() end)
        menu:SetScript("OnHide", function() catcher:Hide() end)

        local y = -8
        local function Header(text)
            local t = menu:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            t:SetPoint("TOPLEFT", 10, y)
            t:SetText(text)
            y = y - 18
        end
        local function Option(group, value, label)
            local cb = CreateFrame("CheckButton", nil, menu, "UICheckButtonTemplate")
            cb:SetSize(22, 22)
            cb:SetPoint("TOPLEFT", 12, y + 2)
            cb.group, cb.value = group, value
            local t = menu:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            t:SetPoint("LEFT", cb, "RIGHT", 2, 0)
            t:SetText(label)
            cb:SetScript("OnClick", function() MenuSet(group, value) end)
            menuChecks[#menuChecks + 1] = cb
            y = y - 21
        end
        Header("Tipo")
        Option("kind", "buff", "Buff")
        Option("kind", "debuff", "Debuff")
        Header("Su chi")
        Option("unit", "player", "Me stesso")
        Option("unit", "target", "Bersaglio")
        Option("unit", "focus", "Focus")
        Option("unit", "pet", "Pet")
        Header("Di chi")
        Option("mine", true, "Solo miei")
        Option("mine", false, "Anche di altri")
    end
    local function ShowRowMenu(anchor, index)
        if not menu then BuildMenu() end
        if menu:IsShown() and menuIndex == index then menu:Hide() return end
        menuIndex = index
        MenuRefresh()
        menu:ClearAllPoints()
        menu:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
        menu:Show()
    end

    for i = 1, MAX_DEBUFFS do
        local r = CreateFrame("Frame", nil, opt)
        r:SetSize(330, 22)
        r:SetPoint("TOPLEFT", 24, -230 - (i - 1) * 22)
        r.check = CreateFrame("CheckButton", nil, r, "UICheckButtonTemplate")
        r.check:SetSize(22, 22)
        r.check:SetPoint("LEFT")
        r.check:SetScript("OnClick", function(self)
            if db.debuffs[i] then
                db.debuffs[i].enabled = self:GetChecked() and true or false
                Apply()
            end
        end)
        r.text = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        r.text:SetPoint("LEFT", r.check, "RIGHT", 4, 0)
        r.text:SetJustifyH("LEFT")
        r.del = CreateFrame("Button", nil, r, "UIPanelCloseButton")
        r.del:SetSize(22, 22)
        r.del:SetPoint("RIGHT", 0, 0)
        local sw, fl = MakeStyle(r, function()
            local d = db.debuffs[i]
            if d then return d, "color", d, "flat", COLORS.debuff end
        end)
        fl:SetPoint("RIGHT", r.del, "LEFT", -2, 0)
        sw:SetPoint("RIGHT", fl, "LEFT", -4, 0)
        r.sw = sw

        -- bottone con il riepilogo (es. "Debuff · Bers."): il clic apre il menu di scelta
        r.cfg = CreateFrame("Button", nil, r, "UIPanelButtonTemplate")
        r.cfg:SetSize(104, 20)
        r.cfg:SetPoint("RIGHT", sw, "LEFT", -6, 0)
        r.cfg:SetScript("OnClick", function(self) ShowRowMenu(self, i) end)
        Tip(r.cfg, "Clic per scegliere: Buff o Debuff, su chi controllarlo,\ne se solo i tuoi o anche quelli di altri")
        r.text:SetPoint("RIGHT", r.cfg, "LEFT", -4, 0)

        r.del:SetScript("OnClick", function()
            table.remove(db.debuffs, i)
            RefreshList()
            Apply()
        end)
        rows[i] = r
    end

    MakeSection(opt, -370, "Aspetto")
    local sliders = {}
    local function AddSlider(key, label, minV, maxV, y)
        local sl = CreateFrame("Slider", nil, opt, "OptionsSliderTemplate")
        sl:SetPoint("TOPLEFT", 28, y)
        sl:SetWidth(284)
        sl:SetMinMaxValues(minV, maxV)
        sl:SetValueStep(1)
        if sl.SetObeyStepOnDrag then sl:SetObeyStepOnDrag(true) end
        sl.Low:SetText(tostring(minV))
        sl.High:SetText(tostring(maxV))
        sl:SetScript("OnValueChanged", function(self, v)
            v = math.floor(v + 0.5)
            self.Text:SetText(label .. ": " .. tostring(v))
            if self.busy or not db or db[key] == v then return end
            db[key] = v
            Apply()
        end)
        sl.key, sl.label = key, label
        sliders[#sliders + 1] = sl
    end
    AddSlider("width", "Larghezza", 80, 400, -406)
    AddSlider("height", "Altezza barre", 10, 40, -452)

    local cbLock = MakeCheck(opt, 24, -478, "Blocca la posizione (disattiva SHIFT+trascina)", function(v)
        db.locked = v
        Apply()
    end)

    local reset = CreateFrame("Button", nil, opt, "UIPanelButtonTemplate")
    reset:SetSize(170, 24)
    reset:SetPoint("BOTTOM", 0, 20)
    reset:SetText("Ripristina posizione")
    reset:SetScript("OnClick", ResetPosition)

    function opt.Refresh()
        for _, cb in ipairs(fixedChecks) do cb:SetChecked(db.bars[cb.key]) end
        for _, sw in ipairs(fixedStyles) do sw.Update() end
        for _, sl in ipairs(sliders) do
            sl.busy = true
            sl:SetValue(db[sl.key])
            sl.Text:SetText(sl.label .. ": " .. tostring(db[sl.key]))
            sl.busy = false
        end
        cbLock:SetChecked(db.locked)
        RefreshList()
    end
    opt:SetScript("OnShow", opt.Refresh)
end

local function ToggleOptions()
    if not db then return end
    if not opt then BuildOptions() end
    if opt:IsShown() then opt:Hide() else opt:Show() end
end
TavesBar_ToggleOptions = ToggleOptions

if TavesMenu then
    TavesMenu.Register("bar", "TavesBar", "Interface\\Icons\\Ability_Rogue_Eviscerate", ToggleOptions)
end

---------------------------------------------------------------------
-- Init e comandi
---------------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("MODIFIER_STATE_CHANGED")
ev:RegisterEvent("PLAYER_REGEN_ENABLED")
ev:RegisterEvent("PLAYER_TARGET_CHANGED")
ev:RegisterUnitEvent("UNIT_AURA", "target", "player", "focus", "pet")
ev:RegisterEvent("PLAYER_FOCUS_CHANGED")
ev:RegisterEvent("SPELLS_CHANGED")
ev:SetScript("OnEvent", function(_, event)
    if event == "MODIFIER_STATE_CHANGED" then
        UpdateMouse()
        return
    elseif event == "PLAYER_REGEN_ENABLED" then
        if db and pendingApply then Apply() end
        LearnIDs()
        return
    elseif event == "SPELLS_CHANGED" then
        bookIDs = nil
        if db and not InCombat() then Apply() end
        return
    elseif event == "PLAYER_TARGET_CHANGED" or event == "PLAYER_FOCUS_CHANGED" or event == "UNIT_AURA" then
        if db then
            RefreshAuras()
            LearnIDs()
        end
        return
    end
    TavesBarDB = TavesBarDB or {}
    db = TavesBarDB
    local oldVer = db.ver
    for k, v in pairs(DEFAULTS) do
        if db[k] == nil then
            if type(v) == "table" then
                db[k] = {}
                for k2, v2 in pairs(v) do db[k][k2] = v2 end
            else
                db[k] = v
            end
        end
    end
    for k, v in pairs(DEFAULTS.bars) do
        if db.bars[k] == nil then db.bars[k] = v end
    end
    if not oldVer and next(db.debuffs) == nil then
        db.bars.energy, db.bars.rage = false, false
    end
    -- opzioni delle versioni precedenti
    db.onlyMine, db.debuffBlock, db.hideInactive = nil, nil, nil
    for _, d in ipairs(db.debuffs) do d.duration = nil end
    db.ver = DEFAULTS.ver
    PlaceContainer()
    Apply()
end)

SLASH_TAVESBAR1 = "/tbar"
SlashCmdList["TAVESBAR"] = function(msg)
    msg = (msg or ""):lower():match("^%s*(.-)%s*$")
    if not db then return end
    if msg == "lock" then
        db.locked = true
        Apply()
    elseif msg == "unlock" then
        db.locked = false
        Apply()
    elseif msg == "reset" then
        ResetPosition()
    elseif msg == "ids" or msg == "status" then
        local function S(f, m)
            if not f or type(f[m]) ~= "function" then return "-" end
            local ok, v = pcall(f[m], f)
            if not ok then return "err" end
            if IsSecret(v) then return "secret" end
            return tostring(v)
        end
        for _, d in ipairs(db.debuffs) do
            local _, key = CandidateIDs(d)
            local unit, filter = AuraParams(d)
            local line = d.name .. " [" .. unit .. " " .. filter .. "] ID: " .. (key == "" and "nessuno" or key)
            for _, f in ipairs(debuffPool) do
                if f.spec and f.spec.d == d then
                    line = line .. " | contenitore=" .. (f.aura and "si" or "NO") ..
                        " visibile=" .. S(f.aura, "IsShown") .. " unita=" .. S(f.aura, "GetUnit") ..
                        " barra=" .. S(f, "IsShown")
                end
            end
            print("|cffffd100TavesBar:|r " .. line)
        end
    else
        ToggleOptions()
    end
    if opt and opt:IsShown() then opt.Refresh() end
end
