-- TavesNotes: aggiunge alla chat una scheda "Note" (blocco note con lista, modifica, elimina).
-- Comando: /note (passa alla scheda Note e torna alla chat generale)

local TAB_NAME = "Note"

local db
local selectedId
local rows = {}
local ROW_H = 38
local LIST_W = 140

local chatFrame, panel
local body, bodyScroll, listChild, info

local function Now() return time() end
local function Fmt(t) return date("%d/%m/%y %H:%M", t or 0) end

---------------------------------------------------------------------
-- Dati
---------------------------------------------------------------------
local function NewId()
    db.nextId = (db.nextId or 0) + 1
    return db.nextId
end

local function FindNote(id)
    for i, n in ipairs(db.notes) do
        if n.id == id then return n, i end
    end
end

local function Sorted()
    local list = {}
    for _, n in ipairs(db.notes) do list[#list + 1] = n end
    table.sort(list, function(a, b) return (a.mod or 0) > (b.mod or 0) end)
    return list
end

local function FirstLines(text)
    text = text or ""
    local l1, l2 = text:match("^([^\n]*)\n?([^\n]*)")
    l1 = (l1 and l1:match("^%s*(.-)%s*$")) or ""
    l2 = (l2 and l2:match("^%s*(.-)%s*$")) or ""
    return l1, l2
end

local function CreateNote()
    local n = { id = NewId(), text = "", mod = Now() }
    table.insert(db.notes, n)
    return n
end

---------------------------------------------------------------------
-- Logica lista / selezione
---------------------------------------------------------------------
local Refresh, Select, ShowNoteMenu

local function GetRow(i)
    local r = rows[i]
    if r then return r end
    r = CreateFrame("Button", nil, listChild)
    r:SetSize(LIST_W, ROW_H)
    r:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
    r.hl = r:CreateTexture(nil, "HIGHLIGHT")
    r.hl:SetAllPoints()
    r.hl:SetColorTexture(1, 1, 1, 0.12)
    r.sel = r:CreateTexture(nil, "BACKGROUND")
    r.sel:SetAllPoints()
    r.sel:SetColorTexture(1, 0.82, 0, 0.22)
    r.t = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    r.t:SetPoint("TOPLEFT", 6, -4)
    r.t:SetPoint("TOPRIGHT", -4, -4)
    r.t:SetJustifyH("LEFT")
    r.t:SetWordWrap(false)
    r.d = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    r.d:SetPoint("TOPLEFT", r.t, "BOTTOMLEFT", 0, -2)
    r.d:SetPoint("TOPRIGHT", r.t, "BOTTOMRIGHT", 0, -2)
    r.d:SetJustifyH("LEFT")
    r.d:SetWordWrap(false)
    r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    r:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            ShowNoteMenu(self.noteId)
        else
            Select(self.noteId)
        end
    end)
    rows[i] = r
    return r
end

function Refresh()
    local list = Sorted()
    for i, n in ipairs(list) do
        local r = GetRow(i)
        local l1, l2 = FirstLines(n.text)
        r.noteId = n.id
        r.t:SetText(l1 ~= "" and l1 or "Nuova nota")
        r.d:SetText(Fmt(n.mod) .. (l2 ~= "" and ("  " .. l2) or ""))
        r.sel:SetShown(n.id == selectedId)
        r:Show()
    end
    for i = #list + 1, #rows do rows[i]:Hide() end
    listChild:SetHeight(math.max(1, #list * ROW_H))
    local n = FindNote(selectedId)
    info:SetText(n and ("Modificata: " .. Fmt(n.mod)) or "")
end

function Select(id)
    -- scarta la nota corrente se e' rimasta vuota
    local cur = FindNote(selectedId)
    if cur and cur.id ~= id and (cur.text or ""):match("^%s*$") and #db.notes > 1 then
        local _, idx = FindNote(cur.id)
        table.remove(db.notes, idx)
    end
    local n = FindNote(id)
    if not n then
        n = Sorted()[1] or CreateNote()
    end
    selectedId = n.id
    db.selected = n.id
    body.loading = true
    body:SetText(n.text or "")
    body.loading = false
    bodyScroll:SetVerticalScroll(0)
    Refresh()
end

StaticPopupDialogs["TavesNotes_DELETE"] = {
    text = "Eliminare questa nota?",
    button1 = YES,
    button2 = NO,
    OnAccept = function()
        local _, idx = FindNote(selectedId)
        if idx then table.remove(db.notes, idx) end
        if #db.notes == 0 then CreateNote() end
        selectedId = nil
        Select(Sorted()[1].id)
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

---------------------------------------------------------------------
-- Condivisione note (messaggi di addon nascosti, a pezzi)
---------------------------------------------------------------------
local PREFIX = "TavesNotes"
local RegisterPrefix = (C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix) or RegisterAddonMessagePrefix
local SendAddon = (C_ChatInfo and C_ChatInfo.SendAddonMessage) or SendAddonMessage
local CHUNK = 200            -- caratteri codificati per messaggio (limite del gioco: 255)
local MAX_PARTS = 100
local incoming = {}
local openPopups = 0

local function Say(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cffffd100TavesNotes:|r " .. msg)
end

-- codifica: i caratteri che romperebbero un messaggio di addon diventano %XX
local function Enc(s)
    return (s:gsub("[%%\t\n\r|%z]", function(c) return string.format("%%%02X", c:byte()) end))
end
local function Dec(s)
    return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local function MakeChunks(text)
    local chunks, cur, len = {}, {}, 0
    for ch in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        local e = Enc(ch)
        if len + #e > CHUNK then
            chunks[#chunks + 1] = table.concat(cur)
            cur, len = {}, 0
        end
        cur[#cur + 1] = e
        len = len + #e
    end
    if #cur > 0 then chunks[#chunks + 1] = table.concat(cur) end
    return chunks
end

local function TitleOf(note)
    local l1 = FirstLines(note.text)
    if l1 == "" then l1 = "Senza titolo" end
    local out, n = {}, 0
    for ch in l1:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        n = n + 1
        if n > 60 then break end
        out[n] = ch
    end
    return table.concat(out)
end

-- coda di invio: un pezzo alla volta, riprova se il gioco rallenta (throttle)
local queue, ticker = {}, nil
local function Pump()
    local m = queue[1]
    if not m then
        if ticker then ticker:Cancel() ticker = nil end
        return
    end
    local r = SendAddon(PREFIX, m.msg, m.channel, m.target)
    local failed = (r == false) or (type(r) == "number" and r ~= 0)
    if failed then
        m.tries = (m.tries or 0) + 1
        if m.tries > 20 then table.remove(queue, 1) end
    else
        table.remove(queue, 1)
    end
end

local function ShareNote(note, kind, target, gid, acct)
    if not note or (note.text or ""):match("^%s*$") then
        Say("La nota e' vuota.")
        return
    end
    local channel, slash
    if kind == "WHISPER" then
        if not target or target == "" then return end
        gid = nil   -- sempre whisper standard del gioco, mai quello di Battle.net
        channel, slash = "WHISPER", "/w " .. target
    elseif kind == "GUILD" then
        if not IsInGuild() then Say("Non sei in una gilda.") return end
        channel, slash = "GUILD", "/g"
    else
        if not IsInGroup() then Say("Non sei in un gruppo.") return end
        if IsInRaid() then channel, slash = "RAID", "/raid" else channel, slash = "PARTY", "/p" end
    end
    local title = TitleOf(note)
    local chunks = MakeChunks(note.text)
    if #chunks > MAX_PARTS then Say("La nota e' troppo lunga per essere condivisa.") return end
    local id = string.format("%d%03d", time() % 100000, math.random(0, 999))
    local tgt = (kind == "WHISPER") and target or nil
    queue[#queue + 1] = { channel = channel, target = tgt, gid = gid, msg = "S\t" .. id .. "\t" .. #chunks .. "\t" .. Enc(title) }
    for i, c in ipairs(chunks) do
        queue[#queue + 1] = { channel = channel, target = tgt, gid = gid, msg = "D\t" .. id .. "\t" .. i .. "\t" .. c }
    end
    if not ticker then ticker = C_Timer.NewTicker(0.15, Pump) end
    -- annuncio visibile (senza link) pronto nella chat giusta: basta premere Invio
    local text = UnitName("player") .. " ha condiviso la nota \"" .. title .. "\""
    ChatFrame_OpenChat(slash .. " " .. text:gsub("|", "||"), DEFAULT_CHAT_FRAME or ChatFrame1)
    -- whisper: invio automatico (party e gilda restano da confermare con Invio)
    if kind == "WHISPER" then
        local eb = ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow()
        if eb and eb:GetText() ~= "" then
            if ChatEdit_OnEnterPressed then
                ChatEdit_OnEnterPressed(eb)
            elseif ChatEdit_SendText then
                ChatEdit_SendText(eb, 1)
                ChatEdit_DeactivateChat(eb)
            end
        end
    end
end

-- ricezione -----------------------------------------------------------
StaticPopupDialogs["TavesNotes_RECEIVE"] = {
    text = "%s vuole condividere con te la nota \"%s\".\nVuoi salvarla?",
    button1 = "Salva",
    button2 = "Rifiuta",
    OnAccept = function(self, data)
        if not data or not db then return end
        local n = { id = NewId(), text = data.text, mod = Now() }
        table.insert(db.notes, n)
        if panel and listChild then Refresh() end
        Say("nota \"" .. data.title .. "\" salvata.")
    end,
    OnHide = function() openPopups = math.max(0, openPopups - 1) end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- cerca una nota con lo stesso titolo (prima riga) di quella ricevuta
local function FindByTitle(title)
    for _, n in ipairs(db.notes) do
        if TitleOf(n) == title then return n end
    end
end

StaticPopupDialogs["TavesNotes_REPLACE"] = {
    text = "%s ha aggiornato la nota \"%s\".\nVuoi sostituire la tua versione?",
    button1 = "Sostituisci",
    button2 = "Rifiuta",
    OnAccept = function(self, data)
        if not data or not db then return end
        local n = FindByTitle(data.title)
        if n then
            n.text = data.text
            n.mod = Now()
            if panel and listChild then
                if selectedId == n.id then Select(n.id) else Refresh() end
            end
            Say("nota \"" .. data.title .. "\" aggiornata.")
        else
            -- nel frattempo la nota e' stata eliminata: la salvo come nuova
            table.insert(db.notes, { id = NewId(), text = data.text, mod = Now() })
            if panel and listChild then Refresh() end
            Say("nota \"" .. data.title .. "\" salvata.")
        end
    end,
    OnHide = function() openPopups = math.max(0, openPopups - 1) end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

local function OnAddon(prefix, msg, channel, sender)
    if prefix ~= PREFIX or not db or not msg then return end
    if channel ~= "PARTY" and channel ~= "RAID" and channel ~= "GUILD" and channel ~= "INSTANCE_CHAT"
        and channel ~= "WHISPER" and channel ~= "BNET" then return end
    -- ignora i messaggi che ci tornano indietro dal nostro stesso invio
    local me = UnitName("player")
    local realm = GetNormalizedRealmName and GetNormalizedRealmName()
    local short = Ambiguate and Ambiguate(sender, "none") or sender
    if sender == me or short == me or (realm and sender == me .. "-" .. realm)
        or sender:match("^([^-]+)") == me and (not realm or sender:match("%-(.+)$") == realm)
        or UnitIsUnit(sender, "player") then
        return
    end
    local kind, id, b, c = strsplit("\t", msg, 4)
    if not id then return end
    local key = sender .. "-" .. id
    if kind == "S" then
        local n = tonumber(b)
        if not n or n < 1 or n > MAX_PARTS then return end
        local now = GetTime()
        for k, e in pairs(incoming) do
            if now - e.t > 120 then incoming[k] = nil end
        end
        incoming[key] = { n = n, got = 0, parts = {}, title = Dec(c or ""), sender = short, t = now }
    elseif kind == "D" then
        local e = incoming[key]
        local idx = tonumber(b)
        if not e or not idx or idx < 1 or idx > e.n or e.parts[idx] then return end
        e.parts[idx] = c or ""
        e.got = e.got + 1
        if e.got == e.n then
            incoming[key] = nil
            if openPopups >= 5 then return end
            local text = Dec(table.concat(e.parts))
            if #text > 20000 then return end
            openPopups = openPopups + 1
            local which = FindByTitle(e.title) and "TavesNotes_REPLACE" or "TavesNotes_RECEIVE"
            StaticPopup_Show(which, e.sender, (e.title:gsub("|", "||")), { text = text, title = e.title })
        end
    end
end

-- menu tasto destro sulla nota ------------------------------------------
local menus, menuCatcher = {}, nil   -- menus[0] = principale, [1] e [2] = tendine
local MAX_FRIENDS = 25

local function HideFrom(level)
    for l = level, 2 do
        if menus[l] then menus[l]:Hide() end
    end
end

local function CloseMenus()
    HideFrom(0)
    if menuCatcher then menuCatcher:Hide() end
end

local function OpenSub(b)
    local level = b:GetParent().level
    local child = menus[level + 1]
    if not child then return end
    HideFrom(level + 2)
    local defs = b.def.sub
    if type(defs) == "function" then defs = defs() end
    child:Set(defs)
    child:ClearAllPoints()
    child:SetPoint("TOPLEFT", b, "TOPRIGHT", 4, 6)
    child:Show()
end

-- amici online (per "Condividi in whisper")
local function FriendsMenu(note)
    local list, seen = {}, {}
    local function Add(target, label, gid, acct)
        local key = (label or target):lower()
        if seen[key] or #list >= MAX_FRIENDS then return end
        seen[key] = true
        list[#list + 1] = {
            text = label or target,
            func = function() ShareNote(note, "WHISPER", target, gid, acct) end,
        }
    end

    -- amici del gioco
    local num = (C_FriendList and C_FriendList.GetNumFriends and C_FriendList.GetNumFriends())
        or (GetNumFriends and GetNumFriends()) or 0
    for i = 1, num do
        local name, online
        if C_FriendList and C_FriendList.GetFriendInfoByIndex then
            local info = C_FriendList.GetFriendInfoByIndex(i)
            if info then name, online = info.name, info.connected end
        elseif GetFriendInfo then
            local n, _, _, _, c = GetFriendInfo(i)
            name, online = n, c
        end
        if name and online then Add(name) end
    end

    -- amici Battle.net online che stanno giocando a WoW (stessa versione del gioco)
    if C_BattleNet and C_BattleNet.GetFriendAccountInfo and BNGetNumFriends then
        local myRealm = GetNormalizedRealmName and GetNormalizedRealmName()
        local total = BNGetNumFriends()
        for i = 1, total do
            local acc = C_BattleNet.GetFriendAccountInfo(i)
            local g = acc and acc.gameAccountInfo
            if g and g.isOnline and g.clientProgram == "WoW" and g.characterName and g.characterName ~= ""
                and (not WOW_PROJECT_ID or not g.wowProjectID or g.wowProjectID == WOW_PROJECT_ID) then
                -- si identifica il personaggio e si usa il whisper normale del gioco
                -- (con il reame solo se e' diverso dal mio)
                local target = g.characterName
                local realm = g.realmName and g.realmName:gsub("[%s%-]", "")
                if myRealm and realm and realm ~= "" and realm:lower() ~= myRealm:lower() then
                    target = target .. "-" .. realm
                end
                Add(target, g.characterName)
            end
        end
    end
    if #list == 0 then list[1] = { text = "Nessun amico online" } end
    return list
end

local function NewMenu(level)
    local m = CreateFrame("Frame", nil, UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    m:SetFrameStrata("DIALOG")
    m:SetFrameLevel(30 + level * 10)
    m:SetClampedToScreen(true)
    m:EnableMouse(true)
    if m.SetBackdrop then
        m:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 14,
            insets = { left = 4, right = 4, top = 4, bottom = 4 },
        })
        m:SetBackdropColor(0, 0, 0, 1)
    end
    m:Hide()
    m.level = level
    m.items = {}
    function m:Set(defs)
        for i, def in ipairs(defs) do
            local b = self.items[i]
            if not b then
                b = CreateFrame("Button", nil, self)
                b:SetHeight(22)
                b:SetPoint("TOPLEFT", 6, -6 - (i - 1) * 22)
                b:SetPoint("TOPRIGHT", -6, -6 - (i - 1) * 22)
                b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
                b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
                b.text:SetPoint("LEFT", 4, 0)
                b.arrow = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
                b.arrow:SetPoint("RIGHT", -4, 0)
                b.arrow:SetText(">")
                b:SetScript("OnClick", function(s)
                    if s.def.sub then
                        OpenSub(s)
                    elseif s.def.func then
                        CloseMenus()
                        s.def.func()
                    end
                end)
                b:SetScript("OnEnter", function(s)
                    if s.def.sub then
                        OpenSub(s)
                    else
                        HideFrom(s:GetParent().level + 1)
                    end
                end)
                self.items[i] = b
            end
            b.def = def
            b.text:SetText(def.text)
            b.arrow:SetShown(def.sub ~= nil)
            b:Show()
        end
        for i = #defs + 1, #self.items do self.items[i]:Hide() end
        self:SetSize(170, 12 + #defs * 22)
    end
    return m
end

function ShowNoteMenu(id)
    if not menus[0] then
        menuCatcher = CreateFrame("Button", nil, UIParent)
        menuCatcher:SetAllPoints(UIParent)
        menuCatcher:SetFrameStrata("DIALOG")
        menuCatcher:SetFrameLevel(1)
        menuCatcher:RegisterForClicks("AnyUp")
        menuCatcher:SetScript("OnClick", CloseMenus)
        menuCatcher:Hide()
        for l = 0, 2 do menus[l] = NewMenu(l) end
    end
    Select(id)
    local note = FindNote(id)
    if not note then return end
    local noteMenu = menus[0]
    noteMenu:Set({
        { text = "Condividi nota", sub = {
            { text = "Condividi in party", func = function() ShareNote(note, "PARTY") end },
            { text = "Condividi in gilda", func = function() ShareNote(note, "GUILD") end },
            { text = "Condividi in whisper", sub = function() return FriendsMenu(note) end },
        } },
        { text = "Elimina nota", func = function()
            if not FindNote(selectedId) then return end
            if (note.text or ""):match("^%s*$") then
                StaticPopupDialogs["TavesNotes_DELETE"].OnAccept()
            else
                StaticPopup_Show("TavesNotes_DELETE")
            end
        end },
    })
    HideFrom(1)
    local x, y = GetCursorPosition()
    local s = UIParent:GetEffectiveScale()
    noteMenu:ClearAllPoints()
    noteMenu:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x / s, y / s)
    menuCatcher:Show()
    noteMenu:Show()
end

---------------------------------------------------------------------
-- Pannello Note (figlio della finestra di chat: segue scheda, posizione e misure)
---------------------------------------------------------------------
local function BuildPanel()
    panel = CreateFrame("Frame", "TavesNotesPanel", chatFrame)
    panel:SetAllPoints(chatFrame)
    panel:SetFrameLevel(chatFrame:GetFrameLevel() + 20)
    panel:EnableMouse(true)

    local bg = panel:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.04, 0.04, 0.04, 0.95)

    -- barra superiore
    local btnNew = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    btnNew:SetSize(26, 20)
    btnNew:SetPoint("TOPLEFT", 4, -4)
    btnNew:SetText("+")

    info = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    info:SetPoint("TOPRIGHT", -6, -9)

    -- lista (sinistra)
    local listScroll = CreateFrame("ScrollFrame", "TavesNotesListScroll", panel, "UIPanelScrollFrameTemplate")
    listScroll:SetPoint("TOPLEFT", 4, -28)
    listScroll:SetPoint("BOTTOMLEFT", 4, 4)
    listScroll:SetWidth(LIST_W)
    listChild = CreateFrame("Frame", nil, listScroll)
    listChild:SetSize(LIST_W, 10)
    listScroll:SetScrollChild(listChild)

    -- editor (destra)
    bodyScroll = CreateFrame("ScrollFrame", "TavesNotesBodyScroll", panel, "UIPanelScrollFrameTemplate")
    bodyScroll:SetPoint("TOPLEFT", listScroll, "TOPRIGHT", 30, 0)
    bodyScroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -26, 4)

    body = CreateFrame("EditBox", "TavesNotesBody", bodyScroll)
    body:SetMultiLine(true)
    body:SetAutoFocus(false)
    body:SetFontObject("ChatFontNormal")
    body:SetWidth(200)
    body:SetTextInsets(4, 4, 4, 4)
    body:SetMaxLetters(8000)
    bodyScroll:SetScrollChild(body)
    bodyScroll:SetScript("OnSizeChanged", function(_, w) body:SetWidth(math.max(50, w - 4)) end)
    body:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    body:SetScript("OnCursorChanged", function(self, x, y, w, h)
        local sf = self:GetParent()
        local top = sf:GetVerticalScroll()
        local bottom = top + sf:GetHeight()
        y = -y
        if y < top then
            sf:SetVerticalScroll(y)
        elseif y + h > bottom then
            sf:SetVerticalScroll(y + h - sf:GetHeight())
        end
    end)
    bodyScroll:EnableMouse(true)
    bodyScroll:SetScript("OnMouseDown", function() body:SetFocus() end)

    local bodyBg = panel:CreateTexture(nil, "BACKGROUND", nil, 1)
    bodyBg:SetPoint("TOPLEFT", bodyScroll, -2, 2)
    bodyBg:SetPoint("BOTTOMRIGHT", bodyScroll, 24, -2)
    bodyBg:SetColorTexture(0, 0, 0, 0.35)

    body:SetScript("OnTextChanged", function(self, userInput)
        if self.loading or not userInput then return end
        local n = FindNote(selectedId)
        if not n then return end
        n.text = self:GetText()
        n.mod = Now()
        Refresh()
    end)

    btnNew:SetScript("OnClick", function()
        local n = CreateNote()
        Select(n.id)
        body:SetFocus()
    end)

    panel:SetScript("OnShow", function()
        Select(selectedId or db.selected)
    end)
    panel:SetScript("OnHide", function()
        body:ClearFocus()
        -- elimina eventuale nota vuota lasciata aperta
        local cur = FindNote(selectedId)
        if cur and (cur.text or ""):match("^%s*$") and #db.notes > 1 then
            local _, idx = FindNote(cur.id)
            table.remove(db.notes, idx)
            selectedId = nil
        end
    end)

    -----------------------------------------------------------------
    -- Tasto destro sul testo selezionato -> "Link to chat"
    -----------------------------------------------------------------
    -- WoW non espone il testo selezionato di un EditBox: lo ricavo togliendolo
    -- con Insert(""), confrontando i testi e poi ripristinando testo e selezione.
    local function GetSelection()
        local text = body:GetText()
        if text == "" then return nil end
        local vs = bodyScroll:GetVerticalScroll()
        body.loading = true
        body:Insert("")
        local after = body:GetText()
        local diff = #text - #after
        local sel, selStart, selEnd
        if diff > 0 then
            local i = 1
            while i <= #after and text:byte(i) == after:byte(i) do i = i + 1 end
            -- allinea all'inizio di un carattere UTF-8
            while i > 1 do
                local b = text:byte(i)
                if b and b >= 0x80 and b <= 0xBF then i = i - 1 else break end
            end
            sel = text:sub(i, i + diff - 1)
            body:SetText(text)
            local s = strlenutf8(text:sub(1, i - 1))
            local e = s + strlenutf8(sel)
            body:SetCursorPosition(e)
            body:HighlightText(s, e)
            bodyScroll:SetVerticalScroll(vs)
            selStart, selEnd = s, e
        end
        body.loading = false
        if sel and sel:match("^%s*$") then return nil end
        return sel, selStart, selEnd
    end

    local function LinkToChat(text)
        text = text:gsub("%s+", " "):match("^%s*(.-)%s*$")
        if text == "" then return end
        text = text:gsub("|", "||")
        if #text > 255 then text = text:sub(1, 255) end
        ChatFrame_OpenChat(text, DEFAULT_CHAT_FRAME or ChatFrame1)
    end

    local menu = CreateFrame("Frame", nil, UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    menu:SetFrameStrata("DIALOG")
    menu:SetFrameLevel(20)
    menu:SetClampedToScreen(true)
    menu:SetSize(130, 30)
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

    local catcher = CreateFrame("Button", nil, UIParent)
    catcher:SetAllPoints(UIParent)
    catcher:SetFrameStrata("DIALOG")
    catcher:SetFrameLevel(1)
    catcher:RegisterForClicks("AnyUp")
    catcher:Hide()
    catcher:SetScript("OnClick", function() menu:Hide() end)
    menu:SetScript("OnShow", function() catcher:Show() end)
    menu:SetScript("OnHide", function() catcher:Hide() end)
    panel:HookScript("OnHide", function() menu:Hide() end)

    local item = CreateFrame("Button", nil, menu)
    item:SetPoint("TOPLEFT", 6, -5)
    item:SetPoint("BOTTOMRIGHT", -6, 5)
    item:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    local itemText = item:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    itemText:SetPoint("LEFT", 4, 0)
    itemText:SetText("Link to chat")
    item:SetScript("OnClick", function()
        menu:Hide()
        if menu.text then LinkToChat(menu.text) end
    end)

    -- ripristina la selezione (il clic destro del motore di gioco la toglierebbe)
    local function Reselect(s, e)
        local vs = bodyScroll:GetVerticalScroll()
        body:SetFocus()
        body:SetCursorPosition(e)
        body:HighlightText(s, e)
        bodyScroll:SetVerticalScroll(vs)
    end

    -- doppio clic: seleziona la parola intera
    local lastClick, lastPos = 0, -1
    local function SelectWordAtCursor()
        local text = body:GetText()
        local chars = {}
        for ch in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do chars[#chars + 1] = ch end
        local function isWord(i)
            local ch = chars[i]
            return ch and not ch:match("^[%s%p]$")
        end
        local c = body:GetCursorPosition()
        local i
        if isWord(c + 1) then i = c + 1 elseif isWord(c) then i = c end
        if not i then return end
        local a, b = i, i
        while isWord(a - 1) do a = a - 1 end
        while isWord(b + 1) do b = b + 1 end
        Reselect(a - 1, b)
        C_Timer.After(0, function() Reselect(a - 1, b) end)
    end

    local pending, pendS, pendE
    body:SetScript("OnMouseDown", function(_, button)
        if button == "RightButton" then pending, pendS, pendE = GetSelection() end
    end)
    body:SetScript("OnMouseUp", function(_, button)
        if button == "LeftButton" then
            local now, pos = GetTime(), body:GetCursorPosition()
            if now - lastClick < 0.4 and pos == lastPos then
                lastClick = 0
                SelectWordAtCursor()
            else
                lastClick, lastPos = now, pos
            end
            return
        end
        if button ~= "RightButton" or not pending then return end
        menu.text = pending
        if pendS then
            local s, e = pendS, pendE
            Reselect(s, e)
            C_Timer.After(0, function() Reselect(s, e) end)
        end
        pending = nil
        local x, y = GetCursorPosition()
        local s = UIParent:GetEffectiveScale()
        menu:ClearAllPoints()
        menu:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x / s, y / s)
        menu:Show()
    end)

    if panel:IsVisible() then panel:GetScript("OnShow")() end
end

---------------------------------------------------------------------
-- Scheda di chat "Note"
---------------------------------------------------------------------
local function FindChatFrame()
    for i = 1, (NUM_CHAT_WINDOWS or 10) do
        local name, _, _, _, _, _, shown, _, docked = GetChatWindowInfo(i)
        -- una finestra chiusa (non visibile e non agganciata) non conta
        if name == TAB_NAME and (shown or docked) then
            return _G["ChatFrame" .. i]
        end
    end
end

-- true se la finestra Note e' stata chiusa dall'utente
local function IsClosed(frame)
    local _, _, _, _, _, _, shown, _, docked = GetChatWindowInfo(frame:GetID())
    return not shown and not docked
end

-- Riapre la scheda Note dopo un "Chiudi finestra" e riaggancia il pannello
local function Reopen()
    local new = FCF_OpenNewWindow(TAB_NAME)
    if not new then return end
    if ChatFrame_RemoveAllMessageGroups then ChatFrame_RemoveAllMessageGroups(new) end
    if ChatFrame_RemoveAllChannels then ChatFrame_RemoveAllChannels(new) end
    chatFrame = new
    panel:SetParent(new)
    panel:ClearAllPoints()
    panel:SetAllPoints(new)
    panel:SetFrameLevel(new:GetFrameLevel() + 20)
end

local function SelectFrame(frame)
    if FCF_SelectDockFrame then
        FCF_SelectDockFrame(frame)
    else
        local tab = _G[frame:GetName() .. "Tab"]
        if tab then tab:Click() end
    end
end

-- Angolino in alto a destra per ridimensionare la finestra di chat
local function AddGrip(frame)
    if not frame or frame.tavesGrip then return end
    local g = CreateFrame("Button", nil, frame)
    g:SetSize(16, 16)
    g:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    g:SetFrameLevel(frame:GetFrameLevel() + 40)
    -- la texture di Blizzard e' per l'angolo in basso a destra: la rovescio in verticale
    g:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    g:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    g:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    for _, t in ipairs({ g:GetNormalTexture(), g:GetPushedTexture(), g:GetHighlightTexture() }) do
        t:SetTexCoord(0, 1, 1, 0)
    end
    -- Ridimensionamento manuale: agisce sempre sulla finestra principale del dock
    -- (General) se la scheda e' agganciata, cosi' tutte le schede hanno la stessa misura.
    local function Target()
        local dock = _G.GENERAL_CHAT_DOCK
        if frame.isDocked and dock and dock.primary then return dock.primary end
        return frame
    end
    local function Stop(self)
        self:SetScript("OnUpdate", nil)
        if not self.sizing then return end
        self.sizing = nil
        local t = Target()
        if FCF_SavePositionAndDimensions then FCF_SavePositionAndDimensions(t) end
        if t ~= frame and FCF_SavePositionAndDimensions then FCF_SavePositionAndDimensions(frame) end
        if FCF_DockUpdate then FCF_DockUpdate() end
        if db then db.height = t:GetHeight() end
    end
    g:SetScript("OnMouseDown", function(self)
        local t = Target()
        local cx, cy = GetCursorPosition()
        self.sizing = { t = t, cx = cx, cy = cy, w = t:GetWidth(), h = t:GetHeight(), s = t:GetEffectiveScale() }
        self:SetScript("OnUpdate", function(s)
            local st = s.sizing
            if not st then return end
            local x, y = GetCursorPosition()
            local w = math.max(120, st.w + (x - st.cx) / st.s)
            local h = math.max(60, st.h + (y - st.cy) / st.s)
            st.t:SetSize(w, h)
        end)
    end)
    g:SetScript("OnMouseUp", Stop)
    g:SetScript("OnHide", Stop)
    g:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Trascina per ridimensionare la chat")
        GameTooltip:Show()
    end)
    g:SetScript("OnLeave", function() GameTooltip:Hide() end)
    frame.tavesGrip = g
end

local function AddAllGrips()
    for i = 1, (NUM_CHAT_WINDOWS or 10) do
        AddGrip(_G["ChatFrame" .. i])
    end
end

-- Altezza della chat: la prima volta raddoppia quella attuale, poi la ricorda
-- (anche dopo /reload) e la applica a tutte le schede agganciate.
local function ApplyHeight()
    if not db or not ChatFrame1 then return end
    if not db.height then
        db.height = ChatFrame1:GetHeight() * 2
    end
    local h = math.min(db.height, UIParent:GetHeight() * 0.7)
    for i = 1, (NUM_CHAT_WINDOWS or 10) do
        local f = _G["ChatFrame" .. i]
        if f and (f == ChatFrame1 or f.isDocked) then
            f:SetHeight(h)
            if FCF_SavePositionAndDimensions then FCF_SavePositionAndDimensions(f) end
        end
    end
    if FCF_DockUpdate then FCF_DockUpdate() end
end

local function Setup()
    if panel then return end
    ApplyHeight()
    AddAllGrips()
    -- finestre aperte in seguito (es. nuove schede) ricevono la maniglia
    if FCF_OpenNewWindow and not TavesNotes_HookedOpen then
        TavesNotes_HookedOpen = true
        hooksecurefunc("FCF_OpenNewWindow", function() AddAllGrips() end)
    end
    chatFrame = FindChatFrame()
    if not chatFrame then
        chatFrame = FCF_OpenNewWindow(TAB_NAME)
        if not chatFrame then return end
        -- la scheda Note non deve ricevere messaggi
        if ChatFrame_RemoveAllMessageGroups then ChatFrame_RemoveAllMessageGroups(chatFrame) end
        if ChatFrame_RemoveAllChannels then ChatFrame_RemoveAllChannels(chatFrame) end
        if ChatFrame1 then SelectFrame(ChatFrame1) end
    end
    AddAllGrips()
    BuildPanel()
end

local function Toggle()
    if not panel then Setup() end
    if not panel then return end
    if IsClosed(chatFrame) then
        Reopen()
        AddGrip(chatFrame)
        SelectFrame(chatFrame)
        return
    end
    if panel:IsVisible() then
        SelectFrame(ChatFrame1)
    else
        SelectFrame(chatFrame)
    end
end
TavesNotes_Toggle = Toggle

if TavesMenu then
    TavesMenu.Register("notes", "TavesNotes", "Interface\\Icons\\INV_Misc_Note_01", Toggle)
end

---------------------------------------------------------------------
-- Init
---------------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("CHAT_MSG_ADDON")
ev:RegisterEvent("BN_CHAT_MSG_ADDON")
ev:SetScript("OnEvent", function(self, event, ...)
    if event == "CHAT_MSG_ADDON" then
        OnAddon(...)
    elseif event == "BN_CHAT_MSG_ADDON" then
        local prefix, text, _, senderID = ...
        if prefix ~= PREFIX then return end
        local name
        if C_BattleNet and C_BattleNet.GetAccountInfoByID then
            local acc = C_BattleNet.GetAccountInfoByID(senderID)
            if acc then name = (acc.gameAccountInfo and acc.gameAccountInfo.characterName) or acc.accountName end
        end
        if not name and C_BattleNet and C_BattleNet.GetGameAccountInfoByID then
            local g = C_BattleNet.GetGameAccountInfoByID(senderID)
            if g then name = g.characterName end
        end
        OnAddon(prefix, text, "BNET", name or ("bn" .. tostring(senderID)))
    elseif event == "PLAYER_LOGIN" then
        if RegisterPrefix then RegisterPrefix(PREFIX) end
        -- migra le note dalle versioni precedenti: quando le note stavano in TavesChat
        -- (TavesChatDB), poi TaverNotes / ChatNotes. Le variabili vecchie sono ancora
        -- dichiarate dal toc di TavesChat, quindi qui sono gia' caricate.
        TavesNotesDB = TavesNotesDB or TavesChatDB or TaverNotesDB or ChatNotesDB or {}
        TavesChatDB, TaverNotesDB, ChatNotesDB = nil, nil, nil
        db = TavesNotesDB
        db.notes = db.notes or {}
        if #db.notes == 0 then CreateNote() end
        selectedId = db.selected
    else
        self:UnregisterEvent("PLAYER_ENTERING_WORLD")
        -- aspetta che le finestre di chat siano caricate
        C_Timer.After(1, Setup)
    end
end)

SLASH_TavesNotes1 = "/note"
SLASH_TavesNotes2 = "/notes"
SlashCmdList["TavesNotes"] = Toggle
