-- TavesChat: scheda "Chat": una chat di gruppo condivisa tra amici.
-- Trasporto: messaggi di addon in WHISPER (nascosti), un invio per ogni membro.
-- Comando: /tchat

local TAB_NAME = "Chat"
local PREFIX = "TavesChatG"
local RegisterPrefix = (C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix) or RegisterAddonMessagePrefix
local SendAddon = (C_ChatInfo and C_ChatInfo.SendAddonMessage) or SendAddonMessage

local CHUNK = 170        -- byte codificati per messaggio (il limite del gioco e' 255)
local MAX_MSGS = 200     -- messaggi conservati
local MAX_HIST = 30      -- messaggi inviati a chi chiede lo storico

local db, chatFrame, panel
local smf, input, title, emptyText, btnAdd, btnMembers, btnLeave
local me, meKey
local seen = {}
local lastDay
local UpdateUI, Render

---------------------------------------------------------------------
-- Utilita'
---------------------------------------------------------------------
local function Say(msg) DEFAULT_CHAT_FRAME:AddMessage("|cffffd100TavesChat:|r " .. msg) end

local function Enc(s)
    return (s:gsub("[%%\t\n\r|%z]", function(c) return string.format("%%%02X", c:byte()) end))
end
local function Dec(s)
    return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local function Short(name)
    if not name then return "" end
    return Ambiguate and Ambiguate(name, "none") or name
end
local function Key(name) return Short(name):lower() end
-- nome da mostrare: senza il reame
local function Label(name)
    local s = Short(name)
    return s:match("^([^%-]+)") or s
end

-- /tchat debug: stampa ogni invio/ricezione, per capire dove si ferma un messaggio
local debugOn = false
local function Dbg(msg)
    if debugOn then DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffTavesChat debug:|r " .. msg) end
end

-- nome completo con reame (per scambiarlo con persone di altri reami collegati)
local function Full(name)
    if name:find("-", 1, true) then return name end
    local r = GetNormalizedRealmName and GetNormalizedRealmName()
    return r and (name .. "-" .. r) or name
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

---------------------------------------------------------------------
-- Amici (solo quelli online: i whisper non arrivano agli offline)
---------------------------------------------------------------------
-- Nome di un personaggio Battle.net come lo usiamo noi (con reame se e' diverso dal mio)
local function BNetName(g)
    local target = g.characterName
    local realm = g.realmName and g.realmName:gsub("[%s%-]", "")
    local myRealm = GetNormalizedRealmName and GetNormalizedRealmName()
    if realm and realm ~= "" and realm ~= myRealm then target = target .. "-" .. realm end
    return target
end

-- ritorna: lista dei nomi online, mappa nome(minuscolo) -> true/false,
-- mappa nome(minuscolo) -> gameAccountID (amici Battle.net: invio diretto, anche tra fazioni)
local scanCache
local function ScanFriends()
    if scanCache and GetTime() - scanCache.t < 1 then
        return scanCache.online, scanCache.known, scanCache.gids, scanCache.accs
    end
    local online, known, listed, gids, accs = {}, {}, {}, {}, {}
    local function Add(name, gid, acct)
        local k = Key(name)
        known[k] = true
        if gid then gids[k] = gid end
        if acct then accs[k] = acct end
        if not listed[k] then
            listed[k] = true
            online[#online + 1] = Short(name)
        end
    end

    local num = (C_FriendList and C_FriendList.GetNumFriends and C_FriendList.GetNumFriends())
        or (GetNumFriends and GetNumFriends()) or 0
    for i = 1, num do
        local name, conn
        if C_FriendList and C_FriendList.GetFriendInfoByIndex then
            local info = C_FriendList.GetFriendInfoByIndex(i)
            if info then name, conn = info.name, info.connected end
        elseif GetFriendInfo then
            local n, _, _, _, c = GetFriendInfo(i)
            name, conn = n, c
        end
        if name then
            if conn then Add(name) elseif known[Key(name)] == nil then known[Key(name)] = false end
        end
    end

    if C_BattleNet and C_BattleNet.GetFriendAccountInfo and BNGetNumFriends then
        for i = 1, BNGetNumFriends() do
            local acc = C_BattleNet.GetFriendAccountInfo(i)
            local g = acc and acc.gameAccountInfo
            if g and g.isOnline and g.clientProgram == "WoW" and g.characterName and g.characterName ~= ""
                and (not WOW_PROJECT_ID or not g.wowProjectID or g.wowProjectID == WOW_PROJECT_ID) then
                Add(BNetName(g))   -- nome del personaggio (con reame se diverso dal mio)
            end
        end
    end
    scanCache = { t = GetTime(), online = online, known = known, gids = gids, accs = accs }
    return online, known, gids, accs
end

-- true = online, false = amico offline, nil = non lo so (non e' un mio amico)
local function IsOnline(name)
    local _, known = ScanFriends()
    return known[Key(name)]
end

---------------------------------------------------------------------
-- Invio (coda: un messaggio ogni 0.15s, riprova se il gioco rallenta)
---------------------------------------------------------------------
local queue, ticker = {}, nil
local function Pump()
    local m = queue[1]
    if not m then
        if ticker then ticker:Cancel() ticker = nil end
        return
    end
    -- sempre whisper al nome del personaggio (anche per gli amici Battle.net)
    -- il whisper va al solo nome del personaggio, senza il reame
    local r = SendAddon(PREFIX, m.msg, "WHISPER", Label(m.target))
    Dbg("invio " .. m.msg:sub(1, 1) .. " a '" .. Label(m.target) .. "' (whisper) -> risultato " .. tostring(r))
    local failed = (r == false) or (type(r) == "number" and r ~= 0)
    if failed then
        m.tries = (m.tries or 0) + 1
        if m.tries > 20 then table.remove(queue, 1) end
    else
        table.remove(queue, 1)
    end
end

local function Send(target, msg)
    queue[#queue + 1] = { target = target, msg = msg }
    if not ticker then ticker = C_Timer.NewTicker(0.15, Pump) end
end

-- whisper normale, visibile all'altro: lo avvisa dell'invito anche se non ha l'addon
local function VisibleWhisper(target, text)
    Dbg("whisper visibile a '" .. Label(target) .. "'")
    pcall(SendChatMessage, text, "WHISPER", nil, Label(target))
end

local function Broadcast(msg)
    local c = db.chat
    if not c then return end
    local known
    for _, m in ipairs(c.members) do
        if Key(m) ~= meKey then
            if not known then local _, k = ScanFriends() known = k end
            if known[Key(m)] ~= false then Send(m, msg) end
        end
    end
end

---------------------------------------------------------------------
-- Stato della chat
---------------------------------------------------------------------
local function IsMember(name)
    local c = db.chat
    if not c then return false end
    local k = Key(name)
    for _, m in ipairs(c.members) do
        if m:lower() == k then return true end
    end
    return false
end

local function AddMember(name)
    name = Short(name)
    if name == "" then return end
    if not IsMember(name) then table.insert(db.chat.members, name) end
    db.chat.gone[Key(name)] = nil
end

local function RemoveMember(name)
    local c, k = db.chat, Key(name)
    for i, m in ipairs(c.members) do
        if m:lower() == k then table.remove(c.members, i) break end
    end
    c.gone[k] = true
end

local function RebuildSeen()
    seen = {}
    if db and db.chat then
        for _, m in ipairs(db.chat.msgs) do seen[m.id] = true end
    end
end

---------------------------------------------------------------------
-- Messaggi
---------------------------------------------------------------------
local function FormatLine(m)
    local text = (m.text or ""):gsub("[\r\n]+", " "):gsub("|", "||")
    if m.sys then
        return "|cff8a8a8a- " .. text .. " -|r"
    end
    local ts = "|cff8a8a8a" .. date("%H:%M", m.t) .. "|r "
    if Key(m.from) == meKey then
        return ts .. "|cff7fd67fTu|r: |cffdfffdf" .. text .. "|r"
    end
    return ts .. "|cffffd100" .. Label(m.from):gsub("|", "||") .. "|r: " .. text
end

local function AddLine(m)
    local day = date("%d/%m/%Y", m.t)
    if day ~= lastDay then
        lastDay = day
        smf:AddMessage("|cff8a8a8a--- " .. day .. " ---|r")
    end
    smf:AddMessage(FormatLine(m))
end

function Render()
    if not smf then return end
    smf:Clear()
    lastDay = nil
    local c = db and db.chat
    if not c then return end
    for _, m in ipairs(c.msgs) do AddLine(m) end
end

local function AddMsg(m)
    local c = db.chat
    if not c or seen[m.id] then return end
    seen[m.id] = true
    local msgs = c.msgs
    local pos = #msgs + 1
    while pos > 1 and msgs[pos - 1].t > m.t do pos = pos - 1 end
    table.insert(msgs, pos, m)
    while #msgs > MAX_MSGS do
        local old = table.remove(msgs, 1)
        seen[old.id] = nil
    end
    local visible = panel and panel:IsVisible()
    if visible then
        if pos == #msgs then AddLine(m) else Render() end
    elseif not m.sys and Key(m.from) ~= meKey and chatFrame and FCF_StartAlertFlash then
        FCF_StartAlertFlash(chatFrame)   -- fa lampeggiare la scheda
    end
end

local function AddSys(text)
    AddMsg({ id = "sys" .. time() .. math.random(1000, 9999), sys = true, t = time(), text = text })
end

local function SendText(text)
    local c = db.chat
    if not c then return end
    text = (text or ""):match("^%s*(.-)%s*$")
    if text == "" then return end
    for _, chunk in ipairs(MakeChunks(text)) do
        c.n = (c.n or 0) + 1
        local idnum = time() .. "." .. c.n
        AddMsg({ id = meKey .. "-" .. idnum, from = me, t = time(), text = Dec(chunk) })
        Broadcast("M\t" .. c.id .. "\t" .. idnum .. "\t" .. chunk)
    end
end

---------------------------------------------------------------------
-- Azioni: invitare, rimuovere, uscire
---------------------------------------------------------------------
-- inviti in attesa di conferma di ricezione (chiave = nome in minuscolo)
local pending = {}

local function Invite(target)
    if not db.chat then
        db.chat = {
            id = tostring(math.random(10000000, 99999999)),
            members = { me }, gone = {}, msgs = {}, n = 0,
        }
        RebuildSeen()
    end
    local c = db.chat
    if IsMember(target) then AddSys(Label(target) .. " e' gia' nella chat.") return end
    local full = {}
    for _, m in ipairs(c.members) do full[#full + 1] = Full(m) end
    local csv = Enc(table.concat(full, ","))
    if #csv > 200 then AddSys("La chat ha troppi membri per poter invitare altre persone.") return end
    -- 1) dati dell'invito (nascosti, li legge l'addon dell'amico)
    Send(target, "I\t" .. c.id .. "\t" .. csv)
    -- 2) whisper visibile, cosi' l'amico sa dell'invito e tu vedi che e' partito
    VisibleWhisper(target, Label(me) .. " ti ha invitato in una chat di gruppo (addon TavesChat). Se hai l'addon aggiornato ti compare la richiesta per entrare.")
    AddSys("Invito inviato a " .. Label(target) .. " (whisper a '" .. Label(target) .. "').")
    -- l'addon dell'amico risponde subito con una conferma: se non arriva, te lo dico
    local k, id = Key(target), c.id
    if pending[k] then pending[k].timer:Cancel() end
    pending[k] = {
        id = id, name = target,
        timer = C_Timer.NewTimer(8, function()
            pending[k] = nil
            if db.chat and db.chat.id == id and not IsMember(target) then
                AddSys("Nessuna risposta da " .. Label(target) .. ": non ha TavesChat aggiornato, oppure il whisper non lo raggiunge (fazione o reame diversi).")
            end
        end),
    }
    UpdateUI()
end

local function Kick(target)
    local c = db.chat
    if not c or Key(target) == meKey or not IsMember(target) then return end
    Broadcast("K\t" .. c.id .. "\t" .. Enc(Full(target)))   -- compreso chi viene rimosso
    RemoveMember(target)
    AddSys("Hai rimosso " .. Label(target) .. " dalla chat.")
    UpdateUI()
end

local function LeaveLocal(reason)
    db.chat = nil
    seen = {}
    if reason then Say(reason) end
    if smf then smf:Clear() end
    UpdateUI()
end

local function Leave()
    local c = db.chat
    if not c then return end
    Broadcast("L\t" .. c.id)
    LeaveLocal("hai lasciato la chat.")
end

---------------------------------------------------------------------
-- Popup
---------------------------------------------------------------------
local openPopups = 0

StaticPopupDialogs["TavesChatG_INVITE"] = {
    text = "%s ti invita in una chat di gruppo.\nVuoi entrare?",
    button1 = "Entra",
    button2 = "Rifiuta",
    OnAccept = function(self, data)
        if not data or not db or db.chat then return end
        local members = {}
        for name in data.members:gmatch("[^,]+") do members[#members + 1] = Short(name) end
        db.chat = { id = data.id, members = members, gone = {}, msgs = {}, n = 0 }
        RebuildSeen()
        AddMember(me)
        if not data.from:match("^bn%d+$") then AddMember(data.from) end
        AddSys("Sei entrato nella chat.")
        Broadcast("J\t" .. data.id)
        Send(data.from, "H\t" .. data.id .. "\t0")
        UpdateUI()
        Render()
    end,
    OnHide = function() openPopups = math.max(0, openPopups - 1) end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

StaticPopupDialogs["TavesChatG_KICK"] = {
    text = "Rimuovere %s dalla chat?",
    button1 = YES,
    button2 = NO,
    OnAccept = function(self, data) if data and db then Kick(data) end end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

StaticPopupDialogs["TavesChatG_LEAVE"] = {
    text = "Vuoi lasciare la chat?",
    button1 = YES,
    button2 = NO,
    OnAccept = function() if db then Leave() end end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

---------------------------------------------------------------------
-- Ricezione
---------------------------------------------------------------------
local cooldown = {}

local function OnAddon(prefix, msg, channel, sender)
    if prefix ~= PREFIX or channel ~= "WHISPER" or not db or not msg or not sender then return end
    local from = Short(sender)
    Dbg("ricevuto " .. tostring(msg:sub(1, 1)) .. " da " .. from .. " [" .. channel .. "]")
    if Key(from) == meKey then return end
    local kind, a, b, c2, d, e = strsplit("\t", msg, 6)
    if not kind or not a then return end

    -- invito: arriva da chiunque
    if kind == "A" then   -- conferma: l'amico ha ricevuto il mio invito
        local p = pending[Key(from)]
        if p and p.id == a then
            p.timer:Cancel()
            pending[Key(from)] = nil
            AddSys(Label(from) .. " ha ricevuto l'invito.")
        end
        return
    end

    if kind == "I" then
        Send(from, "A\t" .. a)
        if db.chat then
            if db.chat.id ~= a then Say(from .. " ti ha invitato in una chat, ma sei gia' in una.") end
            return
        end
        if openPopups >= 3 or not b then return end
        openPopups = openPopups + 1
        StaticPopup_Show("TavesChatG_INVITE", from, nil, { from = from, id = a, members = Dec(b) })
        return
    end

    local c = db.chat
    if not c or c.id ~= a then return end

    if kind == "J" then
        if not IsMember(from) then
            AddMember(from)
            AddSys(Label(from) .. " e' entrato nella chat.")
            UpdateUI()
        end
        return
    end

    if not IsMember(from) then
        -- una persona che ho rimosso (o che ha lasciato) scrive ancora: la avviso
        if c.gone[Key(from)] then Send(from, "K\t" .. c.id .. "\t" .. Enc(Full(from))) end
        return
    end

    if kind == "M" then
        if not c2 or #c2 > 400 then return end
        AddMsg({ id = Key(from) .. "-" .. b, from = from, t = time(), text = Dec(c2) })

    elseif kind == "Y" then   -- storico: a=chat b=autore c2=id d=ora e=testo
        local t = tonumber(d)
        if not b or not c2 or not t or not e or #e > 400 then return end
        t = math.min(t, time())
        AddMsg({ id = Key(b) .. "-" .. c2, from = Short(Dec(b)), t = t, text = Dec(e) })

    elseif kind == "H" then   -- richiesta storico
        local now = GetTime()
        if cooldown[Key(from)] and now - cooldown[Key(from)] < 30 then return end
        cooldown[Key(from)] = now
        local since = tonumber(b) or 0
        local out = {}
        for _, m in ipairs(c.msgs) do
            if not m.sys and m.t >= since and #Enc(m.text) <= 180 then out[#out + 1] = m end
        end
        for i = math.max(1, #out - MAX_HIST + 1), #out do
            local m = out[i]
            local idnum = m.id:match("%-(.+)$")
            if idnum then
                Send(from, "Y\t" .. c.id .. "\t" .. Enc(Full(m.from)) .. "\t" .. idnum .. "\t" .. m.t .. "\t" .. Enc(m.text))
            end
        end

    elseif kind == "K" then
        local target = Short(Dec(b or ""))
        if target == "" then return end
        if Key(target) == meKey then
            LeaveLocal(Label(from) .. " ti ha rimosso dalla chat.")
        elseif IsMember(target) then
            RemoveMember(target)
            AddSys(Label(from) .. " ha rimosso " .. Label(target) .. " dalla chat.")
            UpdateUI()
        end

    elseif kind == "L" then
        RemoveMember(from)
        AddSys(Label(from) .. " ha lasciato la chat.")
        UpdateUI()
    end
end

-- all'accesso chiede ai membri online i messaggi persi
local function SyncRequest()
    local c = db and db.chat
    if not c then return end
    local since = 0
    for i = #c.msgs, 1, -1 do
        if not c.msgs[i].sys then since = c.msgs[i].t break end
    end
    Broadcast("H\t" .. c.id .. "\t" .. since)
end

---------------------------------------------------------------------
-- Menu a tendina semplice
---------------------------------------------------------------------
local menu, catcher

local function CloseMenu()
    if menu then menu:Hide() end
    if catcher then catcher:Hide() end
end

local function ShowMenu(anchor, defs)
    if not menu then
        catcher = CreateFrame("Button", nil, UIParent)
        catcher:SetAllPoints(UIParent)
        catcher:SetFrameStrata("DIALOG")
        catcher:SetFrameLevel(1)
        catcher:RegisterForClicks("AnyUp")
        catcher:SetScript("OnClick", CloseMenu)
        catcher:Hide()

        menu = CreateFrame("Frame", nil, UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
        menu:SetFrameStrata("DIALOG")
        menu:SetFrameLevel(30)
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
        menu.items = {}
    end
    for i, def in ipairs(defs) do
        local b = menu.items[i]
        if not b then
            b = CreateFrame("Button", nil, menu)
            b:SetHeight(22)
            b:SetPoint("TOPLEFT", 6, -6 - (i - 1) * 22)
            b:SetPoint("TOPRIGHT", -6, -6 - (i - 1) * 22)
            b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
            b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            b.text:SetPoint("LEFT", 4, 0)
            b:SetScript("OnClick", function(s)
                if s.def.disabled or not s.def.func then return end
                CloseMenu()
                s.def.func()
            end)
            menu.items[i] = b
        end
        b.def = def
        b.text:SetText(def.text)
        b:Show()
    end
    for i = #defs + 1, #menu.items do menu.items[i]:Hide() end
    local w = 140
    for i = 1, #defs do w = math.max(w, menu.items[i].text:GetStringWidth() + 24) end
    menu:SetSize(w, 12 + #defs * 22)
    menu:ClearAllPoints()
    menu:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
    catcher:Show()
    menu:Show()
end

local function FriendDefs()
    local online = ScanFriends()
    local defs = {}
    for _, name in ipairs(online) do
        if Key(name) ~= meKey and not IsMember(name) and #defs < 25 then
            defs[#defs + 1] = { text = Label(name), func = function() Invite(name) end }
        end
    end
    if #defs == 0 then defs[1] = { text = "Nessun amico online", disabled = true } end
    return defs
end

local function MemberDefs()
    local c = db.chat
    local _, known = ScanFriends()
    local defs = {}
    for _, name in ipairs(c.members) do
        if Key(name) == meKey then
            defs[#defs + 1] = { text = Label(name) .. " (tu)", disabled = true }
        else
            local col = (known[Key(name)] == true and "|cff33ff33") or (known[Key(name)] == false and "|cff808080") or "|cffffffff"
            defs[#defs + 1] = {
                text = col .. "Rimuovi " .. Label(name) .. "|r",
                func = function() StaticPopup_Show("TavesChatG_KICK", Label(name), nil, name) end,
            }
        end
    end
    return defs
end

---------------------------------------------------------------------
-- Pannello
---------------------------------------------------------------------
function UpdateUI()
    if not panel then return end
    local c = db and db.chat
    btnMembers:SetShown(c ~= nil)
    btnLeave:SetShown(c ~= nil)
    smf:SetShown(c ~= nil)
    input:SetShown(c ~= nil)
    emptyText:SetShown(c == nil)
    smf.bg:SetShown(c ~= nil)
    if c then
        local names = {}
        for _, m in ipairs(c.members) do
            if Key(m) ~= meKey then names[#names + 1] = Label(m) end
        end
        title:SetText(#names > 0 and ("con " .. table.concat(names, ", ")) or "solo tu")
    else
        title:SetText("")
    end
end

local function BuildPanel()
    panel = CreateFrame("Frame", "TavesChatPanel", chatFrame)
    panel:SetAllPoints(chatFrame)
    panel:SetFrameLevel(chatFrame:GetFrameLevel() + 20)
    panel:EnableMouse(true)

    local bg = panel:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.04, 0.04, 0.04, 0.95)

    btnAdd = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    btnAdd:SetSize(72, 20)
    btnAdd:SetPoint("TOPLEFT", 4, -4)
    btnAdd:SetText("Aggiungi")
    btnAdd:SetScript("OnClick", function(self) ShowMenu(self, FriendDefs()) end)

    btnMembers = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    btnMembers:SetSize(62, 20)
    btnMembers:SetPoint("LEFT", btnAdd, "RIGHT", 3, 0)
    btnMembers:SetText("Membri")
    btnMembers:SetScript("OnClick", function(self)
        if db.chat then ShowMenu(self, MemberDefs()) end
    end)

    btnLeave = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    btnLeave:SetSize(48, 20)
    btnLeave:SetPoint("LEFT", btnMembers, "RIGHT", 3, 0)
    btnLeave:SetText("Esci")
    btnLeave:SetScript("OnClick", function() StaticPopup_Show("TavesChatG_LEAVE") end)

    title = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    title:SetPoint("TOPLEFT", btnLeave, "TOPRIGHT", 8, -5)
    title:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -22, -9)
    title:SetJustifyH("LEFT")
    title:SetWordWrap(false)

    emptyText = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    emptyText:SetPoint("CENTER", 0, 0)
    emptyText:SetWidth(300)
    emptyText:SetText("Non sei in nessuna chat.\nPremi \"Aggiungi\" e scegli un amico per crearne una.")

    -- messaggi
    smf = CreateFrame("ScrollingMessageFrame", nil, panel)
    smf:SetPoint("TOPLEFT", 6, -28)
    smf:SetPoint("BOTTOMRIGHT", -6, 30)
    smf:SetFontObject("ChatFontNormal")
    smf:SetJustifyH("LEFT")
    smf:SetMaxLines(600)
    smf:SetFading(false)
    smf:SetIndentedWordWrap(true)
    smf.bg = panel:CreateTexture(nil, "BACKGROUND", nil, 1)
    smf.bg:SetPoint("TOPLEFT", smf, -4, 4)
    smf.bg:SetPoint("BOTTOMRIGHT", smf, 4, -4)
    smf.bg:SetColorTexture(0.12, 0.12, 0.15, 0.6)
    smf:EnableMouseWheel(true)
    smf:SetScript("OnMouseWheel", function(self, delta)
        if IsShiftKeyDown() then
            if delta > 0 then self:ScrollToTop() else self:ScrollToBottom() end
        elseif delta > 0 then
            self:ScrollUp() self:ScrollUp() self:ScrollUp()
        else
            self:ScrollDown() self:ScrollDown() self:ScrollDown()
        end
    end)

    -- casella di scrittura: Invio manda il messaggio alla chat
    input = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
    input:SetPoint("BOTTOMLEFT", 12, 5)
    input:SetPoint("BOTTOMRIGHT", -8, 5)
    input:SetHeight(22)
    input:SetAutoFocus(false)
    input:SetMaxLetters(400)
    input:SetScript("OnEnterPressed", function(self)
        local t = self:GetText()
        self:SetText("")
        SendText(t)
    end)
    input:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    panel:SetScript("OnShow", function()
        if FCF_StopAlertFlash and chatFrame then FCF_StopAlertFlash(chatFrame) end
        UpdateUI()
        Render()
    end)
    panel:SetScript("OnHide", function()
        input:ClearFocus()
        CloseMenu()
    end)

    if panel:IsVisible() then panel:GetScript("OnShow")() end
end

---------------------------------------------------------------------
-- Scheda di chat "Chat"
---------------------------------------------------------------------
local function FindChatFrame()
    for i = 1, (NUM_CHAT_WINDOWS or 10) do
        local name, _, _, _, _, _, shown, _, docked = GetChatWindowInfo(i)
        if name == TAB_NAME and (shown or docked) then return _G["ChatFrame" .. i] end
    end
end

local function IsClosed(frame)
    local _, _, _, _, _, _, shown, _, docked = GetChatWindowInfo(frame:GetID())
    return not shown and not docked
end

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

local function Setup()
    if panel then return end
    chatFrame = FindChatFrame()
    if not chatFrame then
        chatFrame = FCF_OpenNewWindow(TAB_NAME)
        if not chatFrame then return end
        -- la scheda Chat non deve ricevere i messaggi normali
        if ChatFrame_RemoveAllMessageGroups then ChatFrame_RemoveAllMessageGroups(chatFrame) end
        if ChatFrame_RemoveAllChannels then ChatFrame_RemoveAllChannels(chatFrame) end
        if ChatFrame1 then SelectFrame(ChatFrame1) end
    end
    BuildPanel()
end

local function Toggle()
    if not panel then Setup() end
    if not panel then return end
    if IsClosed(chatFrame) then
        Reopen()
        SelectFrame(chatFrame)
        return
    end
    if panel:IsVisible() then SelectFrame(ChatFrame1) else SelectFrame(chatFrame) end
end
TavesChat_Toggle = Toggle

if TavesMenu then
    TavesMenu.Register("chat", "TavesChat", "Interface\\Icons\\INV_Letter_15", Toggle)
end

---------------------------------------------------------------------
-- Init
---------------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("CHAT_MSG_ADDON")
ev:RegisterEvent("CHAT_MSG_SYSTEM")
ev:SetScript("OnEvent", function(self, event, ...)
    if event == "CHAT_MSG_ADDON" then
        OnAddon(...)
    elseif event == "CHAT_MSG_SYSTEM" then
        -- se il gioco risponde "nessun giocatore con quel nome" a un invito, lo mostro qui
        local text = ...
        if text and next(pending) then
            for _, p in pairs(pending) do
                if text:lower():find(p.name:lower(), 1, true) or text:lower():find(Label(p.name):lower(), 1, true) then
                    AddSys("Il gioco risponde: " .. text)
                    break
                end
            end
        end
    elseif event == "PLAYER_LOGIN" then
        if RegisterPrefix then RegisterPrefix(PREFIX) end
        me = UnitName("player")
        meKey = me:lower()
        TavesChatGroupDB = TavesChatGroupDB or {}
        db = TavesChatGroupDB
        RebuildSeen()
    else
        self:UnregisterEvent("PLAYER_ENTERING_WORLD")
        -- dopo la scheda Note (che parte a 1s), cosi' le due non si pestano i piedi
        C_Timer.After(2, Setup)
        C_Timer.After(8, SyncRequest)
    end
end)

SLASH_TavesChatG1 = "/tchat"
SlashCmdList["TavesChatG"] = function(arg)
    if (arg or ""):lower():match("^%s*debug") then
        debugOn = not debugOn
        Say("debug " .. (debugOn and "attivo" or "disattivato"))
    else
        Toggle()
    end
end
