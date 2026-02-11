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
local viewMode = "matched" -- "matched" or "silenced"

local function InitializeDB()
    SilencerDB.keyword = SilencerDB.keyword or "inv"
    SilencerDB.enabled = SilencerDB.enabled or false
    SilencerDB.position = SilencerDB.position or nil
    SilencerDB.minimap = SilencerDB.minimap or { hide = false }
    SilencerDB.blockedClasses = SilencerDB.blockedClasses or {}
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

local function WhisperFilter(chatFrame, event, msg, playerName, ...)
    if not isEnabled then
        return false
    end

    local keyword = SilencerDB.keyword
    if not keyword or keyword == "" then
        return false
    end

    -- GUID is the 10th vararg (event arg12, after msg and playerName)
    local guid = select(10, ...)
    local class, classLocal = GetSenderClass(guid)
    local name, realm = strsplit("-", playerName, 2)

    if strlower(msg):find(strlower(keyword), 1, true) then
        local isClassBlocked = class ~= "UNKNOWN" and SilencerDB.blockedClasses[class]

        local entry = {
            name = name,
            realm = realm or "",
            fullName = playerName,
            message = msg,
            time = GetTime(),
            class = class,
            classLocal = classLocal,
            classBlocked = isClassBlocked or false,
        }

        if isClassBlocked then
            -- Keyword matched but class blocked: route to silenced
            silencedCount = silencedCount + 1
            tinsert(silencedQueue, entry)
            if #silencedQueue > MAX_QUEUE then
                tremove(silencedQueue, 1)
            end
        else
            -- Keyword matched, class allowed: matched queue
            matchedCount = matchedCount + 1
            tinsert(queue, entry)
            if #queue > MAX_QUEUE then
                tremove(queue, 1)
            end
        end

        Silencer:UpdateList()
        Silencer:UpdateCounters()
        return true
    else
        -- No match: store and suppress
        silencedCount = silencedCount + 1

        local entry = {
            name = name,
            realm = realm or "",
            fullName = playerName,
            message = msg,
            time = GetTime(),
            class = class,
            classLocal = classLocal,
        }

        tinsert(silencedQueue, entry)
        if #silencedQueue > MAX_QUEUE then
            tremove(silencedQueue, 1)
        end

        Silencer:UpdateList()
        Silencer:UpdateCounters()
        return true
    end
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
    viewMode = "matched"
    self:UpdateToggleButton()
    self:UpdateCounters()
    if not silent then
        print(ADDON_PREFIX .. "Filter ON - keyword: |cFFFFFF00" .. (SilencerDB.keyword or "") .. "|r")
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
    silencedCount = 0
    matchedCount = 0
    viewMode = "matched"
    self:UpdateList()
    self:UpdateToggleButton()
    self:UpdateCounters()
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
            print(ADDON_PREFIX .. "Keyword set to: |cFFFFFF00" .. newKeyword .. "|r")
        end

    elseif msg == "status" then
        print(ADDON_PREFIX .. "Status: " .. (isEnabled and "|cFF00FF00ON|r" or "|cFFFF0000OFF|r"))
        print(ADDON_PREFIX .. "Keyword: |cFFFFFF00" .. (SilencerDB.keyword or "(none)") .. "|r")
        print(ADDON_PREFIX .. "Queue: " .. #queue .. " matched | " .. silencedCount .. " silenced")

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
        matchedCount = 0
        silencedCount = 0
        Silencer:UpdateList()
        Silencer:UpdateCounters()
        print(ADDON_PREFIX .. "Queue cleared")

    else
        print(ADDON_PREFIX .. "Commands:")
        print("  /sil - Toggle window")
        print("  /sil on - Enable filter")
        print("  /sil off - Disable filter")
        print("  /sil keyword <word> - Set keyword")
        print("  /sil block - Show blocked classes")
        print("  /sil status - Show status")
        print("  /sil clear - Clear queue")
    end
end

--------------------------------------------------------------
-- UI Constants
--------------------------------------------------------------

local FRAME_WIDTH = 380
local FRAME_HEIGHT = 378
local ROW_HEIGHT = 28
local VISIBLE_ROWS = 8
local HEADER_HEIGHT = 88
local FOOTER_HEIGHT = 25

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
    kwLabel:SetText("Keyword:")
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
end

--------------------------------------------------------------
-- UI update functions
--------------------------------------------------------------

function Silencer:UpdateList()
    if not self.frame or not self.frame:IsShown() then return end
    if not self.scrollFrame then return end

    local activeQueue = viewMode == "silenced" and silencedQueue or queue
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
        if viewMode == "silenced" then
            self.emptyText:SetText("No silenced whispers")
        else
            self.emptyText:SetText("No whispers matching '" .. (SilencerDB.keyword or "") .. "'")
        end
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
-- Events
--------------------------------------------------------------

local eventFrame = CreateFrame("Frame")

eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
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
    end
end)
