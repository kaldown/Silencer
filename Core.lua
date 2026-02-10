-- Silencer: Whisper gatekeeper for keyword-based group building
-- Filters whispers by keyword, queues matches for manual review

local ADDON_NAME, Silencer = ...

local ADDON_PREFIX = "|cFF33CCFF[Silencer]|r "
local VERSION = GetAddOnMetadata(ADDON_NAME, "Version") or "dev"
local MAX_QUEUE = 50

local LDB = LibStub("LibDataBroker-1.1")
local LDBIcon = LibStub("LibDBIcon-1.0")

--------------------------------------------------------------
-- State
--------------------------------------------------------------

SilencerDB = SilencerDB or {}

local isEnabled = false
local queue = {}
local silencedCount = 0
local matchedCount = 0
local filterRegistered = false

local function InitializeDB()
    SilencerDB.keyword = SilencerDB.keyword or "inv"
    SilencerDB.enabled = SilencerDB.enabled or false
    SilencerDB.position = SilencerDB.position or nil
    SilencerDB.minimap = SilencerDB.minimap or { hide = false }
end

--------------------------------------------------------------
-- Minimap button (LibDataBroker + LibDBIcon)
--------------------------------------------------------------

local dataObject = LDB:NewDataObject("Silencer", {
    type = "launcher",
    icon = "Interface\\Icons\\Spell_Shadow_Silence",
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
-- Chat filter engine
--------------------------------------------------------------

local function WhisperFilter(chatFrame, event, msg, playerName, ...)
    if not isEnabled then
        return false
    end

    local keyword = SilencerDB.keyword
    if not keyword or keyword == "" then
        return false
    end

    if strlower(msg):find(strlower(keyword), 1, true) then
        -- Match: add to queue, suppress from chat
        matchedCount = matchedCount + 1

        local name, realm = strsplit("-", playerName, 2)

        local entry = {
            name = name,
            realm = realm or "",
            fullName = playerName,
            message = msg,
            time = GetTime(),
        }

        tinsert(queue, entry)
        if #queue > MAX_QUEUE then
            tremove(queue, 1)
        end

        Silencer:UpdateList()
        Silencer:UpdateCounters()
        return true
    else
        -- No match: suppress silently
        silencedCount = silencedCount + 1
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
    silencedCount = 0
    matchedCount = 0
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

    elseif msg == "clear" then
        wipe(queue)
        matchedCount = 0
        Silencer:UpdateList()
        Silencer:UpdateCounters()
        print(ADDON_PREFIX .. "Queue cleared")

    else
        print(ADDON_PREFIX .. "Commands:")
        print("  /sil - Toggle window")
        print("  /sil on - Enable filter")
        print("  /sil off - Disable filter")
        print("  /sil keyword <word> - Set keyword")
        print("  /sil status - Show status")
        print("  /sil clear - Clear queue")
    end
end

--------------------------------------------------------------
-- UI Constants
--------------------------------------------------------------

local FRAME_WIDTH = 380
local FRAME_HEIGHT = 350
local ROW_HEIGHT = 28
local VISIBLE_ROWS = 8
local HEADER_HEIGHT = 60
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

    -- ON/OFF toggle
    local toggleBtn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    toggleBtn:SetSize(50, 22)
    toggleBtn:SetPoint("TOPRIGHT", -30, -8)
    toggleBtn:SetText(isEnabled and "ON" or "OFF")
    toggleBtn:SetScript("OnClick", function()
        Silencer:Toggle()
    end)
    self.toggleBtn = toggleBtn

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
        if row.queueIndex and queue[row.queueIndex] then
            tremove(queue, row.queueIndex)
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
        if row.queueIndex and queue[row.queueIndex] then
            local entry = queue[row.queueIndex]
            InvitePlayer(entry.fullName)
            print(ADDON_PREFIX .. "Invited |cFFFFFF00" .. entry.name .. "|r")
            tremove(queue, row.queueIndex)
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
            GameTooltip:AddLine(self.senderName or "", 0.6, 0.8, 1.0)
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
    local counterText = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    counterText:SetPoint("BOTTOMLEFT", 12, 8)
    counterText:SetTextColor(0.7, 0.7, 0.7)
    counterText:SetText("0 matched | 0 silenced")
    self.counterText = counterText
end

--------------------------------------------------------------
-- UI update functions
--------------------------------------------------------------

function Silencer:UpdateList()
    if not self.frame or not self.frame:IsShown() then return end
    if not self.scrollFrame then return end

    local numItems = #queue
    local offset = FauxScrollFrame_GetOffset(self.scrollFrame)

    FauxScrollFrame_Update(self.scrollFrame, numItems, VISIBLE_ROWS, ROW_HEIGHT)

    for i = 1, VISIBLE_ROWS do
        local row = self.rows[i]
        local index = offset + i
        local entry = queue[index]

        if entry then
            row.queueIndex = index
            row.senderName = entry.name
            row.fullMessage = entry.message

            row.nameText:SetText(entry.name)

            -- Truncate message for display
            local displayMsg = entry.message
            if #displayMsg > 35 then
                displayMsg = displayMsg:sub(1, 32) .. "..."
            end
            row.msgText:SetText(displayMsg)

            row:Show()
        else
            row.queueIndex = nil
            row.senderName = nil
            row.fullMessage = nil
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
    if self.counterText then
        self.counterText:SetText(matchedCount .. " matched | " .. silencedCount .. " silenced")
    end
end

function Silencer:UpdateToggleButton()
    if self.toggleBtn then
        self.toggleBtn:SetText(isEnabled and "ON" or "OFF")
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
        self.emptyText:SetText("No whispers matching '" .. (SilencerDB.keyword or "") .. "'")
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
