---@class QuestEventHandler
local QuestEventHandler = QuestieLoader:CreateModule("QuestEventHandler")
---@class QuestEventHandlerPrivate
local _QuestEventHandler = QuestEventHandler.private

local _QuestLogUpdateQueue = {} -- Helper module
local questLogUpdateQueue = {}  -- The actual queue

---@type QuestEventHandlerPrivate
QuestEventHandler.private = QuestEventHandler.private or {}
---@type QuestLogCache
local QuestLogCache = QuestieLoader:ImportModule("QuestLogCache")
---@type QuestieQuest
local QuestieQuest = QuestieLoader:ImportModule("QuestieQuest")
---@type QuestieJourney
local QuestieJourney = QuestieLoader:ImportModule("QuestieJourney")
---@type QuestieNameplate
local QuestieNameplate = QuestieLoader:ImportModule("QuestieNameplate")
---@type QuestieLib
local QuestieLib = QuestieLoader:ImportModule("QuestieLib")
---@type QuestieDB
local QuestieDB = QuestieLoader:ImportModule("QuestieDB")
---@type QuestieAnnounce
local QuestieAnnounce = QuestieLoader:ImportModule("QuestieAnnounce")
---@type IsleOfQuelDanas
local IsleOfQuelDanas = QuestieLoader:ImportModule("IsleOfQuelDanas")
---@type QuestieCombatQueue
local QuestieCombatQueue = QuestieLoader:ImportModule("QuestieCombatQueue")
---@type QuestieTracker
local QuestieTracker = QuestieLoader:ImportModule("QuestieTracker")
---@type l10n
local l10n = QuestieLoader:ImportModule("l10n")
---@type QuestiePlayer
local QuestiePlayer = QuestieLoader:ImportModule("QuestiePlayer")

--- COMPATIBILITY ---
local C_Timer = QuestieCompat.C_Timer
local GetQuestLogTitle = QuestieCompat.GetQuestLogTitle
local GetItemInfo = QuestieCompat.GetItemInfo

local tableRemove = table.remove

local QUEST_LOG_STATES = {
    QUEST_ACCEPTED = "QUEST_ACCEPTED",
    QUEST_TURNED_IN = "QUEST_TURNED_IN",
    QUEST_REMOVED = "QUEST_REMOVED",
    QUEST_ABANDONED = "QUEST_ABANDONED"
}

local eventFrame = CreateFrame("Frame", "QuestieQuestEventFrame")
local questLog = {}
local questLogUpdateQueueSize = 1
local skipNextUQLCEvent = false
local doFullQuestLogScan = false
local deletedQuestItem = false
-- Debounce state for BAG_UPDATE_DELAYED: prevents hammering UpdateAllQuests on every bag slot change.
-- Also schedules a follow-up scan to catch server-side quest-log counter lag (loot bot batch loots).
local _bagUpdateDebounceTimer = nil
local _bagUpdateFollowUpTimer = nil
-- Debounce QUEST_WATCH_UPDATE scans too. Ascension can send objective progress
-- without a follow-up QUEST_LOG_UPDATE, so waiting for the next QLU can leave
-- completed objective pins visible until the periodic refresh catches them.
local _questWatchUpdateDebounceTimer = nil
local _questWatchUpdateFollowUpTimer = nil
local _unitQuestLogChangedDebounceTimer = nil
local _unitQuestLogChangedFollowUpTimer = nil

-- Periodic quest state verification timer.
-- Ascension server events (QUEST_LOG_UPDATE, UNIT_QUEST_LOG_CHANGED) can be
-- unreliable or delayed, causing stale quest.isComplete / quest.WasComplete flags
-- to persist across reload/reaccept cycles. This timer forces a full quest log
-- reconciliation every 30 seconds so pins and arrows stay accurate.
local _periodicRefreshTimer = nil
local PERIODIC_REFRESH_SECONDS = 30

--- Registers all events that are required for questing (accepting, removing, objective updates, ...)
function QuestEventHandler:RegisterEvents()
    Questie:Debug(Questie.DEBUG_DEVELOP, "[Quest Event] RegisterEvents")
    eventFrame:RegisterEvent("QUEST_ACCEPTED")
    eventFrame:RegisterEvent("QUEST_TURNED_IN")
    eventFrame:RegisterEvent("QUEST_REMOVED")
    eventFrame:RegisterEvent("QUEST_LOG_UPDATE")
    eventFrame:RegisterEvent("QUEST_WATCH_UPDATE")
    eventFrame:RegisterEvent("UNIT_QUEST_LOG_CHANGED")
    eventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    eventFrame:RegisterEvent("NEW_RECIPE_LEARNED") -- Spell objectives; Runes in SoD count as recipes because "Engraving" is a profession?
    --eventFrame:RegisterEvent("SPELLS_CHANGED") -- Spell objectives
    eventFrame:RegisterEvent("BAG_UPDATE_DELAYED") -- Catch quest item loots that bypass QUEST_WATCH_UPDATE (e.g. autoloot bots)

    eventFrame:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_HIDE")

    eventFrame:RegisterEvent("CHAT_MSG_COMBAT_FACTION_CHANGE")
    eventFrame:SetScript("OnEvent", _QuestEventHandler.OnEvent)

    -- Start periodic quest state verification timer.
    -- On Ascension, QUEST_LOG_UPDATE events can be unreliable. This timer forces
    -- a full reconciliation every 30 seconds, catching stale isComplete/WasComplete
    -- flags and ensuring objective spawnLists stay populated for active quests.
    if not _periodicRefreshTimer then
        _periodicRefreshTimer = C_Timer.NewTicker(PERIODIC_REFRESH_SECONDS, function()
            Questie:Debug(Questie.DEBUG_DEVELOP, "[Quest Event] Periodic refresh: forcing full quest log scan")
            doFullQuestLogScan = true
            _QuestEventHandler:QuestLogUpdate()
        end)
    end

    -- Force a full reconciliation whenever the player opens the native quest log.
    -- QuestLogCache only updates its stored objective counts when it detects a change, so if a
    -- scan ever ran while the game's own quest log text was still lagging behind the server, the
    -- Tracker can get stuck showing stale progress with nothing left to trigger a retry. Looking
    -- at the quest log is the moment the player is most likely to notice the mismatch, so treat it
    -- as a cue to force a fresh comparison against the live quest log state.
    local questLogFrame = QuestLogExFrame or ClassicQuestLog or QuestLogFrame
    if questLogFrame then
        questLogFrame:HookScript("OnShow", function()
            Questie:Debug(Questie.DEBUG_DEVELOP, "[Quest Event] Quest log opened: forcing full quest log scan")
            doFullQuestLogScan = true
            _QuestEventHandler:QuestLogUpdate()
        end)
    end

    -- StaticPopup dialog hooks. Deleteing Quest items do not always trigger a Quest Log Update.
    hooksecurefunc("StaticPopup_Show", function(...)
        -- Hook StaticPopup_Show. If we find the "DELETE_ITEM" dialog, check for Quest Items and notify the player.
        local which, text_arg1 = ...
        if which == "DELETE_ITEM" then
            local quest
            local questName
            local foundQuestItem = false

            Questie:Debug(Questie.DEBUG_DEVELOP, "[QuestieQuest] StaticPopup_Show: Item Name: ", text_arg1)

            if deletedQuestItem == true then
                deletedQuestItem = false
            end

            for questLogIndex = 1, 75 do
                local title, level, questTag, isHeader, isCollapsed, isComplete, isDaily, questId = GetQuestLogTitle(
                    questLogIndex)

                if title and questId and (not isHeader) then
                    quest = QuestieDB.GetQuest(questId)

                    if quest then
                        local info = StaticPopupDialogs[which]
                        local sourceItemId, soureItemName, sourceItemType, soureClassID
                        local reqSourceItemId, reqSoureItemName, reqSourceItemType, reqSoureClassID

                        if quest.sourceItemId then
                            sourceItemId = quest.sourceItemId

                            if sourceItemId then
                                soureItemName, _, _, _, _, sourceItemType, _, _, _, _, _, soureClassID = GetItemInfo(
                                    sourceItemId)
                            end
                        end

                        if quest.requiredSourceItems then
                            reqSourceItemId = quest.requiredSourceItems[1]

                            if reqSourceItemId then
                                reqSoureItemName, _, _, _, _, reqSourceItemType, _, _, _, _, _, reqSoureClassID =
                                    GetItemInfo(reqSourceItemId)
                            end
                        end

                        if sourceItemId and soureItemName and sourceItemType and soureClassID and (sourceItemType == "Quest" or soureClassID == 12) and QuestieDB.QueryItemSingle(sourceItemId, "class") == 12 and text_arg1 == soureItemName then
                            questName = quest.name
                            foundQuestItem = true
                            break
                        elseif reqSourceItemId and reqSoureItemName and reqSourceItemType and reqSoureClassID and (reqSourceItemType == "Quest" or reqSoureClassID == 12) and QuestieDB.QueryItemSingle(reqSourceItemId, "class") == 12 and text_arg1 == reqSoureItemName then
                            questName = quest.name
                            foundQuestItem = true
                            break
                        else
                            if quest.Objectives and #quest.Objectives > 0 then
                                for _, objective in pairs(quest.Objectives) do
                                    if text_arg1 == objective.Description then
                                        questName = quest.name
                                        foundQuestItem = true
                                        break
                                    end
                                end
                            end
                        end
                    end
                end
            end

            if foundQuestItem and quest and questName then
                local frame, text

                for i = 1, STATICPOPUP_NUMDIALOGS do
                    frame = _G["StaticPopup" .. i]
                    if (frame:IsShown()) and ((frame.text.text_arg1 == text_arg1) or (string.find(frame.text:GetText(), text_arg1))) then
                        text = _G[frame:GetName() .. "Text"]
                        break
                    end
                end

                if frame ~= nil and text ~= nil then
                    local updateText = l10n(
                        "Quest Item %%s might be needed for the quest %%s. \n\nAre you sure you want to delete this?")
                    text:SetFormattedText(updateText, text_arg1, questName)
                    text.text_arg1 = updateText

                    StaticPopup_Resize(frame, which)
                    deletedQuestItem = true

                    Questie:Debug(Questie.DEBUG_DEVELOP,
                        "[QuestieQuest] StaticPopup_Show: Quest Item Detected. Updating Static Popup.")
                end
            end
        end
    end)

    hooksecurefunc("DeleteCursorItem", function()
        -- Hook DeleteCursorItem so we know when the player clicks the Accept button
        -- FIX: Added InCombatLockdown guard and pcall to prevent tainting secure execution paths.
        if InCombatLockdown() then return end
        if deletedQuestItem then
            Questie:Debug(Questie.DEBUG_DEVELOP,
                "[QuestieQuest] DeleteCursorItem: Quest Item deleted. Update all quests.")

            C_Timer.After(0.25, function()
                pcall(function()
                    _QuestEventHandler:UpdateAllQuests()
                end)
                deletedQuestItem = false
            end)
        end
    end)

    _QuestEventHandler:InitQuestLog()
end

-- 5 seconds of half-second passes. A quest the client has still not handed over by then is
-- not going to arrive, and giving up lets the rebuild below run with what did arrive.
local INIT_QUEST_LOG_MAX_ATTEMPTS = 10

--- On Login mark all quests in the quest log with QUEST_ACCEPTED state
---@param attempt number? @1 on the first pass, incremented by each retry
function _QuestEventHandler:InitQuestLog(attempt)
    attempt = attempt or 1

    -- Fill the QuestLogCache for first time. Forced past the expand throttle: this read is what
    -- decides which quests exist for the rest of the session, so it has to see the whole log even
    -- if the player logged in with headers collapsed.
    local cacheMiss, changes = QuestLogCache.CheckForChanges(nil, true)

    -- Whatever was read is valid even when the rest of the log was not ready, so it is marked
    -- before any retry. The previous version returned here and threw these away.
    for questId, _ in pairs(changes) do
        questLog[questId] = {
            state = QUEST_LOG_STATES.QUEST_ACCEPTED
        }
        QuestieLib:CacheItemNames(questId)
    end

    if cacheMiss and attempt < INIT_QUEST_LOG_MAX_ATTEMPTS then
        Questie:Debug(Questie.DEBUG_INFO, "[QuestEventHandler:InitQuestLog] Cache miss during init, retrying in 0.5s... attempt:", attempt)
        C_Timer.After(0.5, function()
            _QuestEventHandler:InitQuestLog(attempt + 1)
        end)
        return
    end

    if attempt > 1 then
        -- The login sequence reads this cache exactly once, in QuestieQuest:GetAllQuestIds, and
        -- it can get there before the client has handed over every quest. Quests recovered by a
        -- retry are then in the cache but missing from currentQuestlog -- which is what the
        -- tracker draws from and what IsQuestWatched answers with -- so they stayed invisible,
        -- and their Track button did nothing, until a /reload found the client cache warm.
        -- Rebuilding from the now-complete cache is what that /reload was doing.
        Questie:Debug(Questie.DEBUG_INFO, "[QuestEventHandler:InitQuestLog] Quest log cache filled on attempt", attempt, "- rebuilding the quest log")
        QuestieQuest:GetAllQuestIds()
    end
end

--- Fires when a quest is accepted in anyway.
---@param questLogIndex number
---@param questId number
function _QuestEventHandler:QuestAccepted(questLogIndex, questId)
    local _, _, _, _, _, _, _, questLogQuestId = GetQuestLogTitle(questLogIndex)
    questId = questId or questLogQuestId
    Questie:Debug(Questie.DEBUG_DEVELOP, "[Quest Event] QUEST_ACCEPTED", questLogIndex, questId)

    if questLog[questId] and questLog[questId].timer then
        -- We had a QUEST_REMOVED event which started this timer and now it was accepted again.
        -- So the quest was abandoned before, because QUEST_TURNED_IN would have run before QUEST_ACCEPTED.
        questLog[questId].timer:Cancel()
        questLog[questId].timer = nil
        QuestieCombatQueue:Queue(function()
            _QuestEventHandler:MarkQuestAsAbandoned(questId)
        end)
    end

    -- If the quest was already in questLog as QUEST_TURNED_IN (e.g. Ebonhold Call Board repeatable
    -- quests that vanish without a proper QUEST_REMOVED event), clean up before re-accepting so the
    -- tracker doesn't show it as already complete.
    -- NOTE: Must check BEFORE wiping questLog[questId] below, otherwise the state check is always false.
    local wasTurnedIn = questLog[questId] and questLog[questId].state == QUEST_LOG_STATES.QUEST_TURNED_IN
    if wasTurnedIn then
        Questie:Debug(Questie.DEBUG_INFO, "Quest:", questId, "re-accepted after auto-complete, clearing stale state")
        QuestLogCache.RemoveQuest(questId)
        QuestieQuest:CompleteQuest(questId) -- clears per-quest data
        QuestieJourney:CompleteQuest(questId)
        QuestieAnnounce:CompletedQuest(questId)
        QuestieTracker:RemoveQuest(questId)
    end

    questLog[questId] = {}

    -- Timed quests do not need a full Quest Log Update.
    -- TODO: Add achievement timers later.
    local questTimers = GetQuestTimers(questId)
    if type(questTimers) == "number" then
        skipNextUQLCEvent = false
    else
        skipNextUQLCEvent = true
    end

    QuestieCombatQueue:Queue(function()
        QuestieLib:CacheItemNames(questId)
        _QuestEventHandler:HandleQuestAccepted(questId)
        QuestieTracker:Update()
    end)

    Questie:Debug(Questie.DEBUG_DEVELOP, "[Quest Event] QUEST_ACCEPTED - skipNextUQLCEvent - ", skipNextUQLCEvent)
end

---@param questId number
---@return boolean true @if the function was successful, false otherwise
function _QuestEventHandler:HandleQuestAccepted(questId)
    Questie:Debug(Questie.DEBUG_DEVELOP, "[QuestEventHandler] HandleQuestAccepted - questId:", questId)
    local idx = QuestieCompat.GetQuestLogIndexByID(questId)
    if not idx then
        Questie:Debug(Questie.DEBUG_DEVELOP, "[QuestEventHandler] HandleQuestAccepted - NO quest log index yet, retrying for questId:", questId)
        _QuestLogUpdateQueue:Insert(function()
            return _QuestEventHandler:HandleQuestAccepted(questId)
        end)
        return false
    end
    -- We first check the quest objectives and retry in the next QLU event if they are not correct yet
    local cacheMiss, changes = QuestLogCache.CheckForChanges({ [questId] = true })
    if cacheMiss then
        -- if cacheMiss, no need to check changes as only 1 questId
        Questie:Debug(Questie.DEBUG_DEVELOP, "[QuestEventHandler] HandleQuestAccepted - CACHE MISS for questId:", questId, "- retrying later")
        _QuestLogUpdateQueue:Insert(function()
            return _QuestEventHandler:HandleQuestAccepted(questId)
        end)

        return false
    end

    Questie:Debug(Questie.DEBUG_DEVELOP, "[QuestEventHandler] HandleQuestAccepted - cache ready, calling AcceptQuest for questId:", questId)
    questLog[questId].state = QUEST_LOG_STATES.QUEST_ACCEPTED
    QuestieQuest:SetObjectivesDirty(questId)

    QuestieJourney:AcceptQuest(questId)
    QuestieAnnounce:AcceptedQuest(questId)

    local isLastIslePhase = Questie.db.global.isleOfQuelDanasPhase == IsleOfQuelDanas.MAX_ISLE_OF_QUEL_DANAS_PHASES
    if Questie.IsWotlk and (not isLastIslePhase) and IsleOfQuelDanas.CheckForActivePhase(questId) then
        QuestieQuest:SmoothReset()
    else
        QuestieQuest:AcceptQuest(questId)
    end
    QuestieCompat.C_Timer.After(0.2, function()
        QuestieTracker:Update()
    end)
    return true
end

--- Fires when a quest is turned in
---@param questId number
---@param xpReward number
---@param moneyReward number
function _QuestEventHandler:QuestTurnedIn(questId, xpReward, moneyReward)
    Questie:Debug(Questie.DEBUG_DEVELOP, "[Quest Event] QUEST_TURNED_IN", xpReward, moneyReward, questId)

    -- Block UpdateQuest from redrawing objective pins while completion is in-flight
    QuestiePlayer.pendingCompleteQuestIds[questId] = true

    if questLog[questId] and questLog[questId].timer then
        -- Cancel the timer so the quest is not marked as abandoned
        questLog[questId].timer:Cancel()
        questLog[questId].timer = nil
    end

    Questie:Debug(Questie.DEBUG_INFO, "Quest:", questId, "was turned in and is completed")

    if questLog[questId] then
        -- There are quests which you just turn in so there is no preceding QUEST_ACCEPTED event and questLog[questId]
        -- is empty
        questLog[questId].state = QUEST_LOG_STATES.QUEST_TURNED_IN
    elseif QuestieCompat.Is335 then
        questLog[questId] = { state = QUEST_LOG_STATES.QUEST_TURNED_IN }
    end

    local parentQuest = QuestieDB.QueryQuestSingle(questId, "parentQuest")

    if parentQuest and parentQuest > 0 then
        -- Quests like "The Warsong Reports" have child quests which are just turned in. These child quests only
        -- fire QUEST_TURNED_IN + QUEST_LOG_UPDATE
        Questie:Debug(Questie.DEBUG_DEVELOP, "Quest:", questId, "Has a Parent Quest - do a full Quest Log check")
        doFullQuestLogScan = true
    end

    local itemName, _, _, quality, _, itemID = GetQuestLogRewardInfo(GetNumQuestLogRewards(questId), questId)

    if (itemID ~= nil or itemName ~= nil) and quality == 1 then
        Questie:Debug(Questie.DEBUG_DEVELOP, "Quest:", questId,
            "Recieved a possible Quest Item - do a full Quest Log check")
        doFullQuestLogScan = true
        skipNextUQLCEvent = false
    else
        skipNextUQLCEvent = true
    end

    QuestLogCache.RemoveQuest(questId)
    QuestieQuest:SetObjectivesDirty(questId) -- is this necessary? should whole quest.Objectives be cleared at some point of quest removal?

    -- Don't immediately mark as complete, wait for QUEST_REMOVED to confirm it was actually turned in
    -- This prevents completed quests from being saved as turned in when abandoned
    -- QuestieQuest:CompleteQuest(questId)
    -- QuestieJourney:CompleteQuest(questId)
    -- QuestieAnnounce:CompletedQuest(questId)
    -- questLog[questId] = nil

    QuestieCombatQueue:Queue(function()
        QuestieTracker:Update()
    end)
end

--- Fires when a quest is removed from the quest log. This includes turning it in and abandoning it.
---@param questId number
function _QuestEventHandler:QuestRemoved(questId)
    Questie:Debug(Questie.DEBUG_DEVELOP, "[Quest Event] QUEST_REMOVED", questId)
    doFullQuestLogScan = false

    if (not questLog[questId]) then
        questLog[questId] = {}
    end

    -- The party members don't care whether a quest was turned in or abandoned, so we can just broadcast here
    Questie:SendMessage("QC_ID_BROADCAST_QUEST_REMOVE", questId)

    -- QUEST_TURNED_IN was called before QUEST_REMOVED --> quest was turned in
    if questLog[questId].state == QUEST_LOG_STATES.QUEST_TURNED_IN then
        Questie:Debug(Questie.DEBUG_INFO, "Quest:", questId, "was turned in before. Completing quest.")

        -- Ensure the guard is set in case QUEST_REMOVED fires before the combat queue drains
        QuestiePlayer.pendingCompleteQuestIds[questId] = true

        -- Now that we confirmed the quest was actually turned in (not abandoned), mark it as complete
        QuestieQuest:CompleteQuest(questId)
        QuestieJourney:CompleteQuest(questId)
        QuestieAnnounce:CompletedQuest(questId)

        questLog[questId] = nil
        return
    end

    -- QUEST_REMOVED can fire before QUEST_TURNED_IN. If QUEST_TURNED_IN is not called after X seconds the quest
    -- was abandoned.
    --
    -- Capture the completion state NOW, while the quest is still in QuestLogCache. On Ascension some
    -- turn-ins (notably crafting/auto-complete quests) never fire QUEST_TURNED_IN, only QUEST_REMOVED,
    -- so MarkQuestAsAbandoned runs a second later — by which point the cache has been cleared and
    -- IsComplete can no longer tell the quest was finished, causing a turned-in quest to be misclassified
    -- as abandoned (its objective pins / turn-in "?" then linger). Snapshot it here so the timer can
    -- treat a quest that was complete at removal as a completion.
    local completeAtRemoval = QuestieDB.IsComplete(questId)
    questLog[questId] = {
        state = QUEST_LOG_STATES.QUEST_REMOVED,
        completeAtRemoval = completeAtRemoval,
        timer = C_Timer.NewTicker(1, function()
            _QuestEventHandler:MarkQuestAsAbandoned(questId)
        end, 1)
    }
    skipNextUQLCEvent = true
    Questie:Debug(Questie.DEBUG_DEVELOP, "[Quest Event] QUEST_REMOVED - skipNextUQLCEvent - ", skipNextUQLCEvent)
end

---@param questId number
function _QuestEventHandler:MarkQuestAsAbandoned(questId)
    Questie:Debug(Questie.DEBUG_DEVELOP, "QuestEventHandler:MarkQuestAsAbandoned")
    local questEntry = questLog[questId]

    -- so we don't attempt to index a nil value.
    if (not questEntry) then
        Questie:Debug(Questie.DEBUG_DEVELOP, "QuestEventHandler:MarkQuestAsAbandoned - questLog entry missing for",
            questId)
        return
    end

    if questEntry.state == QUEST_LOG_STATES.QUEST_REMOVED then
        -- Check if objectives were completed before the quest was removed.
        -- This handles auto-complete quests that disappear from the log without firing QUEST_TURNED_IN properly.
        -- If objectives were complete, treat it as a completion (not abandonment) so objective pins get hidden.
        local objectivesWereComplete = false
        local quest = QuestieDB.GetQuest(questId)
        -- Prefer the completion state snapshotted at QUEST_REMOVED time (before the cache was
        -- cleared); fall back to a live IsComplete if no snapshot was captured. This reliably
        -- catches turn-ins that skipped QUEST_TURNED_IN so they are completed, not abandoned.
        if questEntry.completeAtRemoval == 1 then
            objectivesWereComplete = true
        end
        if quest then
            local isComplete = QuestieDB.IsComplete(questId)
            objectivesWereComplete = objectivesWereComplete or (isComplete == 1)

            -- Check for Ebonhold auto-complete quests which might be removed before IsComplete returns 1
            local desc = quest.Description
            if type(desc) == "table" then desc = desc[1] end

            if (not objectivesWereComplete) and desc and type(desc) == "string" then
                if string.find(desc, "automatically rewarded") then
                    Questie:Debug(Questie.DEBUG_INFO, "Quest:", questId, "detected as auto-complete by description")
                    objectivesWereComplete = true
                end
            end
        end

        if objectivesWereComplete then
            -- Objectives were complete, so this was likely an auto-complete quest.
            -- Mark as complete instead of abandoned so objective pins get hidden.
            Questie:Debug(Questie.DEBUG_INFO, "Quest:", questId,
                "objectives were complete - treating as completed (auto-complete quest)")
            questEntry.state = QUEST_LOG_STATES.QUEST_TURNED_IN

            -- Clear stale objective data so re-accepting this quest later doesn't
            -- inherit Cached "Completed = true" / "isUpdated = true" flags that
            -- would cause PopulateObjectiveNotes to skip drawing map pins.
            if quest then
                quest.Objectives = {}
                quest.WasComplete = nil
                quest.isComplete = nil
            end
            QuestieQuest:SetObjectivesDirty(questId)

            QuestLogCache.RemoveQuest(questId)
            QuestieQuest:CompleteQuest(questId)
            QuestieJourney:CompleteQuest(questId)
            QuestieAnnounce:CompletedQuest(questId)
            questLog[questId] = nil
        else
            Questie:Debug(Questie.DEBUG_INFO, "Quest:", questId, "was abandoned")
            questEntry.state = QUEST_LOG_STATES.QUEST_ABANDONED

            QuestLogCache.RemoveQuest(questId)
            QuestieQuest:SetObjectivesDirty(questId) -- is this necessary? should whole quest.Objectives be cleared at some point of quest removal?

            QuestieQuest:AbandonedQuest(questId)
            QuestieJourney:AbandonQuest(questId)
            QuestieAnnounce:AbandonedQuest(questId)
            questLog[questId] = nil
        end
    end
end

-- 3.3.5 ships with Lua error display off, so an error thrown inside an event handler disappears
-- without a trace: no popup, no chat line, nothing anywhere. The two reconciliation passes below
-- run one after the other from QUEST_LOG_UPDATE, so an error in the first would silently stop the
-- second from ever running -- and from the outside that is indistinguishable from a pass that ran
-- and correctly found nothing to do. Each is guarded so it cannot take the other down with it, and
-- what each one saw is recorded so /questie why can tell those two cases apart.
QuestEventHandler.reconcileStats = {
    logUpdates = 0,
    cleanupRuns = 0,
    cleanupError = nil,
    registerRuns = 0,
    registerError = nil,
    lastAdded = 0,
    totalAdded = 0,
    lastCacheCount = 0,
    lastPartial = nil,
    lastVetoed = 0,
}

local function _RunReconcilePasses()
    local stats = QuestEventHandler.reconcileStats

    stats.cleanupRuns = stats.cleanupRuns + 1
    local cleanupOk, cleanupErr = pcall(function()
        _QuestEventHandler:CleanupRemovedQuestsFallback()
    end)
    stats.cleanupError = (not cleanupOk) and tostring(cleanupErr) or nil

    -- The two act on disjoint sets -- one takes quests that are gone from the log, the other adds
    -- quests that are in it -- so neither can undo the other.
    stats.registerRuns = stats.registerRuns + 1
    local registerOk, registerErr = pcall(function()
        _QuestEventHandler:RegisterMissingQuestsFallback()
    end)
    stats.registerError = (not registerOk) and tostring(registerErr) or nil
end

---Fires when the quest log changed in any way. This event fires very often!
function _QuestEventHandler:QuestLogUpdate()
    Questie:Debug(Questie.DEBUG_DEVELOP, "[Quest Event] QUEST_LOG_UPDATE")
    QuestEventHandler.reconcileStats.logUpdates = QuestEventHandler.reconcileStats.logUpdates + 1

    local continueQueuing = true
    -- Some of the other quest event didn't have the required information and ordered to wait for the next QLU.
    -- We are now calling the function which the event added.
    while continueQueuing and next(questLogUpdateQueue) do
        continueQueuing = _QuestLogUpdateQueue:GetFirst()()
    end

    if doFullQuestLogScan then
        doFullQuestLogScan = false
        -- Function call updates doFullQuestLogScan. Order matters.
        _QuestEventHandler:UpdateAllQuests()
        -- Also on this path: UpdateAllQuests only looks at quests still in the log, so a removal
        -- that fired no event of its own would sit there unnoticed for as long as full scans keep
        -- being asked for.
        _RunReconcilePasses()
    else
        _RunReconcilePasses()
        QuestieCombatQueue:Queue(function()
            QuestieTracker:Update()
        end)
    end
end

--- Fires whenever a quest objective progressed
---@param questId number
function _QuestEventHandler:QuestWatchUpdate(questId)
    Questie:Debug(Questie.DEBUG_DEVELOP, "[Quest Event] QUEST_WATCH_UPDATE", questId)

    -- We do a full scan even though we have the questId because many QUEST_WATCH_UPDATE can fire before
    -- a QUEST_LOG_UPDATE. Also not every QUEST_WATCH_UPDATE gets a single QUEST_LOG_UPDATE and doing a full
    -- scan is less error prone
    doFullQuestLogScan = true
    if questId and questId > 0 then
        questLog[questId] = questLog[questId] or {
            state = QUEST_LOG_STATES.QUEST_ACCEPTED
        }
        QuestieQuest:SetObjectivesDirty(questId)
    end

    if _questWatchUpdateDebounceTimer then
        _questWatchUpdateDebounceTimer:Cancel()
        _questWatchUpdateDebounceTimer = nil
    end
    _questWatchUpdateDebounceTimer = C_Timer.NewTimer(0.2, function()
        _questWatchUpdateDebounceTimer = nil
        doFullQuestLogScan = true
        _QuestEventHandler:QuestLogUpdate()
    end)

    if _questWatchUpdateFollowUpTimer then
        _questWatchUpdateFollowUpTimer:Cancel()
        _questWatchUpdateFollowUpTimer = nil
    end
    _questWatchUpdateFollowUpTimer = C_Timer.NewTimer(1.0, function()
        _questWatchUpdateFollowUpTimer = nil
        doFullQuestLogScan = true
        _QuestEventHandler:QuestLogUpdate()
    end)
end

local _UnitQuestLogChangedCallback = function()
    -- We also check in here because UNIT_QUEST_LOG_CHANGED is fired before the relevant events
    -- (Accept, removed, ...)
    if (not skipNextUQLCEvent) then
        doFullQuestLogScan = true
    else
        doFullQuestLogScan = false
        skipNextUQLCEvent = false
        Questie:Debug(Questie.DEBUG_INFO, "Skipping UnitQuestLogChanged")
    end
    return true
end

--- Fires when an objective changed in the quest log of the unitTarget. The required data is not available yet though
---@param unitTarget string
function _QuestEventHandler:UnitQuestLogChanged(unitTarget)
    Questie:Debug(Questie.DEBUG_DEVELOP, "[Quest Event] UNIT_QUEST_LOG_CHANGED", unitTarget)
    Questie:Debug(Questie.DEBUG_DEVELOP, "[Quest Event] UNIT_QUEST_LOG_CHANGED - skipNextUQLCEvent - ", skipNextUQLCEvent)

    -- There seem to be quests which don't trigger a QUEST_WATCH_UPDATE.
    -- We don't add a full check to the queue if skipNextUQLCEvent == true (from QUEST_WATCH_UPDATE or QUEST_TURNED_IN)
    if (not skipNextUQLCEvent) then
        doFullQuestLogScan = true
        _QuestLogUpdateQueue:Insert(_UnitQuestLogChangedCallback)

        -- Ascension can fire UNIT_QUEST_LOG_CHANGED without a follow-up QUEST_LOG_UPDATE.
        -- The event arrives before objective data is ready, so run a short delayed scan
        -- and one follow-up scan instead of waiting for an event that may never come.
        if _unitQuestLogChangedDebounceTimer then
            _unitQuestLogChangedDebounceTimer:Cancel()
            _unitQuestLogChangedDebounceTimer = nil
        end
        _unitQuestLogChangedDebounceTimer = C_Timer.NewTimer(0.2, function()
            _unitQuestLogChangedDebounceTimer = nil
            doFullQuestLogScan = true
            _QuestEventHandler:QuestLogUpdate()
        end)

        if _unitQuestLogChangedFollowUpTimer then
            _unitQuestLogChangedFollowUpTimer:Cancel()
            _unitQuestLogChangedFollowUpTimer = nil
        end
        _unitQuestLogChangedFollowUpTimer = C_Timer.NewTimer(1.0, function()
            _unitQuestLogChangedFollowUpTimer = nil
            doFullQuestLogScan = true
            _QuestEventHandler:QuestLogUpdate()
        end)
    else
        Questie:Debug(Questie.DEBUG_INFO, "Skipping UnitQuestLogChanged")
    end
    skipNextUQLCEvent = false
end

-- Fallback cleanup: some servers remove quests without firing QUEST_REMOVED reliably.
-- This compares Questie's currentQuestlog vs the game's quest log and removes stale quests.
function _QuestEventHandler:CleanupRemovedQuestsFallback()
    -- This runs on every QUEST_LOG_UPDATE, and collapsing a header fires one -- so it cannot
    -- expand the log itself without driving the event in a loop. It can refuse to act on a log it
    -- knows is incomplete: a collapsed header takes its quests out of the walk below, and every
    -- one of them would then be read as removed and filed as abandoned. Doing nothing for as long
    -- as a header is shut only delays the cleanup of a quest that really did go.
    if QuestieCompat.IsQuestLogPartial() then
        Questie:Debug(Questie.DEBUG_DEVELOP,
            "[CleanupRemovedQuestsFallback] Quest log has collapsed headers, skipping removal pass")
        return
    end

    local gameQuestIds = {}
    local numEntries = select(1, GetNumQuestLogEntries()) or 0
    for questLogIndex = 1, numEntries do
        local title, level, questTag, isHeader, isCollapsed, isComplete, isDaily, qid = GetQuestLogTitle(questLogIndex)
        if title and qid and qid > 0 and (not isHeader) then
            gameQuestIds[qid] = true
        end
    end

    if QuestiePlayer and QuestiePlayer.currentQuestlog then
        local removedQuestIds = {}
        for questId in pairs(QuestiePlayer.currentQuestlog) do
            -- Typed check: a stray string key (saved variables have produced them) would other-
            -- wise error on the comparison and take the whole pass down with it.
            if type(questId) == "number" and questId > 0 and (not gameQuestIds[questId]) then
                removedQuestIds[#removedQuestIds + 1] = questId
            end
        end

        for i = 1, #removedQuestIds do
            local questId = removedQuestIds[i]

            -- Quest disappeared from log (abandoned or auto-turned-in)
            -- Check if this quest was confirmed as turned in (not just objectives complete)
            local wasTurnedIn = questLog[questId] and questLog[questId].state == QUEST_LOG_STATES.QUEST_TURNED_IN
            local wasAlreadyComplete = Questie.db.char.complete and Questie.db.char.complete[questId]
            local completeAtRemoval = QuestieDB.IsComplete(questId)
            -- The server's own record, and the only one that knows anything about a quest the
            -- database has never heard of: QuestieDB.IsComplete cannot answer for those, so an
            -- Ascension quest the server finished by itself would otherwise be filed as abandoned.
            local serverFlaggedComplete = IsQuestFlaggedCompleted and IsQuestFlaggedCompleted(questId)
            local shouldComplete = wasTurnedIn or wasAlreadyComplete or completeAtRemoval == 1 or
                serverFlaggedComplete

            QuestLogCache.RemoveQuest(questId)
            QuestieQuest:SetObjectivesDirty(questId)

            -- Only mark as complete if it was actually turned in OR already marked complete from previous session
            -- Don't use quest.WasComplete because that's set when objectives complete, not when quest is turned in
            if shouldComplete then
                QuestieQuest:CompleteQuest(questId)
            else
                QuestieQuest:AbandonedQuest(questId)
                QuestieJourney:AbandonQuest(questId)
                QuestieAnnounce:AbandonedQuest(questId)
            end

            questLog[questId] = nil
        end

        if #removedQuestIds > 0 then
            QuestieNameplate:UpdateNameplate()
            QuestieCombatQueue:Queue(function()
                QuestieTracker:Update()
            end)
        end
    end
end

-- The mirror of CleanupRemovedQuestsFallback: a quest the player has that Questie never took a
-- record of. currentQuestlog is built once at login, by GetAllQuestIds, out of whatever
-- QuestLogCache happened to hold at that moment -- and the client fills that cache in waves,
-- because CheckForChanges skips a quest whose objective text the server has not sent yet. A quest
-- that lands in the cache after the last rebuild is then in the cache and in nothing else:
-- UpdateAllQuests only ever revisits quests it already knows, and after login the only things that
-- add to currentQuestlog are accepting a quest and the tracker's own fallback path. The tracker,
-- the arrow and IsQuestWatched all read currentQuestlog, so such a quest stays invisible for the
-- rest of the session however many times the log updates.
--
-- Registering it here is the same work the login rebuild does, so a quest that arrives late ends
-- up indistinguishable from one that arrived on time.
--
-- Driven from QuestLogCache rather than a walk of the log, and that asymmetry with
-- CleanupRemovedQuestsFallback is deliberate. A collapsed header takes its quests out of the index
-- space the log walk sees, so a walk cannot find exactly the quests this pass exists to rescue --
-- while the cache is collapse-proof, because CheckForChanges expands the whole log before reading,
-- and it is pruned on removal by QuestLogCache.RemoveQuest. The cleanup pass has the opposite need:
-- the log is the only authority on what is gone, which is why it keeps its walk and refuses to run
-- on a partial log. One adds from the cache, the other removes from the log, and the sets stay
-- disjoint.
function _QuestEventHandler:RegisterMissingQuestsFallback()
    if not QuestiePlayer.currentQuestlog then return end

    -- When nothing is collapsed the walk is complete, so it can be trusted to veto a cache entry
    -- for a quest the player no longer has -- a removal that landed while a header was shut leaves
    -- one behind, because the cleanup pass declines to run then. When the log IS partial there is
    -- nothing to check against and the cache stands on its own.
    local stats = QuestEventHandler.reconcileStats
    local partial = QuestieCompat.IsQuestLogPartial()
    stats.lastPartial = partial

    local inLog
    if not partial then
        inLog = {}
        local numEntries = select(1, GetNumQuestLogEntries()) or 0
        for questLogIndex = 1, numEntries do
            local title, _, _, isHeader, _, _, _, logId = GetQuestLogTitle(questLogIndex)
            if title and logId and logId > 0 and (not isHeader) then
                inLog[logId] = true
            end
        end
    end

    local added, cacheCount, vetoed = 0, 0, 0
    for questId in pairs(QuestLogCache.questLog_DO_NOT_MODIFY or {}) do
        cacheCount = cacheCount + 1
        -- Counted separately from "already registered": a cache entry the log walk cannot vouch
        -- for is the one case where this pass declines to act on the cache, and it is the only
        -- way a quest that is plainly in the cache can come out of here still unregistered.
        if type(questId) == "number" and questId > 0
            and (not QuestiePlayer.currentQuestlog[questId])
            and inLog and (not inLog[questId]) then
            vetoed = vetoed + 1
        end
        if type(questId) == "number" and questId > 0
            and (not QuestiePlayer.currentQuestlog[questId])
            and ((not inLog) or inLog[questId]) then
            local quest = QuestieDB.GetQuest(questId)

            if quest then
                QuestiePlayer.currentQuestlog[questId] = quest
                -- Objectives come from here. Guarded because one quest failing to populate must
                -- not strand the ones after it -- which is exactly what the login rebuild, an
                -- unprotected loop over every quest, has no defence against.
                local ok, err = pcall(function() QuestieQuest:PopulateQuestLogInfo(quest) end)
                if not ok then
                    Questie:Debug(Questie.DEBUG_CRITICAL,
                        "[RegisterMissingQuestsFallback] PopulateQuestLogInfo failed for", questId, err)
                end
            else
                -- No database row and none to build from: register the id on its own, the same
                -- way the login rebuild does, and the tracker builds an object from the log.
                QuestiePlayer.currentQuestlog[questId] = questId
            end

            added = added + 1
            Questie:Debug(Questie.DEBUG_INFO,
                "[RegisterMissingQuestsFallback] registering quest the rebuild never took:", questId)
        end
    end

    stats.lastCacheCount = cacheCount
    stats.lastVetoed = vetoed
    stats.lastAdded = added
    stats.totalAdded = stats.totalAdded + added

    if added > 0 then
        QuestieCombatQueue:Queue(function()
            QuestieTracker:Update()
        end)
    end

    return added
end

--- Does a full scan of the quest log and updates every quest that is in the QUEST_ACCEPTED state and which hash changed
--- since the last check
function _QuestEventHandler:UpdateAllQuests()
    Questie:Debug(Questie.DEBUG_INFO, "Running full questlog check")
    local questIdsToCheck = {}

    -- TODO replace with a ready table so no need to generate at each call
    for questId, data in pairs(questLog) do
        if data.state == QUEST_LOG_STATES.QUEST_ACCEPTED then
            questIdsToCheck[questId] = true
        end
    end

    local cacheMiss, changes = QuestLogCache.CheckForChanges(questIdsToCheck)

    if next(changes) then
        for questId, objIds in pairs(changes) do
            --Questie:Debug(Questie.DEBUG_INFO, "Quest:", questId, "objectives:", table.concat(objIds, ","), "will be updated")
            Questie:Debug(Questie.DEBUG_INFO, "Quest:", questId, "will be updated")
            QuestieQuest:SetObjectivesDirty(questId)

            QuestieNameplate:UpdateNameplate()
            QuestieQuest:UpdateQuest(questId)
        end
        QuestieCombatQueue:Queue(function()
            QuestieTracker:Update()
            C_Timer.After(1.0, function()
                QuestieTracker:Update()
            end)
        end)
    else
        Questie:Debug(Questie.DEBUG_INFO, "Nothing to update")
    end


    _QuestEventHandler:CleanupRemovedQuestsFallback()

    -- Do UpdateAllQuests() again at next QUEST_LOG_UPDATE if there was "cacheMiss" (game's cache and addon's cache didn't have all required data yet)
    doFullQuestLogScan = doFullQuestLogScan or cacheMiss
end

local lastTimeQuestRelatedFrameClosedEvent = -1
--- Blizzard does not fire any event when quest items are received or retrieved from sources other than looting.
--- So we hook events which fires once or twice after closing certain frames and do a full quest log check.
function _QuestEventHandler:QuestRelatedFrameClosed(event)
    local now = math.floor(GetTime())
    -- Don't do update if event fired twice
    if lastTimeQuestRelatedFrameClosedEvent ~= now then
        Questie:Debug(Questie.DEBUG_DEVELOP, "[Quest Event]", event)

        lastTimeQuestRelatedFrameClosedEvent = now
        _QuestEventHandler:UpdateAllQuests()
        QuestieTracker:Update()
    end
end

function _QuestEventHandler:ReputationChange()
    Questie:Debug(Questie.DEBUG_DEVELOP, "[Quest Event] CHAT_MSG_COMBAT_FACTION_CHANGE")

    -- Reputational quest progression doesn't fire UNIT_QUEST_LOG_CHANGED event, only QUEST_LOG_UPDATE event.
    doFullQuestLogScan = true
end

--- Helper function to insert a callback to the questLogUpdateQueue and increase the index
function _QuestLogUpdateQueue:Insert(callback)
    questLogUpdateQueue[questLogUpdateQueueSize] = callback
    questLogUpdateQueueSize = questLogUpdateQueueSize + 1
end

--- Helper function to retrieve the first element of questLogUpdateQueue
---@return function @The callback that was inserted first into questLogUpdateQueue
function _QuestLogUpdateQueue:GetFirst()
    questLogUpdateQueueSize = questLogUpdateQueueSize - 1
    return tableRemove(questLogUpdateQueue, 1)
end

local trackerMinimizedByDungeon = false
function _QuestEventHandler:ZoneChangedNewArea()
    Questie:Debug(Questie.DEBUG_DEVELOP, "[EVENT] ZONE_CHANGED_NEW_AREA")
    -- By my tests it takes a full 6-7 seconds for the world to load. There are a lot of
    -- backend Questie updates that occur when a player zones in/out of an instance. This
    -- is necessary to get everything back into it's "normal" state after all the updates.
    local isInInstance, instanceType = IsInInstance()

    if isInInstance then
        C_Timer.After(8, function()
            Questie:Debug(Questie.DEBUG_DEVELOP, "[EVENT] ZONE_CHANGED_NEW_AREA: Entering Instance")
            if Questie.db.profile.hideTrackerInDungeons then
                trackerMinimizedByDungeon = true

                QuestieCombatQueue:Queue(function()
                    QuestieTracker:Collapse()
                end)
            end
        end)

        -- We only want this to fire outside of an instance if the player isn't dead and we need to reset the Tracker
    elseif (not Questie.db.char.isTrackerExpanded and not UnitIsGhost("player")) and trackerMinimizedByDungeon == true then
        C_Timer.After(8, function()
            Questie:Debug(Questie.DEBUG_DEVELOP, "[EVENT] ZONE_CHANGED_NEW_AREA: Exiting Instance")
            if Questie.db.profile.hideTrackerInDungeons then
                trackerMinimizedByDungeon = false

                QuestieCombatQueue:Queue(function()
                    QuestieTracker:Expand()
                end)
            end
        end)
    end
end

--- Is executed whenever an event is fired and triggers relevant event handling.
---@param event string
function _QuestEventHandler:OnEvent(event, ...)
    if event == "QUEST_ACCEPTED" then
        _QuestEventHandler:QuestAccepted(...)
    elseif event == "QUEST_TURNED_IN" then
        _QuestEventHandler:QuestTurnedIn(...)
    elseif event == "QUEST_REMOVED" then
        _QuestEventHandler:QuestRemoved(...)
    elseif event == "QUEST_LOG_UPDATE" then
        _QuestEventHandler:QuestLogUpdate()
    elseif event == "QUEST_WATCH_UPDATE" then
        _QuestEventHandler:QuestWatchUpdate(...)
    elseif event == "UNIT_QUEST_LOG_CHANGED" and select(1, ...) == "player" then
        _QuestEventHandler:UnitQuestLogChanged(...)
    elseif event == "ZONE_CHANGED_NEW_AREA" then
        _QuestEventHandler:ZoneChangedNewArea()
    elseif event == "NEW_RECIPE_LEARNED" then
        Questie:Debug(Questie.DEBUG_DEVELOP, "[EVENT] NEW_RECIPE_LEARNED (QuestEventHandler)")
        doFullQuestLogScan = true -- If this event is related to a spell objective, a QUEST_LOG_UPDATE will be fired afterwards
    elseif event == "BAG_UPDATE_DELAYED" then
        -- Autoloot bots bypass the loot frame entirely, so QUEST_WATCH_UPDATE never fires for bot-looted items.
        -- Additionally, when a bot loots a stack very quickly the server batches the quest-objective counter
        -- updates so C_QuestLog.GetQuestObjectives still returns the OLD count when this event fires.
        -- Strategy:
        --   1) Immediate scan (catches single-item normal loots and is fast).
        --   2) Debounce rapid fires to at most one extra scan per 0.3s burst.
        --   3) Always schedule a follow-up scan 2 s later so the server counter has time to catch up.
        doFullQuestLogScan = true
        _QuestEventHandler:QuestLogUpdate()

        -- Cancel any pending debounce timer so rapid fires collapse into one.
        if _bagUpdateDebounceTimer then
            _bagUpdateDebounceTimer:Cancel()
            _bagUpdateDebounceTimer = nil
        end
        _bagUpdateDebounceTimer = C_Timer.NewTimer(0.3, function()
            _bagUpdateDebounceTimer = nil
            -- Second scan: picks up any items the immediate scan missed.
            doFullQuestLogScan = true
            _QuestEventHandler:QuestLogUpdate()
        end)

        -- Follow-up scan: wait for the server's quest counters to reflect the full loot batch.
        if _bagUpdateFollowUpTimer then
            _bagUpdateFollowUpTimer:Cancel()
        end
        _bagUpdateFollowUpTimer = C_Timer.NewTimer(2.0, function()
            _bagUpdateFollowUpTimer = nil
            Questie:Debug(Questie.DEBUG_DEVELOP, "[BAG_UPDATE_DELAYED] Follow-up scan for batch loot bot items")
            doFullQuestLogScan = true
            _QuestEventHandler:QuestLogUpdate()
        end)
    elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" then
        local eventType = select(1, ...)
        if eventType == 1 then
            event = "TRADE_CLOSED"
        elseif eventType == 5 then
            event = "MERCHANT_CLOSED"
        elseif eventType == 8 then
            event = "BANKFRAME_CLOSED"
        elseif eventType == 10 then
            event = "GUILDBANKFRAME_CLOSED"
        elseif eventType == 12 then
            event = "VENDOR_CLOSED"
        elseif eventType == 17 then
            event = "MAIL_CLOSED"
        elseif eventType == 21 then
            event = "AUCTION_HOUSE_CLOSED"
        else
            -- Unknown event which we will simply ignore
            return
        end
        _QuestEventHandler:QuestRelatedFrameClosed(event)
    elseif event == "CHAT_MSG_COMBAT_FACTION_CHANGE" then
        _QuestEventHandler:ReputationChange()
    end
end
