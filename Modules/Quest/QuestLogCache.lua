--- Contains last known valid state of each quest in game's quest log, per quest.
--- I.E. All data related to a quest is valid.
--- Includes a "hack" to have correct objectives' progress while quest isComplete = 1. Otherwise it would need to be done everywhere else in code
---@class QuestLogCache
local QuestLogCache = QuestieLoader:CreateModule("QuestLogCache")
---@type QuestieLib
local QuestieLib = QuestieLoader:ImportModule("QuestieLib")
---@type Sounds
local Sounds = QuestieLoader:ImportModule("Sounds")

--- COMPATIBILITY ---
local QuestieCompat = QuestieCompat -- Ensure it's loaded
local GetQuestLogTitle = QuestieCompat.GetQuestLogTitle
local C_QuestLog_GetQuestObjectives = QuestieCompat.C_QuestLog and QuestieCompat.C_QuestLog.GetQuestObjectives
local HaveQuestData = QuestieCompat.HaveQuestData

local stringByte = string.byte

-- 3 * (Max possible number of quests in game quest log)
-- This is a safe value, even smaller would be enough. Too large won't effect performance
local MAX_QUEST_LOG_INDEX = 75

--[[
Example of data in cache table.
raw_* are as in game's quest log. Their non-raw versions are corrected/modified for addon's easy use.

local cache = {
    [questId] = {
        title = "Quest name",
        questTag = "Dungeon", -- nil, "Dungeon", "Raid", etc.
        isComplete = nil,
        objectives = {
            {
                text = "Objective Text"
                type = "monster",
                finished = false,
                numFulfilled = 2,
                numRequired = 3,
                raw_Text = "Objective Text slain: 2/3",
                raw_finished = false
                raw_numFulfilled = 2,
            },
            {
                text = "Objective2"
                type = "item",
                finished = false,
                numFulfilled = 0,
                numRequired = 5,
                raw_text = "Objective2 : 0/5",
                raw_finished = false,
                raw_numFulfilled = 0,
            },
            ....
        },
    [questId2] = ....,
}
]] --


---@class QuestLogCacheObjectiveData
---@field text string "Objective Text"
---@field type "monster"|"object"|"item"|"reputation"|"killcredit"|"event"|"spell"
---@field finished boolean
---@field numFulfilled number
---@field numRequired number
---@field raw_Text string E.g "Objective Text slain: 2/3",
---@field raw_finished boolean
---@field raw_numFulfilled number

---@class QuestLogCacheData
---@field title string
---@field questTag QuestTag
---@field isComplete -1|0|1 @ -1 = failed, 0 = not complete, 1 = complete
---@field objectives QuestLogCacheObjectiveData[]


---@type table<QuestId, QuestLogCacheData>
local cache = {}

--- NEVER EVER EDIT this table outside of the QuestLogCache module!  !!!
---@type table<QuestId, QuestLogCacheData>
QuestLogCache.questLog_DO_NOT_MODIFY = cache



---@return table? newObjectives, ObjectiveIndex[] changedObjIds @nil == cache miss in both addon and game caches. table {} == no objectives.
local function GetNewObjectives(questId, oldObjectives, questLogIndex)
    local newObjectives = {} -- creating a fresh one to be able revert to old easily in case of missing data
    local changedObjIds      -- not assigning {} for easier nil when nothing changed
    local objectives = C_QuestLog_GetQuestObjectives(questId, questLogIndex)

    for objIndex = 1, table.getn(objectives) do -- iterate manually to be sure getting those in order
        local oldObj = oldObjectives[objIndex]
        local newObj = objectives[objIndex]
        -- Check if objective.text is in game's cache
        if (newObj.text) and (stringByte(newObj.text, 1) ~= 32) then
            -- Check if objective has changed
            if oldObj and oldObj.raw_numFulfilled == newObj.numFulfilled and oldObj.raw_text == newObj.text and oldObj.raw_finished == newObj.finished and oldObj.numRequired == newObj.numRequired and oldObj.type == newObj.type then
                -- Not changed
                newObjectives[objIndex] = oldObj
            else
                -- objective has changed, add it to list of change ones
                if (not changedObjIds) then
                    changedObjIds = { objIndex }
                else
                    changedObjIds[table.getn(changedObjIds) + 1] = objIndex
                end

                if oldObj and newObj and oldObj.numRequired ~= oldObj.numFulfilled and newObj.numRequired == newObj.numFulfilled then
                    Sounds.PlayObjectiveComplete()
                end

                if oldObj and newObj and oldObj.numRequired ~= oldObj.numFulfilled and newObj.numRequired ~= newObj.numFulfilled then
                    Sounds.PlayObjectiveProgress()
                end

                newObjectives[objIndex] = {
                    raw_text = newObj.text,
                    raw_finished = newObj.finished,
                    raw_numFulfilled = newObj.numFulfilled,
                    type = newObj.type,
                    numRequired = newObj.numRequired,
                    text = QuestieLib.TrimObjectiveText(newObj.text, newObj.type),
                    finished = newObj.finished,         -- gets overwritten with correct value later if quest isComplete
                    numFulfilled = newObj.numFulfilled, -- gets overwritten with correct value later if quest isComplete
                }
            end
        else -- objective text not in game's cache
            if oldObj then
                Questie:Debug(Questie.DEBUG_INFO,
                    "[GetNewObjectives] objective not in game's cache. Using addon's cache. questID, objIndex:", questId,
                    objIndex)
                -- Extremely unlikely that the objective has changed from cached version as a change SHOULD trigger fetching data into game cache.
                -- Possible bug point if there comes desync issues.
                newObjectives[objIndex] = oldObj
            else
                Questie:Debug(Questie.DEBUG_INFO,
                    "[GetNewObjectives] \"WARNING\" objective not in game's cache nor addon's cache. questID, objIndex:",
                    questId, objIndex)
                -- Objective has been never cached
                -- Tell to function caller that we couldn't get all required data from game's cache
                -- Don't loop rest of objectives as we won't anyway save those into cache[] and C_QuestLog.GetQuestObjectives() call already triggered game to initiate caching those into game's cache.
                return nil
            end
        end
    end

    return newObjectives, changedObjIds
end

-- For profiling
QuestLogCache._GetNewObjectives = GetNewObjectives

-- Reads the quest log as it stands. Call through QuestLogCache.CheckForChanges, which makes sure
-- the whole log is walkable first.
local function CheckForChanges(questIdsToCheck)
    local cacheMiss = false
    local changes = {}
    local questIdsChecked = {}

    local numEntries, numQuests = GetNumQuestLogEntries()
    numEntries = numEntries or 0
    -- The header a quest sits under is only knowable from its position in this walk, and the
    -- tracker needs it to group quests the database has never heard of. Recording it here means
    -- the tracker still has it for a quest that a later, partial walk cannot reach.
    local header
    -- How many quests this walk could actually reach, checked against the client's own total below.
    local questsSeen = 0

    for questLogIndex = 1, numEntries do
        local title, level, questTag, isHeader, isCollapsed, isComplete, isDaily, questId = GetQuestLogTitle(
        questLogIndex)

        if isHeader then
            if title and title ~= "" then
                header = title
            end
        -- Skip weird/header entries / questId=0 (these happen a lot on your server)
        elseif title and questId and questId > 0 then
            questsSeen = questsSeen + 1
            if (not questIdsToCheck) or questIdsToCheck[questId] then
                questIdsChecked[questId] = true

                if HaveQuestData(questId) then
                    local cachedQuest = cache[questId]
                    local cachedObjectives = cachedQuest and cachedQuest.objectives or {}

                    local newObjectives, changedObjIds = GetNewObjectives(questId, cachedObjectives, questLogIndex)

                    if newObjectives then
                        -- Quest-level state (title / tag / isComplete) can change without any
                        -- objective line changing. The equal-count guard stops a transiently
                        -- empty leaderboard from wiping a populated cache entry, but it must NOT
                        -- also require a non-empty list: a pure exploration quest (questKeys.
                        -- triggerEnd, e.g. "Investigating the Camp") has no countable leaderboard
                        -- line at all, so GetNewObjectives can never report a change for it. With
                        -- a "> 0" clause here its cache entry was written once and then frozen,
                        -- leaving isComplete stuck at 0 for the session -- which kept
                        -- QuestieDB.IsComplete returning 0 and pinned the arrow to the explored
                        -- spot forever.
                        if (not cachedQuest) or (table.getn(cachedObjectives) == table.getn(newObjectives) and
                                (cachedQuest.title ~= title or cachedQuest.questTag ~= questTag or cachedQuest.isComplete ~= isComplete)) then
                            changedObjIds = {}
                            for i = 1, table.getn(newObjectives) do
                                changedObjIds[i] = i
                            end

                            if isComplete == 1 then
                                for i = 1, table.getn(newObjectives) do
                                    local o = newObjectives[i]
                                    o.finished = true
                                    o.numFulfilled = o.numRequired
                                end
                            end
                        end

                        if cachedQuest and (not cachedQuest.isComplete) and isComplete == 1 then
                            Sounds.PlayQuestComplete()
                        end

                        if changedObjIds then
                            cache[questId] = {
                                title = title,
                                questTag = questTag,
                                isComplete = isComplete,
                                objectives = newObjectives,
                                header = header,
                            }
                            changes[questId] = changedObjIds
                        end

                        -- Also on the unchanged path: a quest whose objectives never move still
                        -- gets refiled when the server changes its category, and the entry is
                        -- only rewritten above when something changed.
                        if cache[questId] and header then
                            cache[questId].header = header
                        end
                    else
                        cacheMiss = true
                    end
                else
                    Questie:Debug(Questie.DEBUG_CRITICAL,
                        "[QuestLogCache.CheckForChanges] HaveQuestData() == false. questId, index:", questId,
                        questLogIndex)
                    C_QuestLog_GetQuestObjectives(questId, questLogIndex)
                    cacheMiss = true
                end
            end
        end
    end

    -- A quest the walk could not reach at all is a cache miss too, and it is a different kind from
    -- the one above: that one means "this quest's objective text has not arrived yet", which only
    -- gets noticed for a quest that was visible in the first place. A quest hidden behind a
    -- collapsed header is not visible, so nothing was ever recorded as missing for it -- the login
    -- read then looked complete, InitQuestLog never retried, and the rebuild it does on a retry
    -- never happened. currentQuestlog was left short of the log for the rest of the session.
    --
    -- GetNumQuestLogEntries' second return counts every quest the log holds, collapsed or not (it
    -- is what the "Quests: n/25" counter shows), so a walk that came up short read a partial log.
    -- Only used to ask for a retry, never to discard anything, so a client that reports this
    -- oddly costs a few extra login passes and nothing else.
    if type(numQuests) == "number" and numQuests > 0 and questsSeen < numQuests then
        Questie:Debug(Questie.DEBUG_INFO, "[QuestLogCache.CheckForChanges] Only reached", questsSeen,
            "of", numQuests, "quests -- treating as a cache miss so the log is read again")
        cacheMiss = true
    end

    -- Debug / warning: ignore questId=0 and don't treat it as "missing" when the log has weird entries
    if questIdsToCheck then
        local questId, _ = next(questIdsToCheck)
        while questId do
            if questId and questId > 0 and (not questIdsChecked[questId]) then
                Questie:Warning("Please report on Github or Discord. QuestId doesn't exist in Game's quest log:", questId)
            end
            questId, _ = next(questIdsToCheck, questId)
        end
    end

    return cacheMiss, changes
end

--- Updates questlogcache.
--- Remember to handle returned changes table even when cacheMiss == true. Returned changes are still valid. There may just be more changes that we couldn't get yet.
--- Called only from QuestEventHandler.
---@param questIdsToCheck table? @keys are the questIds
---@param forceFullLog boolean? @bypass the expand throttle; for the login read
---@return boolean cacheMiss, table changes @cacheMiss = couldn't get all required data  ; changes[questId] = list of changed objectiveIndexes (may be an empty list if quest has no objectives)
function QuestLogCache.CheckForChanges(questIdsToCheck, forceFullLog)
    -- A collapsed header hides its quests from the walk below, and this is the only thing that
    -- puts a quest into the cache -- so without expanding first, a quest the player accepted
    -- under a shut header is never cached, never reaches currentQuestlog, and never draws.
    return QuestieCompat.WithFullQuestLog(function()
        return CheckForChanges(questIdsToCheck)
    end, forceFullLog)
end

--- The quest log header the client filed a quest under, as of the last walk that could see it.
--- Survives the quest being hidden behind a collapsed header, which the live log cannot report.
---@param questId QuestId
---@return string?
function QuestLogCache.GetHeader(questId)
    local entry = cache[questId]
    return entry and entry.header
end

function QuestLogCache.RemoveQuest(questId)
    Questie:Debug(Questie.DEBUG_DEVELOP, "[QuestLogCache.RemoveQuest] remove questId:", questId)
    cache[questId] = nil
    -- Also evict any live fallback object so stale tracker entries don't persist.
    local QuestieDB = QuestieLoader:ImportModule("QuestieDB")
    if QuestieDB and QuestieDB.InvalidateLiveQuest then
        QuestieDB.InvalidateLiveQuest(questId)
    end
end

--- Tests if game client's cache has all quest log quests and objectives cached.
--- Avoid using this function if possible.
---@return boolean gameCacheOK
local function TestGameCache()
    local gameCacheOK = true
    for questLogIndex = 1, MAX_QUEST_LOG_INDEX do
        local title, level, questTag, isHeader, isCollapsed, isComplete, isDaily, questId = GetQuestLogTitle(
        questLogIndex)
        if title and questId and (not isHeader) then
            if HaveQuestData(questId) then
                local objectives = C_QuestLog_GetQuestObjectives(questId, questLogIndex)

                for objIndex = 1, table.getn(objectives) do
                    local text = objectives[objIndex].text
                    -- Check if objective.text is not in game's cache
                    if (not text) or (stringByte(text, 1) == 32) then
                        gameCacheOK = false
                    end
                end
            else
                gameCacheOK = false
            end
        end
    end

    Questie:Debug(Questie.DEBUG_DEVELOP, "[QuestLogCache.TestGameCache]",
        (gameCacheOK and "Cache ok." or "Cache missing data."))
    return gameCacheOK
end

--- Tests if game client's cache has all quest log quests and objectives cached.
--- Avoid using this function if possible.
---@return boolean gameCacheOK
function QuestLogCache.TestGameCache()
    -- Expanded first, or a quest behind a shut header is reported as cached simply by being
    -- invisible to the walk.
    return QuestieCompat.WithFullQuestLog(TestGameCache)
end

--- A wrapper function to add error check instead using exposed table directly.
---@param questId QuestId
---@return QuestLogCacheData? @NEVER EVER MODIFY THE RETURNED TABLE
function QuestLogCache.GetQuest(questId)
    -- Fix the issue at function caller side if this error pops up.
    if (not cache[questId]) then
        -- Graceful degradation: return nil instead of throwing a fatal error if questId is 0 or Questie has not finished starting.
        -- This prevents many common initialization race conditions on custom clients like Ascension.
        if questId == 0 or (not Questie.started) then
            return nil
        end
        Questie:Debug(Questie.DEBUG_DEVELOP, debugstack(1, 20, 4))
        Questie:Debug(Questie.DEBUG_DEVELOP, "GetQuest: The quest doesn't exist in QuestLogCache.", questId)
        return nil
    end
    return cache[questId]
end

--- A wrapper function to add error check instead using exposed table directly.
---@param questId QuestId
---@return table<ObjectiveIndex, QuestLogCacheObjectiveData>? @NEVER EVER MODIFY THE RETURNED TABLE
function QuestLogCache.GetQuestObjectives(questId)
    -- Fix the issue at function caller side if this error pops up.
    if (not cache[questId]) then
        -- Graceful degradation: return an empty table instead of throwing a fatal error if questId is 0 or Questie has not finished starting.
        if questId == 0 or (not Questie.started) then
            return {}
        end
        Questie:Debug(Questie.DEBUG_DEVELOP, debugstack(1, 20, 4))
        Questie:Debug(Questie.DEBUG_DEVELOP, "GetQuestObjectives: The quest doesn't exist in QuestLogCache.", questId)
        return {}
    end
    return cache[questId].objectives
end

---@param q table @quest
---@param i number @index of the objective
---@param o table @objective
local function DebugPrintObjective(q, i, o)
    if (o.raw_numFulfilled == o.numFulfilled) and (o.raw_finished == o.finished) then
        print(" ", i .. "/" .. table.getn(q.objectives) .. ":",
            o.numFulfilled .. "/" .. o.numRequired .. "=" .. tostring(o.finished),
            o.type,
            "\"" .. o.raw_text .. "\" \"" .. o.text .. "\"")
    else
        print(" ", i .. "/" .. table.getn(q.objectives) .. ":",
            o.raw_numFulfilled .. "/" .. o.numRequired .. "=" .. tostring(o.raw_finished),
            "FIX:", o.numFulfilled .. "/" .. o.numRequired .. "=" .. tostring(o.finished),
            o.type,
            "\"" .. o.raw_text .. "\" \"" .. o.text .. "\"")
    end
end

--- Debug function, prints whole cache
function QuestLogCache.DebugPrintCache()
    print("DebugPrintCache", GetTime())
    local count = 0
    local questId, q = next(cache)
    while questId do
        count = count + 1
        print("Quest: (" .. questId .. ") \"" .. q.title .. "\" questTag=" .. tostring(q.questTag),
            "isComplete=" .. tostring(q.isComplete))
        if not next(q.objectives) then
            print("  no objectives")
        else
            local i = 1
            while q.objectives[i] do
                DebugPrintObjective(q, i, q.objectives[i])
                i = i + 1
            end
        end
        questId, q = next(cache, questId)
    end
    print("Total Quests ", count)
end

--- Debug function, prints changes
function QuestLogCache.DebugPrintCacheChanges(cacheMiss, changes)
    local highlight = ((not cacheMiss) and (not next(changes))) or
        (cacheMiss and next(changes)) -- highlight untypical cases. they are okey, but sometimes interesting.
    print("DebugPrintCacheChanges", GetTime(), (highlight and "\124cffFF4444CacheMiss:\124r" or "CacheMiss"), cacheMiss)

    local questId, objIndexes = next(changes)
    while questId do
        local q = cache[questId]
        print("Quest: (" .. questId .. ") \"" .. q.title .. "\" questTag=" .. tostring(q.questTag),
            "isComplete=" .. tostring(q.isComplete))
        if not next(objIndexes) then
            print("  no objectives changed (or quest doesn't have objectives)")
        else
            local idx = 1
            while objIndexes[idx] do
                local i = objIndexes[idx]
                DebugPrintObjective(q, i, q.objectives[i])
                idx = idx + 1
            end
        end
        questId, objIndexes = next(changes, questId)
    end
end
