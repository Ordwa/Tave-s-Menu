-- TavesCam: mouselook con un tasto (telecamera che segue il mouse, stile action combat)
-- Comandi: /cam (attiva/disattiva)  /cam on  /cam off  /cam help
-- Il tasto si assegna da Opzioni -> Tasti -> TavesCam.

BINDING_HEADER_TAVESCAM = "TavesCam"
BINDING_NAME_TAVESCAM_TOGGLE = "Attiva/disattiva mouselook"

local wanted = false -- l'utente vuole il mouselook attivo

-- Finestre che, se aperte, mettono in pausa il mouselook (serve il cursore)
local WINDOWS = {
    "WorldMapFrame", "CharacterFrame", "SpellBookFrame", "PlayerTalentFrame", "TalentFrame",
    "QuestLogFrame", "QuestFrame", "GossipFrame", "MerchantFrame", "TradeFrame", "MailFrame",
    "BankFrame", "AuctionFrame", "FriendsFrame", "LootFrame", "TaxiFrame", "TradeSkillFrame",
    "CraftFrame", "TrainerFrame", "ClassTrainerFrame", "GameMenuFrame", "InterfaceOptionsFrame",
    "SettingsPanel", "VideoOptionsFrame", "KeyBindingFrame", "MacroFrame", "TavesChatPanel", "TavesNotesPanel", "TavesCamOptions", "TavesMapOptions",
    "StackSplitFrame", "ItemTextFrame", "PetStableFrame", "BattlefieldFrame", "WorldStateScoreFrame",
}

local function AnyWindowOpen()
    for i = 1, #WINDOWS do
        local fr = _G[WINDOWS[i]]
        if fr and fr.IsShown and fr:IsShown() then return true end
    end
    for i = 1, 13 do
        local fr = _G["ContainerFrame" .. i]
        if fr and fr:IsShown() then return true end
    end
    for i = 1, 4 do
        local fr = _G["StaticPopup" .. i]
        if fr and fr:IsShown() then return true end
    end
    return false
end

---------------------------------------------------------------------
-- Logica
---------------------------------------------------------------------
local started = false -- il mouselook l'ho avviato io (non il gioco col tasto destro)

local function Apply()
    -- se l'utente non ha mai attivato il toggle, non tocco niente
    if not wanted and not started then return end
    local should = wanted and not AnyWindowOpen()
    local looking = IsMouselooking()
    if should then
        if not looking then
            MouselookStart()
        end
        started = true
    else
        -- fermo solo il mouselook che ho avviato io
        if started and looking then
            MouselookStop()
        end
        started = false
    end
end

function TavesCam_Toggle()
    wanted = not wanted
    Apply()
end

local acc = 0
local ticker = CreateFrame("Frame")
ticker:SetScript("OnUpdate", function(_, elapsed)
    acc = acc + elapsed
    if acc < 0.1 then return end
    acc = 0
    Apply()
end)

---------------------------------------------------------------------
-- Finestra opzioni (tasto di attivazione, on/off)
---------------------------------------------------------------------
local BINDING = "TAVESCAM_TOGGLE"
local opt -- creata al primo utilizzo

local function KeyText()
    local k1 = GetBindingKey(BINDING)
    return k1 and GetBindingText(k1, "KEY_") or "Non assegnato"
end

local function StopCapture()
    if not opt then return end
    opt.capturing = false
    opt.keyBtn:EnableKeyboard(false)
    opt.keyBtn:SetText(KeyText())
end

local function AssignKey(key)
    if InCombatLockdown() then
        print("|cffffd100TavesCam:|r non puoi cambiare il tasto in combattimento.")
        return
    end
    -- toglie il tasto precedente e assegna il nuovo
    local old = { GetBindingKey(BINDING) }
    for _, k in ipairs(old) do SetBinding(k) end
    if key then SetBinding(key, BINDING) end
    SaveBindings(GetCurrentBindingSet())
end

local IGNORE = {
    LSHIFT = true, RSHIFT = true, LCTRL = true, RCTRL = true,
    LALT = true, RALT = true, LMETA = true, RMETA = true,
}

local function OnCapture(key)
    if not opt or not opt.capturing then return end
    if IGNORE[key] then return end
    if key == "ESCAPE" then
        StopCapture()
        return
    end
    if key == "LeftButton" then key = "BUTTON1"
    elseif key == "RightButton" then key = "BUTTON2"
    elseif key == "MiddleButton" then key = "BUTTON3"
    else
        key = key:gsub("^Button(%d+)$", "BUTTON%1")
    end
    -- il click sinistro serve per iniziare la cattura: non lo accetto come tasto
    if key == "BUTTON1" then return end
    local prefix = (IsAltKeyDown() and "ALT-" or "")
        .. (IsControlKeyDown() and "CTRL-" or "")
        .. (IsShiftKeyDown() and "SHIFT-" or "")
    AssignKey(prefix .. key)
    StopCapture()
end

local function BuildOptions()
    opt = CreateFrame("Frame", "TavesCamOptions", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    opt:SetSize(300, 190)
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
    tinsert(UISpecialFrames, "TavesCamOptions")

    local title = opt:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -16)
    title:SetText("TavesCam")

    local close = CreateFrame("Button", nil, opt, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -6, -6)

    local lbl = opt:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    lbl:SetPoint("TOPLEFT", 24, -52)
    lbl:SetText("Tasto di attivazione:")

    -- bottone: clic, poi premi il tasto desiderato
    local kb = CreateFrame("Button", nil, opt, "UIPanelButtonTemplate")
    kb:SetSize(150, 26)
    kb:SetPoint("TOPLEFT", lbl, "BOTTOMLEFT", 0, -6)
    kb:RegisterForClicks("AnyUp")
    kb:SetScript("OnClick", function(self, button)
        if opt.capturing then
            OnCapture(button) -- clic centrale/laterale durante la cattura
        else
            opt.capturing = true
            self:SetText("Premi un tasto...")
            self:EnableKeyboard(true)
            self:SetPropagateKeyboardInput(false)
        end
    end)
    kb:SetScript("OnKeyDown", function(_, key) OnCapture(key) end)
    kb:SetScript("OnHide", StopCapture)
    opt.keyBtn = kb

    local clear = CreateFrame("Button", nil, opt, "UIPanelButtonTemplate")
    clear:SetSize(90, 26)
    clear:SetPoint("LEFT", kb, "RIGHT", 8, 0)
    clear:SetText("Rimuovi")
    clear:SetScript("OnClick", function()
        AssignKey(nil)
        StopCapture()
    end)

    local hint = opt:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", kb, "BOTTOMLEFT", 0, -6)
    hint:SetWidth(250)
    hint:SetJustifyH("LEFT")
    hint:SetText("Clic sul tasto, poi premi la combinazione voluta (Esc per annullare).")

    local tog = CreateFrame("Button", nil, opt, "UIPanelButtonTemplate")
    tog:SetSize(150, 26)
    tog:SetPoint("BOTTOMLEFT", 24, 22)
    tog:SetScript("OnClick", function()
        TavesCam_Toggle()
        opt.Refresh()
    end)
    opt.togBtn = tog

    function opt.Refresh()
        kb:SetText(KeyText())
        tog:SetText(wanted and "Disattiva mouselook" or "Attiva mouselook")
    end
    opt:SetScript("OnShow", opt.Refresh)
end

function TavesCam_OpenOptions()
    if not opt then BuildOptions() end
    if opt:IsShown() then opt:Hide() else opt:Show() end
end

if TavesMenu then
    TavesMenu.Register("cam", "TavesCam", "Interface\\Icons\\INV_Misc_Spyglass_02", TavesCam_OpenOptions)
end

---------------------------------------------------------------------
-- Comandi
---------------------------------------------------------------------
local function Say(msg) print("|cffffd100TavesCam:|r " .. msg) end

SLASH_TAVESCAM1 = "/cam"
SlashCmdList["TAVESCAM"] = function(msg)
    msg = (msg or ""):lower():match("^%s*(.-)%s*$")
    if msg == "on" then
        wanted = true
        Apply()
        Say("mouselook attivo.")
    elseif msg == "off" then
        wanted = false
        Apply()
        Say("mouselook disattivato.")
    elseif msg == "opzioni" or msg == "options" or msg == "config" then
        TavesCam_OpenOptions()
    elseif msg == "help" or msg == "?" then
        Say("/cam = attiva/disattiva | /cam on | /cam off")
        Say("Per assegnare un tasto: Opzioni -> Tasti -> TavesCam.")
    else
        wanted = not wanted
        Apply()
        Say("mouselook " .. (wanted and "attivo." or "disattivato."))
    end
end
