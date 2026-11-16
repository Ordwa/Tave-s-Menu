-- TavesMenu: icona a ingranaggio che apre un menu con tutti gli addon Taves.
-- Gli altri addon si registrano con:
--   if TavesMenu then TavesMenu.Register("chiave", "Etichetta", "Interface\\Icons\\...", function() ... end) end
-- (aggiungere "## OptionalDeps: TavesMenu" nel loro .toc, cosi' TavesMenu si carica prima)

local TM = {}
_G.TavesMenu = TM

local entries = {}
local ROW_H, MENU_W = 26, 170

function TM.Register(key, label, icon, func)
    for _, e in ipairs(entries) do
        if e.key == key then
            e.label, e.icon, e.func = label, icon, func
            return
        end
    end
    entries[#entries + 1] = { key = key, label = label, icon = icon, func = func }
end

---------------------------------------------------------------------
-- Menu a tendina
---------------------------------------------------------------------
local menu = CreateFrame("Frame", "TavesMenuFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
menu:SetFrameStrata("DIALOG")
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
tinsert(UISpecialFrames, "TavesMenuFrame")

-- sfondo invisibile: un clic fuori dal menu lo chiude
local catcher = CreateFrame("Button", nil, UIParent)
catcher:SetAllPoints(UIParent)
catcher:SetFrameStrata("DIALOG")
catcher:SetFrameLevel(1)
catcher:RegisterForClicks("AnyUp")
catcher:Hide()
catcher:SetScript("OnClick", function() menu:Hide() end)
menu:SetFrameLevel(10)
menu:SetScript("OnShow", function() catcher:Show() end)
menu:SetScript("OnHide", function() catcher:Hide() end)

local rows = {}
local function GetRow(i)
    local r = rows[i]
    if r then return r end
    r = CreateFrame("Button", nil, menu)
    r:SetHeight(ROW_H)
    r:SetPoint("TOPLEFT", 8, -8 - (i - 1) * ROW_H)
    r:SetPoint("TOPRIGHT", -8, -8 - (i - 1) * ROW_H)
    r:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(20, 20)
    r.icon:SetPoint("LEFT", 2, 0)
    r.text = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    r.text:SetPoint("LEFT", r.icon, "RIGHT", 6, 0)
    r.text:SetPoint("RIGHT", -2, 0)
    r.text:SetJustifyH("LEFT")
    r:SetScript("OnClick", function(self)
        menu:Hide()
        if self.func then self.func() end
    end)
    rows[i] = r
    return r
end

local function BuildMenu()
    for i, e in ipairs(entries) do
        local r = GetRow(i)
        r.icon:SetTexture(e.icon)
        r.text:SetText(e.label)
        r.func = e.func
        r:Show()
    end
    for i = #entries + 1, #rows do rows[i]:Hide() end
    menu:SetSize(MENU_W, 16 + math.max(1, #entries) * ROW_H)
end

---------------------------------------------------------------------
-- Icona ingranaggio
---------------------------------------------------------------------
local btn = CreateFrame("Button", "TavesMenuButton", UIParent)
btn:SetSize(26, 26)
btn:SetFrameStrata("MEDIUM")
btn:SetNormalTexture("Interface\\Icons\\Trade_Engineering")
btn:SetPushedTexture("Interface\\Icons\\Trade_Engineering")
btn:GetPushedTexture():SetVertexColor(0.7, 0.7, 0.7)
btn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")

local function Toggle()
    if menu:IsShown() then
        menu:Hide()
        return
    end
    BuildMenu()
    menu:ClearAllPoints()
    menu:SetPoint("BOTTOMLEFT", btn, "BOTTOMRIGHT", 4, 0)
    menu:Show()
end
TM.Toggle = Toggle

btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
btn:SetScript("OnClick", function(_, button)
    if button == "RightButton" then
        menu:Hide()
        ReloadUI()
    else
        Toggle()
    end
end)
btn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("Taves")
    GameTooltip:AddLine("Clic sinistro: apre il menu degli addon", 1, 1, 1)
    GameTooltip:AddLine("Clic destro: ricarica l'interfaccia (/reload)", 1, 1, 1)
    GameTooltip:Show()
end)
btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

local function PlaceButton()
    btn:ClearAllPoints()
    local bf = _G.ChatFrame1ButtonFrame
    if bf and bf:IsShown() then
        btn:SetPoint("TOP", bf, "BOTTOM", 0, -4)
    elseif _G.ChatFrame1 then
        btn:SetPoint("TOPRIGHT", _G.ChatFrame1, "TOPLEFT", -4, 0)
    else
        btn:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 4, 200)
    end
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:SetScript("OnEvent", function()
    TavesMenuDB = TavesMenuDB or {}
    PlaceButton()
end)

SLASH_TAVESMENU1 = "/tmenu"
SlashCmdList["TAVESMENU"] = Toggle
