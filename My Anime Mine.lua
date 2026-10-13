-- PuckAFK My Anime Mine - COMPLETE SMART AUTOFARM - v2.5 (2026-10-13)
-- Executor compatibility: verified flat-file config backup, session fallback, JSON import/export
-- Standalone main script based on the supplied original source and game dump.
-- Integrated stock-aware smart pickaxe buying and equipped-miner optimization.
-- v2.1: immediate chest-to-seller cash-out when ore funds required research or a zone unlock.
-- v2.3: simple first-run PuckUI, default-on safe progression, quick presets, live status; advanced controls separated.
-- v2.4: protect strong/equipped miners while selling weak bag/chest spares; strict research -> zone -> optional spending.
-- Uses PuckUI via its canonical URL; never initiates Robux purchases.
-- Game-server interactions are subject to live-game availability and verification.

local SERVICE = function(name) return game:GetService(name) end
local Players = SERVICE("Players")
local RS = SERVICE("ReplicatedStorage")
local PathfindingService = SERVICE("PathfindingService")
local RunService = SERVICE("RunService")
local Workspace = SERVICE("Workspace")
local HttpService = SERVICE("HttpService")
local Player = Players.LocalPlayer

-- Cleanly retire an earlier execution without leaving parallel movement loops.
local env = getgenv and getgenv() or _G
if type(env.PuckAFK_MyAnimeMine) == "table" and type(env.PuckAFK_MyAnimeMine.Unload) == "function" then
    pcall(env.PuckAFK_MyAnimeMine.Unload)
    task.wait(0.15)
end

local Modules = RS:WaitForChild("Modules", 25)
if not Modules then error("[PuckAFK Mine] ReplicatedStorage.Modules is unavailable") end
local function requireModule(name)
    local object = Modules:WaitForChild(name, 12)
    if not object then error("[PuckAFK Mine] Missing module: " .. name) end
    return require(object)
end
local GameState = requireModule("GameState")
local MineConfig = requireModule("MineConfig")
local MineInventory = requireModule("MineInventory")
local SpinConfig = requireModule("MineDailySpinConfig")
local QuestConfig = requireModule("MineDailyQuestsCatalog")
local MineStock = requireModule("MineStock")
local Items = requireModule("Items")
local CraftingCatalog = requireModule("MineCraftingCatalog")
local SummonCatalog = requireModule("MineSummonCatalog")

local CFG_PATH = "PuckAFK/MyAnimeMine_v1.json"
local defaults = {
    Master = false,
    Mine = true,
    AutoChest = true,
    AutoSellOre = true,
    AutoSellMiners = true, -- sells genuinely weak unassigned MINERS; never haulers or valuable protected units
    MinerKeepBestSpare = 2, -- keep the two strongest unassigned miner stacks as backups
    MinerSellStrength = 0.85, -- only sell miners below 85% of the weakest equipped miner's base strength
    AutoCashoutProgression = true, -- auto collect chest ore and sell once it can fund next research/zone
    EquipBest = true,
    AutoSkills = true,
    AutoCompleteResearch = true,
    AutoTapUpgrades = true,
    AutoSlots = true,
    AutoCharacterLevels = true,
    AutoMinerMineSpeed = true, -- upgrade each selected miner's mining hit interval
    AntiAFK = true, -- passive idle prevention; independent of the farm switch
    AutoCrafting = false,
    AutoPickaxes = true,
    PickaxeMode = "Smart",
    PickaxeSpendPercent = 0.50,
    PickaxeReservePercent = 0.15,
    PickaxeMinTeamGain = 0.015,
    AutoEquipOwnedPickaxes = true,
    EnableOwnedAutoSell = true, -- only uses an already owned gamepass; never purchases one
    AutoFocusSpecial = false,
    AutoZone = true,
    AutoBuyZones = true,
    ZoneSaveForNext = true,
    ZoneSaveAt = 0.30,
    ZoneBuyMode = "Affordable",
    ZoneMaxRockSeconds = 60,
    AutoSpin = true,
    AutoQuests = true,
    AutoIndex = true, AutoMailbox = true, AutoBuffGift = true,
    AutoEventClaims = true, AutoTrialClaims = true,
    AutoTrialRuns = false, TrialMinPowerRatio = 1.5,
    AutoGear = true, AutoCrewSpeed = true,
    AutoPotions = true, PotionMode = "Balanced", PotionReserve = 2, -- uses only spare owned potions
    AutoEnchants = true,
    AutoPerformance = false,
    FocusSpecialRocks = true, WeatherAware = true,
    KeepSummonScrolls = 2,
    ColossusMaxSeconds = 45, UpgradeReserve = 0.18,
    AutoSummon = true, -- uses only spare scrolls after KeepSummonScrolls reserve
    NativeTravel = true,
    MineMode = "Balanced",
    BudgetPercent = 0.22,
    ChestPercent = 0.72,
    EfficientTrips = true,
    FastLocalMining = true,
    SmartUpgradeSavings = true,
    TapInterval = math.max(1.2, tonumber(MineConfig.MineHitInterval) or 1.2),
    MaxTapsPerRock = 34,
    MaxWalkRetries = 4,
    AutoJumpObstacles = true,
    CornerRecovery = true,
    MaxTargetTravel = 75,
    RockLocalityBoost = 1.60,
    MinSellValue = 1000,
    FasterScheduling = true,
    SmartResearchPriority = true,
    PowerGateRescue = true,
    PowerRescuePickaxes = true,
    PowerRescueLevels = true,
    PowerRescueMaxPurchase = 0.22,
    PowerRescueKeepCash = 0.40,
    CancelDeadRockWalk = true,
    AdaptiveRockChoice = true,
    ResearchCashBoost = true,
    PowerAwareResearch = true,
    AdaptiveNodeDensity = true,
    UrgentFullChest = true,
    AccurateMotherlode = true,
    StuckTimeout = 0.90,
    ZoneMode = "Highest unlocked",
    ChosenZone = 1,
}
local config = table.clone(defaults)
-- v2.5 executor-safe backup. PuckUI retains full named profile controls where
-- its filesystem APIs work; a flat, portable file covers partial file APIs.
-- Executors without persistent file APIs keep session settings only.
local COMPAT_PATH = "PuckAFK_MyAnimeMine_Config_v2.json"
local SESSION_KEY = "__PUCKAFK_MINE_CONFIG_SESSION_V2"
local compatStore = {
    read = type(readfile) == "function" and readfile or nil,
    write = type(writefile) == "function" and writefile or nil,
    lastError = nil, lastSaved = nil, lastAttempt = -100,
    loadedFrom = "defaults", lastWriteOK = false,
}
local numberLimits = {
    MinerKeepBestSpare = {0, 10}, MinerSellStrength = {0.10, 1},
    ZoneSaveAt = {0.10, 0.95}, TapInterval = {1.2, 3},
    StuckTimeout = {0.70, 2}, ChosenZone = {1, 12},
    MaxWalkRetries = {1, 5}, MaxTapsPerRock = {8, 100},
    MaxTargetTravel = {25, 140}, ColossusMaxSeconds = {15, 180},
    ZoneMaxRockSeconds = {15, 180}, MinSellValue = {0, 100000},
    ChestPercent = {0.20, 0.95}, BudgetPercent = {0.05, 0.80},
    UpgradeReserve = {0, 0.60}, RockLocalityBoost = {1, 2},
    PickaxeSpendPercent = {0.10, 0.90},
    PickaxeReservePercent = {0, 0.80},
    PickaxeMinTeamGain = {0, 0.20},
    PowerRescueMaxPurchase = {0.05, 0.45},
    PowerRescueKeepCash = {0.15, 0.80},
    PotionReserve = {0, 15}, KeepSummonScrolls = {0, 30},
    TrialMinPowerRatio = {1, 10},
}
local choices = {
    MineMode = {"Balanced", "Fast", "Value", "Rare loot"},
    PickaxeMode = {"Smart", "Conservative", "Aggressive"},
    ZoneBuyMode = {"Affordable", "Power ready"},
    ZoneMode = {"Highest unlocked", "Selected zone"},
    PotionMode = {"Balanced", "Cash", "Rare finds", "Power"},
}
local function validSetting(key, value)
    local default = defaults[key]
    if default == nil or key == "Master" or type(value) ~= type(default) then
        return false
    end
    if type(value) == "number" then
        if value ~= value or value == math.huge or value == -math.huge then return false end
        local range = numberLimits[key]
        return not range or (value >= range[1] and value <= range[2])
    end
    local allowed = choices[key]
    if allowed then return table.find(allowed, value) ~= nil end
    return true
end
local function importSettings(values)
    if type(values) ~= "table" then return false end
    local found = false
    for key in pairs(defaults) do
        local value = values[key]
        if validSetting(key, value) then
            config[key] = value
            found = true
        end
    end
    config.Master = false
    return found
end
local function snapshotSettings()
    local values = {}
    for key in pairs(defaults) do
        if key ~= "Master" and validSetting(key, config[key]) then
            values[key] = config[key]
        end
    end
    return values
end
local function readSettingsFile(path)
    if not compatStore.read then return nil end
    local ok, raw = pcall(compatStore.read, path)
    if not ok or type(raw) ~= "string" or raw == "" then return nil end
    local decoded, parsed = pcall(function()
        return HttpService:JSONDecode(raw)
    end)
    if not decoded or type(parsed) ~= "table" then return nil end
    return type(parsed.Values) == "table" and parsed.Values or parsed
end
local oldSettings = readSettingsFile(CFG_PATH)
if importSettings(oldSettings) then compatStore.loadedFrom = "legacy v1" end
local backedUp = readSettingsFile(COMPAT_PATH)
if not backedUp then backedUp = readSettingsFile(COMPAT_PATH .. ".bak") end
if importSettings(backedUp) then compatStore.loadedFrom = "portable disk backup" end
if type(env[SESSION_KEY]) == "table" and importSettings(env[SESSION_KEY]) then
    compatStore.loadedFrom = "executor session"
end
config.Master = false
local function settingsChanged(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return true end
    for key in pairs(defaults) do
        if key ~= "Master" and a[key] ~= b[key] then return true end
    end
    return false
end
local function saveCompatSettings(force)
    local values = snapshotSettings()
    -- Memory is available even when the executor cannot write a file.
    env[SESSION_KEY] = values
    if not force and not settingsChanged(values, compatStore.lastSaved) then
        return compatStore.lastWriteOK
    end
    compatStore.lastSaved = values
    compatStore.lastAttempt = os.clock()
    if not compatStore.write or not compatStore.read then
        compatStore.lastWriteOK = false
        compatStore.lastError = "No persistent readfile/writefile support (session only)"
        return false
    end
    local ok, encoded = pcall(function()
        return HttpService:JSONEncode({Version = 2, Values = values})
    end)
    if not ok or type(encoded) ~= "string" then
        compatStore.lastWriteOK = false
        compatStore.lastError = "JSON encoding failed"
        return false
    end
    -- Keep a known-good recovery copy before replacing the portable file.
    local oldOk, old = pcall(compatStore.read, COMPAT_PATH)
    if oldOk and type(old) == "string" and old ~= "" and old ~= encoded then
        pcall(compatStore.write, COMPAT_PATH .. ".bak", old)
    end
    local success, reason = pcall(compatStore.write, COMPAT_PATH, encoded)
    if success then
        local verify, actual = pcall(compatStore.read, COMPAT_PATH)
        success = verify and actual == encoded
        if not success then reason = "Write could not be read back" end
    end
    compatStore.lastWriteOK = success
    compatStore.lastError = success and nil or tostring(reason)
    return success
end
local function configSaveAllowed(window)
    local uiConfig = window and window.Config
    return not uiConfig or uiConfig.AutoSave ~= false
end

local state = {
    alive = true, walkEpoch = 0, walking = false,
    target = "None", plot = nil,
    oreSales = 0, rocksMined = 0, chests = 0, steps = 0,
    lastChest = -100, lastSell = -100, lastEquip = -100,
    cashoutStatus = "Waiting for sellable chest ore", cashoutGoal = "None",
    cashoutChestWorth = 0, cashoutInventoryWorth = 0,
    cashoutChestCollections = 0, cashoutSells = 0, lastCashoutAt = -100,
    minersSold = 0, minerSaleRevenue = 0, minerSellStatus = "Waiting for crew data",
    minerSellCandidates = 0, lastMinerSale = -100,
    lastSpend = -100, lastSpin = -100, lastSummon = -100,
    lastQuest = -100, lastZone = -100, lastPickaxe = -100,
    lastHome = -100, lastTravel = -100, lastScan = 0,
    lastSellAttempt = -100, lastChestAttempt = -100, lastCraft = -100,
    actionBlocks = {}, actionAttempts = {}, actionVerified = {},
    replanCount = 0, stuckCount = 0, failedRoutes = 0,
    quickBreaks = 0, avoidedSellTrips = 0, ownAutoSellEnabled = 0,
    crewFocusRequests = 0, crewFocusNode = nil, crewFocusAt = -100,
    ownedPickaxeEquips = 0, powerCache = nil, powerCacheAt = 0,
    recentRock = nil, recentRockAt = 0, lastOwnAutoSell = -100,
    lastPickaxeEquip = -100, lastActualSell = -100,
    pickaxeStatus = "Waiting for shop data", pickaxeBuys = 0,
    pickaxePending = {},
    lastFastClaim = -100, nativeAutoSellState = "Not enabled",
    jumpCount = 0, wallAvoids = 0, flankCount = 0,
    zoneBuys = 0, zoneGoal = "Scanning zones", zoneWait = "",
    researchCurrent = 0, researchTotal = 0, researchPercent = 100,
    researchZone = "Z1", researchNextCost = 0, researchNextName = "None",
    researchStatus = "Checking research", researchBuys = 0,
    researchBlocked = "", researchLast = -100, researchResolved = {},
    lastZoneBuy = -100,
    lastSuccess = "None", lastFailure = "None",
    lastAction = "None", weather = "Clear", event = "None", special = "None",
    advanced = "Initialising", indexClaims = 0, mailClaims = 0, eventClaims = 0,
    trialClaims = 0, gearEquips = 0, potionsUsed = 0, otherClaims = 0,
    currentRockScore = 0, observedDPS = 0, mineSample = nil,
    activeTrial = false, trialNext = 0, lastAdvanced = -100,
    lastSpeedUpgrade = -100, enchantEquips = 0, upgradeCursor = 0,
    minerStatUpgrades = {Damage = 0, Speed = 0, MineSpeed = 0},
    minerStatsLastToken = "", lastMinerStatCheck = -100,
    minerStatsStatus = "Checking assigned miners",
    antiAfkTriggers = 0, lastAntiAfk = -100, antiAfkStatus = "Disabled",
    cancelledDeadWalks = 0, cancelledMoveTo = 0,
    directStops = 0, timeMining = 0, timeWalking = 0,
    timeSelling = 0, startedAt = os.clock(), rocksAt = {},
    researchBudgetBypasses = 0, lastResearchAffordable = "None",
    researchPowerWait = "", researchPowerSkips = 0, urgentChests = 0,
    motherlodeEvaluations = 0,
    rescuePower = 0, rescueRequired = 0, rescueActive = false,
    rescueState = "Checking miner power", rescuePickaxeBuys = 0,
    rescueCharacterBuys = 0, rescueLastGain = 0,
    interactionCache = setmetatable({}, {__mode="k"}),
    routeVisibility = setmetatable({}, {__mode="k"}),

    blocked = setmetatable({}, {__mode = "k"}),
    failedPositions = {},
    nodeAttempts = setmetatable({}, {__mode = "k"}),
    connections = {},
}
local function getData()
    local ok, data = pcall(GameState.GetData2)
    return ok and type(data) == "table" and data or nil
end
local function getMine()
    local d = getData()
    return d, d and d.MineGame or nil
end
-- FireServer returns no success/failure response. Verification must observe a
-- changed replicated GameState, otherwise an ignored server action looks successful.
local function sendConfirmed(action, check, waitSec, ...)
    if not state.alive or not config.Master then return false end
    local args = table.pack(...)
    -- A failed purchase/claim should temporarily block THAT target, not the
    -- entire skill tree or all upgrades using the same event name.
    local scope = action
    if action == "MineBuySkill" then
        scope = action .. ":" .. tostring(args[1]) .. ":" .. tostring(args[2]) .. ":" .. tostring(args[3])
    elseif action == "MineBuyPickaxe" then
        scope = action .. ":" .. tostring(args[1])
    elseif action == "MineSelectZone" or action == "MineEquipPickaxe"
        or action == "MineUpgradeCharacter" or action == "MineAutoSellSet"
        or action == "MineEquipEnchant" then
        scope = action .. ":" .. tostring(args[1]) .. ":" .. tostring(args[2])
    end
    if (state.actionBlocks[action] or 0) > os.clock()
        or (state.actionBlocks[scope] or 0) > os.clock() then return false end
    local ok, err = pcall(function()
        GameState.SendEvent(action, table.unpack(args, 1, args.n))
    end)
    state.lastAction = action
    state.actionAttempts[action] = (state.actionAttempts[action] or 0) + 1
    if not ok then
        state.lastFailure = action .. " errored: " .. tostring(err)
        state.actionBlocks[action] = os.clock() + 15
        return false
    end
    if not check then return true end
    local started = os.clock()
    repeat
        task.wait(config.FasterScheduling and 0.10 or 0.18)
        local data, mg = getMine()
        local chkOk, changed = pcall(check, data, mg)
        if chkOk and changed then
            state.actionVerified[action] = (state.actionVerified[action] or 0) + 1
            state.lastSuccess = action .. " verified"
            return true
        end
    until not state.alive or os.clock() - started >= (waitSec or 2.4)
    state.lastFailure = action .. ": no server-state confirmation"
    -- A slow replication window is not proof the action was invalid. Cool
    -- down this target moderately while allowing unrelated actions to proceed.
    state.actionBlocks[scope] = os.clock() + 5

    return false
end
local function send(action, ...)
    if not state.alive then return false end
    local ok, why = pcall(GameState.SendEvent, action, ...)
    state.lastAction = tostring(action)
    state.actionAttempts[action] = (state.actionAttempts[action] or 0) + 1
    if not ok then
        state.lastFailure = "Action " .. action .. " error: " .. tostring(why)

    end
    return ok
end
local function moneyAvailable(data)
    return tonumber(data and data.Money) or 0
end
-- Find the NEXT real, consecutive zone. The dynamic MineConfig.ZoneKeys list is
-- the runtime gate: staged/unreleased modules alone never authorise purchases.
local function nextZoneFromSave(mg)
    if type(mg) ~= "table" then return nil end
    local owned = type(mg.UnlockedZones) == "table" and mg.UnlockedZones or {}
    local keys = MineConfig.ZoneKeys or {"Z1"}
    local contiguous = 1
    for index = 2, #keys do
        local previous = keys[index - 1]
        local key = keys[index]
        if owned[previous] ~= true and previous ~= "Z1" then return nil end
        if not (MineConfig.Zones and MineConfig.Zones[key]) then return nil end
        if owned[key] ~= true then
            local cost = tonumber(MineConfig.Zones[key].UnlockCost)
            if not cost or cost <= 0 or cost >= math.huge or cost ~= cost then return nil end
            if config.ZoneMode == "Selected zone" and index > config.ChosenZone then return nil end
            return key, cost, MineConfig.Zones[key], index
        end
        contiguous = index
    end
    return nil
end
-- Research % is the game's OWN progress calculation, not the percentage of
-- nodes purchased. Some staged nodes have CompletionPips overrides.
local function zoneResearchStatus(mg, nextKey)
    if not mg or not nextKey or not (MineConfig.Zones and MineConfig.Zones[nextKey]) then
        return nil, 0, 0, false
    end
    local gate = MineConfig.ZoneResearchGateFor(nextKey)
    if not gate or not (MineConfig.Zones and MineConfig.Zones[gate]) then
        return nil, 0, 0, true
    end
    local skills = type(mg.Skills) == "table" and mg.Skills or {}
    local ok, earned, required = pcall(MineConfig.GetZoneResearchProgress, skills, gate)
    if not ok then return gate, 0, 0, false end
    earned, required = tonumber(earned) or 0, tonumber(required) or 0
    local checkOk, completed = pcall(MineConfig.IsZoneResearchComplete, skills, gate)
    return gate, earned, required, checkOk and completed == true and earned >= required
end

-- Power gates are based on the *sum* of equipped miners' damage, including
-- their pickaxes, levels, variants and enchanter multipliers. This is the same
-- calculation used by the game's HUD for the research notification badge.
local function liveTeamPower(mg)
    if type(mg) ~= "table" then return 0 end
    local ok, actual = pcall(MineConfig.GetTeamPower, mg, Items.GetItemData)
    if ok and type(actual) == "number" and actual == actual then return math.max(0, actual) end
    return math.max(0, tonumber(Player:GetAttribute("MinePower")) or 0)
end

-- Mandatory research is fully funded BEFORE optional upgrades. When the next
-- gate is complete, save ALL money for the zone. The sole exception is a capped
-- team-power rescue when every reachable required research pip is power-locked.
local function affordable(data, cost, spendingKind)
    cost = tonumber(cost)
    if not cost or cost <= 0 or cost == math.huge or cost ~= cost then return false end
    local cash = moneyAvailable(data)
    if config.AutoCompleteResearch then
        local mg = data and data.MineGame
        local nextKey = nextZoneFromSave(mg)
        if nextKey then
            local _, _, _, ready = zoneResearchStatus(mg, nextKey)
            if not ready then
                if spendingKind == "TeamPower" and config.PowerGateRescue
                    and state.rescueActive then
                    local minKeep = math.clamp(config.PowerRescueKeepCash, 0, 0.90)
                    local maxSingle = math.clamp(config.PowerRescueMaxPurchase, 0.01, 0.80)
                    return cash >= cost and cost <= cash * maxSingle
                        and cash - cost >= cash * minKeep
                end
                return false -- even tiny nonessential purchases would delay research
            end
            if config.AutoBuyZones then
                return false -- buy the researched zone BEFORE optional upgrades
            end
        end
    end
    if config.AutoBuyZones and config.ZoneSaveForNext then
        local mg = data and data.MineGame
        local nextKey, zoneCost = nextZoneFromSave(mg)
        local _, _, _, researchReady = zoneResearchStatus(mg, nextKey)
        if nextKey and researchReady and zoneCost
            and cash >= zoneCost * math.clamp(config.ZoneSaveAt, 0.05, 0.95) then
            return false
        end
    end
    return cash >= cost and cost <= cash * math.clamp(config.BudgetPercent, 0.05, 0.95)
        and cash - cost >= cash * math.clamp(config.UpgradeReserve, 0, 0.85)
end
local function getRig()
    local char = Player.Character
    if not char then return end
    local hum = char:FindFirstChildOfClass("Humanoid")
    local root = char:FindFirstChild("HumanoidRootPart")
    if hum and root and hum.Health > 0 and root.Parent then return char, hum, root end
end
local function getPlot()
    local plots = Workspace:FindFirstChild("MineWorld")
    plots = plots and plots:FindFirstChild("Plots")
    if not plots then return nil end
    if state.plot and state.plot.Parent and state.plot:GetAttribute("OwnerUserId") == Player.UserId then
        return state.plot
    end
    for _, plot in ipairs(plots:GetChildren()) do
        if plot:GetAttribute("OwnerUserId") == Player.UserId then
            state.plot = plot
            return plot
        end
    end
end
local function positionOf(instance)
    if not instance then return end
    if instance:IsA("BasePart") then return instance.Position end
    if instance:IsA("Attachment") then return instance.WorldPosition end
    if instance:IsA("Model") then
        local pp = instance.PrimaryPart or instance:FindFirstChild("HumanoidRootPart", true)
            or instance:FindFirstChild("ChestBase", true)
            or instance:FindFirstChildWhichIsA("BasePart", true)
        return pp and pp.Position
    end
end
local function distance(a, b)
    return (a - b).Magnitude
end
local function travelValid(epoch)
    return state.alive and config.Master and config.Mine and epoch == state.walkEpoch
end
local function stopAtCurrentPosition(hum, root)
    if hum and root and root.Parent then
        hum:MoveTo(root.Position)

    end
end
local function cancelWalk()
    state.walkEpoch += 1
    local _, humanoid, root = getRig()
    stopAtCurrentPosition(humanoid, root)
    state.walking = false
end

-- Walking is *always* Humanoid:MoveTo. We take a visible direct route first;
-- navmesh is a fallback, not the primary route (navmesh on crowded mine plots
-- often returns hundreds of tiny waypoints around the decorative scenery).
-- Neither pathfinder nor recovery changes WalkSpeed or character CFrame.
local function planar(a, b)
    return (Vector3.new(a.X, 0, a.Z) - Vector3.new(b.X, 0, b.Z)).Magnitude
end
local function buildRayParams(ignore)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.IgnoreWater = true
    params.RespectCanCollide = true
    params.FilterDescendantsInstances = ignore or {}
    return params
end
-- A clear *character-width* corridor is more useful than a single centre ray:
-- a single ray sometimes threaded a fence while the player's shoulders hit it.
local function wallHit(from, direction, length, yOffset, ignored)
    local horizontal = Vector3.new(direction.X, 0, direction.Z)
    if horizontal.Magnitude < 0.001 then return nil end
    return Workspace:Raycast(from + Vector3.new(0, yOffset or 0, 0),
        horizontal.Unit * length, buildRayParams(ignored))
end
local function seeRoute(from, target, ignores)
    if math.abs(from.Y - target.Y) > 5.5 then return false end
    local delta = Vector3.new(target.X - from.X, 0, target.Z - from.Z)
    local length = delta.Magnitude
    if length < 1.8 then return true end
    local dir = delta.Unit
    local side = Vector3.new(-dir.Z, 0, dir.X)
    local params = buildRayParams(ignores)
    -- Test the lower body and the torso, and a modest width on both sides.
    -- RespectCanCollide avoids invisible non-colliding VFX.
    for _, lateral in ipairs({0, -1.10, 1.10}) do
        local offset = side * lateral
        for _, rise in ipairs({-1.35, 0.6}) do
            local hit = Workspace:Raycast(from + offset + Vector3.new(0,rise,0), delta, params)
            if hit and hit.Distance < length - 1.45 then return false end
        end
    end
    return true
end
local function groundedJump(hum)
    if not config.AutoJumpObstacles then return false end
    if hum.FloorMaterial == Enum.Material.Air or hum.Health <= 0 then return false end
    if hum:GetState() == Enum.HumanoidStateType.Seated then return false end
    hum.Jump = true -- ordinary character jump: no changing JumpPower or position

    return true
end
local function obstacleAhead(root, destination)
    local toward = Vector3.new(destination.X-root.Position.X,0,destination.Z-root.Position.Z)
    if toward.Magnitude < 0.5 then return nil, false end
    local length = math.min(4.5, toward.Magnitude)
    local ignore={Player.Character}
    local low=wallHit(root.Position,toward,length,-1.25,ignore)
    if not low then return nil, false end
    local high=wallHit(root.Position,toward,length,2.15,ignore)
    -- Short obstacle: low ray hits, head-level ray has clearance.
    -- Tall wall: both rays collide; jumping is pointless; reroute instead.
    local short = not high or high.Distance > low.Distance+1.4
    return low, short
end
local function moveSegment(dest, acceptable, epoch, budget, direct, early)
    local _, hum, root = getRig()
    if not root then return false, "no character" end
    if early and early() then
        stopAtCurrentPosition(hum, root)
        return true
    end
    if planar(root.Position, dest) <= acceptable and math.abs(root.Position.Y-dest.Y) < 6 then
        stopAtCurrentPosition(hum, root)
        return true
    end
    hum:MoveTo(dest)

    local started=os.clock()
    local lastProgress=started
    local nextProbe=started
    local lastJump=-100
    local oldDist=planar(root.Position,dest)
    local lastMoveTo=started
    local jumped=0
    while travelValid(epoch) and os.clock()-started<budget do
        local _, currentHum, currentRoot=getRig()
        if not currentRoot then return false,"respawn" end
        if early and early() then
            stopAtCurrentPosition(currentHum, currentRoot)
            return true
        end
        local curDist=planar(currentRoot.Position,dest)
        if curDist<=acceptable and math.abs(currentRoot.Position.Y-dest.Y)<=6 then
            stopAtCurrentPosition(currentHum, currentRoot)

            return true
        end
        local now=os.clock()
        if curDist+0.32<oldDist then
            oldDist=curDist
            lastProgress=now
        end
        if now>=nextProbe then
            nextProbe=now+0.24
            local wall, isShort=obstacleAhead(currentRoot,dest)
            if wall then
                if isShort and now-lastJump>0.85 and jumped<2 and groundedJump(currentHum) then
                    jumped+=1
                    lastJump=now
                    lastProgress=now
                    currentHum:MoveTo(dest)
                    lastMoveTo=now
                elseif not isShort and curDist>acceptable+1 then

                    return false,"wall"
                end
            end
        end
        local stalled=now-lastProgress
        if stalled>math.max(0.55,config.StuckTimeout) then
            if now-lastJump>0.9 and jumped<2 and groundedJump(currentHum) then
                jumped+=1
                lastJump=now
                lastProgress=now
                currentHum:MoveTo(dest)
                lastMoveTo=now
            elseif currentHum.FloorMaterial ~= Enum.Material.Air and stalled>math.max(0.65,config.StuckTimeout)+0.35 then

                return false,"stuck"
            end
        end
        if direct and curDist>7 and now-started>0.9
            and not seeRoute(currentRoot.Position,dest,{Player.Character}) then
            return false,"corridor blocked"
        end
        if now-lastMoveTo>1.6 and now-lastProgress<0.7 then
            currentHum:MoveTo(dest)
            lastMoveTo=now
        end
        task.wait(0.08)
    end
    return false,"timeout"
end
local function groundPosition(around, ignore)
    local hit=Workspace:Raycast(around+Vector3.new(0,14,0),Vector3.new(0,-32,0),buildRayParams(ignore))
    if not hit or hit.Normal.Y<0.76 then return nil end
    return hit.Position+Vector3.new(0,2.5,0)
end
-- If a wall defeats the navmesh, walk along its side to a safe flank rather
-- than jumping indefinitely against its face or oscillating between corners.
local function flankWall(goal, epoch, attempt, seen)
    local _,hum,root=getRig()
    if not root then return false end
    local delta=Vector3.new(goal.X-root.Position.X,0,goal.Z-root.Position.Z)
    if delta.Magnitude<1 then return false end
    local dir=delta.Unit
    local side=Vector3.new(-dir.Z,0,dir.X)
    local wall=wallHit(root.Position,dir,6,-1.25,{Player.Character})
    local offsets={}
    if wall then
        local normal=Vector3.new(wall.Normal.X,0,wall.Normal.Z)
        if normal.Magnitude>0.15 then
            local tangent=Vector3.new(-normal.Z,0,normal.X).Unit
            offsets={tangent,-tangent,side,-side,-dir}
        end
    end
    if #offsets==0 then offsets={side,-side,-dir} end
    local ignore={Player.Character}
    local plot=getPlot()
    if plot then
        local nodes=plot:FindFirstChild("Nodes")
        if nodes then table.insert(ignore,nodes) end
        local crew=plot:FindFirstChild("Crew")
        if crew then table.insert(ignore,crew) end
    end
    local choices={}
    for i,vector in ipairs(offsets) do
        for _,stride in ipairs({5,8,11}) do
            local candidate=groundPosition(root.Position+vector*stride+dir*2.5,ignore)
            if candidate and math.abs(candidate.Y-root.Position.Y)<5
                and seeRoute(root.Position,candidate,{Player.Character}) then
                local key=math.floor(candidate.X/3)..":"..math.floor(candidate.Z/3)
                if not (seen[key] and seen[key]>os.clock()) then
                    local away=planar(candidate,goal)
                    local score=away+stride*0.35+(i>2 and 2 or 0)
                    table.insert(choices,{pos=candidate,key=key,score=score})
                end
            end
        end
    end
    table.sort(choices,function(a,b) return a.score<b.score end)
    for index=1,math.min(3,#choices) do
        if not travelValid(epoch) then return false end
        local choice=choices[index]
        seen[choice.key]=os.clock()+18
        local _,h,r=getRig()
        if not r then return false end
        -- Jump as we start flanking only when an actual short obstacle exists.
        local _,small=obstacleAhead(r,choice.pos)
        if small then groundedJump(h) end
        local ok=moveSegment(choice.pos,2.5,epoch,
            math.min(3.5,math.max(1.5,planar(r.Position,choice.pos)/math.max(8,h.WalkSpeed)*1.8)),true)
        if ok then return true end
    end
    return false
end
local function smartWalk(goal,goalRadius,epoch,title,early)
    if typeof(goal)~="Vector3" or not travelValid(epoch) then return false end
    goalRadius=goalRadius or 3
    local _,hum,root=getRig()
    if not root then return false end
    if early and early() then stopAtCurrentPosition(hum, root); return true end
    if planar(root.Position,goal)<goalRadius and math.abs(root.Position.Y-goal.Y)<5 then
        stopAtCurrentPosition(hum, root)
        return true
    end
    local speed=math.max(8,hum.WalkSpeed)
    local dist=planar(root.Position,goal)
    local deadline=os.clock()+math.clamp(dist/speed*1.65+2.5,4.5,16.0)
    state.walking=true
    local function finishTravel(ok)

        state.walking = false
        -- Failed moves must also be stopped: otherwise the old MoveTo keeps
        -- steering into the wall while Pathfinder computes a new route.
        local _, h, r = getRig()
        stopAtCurrentPosition(h, r)
        return ok
    end
    local seen={}
    if seeRoute(root.Position,goal,{Player.Character}) then
        local ok=moveSegment(goal,goalRadius,epoch,math.min(10,math.max(1.8,dist/speed*1.6+1.15)),true,early)
        if ok then return finishTravel(true) end
        -- Release a blocked direct MoveTo before computing a navigation path.
        local _, blockedHum, blockedRoot = getRig()
        stopAtCurrentPosition(blockedHum, blockedRoot)
    end
    for attempt=1,math.clamp(config.MaxWalkRetries,1,5) do
        if not travelValid(epoch) or os.clock()>deadline then break end
        local _,h,r=getRig()
        if not r then break end
        if early and early() then return finishTravel(true) end
        if planar(r.Position,goal)<=goalRadius and math.abs(r.Position.Y-goal.Y)<5 then
            return finishTravel(true)
        end
        local path=PathfindingService:CreatePath({
            AgentRadius=2.15,AgentHeight=5.5,AgentCanJump=true,
            AgentCanClimb=false,WaypointSpacing=5,
        })
        local computed=pcall(function() path:ComputeAsync(r.Position,goal) end)

        local points=computed and path.Status==Enum.PathStatus.Success and path:GetWaypoints() or nil
        if points and #points>1 then
            local blockedIndex=math.huge
            local conn=path.Blocked:Connect(function(i) blockedIndex=math.min(blockedIndex,i) end)
            local index=2
            while index<=#points and travelValid(epoch) and os.clock()<deadline do
                local _,hh,rr=getRig()
                if not rr then break end
                if early and early() then
                    hh:MoveTo(rr.Position)
                    conn:Disconnect();return finishTravel(true)
                end
                if planar(rr.Position,goal)<=goalRadius and math.abs(rr.Position.Y-goal.Y)<5 then
                    conn:Disconnect();return finishTravel(true)
                end
                if index>=blockedIndex then break end
                -- Safe shortcut across visible waypoints (never skip a jump point).
                if points[index].Action~=Enum.PathWaypointAction.Jump then
                    for j=math.min(#points,index+4),index+1,-1 do
                        local wouldSkipJump=false
                        for k=index,j do
                            if points[k].Action==Enum.PathWaypointAction.Jump then wouldSkipJump=true;break end
                        end
                        if not wouldSkipJump and seeRoute(rr.Position,points[j].Position,{Player.Character}) then
                            index=j;break
                        end
                    end
                end
                local point=points[index]
                if point.Action==Enum.PathWaypointAction.Jump then groundedJump(hh) end
                local leg=planar(rr.Position,point.Position)
                local ok=moveSegment(point.Position,index==#points and goalRadius or 2.5,
                    epoch,math.min(5,math.max(1.3,leg/speed*1.65+0.65)),false,early)
                if not ok then
                    local _, blockedHum, blockedRoot = getRig()
                    stopAtCurrentPosition(blockedHum, blockedRoot)
                    break
                end
                index+=1
            end
            conn:Disconnect()
        end
        local _,_,after=getRig()
        if after and planar(after.Position,goal)<=goalRadius and math.abs(after.Position.Y-goal.Y)<5 then
            return finishTravel(true)
        end
        if config.CornerRecovery and travelValid(epoch) and os.clock()<deadline then
            -- Do not camp on an impassable wall if Pathfinder cannot get around it.
            flankWall(goal,epoch,attempt,seen)
        end
    end

    return finishTravel(false)
end

-- Choose actual floor beside a node, never the node itself. The old raycast
-- hit the rock's top and ordered the character to climb an inaccessible point.
local function standAround(position, reach, epoch, label, targetNode)
    local _, _, root = getRig()
    if not root then return false end
    if targetNode and config.CancelDeadRockWalk and targetNode.Name:match("^Node%d+$")
        and (not targetNode.Parent or targetNode:GetAttribute("NodeBroken") == true
            or (tonumber(targetNode:GetAttribute("NodeHP")) or 0) <= 0) then return false end
    reach = math.clamp(tonumber(reach) or 10, 3, 32)
    if (root.Position - position).Magnitude <= reach - 1.0 then return true end
    local ignore = {Player.Character}
    if targetNode then table.insert(ignore, targetNode) end
    local plot = getPlot()
    if plot then
        local nodes = plot:FindFirstChild("Nodes")
        if nodes then table.insert(ignore, nodes) end
        local crew = plot:FindFirstChild("Crew")
        if crew then table.insert(ignore, crew) end
    end
    -- First attempt the floor on the player's near side. This usually removes
    -- a 24-position scan and the pathfinder invocation entirely. If scenery
    -- blocks it, retain the complete multi-angle recovery used by v1.4.0.
    local horizontal=Vector3.new(root.Position.X-position.X,0,root.Position.Z-position.Z)
    if horizontal.Magnitude > 1.5 then
        local nearRaw=position+horizontal.Unit*math.min(reach-2.0,5.5)
        local near=groundPosition(nearRaw,ignore)
        if near and math.abs(near.Y-root.Position.Y)<8
            and (near-position).Magnitude<=reach-0.7
            and seeRoute(root.Position,near,{Player.Character}) then
            local function done()
                local _,_,r=getRig()
                if targetNode and config.CancelDeadRockWalk and targetNode.Name:match("^Node%d+$")
                    and (not targetNode.Parent or targetNode:GetAttribute("NodeBroken") == true
                        or (tonumber(targetNode:GetAttribute("NodeHP")) or 0) <= 0) then return true end
                return r and (r.Position-position).Magnitude<=reach-0.8
            end
            if smartWalk(near,3.2,epoch,label,done) then
                local _,_,r=getRig()
                if r and (r.Position-position).Magnitude<=reach-0.8 then return true end
                if targetNode and targetNode.Name:match("^Node%d+$") then

                    return false
                end
            end
        end
    end
    local candidateList = {}
    local approaches = {math.min(reach - 2, 5.5), math.min(reach - 1.2, 7.5)}
    local previousFail = state.failedPositions
    for ring = 1, #approaches do
        for index = 1, 12 do
            local a = 2 * math.pi * (index - 1) / 12
            local dir = Vector3.new(math.cos(a), 0, math.sin(a))
            local raw = position + dir * approaches[ring]
            local ground = groundPosition(raw, ignore)
            if ground and math.abs(ground.Y - root.Position.Y) <= 9
                and (ground - position).Magnitude <= reach - 0.5 then
                local d = planar(root.Position, ground)
                local clear = seeRoute(root.Position, ground, {Player.Character})
                local key = math.floor(ground.X/3) .. ":" .. math.floor(ground.Z/3)
                local penalty = previousFail[key] and previousFail[key] > os.clock() and 120 or 0
                table.insert(candidateList, {pos=ground, key=key,
                    score=d + (clear and 0 or 13) + penalty + (ring-1)*1.2})
            end
        end
    end
    table.sort(candidateList, function(a,b) return a.score < b.score end)
    local function inInteractionReach()
        if targetNode and config.CancelDeadRockWalk and targetNode.Name:match("^Node%d+$")
            and (not targetNode.Parent or targetNode:GetAttribute("NodeBroken") == true
                or (tonumber(targetNode:GetAttribute("NodeHP")) or 0) <= 0) then return true end
        local _, _, currentRoot=getRig()
        return currentRoot and (currentRoot.Position-position).Magnitude <= reach-0.8
    end
    for i=1,math.min(3,#candidateList) do
        local candidate = candidateList[i]
        if targetNode and targetNode.Name:match("^Node%d+$") and config.CancelDeadRockWalk
            and (not targetNode.Parent or targetNode:GetAttribute("NodeBroken") == true
                or (tonumber(targetNode:GetAttribute("NodeHP")) or 0) <= 0) then

            return false
        end
        if smartWalk(candidate.pos, 3.2, epoch, label, inInteractionReach) then
            local _,_,r = getRig()
            if r and (r.Position-position).Magnitude <= reach-0.3 then return true end
        end
        previousFail[candidate.key] = os.clock() + 22
    end
    return false
end

local function findChest(plot)
    local chest = plot and plot:FindFirstChild("Chest")
    if chest then
        return chest:FindFirstChild("ChestBase") or chest.PrimaryPart or chest:FindFirstChildWhichIsA("BasePart", true)
    end
end
local function findSeller()
    local sell = Workspace:FindFirstChild("SellStand")
    if not sell then return nil end
    return sell:FindFirstChild("legendsmnd", true) or sell
end
local function teleportGame(destination, epoch)
    if not config.NativeTravel or not travelValid(epoch) then return false end
    local _, _, root = getRig()
    if not root then return false end
    local plot = getPlot()
    local arrival
    if destination == "Plot" then
        arrival = plot and positionOf(plot:FindFirstChild("PlotSpawn"))
    elseif destination == "Hub" then
        local mineWorld = Workspace:FindFirstChild("MineWorld")
        local hub = mineWorld and mineWorld:FindFirstChild("Hub")
        arrival = hub and positionOf(hub:FindFirstChild("MineSpawn"))
        if not arrival then arrival = positionOf(findSeller()) end
    end
    if arrival and planar(root.Position, arrival) <= 55 then return true end
    if not send("MineTeleport", destination) then return false end
    local start = os.clock()
    local origin = root.Position
    while os.clock() - start < 3.0 and travelValid(epoch) do
        local _, _, r = getRig()
        if r and ((arrival and distance(r.Position, arrival) < 70)
            or (not arrival and distance(r.Position, origin) > 60)) then
            stopAtCurrentPosition(select(2, getRig()), r)
            return true
        end
        task.wait(0.12)
    end
    -- The home/seller location may be streaming out; allow walking as a fallback.
    return false
end
local function getNodePart(node)
    if not node or not node:IsA("Model") then return nil end
    return node.PrimaryPart or node:FindFirstChild("Rock") or node:FindFirstChildWhichIsA("BasePart", true)
end
local function getDetector(node)
    return node:FindFirstChild("NodeClick") or (getNodePart(node) and getNodePart(node):FindFirstChild("NodeClick"))
        or node:FindFirstChild("NodeClick", true)
end
local function isLiveNode(node)
    return node:IsA("Model") and node.Parent and node:GetAttribute("NodeBroken") ~= true
        and (tonumber(node:GetAttribute("NodeHP")) or 0) > 0
        and getNodePart(node) ~= nil and getDetector(node) ~= nil
        and (state.blocked[node] == nil or os.clock() > state.blocked[node])
end
local function tapsDamage(mg)
    local level = tonumber(mg and mg.TapLevel) or 1
    local ok, d = pcall(MineConfig.GetTapDamage, level)
    return ok and math.max(1, tonumber(d) or 1) or 1
end
-- Estimate physical manual taps PLUS observed server HP decay due to miners.
-- The learned component is deliberately capped: stale observations of a buffed rock
-- must never convince the planner to commit to a Colossus it cannot finish.
local function estimatedRockDPS(mg)
    local now = os.clock()
    if state.powerCache and now - state.powerCacheAt < 0.55 then
        return state.powerCache
    end
    local interval = math.max(1.2, tonumber(MineConfig.MineHitInterval) or 1.2, config.TapInterval)
    local personal = tapsDamage(mg) / interval
    local crew = 0
    local ok, estimatedPower = pcall(MineConfig.GetTeamPower, mg, Items.GetItemData)
    if ok then crew = math.max(0, tonumber(estimatedPower) or 0) end
    -- Crew miners hit distinct rocks, so conservatively divide the total by
    -- a live node-count estimate and apply a reaction/efficiency allowance.
    local nodes = state.plot and state.plot:FindFirstChild("Nodes")
    local nodeCount = nodes and math.max(1, #nodes:GetChildren()) or 4
    local perRock = math.min(crew / (interval * math.clamp(nodeCount, 2, 10)) * 0.4, crew)
    local observed = math.max(0, tonumber(state.observedDPS) or 0)
    local result = personal + math.max(perRock, observed * 0.65)
    state.powerCache, state.powerCacheAt = result, now
    return result
end
local function rockCandidateScore(node, part, mg, origin)
    if not isLiveNode(node) then return nil end
    local hp = tonumber(node:GetAttribute("NodeHP")) or math.huge
    local maxHp = tonumber(node:GetAttribute("NodeMaxHP")) or hp
    local tier = MineConfig.GetNodeTier(node:GetAttribute("NodeTier"))
    if type(tier) ~= "table" then return nil end
    local detector = getDetector(node)
    local radius = detector and tonumber(detector.MaxActivationDistance) or 0
    local dist = planar(origin, part.Position)
    local approxDPS = math.max(1, estimatedRockDPS(mg))
    local taps = math.ceil(hp / math.max(1, tapsDamage(mg)))
    local expectedTime = hp / approxDPS
    local big = node:GetAttribute("BigNode") == true or node:GetAttribute("Colossus") == true
        or tostring(node:GetAttribute("NodeTier")):lower():find("big") ~= nil
    local mother = node:GetAttribute("Motherlode") == true
    if dist >= math.max(28, config.MaxTargetTravel) or radius < 4 then return nil end
    if (expectedTime > 70 and not big) or (big and expectedTime > config.ColossusMaxSeconds) then return nil end
    if taps > config.MaxTapsPerRock * 2 and expectedTime > 28 then return nil end
    local reward = math.max(1, tonumber(tier.LootMult) or 1)
    local luck = math.max(1, (tonumber(tier.CharLuck) or 1) + (tonumber(tier.OreLuck) or 1))
    if mother and config.FocusSpecialRocks then
        -- MineConfig has NO MotherlodeRewardMult field. Read the same
        -- research-adjusted action stats that drive the live Motherlode.
        local currentZone = tostring((mg and mg.CurrentZone) or "Z1")
        if not currentZone:match("^Z") then currentZone = "Z" .. currentZone end
        local lode = nil
        if config.AccurateMotherlode and type(MineConfig.GetMotherlode) == "function" then
            local ok, stats = pcall(MineConfig.GetMotherlode, (mg and mg.Skills) or {}, currentZone)
            if ok and type(stats) == "table" then lode = stats end
        end
        if not lode then lode = type(MineConfig.Motherlode) == "table" and MineConfig.Motherlode.Base or nil end
        reward *= math.max(1, tonumber(lode and lode.OreMult) or 20)
        luck *= math.max(1, tonumber(lode and lode.Luck) or 2)

    end
    local _,hum = getRig()
    local travel = math.max(0, dist - radius + 1.1) / math.max(8, hum and hum.WalkSpeed or 16)
    local time = expectedTime + travel + 1.5
    local score = reward ^ 0.48 * math.sqrt(luck) / math.max(0.7, time)
    if config.MineMode == "Fast" then score = 15 / (time + expectedTime * 0.75)
    elseif config.MineMode == "Value" then score = reward ^ 0.61 / time
    elseif config.MineMode == "Rare loot" then score = reward ^ 0.4 * luck / time end
    if config.ResearchCashBoost and config.AutoCompleteResearch
        and state.researchTotal > state.researchCurrent and state.researchNextCost > 0 then
        -- Progression is currently cash-gated: ore yield matters more than
        -- speculative character luck. Do not override special rewards.
        score *= 1 + 0.13 * math.clamp(math.log10(reward + 1), 0, 5)
    end
    if mother and config.FocusSpecialRocks then score *= 2.4 end
    if big then score *= 0.65 end
    if config.FastLocalMining then
        -- Staying inside click range saves a full navigation/replan cycle.
        if dist <= radius - 0.8 then
            score *= math.max(1, config.RockLocalityBoost)
            if config.AdaptiveRockChoice then score *= 1.35 end
        elseif config.AdaptiveRockChoice and dist > radius + 2.0 then
            -- Cache the expensive six-ray corridor test briefly. Recheck when
            -- the character moves a meaningful distance or the rock moves.
            local cache = state.routeVisibility[node]
            local now = os.clock()
            local clear
            if cache and cache.expires > now and planar(cache.origin,origin) < 5
                and (cache.destination - part.Position).Magnitude < 2 then
                clear = cache.clear
            else
                clear = seeRoute(origin, part.Position, {Player.Character})
                state.routeVisibility[node] = {origin=origin, destination=part.Position,
                    expires=now+1.2, clear=clear}
            end
            if not clear then score *= 0.61 end
        end
        -- Crew may finish a node during long movement, favour reachable ones.
        if dist > 32 and expectedTime < 2.5 then score *= 0.78 end
        if state.recentRock and os.clock() - state.recentRockAt < 8 then
            local prev = getNodePart(state.recentRock)
            if prev and planar(prev.Position,part.Position) < 12 then score *= 1.08 end
        end
    end
    if config.WeatherAware then
        local weather = string.lower(state.weather or "")
        if weather:find("aurora") or weather:find("blizzard") or weather:find("rain") then
            -- Ore-boost weather makes richer rocks relatively more useful.
            score *= 1 + 0.12 * math.clamp(math.log10(reward + 1), 0, 6)
        elseif weather:find("ghost") or weather:find("starry") then
            -- Character-find weather rewards a larger count of quick clears.
            score *= 1 + 0.3 / math.sqrt(math.max(1, time))
        elseif weather:find("eclipse") then
            score *= 1 + 0.2 / math.sqrt(math.max(1, time))
        end
    end
    return score, {hp = hp, maxHp = maxHp, big = big, mother = mother, time = time}
end
local function selectNode(plot, mg)
    local nodes = plot and plot:FindFirstChild("Nodes")
    local _, _, root = getRig()
    if not nodes or not root then return nil end
    local best, bestScore, bestInfo
    for _, node in ipairs(nodes:GetChildren()) do
        if isLiveNode(node) then
            local part = getNodePart(node)
            local score, info = rockCandidateScore(node, part, mg, root.Position)
            if score and (not bestScore or score > bestScore) then
                best, bestScore, bestInfo = node, score, info
            end
        end
    end
    state.currentRockScore = bestScore or 0
    state.special = bestInfo and (bestInfo.mother and "Motherlode" or bestInfo.big and "Colossus" or "Ordinary") or "None"
    return best
end

-- Use the node's ordinary ClickDetector. No hit/damage remote manipulation.
local vim
local function clickNode(detector, part)
    if type(fireclickdetector) == "function" then
        return pcall(fireclickdetector, detector)
    end
    if not vim then pcall(function() vim = SERVICE("VirtualInputManager") end) end
    if vim then
        local camera = Workspace.CurrentCamera
        local pos, onScreen = camera:WorldToViewportPoint(part.Position)
        if onScreen and pos.Z > 0 then
            local ok = pcall(function()
                vim:SendMouseButtonEvent(pos.X, pos.Y, 0, true, game, 0)
                task.wait(0.05)
                vim:SendMouseButtonEvent(pos.X, pos.Y, 0, false, game, 0)
            end)
            return ok
        end
    end
    return false
end
-- "Send characters to rocks" from the actual game UI: a list of occupied
-- miner pad keys and the numeric node index. Only uses the in-game action.
local function specialCrewFocus(node, mg)
    if not config.AutoFocusSpecial or not mg then return false end
    local isSpecial = node:GetAttribute("Motherlode") == true
        or node:GetAttribute("BigNode") == true or node:GetAttribute("Colossus") == true
    if not isSpecial then return false end
    local nodeIndex=tonumber(node.Name:match("^Node(%d+)$"))
    if not nodeIndex then return false end
    if state.crewFocusNode == node and os.clock()-state.crewFocusAt < 22 then
        return false
    end
    if os.clock()-state.crewFocusAt < 10 then return false end
    local keys = {}
    for key, holder in pairs(mg.Holders or {}) do
        if type(key)=="string" and key:sub(1,1)=="M"
            and type(holder)=="table" and type(holder.CharName)=="string" then
            local unit=Items.GetItemData(holder.CharName)
            if unit and unit.MineRole~="Hauler" then table.insert(keys,key) end
        end
    end
    if #keys < 2 then return false end
    table.sort(keys)
    state.crewFocusAt, state.crewFocusNode = os.clock(), node
    if send("MineFocusMany",keys,nodeIndex) then

        state.lastAction="Requested crew focus for special rock"
        return true
    end
    return false
end

local function mineNode(node, epoch)
    local part = getNodePart(node)
    local click = getDetector(node)
    if not part or not click or not isLiveNode(node) then return false end
    local radius = tonumber(click.MaxActivationDistance) or 7
    if radius < 4 then state.blocked[node] = os.clock() + 20; return false end
    state.target = node.Name .. " / " .. tostring(node:GetAttribute("NodeTier"))
    -- Crew start walking while the player starts walking: tasks overlap.
    if config.AutoFocusSpecial then specialCrewFocus(node, select(2, getMine())) end

    if not standAround(part.Position, radius, epoch, "Rock", node) then
        if config.CancelDeadRockWalk and (not node.Parent or node:GetAttribute("NodeBroken") == true
            or (tonumber(node:GetAttribute("NodeHP")) or 0) <= 0) then

            return false
        end
        state.blocked[node] = os.clock() + 22
        state.lastFailure = "Unreachable node: " .. state.target
        return false
    end
    local oldHp = tonumber(node:GetAttribute("NodeHP")) or 0
    if oldHp <= 0 or node:GetAttribute("NodeBroken") then return false end
    local noDamage, hits = 0, 0
    local started = os.clock()
    local interval = math.max(tonumber(MineConfig.MineHitInterval) or 1.2, config.TapInterval)
    while travelValid(epoch) and isLiveNode(node) and hits < config.MaxTapsPerRock do
        local _, _, root = getRig()
        if not root or not part.Parent then break end
        if (root.Position - part.Position).Magnitude > radius + 0.7 then break end

        if not clickNode(click, part) then
            state.lastFailure = "No usable ClickDetector input"

            state.blocked[node] = os.clock() + 45
            return false
        end
        hits += 1
        local t0 = os.clock()
        local hp = oldHp
        -- Watch replicated rock state while the next legitimate hit is cooling
        -- down. A crew member can finish the rock during this interval: move
        -- to the next target instantly rather than idling the full 1.2 sec.
        while travelValid(epoch) and os.clock() - t0 < interval do
            task.wait(0.065)
            if not node.Parent or node:GetAttribute("NodeBroken") == true then

                state.lastSuccess = "Mined " .. state.target
                state.blocked[node] = os.clock() + (tonumber(MineConfig.NodeRespawnSeconds) or 3.5)
                state.recentRock, state.recentRockAt = node, os.clock()
                return true
            end
            hp = tonumber(node:GetAttribute("NodeHP")) or 0
            if hp <= 0 then

                state.lastSuccess = "Mined " .. state.target
                state.blocked[node] = os.clock() + (tonumber(MineConfig.NodeRespawnSeconds) or 3.5)
                state.recentRock, state.recentRockAt = node, os.clock()
                return true
            end
        end
        hp = tonumber(node:GetAttribute("NodeHP")) or 0
        if hp <= 0 or node:GetAttribute("NodeBroken") then

            state.lastSuccess = "Mined " .. state.target
            state.blocked[node] = os.clock() + (tonumber(MineConfig.NodeRespawnSeconds) or 3.5)
            state.recentRock, state.recentRockAt = node, os.clock()
            return true
        end
        if hp < oldHp then
            local damage = oldHp - hp
            local approximateTap = tapsDamage(select(2, getMine()))
            local extraDPS = math.max(0, damage - approximateTap) / math.max(1.2, interval)
            if extraDPS > 0 then
                state.observedDPS = math.max(0, (state.observedDPS or 0) * 0.85 + extraDPS * 0.15)
            end
            noDamage = 0
            oldHp = hp
        else
            noDamage += 1
        end
        if noDamage >= 3 or os.clock() - started > 70 then break end
    end

    state.lastFailure = (noDamage >= 3 and "No verified rock damage: " or "Mining interrupted: ") .. state.target
    state.blocked[node] = os.clock() + (noDamage >= 3 and 50 or 16)
    return false
end

local function getChestEntries(mg)
    local ok, items = pcall(MineInventory.ChestEntries, mg)
    return ok and type(items) == "table" and items or {}
end
local function totalChestCount(entries)
    local count = 0
    for _, e in ipairs(entries) do count += tonumber(e.Count) or 0 end
    return count
end
local function collectChest(plot, mg, epoch, force, progressionUrgent)
    if not config.AutoChest then return false end
    local full = config.UrgentFullChest and plot and plot:GetAttribute("MineChestFull") == true
    -- A full chest can stall the crew; prefer a prompt retry, but never
    -- hammer a failing collection action every scheduler tick.
    local minimumInterval = progressionUrgent and 2.5 or (full and 5 or 16)
    if os.clock()-state.lastChestAttempt < minimumInterval then return false end
    local entries = getChestEntries(mg)
    local amount = totalChestCount(entries)
    if amount == 0 then return false end
    local capacity = tonumber(MineConfig.GetChestCapacityFor(mg, 0)) or 0
    if not force and not full and capacity > 0 and amount < capacity * config.ChestPercent
        and os.clock() - state.lastChest < 115 then return false end
    local chestBase = findChest(plot)
    if not chestBase then state.lastFailure = "Chest not streamed"; return false end
    state.lastChestAttempt = os.clock()

    local cp = chestBase:FindFirstChild("ChestPrompt")
    local reach = cp and math.min(8.0, math.max(5, cp.MaxActivationDistance)) or 8
    if not standAround(chestBase.Position, reach, epoch, "Chest", chestBase.Parent) then return false end
    local beforeChest = table.clone(mg.Chest or {})
    local beforeBagOres = table.clone(mg.Ores or {})
    local ok = sendConfirmed("MineTakeChest", function(_, fresh)
        if not fresh then return false end
        if totalChestCount(getChestEntries(fresh)) < amount then return true end
        -- New ore can enter the chest WHILE it is being collected. Confirm a
        -- reduction in any existing stack, or an increased carried-ore stack,
        -- even if the total chest count rose during the transfer.
        for key, initial in pairs(beforeChest) do
            if (tonumber((fresh.Chest or {})[key]) or 0) < (tonumber(initial) or 0)
                or (tonumber((fresh.Ores or {})[key]) or 0) > (tonumber(beforeBagOres[key]) or 0) then
                return true
            end
        end
        return false
    end, 3.2)
    if ok then

        state.lastChest = os.clock()

    end
    return ok
end
local function sellableOre(mg)
    local ok, items = pcall(MineInventory.Collect, mg, "Ores", MineInventory.KindOrder.OreFirst)
    if not ok or type(items) ~= "table" then return {}, 0 end
    local keys, worth = {}, 0
    for _, item in ipairs(items) do
        if item.Kind == "Ore" and (tonumber(item.Count) or 0) > 0
            and (tonumber(item.Worth) or 0) > 0 then
            table.insert(keys, item.Key)
            worth += tonumber(item.Worth) or 0
        end
    end
    return keys, worth
end
-- The seller accepts stack keys for BOTH ores and miners via MineSellItems.
-- Unlike blindly selling every Character key, this plan protects assigned crew,
-- all haulers, special unsellable rarities, and the best unassigned backups.
-- It also examines chest loot so research cashouts can use safe miner sale value.
local function minerSalePlan(mg, chestEntries)
    local plan = {Keys = {}, BagWorth = 0, ChestWorth = 0, Stacks = 0}
    if not config.AutoSellMiners or type(mg) ~= "table" then return plan end
    local holders = type(mg.Holders) == "table" and mg.Holders or {}
    local assignedNames = {}
    local assigned = 0
    local weakest = math.huge
    for holderKey, holder in pairs(holders) do
        if type(holder) == "table" and type(holder.CharName) == "string" then
            local ok, item = pcall(Items.GetItemData, holder.CharName)
            if ok and type(item) == "table" and item.Type == "Character" then
                assignedNames[holder.CharName] = true -- protects every equipped stack/variant
                if item.MineRole ~= "Hauler" then
                    assigned += 1
                    local good, base = pcall(MineConfig.GetHolderBaseDamage, holder, item)
                    local levelOK, level = pcall(MineConfig.GetHolderLevel, holder)
                    local variantOK, variantMult = pcall(MineConfig.GetHolderVariantMult, holder)
                    local miningOK, miningSpeed = pcall(MineConfig.GetHolderMineSpeed, holder)
                    if good and levelOK and variantOK and miningOK then
                        local multiplyOK, levelMult = pcall(MineConfig.GetCharacterLevelMultiplier, level)
                        if multiplyOK then
                            local power = (tonumber(base) or 0) * (tonumber(levelMult) or 1)
                                * (tonumber(variantMult) or 1) * (tonumber(miningSpeed) or 1)
                            if power > 0 then weakest = math.min(weakest, power) end
                        end
                    end
                end
            end
        end
    end
    -- Never liquidate miners to fill an incomplete team. Under this condition
    -- all unassigned miners may still be needed on spare pads.
    local slotCount = tonumber(mg.MinerSlots) or assigned
    if assigned == 0 or assigned < slotCount or weakest == math.huge then
        state.minerSellStatus = "Waiting for fully assigned mining crew"
        return plan
    end
    -- Wait briefly after the game's Equip Best action, so new drops are assigned
    -- before any evaluation. No extra equip/unequip server calls are made here.
    if config.EquipBest and os.clock() - state.lastEquip < 5.5 then
        state.minerSellStatus = "Giving Equip Best time to settle"
        return plan
    end
    local all = {}
    local function add(entries, inChest)
        for _, entry in ipairs(entries or {}) do
            if type(entry) == "table" and entry.Kind == "Character"
                and entry.Role == "Miner" and type(entry.Key) == "string"
                and not assignedNames[entry.Name] and (tonumber(entry.Count) or 0) > 0
                and (tonumber(entry.Worth) or 0) > 0 then
                local ok, item = pcall(Items.GetItemData, entry.Name)
                if ok and type(item) == "table" and item.Type == "Character"
                    and item.MineRole ~= "Hauler" and MineConfig.CanSellCharacter(item) then
                    local good, damage = pcall(MineConfig.GetCharacterDamage, item)
                    local lvlOK, lvl = pcall(MineConfig.GetCharacterLevelMultiplier, entry.Level or 1)
                    local variantOK, variant = pcall(MineConfig.GetVariantMult, entry.Variant)
                    local speedOK, speed = pcall(MineConfig.GetCharacterMineSpeed, entry.MineSpeedLevel or 1)
                    local power = (good and tonumber(damage) or 0)
                        * (lvlOK and tonumber(lvl) or 1)
                        * (variantOK and tonumber(variant) or 1)
                        * (speedOK and tonumber(speed) or 1)
                    if power > 0 and power == power then
                        local record = all[entry.Key]
                        if not record then
                            record = {Key = entry.Key, Power = power, BagWorth = 0, ChestWorth = 0}
                            all[entry.Key] = record
                        end
                        if inChest then record.ChestWorth += tonumber(entry.Worth) or 0
                        else record.BagWorth += tonumber(entry.Worth) or 0 end
                    end
                end
            end
        end
    end
    local ok, bag = pcall(MineInventory.Collect, mg, "All", MineInventory.KindOrder.Default)
    if not ok or type(bag) ~= "table" then return plan end
    add(bag, false)
    add(chestEntries, true)
    local ranked = {}
    for _, entry in pairs(all) do ranked[#ranked + 1] = entry end
    table.sort(ranked, function(a,b)
        if a.Power ~= b.Power then return a.Power > b.Power end
        return a.Key < b.Key
    end)
    -- Protect entire stacks, never attempt to sell a portion of a stack: the
    -- game's Sell event accepts keys and normally sells their entire count.
    local keep = math.clamp(math.floor(tonumber(config.MinerKeepBestSpare) or 2), 0, 10)
    local threshold = weakest * math.clamp(tonumber(config.MinerSellStrength) or 0.85, 0.1, 1)
    for i, entry in ipairs(ranked) do
        if i > keep and entry.Power < threshold then
            if entry.BagWorth > 0 then
                plan.Keys[#plan.Keys + 1] = entry.Key
                plan.BagWorth += entry.BagWorth
                plan.Stacks += 1
            end
            plan.ChestWorth += entry.ChestWorth
        end
    end
    state.minerSellCandidates = plan.Stacks
    state.minerSellStatus = string.format("%d weak spare stacks | worth %.3g on hand + %.3g in chest",
        plan.Stacks, plan.BagWorth, plan.ChestWorth)
    return plan
end

local function sellableCargo(mg, chestEntries)
    local keys, worth, oreWorth = {}, 0, 0
    if config.AutoSellOre then
        local oreKeys, oreValue = sellableOre(mg)
        for _, key in ipairs(oreKeys) do keys[#keys + 1] = key end
        worth = oreValue
        oreWorth = oreValue
    end
    local miners = minerSalePlan(mg, chestEntries)
    for _, key in ipairs(miners.Keys) do keys[#keys + 1] = key end
    return keys, worth + miners.BagWorth, oreWorth, miners
end

local function sellOre(mg, epoch, force)
    -- Includes safe weak miner stacks as well as ore; limits repeated seller
    -- journeys and preserves the existing immediate progression cashout policy.
    if not (config.AutoSellOre or config.AutoSellMiners)
        or os.clock() - state.lastSellAttempt < (force and 5 or 30) then return false end
    local keys, worth, oreWorth, miners = sellableCargo(mg, getChestEntries(mg))
    if #keys == 0 or worth <= 0 then return false end
    local cash = moneyAvailable(select(1, getMine()))
    local researchReady = config.AutoCompleteResearch and state.researchTotal > state.researchCurrent
        and state.researchNextCost > cash and cash + worth >= state.researchNextCost
    if not force and not researchReady and worth < math.max(config.MinSellValue, cash * 0.012)
        and os.clock() - state.lastSell < 150 then return false end
    if config.EfficientTrips and not force then
        local _, fresh = getMine()
        local zoneKey, zoneCost = nextZoneFromSave(fresh or mg)
        local _, _, _, gateComplete = zoneResearchStatus(fresh or mg, zoneKey)
        local zoneReady = zoneKey and gateComplete and zoneCost and cash < zoneCost
            and cash + worth >= zoneCost
        local chestEntries = getChestEntries(fresh or mg)
        local capacity = tonumber(MineConfig.GetChestCapacityFor(fresh or mg, 0)) or 0
        local chestCount = totalChestCount(chestEntries)
        local chestSoon = config.AutoChest and capacity > 0 and chestCount >= capacity * 0.63
        local enoughCashValue = worth >= math.max(config.MinSellValue, cash * 0.055)
        local maxWaitReached = os.clock() - state.lastSell > 165
        local recentTrip = os.clock() - state.lastActualSell < (config.FasterScheduling and 50 or 65)
        if not researchReady and not zoneReady and not chestSoon and not maxWaitReached
            and (not enoughCashValue or recentTrip) then return false end
    end
    state.lastSellAttempt = os.clock()
    if config.NativeTravel then teleportGame("Hub", epoch) end
    local seller = findSeller()
    local pos = positionOf(seller)
    if not pos then state.lastFailure = "SellStand not loaded"; return false end
    local prompt = seller:FindFirstChild("SellPrompt", true)
    local reach = prompt and math.min(8.0, math.max(5.5, prompt.MaxActivationDistance)) or 8
    if not standAround(pos, reach, epoch, "Seller", seller) then
        state.lastFailure = "Seller navigation blocked"
        return false
    end
    -- Re-evaluate *after* travelling: the game may have equipped a new miner
    -- during the journey. Never send a stale list of potentially strong units.
    local freshData, fresh = getMine()
    if not fresh then
        if config.NativeTravel and travelValid(epoch) then teleportGame("Plot", epoch) end
        return false
    end
    local finalKeys, finalWorth, _, finalMiners = sellableCargo(fresh, getChestEntries(fresh))
    if #finalKeys == 0 then
        if config.NativeTravel and travelValid(epoch) then teleportGame("Plot", epoch) end
        return false
    end
    local priorCash = moneyAvailable(freshData)
    local originalCounts = {}
    for _, key in ipairs(finalMiners.Keys) do
        originalCounts[key] = tonumber((fresh.Characters or {})[key]) or 0
    end
    local sold = sendConfirmed("MineSellItems", function(newData, newer)
        if not newer then return false end
        if moneyAvailable(newData) > priorCash then return true end
        local _, remaining = sellableCargo(newer, getChestEntries(newer))
        if remaining < finalWorth then return true end
        for key, oldCount in pairs(originalCounts) do
            if (tonumber((newer.Characters or {})[key]) or 0) < oldCount then return true end
        end
        return false
    end, 3.2, finalKeys)
    if sold then
        state.lastSell = os.clock()
        state.lastActualSell = state.lastSell
        local _, post = getMine()
        if post then
            for key, before in pairs(originalCounts) do
                local actual = math.max(0, before - (tonumber((post.Characters or {})[key]) or 0))
                state.minersSold += actual
            end
        end
        if next(originalCounts) then
            state.lastMinerSale = state.lastSell
            state.minerSaleRevenue += finalMiners.BagWorth
            state.minerSellStatus = string.format("Sold safe spare miners for about %.3g", finalMiners.BagWorth)
        end
    end
    if config.NativeTravel and travelValid(epoch) then teleportGame("Plot", epoch) end
    return sold
end

local function bestUnlockedZone(mg)
    local maxZone = 1
    for k, unlocked in pairs(mg.UnlockedZones or {}) do
        if unlocked and MineConfig.Zones and MineConfig.Zones[k] then
            local n = tonumber(tostring(k):match("^Z(%d+)$"))
            if n then maxZone = math.max(maxZone, n) end
        end
    end
    return maxZone
end
local function currentZoneNum(mg)
    return tonumber(tostring(mg.CurrentZone):match("%d+")) or 1
end
local function zoneTick(mg)
    if os.clock()-state.lastZone<(config.FasterScheduling and 2.5 or 5) then return end
    local best=bestUnlockedZone(mg)
    local wanted=config.ZoneMode=="Selected zone" and math.min(best,config.ChosenZone) or best
    if currentZoneNum(mg)==wanted then return end
    state.lastZone=os.clock()
    local old=currentZoneNum(mg)
    sendConfirmed("MineSelectZone",function(_,fresh)
        return fresh and currentZoneNum(fresh)==wanted and currentZoneNum(fresh)~=old
    end,2.8,"Z"..wanted)
end
-- Resolve the next research pip using the real family offsets, parent nodes,
-- family caps and CompletionPips rules. The first active pip in a family is
-- mandatory when the family's earned count is below the completion threshold.
-- Recursive prerequisite resolution covers optional parent nodes that are
-- needed to reach a mandatory child. It never buys unrelated optional pips.
local function researchFamilyGoals(zone)
    local goals = {}
    local families = MineConfig.ZoneSkillMax and MineConfig.ZoneSkillMax[zone] or {}
    local nodes = MineConfig.GetSkillNodes(zone) or {}
    for family in pairs(families) do
        local maximum = tonumber(MineConfig.GetSkillMax(zone, family)) or 0
        for _, node in ipairs(nodes) do
            if node.Family == family and node.CompletionPips ~= nil then
                local pips = tonumber(node.Pips) or 0
                maximum -= pips - math.clamp(tonumber(node.CompletionPips) or 0, 0, pips)
            end
        end
        goals[family] = math.max(0, math.floor(maximum))
    end
    return goals, nodes
end

local function researchPlan(mg, zone)
    local levels = ((mg.Skills or {})[zone]) or {}
    local goals, nodes = researchFamilyGoals(zone)
    local byId = MineConfig.ZoneSkillNodeById and MineConfig.ZoneSkillNodeById[zone] or {}
    local available = {}
    local unresolved = 0

    local function resolve(node, visited)
        if not node or MineConfig.IsSkillNodeMaxed(levels, node) then return nil end
        if visited[node.Id] then return nil end
        visited[node.Id] = true
        -- Parents must be MAXED, not merely purchased once.
        for _, id in ipairs(node.Parents or {}) do
            local parent = byId[id]
            if parent and not MineConfig.IsSkillNodeMaxed(levels, parent) then
                local prerequisite = resolve(parent, visited)
                visited[node.Id] = nil
                return prerequisite
            end
        end
        local level = tonumber(levels[node.Family]) or 0
        if level < (tonumber(node.FamilyOffset) or 0) then
            -- Family-specific levels are sequential even if parent graph is open.
            for _, previous in ipairs(nodes) do
                if previous.Family == node.Family
                    and (tonumber(previous.FamilyOffset) or 0) <= level
                    and not MineConfig.IsSkillNodeMaxed(levels, previous) then
                    local first = resolve(previous, visited)
                    visited[node.Id] = nil
                    return first
                end
            end
            visited[node.Id] = nil
            return nil
        end
        local open = MineConfig.IsSkillNodeOpen(levels, node)
        visited[node.Id] = nil
        return open and node or nil
    end

    for family, goal in pairs(goals) do
        if (tonumber(levels[family]) or 0) < goal then
            unresolved += 1
            local current = MineConfig.GetActiveSkillNode(levels, family, zone)
            local nextNode = resolve(current, {})
            if nextNode then
                local id = tostring(nextNode.ZoneKey or zone) .. ":" .. tostring(nextNode.Id)
                if not available[id] then
                    local level = tonumber(levels[nextNode.Family]) or 0
                    local cost = tonumber(MineConfig.GetSkillCost(zone, level, nextNode.Family))
                    if cost and cost > 0 and cost < math.huge and cost == cost then
                        available[id] = {Zone = zone, Node = nextNode, Cost = cost,
                            Level = level, Required = (goals[nextNode.Family] or 0) > level}
                    end
                end
            end
        end
    end
    local ordered = {}
    for _, candidate in pairs(available) do
        table.insert(ordered, candidate)
    end
    -- Cheapest progress first, but NodeLevel can improve ore per rock HP.
    -- Elevate it only when the actual current power can still one-hit the
    -- upcoming zone's baseline Easy node after the density upgrade.
    local zoneDef = MineConfig.Zones and MineConfig.Zones[zone]
    local zoneHp = tonumber(zoneDef and zoneDef.NodeBaseHealth) or 0
    local minePower = tonumber(Player:GetAttribute("MinePower"))
    local function densityStage(a)
        if a.Node.Family == "BigNode" then return 1 end
        if a.Node.Family ~= "NodeLevel" then return 0 end
        if config.AdaptiveNodeDensity and minePower and zoneHp > 0
            and type(MineConfig.GetNodeLevelHealthMult) == "function" then
            local futureHealthMult = tonumber(MineConfig.GetNodeLevelHealthMult(a.Level + 1, zone)) or 1
            local futureOreMult = tonumber(MineConfig.GetNodeLevelOreStep(a.Level, zone)) or 1
            local futureHealthStep = tonumber(MineConfig.GetNodeLevelHealthStep(a.Level, zone)) or 1
            if futureOreMult > futureHealthStep and minePower >= zoneHp * futureHealthMult then
                return -1
            end
        end
        return 1
    end
    table.sort(ordered, function(a, b)
        local stageA = densityStage(a)
        local stageB = densityStage(b)
        if stageA ~= stageB then return stageA < stageB end
        if a.Cost ~= b.Cost then return a.Cost < b.Cost end
        if a.Required ~= b.Required then return a.Required end
        return tostring(a.Node.Id) < tostring(b.Node.Id)
    end)
    return ordered, unresolved
end

-- IMPORTANT: sale value is item.Worth for the entire stack (not price per unit).
-- Only genuinely sellable items count toward the funding goal: ore plus
-- weak unassigned miner stacks after protecting the crew and best spares.
-- MineInventory.ChestEntries supplies the game's current sell multipliers.
local function chestOreWorth(entries)
    local worth = 0
    for _, entry in ipairs(entries or {}) do
        if entry.Kind == "Ore" and (tonumber(entry.Count) or 0) > 0 then
            local value = tonumber(entry.Worth) or 0
            if value > 0 and value < math.huge and value == value then
                worth += value
            end
        end
    end
    return worth
end

-- Evaluate CURRENT required research/next consecutive zone, never an unrelated
-- optional node or an unreleased zone. This runs at the movement scheduler,
-- which can act without waiting for the usual chest-fill / sale thresholds.
local function progressionCashoutPlan(data, mg, chestEntries)
    if not config.AutoCashoutProgression or not config.AutoChest
        or not (config.AutoSellOre or config.AutoSellMiners)
        or not config.AutoBuyZones or type(mg) ~= "table" then return nil end
    local nextKey, zoneCost, zone = nextZoneFromSave(mg)
    if not nextKey then return nil end
    local cash = moneyAvailable(data)
    local _, bagWorth, _, saleMiners = sellableCargo(mg, chestEntries)
    local chestWorth = (config.AutoSellOre and chestOreWorth(chestEntries) or 0)
        + (saleMiners.ChestWorth or 0)
    state.cashoutInventoryWorth, state.cashoutChestWorth = bagWorth, chestWorth
    local available = cash + bagWorth + chestWorth
    if bagWorth <= 0 and chestWorth <= 0 then return nil end

    local _, _, _, gateComplete = zoneResearchStatus(mg, nextKey)
    local goalCost, goalName
    if gateComplete then
        if config.ZoneBuyMode == "Power ready" then
            local hp = tonumber(zone and zone.NodeBaseHealth) or 0
            if hp > 0 and hp / math.max(1, estimatedRockDPS(mg)) > config.ZoneMaxRockSeconds then
                return nil
            end
        end
        if zoneCost and zoneCost > cash and zoneCost <= available then
            goalCost, goalName = zoneCost, "Unlock " .. tostring(nextKey)
        end
    elseif config.AutoCompleteResearch then
        local gate = MineConfig.ZoneResearchGateFor(nextKey)
        if gate then
            local candidates = researchPlan(mg, gate)
            local currentPower = liveTeamPower(mg)
            -- Don't leave a currently affordable required pip waiting while
            -- liquidating for a more expensive one; normal researchTick buys it.
            local immediatelyBuyable = false
            for _, option in ipairs(candidates) do
                local requiredPower
                if config.PowerAwareResearch and type(MineConfig.GetSkillPowerReq) == "function" then
                    local ok, power = pcall(MineConfig.GetSkillPowerReq,
                        gate, option.Node.Family, option.Level + 1)
                    if ok then requiredPower = tonumber(power) end
                end
                if not requiredPower or requiredPower <= currentPower then
                    local scope = "MineBuySkill:" .. tostring(gate) .. ":" .. tostring(option.Node.Family)
                        .. ":" .. tostring(option.Node.Id)
                    if (state.actionBlocks[scope] or 0) <= os.clock() then
                        if option.Cost <= cash then
                            immediatelyBuyable = true
                            break
                        end
                        if option.Cost > cash and option.Cost <= available
                            and (not goalCost or option.Cost < goalCost) then
                            goalCost = option.Cost
                            goalName = "Research " .. tostring(option.Node.Name or option.Node.Id)
                        end
                    end
                end
            end
            if immediatelyBuyable then return nil end
        end
    end
    if not goalCost then return nil end
    return {
        Name = goalName, Cost = goalCost, Cash = cash,
        BagWorth = bagWorth, ChestWorth = chestWorth,
        -- Don't collect the chest unless inventory ore is insufficient.
        NeedChest = cash + bagWorth < goalCost,
    }
end

local function researchTick(data, mg)
    if not config.AutoCompleteResearch then return false end
    local nextKey = nextZoneFromSave(mg)
    if not nextKey then
        state.researchStatus = "No further currently available zone gate"
        state.rescueActive = false
        state.rescueState = "No further research gate"
        state.researchNextCost = 0
        return false
    end
    local gate, earned, required, complete = zoneResearchStatus(mg, nextKey)
    state.researchZone = gate or "None"
    state.researchCurrent, state.researchTotal = earned, required
    state.researchPercent = required > 0 and math.clamp(math.floor(100 * earned / required), 0, complete and 100 or 99) or (complete and 100 or 0)
    if complete then
        state.researchStatus = "100% complete — unlock " .. nextKey
        state.rescueActive = false
        state.rescueRequired = 0
        state.rescueState = "Research complete; saving to unlock zone"
        state.researchNextCost = 0
        state.researchNextName = "Complete"
        state.researchBlocked = ""
        return false
    end
    if not gate or required <= 0 then
        state.researchStatus = "Research progress unavailable for " .. nextKey
        state.researchBlocked = "Missing or unconfirmed research gate"
        return false
    end
    local candidates, remaining = researchPlan(mg, gate)
    -- Keep the least expensive REQUIRED future node visible even when the
    -- highest-productivity candidate is not currently affordable.
    local affordableCandidate = nil
    local cheapestCandidate = nil
    local cash = moneyAvailable(data)
    local cashCanAffordOne = false
    local minePower = liveTeamPower(mg)
    local blockedPower, minMissingPower = 0, nil
    state.researchPowerWait = ""
    state.rescuePower = minePower
    state.rescueRequired = 0
    state.rescueActive = false
    for _, option in ipairs(candidates) do
        if not cheapestCandidate or option.Cost < cheapestCandidate.Cost then cheapestCandidate = option end
        local requiredPower = nil
        if config.PowerAwareResearch and minePower and type(MineConfig.GetSkillPowerReq) == "function" then
            local ok, req = pcall(MineConfig.GetSkillPowerReq, gate, option.Node.Family, option.Level + 1)
            if ok then requiredPower = tonumber(req) end
        end
        if requiredPower and requiredPower > minePower then
            blockedPower += 1
            minMissingPower = math.min(minMissingPower or math.huge, requiredPower)
        elseif option.Cost <= cash then
            cashCanAffordOne = true
            local scope = "MineBuySkill:" .. tostring(gate) .. ":" .. tostring(option.Node.Family)
                .. ":" .. tostring(option.Node.Id)
            if (state.actionBlocks[scope] or 0) <= os.clock() and not affordableCandidate then
                affordableCandidate = option
            end
        end
    end
    if blockedPower > 0 then

        state.rescueRequired = minMissingPower or 0
        state.researchPowerWait = string.format("Team power %.3g / %.3g", minePower, minMissingPower or 0)
        -- Finish affordable, non-power-gated research first, then grow the
        -- team instead of indefinitely sitting on an impossible Density pip.
        -- Cash-starved but *not* power-locked research must save for research;
        -- power rescue can only spend once ALL currently open pips require power.
        state.rescueActive = config.PowerGateRescue and affordableCandidate == nil
            and blockedPower == #candidates
        if state.rescueActive then
            state.rescueState = string.format("Improving team power %.3g / %.3g", minePower, minMissingPower)
        else
            state.rescueState = "Purchasing available research before power-gated nodes"
        end
    else
        state.rescueState = "Team power meets currently open research requirements"
    end
    local nextCandidate = affordableCandidate or cheapestCandidate
    state.researchNextCost = nextCandidate and nextCandidate.Cost or 0
    state.researchNextName = nextCandidate and tostring(nextCandidate.Node.Name or nextCandidate.Node.Id) or "No open pip"
    state.researchStatus = string.format("%s %d/%d (%d%%) -> %s", gate, earned, required, state.researchPercent, nextKey)
    if #candidates == 0 then
        state.researchBlocked = "No reachable research pips; check game progression"
        state.zoneWait = state.researchStatus .. " | " .. state.researchBlocked
        return false
    end
    state.researchBlocked = ""
    if not affordableCandidate then
        if blockedPower == #candidates and blockedPower > 0 then
            state.researchBlocked = "Power-gated research — " .. state.researchPowerWait
            state.zoneWait = state.researchStatus .. " | " .. state.researchBlocked
            return false
        elseif cashCanAffordOne then
            state.zoneWait = state.researchStatus .. " | Brief research verification cooldown"
        else
            state.zoneWait = state.researchStatus .. " | Next " .. state.researchNextName
                .. string.format(" costs %.3g (have %.3g)", (cheapestCandidate and cheapestCandidate.Cost or 0), cash)
        end
        return false
    end
    if os.clock() - state.researchLast < (config.FasterScheduling and 0.75 or 1.15)
        or (state.actionBlocks.MineBuySkill or 0) > os.clock() then return false end
    -- Choose the cheapest AFFORDABLE currently-open mandatory pip, avoiding a
    -- deadlock if a more expensive research family is still being saved for.
    local chosen = config.SmartResearchPriority and affordableCandidate or candidates[1]
    if not chosen or chosen.Cost > cash then return false end

    state.lastResearchAffordable = tostring(chosen.Node.Name or chosen.Node.Id)
    state.researchLast = os.clock()
    local old = tonumber((((mg.Skills or {})[gate]) or {})[chosen.Node.Family]) or 0
    local ok = sendConfirmed("MineBuySkill", function(_, fresh)
        local levels = fresh and fresh.Skills and fresh.Skills[gate]
        return levels and (tonumber(levels[chosen.Node.Family]) or 0) > old
    end, 2.2, gate, chosen.Node.Family, chosen.Node.Id)
    if ok then

        state.lastSuccess = "Research " .. gate .. " : " .. tostring(chosen.Node.Name or chosen.Node.Id)
        state.researchNextCost = 0
        state.zoneWait = "Verified research pip; recalculating gate"
    else
        state.researchBlocked = "Research purchase not confirmed: " .. tostring(chosen.Node.Id)
    end
    return ok
end

local function zoneBuyTick(data,mg)
    if not config.AutoBuyZones then
        state.zoneGoal="Automatic zone purchases off";state.zoneWait=""
        return false
    end
    local key,cost,def,index=nextZoneFromSave(mg)
    if not key then
        state.zoneGoal="All available permitted zones unlocked";state.zoneWait=""
        return false
    end
    state.zoneGoal=key.." - "..tostring(def.DisplayName or key)
    local gate, earned, required, complete = zoneResearchStatus(mg, key)
    if not complete then
        local percent = required > 0 and math.min(99, math.floor(100 * earned / required)) or 0
        state.zoneWait = string.format("First finish %s research %d/%d (%d%%)", gate or "?", earned, required, percent)
        return false
    end
    local cash=moneyAvailable(data)
    local ratio=cash/math.max(1,cost)
    state.zoneWait=string.format("Research 100%% | Cash %.3g / %.3g (%.1f%%)",cash,cost,ratio*100)
    if cash<cost then return false end
    if config.ZoneBuyMode=="Power ready" then
        local hp=tonumber(def.NodeBaseHealth)
        local power=math.max(1,estimatedRockDPS(mg))
        if hp and hp>0 and hp/power>config.ZoneMaxRockSeconds then
            state.zoneWait="Waiting for mining power: "..string.format("%.1fs estimated easy rock",hp/power)
            return false
        end
    end
    if os.clock()-state.lastZoneBuy<(config.FasterScheduling and 4.5 or 8) then return false end
    if (state.actionBlocks.MineSelectZone or 0)>os.clock() then return false end
    state.lastZoneBuy=os.clock()
    -- This is the literal action attached to each zone-board row in the game's
    -- client. A locked row is only attempted if its live configured cash cost is
    -- available, and only the next consecutive accessible zone is targeted.
    local ok=sendConfirmed("MineSelectZone",function(_,fresh)
        return fresh and type(fresh.UnlockedZones)=="table" and fresh.UnlockedZones[key]==true
    end,3.5,key)
    if ok then

        state.lastZone=-100
        state.zoneWait="Verified newly unlocked zone"
        state.lastSuccess="Zone "..key.." unlocked"
        return true
    end
    state.zoneWait="No unlock confirmation - waiting before retry"
    return false
end
local function buySlotOrTap(data, mg)
    local options = {}
    local function coreUnlocked(family)
        local bought = MineConfig.GetCoreBought(mg, family)
        for _, node in ipairs(MineConfig.CoreNodes or {}) do
            if node.Family == family and not MineConfig.IsCoreNodeMaxed(mg, node)
                and MineConfig.IsCoreNodeOpen(mg, node)
                and bought >= (node.FamilyOffset or 0) then
                return true
            end
        end
        return false
    end
    if config.AutoTapUpgrades and coreUnlocked("Tap") then
        local upgrade = MineConfig.CoreUpgradeById.Tap
        local level = tonumber(mg.TapLevel) or upgrade.Base
        local cost = level < upgrade.Max and upgrade.Cost(level) or nil
        if affordable(data, cost) then
            local old = MineConfig.GetTapDamage(level)
            local new = MineConfig.GetTapDamage(math.min(upgrade.Max, level + 1))
            table.insert(options, {Action = upgrade.Event, Cost = cost,
                Score = (new - old) / math.max(1, cost) * math.max(1, moneyAvailable(data)) * 0.15,
                Name = "Tap damage"})
        end
    end
    if config.AutoSlots and coreUnlocked("Slots") then
        local upgrade = MineConfig.CoreUpgradeById.Slots
        local level = tonumber(mg.MinerSlots) or upgrade.Base
        local cost = level < upgrade.Max and upgrade.Cost(level) or nil
        if affordable(data, cost, "TeamPower") then
            local holderCount = 0
            for _, holder in pairs(mg.Holders or {}) do
                if type(holder) == "table" and (holder.CharName or holder.Character or holder.Miner) then holderCount += 1 end
            end
            local available = 0
            for _, c in pairs(mg.Characters or {}) do available += math.max(0, tonumber(c) or 0) end
            local pressure = available > level and 2 or 0.2
            if not state.rescueActive or available > holderCount then
            table.insert(options, {Action = upgrade.Event, Cost = cost,
                Score = pressure * (1 + holderCount / math.max(1, level)) / (1 + math.log10(math.max(1, cost))),
                Name = "Miner slot"})
            end
        end
    end
    table.sort(options, function(a, b) return a.Score > b.Score end)
    if options[1] then
        local chosen = options[1]
        local oldLevel = chosen.Action == "MineUpgradeTap" and (tonumber(mg.TapLevel) or 0)
            or (tonumber(mg.MinerSlots) or 0)
        local field = chosen.Action == "MineUpgradeTap" and "TapLevel" or "MinerSlots"
        if sendConfirmed(chosen.Action, function(_, fresh)
            return fresh and (tonumber(fresh[field]) or 0) > oldLevel
        end, 2.3) then return chosen.Name end
    end
end
local function skillTick(data, mg)
    if not config.AutoSkills then return nil end
    if config.AutoBuyZones and config.AutoCompleteResearch then
        local key = nextZoneFromSave(mg)
        if key then
            local _, _, _, complete = zoneResearchStatus(mg, key)
            if not complete then return nil end
        end
    end
    local best, bestScore, bestZone, bestLevel
    for _, zone in ipairs(MineConfig.ZoneKeys or {"Z1"}) do
    if (mg.UnlockedZones or {})[zone] then
    local levels = (mg.Skills or {})[zone] or {}
    local nodes = MineConfig.GetSkillNodes(zone)
    for _, node in ipairs(nodes or {}) do
        if not MineConfig.IsSkillNodeMaxed(levels, node)
            and MineConfig.IsSkillNodeOpen(levels, node) then
            local level = tonumber(levels[node.Family]) or 0
            local cost = MineConfig.GetSkillCost(zone, level, node.Family)
            if affordable(data, cost) then
                local name = tostring(node.Family .. " " .. (node.Name or "")):lower()
                local weight = name:find("damage") and 4 or name:find("tap") and 3.7
                    or name:find("power") and 3.5 or name:find("slot") and 3.3
                    or name:find("speed") and 3 or name:find("ore") and 2.8
                    or name:find("luck") and 2.4 or 1.8
                if name:find("nodelevel") or name:find("hard") or name:find("colossus") then
                    local power = math.max(1, estimatedRockDPS(mg))
                    local rockHP = tonumber((mg.Stats or {}).CurrentHardNodeHp) or 0
                    if rockHP > 0 and rockHP / power > config.ColossusMaxSeconds then weight *= 0.15 end
                elseif name:find("count") or name:find("regrowth") or name:find("respawn") then
                    weight *= (state.observedDPS or 0) > 0 and 1.25 or 0.9
                elseif name:find("motherlode") or name:find("windfall") then
                    weight *= 1.5
                elseif name:find("tempo") or name:find("crit") or name:find("strength") then
                    weight *= 1.4
                end
                local score = weight / (1 + math.log10(math.max(1, tonumber(cost) or 1)))
                if not bestScore or score > bestScore then
                    bestScore, best, bestZone, bestLevel = score, node, zone, level
                end
            end
        end
    end
    end
    end
    if best then
        local old = tonumber(((mg.Skills or {})[bestZone] or {})[best.Family]) or 0
        if sendConfirmed("MineBuySkill", function(_, fresh)
            local levels = fresh and (fresh.Skills or {})[bestZone]
            return levels and (tonumber(levels[best.Family]) or 0) > old
        end, 2.3, bestZone, best.Family, best.Id) then
            return "Skill: " .. tostring(best.Name or best.Id)
        end
    end
end
-- Pickaxes are multipliers on each individual miner. Owning one Quartz
-- doesn't mean the other five miners have Quartz! Evaluate the biggest
-- *actual team-power gain* from every shop pickaxe/miner combination.
-- Smart pickaxe planner: live stock, real unlocks, earned team power, one purchase at a time.
local function pickaxeTick(data, mg)
    local rescue = config.PowerGateRescue and config.PowerRescuePickaxes and state.rescueActive
    if not (config.AutoPickaxes or rescue) then
        state.pickaxeStatus = "Optional automatic purchases disabled"
        return nil
    end
    local now = os.clock()
    if now - state.lastPickaxe < (rescue and 2.8 or 5.5) then return nil end
    state.lastPickaxe = now

    local cash = moneyAvailable(data)
    local stockGlobal = MineStock.GetGlobal()
    if not stockGlobal or type(stockGlobal.CurrentStock) ~= "table" then
        state.pickaxeStatus = "Waiting for live server shop stock"
        return nil
    end
    local holders = mg.Holders or {}
    local miners = {}
    local teamPower = math.max(1, liveTeamPower(mg))
    local spares = {}
    for name, count in pairs(mg.Pickaxes or {}) do
        if (tonumber(count) or 0) > 0 then
            local _, _, spare = MineConfig.GetPickaxeStock(mg, name)
            local def = MineConfig.GetPickaxeByName(name)
            if def and (tonumber(spare) or 0) > 0 then
                spares[#spares + 1] = {mult = tonumber(def.Multiplier) or 1, name = name}
            end
        end
    end
    for holderKey, holder in pairs(holders) do
        if type(holder) == "table" and type(holder.CharName) == "string" then
            local item = Items.GetItemData(holder.CharName)
            if item and item.Type == "Character" and item.MineRole ~= "Hauler" then
                local oldDef = MineConfig.GetHolderPickaxe(holder)
                local oldMult = math.max(1, tonumber(oldDef and oldDef.Multiplier) or 1)
                local fullDamage = (tonumber(MineConfig.GetHolderDamage(holder, item)) or 0)
                    * (tonumber(MineConfig.GetEnchantPowerMult(mg, holderKey)) or 1)
                if fullDamage > 0 then
                    miners[#miners + 1] = {key = holderKey, current = oldMult, power = fullDamage}
                end
            end
        end
    end
    if #miners == 0 then
        state.pickaxeStatus = "Waiting for equipped mining characters"
        return nil
    end
    -- The owned-equipment loop has priority. A duplicate purchase here would waste coins.
    if config.AutoEquipOwnedPickaxes then
        for _, miner in ipairs(miners) do
            for _, spare in ipairs(spares) do
                if spare.mult > miner.current * 1.001 then
                    state.lastPickaxeEquip = -100
                    state.pickaxeStatus = "Equipping an already-owned better pickaxe first"
                    return nil
                end
            end
        end
    end

    local nextKey, zoneCost = nextZoneFromSave(mg)
    local _, _, _, researchReady = zoneResearchStatus(mg, nextKey)
    if nextKey and config.AutoCompleteResearch
        and not researchReady and not rescue then
        state.pickaxeStatus = "Saving for required zone research"
        return nil
    end
    if nextKey and researchReady and config.AutoBuyZones and config.AutoCompleteResearch then
        state.pickaxeStatus = "Required research done; saving every coin for zone " .. nextKey
        return nil
    end
    -- Prefer the zone unlock once savings are substantial, except for a small,
    -- unusually high-value upgrade when the current rocks are already slow.
    local preservingZone = nextKey and researchReady and config.AutoBuyZones
        and config.ZoneSaveForNext and zoneCost and cash >= zoneCost * 0.25 and not rescue
    local currentZone = MineConfig.Zones and MineConfig.Zones[mg.CurrentZone or "Z1"]
    local currentRockHealth = tonumber(currentZone and currentZone.NodeBaseHealth) or 0
    local slowMiners = currentRockHealth > teamPower * 14

    local unlocked = mg.UnlockedZones or {}
    local minTeamGain = math.clamp(tonumber(config.PickaxeMinTeamGain) or 0.015, 0, 1)
    local cap = math.clamp(tonumber(config.PickaxeSpendPercent) or 0.50, 0.05, 0.95)
    local reserve = math.clamp(tonumber(config.PickaxeReservePercent) or 0.15, 0, 0.90)
    if config.PickaxeMode == "Conservative" then
        cap = math.min(cap, 0.30)
        reserve = math.max(reserve, 0.35)
    elseif config.PickaxeMode == "Aggressive" then
        cap = math.max(cap, 0.78)
        reserve = math.min(reserve, 0.07)
    end
    local deficit = rescue and math.max(0, (tonumber(state.rescueRequired) or 0) - teamPower) or 0
    local best, bestScore, bestGain, bestCloses = nil, nil, nil, nil
    local stocked, affordableStock, locked = 0, 0, 0
    local secsLeft = math.max(0, tonumber(MineStock.SecondsLeft()) or 0)

    for index, def in ipairs(MineConfig.Pickaxes or {}) do
        local name = def.Name
        local cost = tonumber(def.Cost)
        local newMult = tonumber(def.Multiplier) or 0
        if type(name) == "string" and not def.RobuxOnly and type(def.Stock) == "table"
            and cost and cost > 0 and cost < math.huge and cost == cost and newMult > 1 then
            if not unlocked[tostring(def.ZoneReq or "Z1")] then
                locked += 1
            else
                local remaining = MineStock.GetRemaining(data, name)
                if remaining and remaining > 0 then
                    stocked += 1
                    local bestLocalGain = 0
                    for _, miner in ipairs(miners) do
                        if newMult > miner.current * 1.001 then
                            local gain = miner.power * (newMult / miner.current - 1)
                            if gain > bestLocalGain then bestLocalGain = gain end
                        end
                    end
                    local relative = bestLocalGain / teamPower
                    local closesGate = deficit > 0 and bestLocalGain >= deficit
                    local enoughImpact = bestLocalGain > 0 and (relative >= minTeamGain or rescue)
                    if enoughImpact and cash >= cost then
                        local share = cost / math.max(1, cash)
                        local buyCap, keepPercent = cap, reserve
                        if rescue then
                            buyCap = math.max(cap, math.clamp(config.PowerRescueMaxPurchase, 0.05, 0.85))
                            keepPercent = math.min(reserve, math.clamp(config.PowerRescueKeepCash, 0, 0.90))
                            if closesGate then
                                buyCap = math.max(buyCap, 0.92)
                                keepPercent = math.min(keepPercent, 0.08)
                            end
                        end
                        local strongException = slowMiners and relative >= 0.40
                            and share <= 0.08
                        if share <= buyCap and share <= 1 - keepPercent
                            and (not preservingZone or strongException) then
                            affordableStock += 1
                            local score = (relative / (0.12 + share))
                                * (1 + math.min(1.5, math.log10(math.max(1, newMult))))
                            if rescue then
                                score *= closesGate and 20 or (1 + math.min(5, bestLocalGain / math.max(1, deficit) * 6))
                            end
                            -- A temporary failed target should not lock all shop purchases.
                            local blocked = (state.actionBlocks["MineBuyPickaxe:" .. tostring(index)] or 0) > now
                            local pending = state.pickaxePending and (state.pickaxePending[name] or 0) > now
                            if not blocked and not pending and (not bestScore or score > bestScore) then
                                best = {index = index, name = name, cost = cost}
                                bestScore, bestGain, bestCloses = score, bestLocalGain, closesGate
                            end
                        end
                    end
                end
            end
        end
    end

    if not best then
        if stocked == 0 then
            state.pickaxeStatus = string.format("No unlocked pickaxes in stock; restock in %d:%02d", secsLeft // 60, secsLeft % 60)
        elseif affordableStock == 0 then
            state.pickaxeStatus = preservingZone and ("Saving for " .. nextKey .. " zone purchase")
                or (rescue and "Saving for pickaxe power-upgrade; research requires more team power"
                or "Waiting for an affordable, worthwhile pickaxe")
        else
            state.pickaxeStatus = "Waiting for shop verification cooldown"
        end
        return nil
    end

    local ownedBefore = tonumber((mg.Pickaxes or {})[best.name]) or 0
    state.pickaxePending = state.pickaxePending or {}
    state.pickaxePending[best.name] = now + 7
    state.pickaxeStatus = "Buying " .. best.name .. " (server verification)"
    local purchased = sendConfirmed("MineBuyPickaxe", function(_, fresh)
        return fresh and (tonumber((fresh.Pickaxes or {})[best.name]) or 0) > ownedBefore
    end, 2.8, best.index)
    if purchased then
        state.pickaxeBuys = (state.pickaxeBuys or 0) + 1
        state.pickaxePending[best.name] = nil
        state.lastPickaxeEquip = -100
        if rescue then
            state.rescuePickaxeBuys = (state.rescuePickaxeBuys or 0) + 1
            state.rescueState = string.format("Upgraded %s (+%.3g power); equipping", best.name, bestGain)
        end
        state.pickaxeStatus = string.format("Bought %s; estimated +%.3g team power%s", best.name, bestGain,
            bestCloses and " (research gate met when equipped)" or "")
        return "Smart pickaxe: " .. best.name
    end
    state.pickaxeStatus = "Purchase not confirmed; retrying safely after cooldown"
    return nil
end

-- All three buttons shown on the game's miner detail screen send the same
-- MineUpgradeCharacter event with an explicit stat kind: Damage / Speed / MineSpeed.
-- Upgrade ACTUALLY assigned miners, not unequipped inventory characters. Rotate
-- fairly across both holders and stat types to avoid upgrading only one strong
-- miner forever. No paid purchases, capped levels, or unverified repeated sends.
local function characterLevelsTick(data, mg)
    if not (config.AutoCharacterLevels or config.AutoCrewSpeed or config.AutoMinerMineSpeed) then
        state.minerStatsStatus = "Automatic miner stats disabled"
        return nil
    end
    if os.clock() - state.lastMinerStatCheck < 0.75 then return nil end
    state.lastMinerStatCheck = os.clock()
    if type(mg) ~= "table" or type(mg.Holders) ~= "table" then return nil end

    local options, assigned, copied, capped, cashBlocked = {}, 0, 0, 0, 0
    local rescue = config.PowerGateRescue and state.rescueActive
    local stats = {
        {Name = "Damage", On = config.AutoCharacterLevels,
            Level = MineConfig.GetHolderLevel, Max = nil,
            Cost = MineConfig.GetCharacterUpgradeCost, Order = 1},
        {Name = "MineSpeed", On = config.AutoMinerMineSpeed,
            Level = MineConfig.GetHolderMineSpeedLevel, Max = MineConfig.CharMineSpeedMaxLevel,
            Cost = MineConfig.GetCharacterMineSpeedUpgradeCost, Order = 2},
        {Name = "Speed", On = config.AutoCrewSpeed,
            Level = MineConfig.GetHolderSpeedLevel, Max = MineConfig.CharSpeedMaxLevel,
            Cost = MineConfig.GetCharacterSpeedUpgradeCost, Order = 3},
    }
    for holderKey, holder in pairs(mg.Holders) do
        if type(holder) == "table" and type(holder.CharName) == "string" and holder.CharName ~= "" then
            local success, item = pcall(Items.GetItemData, holder.CharName)
            if success and type(item) == "table" and item.Type == "Character"
                and item.MineRole ~= "Hauler" then
                assigned += 1
                -- Copied/scaled miners display disabled 'Copied' stat buttons.
                local copyOK, copyText = pcall(MineConfig.ScaledCopyText, holder, item)
                if copyOK and copyText then
                    copied += 1
                else
                    for _, stat in ipairs(stats) do
                        if stat.On and (not rescue or stat.Name == "Damage") then
                            local ok, level = pcall(stat.Level, holder)
                            level = ok and tonumber(level) or nil
                            local limit = tonumber(stat.Max)
                            if stat.Name == "Damage" then
                                local capOK, cap = pcall(MineConfig.GetCharLevelCap,
                                    mg, holderKey, holder, item, Items.GetItemData)
                                limit = capOK and tonumber(cap) or tonumber(MineConfig.CharMaxLevel)
                            end
                            if level and limit and level >= 1 and level < limit then
                                local costOK, cost = pcall(stat.Cost, level, item)
                                cost = costOK and tonumber(cost) or nil
                                if cost and cost > 0 and cost < math.huge and cost == cost then
                                    local kind = stat.Name == "Damage" and "TeamPower" or nil
                                    if affordable(data, cost, kind) then
                                        local token = tostring(holderKey) .. "|" .. tostring(stat.Order)
                                        local score = 0
                                        if rescue and stat.Name == "Damage" then
                                            local baseOK, base = pcall(MineConfig.GetHolderBaseDamage, holder, item)
                                            local pickOK, pick = pcall(MineConfig.GetHolderPickaxe, holder)
                                            local oldOK, oldLevelMult = pcall(MineConfig.GetCharacterLevelMultiplier, level)
                                            local newOK, newLevelMult = pcall(MineConfig.GetCharacterLevelMultiplier, level + 1)
                                            if baseOK and oldOK and newOK then
                                                score = math.max(0, (tonumber(base) or 0)
                                                    * (pickOK and tonumber(pick and pick.Multiplier) or 1)
                                                    * ((tonumber(newLevelMult) or 1) - (tonumber(oldLevelMult) or 1)))
                                                    / math.max(1, cost)^0.10
                                            end
                                        end
                                        options[#options + 1] = {
                                            Key = holderKey, CharName = holder.CharName,
                                            Name = stat.Name, Level = level, Cost = cost,
                                            Reader = stat.Level, Token = token,
                                            Score = score,
                                        }
                                    else
                                        cashBlocked += 1
                                    end
                                end
                            else
                                capped += 1
                            end
                        end
                    end
                end
            end
        end
    end
    if #options == 0 then
        state.minerStatsStatus = string.format("%d assigned miners; %d copied; %d capped stats; %d waiting for cash/research",
            assigned, copied, capped, cashBlocked)
        return nil
    end

    -- In a research power emergency, spend on the most productive Damage
    -- increase first. Otherwise, sort deterministically and cycle fairly
    -- through ALL equipped miner/stat pairs on successive successful upgrades.
    table.sort(options, function(a, b)
        if rescue and a.Score ~= b.Score then return a.Score > b.Score end
        return a.Token < b.Token
    end)
    local start = 1
    if not rescue then
        local lastToken = state.minerStatsLastToken or ""
        for i, option in ipairs(options) do
            if option.Token > lastToken then start = i; break end
        end
    end
    for offset = 0, #options - 1 do
        local selected = options[(start + offset - 1) % #options + 1]
        local scope = "MineUpgradeCharacter:" .. tostring(selected.Key) .. ":" .. selected.Name
        if (state.actionBlocks[scope] or 0) <= os.clock() then
            -- The game UI always passes the stat kind; the previous Damage
            -- upgrader omitted it. Explicit arguments match its button exactly.
            state.minerStatsLastToken = selected.Token
            local bought = sendConfirmed("MineUpgradeCharacter", function(_, fresh)
                local holder = fresh and fresh.Holders and fresh.Holders[selected.Key]
                if not holder or holder.CharName ~= selected.CharName then return false end
                local checked, freshLevel = pcall(selected.Reader, holder)
                return checked and (tonumber(freshLevel) or 0) > selected.Level
            end, 2.4, selected.Key, selected.Name)
            if bought then
                state.minerStatUpgrades[selected.Name] = (state.minerStatUpgrades[selected.Name] or 0) + 1
                if rescue and selected.Name == "Damage" then
                    state.rescueCharacterBuys = (state.rescueCharacterBuys or 0) + 1
                end
                state.minerStatsStatus = string.format("Upgraded %s on %s (%s): %d -> %d",
                    selected.Name, tostring(selected.Key), selected.CharName,
                    selected.Level, selected.Level + 1)
                state.lastSuccess = state.minerStatsStatus
                return state.minerStatsStatus
            end
            state.minerStatsStatus = string.format("%s on %s not confirmed; trying other miners next",
                selected.Name, tostring(selected.Key))
            return nil
        end
    end
    state.minerStatsStatus = "All available stat upgrades cooling down"
    return nil
end

local function craftTick(data, mg)
    if config.AutoCompleteResearch then
        local nextKey = nextZoneFromSave(mg)
        if nextKey then
            local _, _, _, complete = zoneResearchStatus(mg, nextKey)
            if not complete or config.AutoBuyZones then return nil end
        end
    end
    if not config.AutoCrafting or CraftingCatalog.Enabled ~= true
        or os.clock() - state.lastCraft < 40 then return nil end
    local candidates = CraftingCatalog.Recipes()
    for i = #candidates, 1, -1 do
        local recipe = candidates[i]
        -- Check() is the SAME cost and ingredient validator used by the in-game forge.
        local ok, permitted = pcall(CraftingCatalog.Check, mg, data.Money or 0, recipe)
        if ok and permitted and recipe and recipe.Key then
            state.lastCraft = os.clock()
            if send("MineCraft", recipe.Key) then
                return "Craft request: " .. tostring(recipe.Output or recipe.Key)
            end
        end
    end
end
local function rewardsTick(mg)
    if config.AutoSpin and SpinConfig.Enabled and SpinConfig.Unlocked(mg)
        and os.clock() - state.lastSpin > 60 then
        local nextAt = tonumber((mg.DailySpin or {}).NextAt) or 0
        if Workspace:GetServerTimeNow() >= nextAt then
            state.lastSpin = os.clock()
            send(SpinConfig.Events.Spin or "MineDailySpin")
        end
    end
    if config.AutoQuests and QuestConfig.Enabled and os.clock() - state.lastQuest > 30 then
        state.lastQuest = os.clock()
        local daily = mg.DailyQuests
        if daily and QuestConfig.IsToday(daily, Workspace:GetServerTimeNow()) then
            local slots = table.clone(QuestConfig.Slots or {})
            table.insert(slots, QuestConfig.GrandSlot or "Grand")
            for _, slot in ipairs(slots) do
                local q = QuestConfig.Quest(daily, slot)
                if q and QuestConfig.IsComplete(q) and q.Claimed ~= true then
                    send(QuestConfig.Events.Claim or "MineDailyQuestClaim", slot)
                    break
                end
            end
        end
    end
    if config.AutoSummon and os.clock() - state.lastSummon > 18
        and SummonCatalog.Unlocked(mg) then
        local count = MineConfig.GetSummonScrollCount(mg)
        if tonumber(count) and count > math.max(0, config.KeepSummonScrolls) then
            state.lastSummon = os.clock()
            send("MineSummon")
        end
    end
end
-- Deep-game systems run in their own closure to avoid the Luau 200-local-register limit.
-- Every action is gated by the actual replicated unlock/state; no speculative purchases.
local Advanced = (function()
    local function opt(name)
        local ref = Modules:FindFirstChild(name)
        if not ref then return nil end
        local ok, value = pcall(require, ref)
        return ok and type(value) == "table" and value or nil
    end
    local Index = opt("MineIndexRewardsConfig")
    local Mail = opt("MailRewards")
    local Trial = opt("MineTrialConfig")
    local Events = opt("MineEventsConfig")
    local Potions = opt("MinePotionCatalog")
    local Gear = opt("MineGearCatalog")
    local Weather = opt("MineWeather")
    local Enchants = opt("MineEnchantCatalog")
    local Lag = opt("MineLagToggles")
    local eventState = nil
    local latestEventsAt = 0
    local lastCall = {}
    local blockedFeatures = {}
    local function ready(key, cooldown)
        local now = os.clock()
        if now < (lastCall[key] or -100) + cooldown then return false end
        lastCall[key] = now
        return true
    end
    local function safe(fn, ...)
        if type(fn) ~= "function" then return nil end
        local ok, value = pcall(fn, ...)
        return ok and value or nil
    end
    local function doClaim(action, check, ...)
        if not config.Master or not state.alive then return false end
        return sendConfirmed(action, check, 2.6, ...)
    end
    if Events and Events.Enabled and type(GameState.ListenToEvent) == "function" then
        local conn = safe(GameState.ListenToEvent, Events.Events and Events.Events.State or "MineEventsState", function(payload)
            if not state.alive or type(payload) ~= "table" then return end
            eventState = payload
            latestEventsAt = os.clock()
        end)
        if conn and type(conn.Disconnect) == "function" then
            table.insert(state.connections, conn)
        end
    end
    local function indexClaim(mg)
        if not config.AutoIndex or not Index or Index.Enabled ~= true then return false end
        if not ready("indexScan", 8) then return false end
        local names = safe(Index.HeldNames, mg)
        if type(names) ~= "table" then return false end
        for _, category in ipairs(safe(Index.Keys) or {}) do
            local def = safe(Index.Category, category)
            if def and (not def.Zone or (mg.UnlockedZones or {})[category] == true) then
                local snapshot = safe(Index.State, mg, category, names)
                for _, tier in ipairs(snapshot and snapshot.Track or {}) do
                    if tier.Reached and not tier.Claimed then
                        for index, already in ipairs(tier.ClaimedRewards or {}) do
                            if not already then
                                local key, tierKey = category, tier.Key
                                local ok = doClaim(Index.Events.Claim, function(_, fresh)
                                    return fresh and safe(Index.ClaimedReward, fresh, key, tierKey, index) == true
                                end, key, tierKey, index)

                                return ok
                            end
                        end
                    end
                end
            end
        end
        return false
    end
    local function mailboxClaim(data)
        if not config.AutoMailbox or not Mail or not ready("mailScan", 9) then return false end
        local box = type(data.Mailbox) == "table" and data.Mailbox or nil
        for _, message in ipairs(box and box.Messages or {}) do
            if type(message) == "table" and message.Id ~= nil and message.Claimed ~= true then
                for index, reward in ipairs(message.Rewards or {}) do
                    if type(reward) == "table" and not Mail.IsClaimed(message, reward) then
                        local mailId = tostring(message.Id)
                        local ok = doClaim("ClaimMailboxReward", function(fresh)
                            for _, msg in ipairs(((fresh or {}).Mailbox or {}).Messages or {}) do
                                if tostring(msg.Id) == mailId then
                                    return msg.Claimed == true or ((msg.Rewards or {})[index] or {}).Claimed == true
                                end
                            end
                            return false
                        end, mailId, index)

                        return ok
                    end
                end
            end
        end
        return false
    end
    local function buffClaim(mg)
        if not config.AutoBuffGift or mg.BuffModeClaimed ~= false
            or not ready("buff", 45) then return false end
        local ok = doClaim("MineBuffModeClaim", function(_, fresh)
            return fresh and fresh.BuffModeClaimed == true
        end)

        return ok
    end
    local function trialClaim(mg)
        if not config.AutoTrialClaims or not Trial or not Trial.Enabled
            or not safe(Trial.Unlocked, mg) or not ready("trialClaimScan", 12) then return false end
        local trial = type(mg.Trial) == "table" and mg.Trial or {}
        local active = type(trial.Attempt) == "table"
            and Workspace:GetServerTimeNow() < (tonumber(trial.Attempt.EndsAt) or 0)
        state.activeTrial = active
        local rank = active and tonumber(trial.Attempt.Tier) or 0
        local claims = safe(Trial.ClaimableTiers, trial, rank)
        if type(claims) == "table" and #claims > 0 then
            local target = claims[1]
            local ok = doClaim(Trial.Events.Claim, function(_, fresh)
                return fresh and safe(Trial.IsClaimed, fresh.Trial or {}, target) == true
            end, target)

            return ok
        end
        return false
    end
    local function trialRun(mg)
        if not config.AutoTrialRuns or not Trial or not Trial.Enabled
            or not safe(Trial.Unlocked, mg) or not ready("trialRunScan", 40) then return false end
        local t = type(mg.Trial) == "table" and mg.Trial or {}
        if type(t.Attempt) == "table" and Workspace:GetServerTimeNow() < (tonumber(t.Attempt.EndsAt) or 0) then
            state.activeTrial = true
            return false
        end
        state.activeTrial = false
        if os.clock() < state.trialNext then return false end
        local ratio = tonumber(config.TrialMinPowerRatio) or 1.5
        local ladder = safe(Trial.LadderKey)
        local spec = Trial.Ladders and Trial.Ladders[ladder or Trial.BaseLadder]
        local minimum = spec and tonumber(spec.BasePower) or math.huge
        local crew = safe(MineConfig.GetTeamPower, mg, Items.GetItemData)
        if not crew or crew < minimum * ratio then return false end
        local ok = doClaim(Trial.Events.Start, function(_, fresh)
            local attempt = fresh and fresh.Trial and fresh.Trial.Attempt
            return type(attempt) == "table" and Workspace:GetServerTimeNow() < (tonumber(attempt.EndsAt) or 0)
        end)
        -- A trial lasts 5 min. Prevent unnecessary restarts even if start was ignored.
        state.trialNext = os.clock() + (ok and (Trial.WindowSeconds or 300) + 120 or 600)
        return ok
    end
    local function eventClaim()
        if not config.AutoEventClaims or not Events or Events.Enabled ~= true
            or not Events.PayoutsEnabled or not ready("eventScan", 12) then return false end
        if not eventState or eventState.Enabled == false or os.clock() - latestEventsAt > 90 then
            if ready("eventRequest", 32) then send(Events.Events.Open) end
            return false
        end
        local now = Workspace:GetServerTimeNow()
        for _, event in ipairs(eventState.Events or {}) do
            local endsAt = tonumber(event.EndsAt)
            local active = endsAt == nil or now < endsAt
            if active then
                local ladders = {event}
                if safe(Events.PersonalOn) and type(event.Personal) == "table" then
                    local p = table.clone(event.Personal)
                    p.IsPersonal, p.Key, p.Days = true, event.Key, event.Days
                    table.insert(ladders, p)
                end
                for _, ladder in ipairs(ladders) do
                    local tiers = ladder.IsPersonal and safe(Events.PersonalTiers)
                        or safe(Events.Tiers, ladder.Days, (Events.Catalog or {})[ladder.Key])
                    local points = tonumber(ladder.Points) or 0
                    for t, threshold in ipairs(ladder.Thresholds or {}) do
                        if type(tiers) == "table" and tiers[t] and points >= (tonumber(threshold) or math.huge) then
                            local rewards = tiers[t].Rewards or {}
                            for idx = 1, #rewards do
                                local done = (ladder.Claimed or {})[t] == true
                                local bits = tonumber((ladder.Got or {})[t]) or 0
                                if not done and bit32.band(bits, bit32.lshift(1, idx - 1)) == 0 then
                                    local eventId = ladder.Id
                                    if eventId then
                                        local ok = doClaim(Events.Events.Claim, function()
                                            for _, current in ipairs(eventState and eventState.Events or {}) do
                                                local revised = current
                                                if tostring(revised.Id) ~= tostring(eventId) then
                                                    revised = type(current.Personal) == "table" and current.Personal or nil
                                                end
                                                if revised and tostring(revised.Id) == tostring(eventId) then
                                                    if revised.Claimed and revised.Claimed[t] then return true end
                                                    local updated = tonumber((revised.Got or {})[t]) or 0
                                                    return bit32.band(updated, bit32.lshift(1, idx - 1)) ~= 0
                                                end
                                            end
                                            return false
                                        end, eventId, t, idx)

                                        return ok
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
        return false
    end
    local function gearScore(def, mode)
        local t = type(def) == "table" and def.Stats or {}
        local score = (tonumber(t.Strength) or 0) * 1.8 + (tonumber(t.Speed) or 0) * 1.3
            + (tonumber(t.Crit) or 0) * 1.5 + (tonumber(t.Colossus) or 0) * 0.4
        if mode == "Colossus" then score += (tonumber(t.Colossus) or 0) * 2.8 end
        if mode == "Rare loot" then score += (tonumber(t.MutLuck) or 0) * 1.8 end
        return score
    end
    local function gearTick(mg)
        if not config.AutoGear or not Gear or not safe(MineConfig.GearUnlocked, mg)
            or not ready("gearScan", 30) then return false end
        local inv = type(mg.GearItems) == "table" and mg.GearItems or mg.Gears
        if type(inv) ~= "table" then return false end
        for holderKey, holder in pairs(mg.Holders or {}) do
            if type(holder) == "table" and type(holder.CharName) == "string" then
                local item = Items.GetItemData(holder.CharName)
                if item and item.MineRole ~= "Hauler" then
                    local limit = math.clamp(tonumber(safe(MineConfig.GetGearSlotCount, mg, holderKey)) or 2, 0, 3)
                    local choices = {}
                    for _, def in ipairs(Gear.Gear or {}) do
                        local available = tonumber(safe(MineConfig.GetGearItemCount, mg, def.Name)) or 0
                        if available > 0 then
                            local score = gearScore(def, config.MineMode)
                            if score > 0 then table.insert(choices, {Name = def.Name, Score = score}) end
                        end
                    end
                    table.sort(choices, function(a,b) return a.Score > b.Score end)
                    for slot = 1, limit do
                        local oldName = safe(MineConfig.GetHolderGearName, mg, holderKey, slot)
                        if not oldName then
                            local candidate = choices[1]
                            if candidate then
                                local ok = doClaim("MineEquipGear", function(_, fresh)
                                    return fresh and safe(MineConfig.GetHolderGearName, fresh, holderKey, slot) == candidate.Name
                                end, holderKey, slot, candidate.Name)

                                return ok
                            end
                        end
                    end
                end
            end
        end
        return false
    end
    -- Equip already-owned spare enchant items into EMPTY slots only; never roll dice,
    -- replace a valuable roll, unequip, or spend Gems/Robux.
    local function enchantTick(mg)
        if not config.AutoEnchants or not Enchants or not safe(Enchants.Unlocked, mg)
            or not ready("enchantScan", 35) then return false end
        if type(mg.EnchantItems) ~= "table" or type(mg.Holders) ~= "table" then return false end
        local choices = {}
        for _, def in ipairs(safe(Enchants.All) or {}) do
            if type(def) == "table" and type(def.Name) == "string" then
                local stock = tonumber(safe(MineConfig.GetEnchantItemCount, mg, def.Name)) or 0
                if stock > 0 then
                    local strength = math.max(1, tonumber(def.DamageMult) or 1)
                    local speed = math.max(1, tonumber(def.SpeedMult) or 1)
                    local chance = math.max(0, tonumber(def.ProcChance) or 0)
                    local cooldown = math.max(1, tonumber(def.Cooldown) or 10)
                    local score = (strength * speed - 1) * 10 + chance * 15 / cooldown
                        + math.max(0, tonumber(def.Rank) or 0) * 0.35
                    if def.SplashRocks or def.SurgeMult or def.BrittleMult then score += 1.25 end
                    table.insert(choices, {Name = def.Name, Score = score})
                end
            end
        end
        table.sort(choices, function(a, b) return a.Score > b.Score end)
        if #choices == 0 then return false end
        for holderKey, holder in pairs(mg.Holders or {}) do
            if type(holder) == "table" and type(holder.CharName) == "string"
                and not safe(MineConfig.GetHolderEnchantName, mg, holderKey) then
                local item = Items.GetItemData(holder.CharName)
                if item and item.MineRole ~= "Hauler" then
                    local name = choices[1].Name
                    local ok = doClaim("MineEquipEnchant", function(_, fresh)
                        return fresh and safe(MineConfig.GetHolderEnchantName, fresh, holderKey) == name
                    end, holderKey, name)

                    return ok
                end
            end
        end
        return false
    end
    local function potionTick(mg)
        if not config.AutoPotions or not Potions or not ready("potionScan", 24) then return false end
        local owned = mg.Potions or {}
        local weather = string.lower(state.weather or "")
        local desired = {Strength = 1.5, Haste = 1.4, Regrowth = 1.25, TapFury = 1.0,
            OreOutput = 1.15, Yield = 1.2, OreLuck = 1.0, CharLuck = 1.0, Unearth = 1.0}
        if config.PotionMode == "Rare finds" or weather:find("starry") or weather:find("ghost") then
            desired.CharLuck, desired.Unearth, desired.OreLuck = 2.3, 2.3, 1.6
        elseif config.PotionMode == "Cash" or weather:find("rain") or weather:find("aurora") then
            desired.OreOutput, desired.Yield, desired.OreLuck = 2, 2, 1.9
        elseif config.PotionMode == "Power" or state.activeTrial then
            desired.Strength, desired.Haste, desired.TapFury, desired.Rally = 2.7, 2.5, 1.7, 2.1
        end
        local picks = {}
        for _, def in ipairs(Potions.Potions or {}) do
            local count = tonumber(owned[def.ItemName]) or 0
            if def.Kind == "Timed" and count > config.PotionReserve and (desired[def.Family] or 0) > 0 then
                local active = safe(MineConfig.GetBoost, mg, def.Family)
                local secondsLeft = active and (tonumber(active.Until) or 0) - Workspace:GetServerTimeNow() or 0
                local sameOrBetter = secondsLeft > 25 and
                    (tonumber(active and active.Mult) or 0) >= (tonumber(def.Mult) or 0) and
                    (tonumber(active and active.Add) or 0) >= (tonumber(def.Add) or 0)
                if not sameOrBetter then
                    table.insert(picks, {Name = def.ItemName, Score = (desired[def.Family] or 1)
                        * math.log(1 + (tonumber(def.Mult) or 1) + math.max(0, tonumber(def.Add) or 0))})
                end
            end
        end
        table.sort(picks, function(a,b) return a.Score > b.Score end)
        if picks[1] then
            local name = picks[1].Name
            local before = tonumber(owned[name]) or 0
            local ok = doClaim("MineUsePotion", function(_, fresh)
                return fresh and (tonumber((fresh.Potions or {})[name]) or 0) < before
            end, name, 1)

            return ok
        end
        return false
    end
    -- Miner Damage, Speed and MineSpeed now share the fair, server-verified
    -- characterLevelsTick planner. Do not run a second, competing buyer here.
    local function weatherTick()
        if not Weather or not ready("weatherScan", 12) then return end
        local list = safe(Weather.GetActive)
        local names = {}
        for _, value in ipairs(type(list) == "table" and list or {}) do
            table.insert(names, tostring(value.Name or value.Key or (value.Def and value.Def.Name) or ""))
        end
        state.weather = #names > 0 and table.concat(names, ", ") or "Clear"
    end
    local function performanceTick()
        if not Lag or not config.AutoPerformance or not ready("performance", 50) then return end
        -- Native client-only LOD. Never hide 'Plots' (navigation needs rock geometry).
        for _, key in ipairs({"Flights", "Damage", "Mutation", "Enchant", "Hits", "Weather", "PostFX", "WorldFX"}) do
            safe(Lag.Set, key, "Hide")
        end
    end
    local function tick(data, mg)
        weatherTick()
        performanceTick()
        if not config.Master then return end
        -- At most one claim/purchase each tick; weak or disabled features cannot block mining.
        local actions = {function() return mailboxClaim(data) end, function() return indexClaim(mg) end,
            function() return buffClaim(mg) end, function() return trialClaim(mg) end,
            function() return eventClaim() end, function() return gearTick(mg) end,
            function() return enchantTick(mg) end, function() return potionTick(mg) end, function() return trialRun(mg) end}
        for _, action in ipairs(actions) do
            if not state.alive or not config.Master then return end
            local ok, outcome = pcall(action)
            if ok and outcome then return end
        end
    end
    return {Tick = tick}
end)()

-- Throughput improvements based on native game mechanics. No new movement owner.
local Accelerator = (function()
    local lastOwnSellAttempt = -100
    local lastPickEquip = -100
    local function equipBestOwnedPickaxe(mg)
        if not config.AutoEquipOwnedPickaxes then return end
        local now = os.clock()
        if now - lastPickEquip < (state.rescueActive and 1.4 or 2.8) then return end
        local spares = {}
        for name, count in pairs(mg.Pickaxes or {}) do
            if (tonumber(count) or 0) > 0 then
                local _, _, spare = MineConfig.GetPickaxeStock(mg, name)
                local definition = MineConfig.GetPickaxeByName(name)
                if definition and (tonumber(spare) or 0) > 0 then
                    spares[#spares + 1] = {name = name, mult = tonumber(definition.Multiplier) or 1}
                end
            end
        end
        if #spares == 0 then return end
        local chosenKey, chosenName, chosenGain
        for holderKey, holder in pairs(mg.Holders or {}) do
            if type(holder) == "table" and type(holder.CharName) == "string" then
                local item = Items.GetItemData(holder.CharName)
                if item and item.Type == "Character" and item.MineRole ~= "Hauler" then
                    local old = MineConfig.GetHolderPickaxe(holder)
                    local oldMult = math.max(1, tonumber(old and old.Multiplier) or 1)
                    local oldDamage = (tonumber(MineConfig.GetHolderDamage(holder, item)) or 0)
                        * (tonumber(MineConfig.GetEnchantPowerMult(mg, holderKey)) or 1)
                    for _, def in ipairs(spares) do
                        if def.mult > oldMult * 1.001 then
                            local gain = oldDamage * (def.mult / oldMult - 1)
                            local scope = "MineEquipPickaxe:" .. tostring(holderKey) .. ":" .. def.name
                            if gain > 0 and (state.actionBlocks[scope] or 0) <= now
                                and (not chosenGain or gain > chosenGain) then
                                chosenKey, chosenName, chosenGain = holderKey, def.name, gain
                            end
                        end
                    end
                end
            end
        end
        if not chosenKey then return end
        lastPickEquip = now
        local okay = sendConfirmed("MineEquipPickaxe", function(_, fresh)
            local holder = fresh and fresh.Holders and fresh.Holders[chosenKey]
            return holder and holder.Pickaxe == chosenName
        end, 2.5, chosenKey, chosenName)
        if okay then
            state.ownedPickaxeEquips = (state.ownedPickaxeEquips or 0) + 1
            state.pickaxeStatus = string.format("Equipped %s (+%.3g team power)", chosenName, chosenGain)
            state.lastSuccess = "Optimised owned pickaxe " .. tostring(chosenName)
            state.lastPickaxe = -100
        end
    end

    local function ownedNativeAutoSell(data,mg)
        if not config.EnableOwnedAutoSell or not mg.TutorialDone or os.clock()-lastOwnSellAttempt < 2.5 then return end
        local ok,hasPass=pcall(MineConfig.PlayerHasPass,data,MineConfig.AutoSellPassLabel)
        if not ok or not hasPass then
            state.nativeAutoSellState="Requires already-owned Auto Sell pass"
            lastOwnSellAttempt=os.clock()+25
            return
        end
        local found=mg.Found or {}
        local assigned=mg.AutoSell or {}
        local target=nil
        for _,zoneKey in ipairs(MineConfig.ZoneKeys or {}) do
            local zone=MineConfig.Zones and MineConfig.Zones[zoneKey]
            if zone then
                for _,ore in ipairs(zone.Ores or {}) do
                    if type(ore.Name)=="string" and found[ore.Name]
                        and not assigned[ore.Name] then
                        target=ore.Name
                        break
                    end
                end
            end
            if target then break end
        end
        if not target then
            state.nativeAutoSellState="Owned native ore Auto Sell configured"
            lastOwnSellAttempt=os.clock()+12
            return
        end
        lastOwnSellAttempt=os.clock()
        local success=sendConfirmed("MineAutoSellSet",function(_,fresh)
            return fresh and fresh.AutoSell and fresh.AutoSell[target]==true
        end,1.8,target,true)
        if success then

            state.nativeAutoSellState="Enabled native sale for "..target
        end
    end
    return {
        Tick=function(data,mg)
            -- Equip only genuinely owned, unassigned pickaxes: never purchases.
            equipBestOwnedPickaxe(mg)
            -- Native auto sell requires existing pass, never buys the pass.
            ownedNativeAutoSell(data,mg)
        end
    }
end)()

local function maintenance()
    local data, mg = getMine()
    if not data or not mg then return end
    if config.EquipBest and os.clock() - state.lastEquip > (state.rescueActive and 5 or 25) then
        state.lastEquip = os.clock()
        send("MineEquipBest")
    end
    if os.clock() - state.lastPickaxeEquip > (state.rescueActive and 1.25 or 3.5) then
        state.lastPickaxeEquip = os.clock()
        local quickOk, quickErr = pcall(Accelerator.Tick,data,mg)
    end
    local rewardOk, rewardErr = pcall(rewardsTick, mg)
    -- Highest priority: the next real zone, before optional skill spending.
    -- A rejected zone action is cooled down, never spammed.
    if os.clock()-state.lastZoneBuy>=8 then
        local zOk,zErr=pcall(zoneBuyTick,data,mg)
    end
    if os.clock() - state.lastSpend > (config.FasterScheduling and 0.85 or 1.25) then
        state.lastSpend = os.clock()
        -- Research unlock chain ALWAYS gets the first purchase opportunity.
        -- No optional upgrade spends coins ahead of the gate. No movement waits.
        local researchOk, researchBought = pcall(researchTick, data, mg)
        if not researchOk then state.lastFailure = "Research planner: " .. tostring(researchBought) end
        local routines = {skillTick, characterLevelsTick, buySlotOrTap, pickaxeTick, craftTick}
        -- Rotate successful spend categories so cheap skills cannot starve
        -- all three miner stat upgrades, tap damage or extra normal slots.
        local start = (state.upgradeCursor % #routines) + 1
        for offset = 0, #routines - 1 do
            if researchOk and researchBought then break end
            if not config.Master or not state.alive then break end
            local index = (start + offset - 1) % #routines + 1
            local routine = routines[index]
            local ok, purchase = pcall(routine, data, mg)
            if not ok then
                local name = tostring(routine)
                state.lastFailure = "Upgrade module: " .. tostring(purchase)

            elseif purchase then
                state.upgradeCursor = index

                break
            end
        end
    end
    if os.clock() - state.lastAdvanced > (config.FasterScheduling and 3.0 or 4.2) then
        state.lastAdvanced = os.clock()
        local ok, why = pcall(Advanced.Tick, data, mg)
    end
    if config.AutoZone then
        local zOk,zErr = pcall(zoneTick, mg)
    end
end

-- A single owner of character movement: chest, sell, mine, idle. Maintenance never walks.
local function farmLoop()
    while state.alive do
        if not config.Master or not config.Mine then
            state.target = "None"
            state.walking = false
            task.wait(0.25)
            continue
        end
        local data, mg = getMine()
        local plot = getPlot()
        local _, _, root = getRig()
        if not mg or not root or not plot then

            task.wait(0.75)
            continue
        end
        local epoch = state.walkEpoch
        local lastActionSucceeded = false
        local entries = getChestEntries(mg)
        local capacity = tonumber(MineConfig.GetChestCapacityFor(mg, 0)) or 0
        local chestCount = totalChestCount(entries)
        local chestFull = config.UrgentFullChest and plot:GetAttribute("MineChestFull") == true
        local goal = nil
        if config.AutoCashoutProgression and config.AutoChest
            and (config.AutoSellOre or config.AutoSellMiners) then
            local planned, result = pcall(progressionCashoutPlan, data, mg, entries)
            if planned then
                goal = result
            else
                state.lastFailure = "Cashout planner: " .. tostring(result)
            end
        end
        local urgentChest = goal and goal.NeedChest
        if goal then
            state.cashoutGoal = goal.Name
            state.cashoutStatus = string.format("%s: %.3g / %.3g cash; sellable %.3g bag + %.3g chest",
                goal.Name, goal.Cash, goal.Cost, goal.BagWorth, goal.ChestWorth)
        else
            state.cashoutGoal = "None"
            state.cashoutStatus = "Waiting for ore to fund required research or next zone"
        end
        if config.AutoChest and chestCount > 0
            and (urgentChest or chestFull or capacity <= 0
                or chestCount / math.max(1, capacity) >= config.ChestPercent
                or os.clock() - state.lastChest > 115) then
            -- Urgent cashouts override the normal chest percentage/age.
            local ok, result = pcall(collectChest, plot, mg, epoch, true, urgentChest)
            if not ok then state.lastFailure = "Chest: " .. tostring(result) end
            lastActionSucceeded = ok and result
            if lastActionSucceeded and urgentChest then
                state.cashoutChestCollections += 1
                state.cashoutStatus = "Collected chest for " .. goal.Name .. "; selling eligible loot"
                -- Chest and inventory replication is confirmed before selling;
                -- collectChest uses the game's Take All, which also keeps miners.
                task.wait(0.12)
                local _, refreshedMine = getMine()
                local soldOk, sold = pcall(sellOre, refreshedMine or mg, epoch, true)
                if not soldOk then
                    state.lastFailure = "Progression sale: " .. tostring(sold)
                elseif sold then
                    state.cashoutSells += 1
                    state.lastCashoutAt = os.clock()
                    state.cashoutStatus = "Sold chest loot for " .. goal.Name
                end
            end
        end
        if not lastActionSucceeded and (config.AutoSellOre or config.AutoSellMiners)
            and not (urgentChest and chestCount > 0) then
            -- Wait for the chest if its ore is REQUIRED for this purchase;
            -- selling a smaller partial bag first wastes a seller journey.
            -- If bagged ore ALREADY pays for the goal, visit the seller first.
            local urgentSell = goal and not goal.NeedChest
            local ok, result = pcall(sellOre, mg, epoch, urgentSell == true)
            if not ok then state.lastFailure = "Seller: " .. tostring(result) end
            lastActionSucceeded = ok and result
            if lastActionSucceeded and urgentSell then
                state.cashoutSells += 1
                state.lastCashoutAt = os.clock()
                state.cashoutStatus = "Sold eligible items for " .. goal.Name
            end
        end
        if not lastActionSucceeded then
            -- Return by the game's own travel action ONLY for meaningful distances.
            if config.NativeTravel then
                local spawn = positionOf(plot:FindFirstChild("PlotSpawn"))
                local _,_,cur = getRig()
                if spawn and cur and planar(cur.Position, spawn) > 125
                    and os.clock() - state.lastHome > 13 then
                    state.lastHome = os.clock()
                    teleportGame("Plot", epoch)
                end
            end
            local node = selectNode(plot, mg)
            if node then
                local ok, why = pcall(mineNode, node, epoch)
                if not ok then
                    state.lastFailure = "Rock: " .. tostring(why)
                    state.blocked[node] = os.clock() + 35
                end
            else

                task.wait(config.FasterScheduling and 0.23 or 0.55)
            end
        end
        task.wait(config.FasterScheduling and 0.035 or 0.06)
    end
end

local API = {}
local masterToggle
function API.Unload()
    if not state.alive then return end
    state.alive = false
    config.Master = false
    cancelWalk()
    if API.Window then
        -- Flush unsaved UI changes before the window is destroyed. Respect the
        -- native Auto Save switch (manual profiles are not overwritten).
        if configSaveAllowed(API.Window) then pcall(saveCompatSettings, true) end
        pcall(function()
            local native = API.Window.Config
            if native and native.Available and native.AutoSave
                and type(API.Window._WriteConfig) == "function" then
                API.Window:_WriteConfig(native.Selected, false)
            end
        end)
        pcall(function() API.Window:Destroy() end)
    end
    for _, connection in ipairs(state.connections) do pcall(function() connection:Disconnect() end) end
    -- PuckUI manages full profiles; the flat compat file backs up settings.
    if env.PuckAFK_MyAnimeMine == API then env.PuckAFK_MyAnimeMine = nil end

end
function API.Start()
    if not state.alive then return end
    config.Master = true
    if masterToggle then pcall(function()
        if masterToggle:Get() ~= true then masterToggle:Set(true) end
    end) end

end
function API.Stop()
    config.Master = false
    cancelWalk()
    if masterToggle then pcall(function()
        if masterToggle:Get() == true then masterToggle:Set(false) end
    end) end

end
API.Config = config
API.State = state
API.SaveConfig = function() return saveCompatSettings(true) end
API.ConfigCompatibility = compatStore
env.PuckAFK_MyAnimeMine = API

table.insert(state.connections, Player.CharacterAdded:Connect(function()
    cancelWalk()
    state.plot = nil
    task.wait(1)
end))

-- Optional Roblox inactivity prevention: only reacts to LocalPlayer.Idled.
-- Works independently of the farm Master toggle and is automatically
-- disconnected by API.Unload. Does not modify character position or stats.
local idleConnected, idleError = pcall(function()
    local connection = Player.Idled:Connect(function()
        if not state.alive or not config.AntiAFK then return end
        if os.clock() - state.lastAntiAfk < 45 then return end
        state.lastAntiAfk = os.clock()
        local ok, why = pcall(function()
            local camera = Workspace.CurrentCamera
            if not camera then error("Camera unavailable") end
            local virtualUser = SERVICE("VirtualUser")
            virtualUser:CaptureController()
            virtualUser:Button2Down(Vector2.new(0, 0), camera.CFrame)
            task.wait(0.10)
            virtualUser:Button2Up(Vector2.new(0, 0), camera.CFrame)
        end)
        if ok then
            state.antiAfkTriggers += 1
            state.antiAfkStatus = "Idle input sent successfully"
        else
            state.antiAfkStatus = "VirtualUser unavailable: " .. tostring(why)
        end
    end)
    table.insert(state.connections, connection)
end)
if not idleConnected then state.antiAfkStatus = "Idle listener unavailable: " .. tostring(idleError) end

-- Prefer canonical PuckUI. Try common HTTP APIs if an executor's HttpGet is
-- unavailable, and reuse a valid preloaded copy when one is supplied.
local function fetchUISource(url)
    local ok, result = pcall(function() return game:HttpGet(url) end)
    if ok and type(result) == "string" and #result > 100 then return result end
    local requests = {}
    if type(request) == "function" then table.insert(requests, request) end
    if type(http_request) == "function" then table.insert(requests, http_request) end
    if type(syn) == "table" and type(syn.request) == "function" then
        table.insert(requests, syn.request)
    end
    if type(http) == "table" and type(http.request) == "function" then
        table.insert(requests, http.request)
    end
    for _, fetch in ipairs(requests) do
        local worked, response = pcall(fetch, {Url = url, Method = "GET"})
        if worked and type(response) == "table" then
            local body = response.Body or response.body
            local status = tonumber(response.StatusCode or response.Status or 200) or 0
            if status >= 200 and status < 300 and type(body) == "string"
                and #body > 100 then return body end
        end
    end
    local direct, body = pcall(function() return HttpService:GetAsync(url) end)
    if direct and type(body) == "string" and #body > 100 then return body end
    return nil
end
local okUI, PuckUI = pcall(function()
    for _, name in ipairs({"PuckUI", "PuckAFK_PuckUI"}) do
        local cached = env[name]
        if type(cached) == "table" and type(cached.CreateWindow) == "function" then
            return cached
        end
    end
    if type(loadstring) ~= "function" then
        error("Executor is missing loadstring; PuckUI cannot be compiled")
    end
    local urls = {
        "https://raw.githubusercontent.com/PuckAFK/Puck-Loader/refs/heads/main/ui/PuckUI.lua",
        "https://cdn.jsdelivr.net/gh/PuckAFK/Puck-Loader@main/ui/PuckUI.lua",
    }
    for _, url in ipairs(urls) do
        local source = fetchUISource(url)
        if source then
            local compiled, loader = pcall(loadstring, source)
            if compiled and type(loader) == "function" then
                local executed, library = pcall(loader)
                if executed and type(library) == "table"
                    and type(library.CreateWindow) == "function" then
                    return library
                end
            end
        end
    end
    error("Unable to fetch or run PuckUI with this executor's HTTP APIs")
end)
if not okUI or type(PuckUI) ~= "table"
    or type(PuckUI.CreateWindow) ~= "function" then
    API.Unload()
    error("[PuckAFK Mine] UI compatibility check failed: " .. tostring(PuckUI))
end

-- A concise home screen, dedicated advanced controls and native PuckUI profiles.
-- ConfigId stays stable, with portable disk/session backup for partial APIs.
local windowOK, window = pcall(function() return PuckUI:CreateWindow({
    Name = "PuckAFK | My Anime Mine",
    LoadingTitle = "My Anime Mine",
    LoadingSubtitle = "Easy automatic progression",
    Width = 612, Height = 540,
    ConfigId = "MyAnimeMine",
    Configs = {DefaultProfile = "default", AutoSave = true, AutoLoad = true},
}) end)
if not windowOK or type(window) ~= "table" then
    API.Unload()
    error("[PuckAFK Mine] UI window could not open: " .. tostring(window))
end
API.Window = window
-- If the user disabled profile auto-loading, truly start with defaults.
if window.Config and window.Config.Available and window.Config.AutoLoad == false then
    for key, value in pairs(defaults) do config[key] = value end
    config.Master = false
    compatStore.loadedFrom = "autoload disabled"
end

-- Move old profile keys to the corresponding new tab before UI controls autoload.
-- Existing profile files are not edited in place; the next save writes new keys.
local migratedTabForKey = {
    ['AccurateMotherlode'] = 'Advanced',
    ['AdaptiveNodeDensity'] = 'Advanced',
    ['AdaptiveRockChoice'] = 'Advanced',
    ['AntiAFK'] = 'Settings',
    ['AutoBuffGift'] = 'Rewards',
    ['AutoBuyZones'] = 'Upgrades',
    ['AutoCashoutProgression'] = 'Home',
    ['AutoCharacterLevels'] = 'Upgrades',
    ['AutoChest'] = 'Home',
    ['AutoCompleteResearch'] = 'Upgrades',
    ['AutoCrafting'] = 'Advanced',
    ['AutoCrewSpeed'] = 'Upgrades',
    ['AutoEnchants'] = 'Rewards',
    ['AutoEquipOwnedPickaxes'] = 'Upgrades',
    ['AutoEventClaims'] = 'Rewards',
    ['AutoFocusSpecial'] = 'Advanced',
    ['AutoGear'] = 'Rewards',
    ['AutoIndex'] = 'Rewards',
    ['AutoJumpObstacles'] = 'Advanced',
    ['AutoMailbox'] = 'Rewards',
    ['AutoMinerMineSpeed'] = 'Upgrades',
    ['AutoPerformance'] = 'Settings',
    ['AutoPickaxes'] = 'Upgrades',
    ['AutoPotions'] = 'Rewards',
    ['AutoQuests'] = 'Rewards',
    ['AutoSellOre'] = 'Home',
    ['AutoSellMiners'] = 'Home',
    ['MinerKeepBestSpare'] = 'Advanced',
    ['MinerSellStrength'] = 'Advanced',
    ['AutoSkills'] = 'Upgrades',
    ['AutoSlots'] = 'Upgrades',
    ['AutoSpin'] = 'Rewards',
    ['AutoSummon'] = 'Rewards',
    ['AutoTapUpgrades'] = 'Upgrades',
    ['AutoTrialClaims'] = 'Rewards',
    ['AutoTrialRuns'] = 'Advanced',
    ['AutoZone'] = 'Upgrades',
    ['BudgetPercent'] = 'Advanced',
    ['CancelDeadRockWalk'] = 'Advanced',
    ['ChestPercent'] = 'Advanced',
    ['ChosenZone'] = 'Advanced',
    ['ColossusMaxSeconds'] = 'Advanced',
    ['CornerRecovery'] = 'Advanced',
    ['EfficientTrips'] = 'Advanced',
    ['EnableOwnedAutoSell'] = 'Rewards',
    ['EquipBest'] = 'Upgrades',
    ['FastLocalMining'] = 'Advanced',
    ['FasterScheduling'] = 'Advanced',
    ['FocusSpecialRocks'] = 'Advanced',
    ['KeepSummonScrolls'] = 'Advanced',
    ['Master'] = 'Home',
    ['MaxTapsPerRock'] = 'Advanced',
    ['MaxTargetTravel'] = 'Advanced',
    ['MaxWalkRetries'] = 'Advanced',
    ['MinSellValue'] = 'Advanced',
    ['Mine'] = 'Home',
    ['MineMode'] = 'Advanced',
    ['NativeTravel'] = 'Advanced',
    ['PickaxeMinTeamGain'] = 'Advanced',
    ['PickaxeMode'] = 'Upgrades',
    ['PickaxeReservePercent'] = 'Advanced',
    ['PickaxeSpendPercent'] = 'Advanced',
    ['PotionMode'] = 'Advanced',
    ['PotionReserve'] = 'Advanced',
    ['PowerAwareResearch'] = 'Advanced',
    ['PowerGateRescue'] = 'Upgrades',
    ['PowerRescueKeepCash'] = 'Advanced',
    ['PowerRescueLevels'] = 'Advanced',
    ['PowerRescueMaxPurchase'] = 'Advanced',
    ['PowerRescuePickaxes'] = 'Advanced',
    ['ResearchCashBoost'] = 'Advanced',
    ['RockLocalityBoost'] = 'Advanced',
    ['SmartResearchPriority'] = 'Advanced',
    ['SmartUpgradeSavings'] = 'Advanced',
    ['StuckTimeout'] = 'Advanced',
    ['TapInterval'] = 'Advanced',
    ['TrialMinPowerRatio'] = 'Advanced',
    ['UpgradeReserve'] = 'Advanced',
    ['UrgentFullChest'] = 'Advanced',
    ['WeatherAware'] = 'Rewards',
    ['ZoneBuyMode'] = 'Advanced',
    ['ZoneMaxRockSeconds'] = 'Advanced',
    ['ZoneMode'] = 'Advanced',
    ['ZoneSaveAt'] = 'Advanced',
    ['ZoneSaveForNext'] = 'Upgrades',
}
local function migrateProfileValues(values)
    if type(values) ~= "table" then return values end
    local migrated = table.clone(values)
    local originalTabs = {Home = true, Farm = true, Progress = true,
        Extras = true, Settings = true}
    for oldKey, value in pairs(values) do
        local oldTab, key = tostring(oldKey):match("^([%w_]+)%.([%w_]+)$")
        if oldTab and originalTabs[oldTab] and key and migratedTabForKey[key] then
            local newKey = migratedTabForKey[key] .. "." .. key
            if migrated[newKey] == nil then migrated[newKey] = value end
        end
    end
    return migrated
end
if window.Config and window.Config.AutoLoad and type(window.Config.LoadedValues) == "table" then
    window.Config.LoadedValues = migrateProfileValues(window.Config.LoadedValues)
end
local previousConfigApplier = window._ApplyConfigValues
if type(previousConfigApplier) == "function" then
    function window:_ApplyConfigValues(values)
        return previousConfigApplier(self, migrateProfileValues(values))
    end
end

-- Beginner-first interface: five clearly named tabs plus PuckUI's native Configs.
-- Advanced settings stay available, but are not mixed into everyday controls.
local homeTab = window:CreateTab("Home")
local upgradeTab = window:CreateTab("Upgrades")
local rewardTab = window:CreateTab("Rewards")
local settingsTab = window:CreateTab("Settings") -- PuckUI adds Interface controls
local advancedTab = window:CreateTab("Advanced") -- opt-in fine tuning
local controlSetters = {}
local controlCount = {}

local function register(key, control, toControl)
    assert(defaults[key] ~= nil, "Invalid config key: " .. tostring(key))
    assert(not controlSetters[key], "Duplicate config UI control: " .. key)
    controlCount[key] = (controlCount[key] or 0) + 1
    controlSetters[key] = function(value)
        if control and control.Set then
            local shown = toControl and toControl(value, true) or value
            control:Set(shown)
        else
            config[key] = value
        end
    end
    return control
end
local function toggle(tab, name, key)
    local control = tab:CreateToggle({
        Name = name, ConfigKey = key,
        CurrentValue = config[key], NoConfig = key == "Master",
        Callback = function(value)
            value = value == true
            config[key] = value
            if key == "Master" then
                if value then API.Start() else API.Stop() end
            elseif key == "Mine" and not value then
                cancelWalk()
            elseif key == "NativeTravel" then
                cancelWalk()
            end
        end,
    })
    if key == "Master" then masterToggle = control end
    return register(key, control)
end
local function slider(tab, name, key, minimum, maximum, step, converter)
    local control = tab:CreateSlider({
        Name = name, ConfigKey = key, Range = {minimum, maximum}, Increment = step,
        CurrentValue = converter and converter(config[key], true) or config[key],
        Callback = function(value)
            config[key] = converter and converter(value, false) or value
        end,
    })
    return register(key, control, converter)
end
local function dropdown(tab, name, key, options)
    local control = tab:CreateDropdown({
        Name = name, ConfigKey = key, Options = options,
        CurrentOption = {config[key]},
        Callback = function(value)
            local choice = type(value) == "table" and value[1] or value
            if type(choice) == "string" then config[key] = choice end
        end,
    })
    return register(key, control)
end
local function percent(v, toUI)
    return toUI and math.floor(v * 100 + 0.5) or v / 100
end
local function notify(title, message)
    pcall(function()
        PuckUI:Notify({Title = title, Content = message, Duration = 3})
    end)
end
local function setOption(key, value)
    if key == "Master" then return end -- No preset or profile unexpectedly starts the farm.
    if not validSetting(key, value) then return end
    -- Store immediately: PuckUI callbacks run via task.spawn and may be delayed.
    config[key] = value
    local apply = controlSetters[key]
    if apply then
        local ok, why = pcall(apply, value)
        if not ok then state.lastFailure = "Option " .. key .. ": " .. tostring(why) end
    end
end
local function applyPreset(name, changes)
    for key, value in pairs(changes) do setOption(key, value) end
    state.lastSuccess = "Preset " .. name
    notify("Settings applied", name .. " (farm start/pause unchanged)")
end

-- One-click fix for older profiles containing disabled default settings.
-- Purchases of Robux items never become enabled; crafting, trial running and
-- experimental crew focus remain opt-in. Potions/scrolls consume spare inventory.
local recommended = {
    Mine = true, AutoChest = true, AutoSellOre = true, AutoSellMiners = true,
    AutoCashoutProgression = true, EquipBest = true,
    AutoSkills = true, AutoCompleteResearch = true,
    AutoTapUpgrades = true, AutoSlots = true,
    AutoCharacterLevels = true, AutoCrewSpeed = true,
    AutoMinerMineSpeed = true,
    AutoPickaxes = true, AutoEquipOwnedPickaxes = true,
    EnableOwnedAutoSell = true, AutoZone = true, AutoBuyZones = true,
    ZoneSaveForNext = true, AutoSpin = true, AutoQuests = true,
    AutoIndex = true, AutoMailbox = true, AutoBuffGift = true,
    AutoEventClaims = true, AutoTrialClaims = true,
    AutoGear = true, AutoEnchants = true,
    AutoPotions = true, AutoSummon = true, AntiAFK = true,
    NativeTravel = true, EfficientTrips = true, UrgentFullChest = true,
    FastLocalMining = true, SmartUpgradeSavings = true,
    FasterScheduling = true, SmartResearchPriority = true,
    PowerGateRescue = true, PowerRescuePickaxes = true,
    PowerRescueLevels = true, PowerAwareResearch = true,
    AutoJumpObstacles = true, CornerRecovery = true,
    CancelDeadRockWalk = true, AdaptiveRockChoice = true,
    ResearchCashBoost = true, AdaptiveNodeDensity = true,
    FocusSpecialRocks = true, WeatherAware = true,
    AccurateMotherlode = true,
    AutoTrialRuns = false, AutoFocusSpecial = false,
    AutoCrafting = false, AutoPerformance = false,
    PickaxeMode = "Smart", MineMode = "Balanced",
    ZoneMode = "Highest unlocked", ZoneBuyMode = "Affordable",
}

-- HOME: less clutter, one important switch, recommended setup and live status.
homeTab:CreateSection("Start Farming")
homeTab:CreateParagraph({
    Title = "Automatic Mining & Progression",
    Content = "Turn on the switch below to mine, collect, sell, upgrade miners, buy better pickaxes, complete research and unlock zones.",
    Height = 68,
})
toggle(homeTab, "Start / Pause Autofarm", "Master")
homeTab:CreateLabel("Starts paused each time; your settings are saved.")
homeTab:CreateSection("Everyday Automation")
toggle(homeTab, "Mine Rocks", "Mine")
toggle(homeTab, "Collect Ore Chests", "AutoChest")
toggle(homeTab, "Sell Ores Automatically", "AutoSellOre")
toggle(homeTab, "Sell Weak Spare Miners", "AutoSellMiners")
toggle(homeTab, "Cash Out for Research / Zones", "AutoCashoutProgression")
homeTab:CreateSection("Recommended Setup")
homeTab:CreateButton({Name = "Enable All Recommended Features", Callback = function()
    applyPreset("Recommended automatic progression", recommended)
end})
homeTab:CreateButton({Name = "Faster Mining", Callback = function()
    applyPreset("Faster mining", {
        MineMode = "Fast", FastLocalMining = true, AdaptiveRockChoice = true,
        RockLocalityBoost = 1.9, MaxTargetTravel = 55,
        ChestPercent = 0.85, FasterScheduling = true,
    })
end})
homeTab:CreateButton({Name = "Save More Money", Callback = function()
    applyPreset("Save more money", {
        MineMode = "Balanced", PickaxeMode = "Conservative",
        PickaxeSpendPercent = 0.25, PickaxeReservePercent = 0.45,
        BudgetPercent = 0.12, UpgradeReserve = 0.35,
        ZoneSaveForNext = true, EfficientTrips = true,
    })
end})
homeTab:CreateLabel("Presets never start farming automatically.")
homeTab:CreateSection("Live Farm Status")
local homeFarmStatus = homeTab:CreateParagraph({
    Title = "Paused", Content = "Ready when you are. Turn on Start / Pause Autofarm.", Height = 58,
})
local homeProgressStatus = homeTab:CreateParagraph({
    Title = "Zone & Research", Content = "Waiting for player progression data.", Height = 58,
})
local homePurchaseStatus = homeTab:CreateParagraph({
    Title = "Purchases & Miner Upgrades", Content = "Waiting for automated progression.", Height = 58,
})
homeTab:CreateLabel("Detailed controls: Upgrades, Rewards, Advanced.")

-- UPGRADES: straightforward defaults for the recurring money and power loop.
upgradeTab:CreateSection("Research & Zones")
toggle(upgradeTab, "Complete Required Research", "AutoCompleteResearch")
upgradeTab:CreateLabel("Required research first; then unlock the zone. Optional upgrades wait.")
toggle(upgradeTab, "Unlock Next Zone", "AutoBuyZones")
toggle(upgradeTab, "Mine Best Unlocked Zone", "AutoZone")
toggle(upgradeTab, "Save Money for Next Zone", "ZoneSaveForNext")
toggle(upgradeTab, "Buy Useful Extra Research", "AutoSkills")
upgradeTab:CreateLabel("Research and zones always take spending priority.")
upgradeTab:CreateSection("Upgrade All Assigned Miners")
toggle(upgradeTab, "Upgrade Miner Damage", "AutoCharacterLevels")
toggle(upgradeTab, "Upgrade Miner Speed", "AutoCrewSpeed")
toggle(upgradeTab, "Upgrade Miner Mining Speed", "AutoMinerMineSpeed")
toggle(upgradeTab, "Equip Best Crew", "EquipBest")
upgradeTab:CreateLabel("Rotates fairly through your selected mining crew.")
upgradeTab:CreateSection("Pickaxes")
toggle(upgradeTab, "Auto Buy Better Pickaxes", "AutoPickaxes")
toggle(upgradeTab, "Equip Best Owned Pickaxes", "AutoEquipOwnedPickaxes")
dropdown(upgradeTab, "Pickaxe Buying", "PickaxeMode", {"Smart", "Conservative", "Aggressive"})
upgradeTab:CreateLabel("Stock, zone locks and cash reserves are respected.")
upgradeTab:CreateSection("Other Helpful Upgrades")
toggle(upgradeTab, "Buy More Miner Slots", "AutoSlots")
toggle(upgradeTab, "Upgrade Click Damage", "AutoTapUpgrades")
toggle(upgradeTab, "Overcome Research Power Gates", "PowerGateRescue")

-- REWARDS: mostly ON from the start; optional inventory-consuming tasks are labelled.
rewardTab:CreateSection("Claim Free Rewards")
toggle(rewardTab, "Free Daily Spins", "AutoSpin")
toggle(rewardTab, "Daily Quests", "AutoQuests")
toggle(rewardTab, "Index Rewards", "AutoIndex")
toggle(rewardTab, "Mailbox Rewards", "AutoMailbox")
toggle(rewardTab, "Free Buff Gifts", "AutoBuffGift")
toggle(rewardTab, "Event Rewards", "AutoEventClaims")
toggle(rewardTab, "Trial Milestone Rewards", "AutoTrialClaims")
rewardTab:CreateSection("Owned Equipment")
toggle(rewardTab, "Equip Best Gear", "AutoGear")
toggle(rewardTab, "Equip Owned Enchants", "AutoEnchants")
toggle(rewardTab, "Use Owned Auto Sell Pass", "EnableOwnedAutoSell")
rewardTab:CreateLabel("Does not purchase any gamepasses or Robux items.")
rewardTab:CreateSection("Useful Extras")
toggle(rewardTab, "Use Spare Potions", "AutoPotions")
toggle(rewardTab, "Use Spare Summon Scrolls", "AutoSummon")
toggle(rewardTab, "React to Weather", "WeatherAware")
rewardTab:CreateLabel("Potions and scrolls use your inventory, with reserves.")

-- SETTINGS: anti-afk, performance, profile guidance and essential safety controls.
settingsTab:CreateSection("AFK & Performance")
toggle(settingsTab, "Prevent AFK Disconnect", "AntiAFK")
toggle(settingsTab, "Reduce Heavy Visual Effects", "AutoPerformance")
settingsTab:CreateLabel("Anti-AFK also works while farming is paused.")
settingsTab:CreateSection("Saving Your Settings")
settingsTab:CreateParagraph({
    Title = "Profiles Save Automatically",
    Content = "Use the Configs tab for save, load, new profiles and Auto Save / Auto Load. Older saved profiles can override these new recommended defaults.",
    Height = 68,
})
settingsTab:CreateLabel("Use Home > Enable All Recommended Features to refresh an old profile.")
settingsTab:CreateSection("Executor Config Backup")
local storeStatus = settingsTab:CreateLabel("Checking persistent settings...")
local function updateStoreStatus()
    local native = window.Config and window.Config.Available
    local disk = compatStore.read and compatStore.write
    local message = native and "PuckUI profiles + portable backup"
        or (disk and "Portable file backup (partial executor APIs)"
        or "Session-only settings (no file persistence)")
    if compatStore.lastError then message = message .. " | " .. tostring(compatStore.lastError) end
    if storeStatus and storeStatus.Set then
        pcall(function() storeStatus:Set(message) end)
    end
end
settingsTab:CreateLabel("Portable file: " .. COMPAT_PATH)
settingsTab:CreateLabel("Session-only means settings may be lost when the executor closes.")
settingsTab:CreateButton({Name = "Save Config Now", Callback = function()
    local saved = saveCompatSettings(true)
    local native = window.Config
    if native and native.Available and type(window._WriteConfig) == "function" then
        pcall(function() window:_WriteConfig(native.Selected, false) end)
    end
    updateStoreStatus()
    notify("Config", saved and "Saved and verified portable backup"
        or "Session backup only: " .. tostring(compatStore.lastError))
end})
settingsTab:CreateButton({Name = "Reload Portable Backup", Callback = function()
    local values = readSettingsFile(COMPAT_PATH)
        or readSettingsFile(COMPAT_PATH .. ".bak")
    if not values then
        notify("Config", "No readable portable backup found.")
        return
    end
    local count = 0
    for key in pairs(defaults) do
        if validSetting(key, values[key]) then
            setOption(key, values[key])
            count += 1
        end
    end
    config.Master = false
    if masterToggle then pcall(function() masterToggle:Set(false) end) end
    notify("Config restored", tostring(count) .. " settings loaded (farm paused).")
    updateStoreStatus()
end})
local importJSON = ""
settingsTab:CreateInput({Name = "Import JSON", CurrentValue = "",
    PlaceholderText = "Paste exported config JSON", NoConfig = true,
    Callback = function(value) importJSON = tostring(value or "") end})
settingsTab:CreateButton({Name = "Apply Imported JSON", Callback = function()
    local ok, decoded = pcall(function() return HttpService:JSONDecode(importJSON) end)
    local values = ok and type(decoded) == "table"
        and (type(decoded.Values) == "table" and decoded.Values or decoded) or nil
    if not values then
        notify("Config", "Invalid JSON. Paste an exported settings JSON object.")
        return
    end
    local count = 0
    for key in pairs(defaults) do
        if validSetting(key, values[key]) then
            setOption(key, values[key])
            count += 1
        end
    end
    API.Stop()
    notify("Config imported", tostring(count) .. " settings applied (farm paused).")
end})
settingsTab:CreateButton({Name = "Export Config JSON", Callback = function()
    local ok, json = pcall(function()
        return HttpService:JSONEncode({Version = 2, Values = snapshotSettings()})
    end)
    if not ok then notify("Config", "Unable to encode settings.") return end
    local copy = type(setclipboard) == "function" and setclipboard
        or type(toclipboard) == "function" and toclipboard or nil
    if copy then
        local copied = pcall(copy, json)
        if copied then notify("Config", "Settings JSON copied to clipboard.") return end
    end
    print("[PuckAFK Mine] CONFIG JSON: " .. json)
    notify("Config", "No clipboard API. JSON printed to executor console.")
end})
updateStoreStatus()
settingsTab:CreateSection("Stop or Reset")
local resetArmedUntil = 0
settingsTab:CreateButton({Name = "Restore Defaults (press twice)", Callback = function()
    if os.clock() > resetArmedUntil then
        resetArmedUntil = os.clock() + 10
        notify("Confirm reset", "Press again within 10 seconds. Farming state is unchanged.")
        return
    end
    resetArmedUntil = 0
    for key, value in pairs(defaults) do
        if key ~= "Master" then setOption(key, value) end
    end
    notify("Defaults restored", "Recommended defaults restored. Start/pause unchanged.")
end})
settingsTab:CreateButton({Name = "Stop and Unload Script", Callback = API.Unload})
settingsTab:CreateLabel("The Interface section above controls UI size and hide key.")

-- ADVANCED: granular tuning only for users who want to customise the automation.
advancedTab:CreateSection("Mining Strategy")
dropdown(advancedTab, "Rock Choice", "MineMode", {"Balanced", "Fast", "Value", "Rare loot"})
toggle(advancedTab, "Prioritise Nearby Rocks", "FastLocalMining")
toggle(advancedTab, "Adaptive Target Choice", "AdaptiveRockChoice")
toggle(advancedTab, "Prioritise Special Rocks", "FocusSpecialRocks")
toggle(advancedTab, "Research-Adjusted Motherlodes", "AccurateMotherlode")
slider(advancedTab, "Nearby Rock Preference (%)", "RockLocalityBoost", 100, 200, 10, percent)
slider(advancedTab, "Maximum Hits per Rock", "MaxTapsPerRock", 8, 100, 1)
slider(advancedTab, "Click Interval (game-limited)", "TapInterval", 1.2, 3.0, 0.1)
slider(advancedTab, "Colossus Time Limit (sec)", "ColossusMaxSeconds", 15, 180, 5)
advancedTab:CreateSection("Chest & Selling")
slider(advancedTab, "Keep Best Spare Miner Stacks", "MinerKeepBestSpare", 0, 10, 1)
slider(advancedTab, "Sell Miners Below Crew Power (%)", "MinerSellStrength", 10, 100, 5, percent)
advancedTab:CreateLabel("Protects assigned crew, haulers, unsellable rarities and strongest backups.")
toggle(advancedTab, "Avoid Unnecessary Seller Trips", "EfficientTrips")
toggle(advancedTab, "Empty a Full Chest Immediately", "UrgentFullChest")
slider(advancedTab, "Collect Chest When Full (%)", "ChestPercent", 20, 95, 5, percent)
slider(advancedTab, "Minimum Ore Sale Value", "MinSellValue", 0, 100000, 1000)
advancedTab:CreateSection("Movement & Recovery")
toggle(advancedTab, "Jump Small Obstacles", "AutoJumpObstacles")
toggle(advancedTab, "Reroute Around Walls", "CornerRecovery")
toggle(advancedTab, "Stop Moving When Rock Breaks", "CancelDeadRockWalk")
toggle(advancedTab, "Use In-Game Hub Travel", "NativeTravel")
slider(advancedTab, "Maximum Rock Travel Distance", "MaxTargetTravel", 25, 140, 5)
slider(advancedTab, "Route Retry Limit", "MaxWalkRetries", 1, 5, 1)
slider(advancedTab, "Stuck Detection (sec)", "StuckTimeout", 0.7, 2, 0.05)
advancedTab:CreateLabel("Only MoveTo, native teleport and pathfinding; no tween.")
advancedTab:CreateSection("Pickaxe Spending")
slider(advancedTab, "Pickaxe Max Spend (%)", "PickaxeSpendPercent", 10, 90, 5, percent)
slider(advancedTab, "Pickaxe Money Reserve (%)", "PickaxeReservePercent", 0, 80, 5, percent)
slider(advancedTab, "Minimum Team Power Gain (%)", "PickaxeMinTeamGain", 0, 20, 1, percent)
advancedTab:CreateSection("Zone & Research Priorities")
toggle(advancedTab, "Prioritise Affordable Research", "SmartResearchPriority")
advancedTab:CreateLabel("Hard priority: required research > next zone > ordinary upgrades.")
toggle(advancedTab, "Respect Research Power Requirements", "PowerAwareResearch")
toggle(advancedTab, "Buy Pickaxes to Unblock Research", "PowerRescuePickaxes")
toggle(advancedTab, "Level Miners to Unblock Research", "PowerRescueLevels")
toggle(advancedTab, "Improve Mining During Cash Wait", "ResearchCashBoost")
toggle(advancedTab, "Buy Useful Node Density", "AdaptiveNodeDensity")
toggle(advancedTab, "Smart Small-Upgrade Savings", "SmartUpgradeSavings")
dropdown(advancedTab, "Zone Unlock Condition", "ZoneBuyMode", {"Affordable", "Power ready"})
dropdown(advancedTab, "Zone Farming Selection", "ZoneMode", {"Highest unlocked", "Selected zone"})
slider(advancedTab, "Chosen Zone", "ChosenZone", 1, 12, 1)
slider(advancedTab, "Overall Upgrade Spend (%)", "BudgetPercent", 5, 80, 5, percent)
slider(advancedTab, "Overall Cash Reserve (%)", "UpgradeReserve", 0, 60, 5, percent)
slider(advancedTab, "Save For Zone At (%)", "ZoneSaveAt", 10, 95, 5, percent)
slider(advancedTab, "Power Rescue: Max Spend (%)", "PowerRescueMaxPurchase", 5, 45, 5, percent)
slider(advancedTab, "Power Rescue: Cash Kept (%)", "PowerRescueKeepCash", 15, 80, 5, percent)
slider(advancedTab, "Max Zone Rock Time (sec)", "ZoneMaxRockSeconds", 15, 180, 5)
advancedTab:CreateSection("Potions, Scrolls & Trials")
dropdown(advancedTab, "Potion Preference", "PotionMode", {"Balanced", "Cash", "Rare finds", "Power"})
slider(advancedTab, "Keep These Potions", "PotionReserve", 0, 15, 1)
slider(advancedTab, "Keep These Summon Scrolls", "KeepSummonScrolls", 0, 30, 1)
slider(advancedTab, "Trial Power Safety Margin", "TrialMinPowerRatio", 1, 10, 0.5)
toggle(advancedTab, "Run Trials (optional)", "AutoTrialRuns")
advancedTab:CreateSection("Experimental & Technical")
toggle(advancedTab, "Automatically Craft (optional)", "AutoCrafting")
toggle(advancedTab, "Experimental Crew Focus", "AutoFocusSpecial")
toggle(advancedTab, "Fast Scheduling", "FasterScheduling")
advancedTab:CreateLabel("Experimental systems remain OFF by default.")

-- Keep a compact status display, without the high-frequency old diagnostics UI.
local function shortText(value, limit)
    local message = tostring(value or "")
    limit = limit or 130
    if #message > limit then return message:sub(1, limit - 3) .. "..." end
    return message
end
local function shortCash(value)
    local n = math.max(0, tonumber(value) or 0)
    local labels = {"", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc"}
    local step = 1
    while n >= 1000 and step < #labels do
        n /= 1000
        step += 1
    end
    if n >= 1000 then return string.format("%.2e", n * 1000 ^ (step - 1)) end
    if n >= 100 then return string.format("%.0f%s", n, labels[step]) end
    return string.format("%.1f%s", n, labels[step])
end
-- Updating only on changes reduces redraws while mining runs.
task.spawn(function()
    local previousFarm, previousProgress, previousPurchase
    while state.alive do
        local data, mg = getMine()
        local farmTitle = config.Master and "Farming Running" or "Farming Paused"
        local farmText = config.Master
            and ("Activity: " .. shortText(state.target or "Choosing rock", 94))
            or "Ready. Use Start / Pause Autofarm above to begin."
        if config.Master and (not data or not mg) then
            farmText = "Waiting for mine data from the game."
        end
        local farmStamp = farmTitle .. ":" .. farmText
        if farmStamp ~= previousFarm then
            pcall(function() homeFarmStatus:Set({Title = farmTitle, Content = farmText}) end)
            previousFarm = farmStamp
        end
        local progressText = "Waiting for mine data."
        if mg then
            local nextZone, nextCost = nextZoneFromSave(mg)
            local gate, done, needed, completed = zoneResearchStatus(mg, nextZone)
            if nextZone then
                local howFar = needed > 0 and math.floor(done / needed * 100) or (completed and 100 or 0)
                local milestone = completed and ("Unlock " .. nextZone .. ": $" .. shortCash(nextCost))
                    or ("Research " .. tostring(gate or "?") .. " " .. tostring(howFar) .. "%")
                progressText = milestone .. " | Money $" .. shortCash(data and data.Money)
            else
                progressText = "All available zones unlocked | Money $" .. shortCash(data and data.Money)
            end
        end
        if progressText ~= previousProgress then
            pcall(function() homeProgressStatus:Set({Title = "Zone & Research", Content = progressText}) end)
            previousProgress = progressText
        end
        local purchaseText = shortText(state.pickaxeStatus or "Monitoring shop", 62)
            .. "\n" .. shortText(state.minerStatsStatus or "Monitoring assigned miners", 65)
        if purchaseText ~= previousPurchase then
            pcall(function() homePurchaseStatus:Set({Title = "Pickaxes & Miner Levels", Content = purchaseText}) end)
            previousPurchase = purchaseText
        end
        task.wait(2.5)
    end
end)

-- Portable backup watches actual config (not UI-only percent slider values).
-- Native PuckUI profiles remain available on executors with full file APIs.
task.spawn(function()
    task.wait(1.8) -- allow PuckUI's deferred profile autoload to finish first
    compatStore.lastSaved = nil
    while state.alive do
        if configSaveAllowed(API.Window) then
            local live = snapshotSettings()
            if settingsChanged(live, compatStore.lastSaved)
                and os.clock() - compatStore.lastAttempt >= 2.0 then
                pcall(saveCompatSettings, false)
            end
        end
        task.wait(1.5)
    end
end)

-- Simplified Home, Upgrades, Rewards, Settings and Advanced tabs; PuckUI owns Configs.
-- All launched tasks are tied to the lifetime of this API object.
task.spawn(function()
    while state.alive do
        if config.Master then
            pcall(maintenance)
        end
        task.wait(config.FasterScheduling and 0.42 or 0.75)
    end
end)
task.spawn(function()
    local ok = pcall(farmLoop)
    if not ok then API.Stop() end
end)
