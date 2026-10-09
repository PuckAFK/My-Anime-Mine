
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
    EquipBest = true,
    AutoSkills = true,
    AutoCompleteResearch = true,
    AutoTapUpgrades = true,
    AutoSlots = true,
    AutoCharacterLevels = true,
    AutoCrafting = false,
    AutoPickaxes = false,
    AutoEquipOwnedPickaxes = true,
    EnableOwnedAutoSell = false,
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
    AutoPotions = false, PotionMode = "Balanced", PotionReserve = 2,
    AutoEnchants = true,
    AutoPerformance = false,
    FocusSpecialRocks = true, WeatherAware = true,
    KeepSummonScrolls = 2,
    ColossusMaxSeconds = 45, UpgradeReserve = 0.18,
    AutoSummon = false,
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
local function settingsSafe()
    return type(isfile) == "function" and type(readfile) == "function" and type(writefile) == "function"
end
local function loadSettings()
    if not settingsSafe() then return end
    local ok, val = pcall(function()
        if isfile(CFG_PATH) then return HttpService:JSONDecode(readfile(CFG_PATH)) end
    end)
    if ok and type(val) == "table" then
        for key, default in pairs(defaults) do
            if type(val[key]) == type(default) then config[key] = val[key] end
        end
    end
    -- Never unexpectedly resume auto-walking on an executor restart.
    config.Master = false
end
-- Backward-compatibility: import v1.x settings if present, without changing
-- the old file. Named profiles are now exclusively written by PuckUI Configs.
loadSettings()

local state = {
    alive = true, walkEpoch = 0, walking = false,
    target = "None", plot = nil,
    oreSales = 0, rocksMined = 0, chests = 0, steps = 0,
    lastChest = -100, lastSell = -100, lastEquip = -100,
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

local function affordable(data, cost, spendingKind)
    cost = tonumber(cost)
    if not cost or cost <= 0 or cost == math.huge then return false end
    local cash = moneyAvailable(data)
    if config.AutoBuyZones and config.AutoCompleteResearch then
        local mg = data and data.MineGame
        local nextKey = nextZoneFromSave(mg)
        if nextKey then
            local _, _, _, ready = zoneResearchStatus(mg, nextKey)
            if not ready then
                -- A power-locked research node cannot be solved by buying more
                -- research: we must first improve EQUIPPED team damage.
                -- Only power-increasing purchases may use this narrow budget.
                if spendingKind == "TeamPower" and config.PowerGateRescue
                    and state.rescueActive then
                    local minKeep = math.clamp(config.PowerRescueKeepCash, 0, 0.90)
                    local maxSingle = math.clamp(config.PowerRescueMaxPurchase, 0.01, 0.80)
                    return cash >= cost and cost <= cash * maxSingle
                        and cash - cost >= cash * minKeep
                end
                return false
            end
        end
    end
    if config.AutoBuyZones and config.ZoneSaveForNext then
        local mg = data and data.MineGame
        local nextKey, zoneCost = nextZoneFromSave(mg)
        local _, _, _, researchReady = zoneResearchStatus(mg, nextKey)
        if nextKey and researchReady and zoneCost and cash >= zoneCost * math.clamp(config.ZoneSaveAt, 0.05, 0.95) then
            -- Save aggressively near the unlock, but don't trap new players with
            -- weak miners at only 30% of an expensive next-zone price.
            if not config.SmartUpgradeSavings or cash >= zoneCost * 0.83 then
                return false
            end
            local current = mg and MineConfig.Zones and MineConfig.Zones[mg.CurrentZone or "Z1"]
            local baseHp = current and tonumber(current.NodeBaseHealth) or nil
            local power = math.max(1, tonumber((mg.Stats or {}).TotalPower) or 0)
            -- A weak setup may invest only a small portion of saved cash.
            -- More expensive upgrades wait for the next zone unlock.
            if not (baseHp and baseHp > 0 and (power < baseHp / 18)
                and cost <= cash * 0.055) then
                return false
            end
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
local function collectChest(plot, mg, epoch, force)
    if not config.AutoChest then return false end
    local full = config.UrgentFullChest and plot and plot:GetAttribute("MineChestFull") == true
    -- A full chest can stall the crew; prefer a prompt retry, but never
    -- hammer a failing collection action every scheduler tick.
    local minimumInterval = full and 5 or 16
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
    local ok = sendConfirmed("MineTakeChest", function(_, fresh)
        return fresh and totalChestCount(getChestEntries(fresh)) < amount
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
local function sellOre(mg, epoch, force)
    if not config.AutoSellOre or os.clock() - state.lastSellAttempt < 30 then return false end
    local keys, worth = sellableOre(mg)
    if #keys == 0 then return false end
    local cash = moneyAvailable(select(1, getMine()))
    local researchReady = config.AutoCompleteResearch and state.researchTotal > state.researchCurrent
        and state.researchNextCost > cash and cash + worth >= state.researchNextCost
    if not force and not researchReady and worth < math.max(config.MinSellValue, cash * 0.012)
        and os.clock() - state.lastSell < 150 then return false end
    if config.EfficientTrips and not force then
        local _,fresh = getMine()
        local zoneKey, zoneCost = nextZoneFromSave(fresh or mg)
        -- Sell immediately when the ore itself funds an unlocked cash zone.
        local _, _, _, gateComplete = zoneResearchStatus(fresh or mg, zoneKey)
        local zoneReady = zoneKey and gateComplete and zoneCost and cash < zoneCost and cash + worth >= zoneCost
        -- Don't save a journey if liquidating ore immediately pays for an
        -- important mining-damage upgrade; that would slow progression.
        local tapDef = MineConfig.CoreUpgradeById and MineConfig.CoreUpgradeById.Tap
        local tapLevel = tonumber((fresh or mg).TapLevel) or 1
        local tapCost = config.AutoTapUpgrades and tapDef and tapLevel < tapDef.Max
            and tapDef.Cost(tapLevel) or nil
        local tapReady = tapCost and cash < tapCost and cash + worth >= tapCost
        -- If chest needs collecting soon, batch one seller trip with that trip.
        local chestEntries = getChestEntries(fresh or mg)
        local capacity = tonumber(MineConfig.GetChestCapacityFor(fresh or mg, 0)) or 0
        local chestCount = totalChestCount(chestEntries)
        local chestSoon = config.AutoChest and capacity > 0 and chestCount >= capacity * 0.63
        local enoughCashValue = worth >= math.max(config.MinSellValue, cash * 0.055)
        local maxWaitReached = os.clock() - state.lastSell > 165
        local recentTrip = os.clock() - state.lastActualSell < (config.FasterScheduling and 50 or 65)
        if not researchReady and not zoneReady and not tapReady and not chestSoon and not maxWaitReached and (not enoughCashValue or recentTrip) then

            return false
        end
    end
    state.lastSellAttempt = os.clock()

    if config.NativeTravel then teleportGame("Hub", epoch) end
    local seller = findSeller()
    local pos = positionOf(seller)
    if not pos then state.lastFailure="SellStand not loaded"; return false end
    local prompt = seller:FindFirstChild("SellPrompt", true)
    local reach = prompt and math.min(8.0, math.max(5.5, prompt.MaxActivationDistance)) or 8
    if not standAround(pos, reach, epoch, "Seller", seller) then
        state.lastFailure = "Seller navigation blocked"
        return false
    end
    local sold = sendConfirmed("MineSellItems", function(_, fresh)
        if not fresh then return false end
        local _, newWorth = sellableOre(fresh)
        return newWorth < worth
    end, 3.2, keys)
    if sold then

        state.lastSell = os.clock()
        state.lastActualSell = state.lastSell
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

local function researchTick(data, mg)
    if not config.AutoBuyZones or not config.AutoCompleteResearch then return false end
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
        state.rescueActive = config.PowerGateRescue and affordableCandidate == nil
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
local function pickaxeTick(data, mg)
    local rescue = config.PowerGateRescue and config.PowerRescuePickaxes and state.rescueActive
    if not (config.AutoPickaxes or rescue) then return nil end
    if os.clock() - state.lastPickaxe < (rescue and 2.6 or 18) then return nil end
    local cash = moneyAvailable(data)
    local unlocked = mg.UnlockedZones or {}
    local holders = mg.Holders or {}
    local unused = {}
    for name, count in pairs(mg.Pickaxes or {}) do
        if tonumber(count) and count > 0 then
            local _, _, spare = MineConfig.GetPickaxeStock(mg, name)
            local definition = MineConfig.GetPickaxeByName(name)
            if (tonumber(spare) or 0) > 0 and definition then
                unused[#unused+1] = tonumber(definition.Multiplier) or 1
            end
        end
    end
    local bestIndex, bestName, bestScore, bestGain, bestCost
    for index, def in ipairs(MineConfig.Pickaxes or {}) do
        local cost = tonumber(def.Cost)
        local newMult = tonumber(def.Multiplier) or 0
        local requiredZone = tostring(def.ZoneReq or "Z1")
        if not def.RobuxOnly and cost and cost > 0
            and unlocked[requiredZone] == true
            and affordable(data, cost, rescue and "TeamPower" or nil) then
            local remaining = MineStock.GetRemaining(data, def.Name)
            if remaining == nil or tonumber(remaining) and tonumber(remaining) > 0 then
                for holderKey, holder in pairs(holders) do
                    if type(holder) == "table" and type(holder.CharName) == "string" then
                        local item = Items.GetItemData(holder.CharName)
                        if item and item.Type == "Character" and item.MineRole ~= "Hauler" then
                            local current = MineConfig.GetHolderPickaxe(holder)
                            local oldMult = math.max(1, tonumber(current and current.Multiplier) or 1)
                            if newMult > oldMult then
                                -- Before shopping, equip better inventory gear
                                -- already owned and unassigned; no duplicates.
                                local spareBetter = false
                                for _, have in ipairs(unused) do
                                    if have >= newMult then spareBetter = true; break end
                                end
                                if not spareBetter then
                                    local curDamage = tonumber(MineConfig.GetHolderDamage(holder, item)) or 0
                                    local enchant = tonumber(MineConfig.GetEnchantPowerMult(mg, holderKey)) or 1
                                    local gain = math.max(0, curDamage * enchant * (newMult / oldMult - 1))
                                    -- When wealthy, prioritise big power gains
                                    -- instead of wasting restock windows buying
                                    -- weak tools merely because they're cheap.
                                    -- When cash is tight, penalise expensive buys.
                                    local budgetScale = math.max(1, cash * 0.02)
                                    local score = gain / (1 + cost / budgetScale)
                                    if gain > 0 and (not bestScore or score > bestScore) then
                                        bestScore, bestGain, bestIndex, bestName, bestCost = score, gain, index, def.Name, cost
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    if not bestIndex then
        if rescue then state.rescueState = "Waiting for affordable available team-power upgrades / shop restock" end
        return nil
    end
    state.lastPickaxe = os.clock()
    local previous = tonumber(MineConfig.GetPickaxeStock(mg, bestName)) or 0
    if sendConfirmed("MineBuyPickaxe", function(_, fresh)
        return fresh and (tonumber(MineConfig.GetPickaxeStock(fresh, bestName)) or 0) > previous
    end, 2.0, bestIndex) then
        if rescue then

            state.rescueState = string.format("Purchased %s; estimated +%.3g power when equipped", bestName, bestGain)
        end
        state.lastPickaxeEquip = -100
        return "Purchased " .. bestName .. " (next: equip on strongest miner)"
    end
end

local function characterLevelsTick(data, mg)
    if not config.AutoCharacterLevels then return nil end
    local bestKey, bestScore
    for key, holder in pairs(mg.Holders or {}) do
        if type(holder) == "table" and type(holder.CharName) == "string" then
            local item = Items.GetItemData(holder.CharName)
            if item and item.Type == "Character" and item.MineRole ~= "Hauler" then
                local current = MineConfig.GetHolderLevel(holder)
                local cap = MineConfig.GetCharLevelCap(mg, key, holder, item, Items.GetItemData)
                if current < cap then
                    local cost = MineConfig.GetCharacterUpgradeCost(current, item)
                    if affordable(data, cost, config.PowerRescueLevels and "TeamPower" or nil) then
                        local base = MineConfig.GetHolderBaseDamage(holder, item)
                        local pick = MineConfig.GetHolderPickaxe(holder)
                        local mult = (pick and pick.Multiplier) or 1
                        local before = MineConfig.GetCharacterLevelMultiplier(current)
                        local after = MineConfig.GetCharacterLevelMultiplier(current + 1)
                        local gain = math.max(0, base * mult * (after - before))
                        local score = math.log10(1 + gain) / (2 + math.log10(math.max(1, cost)))
                        if not bestScore or score > bestScore then bestScore, bestKey = score, key end
                    end
                end
            end
        end
    end
    if bestKey then
        local old = MineConfig.GetHolderLevel((mg.Holders or {})[bestKey])
        if sendConfirmed("MineUpgradeCharacter", function(_, fresh)
            local holder = fresh and (fresh.Holders or {})[bestKey]
            return holder and MineConfig.GetHolderLevel(holder) > old
        end, 2.4, bestKey) then
            if state.rescueActive then state.rescueCharacterBuys += 1 end
            return "Upgraded holder " .. tostring(bestKey)
        end
    end
end

local function craftTick(data, mg)
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
    local function speedUpgrade(data, mg)
        if not config.AutoCrewSpeed or not ready("speedCheck", 13) then return false end
        local bestKey, bestType, bestScore, bestLevel
        for holderKey, holder in pairs(mg.Holders or {}) do
            if type(holder) == "table" and type(holder.CharName) == "string" then
                local item = Items.GetItemData(holder.CharName)
                if item and item.Type == "Character" and item.MineRole ~= "Hauler" then
                    for _, kind in ipairs({"Speed", "MineSpeed"}) do
                        local level = kind == "Speed" and safe(MineConfig.GetHolderSpeedLevel, holder)
                            or safe(MineConfig.GetHolderMineSpeedLevel, holder)
                        local cost = kind == "Speed" and safe(MineConfig.GetCharacterSpeedUpgradeCost, level, item)
                            or safe(MineConfig.GetCharacterMineSpeedUpgradeCost, level, item)
                        local maxLevel = kind == "Speed" and MineConfig.CharSpeedMaxLevel
                            or MineConfig.CharMineSpeedMaxLevel
                        if level and maxLevel and level < maxLevel and affordable(data, cost) then
                            local benefit = kind == "MineSpeed" and 1.7 or 1.0
                            local score = benefit / (1 + math.log10(math.max(1, cost)))
                            if not bestScore or score > bestScore then
                                bestScore, bestKey, bestType, bestLevel = score, holderKey, kind, level
                            end
                        end
                    end
                end
            end
        end
        if bestKey then
            local old = bestLevel
            return doClaim("MineUpgradeCharacter", function(_, fresh)
                local h = fresh and (fresh.Holders or {})[bestKey]
                local current = h and (bestType == "Speed" and safe(MineConfig.GetHolderSpeedLevel, h)
                    or safe(MineConfig.GetHolderMineSpeedLevel, h))
                return current and current > old
            end, bestKey, bestType)
        end
        return false
    end
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
    return {Tick = tick, SpeedUpgrade = speedUpgrade}
end)()

-- Throughput improvements based on native game mechanics. No new movement owner.
local Accelerator = (function()
    local lastOwnSellAttempt = -100
    local lastPickEquip = -100
    local function availablePickaxes(mg)
        local owned = {}
        for name, count in pairs(mg.Pickaxes or {}) do
            if (tonumber(count) or 0) > 0 then
                local def = MineConfig.GetPickaxeByName(name)
                local _,_,unused = MineConfig.GetPickaxeStock(mg, name)
                if def and (tonumber(unused) or 0) > 0 then
                    table.insert(owned, {name=name, multiplier=tonumber(def.Multiplier) or 1})
                end
            end
        end
        table.sort(owned,function(a,b) return a.multiplier > b.multiplier end)
        return owned
    end
    local function equipBestOwnedPickaxe(mg)
        if not config.AutoEquipOwnedPickaxes or os.clock()-lastPickEquip < (state.rescueActive and 1.0 or 4.5) then return end
        local available = availablePickaxes(mg)
        if #available==0 then return end
        local chosenKey, chosenName, chosenGain
        for holderKey, holder in pairs(mg.Holders or {}) do
            if type(holder)=="table" and type(holder.CharName)=="string" then
                local item=Items.GetItemData(holder.CharName)
                if item and item.Type=="Character" and item.MineRole~="Hauler" then
                    local current = MineConfig.GetHolderPickaxe(holder)
                    local currentMult = tonumber(current and current.Multiplier) or 1
                    for _,tool in ipairs(available) do
                        if tool.multiplier>currentMult+0.001 then
                            local base=tonumber(MineConfig.GetHolderBaseDamage(holder,item)) or 0
                            local gain=base*(tool.multiplier-currentMult)
                            if gain>0 and (not chosenGain or gain>chosenGain) then
                                chosenGain,chosenKey,chosenName=gain,holderKey,tool.name
                            end
                        end
                    end
                end
            end
        end
        if not chosenKey then return end
        lastPickEquip=os.clock()
        local okay=sendConfirmed("MineEquipPickaxe",function(_,fresh)
            local holder=fresh and fresh.Holders and fresh.Holders[chosenKey]
            return holder and holder.Pickaxe==chosenName
        end,2.0,chosenKey,chosenName)
        if okay then

            state.lastSuccess="Optimised owned pickaxe "..tostring(chosenName)
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
        local routines = {skillTick, characterLevelsTick, buySlotOrTap, pickaxeTick, craftTick, Advanced.SpeedUpgrade}
        -- Rotate successful spend categories so cheap skills cannot starve
        -- miner speed, miner levels, tap damage or extra normal slots.
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
        if config.AutoChest and chestCount > 0
            and (chestFull or capacity <= 0 or chestCount / math.max(1, capacity) >= config.ChestPercent
                or os.clock() - state.lastChest > 115) then
            local ok, result = pcall(collectChest, plot, mg, epoch, true)
            if not ok then state.lastFailure = "Chest: " .. tostring(result) end
            lastActionSucceeded = ok and result
        end
        if not lastActionSucceeded and config.AutoSellOre then
            local ok, result = pcall(sellOre, mg, epoch, false)
            if not ok then state.lastFailure = "Seller: " .. tostring(result) end
            lastActionSucceeded = ok and result
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
    -- Native PuckUI Configs manages profiles. Preserve the old v1 settings file for migration.
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
env.PuckAFK_MyAnimeMine = API

table.insert(state.connections, Player.CharacterAdded:Connect(function()
    cancelWalk()
    state.plot = nil
    task.wait(1)

end))

local okUI, PuckUI = pcall(function()
    if type(loadstring) ~= "function" then error("Executor does not implement loadstring") end
    return loadstring(game:HttpGet("https://raw.githubusercontent.com/PuckAFK/Puck-Loader/refs/heads/main/ui/PuckUI.lua"))()
end)
if not okUI or type(PuckUI) ~= "table" then
    API.Unload()
    error("[PuckAFK Mine] Could not load PuckUI: " .. tostring(PuckUI))
end

-- A concise home screen, dedicated advanced controls and native PuckUI profiles.
-- ConfigId remains stable between script versions. Existing v1.9 JSON is
-- imported only as the initial fallback when no PuckUI profile is available.
local window = PuckUI:CreateWindow({
    Name = "PuckAFK | My Anime Mine",
    LoadingTitle = "My Anime Mine",
    LoadingSubtitle = "One-click smart farming",
    Width = 560, Height = 520,
    ConfigId = "MyAnimeMine",
    Configs = {DefaultProfile = "default", AutoSave = true, AutoLoad = true},
})
API.Window = window
-- If the user disabled profile auto-loading, truly start with defaults.
if window.Config and window.Config.Available and window.Config.AutoLoad == false then
    for key, value in pairs(defaults) do config[key] = value end
    config.Master = false
end

local homeTab = window:CreateTab("Home")
local farmTab = window:CreateTab("Farm")
local progressTab = window:CreateTab("Progress")
local extrasTab = window:CreateTab("Extras")
local settingsTab = window:CreateTab("Settings") -- PuckUI injects keybind, scale and Configs tab
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
        PuckUI:Notify({Title=title, Content=message, Duration=3})
    end)
end
local function setOption(key, value)
    if key == "Master" then return end -- Never start through profile/preset changes.
    local apply = controlSetters[key]
    if apply then
        local ok, why = pcall(apply, value)
        if not ok then state.lastFailure = "Option " .. key .. ": " .. tostring(why) end
    elseif defaults[key] ~= nil and type(value) == type(defaults[key]) then
        config[key] = value
    end
end
local function applyPreset(name, changes)
    for key, value in pairs(changes) do setOption(key, value) end
    state.lastSuccess = "Preset " .. name
    notify("Preset applied", name .. "; farming start/pause was not changed")
end

homeTab:CreateSection("Quick start")
homeTab:CreateParagraph({
    Title = "Smart Autofarm",
    Content = "Enable the switch below. Mining, selling, crew, research and zone unlocking work together automatically. Adjust details only if you want to.",
})
toggle(homeTab, "Start / Pause Autofarm", "Master")
homeTab:CreateSection("Everyday options")
toggle(homeTab, "Mine Rocks", "Mine")
toggle(homeTab, "Collect Ore Chests", "AutoChest")
toggle(homeTab, "Sell Ore Automatically", "AutoSellOre")
toggle(homeTab, "Unlock New Zones", "AutoBuyZones")
homeTab:CreateSection("Quick presets")
homeTab:CreateButton({Name = "Balanced (recommended)", Callback = function()
    applyPreset("Balanced", {
        MineMode="Balanced", RockLocalityBoost=1.6, ChestPercent=0.72,
        EfficientTrips=true, MaxTargetTravel=75, MaxWalkRetries=4,
        FastLocalMining=true, FasterScheduling=true,
        AutoJumpObstacles=true, CornerRecovery=true,
    })
end})
homeTab:CreateButton({Name = "Fast Farming", Callback = function()
    applyPreset("Fast Farming", {
        MineMode="Fast", RockLocalityBoost=1.9, ChestPercent=0.85,
        EfficientTrips=true, MaxTargetTravel=55, MaxWalkRetries=3,
        FastLocalMining=true, FasterScheduling=true,
        AutoJumpObstacles=true, CornerRecovery=true,
    })
end})
homeTab:CreateButton({Name = "Careful / Fewer Trips", Callback = function()
    applyPreset("Careful", {
        MineMode="Balanced", RockLocalityBoost=1.5, ChestPercent=0.90,
        EfficientTrips=true, MaxTargetTravel=45, MaxWalkRetries=4,
        FastLocalMining=true, FasterScheduling=false,
        AutoJumpObstacles=true, CornerRecovery=true,
    })
end})
homeTab:CreateLabel("Profiles: save or load your setup in the Configs tab.")

farmTab:CreateSection("Mining")
dropdown(farmTab, "Rock selection", "MineMode", {"Balanced", "Fast", "Value", "Rare loot"})
toggle(farmTab, "Prioritise Nearby Rocks", "FastLocalMining")
toggle(farmTab, "Adaptive Rock Targeting", "AdaptiveRockChoice")
toggle(farmTab, "Prioritise Valuable Special Rocks", "FocusSpecialRocks")
toggle(farmTab, "Research-Adjusted Motherlode", "AccurateMotherlode")
slider(farmTab, "Nearby Target Preference (%)", "RockLocalityBoost", 100, 200, 10, percent)
slider(farmTab, "Max Rock Hits", "MaxTapsPerRock", 8, 100, 1)
slider(farmTab, "Tap Interval (game-limited)", "TapInterval", 1.2, 3.0, 0.1)
farmTab:CreateSection("Selling & Storage")
toggle(farmTab, "Avoid Unnecessary Seller Trips", "EfficientTrips")
toggle(farmTab, "Empty Full Chest Immediately", "UrgentFullChest")
toggle(farmTab, "Use Owned Auto Sell Pass", "EnableOwnedAutoSell")
slider(farmTab, "Collect Chest At (%)", "ChestPercent", 20, 95, 5, percent)
slider(farmTab, "Minimum Ore Sale Value", "MinSellValue", 0, 100000, 1000)
farmTab:CreateSection("Character Movement")
toggle(farmTab, "Jump Small Obstacles", "AutoJumpObstacles")
toggle(farmTab, "Reroute Around Walls", "CornerRecovery")
toggle(farmTab, "Stop Moving When Rock Breaks", "CancelDeadRockWalk")
toggle(farmTab, "Use In-Game Hub Travel", "NativeTravel")
slider(farmTab, "Max Target Distance (studs)", "MaxTargetTravel", 25, 140, 5)
slider(farmTab, "Route Retries", "MaxWalkRetries", 1, 5, 1)
slider(farmTab, "Stuck Detection (seconds)", "StuckTimeout", 0.7, 2, 0.05)
farmTab:CreateLabel("Walking uses MoveTo, pathfinding and jumping. No tweening.")

progressTab:CreateSection("Automatic progression")
toggle(progressTab, "Equip Best Crew", "EquipBest")
toggle(progressTab, "Finish Required Research (100%)", "AutoCompleteResearch")
toggle(progressTab, "Prioritise Affordable Research", "SmartResearchPriority")
toggle(progressTab, "Buy Useful Optional Research", "AutoSkills")
toggle(progressTab, "Automatically Select Best Zone", "AutoZone")
toggle(progressTab, "Save Cash for Zone Unlocks", "ZoneSaveForNext")
toggle(progressTab, "Upgrade Equipped Characters", "AutoCharacterLevels")
toggle(progressTab, "Upgrade Crew Speed", "AutoCrewSpeed")
toggle(progressTab, "Equip Owned Pickaxes", "AutoEquipOwnedPickaxes")
progressTab:CreateSection("Blocked by team power?")
toggle(progressTab, "Respect Research Power Requirements", "PowerAwareResearch")
toggle(progressTab, "Improve Power to Unlock Research", "PowerGateRescue")
toggle(progressTab, "Buy Better Pickaxes for Miners", "PowerRescuePickaxes")
toggle(progressTab, "Level Miners for More Power", "PowerRescueLevels")
progressTab:CreateLabel("Research comes first, then the next zone unlock.")
progressTab:CreateSection("Progression preferences")
dropdown(progressTab, "Zone Unlock Condition", "ZoneBuyMode", {"Affordable", "Power ready"})
dropdown(progressTab, "Which Zone to Farm", "ZoneMode", {"Highest unlocked", "Selected zone"})
slider(progressTab, "Selected Zone", "ChosenZone", 1, 12, 1)
slider(progressTab, "Upgrade Spend Limit (%)", "BudgetPercent", 5, 80, 5, percent)
slider(progressTab, "Keep Cash Reserve (%)", "UpgradeReserve", 0, 60, 5, percent)

extrasTab:CreateSection("Free Rewards")
toggle(extrasTab, "Daily Spins", "AutoSpin")
toggle(extrasTab, "Daily Quests When Available", "AutoQuests")
toggle(extrasTab, "Claim Index Rewards", "AutoIndex")
toggle(extrasTab, "Claim Mailbox Rewards", "AutoMailbox")
toggle(extrasTab, "Claim Free Buff Rewards", "AutoBuffGift")
toggle(extrasTab, "Claim Event Rewards", "AutoEventClaims")
toggle(extrasTab, "Claim Trial Milestones", "AutoTrialClaims")
extrasTab:CreateSection("Inventory & Specials")
toggle(extrasTab, "Equip Owned Gear", "AutoGear")
toggle(extrasTab, "Equip Owned Enchants", "AutoEnchants")
toggle(extrasTab, "React to Weather", "WeatherAware")
toggle(extrasTab, "Use Spare Potions", "AutoPotions")
toggle(extrasTab, "Use Spare Summon Scrolls", "AutoSummon")
toggle(extrasTab, "Run Eligible Trials", "AutoTrialRuns")
toggle(extrasTab, "Send Crew to Special Rocks (experimental)", "AutoFocusSpecial")
extrasTab:CreateLabel("Trials and crew-focus are optional. No Robux spending.")
extrasTab:CreateSection("Expert controls")
toggle(extrasTab, "Optional Cash Pickaxe Purchases", "AutoPickaxes")
toggle(extrasTab, "Auto Expand Crew Slots", "AutoSlots")
toggle(extrasTab, "Upgrade Tap Damage", "AutoTapUpgrades")
toggle(extrasTab, "Crafting When Enabled", "AutoCrafting")
toggle(extrasTab, "Buy Useful Density While Strong", "AdaptiveNodeDensity")
toggle(extrasTab, "Auto-Save Small Upgrades", "SmartUpgradeSavings")
toggle(extrasTab, "Mine Cash During Research Wait", "ResearchCashBoost")
toggle(extrasTab, "Fast Responsive Scheduling", "FasterScheduling")
slider(extrasTab, "Save For Zone At (%)", "ZoneSaveAt", 10, 95, 5, percent)
slider(extrasTab, "Max Zone Rock Time (seconds)", "ZoneMaxRockSeconds", 15, 180, 5)
slider(extrasTab, "Power: Max Purchase (%)", "PowerRescueMaxPurchase", 5, 45, 5, percent)
slider(extrasTab, "Power: Keep Money (%)", "PowerRescueKeepCash", 15, 80, 5, percent)
slider(extrasTab, "Colossus Time Limit (seconds)", "ColossusMaxSeconds", 15, 180, 5)
slider(extrasTab, "Keep Summon Scrolls", "KeepSummonScrolls", 0, 30, 1)
dropdown(extrasTab, "Potion Strategy", "PotionMode", {"Balanced", "Cash", "Rare finds", "Power"})
slider(extrasTab, "Keep Potions", "PotionReserve", 0, 15, 1)
slider(extrasTab, "Trial Power Margin", "TrialMinPowerRatio", 1, 10, 0.5)

settingsTab:CreateSection("Farming preferences")
toggle(settingsTab, "Fewer Heavy Effects", "AutoPerformance")
settingsTab:CreateSection("Presets & profiles")
settingsTab:CreateParagraph({
    Title = "Saving your setup",
    Content = "Open Configs to create, save, load or delete named profiles. Auto Save and Auto Load are controlled there. The autofarm always starts paused for safety.",
})
local resetArmedUntil = 0
settingsTab:CreateButton({Name = "Restore Default Options (press twice)", Callback = function()
    if os.clock() > resetArmedUntil then
        resetArmedUntil = os.clock() + 10
        notify("Confirm reset", "Press Restore Default Options again within 10 seconds")
        return
    end
    resetArmedUntil = 0
    for key, value in pairs(defaults) do
        if key ~= "Master" then setOption(key, value) end
    end
    notify("Options restored", "Default options restored. Autofarm start/pause unchanged.")
end})
settingsTab:CreateButton({Name = "Stop and Unload Script", Callback = API.Unload})
settingsTab:CreateLabel("UI size, layout and show/hide key are above.")

-- Home, Farm, Progress, Extras and Settings only. PuckUI manages named Configs.
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
