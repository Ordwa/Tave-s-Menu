-- TavesChat: scheda "Chat" con l'elenco delle chat a sinistra (come WhatsApp):
--   Party   = la chat di party/raid del gioco (solo raccolta, nessuno storico salvato)
--   Gilda   = la chat di gilda del gioco (idem)
--   Privata = chat di gruppo condivisa tra amici, fatta da questo addon.
-- Trasporto della privata: messaggi di addon in WHISPER (nascosti), un invio per ogni membro.
-- Comando: /tchat

local TAB_NAME = "Chat"
local PREFIX = "TavesChatG"
local RegisterPrefix = (C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix) or RegisterAddonMessagePrefix
local SendAddon = (C_ChatInfo and C_ChatInfo.SendAddonMessage) or SendAddonMessage

local CHUNK = 170        -- byte codificati per messaggio (il limite del gioco e' 255)
local MAX_MSGS = 200     -- messaggi conservati
local MAX_HIST = 30      -- messaggi inviati a chi chiede lo storico

local db, chatFrame, panel
local smf, title, emptyText, btnAdd, btnMembers, btnLeave
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

-- un link di oggetto non deve mai essere spezzato tra due messaggi: e' un'unita' sola
local function Units(text)
    local units, i, n = {}, 1, #text
    while i <= n do
        local s, e = text:find("^|c%x%x%x%x%x%x%x%x|H%a+:[^|]+|h%[[^|]*%]|h|r", i)
        if s and #Enc(text:sub(s, e)) <= 200 then
            units[#units + 1] = text:sub(s, e)
            i = e + 1
        else
            local ch = text:match("^[%z\1-\127\194-\244][\128-\191]*", i) or text:sub(i, i)
            units[#units + 1] = ch
            i = i + #ch
        end
    end
    return units
end

local function MakeChunks(text)
    local chunks, cur, len = {}, {}, 0
    for _, ch in ipairs(Units(text)) do
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
-- Nei messaggi privati lascio passare solo i link veri (oggetti, abilita', ecc.);
-- ogni altro "|" viene reso innocuo.
local LINK_TYPES = { item = true, spell = true, quest = true, enchant = true,
    achievement = true, talent = true, currency = true }
local function Safe(text)
    local links = {}
    text = text:gsub("(|c%x%x%x%x%x%x%x%x|H(%a+):[^|]+|h%[[^|]*%]|h|r)", function(l, kind)
        if not LINK_TYPES[kind] then return nil end
        links[#links + 1] = l
        return "\1" .. #links .. "\2"
    end)
    text = text:gsub("|", "||")
    return (text:gsub("\1(%d+)\2", function(n) return links[tonumber(n)] end))
end

local function FormatLine(m)
    local text = (m.text or ""):gsub("[\r\n]+", " ")
    text = m.sys and text:gsub("|", "||") or Safe(text)
    if m.sys then
        return "|cff8a8a8a- " .. text .. " -|r"
    end
    local ts = "|cff8a8a8a" .. date("%H:%M", m.t) .. "|r "
    if Key(m.from) == meKey then
        return ts .. "|cff7fd67fTu|r: |cffd0d0d0" .. text .. "|r"
    end
    return ts .. "|cffffd100" .. Label(m.from):gsub("|", "||") .. "|r: |cffd0d0d0" .. text .. "|r"
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
-- Pannello: a sinistra l'elenco delle chat, a destra la chat scelta
---------------------------------------------------------------------
local LIST_W = 100
local VIEWS = {
    { key = "party",   label = "Party" },
    { key = "guild",   label = "Gilda" },
    { key = "private", label = "Privata" },
}
local view = "private"
local rowsUI = {}
local partySmf, guildSmf, heading

-- Party e Gilda: niente storico salvato, solo le righe arrivate in questa sessione
local buf = { party = {}, guild = {} }
local GROUP_EVENTS = {
    CHAT_MSG_PARTY                = { "party", "|cffaaaaff" },
    CHAT_MSG_PARTY_LEADER         = { "party", "|cff77c8ff" },
    CHAT_MSG_RAID                 = { "party", "|cffff7f00" },
    CHAT_MSG_RAID_LEADER          = { "party", "|cffff4809" },
    CHAT_MSG_RAID_WARNING         = { "party", "|cffff4800" },
    CHAT_MSG_INSTANCE_CHAT        = { "party", "|cffff7f00" },
    CHAT_MSG_INSTANCE_CHAT_LEADER = { "party", "|cffff4809" },
    CHAT_MSG_GUILD                = { "guild", "|cff40ff40" },
    CHAT_MSG_OFFICER              = { "guild", "|cff40c040" },
}

local function ViewSmf(k)
    if k == "party" then return partySmf elseif k == "guild" then return guildSmf end
    return smf
end

local function PartyChannel()
    if LE_PARTY_CATEGORY_INSTANCE and IsInGroup(LE_PARTY_CATEGORY_INSTANCE)
        and not (LE_PARTY_CATEGORY_HOME and IsInGroup(LE_PARTY_CATEGORY_HOME)) then
        return "INSTANCE_CHAT"
    end
    if IsInRaid and IsInRaid() then return "RAID" end
    if IsInGroup and IsInGroup() then return "PARTY" end
end

local TEXT_COLOR = "|cffd0d0d0"   -- colore base dei testi (grigio chiaro)

-- colore del nome: quello della classe, se il gioco la conosce; altrimenti quello del canale
local function NameColor(guid, fallback)
    if guid and guid ~= "" and GetPlayerInfoByGUID then
        local ok, _, class = pcall(GetPlayerInfoByGUID, guid)
        local c = ok and class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
        if c then
            return string.format("|cff%02x%02x%02x", math.floor(c.r * 255 + 0.5),
                math.floor(c.g * 255 + 0.5), math.floor(c.b * 255 + 0.5))
        end
    end
    return fallback
end

local function AddGroupLine(v, color, text, sender, guid)
    local name = (sender and sender ~= "") and Label(sender) or "?"
    if meKey and sender and Key(sender) == meKey then name = "Tu" end
    local line = "|cff8a8a8a" .. date("%H:%M") .. "|r " .. NameColor(guid, color) .. name .. "|r: "
        .. TEXT_COLOR .. (text or "") .. "|r"
    local b = buf[v]
    b[#b + 1] = line
    if #b > MAX_MSGS then table.remove(b, 1) end
    local s = ViewSmf(v)
    if s then s:AddMessage(line) end
end

local function GroupNote(v, text)
    local s = ViewSmf(v)
    if s then s:AddMessage("|cff8a8a8a- " .. text .. " -|r") end
end

---------------------------------------------------------------------
-- Si scrive con la casella di chat di WoW (niente casella aggiuntiva).
-- Party/Gilda: la casella viene impostata su /p, /raid, /i oppure /g.
-- Privata: l'Invio viene intercettato e il testo va alla chat dell'addon.
---------------------------------------------------------------------
local privBox, privOrigEnter

local function BoxOf(f) return f and (f.editBox or _G[f:GetName() .. "EditBox"]) end

local function RestoreBox()
    if privBox then
        privBox:SetScript("OnEnterPressed", privOrigEnter)
        privBox, privOrigEnter = nil, nil
    end
end

local function SetPrivateHeader(box)
    box.header:SetText("Privata: ")
    box:SetTextInsets(15 + box.header:GetStringWidth(), 13, 0, 0)
end

local function PrivateEnter(self)
    local text = self:GetText() or ""
    if text:match("^%s*/") or not text:match("%S") then
        -- comandi (/p, /w ...) o riga vuota: ci pensa WoW
        local orig = privOrigEnter
        RestoreBox()
        if orig then orig(self) elseif ChatEdit_OnEnterPressed then ChatEdit_OnEnterPressed(self) end
        return
    end
    pcall(self.AddHistoryLine, self, text)
    SendText(text)
    self:SetText("")
    RestoreBox()
    ChatEdit_DeactivateChat(self)
end

-- prepara la casella di chat per la chat selezionata
local function ApplyView(box, force)
    local ct = box:GetAttribute("chatType")
    -- risposte a un whisper, canali, ecc.: non li tocco (a meno che l'apertura sia stata chiesta da me)
    if not force and (ct == "BN_WHISPER" or ct == "CHANNEL"
        or (ct == "WHISPER" and (box:GetAttribute("tellTarget") or "") ~= "")) then
        return
    end
    if view == "party" then
        local ch = PartyChannel()
        if not ch then
            ChatEdit_DeactivateChat(box)
            GroupNote("party", "Non sei in un gruppo.")
            return
        end
        box:SetAttribute("chatType", ch)
        ChatEdit_UpdateHeader(box)
    elseif view == "guild" then
        if not IsInGuild() then
            ChatEdit_DeactivateChat(box)
            GroupNote("guild", "Non sei in una gilda.")
            return
        end
        box:SetAttribute("chatType", "GUILD")
        ChatEdit_UpdateHeader(box)
    else
        if not (db and db.chat) then
            ChatEdit_DeactivateChat(box)
            return
        end
        -- "WHISPER" senza destinatario e' un ripiego innocuo: se l'intercettazione
        -- dell'Invio mancasse, il testo non puo' finire in /say
        box:SetAttribute("chatType", "WHISPER")
        box:SetAttribute("tellTarget", "")
        ChatEdit_UpdateHeader(box)
        if privBox ~= box then
            privBox = box
            privOrigEnter = box:GetScript("OnEnterPressed")
            box:SetScript("OnEnterPressed", PrivateEnter)
        end
        SetPrivateHeader(box)
    end
end

local function CloseInput()
    local box = BoxOf(chatFrame)
    if box and ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow() == box then
        ChatEdit_DeactivateChat(box)
    end
    RestoreBox()
end

-- clic sull'area della chat: parte la scrittura
local function OpenInput()
    if not (panel and panel:IsVisible()) then return false end
    if view == "private" and not (db and db.chat) then return false end
    if view == "party" and not PartyChannel() then GroupNote("party", "Non sei in un gruppo.") return false end
    if view == "guild" and not IsInGuild() then GroupNote("guild", "Non sei in una gilda.") return false end
    local box = BoxOf(chatFrame)
    if not box then return false end
    -- casella gia' aperta: non la riapro, altrimenti si svuota (e perderebbe il link appena inserito)
    if ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow() == box then return true end
    ChatFrame_OpenChat("", chatFrame)
    ApplyView(box, true)   -- idempotente: serve se l'hook non e' ancora scattato
    return ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow() == box
end

-- oggetto (o abilita') trascinato sulla chat: lo linka nella casella
local function CursorLink()
    local kind, a, b, c = GetCursorInfo()
    if kind == "item" then
        return b or (a and select(2, GetItemInfo(a)))
    elseif kind == "spell" and GetSpellLink then
        local ok, l = pcall(GetSpellLink, c or a)
        return ok and l or nil
    end
end

-- Il gioco puo' svuotare il cursore prima che il rilascio arrivi alla chat (e l'ordine
-- degli eventi cambia): quindi tengo sempre l'ultimo link visto sul cursore.
local lastLink, lastLinkTime = nil, 0
local function TrackCursor()
    local l = CursorLink()
    if l then lastLink, lastLinkTime = l, GetTime() end
end

local function InsertIntoBox(link)
    local b = ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow()
    if not b then return end
    if not ChatEdit_InsertLink(link) then b:Insert(link) end
    -- controllo di sicurezza: se qualcosa ha svuotato la casella, lo reinserisco
    local data = link:match("|H(.-)|h") or link
    C_Timer.After(0.05, function()
        local bb = ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow()
        if bb and not (bb:GetText() or ""):find(data, 1, true) then bb:Insert(link) end
    end)
end

-- link pronto da inserire: dal cursore adesso, oppure visto un attimo fa
local function TakeDropLink()
    local l = CursorLink()
    if not l and lastLink and GetTime() - lastLinkTime < 0.4 then l = lastLink end
    lastLink = nil
    return l
end

local function DoDrop(link)
    Dbg("trascinato: " .. tostring(link))
    if OpenInput() then
        ClearCursor()
        InsertIntoBox(link)
    end
end

local function OnDropOnChat()
    local link = TakeDropLink()
    if link then DoDrop(link) end
end

local function ClickToType(_, button)
    if button ~= "LeftButton" then return end
    if GetCursorInfo() then return end        -- c'e' ancora qualcosa sul cursore: lo gestisce OnReceiveDrag
    local link = TakeDropLink()               -- rilascio gia' avvenuto: il cursore era gia' vuoto
    if link then DoDrop(link) else OpenInput() end
end

local function InstallHooks()
    hooksecurefunc("ChatEdit_ActivateChat", function(box)
        if panel and panel:IsVisible() and box == BoxOf(chatFrame) then ApplyView(box) end
    end)
    hooksecurefunc("ChatEdit_DeactivateChat", function(box)
        if box == privBox then RestoreBox() end
    end)
    hooksecurefunc("ChatEdit_UpdateHeader", function(box)
        if box == privBox then SetPrivateHeader(box) end
    end)
end

local function PartyStatus()
    local ch = PartyChannel()
    if ch == "RAID" then return "Raid" elseif ch then return "In gruppo" end
    return "Nessun gruppo"
end

local function GuildStatus()
    if IsInGuild() then return (GetGuildInfo and GetGuildInfo("player")) or "In gilda" end
    return "Nessuna gilda"
end

function UpdateUI()
    if not panel then return end
    local c = db and db.chat
    local priv = (view == "private")

    -- chat privata (quella dell'addon)
    btnAdd:SetShown(priv)
    btnMembers:SetShown(priv and c ~= nil)
    btnLeave:SetShown(priv and c ~= nil)
    smf:SetShown(priv and c ~= nil)
    smf.bg:SetShown(priv and c ~= nil)
    emptyText:SetShown(priv and c == nil)
    if priv and c then
        local names = {}
        for _, m in ipairs(c.members) do
            if Key(m) ~= meKey then names[#names + 1] = Label(m) end
        end
        title:SetText(#names > 0 and ("con " .. table.concat(names, ", ")) or "solo tu")
    else
        title:SetText("")
    end

    -- party e gilda
    partySmf:SetShown(view == "party")
    partySmf.bg:SetShown(view == "party")
    guildSmf:SetShown(view == "guild")
    guildSmf.bg:SetShown(view == "guild")
    if view == "party" then
        heading:SetText(PartyChannel() and "Chat di gruppo" or "Non sei in un gruppo")
    elseif view == "guild" then
        heading:SetText(IsInGuild() and "Chat di gilda" or "Non sei in una gilda")
    else
        heading:SetText("")
    end

    -- elenco a sinistra
    for _, r in ipairs(rowsUI) do
        r.sel:SetShown(r.key == view)
        if r.key == "party" then
            r.sub:SetText(PartyStatus())
        elseif r.key == "guild" then
            r.sub:SetText(GuildStatus())
        else
            r.sub:SetText(c and (#c.members .. " membri") or "Nessuna chat")
        end
    end
end

local function SelectView(k)
    view = k
    if db then db.view = k end
    CloseInput()
    UpdateUI()
    if k == "private" then Render() end
end

local function MakeSmf()
    local s = CreateFrame("ScrollingMessageFrame", nil, panel)
    s:SetPoint("TOPLEFT", LIST_W + 8, -28)
    s:SetPoint("BOTTOMRIGHT", -6, 6)
    s:SetScript("OnMouseUp", ClickToType)
    s:SetScript("OnReceiveDrag", OnDropOnChat)
    s:SetFontObject("ChatFontNormal")
    s:SetJustifyH("LEFT")
    s:SetMaxLines(600)
    s:SetFading(false)
    s:SetIndentedWordWrap(true)
    s.bg = panel:CreateTexture(nil, "BACKGROUND", nil, 1)
    s.bg:SetPoint("TOPLEFT", s, -4, 4)
    s.bg:SetPoint("BOTTOMRIGHT", s, 4, -4)
    s.bg:SetColorTexture(0.12, 0.12, 0.15, 0.6)
    s:EnableMouseWheel(true)
    s:SetScript("OnMouseWheel", function(self, delta)
        if IsShiftKeyDown() then
            if delta > 0 then self:ScrollToTop() else self:ScrollToBottom() end
        elseif delta > 0 then
            self:ScrollUp() self:ScrollUp() self:ScrollUp()
        else
            self:ScrollDown() self:ScrollDown() self:ScrollDown()
        end
    end)
    -- link (oggetti ecc.) cliccabili nelle chat di party e gilda
    if s.SetHyperlinksEnabled then
        s:SetHyperlinksEnabled(true)
        s:SetScript("OnHyperlinkClick", function(self, link, text, button)
            if SetItemRef then SetItemRef(link, text, button, self) end
        end)
    end
    return s
end

local function BuildPanel()
    panel = CreateFrame("Frame", "TavesChatPanel", chatFrame)
    panel:SetAllPoints(chatFrame)
    panel:SetFrameLevel(chatFrame:GetFrameLevel() + 20)
    panel:EnableMouse(true)

    local bg = panel:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.04, 0.04, 0.04, 0.95)

    -- colonna sinistra: elenco delle chat
    local listBg = panel:CreateTexture(nil, "BACKGROUND", nil, 1)
    listBg:SetPoint("TOPLEFT", 0, 0)
    listBg:SetPoint("BOTTOMLEFT", 0, 0)
    listBg:SetWidth(LIST_W)
    listBg:SetColorTexture(0.09, 0.09, 0.12, 0.95)
    local sep = panel:CreateTexture(nil, "BORDER")
    sep:SetPoint("TOPLEFT", LIST_W, 0)
    sep:SetPoint("BOTTOMLEFT", LIST_W, 0)
    sep:SetWidth(1)
    sep:SetColorTexture(0.35, 0.35, 0.35, 0.7)

    for i, v in ipairs(VIEWS) do
        local r = CreateFrame("Button", nil, panel)
        r:SetSize(LIST_W - 2, 40)
        r:SetPoint("TOPLEFT", 1, -4 - (i - 1) * 42)
        r.key = v.key
        r.hl = r:CreateTexture(nil, "HIGHLIGHT")
        r.hl:SetAllPoints()
        r.hl:SetColorTexture(1, 1, 1, 0.10)
        r.sel = r:CreateTexture(nil, "BACKGROUND")
        r.sel:SetAllPoints()
        r.sel:SetColorTexture(1, 0.82, 0, 0.22)
        r.t = r:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        r.t:SetPoint("TOPLEFT", 8, -7)
        r.t:SetPoint("TOPRIGHT", -4, -7)
        r.t:SetJustifyH("LEFT")
        r.t:SetText(v.label)
        r.sub = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        r.sub:SetPoint("TOPLEFT", r.t, "BOTTOMLEFT", 0, -3)
        r.sub:SetPoint("TOPRIGHT", r.t, "BOTTOMRIGHT", 0, -3)
        r.sub:SetJustifyH("LEFT")
        r.sub:SetWordWrap(false)
        r:SetScript("OnClick", function() SelectView(v.key) end)
        rowsUI[i] = r
    end

    -- colonna destra: barra in alto (solo per la chat privata)
    local X = LIST_W + 5
    btnAdd = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    btnAdd:SetSize(72, 20)
    btnAdd:SetPoint("TOPLEFT", X, -4)
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

    heading = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    heading:SetPoint("TOPLEFT", X + 4, -9)
    heading:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -22, -9)
    heading:SetJustifyH("LEFT")
    heading:SetWordWrap(false)

    emptyText = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    emptyText:SetPoint("CENTER", panel, "CENTER", LIST_W / 2, 0)
    emptyText:SetWidth(280)
    emptyText:SetText("Non sei in nessuna chat privata.\nPremi \"Aggiungi\" e scegli un amico per crearne una.")

    -- le tre aree messaggi (una per chat)
    smf = MakeSmf()
    partySmf = MakeSmf()
    guildSmf = MakeSmf()
    for _, line in ipairs(buf.party) do partySmf:AddMessage(line) end
    for _, line in ipairs(buf.guild) do guildSmf:AddMessage(line) end

    -- clic sull'area della chat = inizia a scrivere; oggetto trascinato = link
    panel:SetScript("OnMouseUp", ClickToType)
    panel:SetScript("OnReceiveDrag", OnDropOnChat)
    panel:SetScript("OnUpdate", TrackCursor)

    panel:SetScript("OnShow", function()
        if FCF_StopAlertFlash and chatFrame then FCF_StopAlertFlash(chatFrame) end
        UpdateUI()
        Render()
    end)
    panel:SetScript("OnHide", function()
        CloseInput()
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
-- chat di party/gilda del gioco (alcuni eventi possono non esistere in questa versione)
for name in pairs(GROUP_EVENTS) do pcall(ev.RegisterEvent, ev, name) end
pcall(ev.RegisterEvent, ev, "GROUP_ROSTER_UPDATE")
pcall(ev.RegisterEvent, ev, "PLAYER_GUILD_UPDATE")
ev:SetScript("OnEvent", function(self, event, ...)
    if event == "CHAT_MSG_ADDON" then
        OnAddon(...)
    elseif GROUP_EVENTS[event] then
        local text, sender = ...
        AddGroupLine(GROUP_EVENTS[event][1], GROUP_EVENTS[event][2], text, sender, (select(12, ...)))
    elseif event == "GROUP_ROSTER_UPDATE" or event == "PLAYER_GUILD_UPDATE" then
        UpdateUI()
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
        view = db.view or "private"
        InstallHooks()
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
