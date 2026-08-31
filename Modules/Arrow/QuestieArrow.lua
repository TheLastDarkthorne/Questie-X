---@class QuestieArrow
local QuestieArrow = QuestieLoader:CreateModule("QuestieArrow")

---@type ZoneDB
local ZoneDB = QuestieLoader:ImportModule("ZoneDB")
---@type QuestieLib
local QuestieLib = QuestieLoader:ImportModule("QuestieLib")
---@type QuestieMap
local QuestieMap = QuestieLoader:ImportModule("QuestieMap")
---@type QuestieTracker
local QuestieTracker = QuestieLoader:ImportModule("QuestieTracker")
---@type QuestieDB
local QuestieDB = QuestieLoader:ImportModule("QuestieDB")
---@type QuestiePlayer
local QuestiePlayer = QuestieLoader:ImportModule("QuestiePlayer")
---@type QuestieQuest
local QuestieQuest = QuestieLoader:ImportModule("QuestieQuest")
---@type QuestieArrowAssets
local QuestieArrowAssets = QuestieLoader:ImportModule("QuestieArrowAssets")
---@type TrackerUtils
local TrackerUtils = QuestieLoader:ImportModule("TrackerUtils")

local HBD = QuestieCompat.HBD or LibStub("HereBeDragonsQuestie-2.0")
local SharedMedia = LibStub and LibStub("LibSharedMedia-3.0", true)

local atan2 = math.atan2
local pi = math.pi
local floor = math.floor
local abs = math.abs
local max = math.max
local min = math.min

local ARROW_SHEET_SIZE = 512
local ARROW_CELL_W = 56
local ARROW_CELL_H = 42
local ARROW_IMAGE_SIZE = 96
local ARROW_SHEET_COLS = 9
local ARROW_SHEET_ROWS = 12
local ARROW_TOTAL_CELLS = ARROW_SHEET_COLS * ARROW_SHEET_ROWS
local ARROW_DEFAULT_STYLE = "arrow1"

local DEFAULT_UPDATE_THROTTLE_SECONDS = 0.05
local DEFAULT_RECALC_NEAREST_SECONDS = 1.0
local DEFAULT_TRACKER_REFRESH_THROTTLE_SECONDS = 0.5

---@type Frame?
local arrowFrame = nil
---@type Frame?
local objectiveFrame = nil
---@type Frame?
local driverFrame = nil

-- Current auto-tracked targets sorted by distance
local sortedTargets = {}
local hasManualTarget = false
local _targetsDirty = true  -- when true, next Refresh rebuilds from quest data
local _lastFocusComplete = nil  -- complete-state of the focused quest at the last rebuild

-- Shared context written by UpdateNearestTargets, read by hoisted helpers.
-- Avoids closure allocation on every call.
local _arrow_playerX, _arrow_playerY, _arrow_playerInstance
local _arrow_usingAutoLogic, _arrow_playerZoneId, _arrow_playerUiMapId
local _arrow_quest  -- current quest being processed by the hoisted helpers
local _arrow_zoneUiMapCache = {}

local lastPopulateByQuestId = {}

-- Profiling buffer: nil when inactive, a table when recording.
-- /questie arrow perf start  -> begins collecting samples
-- /questie arrow perf stop   -> stops and saves to QuestieConfig.ArrowPerfLog (persists on /reload)
-- /questie arrow perf show   -> prints summary of last run
-- /questie arrow perf clear  -> wipes saved data (from memory and SavedVariables)
local _arrowPerfLog = nil

function QuestieArrow:HandlePerfCommand(action)
    if action == "start" then
        _arrowPerfLog = {}
        print("|cff00ff00[Arrow Perf]|r Recording started. Play normally, then type /questie arrow perf stop")
    elseif action == "stop" then
        if not _arrowPerfLog then
            print("|cffff0000[Arrow Perf]|r Not recording.")
            return
        end
        QuestieConfig = QuestieConfig or {}
        QuestieConfig.ArrowPerfLog = _arrowPerfLog
        print(string.format("|cff00ff00[Arrow Perf]|r Stopped. %d samples saved. Type /questie arrow perf show for summary, or /reload to flush to disk.", #_arrowPerfLog))
        _arrowPerfLog = nil
    elseif action == "show" then
        local log = (_arrowPerfLog) or (QuestieConfig and QuestieConfig.ArrowPerfLog)
        if not log or #log == 0 then
            print("|cffff0000[Arrow Perf]|r No data. Run /questie arrow perf start first.")
            return
        end
        print(string.format("|cff00ff00[Arrow Perf]|r %d samples:", #log))
        local startIdx = max(1, #log - 29)
        for i = startIdx, #log do
            print("  " .. log[i])
        end
        if startIdx > 1 then
            print(string.format("  ... (%d earlier samples omitted, see WTF SavedVariables for full log)", startIdx - 1))
        end
    elseif action == "clear" then
        _arrowPerfLog = nil
        if QuestieConfig then QuestieConfig.ArrowPerfLog = nil end
        print("|cff00ff00[Arrow Perf]|r Cleared.")
    else
        print("|cff00ff00[Arrow Perf]|r Usage: /questie arrow perf [start|stop|show|clear]")
    end
end

local _GetBundledArrowStyle
local _GetProfilePosition
local _GetObjectiveProfilePosition
local EnsureObjectiveFrame
local EnsureArrowFrame

local function _IsArrowEnabled()
    if not Questie or not Questie.db or not Questie.db.profile then
        return true
    end
    return Questie.db.profile.arrowEnabled ~= false
end

local function _GetProfileNumber(key, defaultValue, minValue, maxValue)
    if not Questie or not Questie.db or not Questie.db.profile then
        return defaultValue
    end

    local value = Questie.db.profile[key]
    if type(value) ~= "number" then
        return defaultValue
    end
    if value < minValue then
        return minValue
    end
    if value > maxValue then
        return maxValue
    end
    return value
end

local function _GetArrowUpdateThrottle()
    return _GetProfileNumber("arrowUpdateThrottle", DEFAULT_UPDATE_THROTTLE_SECONDS, 0.03, 0.5)
end

local function _GetArrowRecalcInterval()
    return _GetProfileNumber("arrowRecalcInterval", DEFAULT_RECALC_NEAREST_SECONDS, 0.5, 10.0)
end

local function _GetArrowTrackerRefreshThrottle()
    return _GetProfileNumber("arrowTrackerRefreshThrottle", DEFAULT_TRACKER_REFRESH_THROTTLE_SECONDS, 0.25, 5.0)
end

local function _GetArrowScale()
    if not Questie or not Questie.db or not Questie.db.profile then
        return 1
    end
    return Questie.db.profile.arrowScale or 1
end

local function _GetArrowAlpha()
    if not Questie or not Questie.db or not Questie.db.profile then
        return 1.0
    end
    return Questie.db.profile.arrowAlpha or 1.0
end

local function _GetObjectiveAlpha()
    if not Questie or not Questie.db or not Questie.db.profile then
        return 1.0
    end
    return Questie.db.profile.arrowObjectiveAlpha or 1.0
end

local function _IsArrowLocked()
    if not Questie or not Questie.db or not Questie.db.profile then
        return false
    end
    return Questie.db.profile.arrowLocked == true
end

local function _IsObjectiveLocked()
    if not Questie or not Questie.db or not Questie.db.profile then
        return false
    end
    return Questie.db.profile.arrowObjectiveLocked == true
end

local function _IsObjectiveAttached()
    if not Questie or not Questie.db or not Questie.db.profile then
        return false
    end
    return Questie.db.profile.arrowObjectiveAttached == true
end

local function _GetObjectiveGap()
    if not Questie or not Questie.db or not Questie.db.profile then
        return 10
    end
    return Questie.db.profile.arrowObjectiveGap or 10
end

-- The quest the arrow is locked to, or nil when it should follow the nearest target.
local function _GetFocusedQuestId()
    if not Questie or not Questie.db or not Questie.db.profile then
        return nil
    end
    return Questie.db.profile.arrowFocusedQuestId
end

local function _GetDistanceUnit()
    if not Questie or not Questie.db or not Questie.db.profile then
        return "yards"
    end

    local unit = Questie.db.profile.arrowDistanceUnit or "yards"
    if unit ~= "yards" and unit ~= "meters" and unit ~= "feet" then
        return "yards"
    end

    return unit
end

local function _FormatDistance(dist)
    local unit = _GetDistanceUnit()
    local value = dist
    local suffix = " yd"

    if unit == "meters" then
        value = dist * 0.9144
        suffix = " m"
    elseif unit == "feet" then
        value = dist * 3
        suffix = " ft"
    end

    return string.format("%.1f%s", value, suffix)
end

local function _SortTargetByDistance(a, b)
    return a.distance < b.distance
end

local function _GetUiMapIdForZone(zone)
    if not zone then return nil end
    local cached = _arrow_zoneUiMapCache[zone]
    if cached ~= nil then
        return cached
    end

    local uiMapId = ZoneDB:GetUiMapIdByAreaId(zone)
    _arrow_zoneUiMapCache[zone] = uiMapId or false
    return uiMapId
end

local function _AddArrowTarget(x, y, uiMapId, title, questLevel, iconPath, worldX, worldY, worldInstance, distance)
    table.insert(sortedTargets, {
        x = x,
        y = y,
        uiMapId = uiMapId,
        title = title,
        questLevel = questLevel,
        iconPath = iconPath,
        worldX = worldX,
        worldY = worldY,
        worldInstance = worldInstance,
        distance = distance,
    })
end

local function _GetArrowStyleKey()
    if not Questie or not Questie.db or not Questie.db.profile then
        return ARROW_DEFAULT_STYLE
    end

    local styleKey = Questie.db.profile.arrowStyle
    if styleKey == "arrow" then
        styleKey = "arrow1"
    end
    if styleKey and styleKey ~= "custom" and _GetBundledArrowStyle(styleKey) then
        return styleKey
    end
    if styleKey == "custom" then
        return styleKey
    end

    return ARROW_DEFAULT_STYLE
end

local function _IsBundledSheetStyle(styleKey)
    return styleKey == "arrowold"
end

_GetBundledArrowStyle = function(styleKey)
    if QuestieArrowAssets and QuestieArrowAssets.GetStyleData then
        return QuestieArrowAssets:GetStyleData(styleKey)
    end
    return nil
end

local function _GetCustomArrowTexturePath()
    if not Questie or not Questie.db or not Questie.db.profile then
        return nil
    end

    local fileName = Questie.db.profile.arrowCustomTexture
    if not fileName or fileName == "" then
        return nil
    end

    fileName = string.match(fileName, "[^\\/]+$") or fileName
    fileName = string.gsub(fileName, "^%s+", "")
    fileName = string.gsub(fileName, "%s+$", "")
    if fileName == "" then
        return nil
    end

    if not string.find(string.lower(fileName), "%.tga$") then
        fileName = fileName .. ".tga"
    end

    return QuestieLib.AddonPath .. "Icons\\Arrows\\" .. fileName
end

local function _GetArrowStyle()
    local styleKey = _GetArrowStyleKey()
    if styleKey == "custom" then
        local customTexture = _GetCustomArrowTexturePath()
        local isSheet = Questie and Questie.db and Questie.db.profile and Questie.db.profile.arrowCustomIsSheet
        local defaultStyle = _GetBundledArrowStyle(ARROW_DEFAULT_STYLE)
        local fallbackTexture = defaultStyle and (QuestieLib.AddonPath .. defaultStyle.texture) or ""
        local displayWidth = isSheet and ARROW_CELL_W or ARROW_IMAGE_SIZE
        local displayHeight = isSheet and ARROW_CELL_H or ARROW_IMAGE_SIZE
        return {
            label = "Custom TGA",
            texturePath = customTexture or fallbackTexture,
            previewPath = customTexture or fallbackTexture,
            mode = isSheet and "sheet" or "image",
            displayWidth = displayWidth,
            displayHeight = displayHeight,
            textureCoordLeft = 0,
            textureCoordRight = 1,
            textureCoordTop = 0,
            textureCoordBottom = 1,
        }
    end

    local style = _GetBundledArrowStyle(styleKey) or _GetBundledArrowStyle(ARROW_DEFAULT_STYLE)
    local isSheet = _IsBundledSheetStyle(styleKey)
    local runtimeTexture = style.texture
    return {
        label = style.label,
        texturePath = QuestieLib.AddonPath .. runtimeTexture,
        sourceTexturePath = QuestieLib.AddonPath .. style.texture,
        previewPath = QuestieLib.AddonPath .. style.preview,
        mode = isSheet and "sheet" or "image",
        displayWidth = isSheet and (style.displayWidth or ARROW_CELL_W) or (style.displayWidth or ARROW_IMAGE_SIZE),
        displayHeight = isSheet and (style.displayHeight or ARROW_CELL_H) or (style.displayHeight or ARROW_IMAGE_SIZE),
        visualBottomInset = style.visualBottomInset or 0,
        textureCoordLeft = style.textureCoordLeft or 0,
        textureCoordRight = style.textureCoordRight or 1,
        textureCoordTop = style.textureCoordTop or 0,
        textureCoordBottom = style.textureCoordBottom or 1,
    }
end

local function _GetArrowTexturePath()
    local style = _GetArrowStyle()
    return style.texturePath
end

local function _GetArrowPreviewPath()
    local style = _GetArrowStyle()
    if not style then
        return nil
    end

    if style.previewPath and (type(DoesFileExist) ~= "function" or DoesFileExist(style.previewPath)) then
        return style.previewPath
    end

    return style.texturePath
end

local function _IsArrowSpriteSheet()
    return (_GetArrowStyle().mode == "sheet")
end

local function _ApplyArrowStyle()
    if not arrowFrame or not arrowFrame.arrow then
        return
    end

    local style = _GetArrowStyle()
    local styleSignature = table.concat({
        _GetArrowStyleKey(),
        style.texturePath or "",
        style.previewPath or "",
        style.mode or "",
        tostring(style.textureCoordLeft or 0),
        tostring(style.textureCoordRight or 1),
        tostring(style.textureCoordTop or 0),
        tostring(style.textureCoordBottom or 1),
    }, "|")
    local styleChanged = arrowFrame._arrowStyleSignature ~= styleSignature

    arrowFrame._arrowStyle = style
    arrowFrame._arrowStyleSignature = styleSignature

    if styleChanged then
        arrowFrame.arrow:SetTexture(nil)
        arrowFrame.arrow:SetTexture(style.texturePath)
        arrowFrame._arrowStyleMode = nil
    end

    if arrowFrame._arrowStyleMode ~= style.mode then
        if style.mode == "sheet" then
            arrowFrame.arrow:SetTexCoord(0, ARROW_CELL_W / ARROW_SHEET_SIZE, 0, ARROW_CELL_H / ARROW_SHEET_SIZE)
        else
            arrowFrame.arrow:SetTexCoord(
                style.textureCoordLeft or 0,
                style.textureCoordRight or 1,
                style.textureCoordTop or 0,
                style.textureCoordBottom or 1
            )
        end
        if arrowFrame.arrow.SetRotation then
            arrowFrame.arrow:SetRotation(0)
        end
        arrowFrame._arrowStyleMode = style.mode
    end

    local scale = _GetArrowScale()
    local width = (style.displayWidth or ARROW_IMAGE_SIZE) * scale
    local height = (style.displayHeight or ARROW_IMAGE_SIZE) * scale
    arrowFrame._arrowScaleSignature = table.concat({ styleSignature, tostring(scale) }, "|")
    arrowFrame.arrow:SetWidth(width)
    arrowFrame.arrow:SetHeight(height)
    if not arrowFrame._arrowStylePointSet then
        arrowFrame.arrow:SetPoint("TOP", arrowFrame, "TOP", 0, 0)
        arrowFrame._arrowStylePointSet = true
    end
end

local function _UpdateArrowFrameDimensions()
    if not arrowFrame or not arrowFrame.arrow then
        return
    end

    local style = _GetArrowStyle()
    local scale = _GetArrowScale()
    local width = (style.displayWidth or ARROW_IMAGE_SIZE) * scale
    local height = (style.displayHeight or ARROW_IMAGE_SIZE) * scale

    arrowFrame:SetWidth(width)
    arrowFrame:SetHeight(height)
end

local function _UpdateObjectiveFrameDimensions()
    if not objectiveFrame then
        return
    end

    local fontSize = 10
    if Questie and Questie.db and Questie.db.profile then
        fontSize = Questie.db.profile.arrowFontSize or fontSize
    end

    objectiveFrame:SetWidth(320)
    objectiveFrame:SetHeight(max(72, (fontSize * 2) + 40))
end

local function _UpdateObjectiveFramePosition()
    if not objectiveFrame then
        return
    end

    if objectiveFrame._isDragging then
        return
    end

    if _IsObjectiveAttached() and arrowFrame then
        local gap = _GetObjectiveGap()
        objectiveFrame:ClearAllPoints()
        objectiveFrame:SetPoint("TOP", arrowFrame, "BOTTOM", 0, gap)
        objectiveFrame._useDefaultPosition = false
        return
    end

    local pos = _GetObjectiveProfilePosition()
    if pos and pos.point and pos.relativePoint and pos.x and pos.y then
        objectiveFrame:ClearAllPoints()
        objectiveFrame:SetPoint(pos.point, UIParent, pos.relativePoint, pos.x, pos.y)
        objectiveFrame._useDefaultPosition = false
        return
    end

    objectiveFrame:ClearAllPoints()
    objectiveFrame:SetPoint("CENTER", UIParent, "CENTER", 0, -170)
    objectiveFrame._useDefaultPosition = true
end

local function _UpdateArrowFramePosition()
    if not arrowFrame then
        return
    end

    if arrowFrame._isDragging then
        return
    end

    local pos = _GetProfilePosition()
    if pos and pos.point and pos.relativePoint and pos.x and pos.y then
        arrowFrame:ClearAllPoints()
        arrowFrame:SetPoint(pos.point, UIParent, pos.relativePoint, pos.x, pos.y)
        arrowFrame._useDefaultPosition = false
        return
    end

    arrowFrame:ClearAllPoints()
    arrowFrame:SetPoint("CENTER", 0, -100)
    arrowFrame._useDefaultPosition = true
end

local function _UpdateObjectText(target)
    if not objectiveFrame then
        return
    end

    if not target then
        objectiveFrame.title:SetText("")
        objectiveFrame.distance:SetText("Distance: --")
        objectiveFrame.icon:Hide()
        return
    end

    local title = target.title or ""
    if target.questLevel then
        title = "[" .. target.questLevel .. "] " .. title
    end
    objectiveFrame.title:SetText(Questie:Colorize(title, "gold"))

    if target.iconPath then
        objectiveFrame.icon:SetTexture(target.iconPath)
        objectiveFrame.icon:Show()
    else
        objectiveFrame.icon:Hide()
    end
end

local function _ApplyArrowVisualScale()
    if not arrowFrame or not arrowFrame.arrow then
        return
    end

    _ApplyArrowStyle()
    _UpdateArrowFrameDimensions()
end

local function _SetArrowScale(scale)
    if not Questie or not Questie.db or not Questie.db.profile then
        return
    end
    Questie.db.profile.arrowScale = scale
end

_GetProfilePosition = function()
    if not Questie or not Questie.db or not Questie.db.profile then
        return nil
    end
    return Questie.db.profile.arrowPosition
end

_GetObjectiveProfilePosition = function()
    if not Questie or not Questie.db or not Questie.db.profile then
        return nil
    end
    return Questie.db.profile.arrowObjectivePosition
end

local function _SaveProfilePosition(point, relativePoint, x, y)
    if not Questie or not Questie.db or not Questie.db.profile then
        return
    end
    Questie.db.profile.arrowPosition = {
        point = point,
        relativePoint = relativePoint,
        x = x,
        y = y,
    }
end

local function _SaveObjectiveProfilePosition(point, relativePoint, x, y)
    if not Questie or not Questie.db or not Questie.db.profile then
        return
    end
    Questie.db.profile.arrowObjectivePosition = {
        point = point,
        relativePoint = relativePoint,
        x = x,
        y = y,
    }
end

local function _SaveObjectiveCurrentScreenPosition()
    if not objectiveFrame then
        return
    end

    local centerX, centerY = objectiveFrame:GetCenter()
    if not centerX or not centerY then
        return
    end

    _SaveObjectiveProfilePosition("CENTER", "BOTTOMLEFT", centerX, centerY)
end

local function _SaveArrowCurrentScreenPosition()
    if not arrowFrame then
        return
    end

    local centerX, centerY = arrowFrame:GetCenter()
    if not centerX or not centerY then
        return
    end

    _SaveProfilePosition("CENTER", "BOTTOMLEFT", centerX, centerY)
end

local function _AttachObjectiveToArrow()
    if not Questie or not Questie.db or not Questie.db.profile then
        return
    end

    Questie.db.profile.arrowObjectiveAttached = true

    EnsureArrowFrame()
    EnsureObjectiveFrame()
    _UpdateArrowFramePosition()
    _UpdateObjectiveFramePosition()
end

local function _DetachObjectiveFromArrow()
    if not Questie or not Questie.db or not Questie.db.profile then
        return
    end

    if arrowFrame then
        _SaveArrowCurrentScreenPosition()
    end
    if objectiveFrame then
        _SaveObjectiveCurrentScreenPosition()
    end
    Questie.db.profile.arrowObjectiveAttached = false

    EnsureObjectiveFrame()
    _UpdateObjectiveFramePosition()
    _UpdateArrowFramePosition()
end

local function modulo(val, by)
    return val - floor(val / by) * by
end

local function GetColorGradient(perc)
    if perc <= 0.5 then
        return 1, perc * 2, 0
    else
        return 2 - perc * 2, 1, 0
    end
end

local function ResolveIconTexture(icon)
    if not icon then
        return nil
    end

    if type(icon) == "string" then
        return icon
    end

    if type(icon) == "number" then
        if Questie and Questie.usedIcons then
            return Questie.usedIcons[icon]
        end
        return nil
    end

    return nil
end

local function _ApplyOutline(fontString)
    if not fontString or not fontString.GetFont or not fontString.SetFont then
        return
    end

    local font, size, flags = fontString:GetFont()
    if not font then
        return
    end

    flags = flags or ""
    if not string.find(flags, "OUTLINE", 1, true) then
        if flags ~= "" then
            flags = flags .. ",OUTLINE"
        else
            flags = "OUTLINE"
        end
    end

    fontString:SetFont(font, size, flags)
end

EnsureObjectiveFrame = function()
    if objectiveFrame then
        _UpdateObjectiveFrameDimensions()
        _UpdateObjectiveFramePosition()
        _UpdateObjectText(sortedTargets[1])
        objectiveFrame:SetAlpha(_GetObjectiveAlpha())
        return
    end

    objectiveFrame = CreateFrame("Frame", "QuestieArrowObjectiveFrame", UIParent)
    objectiveFrame:SetClampedToScreen(true)
    objectiveFrame:SetMovable(true)
    objectiveFrame:EnableMouse(true)
    objectiveFrame:RegisterForDrag("LeftButton")
    objectiveFrame._useDefaultPosition = true
    _UpdateObjectiveFrameDimensions()
    _UpdateObjectiveFramePosition()

    objectiveFrame:SetScript("OnDragStart", function(self)
        if _IsObjectiveLocked() then
            return
        end
        if _IsObjectiveAttached() then
            return
        end
        if IsShiftKeyDown() then
            self._isDragging = true
            self:StartMoving()
        end
    end)

    objectiveFrame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        self._isDragging = false
        local point, _, relativePoint, x, y = self:GetPoint(1)
        if point and relativePoint and x and y and not _IsObjectiveLocked() then
            _SaveObjectiveProfilePosition(point, relativePoint, x, y)
            self._useDefaultPosition = false
        end
    end)

    objectiveFrame:SetScript("OnMouseUp", function(self, button)
        if button == "RightButton" then
            hasManualTarget = false
            sortedTargets = {}
            QuestieArrow:ClearFocusedQuest()
        end
    end)

    objectiveFrame.icon = objectiveFrame:CreateTexture(nil, "OVERLAY")
    objectiveFrame.icon:SetWidth(28)
    objectiveFrame.icon:SetHeight(28)
    objectiveFrame.icon:SetPoint("TOP", objectiveFrame, "TOP", 0, 0)

    objectiveFrame.title = objectiveFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    objectiveFrame.title:SetPoint("TOP", objectiveFrame.icon, "BOTTOM", 0, -2)
    objectiveFrame.title:SetJustifyH("CENTER")
    _ApplyOutline(objectiveFrame.title)

    objectiveFrame.distance = objectiveFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    objectiveFrame.distance:SetPoint("TOP", objectiveFrame.title, "BOTTOM", 0, -2)
    objectiveFrame.distance:SetJustifyH("CENTER")
    objectiveFrame.distance:SetTextColor(1, 1, 1, 1)
    _ApplyOutline(objectiveFrame.distance)

    objectiveFrame._lastTarget = nil
    _UpdateObjectText(sortedTargets[1])
    QuestieArrow:UpdateFont()
    objectiveFrame:Hide()
end

EnsureArrowFrame = function()
    if arrowFrame then
        _UpdateArrowFrameDimensions()
        _ApplyArrowStyle()
        arrowFrame:SetAlpha(_GetArrowAlpha())
        return
    end

    arrowFrame = CreateFrame("Frame", "QuestieArrowFrame", UIParent)

    local pos = _GetProfilePosition()
    if pos and pos.point and pos.relativePoint and pos.x and pos.y then
        arrowFrame:SetPoint(pos.point, UIParent, pos.relativePoint, pos.x, pos.y)
        arrowFrame._useDefaultPosition = false
    else
        arrowFrame:SetPoint("CENTER", 0, -100)
        arrowFrame._useDefaultPosition = true
    end

    _UpdateArrowFrameDimensions()
    arrowFrame:SetClampedToScreen(true)
    arrowFrame:SetMovable(true)
    arrowFrame:EnableMouse(true)
    arrowFrame:EnableMouseWheel(true)
    arrowFrame:RegisterForDrag("LeftButton")
    arrowFrame:SetScript("OnDragStart", function(self)
        if _IsArrowLocked() then
            return
        end
        if IsShiftKeyDown() then
            self._isDragging = true
            self:StartMoving()
        end
    end)
    arrowFrame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        self._isDragging = false

        local point, _, relativePoint, x, y = self:GetPoint(1)
        if point and relativePoint and x and y and not _IsArrowLocked() then
            _SaveProfilePosition(point, relativePoint, x, y)
            self._useDefaultPosition = false
        end
    end)

    arrowFrame:SetScript("OnMouseWheel", function(self, delta)
        if not IsShiftKeyDown() then
            return
        end

        local scale = _GetArrowScale() or 1
        local step = 0.05
        if delta and delta > 0 then
            scale = scale + step
        else
            scale = scale - step
        end

        if scale < 0.5 then scale = 0.5 end
        if scale > 4.0 then scale = 4.0 end

        _SetArrowScale(scale)
        _ApplyArrowVisualScale()
    end)

    arrowFrame.arrow = arrowFrame:CreateTexture(nil, "MEDIUM")
    _ApplyArrowStyle()
    _UpdateArrowFrameDimensions()

    arrowFrame._lastUpdate = 0
    arrowFrame._lastRecalc = 0
    arrowFrame._lastTarget = nil

    arrowFrame:SetScript("OnMouseUp", function(self, button)
        if button == "RightButton" then
            hasManualTarget = false
            sortedTargets = {}
            QuestieArrow:ClearFocusedQuest()
        end
    end)

    arrowFrame:SetScript("OnUpdate", function(self)
        local _prof0 = _arrowPerfLog and debugprofilestop()
        local now = GetTime()

        local target = sortedTargets[1]
        if not target then
            self:Hide()
            if objectiveFrame then
                objectiveFrame:Hide()
            end
            return
        end

        if not self:IsShown() then
            self:Show()
        end
        if objectiveFrame and not objectiveFrame:IsShown() then
            objectiveFrame:Show()
        end

        if (self._lastUpdate or 0) + _GetArrowUpdateThrottle() > now then
            return
        end
        self._lastUpdate = now

        local playerX, playerY, playerInstance = HBD:GetPlayerWorldPosition()
        if not playerX or not playerY or not playerInstance then
            if objectiveFrame then
                objectiveFrame.distance:SetText("Distance: --")
            end
            return
        end

        local targetX, targetY, targetInstance = target.worldX, target.worldY, target.worldInstance
        if not targetX or not targetY or not targetInstance then
            targetX, targetY, targetInstance = HBD:GetWorldCoordinatesFromZone(target.x / 100.0, target.y / 100.0,
                target.uiMapId)
            target.worldX, target.worldY, target.worldInstance = targetX, targetY, targetInstance
        end
        if not targetX or not targetY or not targetInstance then
            if objectiveFrame then
                objectiveFrame.distance:SetText("Distance: --")
            end
            return
        end

        if targetInstance ~= playerInstance then
            self:Hide()
            if objectiveFrame then
                objectiveFrame:Hide()
            end
            return
        end

        local xDelta = (playerX - targetX) * 1.5
        local yDelta = (playerY - targetY)
        local angle = atan2(xDelta, -(yDelta))
        angle = angle > 0 and (pi * 2) - angle or -angle
        if angle < 0 then angle = angle + (pi * 2) end

        local player = GetPlayerFacing and GetPlayerFacing() or 0
        angle = angle - player

        local r, g, b = 1, 1, 1
        if self._arrowStyle and self._arrowStyle.mode == "sheet" then
            local perc = abs(((pi - abs(angle)) / pi))
            r, g, b = GetColorGradient(perc)
        end

        local dist = HBD:GetWorldDistance(targetInstance, playerX, playerY, targetX, targetY)
        if dist then
            local area = 1
            local alpha = 1
            if dist <= area then
                alpha = dist / area
                alpha = alpha > 1 and 1 or alpha
                alpha = alpha < 0.5 and 0.5 or alpha
            end

            local texalpha = (1 - alpha) * 2
            texalpha = texalpha > 1 and 1 or texalpha
            texalpha = texalpha < 0 and 0 or texalpha

            r, g, b = r + texalpha, g + texalpha, b + texalpha

            if self._arrowStyle and self._arrowStyle.mode == "sheet" then
                local cell = modulo(floor(angle / (pi * 2) * ARROW_TOTAL_CELLS + 0.5), ARROW_TOTAL_CELLS)
                local column = modulo(cell, ARROW_SHEET_COLS)
                local row = floor(cell / ARROW_SHEET_COLS)
                local xstart = (column * ARROW_CELL_W) / ARROW_SHEET_SIZE
                local ystart = (row * ARROW_CELL_H) / ARROW_SHEET_SIZE
                local xend = ((column + 1) * ARROW_CELL_W) / ARROW_SHEET_SIZE
                local yend = ((row + 1) * ARROW_CELL_H) / ARROW_SHEET_SIZE
                local padX = 0.5 / ARROW_SHEET_SIZE
                local padY = 0.5 / ARROW_SHEET_SIZE
                xstart = xstart + padX
                ystart = ystart + padY
                xend = xend - padX
                yend = yend - padY
                self.arrow:SetTexCoord(xstart, xend, ystart, yend)
            else
                local style = self._arrowStyle or _GetArrowStyle()
                self.arrow:SetTexCoord(
                    style.textureCoordLeft or 0,
                    style.textureCoordRight or 1,
                    style.textureCoordTop or 0,
                    style.textureCoordBottom or 1
                )
                if self.arrow.SetRotation then
                    self.arrow:SetRotation(angle)
                end
            end

            self.arrow:SetVertexColor(r, g, b)
            self.arrow:SetAlpha(alpha)

            if objectiveFrame then
                local distanceText = "Distance: " .. _FormatDistance(dist)
                if objectiveFrame._lastDistanceText ~= distanceText then
                    objectiveFrame.distance:SetText(distanceText)
                    objectiveFrame._lastDistanceText = distanceText
                end
            end
        end

        if target ~= self._lastTarget then
            self._lastTarget = target
            _UpdateObjectText(target)
        end

        if _prof0 then
            local _elapsed = debugprofilestop() - _prof0
            if _elapsed > 1.0 then
                local log = _arrowPerfLog
                log[#log + 1] = string.format("%.3f OnUpdate %.2fms", now, _elapsed)
                if #log > 500 then table.remove(log, 1) end
            end
        end
    end)

    arrowFrame:Hide()
    EnsureObjectiveFrame()
end

local function EnsureDriverFrame()
    if driverFrame then
        return
    end

    driverFrame = CreateFrame("Frame", "QuestieArrowDriverFrame", UIParent)
    driverFrame:Show()
    driverFrame._lastRecalc = 0

    driverFrame:SetScript("OnUpdate", function(self)
        local now = GetTime()
        if (self._lastRecalc or 0) + _GetArrowRecalcInterval() < now then
            self._lastRecalc = now
            if not _IsArrowEnabled() then
                if arrowFrame then
                    arrowFrame:Hide()
                end
                return
            end
            QuestieArrow:Tick()
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Hoisted helpers for UpdateNearestTargets.
-- These were previously closures recreated on every call; now they are
-- module-level functions that read shared upvalue state set each cycle.
-- ---------------------------------------------------------------------------


local function _GetCompleteIconType(quest)
    local iconType = Questie.ICON_TYPE_COMPLETE
    if QuestieDB and QuestieDB.IsActiveEventQuest and QuestieDB.IsActiveEventQuest(quest.Id) then
        iconType = Questie.ICON_TYPE_EVENTQUEST_COMPLETE
    elseif QuestieDB and QuestieDB.IsPvPQuest and QuestieDB.IsPvPQuest(quest.Id) then
        iconType = Questie.ICON_TYPE_PVPQUEST_COMPLETE
    elseif quest.IsRepeatable then
        iconType = Questie.ICON_TYPE_REPEATABLE_COMPLETE
    end
    return iconType
end

local function _CollectFinisherSpawns(finisher, quest)
    if not finisher then return end
    local pX, pY, pInst = _arrow_playerX, _arrow_playerY, _arrow_playerInstance
    local autoLogic, pZone, pMap = _arrow_usingAutoLogic, _arrow_playerZoneId, _arrow_playerUiMapId
    local iconPath = ResolveIconTexture(_GetCompleteIconType(quest))
    if finisher.spawns then
        for finisherZone, spawns in pairs(finisher.spawns) do
            if finisherZone and spawns then
                for _, coords in ipairs(spawns) do
                    if coords and coords[1] and coords[2] then
                        if coords[1] == -1 or coords[2] == -1 then
                            local dungeonLocation = ZoneDB:GetDungeonLocation(finisherZone)
                            if dungeonLocation then
                                for _, value in ipairs(dungeonLocation) do
                                    local zone = value[1]
                                    local x = value[2]
                                    local y = value[3]
                                    -- Zone filtering disabled (zone ID vs area ID mismatch)
                                    if true then
                                        local uiMapId = _GetUiMapIdForZone(zone)
                                        if uiMapId and x and y then
                                            local tX, tY, tInst = HBD:GetWorldCoordinatesFromZone(x / 100.0, y / 100.0, uiMapId)
                                            if tX and tY and tInst then
                                                local dist = HBD:GetWorldDistance(tInst, pX, pY, tX, tY)
                                                if dist then
                                                    if tInst ~= pInst then
                                                        dist = 500000 + dist * 100
                                                    end
                                                    _AddArrowTarget(x, y, uiMapId, quest.name, quest.level, iconPath, tX, tY, tInst, dist)
                                                end
                                            end
                                        end
                                    end
                                end
                            end
                        else
                            -- Zone filtering disabled (same zone ID vs area ID mismatch issue)
                            if true then
                                local x = coords[1]
                                local y = coords[2]
                                local uiMapId = _GetUiMapIdForZone(finisherZone)
                                if uiMapId then
                                    local tX, tY, tInst = HBD:GetWorldCoordinatesFromZone(x / 100.0, y / 100.0, uiMapId)
                                    if tX and tY and tInst then
                                        local dist = HBD:GetWorldDistance(tInst, pX, pY, tX, tY)
                                        if dist then
                                            if tInst ~= pInst then
                                                dist = 500000 + dist * 100
                                            end
                                            _AddArrowTarget(x, y, uiMapId, quest.name, quest.level, iconPath, tX, tY, tInst, dist)
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    if finisher.waypoints then
        for zone, waypoints in pairs(finisher.waypoints) do
            -- Zone filtering disabled (same zone ID vs area ID mismatch issue)
            if true then
                if waypoints and waypoints[1] and waypoints[1][1] and waypoints[1][1][1] then
                    local x = waypoints[1][1][1]
                    local y = waypoints[1][1][2]
                    local uiMapId = _GetUiMapIdForZone(zone)
                    if uiMapId and x and y then
                        local tX, tY, tInst = HBD:GetWorldCoordinatesFromZone(x / 100.0, y / 100.0, uiMapId)
                        if tX and tY and tInst then
                            local dist = HBD:GetWorldDistance(tInst, pX, pY, tX, tY)
                            if dist then
                                if tInst ~= pInst then
                                    dist = 500000 + dist * 100
                                end
                                _AddArrowTarget(x, y, uiMapId, quest.name, quest.level, iconPath, tX, tY, tInst, dist)
                            end
                        end
                    end
                end
            end
        end
    end
end

-- Exploration objectives are stored in questKeys.triggerEnd as
-- {text, {[zoneId] = {{x, y}, ...}}}. Collected directly so "go to this place"
-- quests still give the arrow a target even when no objective spawnList resolved.
local function _CollectTriggerEnd(quest)
    local triggerEnd = quest and quest.triggerEnd
    local zones = triggerEnd and triggerEnd[2]
    if type(zones) ~= "table" then return end

    local pX, pY, pInst = _arrow_playerX, _arrow_playerY, _arrow_playerInstance
    local iconPath = ResolveIconTexture(Questie.ICON_TYPE_EVENT)
    local debugCollect = Questie and Questie.db and Questie.db.profile and Questie.db.profile.debugArrow

    for zone, coordList in pairs(zones) do
        local uiMapId = _GetUiMapIdForZone(zone)
        if debugCollect then
            print(string.format("    _CollectTriggerEnd: zone=%s uiMapId=%s", tostring(zone), tostring(uiMapId)))
        end
        if uiMapId and type(coordList) == "table" then
            for _, coords in pairs(coordList) do
                if type(coords) == "table" and coords[1] and coords[2] then
                    local tX, tY, tInst = HBD:GetWorldCoordinatesFromZone(coords[1] / 100.0, coords[2] / 100.0, uiMapId)
                    if tX and tY and tInst then
                        local dist = HBD:GetWorldDistance(tInst, pX, pY, tX, tY)
                        if dist then
                            if tInst ~= pInst then
                                dist = 500000 + dist * 100
                            end
                            if debugCollect then
                                print(string.format("      ADDED triggerEnd (%.1f,%.1f) dist=%.0f", coords[1], coords[2], dist))
                            end
                            _AddArrowTarget(coords[1], coords[2], uiMapId, quest.name, quest.level, iconPath, tX, tY, tInst, dist)
                        end
                    end
                end
            end
        end
    end
end

local function _CollectObjective(objective, quest)
    if not objective then return end
    if QuestieQuest.ShouldHideObjective(objective) then return end
    if objective.Completed == true or objective.Completed == 1 then return end
    if objective.Needed and objective.Collected
        and type(objective.Needed) == "number" and type(objective.Collected) == "number"
        and objective.Collected >= objective.Needed then
        return
    end

    -- The spawnList is built lazily by PopulateObjectiveNotes, which the arrow never
    -- calls. Build it here so objectives the map hasn't drawn yet still resolve.
    if (not objective.spawnList) or (not next(objective.spawnList)) then
        if QuestieQuest and QuestieQuest.BuildObjectiveSpawnList then
            local objectiveData
            if quest and quest.ObjectiveData and objective.Index then
                objectiveData = quest.ObjectiveData[objective.Index]
            end
            QuestieQuest:BuildObjectiveSpawnList(objective, objectiveData)
        end
    end
    if not objective.spawnList then return end

    local pX, pY, pInst = _arrow_playerX, _arrow_playerY, _arrow_playerInstance
    local autoLogic, pZone, pMap = _arrow_usingAutoLogic, _arrow_playerZoneId, _arrow_playerUiMapId
    local debugCollect = Questie and Questie.db and Questie.db.profile and Questie.db.profile.debugArrow
    if debugCollect then
        print(string.format("    _CollectObjective: spawnList=%s", objective.spawnList and "yes" or "nil"))
    end
    if not objective.spawnList then return end
    for _, spawnData in pairs(objective.spawnList) do
        if debugCollect then
            print(string.format("      spawnData=%s Spawns=%s", spawnData and "yes" or "nil", spawnData and spawnData.Spawns and "yes" or "nil"))
        end
        if spawnData and spawnData.Spawns then
            for zone, spawns in pairs(spawnData.Spawns) do
                -- Zone filtering is disabled in auto mode because zone IDs and area IDs
                -- are different systems that don't directly compare. The distance
                -- calculation handles instance mismatches.
                local zoneFiltered = false -- Disabled: autoLogic and zone ~= pZone and zone ~= pMap
                if debugCollect then
                    print(string.format("        zone=%s filtered=%s (pZone=%s pMap=%s)", tostring(zone), tostring(zoneFiltered), tostring(pZone), tostring(pMap)))
                end
                if not zoneFiltered then
                    local uiMapId = _GetUiMapIdForZone(zone)
                    for _, spawn in pairs(spawns) do
                        if debugCollect then
                            print(string.format("          spawn=(%.1f,%.1f) uiMapId=%s", spawn[1], spawn[2], tostring(uiMapId)))
                        end
                        if uiMapId then
                            local tX, tY, tInst = HBD:GetWorldCoordinatesFromZone(spawn[1] / 100.0, spawn[2] / 100.0, uiMapId)
                            if tX and tY and tInst then
                                local dist = HBD:GetWorldDistance(tInst, pX, pY, tX, tY)
                                if dist then
                                    if tInst ~= pInst then
                                        dist = 500000 + dist * 100
                                    end
                                    if debugCollect then
                                        print(string.format("            ADDED dist=%.0f", dist))
                                    end
                                    _AddArrowTarget(
                                        spawn[1],
                                        spawn[2],
                                        uiMapId,
                                        quest.name,
                                        quest.level,
                                        ResolveIconTexture(objective.Icon) or ResolveIconTexture(spawnData and spawnData.Icon),
                                        tX,
                                        tY,
                                        tInst,
                                        dist
                                    )
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

-- Gather all objectives from tracked quests and sort by distance
-- Fast path: update only distances and re-sort the existing target list.
-- World coordinates on each target are static, so only the player position changes.
local function _UpdateDistancesAndSort()
    local playerX, playerY, playerInstance = HBD:GetPlayerWorldPosition()
    if not playerX or not playerY or not playerInstance then
        return
    end
    for i = 1, #sortedTargets do
        local t = sortedTargets[i]
        if t.worldX and t.worldY and t.worldInstance then
            local dist = HBD:GetWorldDistance(t.worldInstance, playerX, playerY, t.worldX, t.worldY)
            if dist then
                if t.worldInstance ~= playerInstance then
                    dist = 500000 + dist * 100
                end
                t.distance = dist
            end
        end
    end
    table.sort(sortedTargets, _SortTargetByDistance)
end

function QuestieArrow:UpdateNearestTargets()
    -- Don't override manual targets with auto-updates
    if hasManualTarget then
        return
    end

    -- The focused quest can leave the log (turn-in, abandon) or flip to complete
    -- between rebuilds. Both change which targets are valid, so check before the
    -- fast path would hand back the cached list.
    local focused = _GetFocusedQuestId()
    if focused then
        if not (QuestiePlayer and QuestiePlayer.currentQuestlog and QuestiePlayer.currentQuestlog[focused]) then
            -- Turned in or abandoned: release the lock and fall back to nearest.
            Questie.db.profile.arrowFocusedQuestId = nil
            _lastFocusComplete = nil
            _targetsDirty = true
        else
            local complete = QuestieDB.IsComplete(focused) == 1
            if complete ~= _lastFocusComplete then
                _lastFocusComplete = complete
                _targetsDirty = true
            end
        end
    elseif _lastFocusComplete ~= nil then
        _lastFocusComplete = nil
    end

    -- Fast path: if the target list is still valid, just update distances.
    if not _targetsDirty and #sortedTargets > 0 then
        _UpdateDistancesAndSort()
        return
    end

    sortedTargets = {}
    _targetsDirty = false

    if not Questie.db or not Questie.db.char then
        return
    end

    local playerX, playerY, playerInstance = HBD:GetPlayerWorldPosition()
    if not playerX or not playerY or not playerInstance then
        return
    end

    local tracked = Questie.db.char.TrackedQuests or {}
    local hasTracked = next(tracked) ~= nil

    -- Auto mode logic: If autoTrack is on OR NOTHING is tracked
    local usingAutoLogic = Questie.db.profile.autoTrackQuests or not hasTracked
    local playerZoneId = QuestiePlayer:GetCurrentZoneId()
    local playerUiMapId = QuestiePlayer:GetCurrentUiMapId()
    _arrow_zoneUiMapCache = {}

    -- Publish context for hoisted helper functions (avoids closure allocation every call)
    _arrow_playerX, _arrow_playerY, _arrow_playerInstance = playerX, playerY, playerInstance
    _arrow_usingAutoLogic = usingAutoLogic
    _arrow_playerZoneId, _arrow_playerUiMapId = playerZoneId, playerUiMapId

    -- Already validated against the quest log at the top of this function.
    local focusedQuestId = _GetFocusedQuestId()

    local function _CollectQuestTargets(quest)
        if not quest then return end

        local debugCollect = Questie and Questie.db and Questie.db.profile and Questie.db.profile.debugArrow

        -- The arrow is a passive consumer of quest data. PopulateQuestLogInfo runs
        -- objective:Update() on every objective, which rebuilds spawns/markers and
        -- causes a visible per-second frame hitch. Normal quest events (accept,
        -- QUEST_LOG_UPDATE -> tracker) already populate objectives, so only seed a
        -- quest whose objectives are entirely absent. Never re-populate just because
        -- a Completed flag is nil -- some objective types leave it nil for good, which
        -- otherwise triggers the rebuild on every scan regardless of the throttles.
        if QuestieQuest and QuestieQuest.PopulateQuestLogInfo and quest.Id then
            local hasObjectives = quest.Objectives and next(quest.Objectives) ~= nil
            local hasSpecial = quest.SpecialObjectives and next(quest.SpecialObjectives) ~= nil
            -- Nudge a quest whose objectives haven't been populated yet, but only ONCE
            -- per quest id. Quest objects are created with empty Objectives/SpecialObjectives
            -- tables (Database/QuestieDB.lua), and objective-less turn-in / breadcrumb quests
            -- stay empty for good, so keying off emptiness alone would rebuild them on every
            -- scan and reintroduce the per-second hitch. The normal quest event flow (accept,
            -- QUEST_LOG_UPDATE -> UpdateQuest) keeps objectives and spawnList current after this.
            if not hasObjectives and not hasSpecial and not lastPopulateByQuestId[quest.Id] then
                lastPopulateByQuestId[quest.Id] = GetTime()
                QuestieQuest:PopulateQuestLogInfo(quest)
            end
        end

        local countBefore = #sortedTargets

        -- Quest objects are permanently cached, so quest.isComplete survives an
        -- abandon/reaccept cycle. Read the quest log instead of trusting the flag.
        local isComplete = QuestieDB.IsComplete(quest.Id) == 1
        if isComplete then quest.isComplete = true end

        if debugCollect then
            print(string.format("  _CollectQuestTargets: %s isComplete=%s hasObjectives=%s hasSpecialObjectives=%s hasFinisher=%s",
                tostring(quest.name), tostring(isComplete),
                tostring(quest.Objectives ~= nil),
                tostring(quest.SpecialObjectives ~= nil),
                tostring(quest.Finisher ~= nil)))
        end

        -- _GetCompleteIconType, _CollectFinisherSpawns, _CollectObjective are hoisted
        -- to module level above; no closures are created here.

        -- Main Logic Route for this quest target
        if isComplete then
            if quest.Finisher and quest.Finisher.Id and quest.Finisher.Type then
                local finisher
                if quest.Finisher.Type == "monster" and QuestieDB and QuestieDB.GetNPC then
                    finisher = QuestieDB:GetNPC(quest.Finisher.Id)
                elseif quest.Finisher.Type == "object" and QuestieDB and QuestieDB.GetObject then
                    finisher = QuestieDB:GetObject(quest.Finisher.Id)
                end
                _CollectFinisherSpawns(finisher, quest)
            end
            -- If the quest is complete, do not add normal objectives to the arrow!
            return
        end

        if quest.Objectives then
            if debugCollect then print(string.format("    Collecting %d objectives", #quest.Objectives)) end
            for _, objective in pairs(quest.Objectives) do
                _CollectObjective(objective, quest)
            end
        else
            if debugCollect then print("    No Objectives") end
        end
        if quest.SpecialObjectives then
            if debugCollect then print(string.format("    Collecting %d special objectives", #quest.SpecialObjectives)) end
            for _, objective in pairs(quest.SpecialObjectives) do
                _CollectObjective(objective, quest)
            end
        end

        -- Nothing resolved for this quest. Exploration quests keep their only
        -- destination in triggerEnd, and a quest whose objectives the server hasn't
        -- synced yet has no spawnList to read, so fall back to the raw coordinates.
        if #sortedTargets == countBefore then
            if debugCollect then print("    No targets from objectives, trying triggerEnd") end
            _CollectTriggerEnd(quest)
        end
    end

    if QuestiePlayer and QuestiePlayer.currentQuestlog then
        local debugCollect = Questie and Questie.db and Questie.db.profile and Questie.db.profile.debugArrow
        for questId, quest in pairs(QuestiePlayer.currentQuestlog) do
            if debugCollect then
                print(string.format("Processing questId=%d type=%s", questId, type(quest)))
            end
            if type(quest) == "number" then
                if QuestieDB and QuestieDB.GetQuest then
                    quest = QuestieDB.GetQuest(questId)
                end
            end
            if type(quest) == "table" then
                local shouldTrack = false
                if usingAutoLogic then
                    if not Questie.db.char.AutoUntrackedQuests or not Questie.db.char.AutoUntrackedQuests[questId] then
                        shouldTrack = true
                    end
                else
                    if Questie.db.char.TrackedQuests and Questie.db.char.TrackedQuests[questId] then
                        shouldTrack = true
                    end
                end

                if debugCollect then
                    print(string.format("  questId=%d shouldTrack=%s usingAutoLogic=%s", questId, tostring(shouldTrack), tostring(usingAutoLogic)))
                end

                if shouldTrack then
                    if focusedQuestId and questId ~= focusedQuestId then
                        shouldTrack = false
                    end
                end

                if shouldTrack then
                    if debugCollect then
                        print(string.format("  Calling _CollectQuestTargets for %s", tostring(quest.name)))
                    end
                    _CollectQuestTargets(quest)
                end
            end
        end
    end

    -- Sort by distance
    table.sort(sortedTargets, _SortTargetByDistance)
end

-- Internal: shared rendering after targets are updated.
local function _RenderArrow()
    EnsureArrowFrame()
    EnsureObjectiveFrame()

    local alpha = _GetArrowAlpha()
    if arrowFrame then
        arrowFrame:SetMovable(true)
        arrowFrame:SetAlpha(alpha)
        _ApplyArrowVisualScale()
        _UpdateArrowFramePosition()
    end
    if objectiveFrame then
        objectiveFrame:SetAlpha(_GetObjectiveAlpha())
        _UpdateObjectiveFramePosition()
    end

    if sortedTargets[1] then
        arrowFrame:Show()
        objectiveFrame:Show()
    else
        arrowFrame:Hide()
        objectiveFrame:Hide()
    end
end

-- Full refresh: rebuilds the target list from quest data. Called by external
-- systems (quest accept, tracker hook, options changes) when quest state changes.
function QuestieArrow:Refresh()
    if not _IsArrowEnabled() then
        if arrowFrame then
            arrowFrame:Hide()
        end
        if objectiveFrame then
            objectiveFrame:Hide()
        end
        return
    end

    _targetsDirty = true

    local _t0, _t1
    if _arrowPerfLog then _t0 = debugprofilestop() end

    QuestieArrow:UpdateNearestTargets()

    if _arrowPerfLog then
        _t1 = debugprofilestop()
        local log = _arrowPerfLog
        log[#log + 1] = string.format("%.3f Refresh targets=%d scan=%.2fms",
            GetTime(), #sortedTargets, _t1 - _t0)
        if #log > 500 then table.remove(log, 1) end
    end

    _RenderArrow()
end

-- Lightweight tick: only updates distances and re-sorts the existing target list.
-- Called by the driver frame every recalc interval. Falls back to a full rebuild
-- if the target list is empty (first run, or after ClearTarget).
function QuestieArrow:Tick()
    if not _IsArrowEnabled() then
        if arrowFrame then
            arrowFrame:Hide()
        end
        return
    end

    local _t0, _t1
    if _arrowPerfLog then _t0 = debugprofilestop() end

    QuestieArrow:UpdateNearestTargets()

    if _arrowPerfLog then
        _t1 = debugprofilestop()
        local log = _arrowPerfLog
        log[#log + 1] = string.format("%.3f Tick targets=%d dist=%.2fms",
            GetTime(), #sortedTargets, _t1 - _t0)
        if #log > 500 then table.remove(log, 1) end
    end

    _RenderArrow()
end

-- Manual target setting (called from tracker TomTom bind)
---@param title string
---@param zoneOrUiMapId number
---@param x number
---@param y number
function QuestieArrow:SetTarget(title, zoneOrUiMapId, x, y)
    if not _IsArrowEnabled() then
        return
    end
    -- For manual targets, insert at front of sorted list
    local uiMapId = ZoneDB:GetUiMapIdByAreaId(zoneOrUiMapId) or zoneOrUiMapId

    hasManualTarget = true
    sortedTargets = { {
        x = x,
        y = y,
        uiMapId = uiMapId,
        title = title,
        distance = 0,     -- Manual targets always go first
    } }

    EnsureArrowFrame()
    EnsureObjectiveFrame()
    arrowFrame:SetAlpha(_GetArrowAlpha())
    arrowFrame:Show()
    objectiveFrame:Show()
end

function QuestieArrow:SetFocusedQuest(questId)
    if not Questie or not Questie.db or not Questie.db.profile then
        return
    end
    Questie.db.profile.arrowFocusedQuestId = questId
    hasManualTarget = false
    _targetsDirty = true
    QuestieArrow:Refresh()
end

function QuestieArrow:ClearFocusedQuest()
    if Questie and Questie.db and Questie.db.profile then
        Questie.db.profile.arrowFocusedQuestId = nil
    end
    _targetsDirty = true

    -- Focusing a quest also fades the other quests' map icons, so releasing the
    -- arrow has to lift that too or the map stays dimmed with nothing focused.
    if TrackerUtils and TrackerUtils.UnFocus and Questie and Questie.db and Questie.db.char and Questie.db.char.TrackerFocus then
        TrackerUtils:UnFocus()
        if QuestieQuest and QuestieQuest.ToggleNotes then
            QuestieQuest:ToggleNotes(true)
        end
    end

    QuestieArrow:Refresh()
end

function QuestieArrow:ClearTarget()
    hasManualTarget = false
    sortedTargets = {}
    _targetsDirty = true

    if arrowFrame then
        arrowFrame:Hide()
    end
    if objectiveFrame then
        objectiveFrame:Hide()
    end
end

function QuestieArrow:ResetPosition()
    Questie.db.profile.arrowPosition = nil
    -- Ensure frame exists, then reset to default center position
    EnsureArrowFrame()
    if arrowFrame then
        arrowFrame:ClearAllPoints()
        arrowFrame:SetPoint("CENTER", UIParent, "CENTER", 0, -100)
        arrowFrame._useDefaultPosition = true
    end
end

function QuestieArrow:ResetObjectivePosition()
    Questie.db.profile.arrowObjectivePosition = nil
    EnsureObjectiveFrame()
    if objectiveFrame then
        if _IsObjectiveAttached() then
            _UpdateObjectiveFramePosition()
        else
            objectiveFrame:ClearAllPoints()
            objectiveFrame:SetPoint("CENTER", UIParent, "CENTER", 0, -170)
            objectiveFrame._useDefaultPosition = true
        end
    end
end

function QuestieArrow:AttachObjectiveToArrow()
    _AttachObjectiveToArrow()
end

function QuestieArrow:DetachObjectiveFromArrow()
    _DetachObjectiveFromArrow()
end

function QuestieArrow:ResetAndAttachObjective()
    if not Questie or not Questie.db or not Questie.db.profile then
        return
    end

    Questie.db.profile.arrowPosition = nil
    Questie.db.profile.arrowObjectiveAttached = true

    EnsureArrowFrame()
    EnsureObjectiveFrame()
    _UpdateArrowFramePosition()
    _UpdateObjectiveFramePosition()
end

function QuestieArrow:SetObjectiveGap(gap)
    if not Questie or not Questie.db or not Questie.db.profile then
        return
    end

    Questie.db.profile.arrowObjectiveGap = gap
    if objectiveFrame then
        _UpdateObjectiveFramePosition()
    end
end

function QuestieArrow:ApplyScale()
    EnsureArrowFrame()
    if arrowFrame then
        _ApplyArrowVisualScale()
    end
end

function QuestieArrow:ApplyAlpha()
    EnsureArrowFrame()
    if arrowFrame then
        arrowFrame:SetAlpha(_GetArrowAlpha())
    end
    if objectiveFrame then
        objectiveFrame:SetAlpha(_GetObjectiveAlpha())
    end
end

function QuestieArrow:UpdateSettings()
    EnsureArrowFrame()
    EnsureObjectiveFrame()
    if arrowFrame then
        _UpdateArrowFrameDimensions()
        _ApplyArrowStyle()
        arrowFrame:SetAlpha(_GetArrowAlpha())
    end
    if objectiveFrame then
        _UpdateObjectiveFrameDimensions()
        _UpdateObjectiveFramePosition()
        objectiveFrame:SetAlpha(_GetObjectiveAlpha())
    end
    QuestieArrow:UpdateFont()
end

function QuestieArrow:GetArrowStyleOptions()
    local values = {}

    if QuestieArrowAssets and QuestieArrowAssets.GetStyleOrder and QuestieArrowAssets.GetStyleOptions then
        values = QuestieArrowAssets:GetStyleOptions()
    else
        local fallback = _GetBundledArrowStyle(ARROW_DEFAULT_STYLE)
        if fallback then
            values[ARROW_DEFAULT_STYLE] = fallback.label
        end
    end

    local customPreview = _GetArrowPreviewPath()
    if customPreview then
        values.custom = string.format("|T%s:32:32:0:0|t    %s", customPreview, "Custom")
    else
        values.custom = "Custom"
    end

    return values
end

function QuestieArrow:GetArrowStyleOrder()
    local order = {}

    if QuestieArrowAssets and QuestieArrowAssets.GetStyleOrder then
        for _, key in ipairs(QuestieArrowAssets:GetStyleOrder()) do
            order[#order + 1] = key
        end
    else
        order[#order + 1] = ARROW_DEFAULT_STYLE
    end

    order[#order + 1] = "custom"
    return order
end

function QuestieArrow:GetArrowStylePreviewPath()
    return _GetArrowPreviewPath()
end

function QuestieArrow:GetArrowStyleLabel()
    return _GetArrowStyle().label
end

function QuestieArrow:IsArrowSpriteSheet()
    return _IsArrowSpriteSheet()
end

function QuestieArrow:UpdateFont()
    if not arrowFrame then return end
    local fontSize = Questie.db.profile.arrowFontSize or 10
    local fontName = Questie.db.profile.arrowFont or "Friz Quadrata TT"
    local fontFace = (SharedMedia and SharedMedia.Fetch and SharedMedia:Fetch("font", fontName)) or fontName
    if objectiveFrame and objectiveFrame.title then
        objectiveFrame.title:SetFont(fontFace, fontSize, "OUTLINE")
    end
    if objectiveFrame and objectiveFrame.distance then
        objectiveFrame.distance:SetFont(fontFace, fontSize - 2, "OUTLINE")
    end
end

function QuestieArrow:Initialize()
    EnsureArrowFrame()

    EnsureDriverFrame()

    -- Refresh immediately on tracker updates (quest progress, objective completion, etc.)
    if QuestieTracker and QuestieTracker.Update and hooksecurefunc then
        local lastTrackerRefresh = 0
        hooksecurefunc(QuestieTracker, "Update", function()
            if hasManualTarget or not _IsArrowEnabled() then
                return
            end

            local now = GetTime()
            if (lastTrackerRefresh + _GetArrowTrackerRefreshThrottle()) > now then
                return
            end

            lastTrackerRefresh = now
            _targetsDirty = true
            QuestieArrow:Refresh()
        end)
    end

    QuestieArrow:Refresh()
end

-- Debug function to show current arrow target coordinates
function QuestieArrow:PrintTargetCoords()
    if not sortedTargets or not sortedTargets[1] then
        print("Questie Arrow: No target currently set!")
        return
    end
    local target = sortedTargets[1]
    print("Questie Arrow Target:")
    print("  Quest: " .. tostring(target.title))
    print("  Level: " .. tostring(target.questLevel))
    print("  Zone Coords: " .. string.format("%.1f, %.1f", target.x, target.y))
    print("  UI Map ID: " .. tostring(target.uiMapId))
    print("  Distance: " .. _FormatDistance(target.distance or 0))
end

function QuestieArrow:DebugPrint()
    print("=== Questie Arrow Debug ===")
    print("sortedTargets count: " .. tostring(#sortedTargets))
    print("hasManualTarget: " .. tostring(hasManualTarget))
    print("_arrow_usingAutoLogic: " .. tostring(_arrow_usingAutoLogic))
    print("_arrow_playerX: " .. tostring(_arrow_playerX))
    print("_arrow_playerY: " .. tostring(_arrow_playerY))
    print("_arrow_playerZoneId: " .. tostring(_arrow_playerZoneId))
    print("_arrow_playerUiMapId: " .. tostring(_arrow_playerUiMapId))
    if Questie and Questie.db and Questie.db.profile then
        print("autoTrackQuests: " .. tostring(Questie.db.profile.autoTrackQuests))
    end
    if Questie and Questie.db and Questie.db.char then
        local tracked = Questie.db.char.TrackedQuests or {}
        local autoUntracked = Questie.db.char.AutoUntrackedQuests or {}
        local trackedCount = 0
        for _ in pairs(tracked) do trackedCount = trackedCount + 1 end
        local autoUntrackedCount = 0
        for _ in pairs(autoUntracked) do autoUntrackedCount = autoUntrackedCount + 1 end
        print("TrackedQuests count: " .. tostring(trackedCount))
        print("AutoUntrackedQuests count: " .. tostring(autoUntrackedCount))
    end
    if QuestiePlayer and QuestiePlayer.currentQuestlog then
        local count = 0
        for _ in pairs(QuestiePlayer.currentQuestlog) do count = count + 1 end
        print("currentQuestlog count: " .. tostring(count))
    end
    if sortedTargets and #sortedTargets > 0 then
        print("First 3 targets:")
        for i = 1, math.min(3, #sortedTargets) do
            local t = sortedTargets[i]
            print(string.format("  [%d] %s (%.1f, %.1f) dist=%.0f", i, tostring(t.title), t.x, t.y, t.distance))
        end
    end
    print("========================")
end

-- Also expose sortedTargets for external access
function QuestieArrow:GetTargets()
    return sortedTargets
end

-- Hook into Refresh to show debug info when arrow updates
local _OriginalRefresh = QuestieArrow.Refresh
QuestieArrow.Refresh = function(self, ...)
    _OriginalRefresh(self, ...)
    if Questie and Questie.db and Questie.db.profile and Questie.db.profile.debugArrow then
        if sortedTargets and sortedTargets[1] then
            QuestieArrow:PrintTargetCoords()
        end
    end
end
