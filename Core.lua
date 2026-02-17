-- Silencer: Whisper gatekeeper for keyword-based group building
-- Filters whispers by keyword, queues matches for manual review

local ADDON_NAME, Silencer = ...

local ADDON_PREFIX = "|cFF33CCFF[Silencer]|r "
local GetMetadata = C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata
local VERSION = GetMetadata and GetMetadata(ADDON_NAME, "Version") or "dev"
if VERSION:find("^@") then VERSION = "dev" end
local MAX_QUEUE = 50

local LDB = LibStub("LibDataBroker-1.1")
local LDBIcon = LibStub("LibDBIcon-1.0")

--------------------------------------------------------------
-- State
--------------------------------------------------------------

SilencerDB = SilencerDB or {}

local isEnabled = false
local queue = {}
local silencedQueue = {}
local silencedCount = 0
local matchedCount = 0
local filterRegistered = false
local viewMode = "matched" -- "matched", "silenced", or "blockedword"
local filteredPlayers = {} -- name -> true, tracks who Silencer has filtered this session
local blockedWordQueue = {}
local blockedWordCount = 0

local function InitializeDB()
    SilencerDB.keyword = SilencerDB.keyword or "inv"
    SilencerDB.enabled = SilencerDB.enabled or false
    SilencerDB.position = SilencerDB.position or nil
    SilencerDB.minimap = SilencerDB.minimap or { hide = false }
    SilencerDB.blockedClasses = SilencerDB.blockedClasses or {}
    SilencerDB.blockedWords = SilencerDB.blockedWords or {}
    SilencerDB.blockedWordsEnabled = SilencerDB.blockedWordsEnabled or false
    SilencerDB.blockedWordsOverride = SilencerDB.blockedWordsOverride or false
end

--------------------------------------------------------------
-- Minimap button (LibDataBroker + LibDBIcon)
--------------------------------------------------------------

local dataObject = LDB:NewDataObject("Silencer", {
    type = "launcher",
    icon = "Interface\\Icons\\Spell_Holy_Silence",
    OnClick = function(_, button)
        if button == "LeftButton" then
            Silencer:ToggleFrame()
        elseif button == "RightButton" then
            Silencer:Toggle()
        end
    end,
    OnTooltipShow = function(tooltip)
        tooltip:AddLine("Silencer", 0.2, 0.8, 1.0)
        tooltip:AddLine(" ")
        local status = isEnabled and "|cFF00FF00ON|r" or "|cFFFF0000OFF|r"
        tooltip:AddLine("Status: " .. status, 1, 1, 1)
        tooltip:AddLine(" ")
        tooltip:AddLine("|cFFFFFFFFLeft-click:|r Toggle window", 0.7, 0.7, 0.7)
        tooltip:AddLine("|cFFFFFFFFRight-click:|r Toggle filter ON/OFF", 0.7, 0.7, 0.7)
    end,
})

--------------------------------------------------------------
-- Invite helper (C_PartyInfo.InviteUnit or fallback)
--------------------------------------------------------------

local function InvitePlayer(name)
    if C_PartyInfo and C_PartyInfo.InviteUnit then
        C_PartyInfo.InviteUnit(name)
    else
        InviteUnit(name)
    end
end

--------------------------------------------------------------
-- Class data
--------------------------------------------------------------

local CLASS_ORDER = {
    "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST",
    "SHAMAN", "MAGE", "WARLOCK", "DRUID",
}

local CLASS_ICONS = {
    WARRIOR  = "Interface\\Icons\\ClassIcon_Warrior",
    PALADIN  = "Interface\\Icons\\ClassIcon_Paladin",
    HUNTER   = "Interface\\Icons\\ClassIcon_Hunter",
    ROGUE    = "Interface\\Icons\\ClassIcon_Rogue",
    PRIEST   = "Interface\\Icons\\ClassIcon_Priest",
    SHAMAN   = "Interface\\Icons\\ClassIcon_Shaman",
    MAGE     = "Interface\\Icons\\ClassIcon_Mage",
    WARLOCK  = "Interface\\Icons\\ClassIcon_Warlock",
    DRUID    = "Interface\\Icons\\ClassIcon_Druid",
}

--------------------------------------------------------------
-- Ignore list helper
--------------------------------------------------------------

local function IsPlayerOnIgnoreList(name)
    local numIgnores = C_FriendList and C_FriendList.GetNumIgnores and C_FriendList.GetNumIgnores()
        or GetNumIgnores and GetNumIgnores()
        or 0
    local getIgnoreName = C_FriendList and C_FriendList.GetIgnoreName or GetIgnoreName
    if not getIgnoreName then return false end
    for i = 1, numIgnores do
        local ignoreName = getIgnoreName(i)
        if ignoreName then
            local shortName = strsplit("-", ignoreName)
            -- Exact match first, then case-insensitive fallback
            if shortName == name or strlower(shortName) == strlower(name) then
                return true
            end
        end
    end
    return false
end

--------------------------------------------------------------
-- Chat filter engine
--------------------------------------------------------------

local function GetSenderClass(guid)
    if guid and GetPlayerInfoByGUID then
        local localizedClass, englishClass = GetPlayerInfoByGUID(guid)
        if englishClass then
            return englishClass, localizedClass
        end
    end
    return "UNKNOWN", "Unknown"
end

local function FindBlockedWords(msg)
    if not SilencerDB.blockedWordsEnabled then return nil end
    local words = SilencerDB.blockedWords
    if not words or #words == 0 then return nil end

    local matched = {}
    for _, word in ipairs(words) do
        -- Exact substring first (UTF-8 safe), strlower fallback
        if msg:find(word, 1, true) or strlower(msg):find(strlower(word), 1, true) then
            tinsert(matched, word)
        end
    end

    if #matched > 0 then
        return matched
    end
    return nil
end

local function WhisperFilter(chatFrame, event, msg, playerName, ...)
    if not isEnabled then
        return false
    end

    local keyword = SilencerDB.keyword
    if (not keyword or keyword == "") and not SilencerDB.blockedWordsEnabled then
        return false
    end

    -- GUID is the 10th vararg (event arg12, after msg and playerName)
    local guid = select(10, ...)
    local class, classLocal = GetSenderClass(guid)
    local name, realm = strsplit("-", playerName, 2)
    if not filteredPlayers[name] then
        filteredPlayers[name] = true
        Silencer:UpdatePartyIndicators()
    end

    -- Check blocked words
    local matchedBlockedWords = FindBlockedWords(msg)

    -- Check keyword match
    local keywordMatch = keyword and keyword ~= ""
        and strlower(msg):find(strlower(keyword), 1, true)

    local entry = {
        name = name,
        realm = realm or "",
        fullName = playerName,
        message = msg,
        time = GetTime(),
        class = class,
        classLocal = classLocal,
    }

    -- ROUTING DECISION
    if matchedBlockedWords and (SilencerDB.blockedWordsOverride or not keywordMatch) then
        -- Blocked words win: override enabled, OR no keyword match
        entry.filterReason = table.concat(matchedBlockedWords, ", ")
        blockedWordCount = blockedWordCount + 1
        tinsert(blockedWordQueue, entry)
        if #blockedWordQueue > MAX_QUEUE then
            tremove(blockedWordQueue, 1)
        end
    elseif keywordMatch then
        -- Keyword matched (blocked words either absent or override off)
        local isClassBlocked = class ~= "UNKNOWN" and SilencerDB.blockedClasses[class]
        entry.classBlocked = isClassBlocked or false

        if isClassBlocked then
            silencedCount = silencedCount + 1
            tinsert(silencedQueue, entry)
            if #silencedQueue > MAX_QUEUE then
                tremove(silencedQueue, 1)
            end
        else
            matchedCount = matchedCount + 1
            tinsert(queue, entry)
            if #queue > MAX_QUEUE then
                tremove(queue, 1)
            end
        end
    else
        -- No keyword match, no blocked words (or blocked words disabled)
        silencedCount = silencedCount + 1
        tinsert(silencedQueue, entry)
        if #silencedQueue > MAX_QUEUE then
            tremove(silencedQueue, 1)
        end
    end

    Silencer:UpdateList()
    Silencer:UpdateCounters()
    return true
end

function Silencer:EnableFilter(silent)
    if not filterRegistered then
        ChatFrame_AddMessageEventFilter("CHAT_MSG_WHISPER", WhisperFilter)
        filterRegistered = true
    end
    isEnabled = true
    SilencerDB.enabled = true
    silencedCount = 0
    matchedCount = 0
    blockedWordCount = 0
    viewMode = "matched"
    self:UpdateToggleButton()
    self:UpdateCounters()
    if not silent then
        print(ADDON_PREFIX .. "Filter ON - match word: |cFFFFFF00" .. (SilencerDB.keyword or "") .. "|r")
    end
end

function Silencer:DisableFilter()
    if filterRegistered then
        ChatFrame_RemoveMessageEventFilter("CHAT_MSG_WHISPER", WhisperFilter)
        filterRegistered = false
    end
    isEnabled = false
    SilencerDB.enabled = false
    wipe(queue)
    wipe(silencedQueue)
    wipe(blockedWordQueue)
    wipe(filteredPlayers)
    silencedCount = 0
    matchedCount = 0
    blockedWordCount = 0
    viewMode = "matched"
    self:UpdateList()
    self:UpdateToggleButton()
    self:UpdateCounters()
    self:UpdatePartyIndicators()
    print(ADDON_PREFIX .. "Filter OFF - all whispers flowing normally")
end

function Silencer:Toggle()
    if isEnabled then
        self:DisableFilter()
    else
        self:EnableFilter()
    end
end

--------------------------------------------------------------
-- Slash commands
--------------------------------------------------------------

SLASH_SILENCER1 = "/silencer"
SLASH_SILENCER2 = "/sil"

SlashCmdList["SILENCER"] = function(msg)
    msg = msg and strlower(strtrim(msg)) or ""

    if msg == "" then
        Silencer:ToggleFrame()

    elseif msg == "on" then
        Silencer:EnableFilter()
        Silencer:ShowFrame()

    elseif msg == "off" then
        Silencer:DisableFilter()

    elseif msg:match("^keyword%s+") then
        local newKeyword = strtrim(msg:match("^keyword%s+(.+)"))
        if newKeyword and newKeyword ~= "" then
            SilencerDB.keyword = newKeyword
            Silencer:UpdateKeywordDisplay()
            print(ADDON_PREFIX .. "Match word set to: |cFFFFFF00" .. newKeyword .. "|r")
        end

    elseif msg:match("^match%s+") then
        local newKeyword = strtrim(msg:match("^match%s+(.+)"))
        if newKeyword and newKeyword ~= "" then
            -- Check if new match word is in blocked words list
            for i, word in ipairs(SilencerDB.blockedWords) do
                if strlower(word) == strlower(newKeyword) then
                    print(ADDON_PREFIX .. "|cFFFF4444Warning:|r '" .. newKeyword .. "' is also a blocked word - blocked word filter will not catch it while it's the match word")
                    break
                end
            end
            SilencerDB.keyword = newKeyword
            Silencer:UpdateKeywordDisplay()
            print(ADDON_PREFIX .. "Match word set to: |cFFFFFF00" .. newKeyword .. "|r")
        end

    elseif msg:match("^words%s*") then
        local subcmd = strtrim(msg:match("^words%s*(.*)") or "")

        if subcmd:match("^add%s+") then
            local word = strtrim(subcmd:match("^add%s+(.+)"))
            if not word or word == "" then
                print(ADDON_PREFIX .. "Usage: /sil words add <word>")
            elseif strlower(word) == strlower(SilencerDB.keyword or "") then
                print(ADDON_PREFIX .. "|cFFFF4444Cannot add '" .. word .. "' - it's your active match word|r")
            else
                -- Check for duplicate (case-insensitive)
                for _, existing in ipairs(SilencerDB.blockedWords) do
                    if strlower(existing) == strlower(word) then
                        print(ADDON_PREFIX .. "|cFFFF4444'" .. word .. "' is already in blocked words|r")
                        Silencer:UpdateBlockedWordsList()
                        return
                    end
                end
                tinsert(SilencerDB.blockedWords, word)
                print(ADDON_PREFIX .. "Added blocked word: |cFFFF4444" .. word .. "|r")
                Silencer:UpdateBlockedWordsList()
            end

        elseif subcmd:match("^remove%s+") then
            local word = strtrim(subcmd:match("^remove%s+(.+)"))
            if not word or word == "" then
                print(ADDON_PREFIX .. "Usage: /sil words remove <word>")
            else
                for i, existing in ipairs(SilencerDB.blockedWords) do
                    if strlower(existing) == strlower(word) then
                        tremove(SilencerDB.blockedWords, i)
                        print(ADDON_PREFIX .. "Removed blocked word: |cFFFF4444" .. existing .. "|r")
                        Silencer:UpdateBlockedWordsList()
                        return
                    end
                end
                print(ADDON_PREFIX .. "'" .. word .. "' not found in blocked words")
            end

        elseif subcmd == "list" then
            if #SilencerDB.blockedWords == 0 then
                print(ADDON_PREFIX .. "No blocked words")
            else
                print(ADDON_PREFIX .. "Blocked words: |cFFFF4444" .. table.concat(SilencerDB.blockedWords, ", ") .. "|r")
            end

        elseif subcmd == "clear" then
            wipe(SilencerDB.blockedWords)
            print(ADDON_PREFIX .. "Blocked words cleared")
            Silencer:UpdateBlockedWordsList()

        else
            print(ADDON_PREFIX .. "Words commands: add <word>, remove <word>, list, clear")
        end

    elseif msg == "status" then
        print(ADDON_PREFIX .. "Status: " .. (isEnabled and "|cFF00FF00ON|r" or "|cFFFF0000OFF|r"))
        print(ADDON_PREFIX .. "Match word: |cFFFFFF00" .. (SilencerDB.keyword or "(none)") .. "|r")
        if #SilencerDB.blockedWords > 0 then
            local bwStatus = SilencerDB.blockedWordsEnabled and "|cFF00FF00ON|r" or "|cFFFF0000OFF|r"
            print(ADDON_PREFIX .. "Blocked words (" .. bwStatus .. "): |cFFFF4444" .. table.concat(SilencerDB.blockedWords, ", ") .. "|r")
        end
        print(ADDON_PREFIX .. "Queue: " .. #queue .. " matched | " .. silencedCount .. " silenced | " .. #blockedWordQueue .. " blocked-word")

    elseif msg == "block" then
        local blocked = {}
        for _, class in ipairs(CLASS_ORDER) do
            if SilencerDB.blockedClasses[class] then
                tinsert(blocked, class:sub(1, 1) .. class:sub(2):lower())
            end
        end
        if #blocked > 0 then
            print(ADDON_PREFIX .. "Blocked classes: |cFFFF4444" .. table.concat(blocked, ", ") .. "|r")
        else
            print(ADDON_PREFIX .. "No classes blocked")
        end

    elseif msg == "clear" then
        wipe(queue)
        wipe(silencedQueue)
        wipe(blockedWordQueue)
        wipe(filteredPlayers)
        matchedCount = 0
        silencedCount = 0
        blockedWordCount = 0
        Silencer:UpdateList()
        Silencer:UpdateCounters()
        Silencer:UpdatePartyIndicators()
        print(ADDON_PREFIX .. "Queue cleared")

    elseif msg == "debug" then
        print(ADDON_PREFIX .. "--- Debug: Ignore list ---")
        local numIgnores = C_FriendList and C_FriendList.GetNumIgnores and C_FriendList.GetNumIgnores()
            or GetNumIgnores and GetNumIgnores() or 0
        local getIgnoreName = C_FriendList and C_FriendList.GetIgnoreName or GetIgnoreName
        print("  API: " .. (C_FriendList and C_FriendList.GetIgnoreName and "C_FriendList.GetIgnoreName" or GetIgnoreName and "GetIgnoreName" or "NONE"))
        print("  NumIgnores: " .. tostring(numIgnores))
        for i = 1, numIgnores do
            print("  [" .. i .. "] " .. tostring(getIgnoreName(i)))
        end

        print(ADDON_PREFIX .. "--- Debug: Raid frames ---")
        local raidFound = 0
        for g = 1, 8 do
            for m = 1, 5 do
                local frameName = "CompactRaidGroup" .. g .. "Member" .. m
                local frame = _G[frameName]
                if frame and frame.unit and frame:IsVisible() then
                    local name = UnitName(frame.unit)
                    local ignored = name and IsPlayerOnIgnoreList(name) or false
                    local filtered = name and filteredPlayers[name] or false
                    local ind = raidIndicators[frameName]
                    local indShown = ind and (ind.ignoreIcon:IsShown() or ind.silencerIcon:IsShown()) or false
                    print("  " .. frameName .. " = " .. tostring(name) .. " ign=" .. tostring(ignored) .. " filt=" .. tostring(filtered) .. " shown=" .. tostring(indShown))
                    raidFound = raidFound + 1
                end
            end
        end
        print("  Raid frames found: " .. raidFound)

        print(ADDON_PREFIX .. "--- Debug: Party frames ---")
        local pf = _G["PartyFrame"]
        print("  PartyFrame=" .. tostring(pf and "exists" or "nil") .. " vis=" .. tostring(pf and pf:IsVisible()) .. " shown=" .. tostring(pf and pf:IsShown()))
        for i = 1, 4 do
            local mf = pf and pf["MemberFrame" .. i]
            local name = UnitName("party" .. i)
            local vis = mf and mf:IsVisible()
            local shown = mf and mf:IsShown()
            local ignored = name and IsPlayerOnIgnoreList(name) or false
            local filtered = name and filteredPlayers[name] or false
            local ind = partyIndicators[i]
            local indIgn = ind and ind.ignoreIcon:IsShown() or false
            local indSil = ind and ind.silencerIcon:IsShown() or false
            local hooked = mf and mf._silencerHooked or false
            print("  MF" .. i .. " frame=" .. tostring(mf and "yes" or "nil") .. " vis=" .. tostring(vis) .. " shown=" .. tostring(shown) .. " hooked=" .. tostring(hooked))
            print("    name=" .. tostring(name) .. " ign=" .. tostring(ignored) .. " filt=" .. tostring(filtered) .. " indIgn=" .. tostring(indIgn) .. " indSil=" .. tostring(indSil))
        end

    else
        print(ADDON_PREFIX .. "Commands:")
        print("  /sil - Toggle window")
        print("  /sil on - Enable filter")
        print("  /sil off - Disable filter")
        print("  /sil match <word> - Set match word")
        print("  /sil keyword <word> - Set match word (alias)")
        print("  /sil words add|remove|list|clear - Manage blocked words")
        print("  /sil block - Show blocked classes")
        print("  /sil status - Show status")
        print("  /sil clear - Clear queues")
    end
end

--------------------------------------------------------------
-- UI Constants
--------------------------------------------------------------

local FRAME_WIDTH = 380
local FRAME_HEIGHT = 450
local ROW_HEIGHT = 28
local VISIBLE_ROWS = 8
local HEADER_HEIGHT = 160
local FOOTER_HEIGHT = 25
local WORD_ROW_HEIGHT = 18
local WORD_VISIBLE_ROWS = 3

--------------------------------------------------------------
-- Main frame
--------------------------------------------------------------

function Silencer:CreateMainFrame()
    if self.frame then return self.frame end

    local f = CreateFrame("Frame", "SilencerFrame", UIParent, "BackdropTemplate")
    f:SetSize(FRAME_WIDTH, FRAME_HEIGHT)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(frame)
        frame:StopMovingOrSizing()
        local point, _, relPoint, xOfs, yOfs = frame:GetPoint()
        SilencerDB.position = { point = point, relPoint = relPoint, x = xOfs, y = yOfs }
    end)
    f:Hide()

    f:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    f:SetBackdropColor(0.1, 0.1, 0.1, 0.95)
    f:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)

    -- Restore saved position
    if SilencerDB.position then
        local pos = SilencerDB.position
        f:ClearAllPoints()
        f:SetPoint(pos.point, UIParent, pos.relPoint, pos.x, pos.y)
    end

    self:BuildHeader(f)
    self:BuildScrollList(f)
    self:BuildFooter(f)

    tinsert(UISpecialFrames, "SilencerFrame")
    self.frame = f
    return f
end

--------------------------------------------------------------
-- Header: title, close, toggle, keyword
--------------------------------------------------------------

function Silencer:BuildHeader(parent)
    -- Title
    local title = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 12, -10)
    title:SetText("Silencer")
    title:SetTextColor(0.2, 0.8, 1.0)

    -- Close button
    local closeBtn = CreateFrame("Button", nil, parent, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -2, -2)

    -- Status indicator (button to toggle)
    local statusLabel = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    statusLabel:SetSize(90, 22)
    statusLabel:SetPoint("TOPRIGHT", -30, -8)
    statusLabel:SetScript("OnClick", function()
        Silencer:Toggle()
    end)
    statusLabel:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Click to toggle filtering", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    statusLabel:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    self.statusLabel = statusLabel

    -- Keyword label
    local kwLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    kwLabel:SetPoint("TOPLEFT", 12, -38)
    kwLabel:SetText("Match word:")
    kwLabel:SetTextColor(0.7, 0.7, 0.7)

    -- Keyword editbox
    local kwEditBox = CreateFrame("EditBox", "SilencerKeywordEditBox", parent, "InputBoxTemplate")
    kwEditBox:SetSize(120, 20)
    kwEditBox:SetPoint("LEFT", kwLabel, "RIGHT", 8, 0)
    kwEditBox:SetAutoFocus(false)
    kwEditBox:SetText(SilencerDB.keyword or "inv")
    kwEditBox:SetScript("OnEnterPressed", function(eb)
        local text = strtrim(eb:GetText())
        if text ~= "" then
            SilencerDB.keyword = text
            print(ADDON_PREFIX .. "Keyword set to: |cFFFFFF00" .. text .. "|r")
            Silencer:UpdateEmptyText()
        end
        eb:ClearFocus()
    end)
    kwEditBox:SetScript("OnEscapePressed", function(eb)
        eb:SetText(SilencerDB.keyword or "")
        eb:ClearFocus()
    end)
    self.kwEditBox = kwEditBox

    -- Class filter toggle buttons
    self:BuildClassButtons(parent)

    -- Blocked words section
    self:BuildBlockedWordsSection(parent)
end

--------------------------------------------------------------
-- Class filter toggle buttons
--------------------------------------------------------------

function Silencer:BuildClassButtons(parent)
    local BUTTON_SIZE = 24
    local BUTTON_SPACING = 4
    local totalWidth = #CLASS_ORDER * BUTTON_SIZE + (#CLASS_ORDER - 1) * BUTTON_SPACING
    local startX = (FRAME_WIDTH - totalWidth) / 2

    self.classButtons = {}
    for i, class in ipairs(CLASS_ORDER) do
        local btn = CreateFrame("Button", nil, parent)
        btn:SetSize(BUTTON_SIZE, BUTTON_SIZE)
        btn:SetPoint("TOPLEFT", startX + (i - 1) * (BUTTON_SIZE + BUTTON_SPACING), -58)

        local icon = btn:CreateTexture(nil, "ARTWORK")
        icon:SetAllPoints()
        icon:SetTexture(CLASS_ICONS[class])
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        btn.icon = icon

        local border = btn:CreateTexture(nil, "BACKGROUND")
        border:SetPoint("TOPLEFT", -1, 1)
        border:SetPoint("BOTTOMRIGHT", 1, -1)
        border:SetColorTexture(0.4, 0.4, 0.4, 0.8)
        btn.border = border

        btn.className = class
        btn:SetScript("OnClick", function(self)
            if SilencerDB.blockedClasses[class] then
                SilencerDB.blockedClasses[class] = nil
            else
                SilencerDB.blockedClasses[class] = true
            end
            Silencer:UpdateClassButton(btn)
            -- Refresh tooltip while hovering
            if GameTooltip:GetOwner() == self then
                GameTooltip:ClearLines()
                local localName = class:sub(1, 1) .. class:sub(2):lower()
                local status = SilencerDB.blockedClasses[class] and "|cFFFF4444Blocked|r" or "|cFF00FF00Allowed|r"
                GameTooltip:AddLine(localName .. " - " .. status)
                GameTooltip:AddLine("Click to toggle", 0.7, 0.7, 0.7)
                GameTooltip:Show()
            end
        end)

        btn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            local localName = class:sub(1, 1) .. class:sub(2):lower()
            local status = SilencerDB.blockedClasses[class] and "|cFFFF4444Blocked|r" or "|cFF00FF00Allowed|r"
            GameTooltip:AddLine(localName .. " - " .. status)
            GameTooltip:AddLine("Click to toggle", 0.7, 0.7, 0.7)
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)

        self.classButtons[i] = btn
        self:UpdateClassButton(btn)
    end
end

function Silencer:UpdateClassButton(btn)
    local blocked = SilencerDB.blockedClasses[btn.className]
    if blocked then
        btn.icon:SetDesaturated(true)
        btn.icon:SetVertexColor(0.6, 0.2, 0.2)
        btn.border:SetColorTexture(0.6, 0.1, 0.1, 0.9)
    else
        btn.icon:SetDesaturated(false)
        btn.icon:SetVertexColor(1, 1, 1)
        btn.border:SetColorTexture(0.4, 0.4, 0.4, 0.8)
    end
end

function Silencer:UpdateAllClassButtons()
    if not self.classButtons then return end
    for _, btn in ipairs(self.classButtons) do
        self:UpdateClassButton(btn)
    end
end

--------------------------------------------------------------
-- Blocked words UI section
--------------------------------------------------------------

function Silencer:BuildBlockedWordsSection(parent)
    local yOffset = -90

    -- "Blocked words" enable checkbox
    local bwCheck = CreateFrame("CheckButton", "SilencerBWCheck", parent, "UICheckButtonTemplate")
    bwCheck:SetSize(24, 24)
    bwCheck:SetPoint("TOPLEFT", 8, yOffset)
    bwCheck:SetChecked(SilencerDB.blockedWordsEnabled)
    bwCheck:SetScript("OnClick", function(cb)
        SilencerDB.blockedWordsEnabled = cb:GetChecked()
        Silencer:UpdateBlockedWordsState()
    end)
    local bwLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    bwLabel:SetPoint("LEFT", bwCheck, "RIGHT", 2, 0)
    bwLabel:SetText("Blocked words")
    bwLabel:SetTextColor(0.9, 0.9, 0.9)
    self.bwCheck = bwCheck
    self.bwLabel = bwLabel

    -- "Override match" checkbox
    local ovCheck = CreateFrame("CheckButton", "SilencerOVCheck", parent, "UICheckButtonTemplate")
    ovCheck:SetSize(24, 24)
    ovCheck:SetPoint("LEFT", bwLabel, "RIGHT", 12, 0)
    ovCheck:SetChecked(SilencerDB.blockedWordsOverride)
    ovCheck:SetScript("OnClick", function(cb)
        SilencerDB.blockedWordsOverride = cb:GetChecked()
    end)
    ovCheck:SetScript("OnEnter", function(btn)
        GameTooltip:SetOwner(btn, "ANCHOR_TOP")
        GameTooltip:AddLine("Override match", 1, 1, 1)
        GameTooltip:AddLine("When enabled, blocked words always filter the message even if it contains your match word", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    ovCheck:SetScript("OnLeave", function() GameTooltip:Hide() end)
    local ovLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    ovLabel:SetPoint("LEFT", ovCheck, "RIGHT", 2, 0)
    ovLabel:SetText("Override match")
    ovLabel:SetTextColor(0.9, 0.9, 0.9)
    self.ovCheck = ovCheck
    self.ovLabel = ovLabel

    -- Word add editbox
    local wordEditBox = CreateFrame("EditBox", "SilencerWordEditBox", parent, "InputBoxTemplate")
    wordEditBox:SetSize(200, 20)
    wordEditBox:SetPoint("TOPLEFT", 12, yOffset - 24)
    wordEditBox:SetAutoFocus(false)
    wordEditBox:SetScript("OnEnterPressed", function(eb)
        Silencer:AddBlockedWordFromEditBox(eb)
    end)
    wordEditBox:SetScript("OnEscapePressed", function(eb)
        eb:SetText("")
        eb:ClearFocus()
    end)
    self.wordEditBox = wordEditBox

    -- Add button
    local addBtn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    addBtn:SetSize(45, 20)
    addBtn:SetPoint("LEFT", wordEditBox, "RIGHT", 5, 0)
    addBtn:SetText("Add")
    addBtn:SetScript("OnClick", function()
        Silencer:AddBlockedWordFromEditBox(self.wordEditBox)
    end)
    self.wordAddBtn = addBtn

    -- Word list scroll frame
    local listFrame = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    listFrame:SetPoint("TOPLEFT", 8, yOffset - 48)
    listFrame:SetPoint("RIGHT", parent, "RIGHT", -8, 0)
    listFrame:SetHeight(WORD_ROW_HEIGHT * WORD_VISIBLE_ROWS + 4)
    listFrame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    listFrame:SetBackdropColor(0.05, 0.05, 0.05, 0.8)
    listFrame:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)

    local wordScroll = CreateFrame("ScrollFrame", "SilencerWordScroll", listFrame, "FauxScrollFrameTemplate")
    wordScroll:SetPoint("TOPLEFT", 2, -2)
    wordScroll:SetPoint("BOTTOMRIGHT", -20, 2)
    self.wordScroll = wordScroll

    -- Word rows (pre-created, reused)
    self.wordRows = {}
    for i = 1, WORD_VISIBLE_ROWS do
        local row = CreateFrame("Frame", nil, listFrame)
        row:SetSize(listFrame:GetWidth() - 24, WORD_ROW_HEIGHT)
        row:SetPoint("TOPLEFT", wordScroll, "TOPLEFT", 0, -((i - 1) * WORD_ROW_HEIGHT))

        row.text = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.text:SetPoint("LEFT", 4, 0)
        row.text:SetTextColor(1.0, 0.4, 0.4)

        row.removeBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        row.removeBtn:SetSize(18, 16)
        row.removeBtn:SetPoint("RIGHT", -2, 0)
        row.removeBtn:SetText("X")
        row.removeBtn:SetScript("OnClick", function()
            if row.wordIndex and SilencerDB.blockedWords[row.wordIndex] then
                tremove(SilencerDB.blockedWords, row.wordIndex)
                Silencer:UpdateBlockedWordsList()
            end
        end)

        self.wordRows[i] = row
    end

    wordScroll:SetScript("OnVerticalScroll", function(sf, offset)
        FauxScrollFrame_OnVerticalScroll(sf, offset, WORD_ROW_HEIGHT, function()
            Silencer:UpdateBlockedWordsList()
        end)
    end)

    -- Empty text for word list
    local wordEmptyText = listFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    wordEmptyText:SetPoint("CENTER")
    wordEmptyText:SetText("No blocked words")
    wordEmptyText:SetTextColor(0.4, 0.4, 0.4)
    self.wordEmptyText = wordEmptyText

    self:UpdateBlockedWordsState()
end

function Silencer:AddBlockedWordFromEditBox(editBox)
    local word = strtrim(editBox:GetText())
    if word == "" then return end

    if strlower(word) == strlower(SilencerDB.keyword or "") then
        print(ADDON_PREFIX .. "|cFFFF4444Cannot add '" .. word .. "' - it's your active match word|r")
        return
    end

    for _, existing in ipairs(SilencerDB.blockedWords) do
        if strlower(existing) == strlower(word) then
            print(ADDON_PREFIX .. "|cFFFF4444'" .. word .. "' is already in blocked words|r")
            return
        end
    end

    tinsert(SilencerDB.blockedWords, word)
    editBox:SetText("")
    editBox:ClearFocus()
    self:UpdateBlockedWordsList()
end

function Silencer:UpdateBlockedWordsState()
    if not self.ovCheck then return end
    local enabled = SilencerDB.blockedWordsEnabled
    if enabled then
        self.ovCheck:Enable()
        self.ovLabel:SetTextColor(0.9, 0.9, 0.9)
        self.wordEditBox:Enable()
        self.wordAddBtn:Enable()
    else
        self.ovCheck:Disable()
        self.ovLabel:SetTextColor(0.4, 0.4, 0.4)
        self.wordEditBox:Disable()
        self.wordAddBtn:Disable()
    end
end

--------------------------------------------------------------
-- Scroll list (FauxScrollFrame)
--------------------------------------------------------------

function Silencer:BuildScrollList(parent)
    local scrollFrame = CreateFrame("ScrollFrame", "SilencerScrollFrame", parent, "FauxScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 5, -(HEADER_HEIGHT + 5))
    scrollFrame:SetPoint("BOTTOMRIGHT", -28, FOOTER_HEIGHT + 5)
    self.scrollFrame = scrollFrame

    parent.rows = {}
    for i = 1, VISIBLE_ROWS do
        parent.rows[i] = self:CreateQueueRow(parent, i)
    end
    self.rows = parent.rows

    scrollFrame:SetScript("OnVerticalScroll", function(sf, offset)
        FauxScrollFrame_OnVerticalScroll(sf, offset, ROW_HEIGHT, function()
            Silencer:UpdateList()
        end)
    end)

    -- Empty state
    local emptyText = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    emptyText:SetPoint("CENTER", scrollFrame, "CENTER", 0, 0)
    emptyText:SetTextColor(0.5, 0.5, 0.5)
    emptyText:SetText("No whispers matching '" .. (SilencerDB.keyword or "inv") .. "'")
    emptyText:Hide()
    self.emptyText = emptyText
end

function Silencer:CreateQueueRow(parent, index)
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(FRAME_WIDTH - 50, ROW_HEIGHT)
    row:SetPoint("TOPLEFT", self.scrollFrame, "TOPLEFT", 0, -((index - 1) * ROW_HEIGHT))

    -- Player name
    row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.nameText:SetPoint("LEFT", 5, 0)
    row.nameText:SetWidth(80)
    row.nameText:SetJustifyH("LEFT")
    row.nameText:SetTextColor(0.6, 0.8, 1.0)

    -- Message preview
    row.msgText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.msgText:SetPoint("LEFT", row.nameText, "RIGHT", 5, 0)
    row.msgText:SetWidth(150)
    row.msgText:SetJustifyH("LEFT")
    row.msgText:SetTextColor(0.9, 0.9, 0.9)

    -- Dismiss button (X) - rightmost
    row.dismissBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.dismissBtn:SetSize(22, 20)
    row.dismissBtn:SetPoint("RIGHT", -2, 0)
    row.dismissBtn:SetText("X")
    row.dismissBtn:SetScript("OnClick", function()
        if row.queueIndex and row.activeQueue and row.activeQueue[row.queueIndex] then
            tremove(row.activeQueue, row.queueIndex)
            Silencer:UpdateList()
            Silencer:UpdateCounters()
        end
    end)

    -- Invite button - left of dismiss
    row.inviteBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.inviteBtn:SetSize(50, 20)
    row.inviteBtn:SetPoint("RIGHT", row.dismissBtn, "LEFT", -3, 0)
    row.inviteBtn:SetText("Invite")
    row.inviteBtn:SetScript("OnClick", function()
        if row.queueIndex and row.activeQueue and row.activeQueue[row.queueIndex] then
            local entry = row.activeQueue[row.queueIndex]
            InvitePlayer(entry.fullName)
            print(ADDON_PREFIX .. "Invited |cFFFFFF00" .. entry.name .. "|r")
            tremove(row.activeQueue, row.queueIndex)
            Silencer:UpdateList()
            Silencer:UpdateCounters()
        end
    end)

    -- Hover highlight
    row.highlight = row:CreateTexture(nil, "HIGHLIGHT")
    row.highlight:SetAllPoints()
    row.highlight:SetColorTexture(1, 1, 1, 0.08)

    -- Tooltip for full message
    row:EnableMouse(true)
    row:SetScript("OnEnter", function(self)
        if self.fullMessage then
            GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
            local nameColor = self.entryClass and RAID_CLASS_COLORS[self.entryClass]
            if nameColor then
                GameTooltip:AddLine(self.senderName or "", nameColor.r, nameColor.g, nameColor.b)
            else
                GameTooltip:AddLine(self.senderName or "", 0.6, 0.8, 1.0)
            end
            if self.entryClassLocal and self.entryClassLocal ~= "Unknown" then
                GameTooltip:AddLine(self.entryClassLocal, 0.7, 0.7, 0.7)
            end
            if self.entryClassBlocked then
                GameTooltip:AddLine("Blocked class", 1.0, 0.3, 0.3)
            end
            if self.entryFilterReason then
                GameTooltip:AddLine("Blocked words: " .. self.entryFilterReason, 1.0, 1.0, 0.2)
            end
            GameTooltip:AddLine(self.fullMessage, 1, 1, 1, true)
            GameTooltip:Show()
        end
    end)
    row:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    return row
end

--------------------------------------------------------------
-- Footer: counters
--------------------------------------------------------------

function Silencer:BuildFooter(parent)
    -- Matched counter (clickable)
    local matchedBtn = CreateFrame("Button", nil, parent)
    matchedBtn:SetPoint("BOTTOMLEFT", 8, 5)
    matchedBtn:SetSize(100, 16)
    matchedBtn.text = matchedBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    matchedBtn.text:SetAllPoints()
    matchedBtn.text:SetJustifyH("LEFT")
    matchedBtn.text:SetText("0 matched")
    matchedBtn:SetScript("OnClick", function()
        viewMode = "matched"
        Silencer:UpdateList()
        Silencer:UpdateCounters()
    end)
    matchedBtn:SetScript("OnEnter", function(self)
        self.text:SetTextColor(1, 1, 1)
    end)
    matchedBtn:SetScript("OnLeave", function(self)
        Silencer:UpdateCounterColors()
    end)
    self.matchedBtn = matchedBtn

    -- Separator
    local sep = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sep:SetPoint("LEFT", matchedBtn, "RIGHT", 2, 0)
    sep:SetText("|")
    sep:SetTextColor(0.5, 0.5, 0.5)

    -- Silenced counter (clickable)
    local silencedBtn = CreateFrame("Button", nil, parent)
    silencedBtn:SetPoint("LEFT", sep, "RIGHT", 2, 0)
    silencedBtn:SetSize(100, 16)
    silencedBtn.text = silencedBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    silencedBtn.text:SetAllPoints()
    silencedBtn.text:SetJustifyH("LEFT")
    silencedBtn.text:SetText("0 silenced")
    silencedBtn:SetScript("OnClick", function()
        viewMode = "silenced"
        Silencer:UpdateList()
        Silencer:UpdateCounters()
    end)
    silencedBtn:SetScript("OnEnter", function(self)
        self.text:SetTextColor(1, 1, 1)
    end)
    silencedBtn:SetScript("OnLeave", function(self)
        Silencer:UpdateCounterColors()
    end)
    self.silencedBtn = silencedBtn

    -- Separator 2
    local sep2 = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sep2:SetPoint("LEFT", silencedBtn, "RIGHT", 2, 0)
    sep2:SetText("|")
    sep2:SetTextColor(0.5, 0.5, 0.5)

    -- Blocked-word counter (clickable)
    local blockedWordBtn = CreateFrame("Button", nil, parent)
    blockedWordBtn:SetPoint("LEFT", sep2, "RIGHT", 2, 0)
    blockedWordBtn:SetSize(110, 16)
    blockedWordBtn.text = blockedWordBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    blockedWordBtn.text:SetAllPoints()
    blockedWordBtn.text:SetJustifyH("LEFT")
    blockedWordBtn.text:SetText("0 blocked-word")
    blockedWordBtn:SetScript("OnClick", function()
        viewMode = "blockedword"
        Silencer:UpdateList()
        Silencer:UpdateCounters()
    end)
    blockedWordBtn:SetScript("OnEnter", function(btn)
        btn.text:SetTextColor(1, 1, 1)
    end)
    blockedWordBtn:SetScript("OnLeave", function(btn)
        Silencer:UpdateCounterColors()
    end)
    self.blockedWordBtn = blockedWordBtn
end

--------------------------------------------------------------
-- UI update functions
--------------------------------------------------------------

function Silencer:UpdateList()
    if not self.frame or not self.frame:IsShown() then return end
    if not self.scrollFrame then return end

    local activeQueue
    if viewMode == "blockedword" then
        activeQueue = blockedWordQueue
    elseif viewMode == "silenced" then
        activeQueue = silencedQueue
    else
        activeQueue = queue
    end
    local showInvite = viewMode == "matched"
    local numItems = #activeQueue
    local offset = FauxScrollFrame_GetOffset(self.scrollFrame)

    FauxScrollFrame_Update(self.scrollFrame, numItems, VISIBLE_ROWS, ROW_HEIGHT)

    for i = 1, VISIBLE_ROWS do
        local row = self.rows[i]
        local index = offset + i
        local entry = activeQueue[index]

        if entry then
            row.queueIndex = index
            row.senderName = entry.name
            row.fullMessage = entry.message
            row.activeQueue = activeQueue
            row.entryClass = entry.class
            row.entryClassLocal = entry.classLocal
            row.entryClassBlocked = entry.classBlocked
            row.entryFilterReason = entry.filterReason

            row.nameText:SetText(entry.name)

            -- Class-colored name
            local classColor = entry.class and RAID_CLASS_COLORS[entry.class]
            if classColor then
                row.nameText:SetTextColor(classColor.r, classColor.g, classColor.b)
            else
                row.nameText:SetTextColor(0.6, 0.8, 1.0)
            end

            -- Truncate message for display
            local displayMsg = entry.message
            if #displayMsg > 35 then
                displayMsg = displayMsg:sub(1, 32) .. "..."
            end
            row.msgText:SetText(displayMsg)

            if showInvite then
                row.inviteBtn:Show()
            else
                row.inviteBtn:Hide()
            end

            row:Show()
        else
            row.queueIndex = nil
            row.senderName = nil
            row.fullMessage = nil
            row.activeQueue = nil
            row.entryClass = nil
            row.entryClassLocal = nil
            row.entryClassBlocked = nil
            row.entryFilterReason = nil
            row:Hide()
        end
    end

    -- Empty state
    if numItems == 0 then
        self:UpdateEmptyText()
        self.emptyText:Show()
    else
        self.emptyText:Hide()
    end
end

function Silencer:UpdateCounters()
    if self.matchedBtn then
        self.matchedBtn.text:SetText(#queue .. " matched")
    end
    if self.silencedBtn then
        self.silencedBtn.text:SetText(#silencedQueue .. " silenced")
    end
    if self.blockedWordBtn then
        self.blockedWordBtn.text:SetText(#blockedWordQueue .. " blocked-word")
    end
    self:UpdateCounterColors()
end

function Silencer:UpdateCounterColors()
    if self.matchedBtn then
        if viewMode == "matched" then
            self.matchedBtn.text:SetTextColor(0.2, 0.8, 1.0)
        else
            self.matchedBtn.text:SetTextColor(0.5, 0.5, 0.5)
        end
    end
    if self.silencedBtn then
        if viewMode == "silenced" then
            self.silencedBtn.text:SetTextColor(1.0, 0.6, 0.2)
        else
            self.silencedBtn.text:SetTextColor(0.5, 0.5, 0.5)
        end
    end
    if self.blockedWordBtn then
        if viewMode == "blockedword" then
            self.blockedWordBtn.text:SetTextColor(1.0, 0.3, 0.3)
        else
            self.blockedWordBtn.text:SetTextColor(0.5, 0.5, 0.5)
        end
    end
end

function Silencer:UpdateToggleButton()
    if self.statusLabel then
        if isEnabled then
            self.statusLabel:SetText("|cFF33FF33Silencing...|r")
        else
            self.statusLabel:SetText("Idle")
        end
    end
end

function Silencer:UpdateKeywordDisplay()
    if self.kwEditBox then
        self.kwEditBox:SetText(SilencerDB.keyword or "")
    end
    self:UpdateEmptyText()
end

function Silencer:UpdateEmptyText()
    if self.emptyText then
        if viewMode == "blockedword" then
            self.emptyText:SetText("No blocked-word whispers")
        elseif viewMode == "silenced" then
            self.emptyText:SetText("No silenced whispers")
        else
            self.emptyText:SetText("No whispers matching '" .. (SilencerDB.keyword or "") .. "'")
        end
    end
end

function Silencer:UpdateBlockedWordsList()
    if not self.wordScroll then return end

    local words = SilencerDB.blockedWords
    local numWords = #words
    local offset = FauxScrollFrame_GetOffset(self.wordScroll)

    FauxScrollFrame_Update(self.wordScroll, numWords, WORD_VISIBLE_ROWS, WORD_ROW_HEIGHT)

    for i = 1, WORD_VISIBLE_ROWS do
        local row = self.wordRows[i]
        local index = offset + i
        if index <= numWords then
            row.wordIndex = index
            row.text:SetText(words[index])
            row:Show()
        else
            row.wordIndex = nil
            row:Hide()
        end
    end

    if numWords == 0 then
        self.wordEmptyText:Show()
    else
        self.wordEmptyText:Hide()
    end
end

--------------------------------------------------------------
-- Frame show/hide/toggle
--------------------------------------------------------------

function Silencer:ShowFrame()
    if not self.frame then
        self:CreateMainFrame()
    end
    self.frame:Show()
    self:UpdateList()
    self:UpdateCounters()
    self:UpdateToggleButton()
end

function Silencer:HideFrame()
    if self.frame then
        self.frame:Hide()
    end
end

function Silencer:ToggleFrame()
    if self.frame and self.frame:IsShown() then
        self:HideFrame()
    else
        self:ShowFrame()
    end
end

--------------------------------------------------------------
-- Party and raid frame indicators
-- Party: overlays on PartyFrame.MemberFrame1-4 (5-player groups)
-- Raid: overlays on CompactRaidGroup<G>Member<M> (raid groups)
--------------------------------------------------------------

local INDICATOR_SIZE = 14
local RAID_INDICATOR_SIZE = 10
local partyIndicators = {} -- [1-4] = { silencerIcon, ignoreIcon }
local raidIndicators = {} -- [frameName] = { silencerIcon, ignoreIcon }

local function CreatePartyIndicator(memberFrame)
    if not memberFrame then return nil end

    local indicator = {}

    -- Silencer-filtered icon (bottom position, right side of frame)
    local silBtn = CreateFrame("Button", nil, memberFrame)
    silBtn:SetSize(INDICATOR_SIZE, INDICATOR_SIZE)
    silBtn:SetPoint("TOPRIGHT", memberFrame, "TOPRIGHT", -2, -2)
    silBtn:SetFrameLevel(memberFrame:GetFrameLevel() + 10)

    local silIcon = silBtn:CreateTexture(nil, "ARTWORK")
    silIcon:SetAllPoints()
    silIcon:SetTexture("Interface\\Icons\\Spell_Holy_Silence")
    silIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    local silBorder = silBtn:CreateTexture(nil, "BACKGROUND")
    silBorder:SetPoint("TOPLEFT", -1, 1)
    silBorder:SetPoint("BOTTOMRIGHT", 1, -1)
    silBorder:SetColorTexture(0, 0, 0, 0.8)

    silBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Whisper filtered", 0.2, 0.8, 1.0)
        GameTooltip:Show()
    end)
    silBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    silBtn:Hide()
    indicator.silencerIcon = silBtn

    -- WoW ignored icon (above silencer icon)
    local ignBtn = CreateFrame("Button", nil, memberFrame)
    ignBtn:SetSize(INDICATOR_SIZE, INDICATOR_SIZE)
    ignBtn:SetPoint("RIGHT", silBtn, "LEFT", -2, 0)
    ignBtn:SetFrameLevel(memberFrame:GetFrameLevel() + 10)

    local ignIcon = ignBtn:CreateTexture(nil, "ARTWORK")
    ignIcon:SetAllPoints()
    ignIcon:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcon_7")

    local ignBorder = ignBtn:CreateTexture(nil, "BACKGROUND")
    ignBorder:SetPoint("TOPLEFT", -1, 1)
    ignBorder:SetPoint("BOTTOMRIGHT", 1, -1)
    ignBorder:SetColorTexture(0, 0, 0, 0.8)

    ignBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("On ignore list", 1.0, 0.3, 0.3)
        GameTooltip:Show()
    end)
    ignBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    ignBtn:Hide()
    indicator.ignoreIcon = ignBtn

    return indicator
end

local function CreateRaidIndicator(frame)
    if not frame then return nil end

    local indicator = {}

    -- Silencer-filtered icon (right side, bottom)
    local silBtn = CreateFrame("Button", nil, frame)
    silBtn:SetSize(RAID_INDICATOR_SIZE, RAID_INDICATOR_SIZE)
    silBtn:SetPoint("RIGHT", frame, "RIGHT", -2, -4)
    silBtn:SetFrameLevel(frame:GetFrameLevel() + 10)

    local silIcon = silBtn:CreateTexture(nil, "ARTWORK")
    silIcon:SetAllPoints()
    silIcon:SetTexture("Interface\\Icons\\Spell_Holy_Silence")
    silIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    local silBorder = silBtn:CreateTexture(nil, "BACKGROUND")
    silBorder:SetPoint("TOPLEFT", -1, 1)
    silBorder:SetPoint("BOTTOMRIGHT", 1, -1)
    silBorder:SetColorTexture(0, 0, 0, 0.8)

    silBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Whisper filtered", 0.2, 0.8, 1.0)
        GameTooltip:Show()
    end)
    silBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    silBtn:Hide()
    indicator.silencerIcon = silBtn

    -- WoW ignored icon (right side, top)
    local ignBtn = CreateFrame("Button", nil, frame)
    ignBtn:SetSize(RAID_INDICATOR_SIZE, RAID_INDICATOR_SIZE)
    ignBtn:SetPoint("RIGHT", frame, "RIGHT", -2, 4)
    ignBtn:SetFrameLevel(frame:GetFrameLevel() + 10)

    local ignIcon = ignBtn:CreateTexture(nil, "ARTWORK")
    ignIcon:SetAllPoints()
    ignIcon:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcon_7")

    local ignBorder = ignBtn:CreateTexture(nil, "BACKGROUND")
    ignBorder:SetPoint("TOPLEFT", -1, 1)
    ignBorder:SetPoint("BOTTOMRIGHT", 1, -1)
    ignBorder:SetColorTexture(0, 0, 0, 0.8)

    ignBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("On ignore list", 1.0, 0.3, 0.3)
        GameTooltip:Show()
    end)
    ignBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    ignBtn:Hide()
    indicator.ignoreIcon = ignBtn

    return indicator
end

local function UpdateIndicator(indicator, name, anchorFrame, anchorPoint, size, offsetY)
    local showSilencer = false
    local showIgnore = false

    if name then
        showSilencer = filteredPlayers[name] or false
        showIgnore = IsPlayerOnIgnoreList(name)
    end

    if showSilencer then
        indicator.silencerIcon:Show()
    else
        indicator.silencerIcon:Hide()
    end

    if showIgnore then
        indicator.ignoreIcon:Show()
    else
        indicator.ignoreIcon:Hide()
    end
end

function Silencer:UpdatePartyIndicators()
    -- Update party frame indicators (PartyFrame.MemberFrame1-4)
    local partyFrame = _G["PartyFrame"]
    for i = 1, 4 do
        local memberFrame = partyFrame and partyFrame["MemberFrame" .. i]

        -- Hook OnShow to catch visibility changes after UI rebuilds
        if memberFrame and not memberFrame._silencerHooked then
            memberFrame:HookScript("OnShow", function()
                C_Timer.After(0.1, function() Silencer:UpdatePartyIndicators() end)
            end)
            memberFrame._silencerHooked = true
        end

        if memberFrame and memberFrame:IsVisible() then
            if not partyIndicators[i] then
                partyIndicators[i] = CreatePartyIndicator(memberFrame)
            end

            local indicator = partyIndicators[i]
            if indicator then
                local unitId = "party" .. i
                local name = UnitName(unitId)
                if not (name and UnitExists(unitId)) then name = nil end

                UpdateIndicator(indicator, name)
            end
        else
            local indicator = partyIndicators[i]
            if indicator then
                indicator.silencerIcon:Hide()
                indicator.ignoreIcon:Hide()
            end
        end
    end

    -- Update compact raid frame indicators (CompactRaidGroup<G>Member<M>)
    for g = 1, 8 do
        for m = 1, 5 do
            local frameName = "CompactRaidGroup" .. g .. "Member" .. m
            local frame = _G[frameName]

            if frame and frame.unit and frame:IsVisible() then
                if not raidIndicators[frameName] then
                    raidIndicators[frameName] = CreateRaidIndicator(frame)
                end

                local indicator = raidIndicators[frameName]
                if indicator then
                    local name = UnitName(frame.unit)
                    if not UnitExists(frame.unit) then name = nil end

                    UpdateIndicator(indicator, name)

                    -- Adjust positioning for single icon (center it)
                    local showSilencer = name and filteredPlayers[name]
                    local showIgnore = name and IsPlayerOnIgnoreList(name)
                    if showSilencer and showIgnore then
                        indicator.silencerIcon:SetPoint("RIGHT", frame, "RIGHT", -2, -4)
                        indicator.ignoreIcon:SetPoint("RIGHT", frame, "RIGHT", -2, 4)
                    elseif showSilencer then
                        indicator.silencerIcon:SetPoint("RIGHT", frame, "RIGHT", -2, 0)
                    elseif showIgnore then
                        indicator.ignoreIcon:SetPoint("RIGHT", frame, "RIGHT", -2, 0)
                    end
                end
            else
                -- Frame not visible or no unit, hide indicators if they exist
                local indicator = raidIndicators[frameName]
                if indicator then
                    indicator.silencerIcon:Hide()
                    indicator.ignoreIcon:Hide()
                end
            end
        end
    end
end

--------------------------------------------------------------
-- Events
--------------------------------------------------------------

local eventFrame = CreateFrame("Frame")

eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
eventFrame:RegisterEvent("IGNORELIST_UPDATE")
eventFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        InitializeDB()
        LDBIcon:Register("Silencer", dataObject, SilencerDB.minimap)
        isEnabled = SilencerDB.enabled
        if isEnabled then
            Silencer:EnableFilter(true) -- silent: print not safe before PLAYER_LOGIN
        end
        self:UnregisterEvent("ADDON_LOADED")

    elseif event == "PLAYER_LOGIN" then
        local status = isEnabled
            and ("ON - keyword: |cFFFFFF00" .. (SilencerDB.keyword or "") .. "|r")
            or "OFF"
        print(ADDON_PREFIX .. "v" .. VERSION .. " loaded (" .. status .. "). Type |cFFFFFF00/sil|r for options.")
        self:UnregisterEvent("PLAYER_LOGIN")

    elseif event == "GROUP_ROSTER_UPDATE" or event == "IGNORELIST_UPDATE" then
        Silencer:UpdatePartyIndicators()
        -- Retry after delays to handle frame visibility timing
        C_Timer.After(0.5, function() Silencer:UpdatePartyIndicators() end)
        C_Timer.After(2, function() Silencer:UpdatePartyIndicators() end)
    end
end)
