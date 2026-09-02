---@class QuestieSlash
local QuestieSlash = QuestieLoader:CreateModule("QuestieSlash")

---@type QuestieOptions
local QuestieOptions = QuestieLoader:ImportModule("QuestieOptions")
---@type QuestieJourney
local QuestieJourney = QuestieLoader:ImportModule("QuestieJourney")
---@type QuestieQuest
local QuestieQuest = QuestieLoader:ImportModule("QuestieQuest")
---@type QuestieTracker
local QuestieTracker = QuestieLoader:ImportModule("QuestieTracker")
---@type QuestieSearch
local QuestieSearch = QuestieLoader:ImportModule("QuestieSearch")
---@type QuestieMap
local QuestieMap = QuestieLoader:ImportModule("QuestieMap")
---@type QuestieLib
local QuestieLib = QuestieLoader:ImportModule("QuestieLib")
---@type QuestieDB
local QuestieDB = QuestieLoader:ImportModule("QuestieDB")
---@type l10n
local l10n = QuestieLoader:ImportModule("l10n")
---@type QuestieCombatQueue
local QuestieCombatQueue = QuestieLoader:ImportModule("QuestieCombatQueue")

local function _fmt(v)
    if v == nil then return "nil" end
    if type(v) == "number" then return string.format("%.4f", v) end
    return tostring(v)
end


-- A scrollable, selectable text window. WoW addons cannot write files, so a report that is
-- meant to leave the game has to be presented somewhere the player can Ctrl+A / Ctrl+C it --
-- chat mangles long lines and drops the ones that scroll past.
local copyBox
local function _ShowCopyWindow(title, text)
    if not copyBox then
        copyBox = CreateFrame("Frame", "QuestieCopyBoxFrame", UIParent)
        copyBox:SetSize(720, 520)
        copyBox:SetPoint("CENTER")
        copyBox:SetFrameStrata("DIALOG")
        copyBox:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 32,
            insets = { left = 11, right = 12, top = 12, bottom = 11 },
        })
        copyBox:SetMovable(true)
        copyBox:EnableMouse(true)
        copyBox:RegisterForDrag("LeftButton")
        copyBox:SetScript("OnDragStart", copyBox.StartMoving)
        copyBox:SetScript("OnDragStop", copyBox.StopMovingOrSizing)

        copyBox.title = copyBox:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        copyBox.title:SetPoint("TOP", copyBox, "TOP", 0, -16)

        copyBox.hint = copyBox:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        copyBox.hint:SetPoint("TOPLEFT", copyBox, "TOPLEFT", 20, -36)
        copyBox.hint:SetText("Text is already selected -- press Ctrl+C to copy (Ctrl+A reselects). Esc closes.")

        local close = CreateFrame("Button", nil, copyBox, "UIPanelCloseButton")
        close:SetPoint("TOPRIGHT", copyBox, "TOPRIGHT", -6, -6)

        local scroll = CreateFrame("ScrollFrame", "QuestieCopyBoxScroll", copyBox,
            "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", copyBox, "TOPLEFT", 20, -54)
        scroll:SetPoint("BOTTOMRIGHT", copyBox, "BOTTOMRIGHT", -38, 20)

        local edit = CreateFrame("EditBox", nil, scroll)
        edit:SetMultiLine(true)
        edit:SetAutoFocus(false)
        edit:SetFontObject(ChatFontNormal)
        -- Both caps default to a few hundred on a fresh EditBox, which silently truncates a
        -- report of any size. 0 means no limit.
        edit:SetMaxLetters(0)
        edit:SetMaxBytes(0)
        -- Height 1: a multiline EditBox grows its own height to fit the text, and the scroll
        -- range follows from that. Same pattern as QuestieDebugOffer.
        edit:SetSize(640, 1)
        edit:SetScript("OnEscapePressed", function() copyBox:Hide() end)
        scroll:SetScrollChild(edit)
        copyBox.edit = edit

        -- Lets Esc close it the way every other panel closes.
        if UISpecialFrames then
            table.insert(UISpecialFrames, "QuestieCopyBoxFrame")
        end
    end

    copyBox.title:SetText(title)
    copyBox.edit:SetText(text)
    copyBox.edit:SetCursorPosition(0)
    copyBox:Show()
    copyBox.edit:SetFocus()
    copyBox.edit:HighlightText()
end

-- Walks the player's actual quest log and reports, per quest, every stage between the client
-- handing the quest over and the tracker drawing a line for it. Written because a quest sitting
-- in the log with no line in the tracker can be dropped at any of six places, and guessing which
-- one from the outside is hopeless.
--
-- Returns plain lines and a count. Plain on purpose: the text is meant to be copied out, and
-- WoW colour escapes travel with it and make the paste unreadable.
---@return table lines, number dropped
local function _BuildQuestPipelineReport(onlyQuestId)
    local QuestLogCache = QuestieLoader:ImportModule("QuestLogCache")
    local TrackerUtils = QuestieLoader:ImportModule("TrackerUtils")
    local QuestiePlayer = QuestieLoader:ImportModule("QuestiePlayer")
    -- Module, not a global: referencing it bare reports nil for every learner field.
    local QuestieLearner = QuestieLoader:ImportModule("QuestieLearner")
    local GetQuestLogTitle = QuestieCompat.GetQuestLogTitle

    local lines = {}
    local function add(fmt, ...)
        if select("#", ...) > 0 then
            lines[#lines + 1] = string.format(fmt, ...)
        else
            lines[#lines + 1] = fmt
        end
    end

    local drawn, details = {}, {}
    local ok, sorted, questDetails = pcall(function()
        return TrackerUtils:GetSortedQuestIds()
    end)
    if ok and sorted then
        for _, qid in pairs(sorted) do drawn[qid] = true end
        details = questDetails or {}
    else
        add("GetSortedQuestIds FAILED: %s", tostring(sorted))
    end

    local profile = Questie.db and Questie.db.profile or {}
    local char = Questie.db and Questie.db.char or {}

    add("Questie quest log pipeline")
    add("Questie %s, client %s, locale %s", QuestieLib:GetAddonVersionString(),
        tostring(GetBuildInfo()), tostring(GetLocale()))
    -- Both returns of GetNumQuestLogEntries. The second is meant to count every quest the log
    -- holds whether or not its header is collapsed, and the retry that repairs a partial login read
    -- depends on that being true -- so it is worth seeing what this client actually reports.
    do
        local entries, quests = GetNumQuestLogEntries()
        add("GetNumQuestLogEntries: entries=%s quests=%s", tostring(entries), tostring(quests))
    end
    add("autoTrackQuests=%s showCompleteQuests=%s trackerEnabled=%s partialLog=%s",
        tostring(profile.autoTrackQuests), tostring(profile.trackerShowCompleteQuests),
        tostring(profile.trackerEnabled),
        tostring(QuestieCompat.IsQuestLogPartial and QuestieCompat.IsQuestLogPartial()))
    add("learner enabled=%s live=%s mode=%s",
        tostring(QuestieLearner and QuestieLearner.IsEnabled and QuestieLearner:IsEnabled()),
        tostring(QuestieLearner and QuestieLearner.IsLearnerLiveEnabled
            and QuestieLearner:IsLearnerLiveEnabled()),
        tostring(QuestieLearner and QuestieLearner.GetDataSourceMode
            and QuestieLearner:GetDataSourceMode()))

    -- Reported here as well as by "/questie learn stats", because Questie:Print used to be routed
    -- through the debug gate and answered that command with silence.
    if QuestieLearner and QuestieLearner.GetStats then
        local okStats, npcs, quests, items, objects = pcall(function()
            return QuestieLearner:GetStats()
        end)
        if okStats then
            add("learned so far: %s quest(s), %s npc(s), %s item(s), %s object(s)",
                tostring(quests), tostring(npcs), tostring(items), tostring(objects))
        else
            add("learned so far: GetStats failed -- %s", tostring(npcs))
        end
    end

    -- The reconciliation passes run from QUEST_LOG_UPDATE, where 3.3.5 discards Lua errors
    -- unseen. Without these counters "the pass never ran", "it ran and threw" and "it ran and
    -- found nothing to do" all look the same from here.
    do
        local QuestEventHandler = QuestieLoader:ImportModule("QuestEventHandler")
        local stats = QuestEventHandler and QuestEventHandler.reconcileStats
        if stats then
            add("reconcile: QLU=%s cleanupRuns=%s registerRuns=%s lastAdded=%s totalAdded=%s",
                tostring(stats.logUpdates), tostring(stats.cleanupRuns),
                tostring(stats.registerRuns), tostring(stats.lastAdded),
                tostring(stats.totalAdded))
            add("           lastCacheCount=%s lastPartial=%s lastVetoedByLogWalk=%s",
                tostring(stats.lastCacheCount), tostring(stats.lastPartial),
                tostring(stats.lastVetoed))
            if stats.cleanupError then add("  CLEANUP PASS THREW: %s", stats.cleanupError) end
            if stats.registerError then add("  REGISTER PASS THREW: %s", stats.registerError) end
        else
            add("reconcile: no stats -- QuestEventHandler never loaded them")
        end
    end

    local collapsedZoneNames = {}
    if char.collapsedZones then
        for zoneName, isCollapsed in pairs(char.collapsedZones) do
            if isCollapsed then collapsedZoneNames[#collapsedZoneNames + 1] = tostring(zoneName) end
        end
    end
    table.sort(collapsedZoneNames)
    add("collapsed tracker zone groups: %s",
        #collapsedZoneNames > 0 and table.concat(collapsedZoneNames, " | ") or "(none)")
    add("")

    local header, shown, dropped = nil, 0, 0
    -- Expanded for the walk. Without this the report is blind to exactly the quests worth asking
    -- about: a collapsed header takes its quests out of this index space, so asking after one by id
    -- answered "not in your quest log" when it plainly was. The partialLog line above still reports
    -- the real collapse state, because it was read before this ran.
    QuestieCompat.WithFullQuestLog(function()
    for i = 1, (GetNumQuestLogEntries() or 0) do
        local title, level, questTag, isHeader, _, isComplete, _, questId = GetQuestLogTitle(i)
        if isHeader then
            header = title
        elseif questId and questId > 0 then
            local detail = details[questId]
            local zone = detail and detail.zoneName
            local zoneCollapsed = zone and char.collapsedZones and char.collapsedZones[zone]
            -- A quest can be in the draw list, pass every filter, and still never appear: if it
            -- throws while its line is being built the tracker skips it and moves on, and the error
            -- goes to Questie:Error, which the debug gate swallows. Counted as not visible, or the
            -- report would file it as fine and never print the reason.
            local drawError = QuestieTracker and QuestieTracker.lastDrawErrors
                and QuestieTracker.lastDrawErrors[questId]
            local visible = drawn[questId] and not zoneCollapsed and not drawError
            if not visible then dropped = dropped + 1 end

            -- With no id, only the quests that fail to produce a line are worth printing --
            -- a full log is twenty quests of five lines each and buries the answer.
            if onlyQuestId == questId or ((not onlyQuestId) and not visible) then
                shown = shown + 1

                local slot = QuestiePlayer.currentQuestlog and QuestiePlayer.currentQuestlog[questId]
                local slotKind = "MISSING"
                if type(slot) == "table" then
                    slotKind = slot._isLogFallback and "table(logFallback)" or "table"
                elseif slot ~= nil then
                    slotKind = "id-only(" .. type(slot) .. ")"
                end

                local dbQuest = QuestieDB.GetQuest and QuestieDB.GetQuest(questId)
                local dbKind = "nil"
                if dbQuest then dbKind = dbQuest._isLogFallback and "logFallback" or "real" end

                local learned = Questie.dbLearner and Questie.dbLearner.global
                    and Questie.dbLearner.global.quests and Questie.dbLearner.global.quests[questId]

                add("[%d] %s", questId, tostring(title))
                add("    header=%s", tostring(header))
                add("    log: level=%s tag=%s isComplete=%s",
                    tostring(level), tostring(questTag), tostring(isComplete))
                add("    QuestLogCache=%s currentQuestlog=%s GetQuest=%s fallbackObj=%s",
                    tostring((QuestLogCache.questLog_DO_NOT_MODIFY or {})[questId] ~= nil),
                    slotKind, dbKind,
                    tostring(TrackerUtils._fallbackQuests
                        and TrackerUtils._fallbackQuests[questId] ~= nil))
                -- GetAllQuestIds sets this the one time it walks a quest whose GetQuest is
                -- nil. True while currentQuestlog is MISSING means the rebuild reached the
                -- quest and something removed it after; false means it never got there.
                add("    sessionWarning=%s", tostring(Questie._sessionWarnings
                    and Questie._sessionWarnings[questId] ~= nil))
                add("    learner=%s override=%s markedComplete=%s autoUntracked=%s tracked=%s hidden=%s",
                    tostring(learned ~= nil),
                    tostring(QuestieDB.questDataOverrides
                        and QuestieDB.questDataOverrides[questId] ~= nil),
                    tostring(char.complete and char.complete[questId] ~= nil),
                    tostring(char.AutoUntrackedQuests and char.AutoUntrackedQuests[questId] ~= nil),
                    tostring(char.TrackedQuests and char.TrackedQuests[questId] ~= nil),
                    tostring(char.hidden and char.hidden[questId] ~= nil))

                if drawError then
                    add("    THREW WHILE DRAWING: %s", tostring(drawError))
                end

                if not drawn[questId] then
                    add("    VERDICT: dropped before the tracker draw list")
                else
                    add("    draw list: yes, zone=%s", tostring(zone))
                    add("    zoneCollapsed=%s questCollapsed=%s",
                        tostring(zoneCollapsed and true or false),
                        tostring(char.collapsedQuests
                            and char.collapsedQuests[questId] and true or false))

                    local q = detail and detail.quest
                    local complete = q and q.IsComplete and q:IsComplete()
                    local passesGate
                    if profile.autoTrackQuests then
                        passesGate = (complete ~= 1 or profile.trackerShowCompleteQuests)
                            and not (char.AutoUntrackedQuests and char.AutoUntrackedQuests[questId])
                    else
                        passesGate = (char.TrackedQuests and char.TrackedQuests[questId]) and true or false
                    end

                    if drawError then
                        add("    VERDICT: reached the draw and threw, so no line was made for it")
                    elseif zoneCollapsed then
                        add("    VERDICT: hidden, its zone group is collapsed in the tracker")
                    elseif not passesGate then
                        add("    VERDICT: hidden by the track/complete gate (complete=%s)",
                            tostring(complete))
                    else
                        add("    VERDICT: should be visible")
                    end
                end
                add("")
            end
        end
    end
    end, true)

    if shown == 0 then
        if onlyQuestId then
            add("quest %s is not in your quest log", tostring(onlyQuestId))
        else
            add("every quest in your log reaches the tracker -- nothing is being dropped")
        end
    end

    return lines, dropped
end

local function _ReportQuestPipeline(onlyQuestId)
    local lines, dropped = _BuildQuestPipelineReport(onlyQuestId)
    _ShowCopyWindow("Questie: quest log pipeline", table.concat(lines, "\n"))
    Questie:Print(string.format("Pipeline report opened -- %d quest(s) not reaching the tracker.",
        dropped))
end

-- Re-runs the login rebuild of currentQuestlog and reports before/after. Splits the two reasons
-- a quest can be missing from currentQuestlog: the rebuild never ran while the quest was in the
-- cache (a repeat fixes it) versus the rebuild aborting partway (a repeat changes nothing, and
-- whatever it threw is caught and shown here instead of vanishing into a muted error frame).
local function _RebuildQuestLog()
    local QuestiePlayer = QuestieLoader:ImportModule("QuestiePlayer")
    local QuestLogCache = QuestieLoader:ImportModule("QuestLogCache")

    local function count(t)
        local n = 0
        for _ in pairs(t or {}) do n = n + 1 end
        return n
    end

    local cached = count(QuestLogCache.questLog_DO_NOT_MODIFY)
    local before = count(QuestiePlayer.currentQuestlog)

    -- Which ids the reconciliation pass should already have picked up. If any are listed here, that
    -- pass either never ran or bailed on them, and the manual call below says which.
    local gap = {}
    for questId in pairs(QuestLogCache.questLog_DO_NOT_MODIFY or {}) do
        if not QuestiePlayer.currentQuestlog[questId] then
            gap[#gap + 1] = tostring(questId)
        end
    end
    table.sort(gap)

    -- Call the reconciliation directly. It runs on every QUEST_LOG_UPDATE, so by the time anyone
    -- types this it should have nothing left to do -- anything it adds here is a pass that is not
    -- being reached in the normal event flow, which is a different fault from the rebuild's.
    local QuestEventHandler = QuestieLoader:ImportModule("QuestEventHandler")
    local reconciled, reconcileErr = "not available"
    if QuestEventHandler and QuestEventHandler.private
        and QuestEventHandler.private.RegisterMissingQuestsFallback then
        local rok, res = pcall(function()
            return QuestEventHandler.private:RegisterMissingQuestsFallback()
        end)
        if rok then reconciled = tostring(res) else reconciled, reconcileErr = "ERRORED", res end
    end
    local afterReconcile = count(QuestiePlayer.currentQuestlog)

    local ok, err = pcall(function() QuestieQuest:GetAllQuestIds() end)
    local after = count(QuestiePlayer.currentQuestlog)

    local out = {
        "Forced rebuild of currentQuestlog",
        string.format("QuestLogCache holds %d quest(s)", cached),
        string.format("currentQuestlog before=%d", before),
        string.format("in the cache but not in currentQuestlog: %s",
            #gap > 0 and table.concat(gap, ", ") or "(none)"),
        string.format("RegisterMissingQuestsFallback added %s -> currentQuestlog=%d%s",
            reconciled, afterReconcile,
            reconcileErr and ("  (" .. tostring(reconcileErr) .. ")") or ""),
        string.format("after GetAllQuestIds=%d", after),
        ok and "GetAllQuestIds completed without error"
            or ("GetAllQuestIds ERRORED: " .. tostring(err)),
        "",
    }
    local report = _BuildQuestPipelineReport(nil)
    for k = 1, #report do out[#out + 1] = report[k] end

    _ShowCopyWindow("Questie: forced rebuild", table.concat(out, "\n"))
    Questie:Print(string.format("Rebuild: currentQuestlog %d -> %d (cache holds %d). %s",
        before, after, cached, ok and "No error." or "ERRORED, see window."))
end


local function _dumpFrame(name, frame)
    if not frame then
        print(string.format("%s: nil", name))
        return
    end

    local p1, r1, p2, x, y = frame:GetPoint()
    print(string.format(
        "%s: %s size=%.1fx%.1f scale=%.4f eff=%.4f visible=%s strata=%s level=%s point=(%s,%s,%s,%.1f,%.1f)",
        name,
        frame:GetName() or tostring(frame),
        frame:GetWidth() or 0,
        frame:GetHeight() or 0,
        frame.GetScale and frame:GetScale() or 0,
        frame.GetEffectiveScale and frame:GetEffectiveScale() or 0,
        tostring(frame:IsShown()),
        tostring(frame.GetFrameStrata and frame:GetFrameStrata() or "?"),
        tostring(frame.GetFrameLevel and frame:GetFrameLevel() or "?"),
        tostring(p1), tostring(r1 and r1.GetName and r1:GetName() or r1), tostring(p2), x or 0, y or 0
    ))
end

local function _dumpMaskState(frame)
    if not frame then
        return
    end

    local mask = nil
    if frame.GetMaskTexture then
        pcall(function()
            mask = frame:GetMaskTexture()
        end)
    end

    local tex = nil
    if frame.GetTexture then
        pcall(function()
            tex = frame:GetTexture()
        end)
    end

    local shape = GetMinimapShape and GetMinimapShape() or "UNKNOWN"
    local isSquare = tostring(shape) == "SQUARE"
    print(string.format(
        "Minimap mask/texture: mask=%s texture=%s shape=%s square=%s",
        tostring(mask),
        tostring(tex),
        tostring(shape),
        tostring(isSquare)
    ))
end

local function QuestieTerrainDebug()
    print("=== MINIMAP TERRAIN DEBUG ===")
    _dumpFrame("Minimap", Minimap)
    _dumpFrame("MinimapCluster", MinimapCluster)
    _dumpFrame("MinimapZoomIn", MinimapZoomIn)
    _dumpFrame("MinimapZoomOut", MinimapZoomOut)
    _dumpFrame("MinimapBorderTop", MinimapBorderTop)
    _dumpFrame("MinimapBackdrop", MinimapBackdrop)
    _dumpFrame("MinimapNorthTag", MinimapNorthTag)
    _dumpFrame("MinimapCompassTexture", MinimapCompassTexture)
    _dumpMaskState(Minimap)

    local mmHolder = _G.MMHolder
    _dumpFrame("MMHolder", mmHolder)

    local parent = Minimap and Minimap:GetParent()
    local depth = 0
    while parent and depth < 5 do
        _dumpFrame(string.format("Parent[%d]", depth + 1), parent)
        parent = parent:GetParent()
        depth = depth + 1
    end

    local elvUIEnabled = _G.ElvUI ~= nil or _G.ElvDB ~= nil
    print("")
    print("Interpretation:")
    print(string.format("- ElvUI detected: %s", tostring(elvUIEnabled)))
    print("- If Minimap uses MMHolder plus a square mask/shape, ElvUI's minimap module is active.")
    print("- If anchors are stock but the terrain still misaligns, the likely bug is ElvUI's mask/texture path, not Questie pin math.")
end

local function QuestieRadiusDebug()
    local m = Minimap
    if not m then
        print("=== MINIMAP RADIUS DEBUG ===")
        print("Minimap frame not available")
        return
    end

    local function fmt(v)
        if v == nil then return "nil" end
        if type(v) == "number" then return string.format("%.4f", v) end
        return tostring(v)
    end

    local zoom = m:GetZoom() or -1
    local width = m:GetWidth() or 0
    local height = m:GetHeight() or 0
    local scale = m:GetScale() or 0
    local effScale = m.GetEffectiveScale and m:GetEffectiveScale() or 0
    local shape = GetMinimapShape and GetMinimapShape() or "UNKNOWN"

    print("=== MINIMAP RADIUS DEBUG ===")
    print(string.format("Zoom level: %d", zoom))
    print(string.format("Shape: %s", tostring(shape)))
    print(string.format("Minimap size: %.1f x %.1f", width, height))
    print(string.format("Minimap scale: %.4f (effective %.4f)", scale, effScale))
    print(string.format("Visible: %s", tostring(m:IsVisible())))

    local function getFallbackRadius(isOutdoor)
        local outdoor = {[0]=466 + 2/3, [1]=400, [2]=333 + 1/3, [3]=266 + 2/3, [4]=200, [5]=133 + 1/3}
        local indoor  = {[0]=300, [1]=240, [2]=180, [3]=120, [4]=80,  [5]=50}
        local tableRef = isOutdoor and outdoor or indoor
        return (tableRef[zoom] or 0) / 2
    end

    if m.GetViewRadius then
        print(string.format("Minimap:GetViewRadius() = %s", fmt(m:GetViewRadius())))
    else
        print("Minimap:GetViewRadius() = NOT AVAILABLE")
    end

    if C_Minimap and C_Minimap.GetViewRadius then
        print(string.format("C_Minimap.GetViewRadius() = %s", fmt(C_Minimap.GetViewRadius())))
    else
        print("C_Minimap.GetViewRadius() = NOT AVAILABLE")
    end

    local zoomCVar = tonumber(GetCVar("minimapZoom") or "0") or 0
    local insideZoomCVar = tonumber(GetCVar("minimapInsideZoom") or "0") or 0
    local indoors = zoomCVar == zoom and "outdoor" or "indoor"
    print(string.format("CVar minimapZoom=%d minimapInsideZoom=%d => addon fallback treats current state as %s", zoomCVar, insideZoomCVar, indoors))
    print(string.format("Fallback outdoor radius[%d] = %.2f", zoom, getFallbackRadius(true)))
    print(string.format("Fallback indoor  radius[%d] = %.2f", zoom, getFallbackRadius(false)))

    local HBDPins = QuestieCompat and QuestieCompat.HBDPins
    if HBDPins then
        local activeCount = 0
        for _ in pairs(HBDPins.activeMinimapPins or {}) do
            activeCount = activeCount + 1
        end
        print(string.format("Questie HBDPins activeMinimapPins: %d", activeCount))

        local printed = 0
        print("--- SAMPLE PIN METRICS ---")
        for pin, data in pairs(HBDPins.activeMinimapPins or {}) do
            printed = printed + 1
            if printed > 8 then break end

            local _, _, _, xOff, yOff = pin:GetPoint()
            local px = xOff or 0
            local py = yOff or 0
            local screenDist = math.sqrt(px * px + py * py)
            local radiusPx = math.min(width, height) * 0.5
            local radiusNorm = radiusPx > 0 and (screenDist / radiusPx) or 0
            local edgePx = radiusPx * 0.9
            local edgeErr = screenDist - edgePx
            local onEdge = data.onEdge and true or false
            local shown = pin.IsShown and pin:IsShown() or false
            local iconData = pin.data or {}
            local label = iconData.Name or iconData.name or iconData.Title or "unknown"
            local questId = iconData.Id or iconData.id or iconData.questId or "?"

            print(string.format(
                "[%d] %s q=%s shown=%s edge=%s world=%.2f,%.2f dist=%.3f screen=%.1f,%.1f |px|=%.1f norm=%.3f edgePx=%.1f edgeErr=%.1f",
                printed, label, questId, tostring(shown), tostring(onEdge),
                data.x or 0, data.y or 0, data.distanceFromMinimapCenter or 0,
                px, py, screenDist, radiusNorm, edgePx, edgeErr
            ))
        end
    else
        print("QuestieCompat.HBDPins = NOT AVAILABLE")
    end

    local parent = m:GetParent()
    print(string.format("Minimap parent: %s (size %.0fx%.0f scale %.2f)",
        parent and parent:GetName() or "nil",
        parent and parent:GetWidth() or 0,
        parent and parent:GetHeight() or 0,
        parent and parent:GetScale() or 0))

    print("")
    print("Interpretation:")
    print("- If Minimap:GetViewRadius() and C_Minimap.GetViewRadius() match the fallback, radius is not the drift source.")
    print("- If the sample pin screen error stays near 0.0, Questie's projection math is internally consistent.")
    print("- If radius is correct but the terrain still looks offset, the remaining issue is texture/layout alignment, not pin math.")
end

_G.QuestieRadiusDebug = QuestieRadiusDebug
_G.QuestieTerrainDebug = QuestieTerrainDebug

function QuestieSlash.RegisterSlashCommands()
    Questie:RegisterChatCommand("questieclassic", QuestieSlash.HandleCommands)
    Questie:RegisterChatCommand("questie", QuestieSlash.HandleCommands)
    Questie:RegisterChatCommand("radiusdebug", function()
        if _G.QuestieRadiusDebug then
            _G.QuestieRadiusDebug()
        else
            print("[Questie] radius debug unavailable")
        end
    end)
    Questie:RegisterChatCommand("terraindebug", function()
        if _G.QuestieTerrainDebug then
            _G.QuestieTerrainDebug()
        else
            print("[Questie] terrain debug unavailable")
        end
    end)
end

function QuestieSlash.HandleCommands(input)
    input = string.trim(input, " ");

    local commands = {}
    for c in string.gmatch(input, "([^%s]+)") do
        table.insert(commands, c)
    end

    local mainCommand = commands[1]
    local subCommand = commands[2]

    -- /questie
    if mainCommand == "" or not mainCommand then
        QuestieCombatQueue:Queue(function()
            QuestieOptions:OpenConfigWindow();
        end)

        if QuestieJourney:IsShown() then
            QuestieJourney.ToggleJourneyWindow();
        end
        return ;
    end

    -- /questie help || /questie ?
    if mainCommand == "help" or mainCommand == "?" then
        print(Questie:Colorize(l10n("Questie Commands"), "yellow"));
        print(Questie:Colorize("/questie - " .. l10n("Toggles the Config window"), "yellow"));
        print(Questie:Colorize("/questie toggle - " .. l10n("Toggles showing questie on the map and minimap"), "yellow"));
        print(Questie:Colorize("/questie tomap [<npcId>/<npcName>/reset] - " .. l10n("Adds manual notes to the map for a given NPC ID or name. If the name is ambiguous multipe notes might be added. Without a second command the target will be added to the map. The 'reset' command removes all notes"), "yellow"));
        print(Questie:Colorize("/questie minimap - " .. l10n("Toggles the Minimap Button for Questie"), "yellow"));
        print(Questie:Colorize("/questie journey - " .. l10n("Toggles the My Journey window"), "yellow"));
        print(Questie:Colorize("/questie tracker [show/hide/reset] - " .. l10n("Toggles the Tracker. Add 'show', 'hide', 'reset' to explicit show/hide or reset the Tracker"), "yellow"));
        print(Questie:Colorize("/questie flex - " .. l10n("Flex the amount of quests you have completed so far"), "yellow"));
        print(Questie:Colorize("/questie doable [questID] - " .. l10n("Prints whether you are eligibile to do a quest"), "yellow"));
        print(Questie:Colorize("/questie version - " .. l10n("Prints Questie and client version info"), "yellow"));
        print(Questie:Colorize("/questie learn [toggle/stats/clear/export] - " .. l10n("Self-learning database: toggle on/off, view stats, clear data, or export"), "yellow"));
        print(Questie:Colorize("/questie arrow perf [start/stop/show/clear] - " .. "Arrow performance profiler: record, view, or clear timing data", "yellow"));
        print(Questie:Colorize("/questie arrow why - " .. "Explain the arrow's current target and the quest state behind it", "yellow"));
        print(Questie:Colorize("/questie why [questID] - " .. "Trace every quest in your log through to the tracker and show where it is dropped", "yellow"));
        print(Questie:Colorize("/questie why rebuild - " .. "Force the login rebuild of the quest log and report what it changed", "yellow"));
        return;
    end

    -- /questie toggle
    if mainCommand == "toggle" then
        Questie.db.profile.enabled = (not Questie.db.profile.enabled)
        QuestieQuest:ToggleNotes(Questie.db.profile.enabled);

        -- Close config window if it's open to avoid desyncing the Checkbox
        QuestieOptions:HideFrame();
        return;
    end

    if mainCommand == "reload" then
        QuestieQuest:SmoothReset()
        return
    end

    -- /questie minimap
    if mainCommand == "minimap" then
        Questie.db.profile.minimap.hide = not Questie.db.profile.minimap.hide;

        if Questie.db.profile.minimap.hide then
            Questie.minimapConfigIcon:Hide("Questie");
        else
            Questie.minimapConfigIcon:Show("Questie");
        end
        return;
    end

    -- /questie journey (or /questie journal, because of a typo)
    if mainCommand == "journey" or mainCommand == "journal" then
        QuestieJourney.ToggleJourneyWindow();
        QuestieOptions:HideFrame();
        return;
    end

    if mainCommand == "tracker" then
        if subCommand == "show" then
            QuestieTracker:Enable()
        elseif subCommand == "hide" then
            QuestieTracker:Disable()
        elseif subCommand == "reset" then
            QuestieTracker:ResetLocation()
        else
            QuestieTracker:Toggle()
        end
        return
    end

    if mainCommand == "tomap" then
        if not subCommand then
            subCommand = UnitName("target")
        end

        if subCommand ~= nil then
            if subCommand == "reset" then
                QuestieMap:ResetManualFrames()
                return
            end

            local conversionTry = tonumber(subCommand)
            if conversionTry then -- We've got an ID
                subCommand = conversionTry
                local result = QuestieSearch:Search(subCommand, "npc", "int")
                if result then
                    for npcId, _ in pairs(result) do
                        QuestieMap:ShowNPC(npcId)
                    end
                end
                return
            elseif type(subCommand) == "string" then
                local result = QuestieSearch:Search(subCommand, "npc")
                if result then
                    for npcId, _ in pairs(result) do
                        QuestieMap:ShowNPC(npcId)
                    end
                end
                return
            end
        end
    end

    if mainCommand == "flex" then
        local questCount = 0
        for _, _ in pairs(Questie.db.char.complete) do
            questCount = questCount + 1
        end
        if GetDailyQuestsCompleted then
            questCount = questCount - GetDailyQuestsCompleted() -- We don't care about daily quests
        end
        SendChatMessage(l10n("has completed a total of %d quests", questCount) .. "!", "EMOTE")
        return
    end

    if mainCommand == "version" then
        local gameType = ""
        if Questie.IsWotlk then
            gameType = "Wrath"
        elseif Questie.IsSoD then -- seasonal checks must be made before non-seasonal for that client, since IsEra resolves true in SoD
            gameType = "SoD"
        elseif Questie.IsEra then
            gameType = "Era"
        end

        Questie:Print("Questie " .. QuestieLib:GetAddonVersionString() .. ", Client " .. GetBuildInfo() .. " " .. gameType .. ", Locale " .. GetLocale())
        return
    end

    if mainCommand == "doable" or mainCommand == "eligible" or mainCommand == "eligibility" then
        if not subCommand then
            print(Questie:Colorize("[Questie] ", "yellow") .. "Usage: /questie " .. mainCommand .. " <questID>")
            do return end
        elseif QuestieDB.QueryQuestSingle(tonumber(subCommand), "name") == nil then
            print(Questie:Colorize("[Questie] ", "yellow") .. "Invalid quest ID")
            return
        end

        Questie:Print("[Eligibility] " .. tostring(QuestieDB.IsDoableVerbose(tonumber(subCommand), false, true, false)))

        return
    end

    -- /questie learn [toggle/stats/clear/export]
    if mainCommand == "learn" then
        local QuestieLearner = QuestieLoader:ImportModule("QuestieLearner")
        if not QuestieLearner then
            Questie:Print("QuestieLearner module not loaded")
            return
        end

        if subCommand == "toggle" or not subCommand then
            local settings = QuestieLearner:GetSettings()
            settings.enabled = not settings.enabled
            Questie:Print("Learning " .. (settings.enabled and "|cff00ff00enabled|r" or "|cffff0000disabled|r"))
        elseif subCommand == "stats" then
            local npcCount, questCount, itemCount, objectCount = QuestieLearner:GetStats()
            Questie:Print("Learned data: " .. npcCount .. " NPCs, " .. questCount .. " quests, " .. itemCount .. " items, " .. objectCount .. " objects")
        elseif subCommand == "clear" then
            QuestieLearner:ClearAllData()
        elseif subCommand == "export" then
            local exportText = QuestieLearner:ExportData()
            if exportText and #exportText > 0 then
                Questie:Print("Export data printed to chat. Copy from Lua errors or use /dump")
                print(exportText)
            else
                Questie:Print("No learned data to export")
            end
        else
            Questie:Print("Usage: /questie learn [toggle/stats/clear/export]")
        end
        return
    end

    -- /questie arrow perf [start|stop|show|clear] | /questie arrow why
    if mainCommand == "why" then
        if subCommand == "rebuild" then
            _RebuildQuestLog()
        else
            _ReportQuestPipeline(tonumber(subCommand))
        end
        return
    end

    if mainCommand == "arrow" then
        local QuestieArrow = QuestieLoader:ImportModule("QuestieArrow")
        if subCommand == "perf" then
            local action = commands[3] and string.lower(commands[3]) or ""
            if QuestieArrow and QuestieArrow.HandlePerfCommand then
                QuestieArrow:HandlePerfCommand(action)
            else
                Questie:Print("Arrow perf profiler not available.")
            end
        elseif subCommand == "why" then
            if QuestieArrow and QuestieArrow.PrintWhy then
                QuestieArrow:PrintWhy()
            else
                Questie:Print("Arrow diagnostics not available.")
            end
        else
            Questie:Print("Usage: /questie arrow [perf [start|stop|show|clear] | why]")
        end
        return
    end

    print(Questie:Colorize("[Questie] ", "yellow") .. l10n("Invalid command. For a list of options please type: ") .. Questie:Colorize("/questie help", "yellow"));
end
