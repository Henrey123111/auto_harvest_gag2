--[[ ============================================================
   YumaBlox  (Auto Harvest + Shop + Steal)  —  "Grow a Garden"-style game (LeoDevCore)
   Single-file Roblox executor script. loadstring()()-ready.

   ALL MECHANICS VERIFIED LIVE via the dex bridge on this game:
     * HARVEST  fruit live at Gardens.<myPlot>.Plants.*.Fruits.*.HarvestPart.HarvestPrompt;
                gate = prompt.Enabled (ripe). No proximity (plants IgnoreFruitDistance),
                so NO teleport -- fireproximityprompt(prompt) single-arg. ~1 harvest/frame,
                so fires are paced by FIRE_INTERVAL with a verify re-fire pass.
     * SELL     Networking.NPCS.SellAll:Fire() sells the ENTIRE inventory instantly.
                "Full" = LocalPlayer FruitCount >= MaxFruitCapacity.
     * BUY      Networking.SeedShop.PurchaseSeed:Fire(name)   (catalog in SeedShop GUI)
                Networking.GearShop.PurchaseGear:Fire(name)   (catalog in GearShop GUI)
                Both remote, server-gated on stock + cost.
     * STEAL    other plots' fruit have HarvestPart.StealPrompt; steal via
                Networking.Steal.BeginSteal(ownerUserId, PlantId, FruitId) -> return to
                base -> CompleteSteal. NIGHT-ONLY (ReplicatedStorage.Night), 10-stud +
                line-of-sight, server-gated. Targets ranked by SellValueData * SizeMulti.

   UI: the Fluent library (acrylic, tabs, toggles, multi-select dropdowns). Pick which
   seeds & gears to auto-buy in the Shop tab. Re-running cleanly tears down the prior
   instance; closing the window stops the bot. Control handle: getgenv().AutoHarvestFruit
   ============================================================ ]]

--===========================================================================--
-- SERVICES & EXECUTOR FEATURE DETECTION
--===========================================================================--
local Players           = game:GetService("Players")
local Workspace         = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService  = game:GetService("UserInputService")
local CollectionService  = game:GetService("CollectionService")
local LocalPlayer       = Players.LocalPlayer

local genv = (typeof(getgenv) == "function") and getgenv() or nil
local function ENV() return genv or _G end

-- CRITICAL: harvesting needs fireproximityprompt.
local fireprompt = (typeof(fireproximityprompt) == "function") and fireproximityprompt or nil
if not fireprompt then
    warn("[YumaBlox] This executor lacks fireproximityprompt(); cannot harvest.")
    return
end

-- Optional GUI helpers for the floating mobile toggle button (never assume present).
local gethui_fn      = (typeof(gethui) == "function") and gethui or nil
local protect_gui_fn = (typeof(syn) == "table" and typeof(syn.protect_gui) == "function") and syn.protect_gui or nil

--===========================================================================--
-- CONFIG
--===========================================================================--
local FIRE_INTERVAL   = 0.10   -- seconds between prompt fires (rate-limit safe)
local RESCAN_DELAY    = 1.00   -- pause between full plot sweeps
local VERIFY_RETRY    = true   -- re-fire fruit that didn't drop
local AUTO_START      = true   -- start harvesting on load
local AUTO_SELL       = true   -- sell whole inventory when full
local SELL_AT_PERCENT = 0.85   -- sell once FruitCount >= MaxFruitCapacity * this (was 1.00)
local SELL_COOLDOWN   = 1.0    -- min seconds between auto-sells (was 2.0)
local SELL_INTERVAL   = 3.0    -- also sell on this interval even when not full…
local SELL_MIN_FRUIT  = 8      -- …but only if FruitCount >= this (so a near-empty SellAll isn't wasted)
local SELL_MODE       = "Instant"  -- "Instant" = SellAll whenever you hold any fruit; "Full" = only at MaxFruitCapacity
local AUTO_BUY        = true   -- buy the seeds/gears you tick (when in stock)
local BUY_RESCAN      = 1.0    -- seconds between shop buy sweeps (was 5.0 — reduced for faster pet detection)
local BUY_FIRE_GAP    = 0.15   -- pace between individual purchase fires
local AUTO_BUY_PETS   = false  -- buy ticked wild-pet types (TELEPORTS the character; off by default)
local PET_TP_SETTLE   = 0.15   -- per-tick settle while following a wandering pet to fire its Buy prompt
local AUTO_STEAL       = false -- steal the most valuable fruit in the server, then return to base (NIGHT only; TELEPORTS!)
local STEAL_RESCAN       = 1.5   -- seconds between steal sweeps (paced to dodge the server steal rate-limit)
local STEAL_BATCH        = 6     -- max targets pursued per sweep
local STEAL_TARGET_GAP   = 0.25  -- gap between targets (paced, not spammy -> avoids rate-limit drops)
-- STEPPED teleport (NOT an instant jump): the server runs anti-teleport and silently rejects a single big
-- CFrame jump, so we hop in small lerp steps the server accepts as legit movement. Proven via live MCP.
local STEAL_STEP_DIST    = 6     -- max studs per hop (halved for more natural movement)
local STEAL_STEP_WAIT    = 0.07  -- wait between hops (slower = more legitimate)
local PET_STEP_DIST      = 4     -- pet-buy step size — small steps = smooth, slow, natural glide (not an instant jump)
local PET_STEP_WAIT      = 0.1   -- wait between pet-buy steps — slower ~40 studs/sec (was ~160, looked like a teleport)
local STEAL_PIN_FRAMES   = 12    -- frames to pin ON the fruit so the server registers us in range before firing
local STEAL_FIRE_TRIES   = 3     -- grab (hold) attempts per target
-- Steal time is PER-FRUIT (StealFlags.GetStealHoldDuration): 0 for normal fruit (Apple/Pineapple = INSTANT),
-- 3 for Bamboo/Mushroom. We hold for that duration + a margin, and exit the instant the carry lands.
local STEAL_HOLD_MARGIN  = 1.5   -- extra seconds over the fruit's server-enforced steal duration
local _stealFlags
local function stealHoldSecs(name)
    if _stealFlags == nil then _stealFlags = (select(2, pcall(function()
        return require(game:GetService("ReplicatedStorage").SharedModules.Flags.StealFlags) end))) or false end
    local d = 0
    if _stealFlags and _stealFlags.GetStealHoldDuration then
        local ok, v = pcall(_stealFlags.GetStealHoldDuration, name)
        if ok and type(v) == "number" then d = v end
    end
    return d + STEAL_HOLD_MARGIN     -- e.g. instant fruit -> ~1.5s cap, Bamboo/Mushroom -> ~4.5s cap
end
local VirtualInputManager = game:GetService("VirtualInputManager")
local STEAL_STAND_OFF    = Vector3.new(0, 0, 2)  -- offset to stand on the fruit (within MAD + line-of-sight)
local PAUSE_HARVEST_WHILE_STEALING = true  -- suspend harvesting while a steal is actively in progress
local COLLECT_RESCAN   = 0.6   -- seconds between sweeps of workspace.DroppedItems for wild event seeds
local COLLECT_SETTLE   = 0.12  -- per-tick settle after teleporting onto a dropped seed before firing pickup
local COLLECT_TICKS    = 12    -- hold-on-item + fire-pickup ticks before giving up on one item (~1.5s)
local COLLECT_STAND_OFFSET = 1.5  -- studs above the item's primary part to stand (well inside any MaxActivationDistance)
local COLLECT_DESPAWN_MARGIN = 3  -- skip a wild seed this close (sec) to despawning, so we don't chase one that vanishes mid-grab
local FLUENT_URL      = "https://github.com/dawid-scripts/Fluent/releases/latest/download/main.lua"
-- Config injected by the VPS /script endpoint (getgenv().YB_CONFIG); falls back to these if pasted directly.
local _YB             = (getgenv and getgenv().YB_CONFIG) or {}
local SNIPE_BASE      = _YB.base or "https://roblox.yumacheats.com"   -- coordinator URL. HTTPS via the tunnel (port 443): raw http://IP:8745 is blocked by many executors/networks. The VPS overrides this via YB_CONFIG when served.
local SNIPE_KEY       = _YB.key or "feed-leo-ro-3k9q"           -- READ-ONLY feed token (for /finds only; never the bot token)
local SNIPE_BOT_KEY   = _YB.phKey or "ph-leo-9x4m2k7q"          -- bot token for /report (BigFroot → coordinator)
local SNIPE_POLL      = 5                                          -- feed refresh when just VIEWING the tab (low coordinator load; feed is server-cached)
local SNIPE_POLL_FAST = 1.5                                        -- feed refresh while AUTO-SNIPE is ON -> catch short-lived pets (e.g. 30s Mythicals) before they despawn
local SCRIPT_EXPIRES  = _YB.expires                               -- key expiry (epoch), set when served via /script
local WH_URL          = "https://discord.com/api/webhooks/1517861705890140170/43D86zsG47dzhMcD1RfWHCNqW9vqNuFMbu46D90L8-0-lXI6nLWWO1TTsa1I7FebFRRp"
local _wh_sent        = {}   -- (jobId..name) -> true; survives teleports via getgenv
local _wh_req         = (syn and syn.request) or (http and http.request) or http_request or request
local RAR_WH_COLOR    = { Common=0xAAAAAA, Uncommon=0x57F287, Rare=0x5865F2, Epic=0x9B59B6, Legendary=0xFFCC15, Mythic=0xED4245, Super=0xFF73FA, Secret=0xFFFFFF }
local RAR_WH_ICON     = { Common="⚪", Uncommon="🟢", Rare="🔵", Epic="🟣", Legendary="🟡", Mythic="🔴", Super="🌈", Secret="✨" }
local WH_MIN_RANK   = 4   -- 4=Epic+. 5=Legendary+, 6=Mythic+ only.
local WH_RAR_RANK   = { common=1, uncommon=2, rare=3, epic=4, legendary=5, mythic=6, mythical=6, super=7, secret=8 }
local function whPost(f)
    if not _wh_req or WH_URL == "" then return end
    local name  = tostring(f.name or "?")
    local rar   = tostring(f.rarity or "")
    if (WH_RAR_RANK[rar:lower()] or 0) < WH_MIN_RANK then return end   -- skip Common/Uncommon/Rare/Epic
    local jobId = tostring(f.job or "")
    local place = tostring(f.place or game.PlaceId)
    local secs  = tonumber(f.secondsLeft) or 0
    local price = tonumber(f.price)
    local key   = jobId .. name
    local G     = getgenv and getgenv() or _G
    G.YB_WH_SENT = G.YB_WH_SENT or {}
    if G.YB_WH_SENT[key] then return end
    G.YB_WH_SENT[key] = true
    task.spawn(function()
        local timer = secs >= 60
            and ("\xe2\x8f\xb3%dm %02ds"):format(math.floor(secs/60), secs%60)
            or  (secs > 0 and ("\xe2\x8f\xb3%ds"):format(secs) or nil)
        local priceStr = price and ("\xc2\xa2%s"):format(tostring(math.floor(price)):reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")) or nil
        local bits = {}
        if priceStr then bits[#bits+1] = priceStr end
        if timer    then bits[#bits+1] = timer end
        if rar ~= "" then bits[#bits+1] = rar end
        local icon  = RAR_WH_ICON[rar]  or "\xf0\x9f\x90\xbe"
        local color = RAR_WH_COLOR[rar] or 0xFFCC15
        local desc  = "• **" .. name .. "**" .. (#bits > 0 and ("  —  " .. table.concat(bits, "  ·  ")) or "")
        local joinCmd = "```\nTeleportToPlaceInstance(" .. place .. ', "' .. jobId .. '")\n```'
        local payload = game:GetService("HttpService"):JSONEncode({
            username = "Pet Hunter",
            embeds   = {{
                title       = icon .. " " .. name .. " (" .. (rar ~= "" and rar or "?") .. ")",
                description = desc,
                color       = color,
                fields      = {
                    { name = "Server (JobId)", value = "`" .. jobId .. "`", inline = false },
                    { name = "Time Left",      value = timer or "unknown",  inline = true  },
                    { name = "Place",          value = place,               inline = true  },
                    { name = "Join",           value = joinCmd,             inline = false },
                },
                footer = { text = "pet-hunter" },
            }},
        })
        pcall(_wh_req, { Url = WH_URL, Method = "POST", Headers = { ["Content-Type"] = "application/json" }, Body = payload })
    end)
end

--===========================================================================--
-- SINGLE-INSTANCE TEARDOWN
--===========================================================================--
do
    local prior = ENV().AutoHarvestFruit
    if typeof(prior) == "table" then
        prior.running, prior.alive = false, false
        if typeof(prior.cleanup) == "function" then pcall(prior.cleanup) end
    end
    -- reset per-server reload dedup so re-snipes from this server work correctly
    if getgenv then getgenv().YB_LOADING_JOB = nil end
end

--===========================================================================--
-- STATE
--===========================================================================--
local State = {
    alive = true, running = AUTO_START, autoSell = AUTO_SELL, sellMode = SELL_MODE, autoBuy = AUTO_BUY, autoBuyPets = AUTO_BUY_PETS,
    autoSteal = AUTO_STEAL,
    protectBase = false,   -- PROTECT BASE: at night, stand inside your own garden so IsInOwnGarden=true -> nobody can steal from you
    autoMail = false, mailTo = "", mailItems = {}, mailLeave = 0, mailStatus = "off", mailSent = 0,   -- AUTO MAIL: auto-repeat gift item types (multi) to a recipient. mailItems = { {cat=,typeName=}, ... }
    buySeeds = {}, buyGears = {}, buyPets = {},    -- sets: name -> true
    buyOnce = false, buyArmed = true,              -- "Buy Once Only": when on, buy a single pet then disarm until next snipe-arrival re-arms it
    harvested = 0, fires = 0, sold = 0, bought = 0, stolen = 0,
    harvestSpeed = 6, fireGap = FIRE_INTERVAL,   -- harvest-speed slider (1=slow .. 10=max); fireGap = (10-speed)*0.025
    fruitCount = 0, maxFruit = 0, ripe = 0, status = "starting", stealStatus = "idle", stealing = false, tpBusy = false,
    snipeAuto = false, snipeRar = { Legendary = true, Mythic = true, Super = true }, snipePets = {}, snipeFinds = {}, snipeStatus = "off", snipedJob = nil,
    snipeSkipOld = true, snipeMaxAge = 5,   -- max server age (sec). 5 absorbs the report→cache→poll pipeline (~3s) so fresh servers actually pass; raise to be looser, lower (min 3) to be stricter
    eventSeeds = { Gold = true, Rainbow = true },   -- which seeds the Moon-Events wild auto-pickup grabs
    autoCollectWild = false, wildCollected = 0, collectStatus = "off",  -- pick up Gold/Rainbow seeds that spawn in workspace.DroppedItems during the event
    antiAfk = true, antiFling = false, antiFlingReset = false, flingsBlocked = 0, flingStatus = "off",
    flinging = false,
    antiWheelbarrow = false, wbBlocked = 0, wbStatus = "off",
    antiShovel = false, shovelBlocked = 0, shovelDefStatus = "off",   -- DEFENSE: negate enemy shovel whacks
    autoShovelHit = false, shovelHits = 0, shovelStatus = "off",       -- OFFENSE: whack enemies with our shovel
    autoProtectPets = false, protectStatus = "off",
    lockPosition = false,
    perfMode = false, hidePlants = false, hideAvatar = false,
    autoWater = false, watered = 0, waterStatus = "off",
    autoPlant = false, planted = 0, plantStatus = "off", plantSeeds = {}, plantSpacing = 2, plantMode = "Random",   -- plantSeeds: set (multi). plantMode: "Random" | "Grid" (how seeds get PLANTED)
    stackStatus = "off",   -- pack-plants-via-Trowel button feedback
    limitHarvestKg = false, maxHarvestKg = 50,   -- WEIGHT CAP: when on, skip harvesting fruit heavier than maxHarvestKg (leave it growing)
    espWeight = false,                           -- VISUAL: float "kg | $price" over each fruit in my garden
    autoSprinkle = false, sprinkled = 0, sprinkleStatus = "off", sprinkleMutations = false,   -- false = hit 100 size-luck with fewest sprinklers; true = stack every tier for mutations
    cleanupTypes = {}, cleanupStatus = "off", cleaned = 0,   -- CLEANUP GARDEN: shovel/dig up selected plant types (by SeedName), via the button
    weatherNow = nil, weatherStatus = "clear", weatherPhase = nil, weatherLeft = 0, weatherCycle = 0,
    weatherSeen = {}, tonightW = nil,
    nextGold = nil, nextGoldAt = 0, nextRbow = nil, nextRbowAt = 0, nextBlood = nil, nextBloodAt = 0,
    window = nil, fluent = nil, toggleGui = nil, conns = {},
}
ENV().AutoHarvestFruit = State
local function waitFn(t) task.wait(t) end

-- cross-scope notification: works BEFORE Fluent loads (startup arrival task needs it).
-- Prefers Fluent (nicer UI) once built, falls back to Roblox core notifications.
local function ybNotify(title, text, duration)
    duration = duration or 4
    if State.fluent and State.fluent.Notify then
        local ok = pcall(function() State.fluent:Notify({ Title = title, Content = text, Duration = duration }) end)
        if ok then return end
    end
    pcall(function()
        game:GetService("StarterGui"):SetCore("SendNotification", { Title = title, Text = text, Duration = duration })
    end)
end
State.notify = ybNotify

-- build a readable list of the selected snipe rarities (for notifications)
local function selectedRaritiesText()
    local list = {}
    for r, on in pairs(State.snipeRar or {}) do if on then list[#list+1] = r end end
    table.sort(list)
    return #list > 0 and table.concat(list, "/") or "(none selected)"
end

--===========================================================================--
-- PET-HUNTER SCAN (ported from pet_hunter.lua)
-- Used for arrival check: waits for WildPetSpawns to stabilize then scans.
-- Runs in the NEW server after queue_on_teleport re-executes the script.
-- _phPetData is a local so it resets to nil on every fresh script execution.
--===========================================================================--
local _phPetData          -- nil=not tried, false=failed, table=loaded
local PH_LOAD         = 15     -- max seconds to wait for WildPetSpawns
local PH_INTERVAL     = 0.25   -- poll cadence
local PH_READY_STABLE = 3      -- consecutive equal-count polls = stable

local function phAttr(inst, a)
    local ok, v = pcall(inst.GetAttribute, inst, a); if ok then return v end
end
local function phPetNameOf(inst)
    for _, a in ipairs({"PetName","Pet","PetType"}) do
        local ok, v = pcall(inst.GetAttribute, inst, a)
        if ok and type(v)=="string" and v~="" then return v end
    end
end
local function phPetRarity(name)
    if _phPetData == nil then
        local ok, pd = pcall(function()
            local RS = game:GetService("ReplicatedStorage")
            local sd = RS:FindFirstChild("SharedData")
            local m  = sd and sd:FindFirstChild("PetData")
            if not m then local sm=RS:FindFirstChild("SharedModules"); m=sm and sm:FindFirstChild("PetData") end
            return m and require(m)
        end)
        _phPetData = (ok and type(pd)=="table") and pd or false
    end
    if _phPetData and type(_phPetData[name])=="table" then return _phPetData[name].Rarity end
end

local function phWaitReady()
    local t0 = os.clock(); local lastN, stable = -1, 0
    while os.clock()-t0 < PH_LOAD do
        local map = workspace:FindFirstChild("Map")
        local wps = map and map:FindFirstChild("WildPetSpawns")
        if wps then
            local ok, kids = pcall(function() return wps:GetChildren() end)
            if ok then
                local n, named = #kids, false
                for _, m in ipairs(kids) do if phPetNameOf(m) then named=true; break end end
                if n==lastN then stable+=1 else stable,lastN=0,n end
                if stable>=PH_READY_STABLE and (named or os.clock()-t0>=7) then return true end
            end
        end
        task.wait(PH_INTERVAL)
    end
    return false
end

local function phScanPets()
    local out = {}
    local map = workspace:FindFirstChild("Map")
    if not map then return out end
    -- PREFER WildPetRef — it carries authoritative Rarity + State + OwnerUserId attributes.
    -- Every pet listed here is PRESENT in WildPetRef => still AVAILABLE (not yet secured). The
    -- snipe stay-gate (phHasTargetPet) keys off PRESENCE alone, so a contested pet keeps us here.
    -- `buyable` is a separate, informational flag for auto-buy — BUYABLE RULE (decompiled
    -- SpawnPetController): BuyPrompt.Enabled = (OwnerUserId ~= you):
    --   OwnerUserId == 0           -> unowned wild pet            -> buyable
    --   OwnerUserId == otherPlayer -> CONTESTED (bought, still walking to THEIR garden) -> buyable by us
    --   OwnerUserId == us          -> our own walking pet         -> NOT buyable (already ours; Escort it)
    local ref = map:FindFirstChild("WildPetRef")
    if ref and #ref:GetChildren() > 0 then
        for _, p in ipairs(ref:GetChildren()) do
            local nm = phAttr(p, "PetName")
            if nm then
                local st = tostring(phAttr(p, "State") or "")
                local owner = tonumber(phAttr(p, "OwnerUserId")) or 0
                out[#out+1] = {
                    name = nm,
                    rarity = phAttr(p, "Rarity") or phPetRarity(nm),
                    state = st,
                    owner = owner,
                    buyable = (owner ~= LocalPlayer.UserId),   -- buyable unless WE already own it (contested pets included)
                }
            end
        end
        return out
    end
    -- fallback: WildPetSpawns models + PetData module rarity
    local wps = map:FindFirstChild("WildPetSpawns")
    if not wps then return out end
    for _, m in ipairs(wps:GetChildren()) do
        local nm = phPetNameOf(m)
        if nm then
            out[#out+1] = { name=nm, rarity=phAttr(m,"Rarity") or phPetRarity(nm), buyable=true }
        end
    end
    return out
end

-- case-insensitive + alias rarity match against State.snipeRar (Title-case keys).
-- Handles "Mythic"/"mythic"/"Mythical" all matching the selected "Mythic".
local _RAR_NORM = {
    common="Common", uncommon="Uncommon", rare="Rare", epic="Epic",
    legendary="Legendary", mythic="Mythic", mythical="Mythic",
    super="Super", secret="Secret", divine="Divine", og="OG",
}
local function raritySelected(rar)
    if not rar then return false end
    local s = tostring(rar)
    if State.snipeRar[s] then return true end                 -- exact key
    local norm = _RAR_NORM[s:lower()]
    return norm ~= nil and State.snipeRar[norm] == true        -- normalized
end

-- OPTIONAL pet-name narrowing WITHIN the selected rarities. snipePets EMPTY = snipe ALL pets of the
-- selected rarities (original behaviour); non-empty = snipe ONLY those specific pets.
local function snipePetSelected(name)
    if not next(State.snipePets or {}) then return true end
    return name ~= nil and State.snipePets[tostring(name)] == true
end
-- a pet is a snipe target if its rarity is selected AND (no specific pets picked, or this one is picked)
local function snipeMatch(name, rarity)
    return raritySelected(rarity) and snipePetSelected(name)
end
-- all pet names whose rarity is currently selected — for the "Pets to snipe" picker
local _snipePD
local function snipePetCatalog()
    if _snipePD == nil then
        _snipePD = false
        pcall(function()
            local sd = ReplicatedStorage:FindFirstChild("SharedData")
            local m = sd and sd:FindFirstChild("PetData")
            if not m then local sm = ReplicatedStorage:FindFirstChild("SharedModules"); m = sm and sm:FindFirstChild("PetData") end
            if m then _snipePD = require(m) end
        end)
    end
    local out = {}
    if type(_snipePD) == "table" then
        for name, info in pairs(_snipePD) do
            if type(info) == "table" and info.Rarity and raritySelected(info.Rarity) then out[#out + 1] = tostring(name) end
        end
    end
    table.sort(out)
    return out
end

-- returns true + pet info if a SELECTED-rarity pet is AVAILABLE in this server.
-- "Available" = present in WildPetRef and NOT yet secured — REGARDLESS of who owns it:
--   * unowned wild pet (Owner 0)                       -> available
--   * CONTESTED: bought by ANOTHER player, still walking to their garden -> STILL available
--                (its BuyPrompt stays enabled for us — we can contest-buy / steal it)
--   * bought by US, still walking to our garden        -> available (stay here so Escort protects it)
-- A pet leaves "available" ONLY when its WildPetRef part is removed — i.e. it reaches a garden
-- (SECURED, "get by the player or me") or its Lifetime expires (despawn).
-- This is the MASTER gate for stay-vs-re-snipe: auto-snipe STAYS while ANY target pet is available,
-- and only re-snipes once the pet has actually been gotten (by another player OR by me) / despawned.
-- (Owner-agnostic on purpose — gating on buyability would re-snipe away while a contested pet is
--  still up for grabs, or while we're escorting our own freshly-bought pet home.)
local function phHasTargetPet()
    local pets = phScanPets()
    for _, p in ipairs(pets) do
        if snipeMatch(p.name, p.rarity) then return true, p end
    end
    return false
end

-- ARRIVAL CHECK STARTUP TASK (runs on every script execution including re-executes in new server)
-- If YB_LAST_SNIPE is recent, we just teleported via snipe → check if this server has the target pet.
-- This runs in the NEW server context — correct! Not in the old server like the previous approach.
task.spawn(function()
    local G0 = getgenv and getgenv() or _G
    local lastSnipe = G0.YB_LAST_SNIPE or 0
    -- only run if we sniped in the last 60 seconds
    -- _RELOAD_SCRIPT sets YB_LAST_SNIPE = os.time() immediately on arrival
    -- so this check correctly detects a fresh snipe-join even when getgenv() was empty
    if (os.time() - lastSnipe) > 60 then return end
    -- extend the gate so it holds for the full arrival check duration (up to 30s)
    G0.YB_LAST_SNIPE = os.time()
    State.buyArmed = true   -- fresh snipe-join: re-arm "Buy Once" so it buys one pet in THIS server
    State.snipeStatus = "scanning server for target pets…"
    -- wait for WildPetSpawns to stabilize (pet_hunter approach — NOT hasLocalMatchingPet)
    local ready = phWaitReady()
    if not ready then
        -- server never loaded pets within 15s → move on
        State.snipeStatus = "server load timeout → re-sniping…"
        ybNotify("YumaBlox Snipe", "⏳ Server didn't load pets in time → re-sniping…", 4)
        task.wait(1)
        G0.YB_LAST_SNIPE = 0
        return
    end
    -- reset PetData cache so rarity lookup is fresh in this new server
    _phPetData = nil
    local found, pet = phHasTargetPet()
    if found then
        -- TARGET PET IS HERE → STOP sniping and stay so it can be bought.
        -- Refresh the gate continuously while the pet is present (handled by the
        -- poller's phHasTargetPet() check) so auto-snipe never jumps away.
        State.snipeStatus = "✅ "..tostring(pet.rarity).." "..tostring(pet.name).." found — STAYING!"
        ybNotify("YumaBlox Snipe", "✅ Found "..tostring(pet.rarity).." "..tostring(pet.name).." — staying to buy it!", 6)
        G0.YB_LAST_SNIPE = os.time()   -- hold the arriving gate
    else
        -- NO matching rarity in this server → tell coordinator to REMOVE it from /finds
        -- so other users stop wasting joins on this stale server, then re-snipe.
        State.snipeStatus = "❌ no "..selectedRaritiesText().." here → re-sniping…"
        ybNotify("YumaBlox Snipe", "❌ No "..selectedRaritiesText().." pet in this server → finding next…", 4)
        do
            local thisJob = game.JobId
            local _r = (syn and syn.request) or (http and http.request) or http_request or request
                or (fluxus and fluxus.request) or (getgenv and getgenv().request)
            if _r and SNIPE_BASE ~= "" and thisJob ~= "" then
                task.spawn(function()
                    pcall(_r, {
                        Url     = SNIPE_BASE .. "/nopet",
                        Method  = "POST",
                        Headers = { ["Content-Type"] = "application/json", ["X-PH-Key"] = SNIPE_BOT_KEY },
                        Body    = game:GetService("HttpService"):JSONEncode({
                            bot = "autosnipe", job = thisJob, place = game.PlaceId,
                        }),
                    })
                end)
            end
        end
        task.wait(1)   -- 1s minimum before re-snipe to prevent instant loop
        G0.YB_LAST_SNIPE = 0
    end
end)

-- ===== NON-BLOCKING HTTP (stops the /finds poll freezing the farm on blocking-HttpGet executors) =====
local _httpReq = (syn and syn.request) or (http and http.request) or http_request or request
local function httpGetAsync(url)                 -- returns ok(boolean), body(string|nil)
    if _httpReq then
        local ok, res = pcall(_httpReq, { Url = url, Method = "GET", Timeout = 8 })
        if ok and type(res) == "table" then
            local body = res.Body or res.body
            local code = res.StatusCode or res.status_code or 0
            if type(body) == "string" and code >= 200 and code < 300 then return true, body end
            return false, body
        end
        return false, nil
    end
    local ok, body = pcall(function() return game:HttpGet(url) end)   -- last resort (no async request fn)
    if ok and type(body) == "string" then return true, body end
    return false, nil
end

--===========================================================================--
-- SETTINGS PERSISTENCE  (executor writefile/readfile -> survives leave/rejoin)
--===========================================================================--
local HttpService = game:GetService("HttpService")
local CFG_FILE = "AutoHarvestFruit_config.json"
local _hasFiles = typeof(writefile) == "function" and typeof(readfile) == "function" and typeof(isfile) == "function"
local uiBuilding = false   -- true while buildGui constructs controls; ignore their initial OnChanged fires

local function saveConfig()
    if not _hasFiles or uiBuilding then return end
    pcall(function()
        writefile(CFG_FILE, HttpService:JSONEncode({
            running = State.running, autoSell = State.autoSell, sellMode = State.sellMode, autoBuy = State.autoBuy, autoBuyPets = State.autoBuyPets,
            buyOnce = State.buyOnce,
            harvestSpeed = State.harvestSpeed,
            autoSteal = State.autoSteal, protectBase = State.protectBase, snipeAuto = State.snipeAuto, snipeRar = State.snipeRar, snipePets = State.snipePets,
            snipeSkipOld = State.snipeSkipOld, snipeMaxAge = State.snipeMaxAge,
            antiAfk = State.antiAfk, antiFling = State.antiFling, antiFlingReset = State.antiFlingReset,
            antiWheelbarrow = State.antiWheelbarrow, antiShovel = State.antiShovel, lockPosition = State.lockPosition, autoShovelHit = State.autoShovelHit, autoProtectPets = State.autoProtectPets,
            autoWater = State.autoWater, autoPlant = State.autoPlant, plantSeeds = State.plantSeeds,
            autoMail = State.autoMail, mailTo = State.mailTo, mailItems = State.mailItems, mailLeave = State.mailLeave,
            plantSpacing = State.plantSpacing, plantMode = State.plantMode, autoSprinkle = State.autoSprinkle, sprinkleMutations = State.sprinkleMutations,
            cleanupTypes = State.cleanupTypes,
            buySeeds = State.buySeeds, buyGears = State.buyGears, buyPets = State.buyPets,
            eventSeeds = State.eventSeeds, autoCollectWild = State.autoCollectWild,
            perfMode = State.perfMode, hidePlants = State.hidePlants, hideAvatar = State.hideAvatar,
            limitHarvestKg = State.limitHarvestKg, maxHarvestKg = State.maxHarvestKg, espWeight = State.espWeight,
        }))
    end)
end

local function normSet(t)   -- coerce any on-disk shape (dict/array/mixed) into a clean {string = true} set
    local s = {}
    if type(t) == "table" then
        for k, v in pairs(t) do
            if type(k) == "number" and type(v) == "string" then s[v] = true
            elseif type(k) == "string" and v == true then s[k] = true end
        end
    end
    return s
end

local function loadConfig()
    if not _hasFiles then return end
    pcall(function()
        if not isfile(CFG_FILE) then return end
        local d = HttpService:JSONDecode(readfile(CFG_FILE))
        if type(d) ~= "table" then return end
        if type(d.running)     == "boolean" then State.running     = d.running end
        if type(d.harvestSpeed) == "number" then State.harvestSpeed = math.clamp(d.harvestSpeed, 1, 10); State.fireGap = math.max(0, (10 - State.harvestSpeed) * 0.025) end
        if type(d.autoSell)    == "boolean" then State.autoSell    = d.autoSell end
        if type(d.sellMode)    == "string"  and (d.sellMode == "Instant" or d.sellMode == "Full") then State.sellMode = d.sellMode end
        if type(d.autoBuy)     == "boolean" then State.autoBuy     = d.autoBuy end
        if type(d.autoBuyPets) == "boolean" then State.autoBuyPets = d.autoBuyPets end
        if type(d.buyOnce)     == "boolean" then State.buyOnce     = d.buyOnce end
        if type(d.autoSteal)   == "boolean" then State.autoSteal   = d.autoSteal end
        if type(d.protectBase) == "boolean" then State.protectBase = d.protectBase end
        if type(d.antiAfk)     == "boolean" then State.antiAfk     = d.antiAfk end
        if type(d.antiFling)   == "boolean" then State.antiFling   = d.antiFling end
        if type(d.antiFlingReset) == "boolean" then State.antiFlingReset = d.antiFlingReset end
        if type(d.antiWheelbarrow) == "boolean" then State.antiWheelbarrow = d.antiWheelbarrow end
        if type(d.antiShovel)      == "boolean" then State.antiShovel      = d.antiShovel end
        if type(d.autoShovelHit)   == "boolean" then State.autoShovelHit   = d.autoShovelHit end
        if type(d.autoProtectPets) == "boolean" then State.autoProtectPets = d.autoProtectPets end
        if type(d.lockPosition) == "boolean" then State.lockPosition = d.lockPosition end
        if type(d.autoWater)   == "boolean" then State.autoWater   = d.autoWater end
        if type(d.autoPlant)   == "boolean" then State.autoPlant   = d.autoPlant end
        if d.plantOnMe == true then State.plantMode = "At my feet" end   -- migrate old "plant at my feet" toggle into the placement mode
        if type(d.plantSeeds)  == "table"   then State.plantSeeds  = normSet(d.plantSeeds) end
        if type(d.plantSeed)   == "string" and d.plantSeed ~= "" then State.plantSeeds[d.plantSeed] = true end  -- migrate old single-pick
        if type(d.autoMail)     == "boolean" then State.autoMail     = d.autoMail end
        if type(d.mailTo)       == "string"  then State.mailTo       = d.mailTo end
        if type(d.mailItems) == "table" then
            State.mailItems = {}
            for _, p in ipairs(d.mailItems) do
                if type(p) == "table" and type(p.cat) == "string" and type(p.typeName) == "string" then
                    State.mailItems[#State.mailItems + 1] = { cat = p.cat, typeName = p.typeName }
                end
            end
        end
        if type(d.mailItemType) == "string" and type(d.mailItemCat) == "string" then  -- migrate old single pick
            State.mailItems[#State.mailItems + 1] = { cat = d.mailItemCat, typeName = d.mailItemType }
        end
        if type(d.mailLeave)    == "number"  then State.mailLeave    = math.clamp(d.mailLeave, 0, 10000) end
        if type(d.plantSpacing) == "number" then State.plantSpacing = d.plantSpacing end
        if type(d.plantMode)    == "string" then State.plantMode    = d.plantMode end
        if type(d.autoSprinkle) == "boolean" then State.autoSprinkle = d.autoSprinkle end
        if type(d.sprinkleMutations) == "boolean" then State.sprinkleMutations = d.sprinkleMutations end
        if type(d.cleanupTypes) == "table"   then State.cleanupTypes = normSet(d.cleanupTypes) end
        if type(d.snipeAuto)    == "boolean" then State.snipeAuto    = d.snipeAuto end
        if type(d.snipeRar)     == "table"   then State.snipeRar     = normSet(d.snipeRar) end
        if type(d.snipePets)    == "table"   then State.snipePets    = normSet(d.snipePets) end
        if type(d.snipeSkipOld) == "boolean" then State.snipeSkipOld = d.snipeSkipOld end
        -- migrate old broken values: anything < 3 can never pass the ~3s pipeline, so floor at 3
        if type(d.snipeMaxAge)  == "number"  then State.snipeMaxAge  = math.clamp(d.snipeMaxAge, 3, 300) end
        if type(d.buySeeds)    == "table"   then State.buySeeds    = normSet(d.buySeeds) end
        if type(d.buyGears)    == "table"   then State.buyGears    = normSet(d.buyGears) end
        if type(d.buyPets)     == "table"   then State.buyPets     = normSet(d.buyPets) end
        if type(d.eventSeeds)  == "table"   then State.eventSeeds  = normSet(d.eventSeeds) end
        if type(d.autoCollectWild) == "boolean" then State.autoCollectWild = d.autoCollectWild end
        if type(d.perfMode)   == "boolean" then State.perfMode   = d.perfMode end
        if type(d.hidePlants) == "boolean" then State.hidePlants = d.hidePlants end
        if type(d.hideAvatar) == "boolean" then State.hideAvatar = d.hideAvatar end
        if type(d.limitHarvestKg) == "boolean" then State.limitHarvestKg = d.limitHarvestKg end
        if type(d.maxHarvestKg)   == "number"  then State.maxHarvestKg   = math.clamp(d.maxHarvestKg, 1, 1000) end
        if type(d.espWeight)      == "boolean" then State.espWeight      = d.espWeight end
    end)
end

loadConfig()                    -- restore saved settings BEFORE the engine/UI start
State.saveConfig = saveConfig   -- exposed for the UI handlers + reset

-- ── CONFIG SHARING: export/import a portable code so settings can be reused on another account/device ──
local function exportConfig()
    pcall(saveConfig)                                              -- flush current State to disk first
    local ok, s = pcall(function() return readfile(CFG_FILE) end)
    return (ok and type(s) == "string" and #s > 1) and s or "{}"
end
local function importConfig(code)
    if type(code) ~= "string" then return false end
    code = (code:gsub("^%s+", ""):gsub("%s+$", ""))
    local ok, d = pcall(function() return HttpService:JSONDecode(code) end)
    if not ok or type(d) ~= "table" then return false end          -- not a valid config code
    if not _hasFiles then return false end
    pcall(function() writefile(CFG_FILE, code) end)                -- persist for next launch
    pcall(loadConfig)                                              -- re-read into State (reads the file we just wrote)
    pcall(function() if State.refreshUI then State.refreshUI() end end)   -- sync every UI control to the new State
    return true
end
State.exportConfig, State.importConfig = exportConfig, importConfig

-- FAST loading skip — kills the game's "Loading X/2500" preloader instantly instead of
-- waiting through the click→key skip phases. Verified safe: disabling LoadingScreenController +
-- hiding LoadingGui leaves the game fully playable (assets stream in background).
do
    local RF  = game:GetService("ReplicatedFirst")
    local VIM = game:GetService("VirtualInputManager")

    -- 1. remove Roblox's default loading screen immediately
    pcall(function() RF:RemoveDefaultLoadingScreen() end)

    -- 2. kill the game's LoadingScreenController every frame so its 2500-asset preload
    --    loop never gets to block — the game proceeds straight to playable.
    task.spawn(function()
        local deadline = os.clock() + 20
        while os.clock() < deadline do
            local ctrl = RF:FindFirstChild("LoadingScreenController")
            if ctrl and not ctrl.Disabled then pcall(function() ctrl.Disabled = true end) end
            task.wait()
        end
    end)

    -- 2b. CRITICAL post-load cleanup: killing the controller mid-load leaves THREE things
    --     the controller would normally have reset after preload finished:
    --       (a) camera stuck Scriptable on LoadingScreenCam ("stuck at loading" view)
    --       (b) Lighting Blur left enabled (the blurry screen)
    --       (c) HumanoidRootPart left Anchored (can't move)
    --     We reset all three ourselves for the first 15s after join.
    task.spawn(function()
        local L = game:GetService("Lighting")
        local deadline = os.clock() + 15
        while os.clock() < deadline do
            local cam  = workspace.CurrentCamera
            local char = LocalPlayer.Character
            local hum  = char and char:FindFirstChildWhichIsA("Humanoid")
            local hrp  = char and char:FindFirstChild("HumanoidRootPart")
            -- (a) camera → follow character
            if cam and hum and cam.CameraType == Enum.CameraType.Scriptable then
                pcall(function() cam.CameraType = Enum.CameraType.Custom end)
                pcall(function() cam.CameraSubject = hum end)
                pcall(function() LocalPlayer.CameraMode = Enum.CameraMode.Classic end)
            end
            -- (b) kill the loading blur
            for _, e in ipairs(L:GetDescendants()) do
                if e:IsA("BlurEffect") and e.Enabled then
                    pcall(function() e.Enabled = false; e.Size = 0 end)
                end
            end
            -- (c) unanchor the character so the player can move
            --     (safe in the load window — our lockPosition/steal aren't active yet)
            if hrp and hrp.Anchored then pcall(function() hrp.Anchored = false end) end
            task.wait(0.1)
        end
    end)

    -- 3. force-hide LoadingGui + all join/intro popups every frame for the first 30s
    task.spawn(function()
        local ok, pg = pcall(function() return LocalPlayer:WaitForChild("PlayerGui", 15) end)
        if not ok or not pg then return end
        local targets = { "LoadingGui", "TutorialUI", "GardenLevel", "CinematicBars", "GearCinematicBars", "OfflineAnimation" }
        local sentSkip = false
        local deadline = os.clock() + 30
        while os.clock() < deadline do
            for _, name in ipairs(targets) do
                local gui = pg:FindFirstChild(name)
                if gui then
                    pcall(function() if gui.Enabled then gui.Enabled = false end end)
                    if name == "GardenLevel" then
                        local show = gui:FindFirstChild("SHOW")
                        if show and show:IsA("BoolValue") and show.Value then
                            pcall(function() show.Value = false end)
                        end
                    end
                end
            end
            -- one-time skip-input as a belt-and-suspenders backup (game's own skip path)
            if not sentSkip then
                sentSkip = true
                pcall(function()
                    VIM:SendKeyEvent(true,  Enum.KeyCode.Space, false, game); task.wait(0.05)
                    VIM:SendKeyEvent(false, Enum.KeyCode.Space, false, game)
                end)
            end
            task.wait()
        end
    end)

    print("[YumaBlox] fast loading skip armed")
end

--===========================================================================--
-- PERFORMANCE HELPERS (graphics, plants, avatar)
--===========================================================================--
local _perfOrig   = {}   -- stores originals so we can restore on toggle-off
local _plantConns = {}   -- ChildAdded connections for hide-plants

local function applyPerfMode(on)
    local L = game:GetService("Lighting")
    if on then
        _perfOrig.shadows    = L.GlobalShadows
        _perfOrig.brightness = L.Brightness
        _perfOrig.fogEnd     = L.FogEnd
        L.GlobalShadows = false
        L.Brightness    = 0
        L.FogEnd        = 1e9
        for _, e in ipairs(L:GetDescendants()) do
            if e:IsA("PostEffect") then
                _perfOrig["fx_"..e:GetFullName()] = e.Enabled
                e.Enabled = false
            end
        end
        -- disable particles & beams everywhere EXCEPT WildPetSpawns (keep wild pets visible)
        for _, e in ipairs(workspace:GetDescendants()) do
            if e:IsA("ParticleEmitter") or e:IsA("Beam") or e:IsA("Trail") then
                local inPets = false
                local p = e.Parent
                while p do if p.Name == "WildPetSpawns" then inPets = true; break end; p = p.Parent end
                if not inPets then
                    _perfOrig["pe_"..tostring(e)] = e.Enabled
                    pcall(function() e.Enabled = false end)
                end
            end
        end
        pcall(function() setfpscap(30) end)
        pcall(function() game:GetService("RunService"):Set3dRenderingEnabled(false) end)
    else
        L.GlobalShadows = _perfOrig.shadows    ~= nil and _perfOrig.shadows    or true
        L.Brightness    = _perfOrig.brightness ~= nil and _perfOrig.brightness or 2
        L.FogEnd        = _perfOrig.fogEnd     ~= nil and _perfOrig.fogEnd     or 100000
        for _, e in ipairs(L:GetDescendants()) do
            if e:IsA("PostEffect") then
                local orig = _perfOrig["fx_"..e:GetFullName()]
                if orig ~= nil then e.Enabled = orig end
            end
        end
        for _, e in ipairs(workspace:GetDescendants()) do
            if e:IsA("ParticleEmitter") or e:IsA("Beam") or e:IsA("Trail") then
                local orig = _perfOrig["pe_"..tostring(e)]
                if orig ~= nil then pcall(function() e.Enabled = orig end) end
            end
        end
        pcall(function() setfpscap(0) end)
        pcall(function() game:GetService("RunService"):Set3dRenderingEnabled(true) end)
    end
end

-- hide ONE instance (part / decal / gui / particle). Decal transparency is
-- stored so it restores cleanly. BaseParts use LocalTransparencyModifier (auto-restore).
local _hiddenDecals = {}   -- decal/texture -> original Transparency
local _hiddenEnabled = {}  -- BillboardGui/SurfaceGui/emitter -> original Enabled (so un-hiding never turns ON a label the game had OFF)
local function hideInst(d, on)
    if d:IsA("BasePart") then
        pcall(function() d.LocalTransparencyModifier = on and 1 or 0 end)
    elseif d:IsA("Decal") or d:IsA("Texture") then
        if on then
            if _hiddenDecals[d] == nil then _hiddenDecals[d] = d.Transparency end
            pcall(function() d.Transparency = 1 end)
        else
            local o = _hiddenDecals[d]
            if o ~= nil then pcall(function() d.Transparency = o end); _hiddenDecals[d] = nil end
        end
    elseif d:IsA("BillboardGui") or d:IsA("SurfaceGui")
        or d:IsA("ParticleEmitter") or d:IsA("Beam") or d:IsA("Trail") then
        -- remember the ORIGINAL Enabled and restore it on un-hide — otherwise un-hiding force-enables
        -- labels the game had turned OFF, which is the "big label on every plant" the user saw.
        if on then
            if _hiddenEnabled[d] == nil then _hiddenEnabled[d] = d.Enabled end
            pcall(function() d.Enabled = false end)
        else
            local o = _hiddenEnabled[d]
            if o ~= nil then pcall(function() d.Enabled = o end); _hiddenEnabled[d] = nil end
            -- never recorded → don't touch it (leave the game's own state); this is what stops un-hide
            -- from force-enabling labels that were OFF.
        end
    end
end

-- hide the ENTIRE plot: plants, fruits, garden decorations, signs, sprinklers.
-- Hides ALL gardens INCLUDING your own (purely visual — harvest prompts still fire).
local function hidePlotAll(plot, on)
    for _, d in ipairs(plot:GetDescendants()) do hideInst(d, on) end
end

local function applyHidePlants(on)
    for _, c in ipairs(_plantConns) do pcall(function() c:Disconnect() end) end
    _plantConns = {}
    local gardens = workspace:FindFirstChild("Gardens")
    if not gardens then return end

    -- bulk hide existing plots (yield per plot so we never freeze a frame)
    task.spawn(function()
        for _, plot in ipairs(gardens:GetChildren()) do
            pcall(hidePlotAll, plot, on)
            task.wait()
        end
    end)

    if on then
        -- catch newly-grown fruits / newly-planted plants on EVERY plot (own included)
        for _, plot in ipairs(gardens:GetChildren()) do
            table.insert(_plantConns, plot.DescendantAdded:Connect(function(d)
                if State.hidePlants then hideInst(d, true) end
            end))
        end
        -- catch entire NEW plots arriving (other players joining)
        table.insert(_plantConns, gardens.ChildAdded:Connect(function(plot)
            task.wait(1)
            pcall(hidePlotAll, plot, true)
            table.insert(_plantConns, plot.DescendantAdded:Connect(function(d)
                if State.hidePlants then hideInst(d, true) end
            end))
        end))
    end
end

local function applyHideAvatar(on)
    local char = LocalPlayer.Character
    if not char then return end
    for _, c in ipairs(char:GetChildren()) do
        if c:IsA("Accessory") or c:IsA("Hat") then
            local handle = c:FindFirstChild("Handle")
            if handle then pcall(function() handle.LocalTransparencyModifier = on and 1 or 0 end) end
        end
    end
end

-- apply saved performance states after loadConfig
if State.perfMode   then pcall(applyPerfMode,   true) end
if State.hidePlants then pcall(applyHidePlants,  true) end
if State.hideAvatar then pcall(applyHideAvatar,  true) end

--===========================================================================--
-- AUTO-EXECUTE ON TELEPORT  (mirrors pet_hunter.lua's armReload pattern)
-- armReload() is called BEFORE every TeleportToPlaceInstance — unconditionally,
-- on every attempt including failures. queue_on_teleport replaces the previous
-- payload so calling it multiple times is safe and keeps the queue fresh.
-- No per-hop flag needed: stateless like pet_hunter's armReload().
--===========================================================================--
local _qtp = queue_on_teleport or queueonteleport
    or (syn and syn.queue_on_teleport)
    or (fluxus and fluxus.queue_on_teleport)
    or (getgenv and getgenv().queue_on_teleport)

-- Self-retrying loader with per-server dedup guard.
-- Uses game.JobId as the key so stale flags from previous servers are ignored.
-- getgenv() persists across server joins — a bare boolean flag would block
-- execution in every new server. JobId changes per server so it never sticks.
local _RELOAD_SCRIPT = SNIPE_BASE ~= "" and ([[
-- stamp arrival time FIRST so all snipe gates hold in the new server
-- getgenv() may not persist across joins; this guarantees YB_LAST_SNIPE
-- is set BEFORE any script logic runs, preventing instant re-snipe on arrival
if getgenv then getgenv().YB_LAST_SNIPE = os.time() end
local _jobId = game.JobId
if getgenv then
    local _g = getgenv()
    if _g.YB_LOADING_JOB == _jobId then return end
    _g.YB_LOADING_JOB = _jobId
end
task.spawn(function()
    for _i=1,120 do
        local ok,src=pcall(function() return game:HttpGet("%s/pubscript") end)
        if ok and type(src)=="string" and #src>100 then
            local fn=loadstring(src)
            if fn then pcall(fn) end
            break
        end
        task.wait(3)
    end
    if getgenv then getgenv().YB_LOADING_JOB = nil end
end)]]):format(SNIPE_BASE) or nil

local function armReload()
    if _qtp and _RELOAD_SCRIPT then
        pcall(_qtp, _RELOAD_SCRIPT)
    end
end

--===========================================================================--
-- PLOT DETECTION + HARVEST
--===========================================================================--
local function findMyPlot()
    local gardens = Workspace:FindFirstChild("Gardens")
    if not gardens then return nil end
    for _, plot in ipairs(gardens:GetChildren()) do
        if plot:GetAttribute("OwnerUserId") == LocalPlayer.UserId then return plot end
    end
    for _, plot in ipairs(gardens:GetChildren()) do          -- fallback: my plants
        local plants = plot:FindFirstChild("Plants")
        if plants then
            for _, pl in ipairs(plants:GetChildren()) do
                if pl:GetAttribute("UserId") == LocalPlayer.UserId then return plot end
            end
        end
    end
    return nil
end

local FIRE_GRACE = 0.5   -- if a fired prompt is still ripe past this, re-fire it (verify-by-rescan)
--===========================================================================--
-- FRUIT WEIGHT (kg) + per-type base weight  — used by the harvest weight-cap + the ESP.
--   LIVE-CONFIRMED: a fruit's "Base" part is a SizeMulti-sided cube, and a harvested
--   tool's  Weight / SizeMulti  is an EXACT per-type constant (Ghost Pepper = 7.5). The
--   base-weight table is server-side, so we persist a LEARNED copy in getgenv() and
--   auto-calibrate it from real harvests (see the calibration block below).
--===========================================================================--
-- LIVE-CONFIRMED universal: Weight(kg) = SizeMulti * 7.5. Verified exact on two very different fruits
-- — Ghost Pepper (1.800 -> 13.50) AND Dragon's Breath (4.161 -> 31.21), both ratio = 7.5000. This is a
-- FIXED constant on purpose: NO per-type auto-learn table (mispaired samples corrupted it and made the
-- weight cap under-read big fruit). A constant can't drift, so the cap stays exact at any harvest speed.
local WEIGHT_PER_SIZE = 7.5
ENV().GAG_BaseWeight = nil          -- wipe any corrupted auto-learn table left by older runs

local function fruitOfPrompt(p)            -- ascend from a prompt to its owning fruit Model (the one carrying CorePartName)
    local n = p
    while n and n ~= Workspace do
        if n:IsA("Model") and n:GetAttribute("CorePartName") then return n end
        n = n.Parent
    end
    return nil
end

-- weight (kg) of a fruit (final from spawn) + its type
local function fruitWeight(fruit)
    local size = tonumber(fruit:GetAttribute("SizeMulti")) or 1
    return WEIGHT_PER_SIZE * size, fruit:GetAttribute("CorePartName")
end

local function isHarvestPrompt(p)                -- catch ALL harvestables incl. bamboo (not only Fruits.*.HarvestPart)
    if p.Name == "HarvestPrompt" then return true end
    local txt = (tostring(p.ActionText) .. " " .. tostring(p.ObjectText)):lower()
    return (txt:find("harvest") or txt:find("collect") or txt:find("pick")) ~= nil
end
local function collectPrompts(plot, seen, now)
    local out = {}
    local plants = plot and plot:FindFirstChild("Plants")
    if not plants then return out end
    -- weight cap: when on, leave fruit heavier than maxHarvestKg on the plant
    local cap = (State.limitHarvestKg and State.maxHarvestKg and State.maxHarvestKg > 0) and State.maxHarvestKg or nil
    for _, plant in ipairs(plants:GetChildren()) do
        for _, d in ipairs(plant:GetDescendants()) do          -- scan the whole plant so bamboo/odd layouts are caught
            if d:IsA("ProximityPrompt") and d.Enabled and isHarvestPrompt(d) then
                local skip = false
                if cap then
                    local fr = fruitOfPrompt(d)
                    if fr and fruitWeight(fr) > cap then skip = true end   -- too heavy -> keep growing
                end
                if not skip then
                    local firedAt = seen and seen[d]
                    if (not firedAt) or (now - firedAt >= FIRE_GRACE) then out[#out + 1] = { prompt = d } end
                end
            end
        end
    end
    return out
end

local function fire(prompt)
    pcall(fireprompt, prompt)   -- single-arg form (verified); 2nd arg on some executors is a COUNT
end

--===========================================================================--
-- NETWORKING (cached require) + packet helper
--===========================================================================--
local _net
local function getNet()
    if _net then return _net end
    pcall(function()
        local sm = ReplicatedStorage:FindFirstChild("SharedModules")
        local n = sm and sm:FindFirstChild("Networking")
        _net = n and require(n)
    end)
    return _net
end
local function packet(group, name)
    local net = getNet()
    local g = net and net[group]
    return g and g[name]
end

--===========================================================================--
-- AUTO-SELL  (Networking.NPCS.SellAll)
--===========================================================================--
local function refreshInventory()
    local fc  = LocalPlayer:GetAttribute("FruitCount")
    local cap = LocalPlayer:GetAttribute("MaxFruitCapacity")
    if fc  ~= nil then State.fruitCount = fc end
    if cap ~= nil then State.maxFruit   = cap end
    return fc, cap
end

local lastSell = 0
local function trySell()
    local fc, cap = refreshInventory()
    if not State.autoSell then return end
    if fc == nil or cap == nil or cap <= 0 then return end
    if fc <= 0 then return end                                   -- nothing to sell
    if (os.clock() - lastSell) < SELL_COOLDOWN then return end   -- hard rate-limit, always honoured
    if State.sellMode == "Full" and fc < math.floor(cap * SELL_AT_PERCENT) then return end   -- Full: only at (near) capacity. Instant (default): sell now, paced by SELL_COOLDOWN.
    local p = packet("NPCS", "SellAll"); if not p then return end
    lastSell = os.clock()
    State.status = "selling…"
    if pcall(function() p:Fire() end) then State.sold += 1 end
end

--===========================================================================--
-- AUTO-BUY SHOPS  (generic: seeds + gears)
--===========================================================================--
local SHOP_SKIP = { ItemTemplate = true, Padding = true, Sheckles_Shelf = true, Robux_Shelf = true }

-- find the ScrollingFrame holding a shop's item entries (SeedShop=NormalShop; GearShop=the
-- ScrollingFrame with the most "xN in Stock" entries)
local function shopList(guiName)
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    local gui = pg and pg:FindFirstChild(guiName)
    if not gui then return nil end
    local named = gui:FindFirstChild("NormalShop", true)
    if named and named:IsA("ScrollingFrame") then return named end
    local best, bestN
    for _, sf in ipairs(gui:GetDescendants()) do
        if sf:IsA("ScrollingFrame") then
            local n = 0
            for _, c in ipairs(sf:GetChildren()) do
                if c:IsA("Frame") and not SHOP_SKIP[c.Name] and c:FindFirstChild("Stock_Text", true) then n += 1 end
            end
            if n > 0 and (not bestN or n > bestN) then best, bestN = sf, n end
        end
    end
    return best
end

local function shopItems(guiName)
    local list, names = shopList(guiName), {}
    if not list then return names end
    for _, f in ipairs(list:GetChildren()) do
        if f:IsA("Frame") and not SHOP_SKIP[f.Name] and f:FindFirstChild("Stock_Text", true) then
            names[#names + 1] = f.Name
        end
    end
    table.sort(names)
    return names
end

local function shopStock(guiName, name)
    local list = shopList(guiName)
    local f = list and list:FindFirstChild(name)
    local st = f and f:FindFirstChild("Stock_Text", true)
    local n = st and tostring(st.Text):match("x%s*(%d+)")
    return tonumber(n) or 0
end

local SHOPS = {
    { sel = "buySeeds", gui = "SeedShop", group = "SeedShop", buy = "PurchaseSeed" },
    { sel = "buyGears", gui = "GearShop", group = "GearShop", buy = "PurchaseGear" },
}

local function sheckles()
    local ls = LocalPlayer:FindFirstChild("leaderstats")
    local s = ls and ls:FindFirstChild("Sheckles")
    return (s and s.Value) or 0
end

--===========================================================================--
-- MOON EVENTS — seed-name picker for the wild auto-pickup
--   allSeedNames() feeds the "seeds to pick up" dropdown; always offers Gold/Rainbow.
--===========================================================================--
local function allSeedNames()
    local sv = ReplicatedStorage:FindFirstChild("StockValues")
    local items = sv and sv:FindFirstChild("SeedShop") and sv.SeedShop:FindFirstChild("Items")
    local out, seen = {}, {}
    if items then for _, c in ipairs(items:GetChildren()) do if not seen[c.Name] then seen[c.Name] = true; out[#out + 1] = c.Name end end end
    for _, n in ipairs({ "Gold", "Rainbow" }) do if not seen[n] then seen[n] = true; out[#out + 1] = n end end  -- always offer these
    table.sort(out)
    return out
end

--===========================================================================--
-- AUTO-COLLECT WILD EVENT SEEDS  (Gold/Rainbow seeds spawn as Models in
--   workspace.DroppedItems during Gold Moon / Rainbow Moon). There is NO
--   client-side pickup remote — pickup is SERVER-side via the item's
--   ProximityPrompt (the controller only DISABLES that prompt for OwnerRestricted
--   items dropped by someone else; wild server-spawned seeds are NOT restricted,
--   so their prompt stays live). So this reuses the PROVEN wild-PET template:
--   teleport HRP onto the item (inside MaxActivationDistance), fireproximityprompt
--   its prompt, confirm it's gone, restore position. Because fireproximityprompt is
--   NOT guaranteed to drive the server (it failed for STEAL), we ALSO physically
--   stand on the item every tick so any touch / auto-pickup path fires too, and we
--   hold for several ticks to beat snap-back. Same name filter as the buy list
--   (State.eventSeeds), so "Gold"/"Rainbow" govern both buying and collecting.
--===========================================================================--
-- Gold/Rainbow seed packs spawn during Goldmoon / Rainbow Moon as children of
-- Workspace.Map.SeedPackSpawnServerLocations (attributes GoldSeed/RainbowSeed/SeedPack) with a floating
-- visual under Workspace.Map.SeedPackSpawnClient. There is NO client claim remote — SeedPackSpawn.Claimed/
-- FX/Announce are all server->client; the SERVER claims the pack when you REACH it. So we move onto the pack
-- and hold (touch/proximity) until it despawns. (It is NOT in workspace.DroppedItems — that was the bug.)
local function seedPackFolders()
    local map = Workspace:FindFirstChild("Map")
    if not map then return nil, nil end
    return map:FindFirstChild("SeedPackSpawnServerLocations"), map:FindFirstChild("SeedPackSpawnClient")
end

local function packPart(inst)
    if inst:IsA("BasePart") then return inst end
    local pp = inst:IsA("Model") and (inst.PrimaryPart or inst:FindFirstChildWhichIsA("BasePart")) or nil
    if pp then return pp end
    for _, d in ipairs(inst:GetDescendants()) do if d:IsA("BasePart") then return d end end
    return nil
end

-- any enabled ProximityPrompt on the pack (some spawns may carry one; fire it too if present)
local function itemPickupPrompt(model)
    for _, d in ipairs(model:GetDescendants()) do if d:IsA("ProximityPrompt") and d.Enabled then return d end end
    return nil
end

-- live weather string (workspace.ActiveWeather = "Goldmoon"/"Rainbow Moon"/"Moon"/"Day"/...)
local function activeWeather()
    local w = Workspace:GetAttribute("ActiveWeather")
    return (type(w) == "string" and w ~= "") and w or nil
end
local function moonEventActive()                       -- fail-OPEN: unknown weather -> allow
    local w = activeWeather()
    if not w then return true end
    local lw = w:lower()
    return (lw:find("gold") or lw:find("rainbow")) and true or false
end

-- is this a Gold/Rainbow seed pack we want? (by attribute first, then by name) -> ok, "Gold"/"Rainbow"
local function wantsPack(inst)
    local gold = inst:GetAttribute("GoldSeed") == true
    local rbow = inst:GetAttribute("RainbowSeed") == true
    if not (gold or rbow) then
        for _, d in ipairs(inst:GetDescendants()) do
            if d:GetAttribute("GoldSeed") == true then gold = true end
            if d:GetAttribute("RainbowSeed") == true then rbow = true end
            if gold and rbow then break end
        end
    end
    local n = inst.Name:lower()
    if not gold and n:find("gold") then gold = true end
    if not rbow and (n:find("rainbow") or n:find("rbow")) then rbow = true end
    if gold and State.eventSeeds.Gold then return true, "Gold" end
    if rbow and State.eventSeeds.Rainbow then return true, "Rainbow" end
    return false
end
State._wantsPack = wantsPack       -- expose for the on-map counter in the refresh loop

local function wildSeedCandidates()
    local targets, seen = {}, {}
    local serverLoc, clientVis = seedPackFolders()
    if serverLoc then for _, p in ipairs(serverLoc:GetChildren()) do
        local ok, kind = wantsPack(p)
        if ok and not seen[p] and packPart(p) then seen[p] = true; targets[#targets + 1] = { inst = p, kind = kind } end
    end end
    if clientVis then for _, m in ipairs(clientVis:GetChildren()) do
        local ok, kind = wantsPack(m)
        if ok and not seen[m] and packPart(m) then seen[m] = true; targets[#targets + 1] = { inst = m, kind = kind } end
    end end
    return targets, (serverLoc or clientVis)
end

local function tryCollectWild()
    if not State.autoCollectWild then return end
    if State.tpBusy then return end
    local targets, folder = wildSeedCandidates()
    if #targets == 0 then
        if not folder then State.collectStatus = "watching… (no spawn folder yet)"
        elseif not moonEventActive() then State.collectStatus = ("watching… (%s — no moon event)"):format(activeWeather() or "?")
        else State.collectStatus = "watching… no Gold/Rainbow packs" end
        return
    end
    local char = LocalPlayer.Character
    local hrp  = char and char:FindFirstChild("HumanoidRootPart")
    if not hrp then return end
    State.tpBusy = true
    local saved, wasAnchored = hrp.CFrame, hrp.Anchored
    pcall(function()
        hrp.Anchored = false
        for _, t in ipairs(targets) do
            if not (State.alive and State.autoCollectWild) then break end
            if hrp.Parent == nil then return end
            local inst = t.inst
            if not inst.Parent then continue end
            local part = packPart(inst)
            if not part then continue end

            -- STEP 1: walk to the pack using stepped movement (no instant jump)
            State.collectStatus = "walking to " .. t.kind .. " seed…"
            local destPos = part.CFrame.Position + Vector3.new(0, COLLECT_STAND_OFFSET, 0)
            local startP  = hrp.Position
            local dist    = (destPos - startP).Magnitude
            local steps   = math.clamp(math.ceil(dist / 8), 1, 50)
            for si = 1, steps do
                if hrp.Parent == nil then break end
                if not (inst.Parent and State.alive and State.autoCollectWild) then break end
                pcall(function() hrp.CFrame = CFrame.new(startP:Lerp(destPos, si / steps)) end)
                waitFn(0.05)
            end

            -- already claimed while walking to it
            if not inst.Parent then
                State.wildCollected += 1
                State.collectStatus = "collected " .. t.kind .. " seed 🌱"
                continue
            end

            -- STEP 2: pin on the pack and hold E until the server claims it
            -- (inst.Parent == nil means the server gave it to us)
            -- Only move to the NEXT pack once this one is fully claimed or times out.
            State.collectStatus = "claiming " .. t.kind .. " seed… (holding E)"
            -- press and hold E (the pack requires a long-press interaction)
            pcall(function() VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.E, false, game) end)
            local claimDeadline = os.clock() + 6   -- 6s max per pack
            local claimed = false
            while os.clock() < claimDeadline do
                if hrp.Parent == nil then break end
                if not (State.alive and State.autoCollectWild) then break end
                if not inst.Parent then
                    claimed = true
                    break
                end
                -- keep pinned as pack may drift slightly
                if part and part.Parent then
                    destPos = part.CFrame.Position + Vector3.new(0, COLLECT_STAND_OFFSET, 0)
                    pcall(function() hrp.CFrame = CFrame.new(destPos) end)
                end
                local prompt = itemPickupPrompt(inst)
                if prompt and prompt.Enabled then fire(prompt) end
                waitFn(COLLECT_SETTLE)
            end
            -- release E regardless of outcome
            pcall(function() VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.E, false, game) end)
            if claimed then
                State.wildCollected += 1
                State.collectStatus = "collected " .. t.kind .. " seed 🌱"
            end
            -- only proceed to next pack after this one is done
        end
    end)
    if hrp.Parent then
        pcall(function() hrp.Anchored = wasAnchored end)
        pcall(function() hrp.CFrame = saved end)
    end
    State.tpBusy = false
end

local function tryBuy()
    if not State.autoBuy then return end
    for _, spec in ipairs(SHOPS) do
        local p = packet(spec.group, spec.buy)
        if p then
            local sel = {}                                   -- snapshot (UI may edit mid-sweep)
            for n in pairs(State[spec.sel]) do sel[#sel + 1] = n end
            for _, name in ipairs(sel) do
                local maxN = shopStock(spec.gui, name)       -- cap at the stock shown this sweep
                for _ = 1, maxN do
                    if not (State.alive and State.autoBuy) then return end
                    if not State[spec.sel][name] then break end          -- un-ticked mid-sweep
                    local stB = shopStock(spec.gui, name)
                    if stB <= 0 then break end                           -- out of stock now
                    local shB = sheckles()
                    pcall(function() p:Fire(name) end)
                    waitFn(BUY_FIRE_GAP)
                    if sheckles() < shB then
                        State.bought += 1                                -- confirmed (Sheckles dropped)
                    elseif shopStock(spec.gui, name) >= stB then
                        break                                            -- no progress -> broke/rejected, stop this item
                    end
                end
            end
        end
    end
end

--===========================================================================--
-- AUTO-BUY PETS  (wild pets enforce proximity, so teleport in, fire Buy, restore)
--   Verified live: fireproximityprompt from afar fails (loses the spawn); teleporting
--   HRP within range then firing buys it. Cost is parsed from prompt.ObjectText.
--===========================================================================--
local function wildPetSpawns()
    local map = Workspace:FindFirstChild("Map")
    return map and map:FindFirstChild("WildPetSpawns")
end

local KNOWN_PETS = { "Frog", "Deer", "Owl", "Robin", "Bunny" }   -- fallback if PetModules can't be read
local function getPetTypes()                            -- full roster (RS.SharedModules.PetModules) + spawned, deduped
    local seen, list = {}, {}
    local function add(n) if n and n ~= "" and not seen[n] then seen[n] = true; list[#list + 1] = n end end
    local sm = ReplicatedStorage:FindFirstChild("SharedModules")
    local pm = sm and sm:FindFirstChild("PetModules")
    if pm then
        for _, c in ipairs(pm:GetChildren()) do add(c.Name) end   -- the game's complete pet list
    end
    for _, n in ipairs(KNOWN_PETS) do add(n) end
    local wps = wildPetSpawns()
    if wps then for _, m in ipairs(wps:GetChildren()) do add(m:GetAttribute("PetName")) end end
    table.sort(list)
    return list
end

local function petCost(prompt)               -- "¢10,000" -> 10000
    return tonumber((tostring(prompt.ObjectText):gsub("[^%d]", ""))) or math.huge
end

local function tryBuyPets()
    if not State.autoBuyPets then return end
    if State.buyOnce and not State.buyArmed then return end   -- Buy Once: already bought one this arm; wait for re-arm
    local wps = wildPetSpawns(); if not wps then return end
    if State.tpBusy then return end
    local char = LocalPlayer.Character
    local hrp  = char and char:FindFirstChild("HumanoidRootPart")
    if not hrp then return end

    -- build candidate list, sorted NEAREST FIRST for fastest detection.
    -- BUY if: the pet NAME is explicitly ticked, OR its RARITY matches your Auto-Snipe
    -- rarities (so a sniped Mythic/Super pet is bought automatically — no name needed).
    local targets = {}
    for _, m in ipairs(wps:GetChildren()) do
        local name = m:GetAttribute("PetName")
        if name and m.Parent then
            local rar    = m:GetAttribute("Rarity") or phPetRarity(name)
            local wanted = State.buyPets[name] or raritySelected(rar)
            if wanted then
                local rp = m:FindFirstChild("RootPart")
                local bp = rp and rp:FindFirstChild("BuyPrompt")
                if rp and bp and bp.Enabled and sheckles() >= petCost(bp) then
                    local dist = (rp.Position - hrp.Position).Magnitude
                    targets[#targets+1] = { m=m, rp=rp, bp=bp, name=name, dist=dist }
                end
            end
        end
    end
    if #targets == 0 then return end
    table.sort(targets, function(a, b) return a.dist < b.dist end)

    State.tpBusy = true
    local saved, wasAnchored = hrp.CFrame, hrp.Anchored
    local buyDeadline = os.clock() + 16   -- never hold the HRP mutex longer than this (raised for the slower glide; still under the 20s tpBusy watchdog)
    pcall(function()
        hrp.Anchored = false
        for _, t in ipairs(targets) do
            if os.clock() > buyDeadline then break end   -- time budget exhausted → give up, release mutex
            local m, rp, bp, name = t.m, t.rp, t.bp, t.name
            if not (State.alive and State.autoBuyPets and m.Parent and bp.Enabled) then break end
            if hrp.Parent == nil then return end

            local shB = sheckles()
            local bought = false

            -- re-resolve char per pet (handles respawns between targets)
            char = LocalPlayer.Character
            hrp  = char and char:FindFirstChild("HumanoidRootPart")
            if not hrp then break end

            pcall(function()
                hrp.Anchored = false
                for attempt = 1, 10 do
                    if os.clock() > buyDeadline then break end   -- respect the overall time budget
                    if not (m.Parent and bp.Enabled and State.alive and State.autoBuyPets) then break end
                    if hrp.Parent == nil then return end

                    -- always use pet's CURRENT position (re-read each attempt so we track wandering)
                    local destPos = rp.CFrame.Position + Vector3.new(0, 3, 0)
                    local startP  = hrp.Position
                    local dist    = (destPos - startP).Magnitude

                    if dist <= bp.MaxActivationDistance then
                        -- already in range — just pin and fire
                        for _ = 1, 4 do
                            if hrp.Parent == nil then break end
                            pcall(function() hrp.CFrame = CFrame.new(rp.CFrame.Position + Vector3.new(0, 3, 0)) end)
                            waitFn(PET_STEP_WAIT)
                        end
                    else
                        -- step toward pet's CURRENT position
                        -- cap raised to 40 (was 20) — handles pets up to 320 studs away
                        local steps = math.clamp(math.ceil(dist / PET_STEP_DIST), 1, 40)
                        for si = 1, steps do
                            if hrp.Parent == nil then break end
                            if not (m.Parent and State.alive and State.autoBuyPets) then break end
                            pcall(function() hrp.CFrame = CFrame.new(startP:Lerp(destPos, si / steps)) end)
                            waitFn(PET_STEP_WAIT)
                        end
                        -- pin for proximity registration
                        for _ = 1, 6 do
                            if hrp.Parent == nil then break end
                            -- refresh destPos each pin tick — pet may have moved
                            local pinPos = rp.CFrame.Position + Vector3.new(0, 3, 0)
                            pcall(function() hrp.CFrame = CFrame.new(pinPos) end)
                            waitFn(PET_STEP_WAIT)
                        end
                    end

                    fire(bp)
                    waitFn(0.1)   -- server acks fireproximityprompt in ~0.27s; 0.1s is enough (was 0.4s)
                    if m.Parent == nil or not bp.Enabled or sheckles() < shB then bought = true; break end
                end
            end)

            if hrp.Parent then
                pcall(function() hrp.Anchored = wasAnchored end)
                pcall(function() hrp.CFrame = saved end)
            end
            if bought then
                State.bought += 1; State.status = "bought pet: " .. name
                if State.buyOnce then
                    State.buyArmed = false   -- disarm: stop after this single buy until next snipe-arrival / re-toggle re-arms
                    ybNotify("YumaBlox", "🛒 Bought 1 pet (Buy Once) — paused. Re-arms on next snipe-join, or re-toggle Auto Buy Pets.", 5)
                    break                    -- stop scanning the rest of the targets this pass
                end
            end
        end
    end)
    if hrp and hrp.Parent then
        pcall(function() hrp.Anchored = wasAnchored end)
        pcall(function() hrp.CFrame = saved end)
    end
    State.tpBusy = false
end

--===========================================================================--
-- AUTO-STEAL  (Networking.Steal — verified mechanism; NIGHT-ONLY, server-gated)
--   Other players' fruit have HarvestPart.StealPrompt (Action "Steal"). The steal
--   call is Networking.Steal.BeginSteal(ownerUserId, PlantId, FruitId) — all three
--   are attributes on the fruit. The server enforces:
--       * ReplicatedStorage.Night.Value == true   ("You can only steal at night!")
--       * 10-stud proximity + line-of-sight to the StealPrompt
--       * IsPlantStealable (SharedModules.Flags.StealFlags)
--   Value of a fruit = SellValueData[CorePartName] * SizeMulti — we steal the
--   highest-value stealable fruit in the server first. Flow per target:
--       teleport onto it -> BeginSteal -> teleport back to your base -> CompleteSteal
--       -> restore original position. CancelSteal aborts a half-started steal.
--   NOTE: the actual grab TRIGGER is not yet live-verified (every method tried by night
--   was a no-op except an untested hold-position + BeginSteal-remote loop, which this
--   implements). Confirm + tune once it's night in-game; see steal_capture.lua.
--===========================================================================--
local function isNight()
    local n = ReplicatedStorage:FindFirstChild("Night")
    return (n and n.Value == true) or false
end

local function carrying()   -- am I carrying a stolen fruit RIGHT NOW?
    -- REAL signal: the server welds the stolen fruit as a MODEL into your Character (StealController
    -- addStolenFruitVisual -> v6.Parent = Character, line 722). A normal character has NO Model children.
    -- StolenCarryValue is a STALE CUMULATIVE value (stays >0 after banking) -> it is NOT a carry flag.
    local ch = LocalPlayer.Character
    if not ch then return false end
    for _, c in ipairs(ch:GetChildren()) do
        if c:IsA("Model") and c:FindFirstChildWhichIsA("BasePart") then return true end   -- a welded stolen fruit
    end
    if LocalPlayer:GetAttribute("CarryingStolenFruit") == true then return true end        -- secondary signal
    -- backup: the game disables BackpackGui while you carry (addStolenFruitVisual line 409 / clear line 819)
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    local bp = pg and pg:FindFirstChild("BackpackGui")
    if bp and bp:IsA("ScreenGui") and bp.Enabled == false then return true end
    return false
end

local _svd
local function getSVD()
    if _svd then return _svd end
    pcall(function()
        local sm = ReplicatedStorage:FindFirstChild("SharedModules")
        local s = sm and sm:FindFirstChild("SellValueData")
        _svd = s and require(s)
    end)
    return _svd or {}
end

local function fruitValue(fruit)                       -- SellValueData[CorePartName] * SizeMulti
    local core = fruit:GetAttribute("CorePartName")
    local base = core and tonumber(getSVD()[core]) or 0
    local size = tonumber(fruit:GetAttribute("SizeMulti")) or 1
    return base * size, core
end

-- EXACT sell value via the game's own FruitValueCalc(type, weight, mutations, player, split).
-- value = floor(SellValueData[type] * weight^exponent * mutationMult * friendBonus). We pass no
-- mutations (base price) + the real LocalPlayer (for the Friends bonus). Falls back to base*weight.
local _fvc
local function getFVC()
    if _fvc ~= nil then return _fvc end
    _fvc = false
    pcall(function()
        local sm = ReplicatedStorage:FindFirstChild("SharedModules")
        local m = sm and sm:FindFirstChild("FruitValueCalc")
        if m then _fvc = require(m) end
    end)
    return _fvc
end
local function fruitSellValue(fruit, weightKg, core)
    core = core or fruit:GetAttribute("CorePartName")
    weightKg = weightKg or fruitWeight(fruit)
    local fvc = getFVC()
    if type(fvc) == "function" and core then
        local ok, v = pcall(fvc, core, weightKg, nil, LocalPlayer, nil)
        if ok and type(v) == "number" then return v end
    end
    local base = core and tonumber(getSVD()[core]) or 0     -- fallback (rough)
    return math.floor(base * (weightKg or 1))
end

-- NOTE: there is deliberately NO weight auto-learn. An earlier version paired harvest-fires with the
-- resulting fruit proxies to "learn" a per-type ratio, but because weight = 7.5*size for EVERY fruit,
-- any mispaired sample (rampant at max harvest speed, when many different-size fruits resolve out of
-- order) yields a wrong ratio. The drifting result once dipped below 7.5 and let a 100kg fruit slip
-- under the weight cap. The 7.5 constant is exact and universal, so the cap is reliable at any speed.

-- a garden is LOCKED (un-stealable) while its owner is standing in it. The game tracks this with the
-- per-Player attribute "IsInOwnGarden" (LIVE-VERIFIED: true when home, false/away). Offline owner (no
-- Player) = away = stealable. So: skip a plot only when its owner is present (IsInOwnGarden == true).
local function ownerHome(plot)
    local oid = plot:GetAttribute("OwnerUserId")
    if not oid then return false end
    local owner = Players:GetPlayerByUserId(oid)
    return owner ~= nil and owner:GetAttribute("IsInOwnGarden") == true
end

-- scan every OTHER player's UNLOCKED plot (owner away) for enabled StealPrompts, ranked by value (desc)
local function scanStealTargets(limit)
    local gardens = Workspace:FindFirstChild("Gardens")
    local out = {}
    if not gardens then return out end
    local myId = LocalPlayer.UserId
    for _, plot in ipairs(gardens:GetChildren()) do
        if plot:GetAttribute("OwnerUserId") ~= myId and not ownerHome(plot) then
            local plants = plot:FindFirstChild("Plants")
            if plants then
                for _, pl in ipairs(plants:GetChildren()) do
                    local fruits = pl:FindFirstChild("Fruits")
                    if fruits then
                        for _, f in ipairs(fruits:GetChildren()) do
                            local hp = f:FindFirstChild("HarvestPart")
                            local sp = hp and hp:FindFirstChild("StealPrompt")
                            if sp and sp.Enabled then
                                local val, core = fruitValue(f)
                                out[#out + 1] = {
                                    fruit = f, part = hp, sp = sp, value = val, name = core or f.Name, plot = plot,
                                    owner = f:GetAttribute("UserId"),
                                    plantId = f:GetAttribute("PlantId"), fruitId = f:GetAttribute("FruitId"),
                                }
                            end
                        end
                    end
                end
            end
        end
    end
    table.sort(out, function(a, b) return a.value > b.value end)
    if limit and #out > limit then
        local t = {}; for i = 1, limit do t[i] = out[i] end; return t
    end
    return out
end

local function myBaseCFrame()                          -- a point INSIDE your garden so IsInOwnGarden flips true -> the steal BANKS
    local plot = findMyPlot()
    if not plot then return nil end
    -- PlotSizeReference is the plot-bounds part; its CENTER is deep inside the garden (LIVE-VERIFIED:
    -- standing there -> IsInOwnGarden=true; the SpawnPoint sits on the EDGE -> false -> the steal won't bank).
    local psr = plot:FindFirstChild("PlotSizeReference", true)
    if psr and psr:IsA("BasePart") then return CFrame.new(psr.Position + Vector3.new(0, 4, 0)) end
    local plants = plot:FindFirstChild("Plants")          -- fallback: centre of your plants (also well inside)
    if plants then
        local sum, n = Vector3.zero, 0
        for _, pl in ipairs(plants:GetChildren()) do local ok, piv = pcall(function() return pl:GetPivot().Position end); if ok then sum = sum + piv; n = n + 1 end end
        if n > 0 then return CFrame.new(sum / n + Vector3.new(0, 4, 0)) end
    end
    local sp = plot:FindFirstChild("SpawnPoint", true)    -- last resort (edge — may not bank)
    if sp and sp:IsA("BasePart") then return sp.CFrame end
    if plot:IsA("Model") and plot.PrimaryPart then return plot.PrimaryPart.CFrame end
    return nil
end

-- STEPPED teleport to a world position: hop in small lerp steps (NOT one big jump) so the server's
-- anti-teleport accepts it as legit movement. Live-proven: a single CFrame jump is silently rejected;
-- stepped movement is honoured. HRP stays unanchored so the server replicates the position.
local function steppedMoveTo(hrp, destPos, abortFn)
    local startP = hrp.Position
    local dist = (destPos - startP).Magnitude
    local steps = math.clamp(math.ceil(dist / STEAL_STEP_DIST), 1, 80)
    for i = 1, steps do
        if hrp.Parent == nil then return false end
        if not (State.alive and State.autoSteal) then return false end
        if abortFn and abortFn() then return false end       -- e.g. the target garden just LOCKED (owner came back)
        if hrp.Anchored then pcall(function() hrp.Anchored = false end) end
        pcall(function() hrp.CFrame = CFrame.new(startP:Lerp(destPos, i / steps)) end)
        waitFn(STEAL_STEP_WAIT)
    end
    return true
end

-- GRAB one target: stepped-move onto the fruit, pin in range, fire StealPrompt + BeginSteal until the server
-- grants the carry (carrying()==true). Returns true once we're carrying it. Does NOT deposit — you can only
-- hold ONE stolen fruit and the steal only counts once you carry it home and deposit it.
-- ABORTS the instant the target garden locks (owner walks back in) so we never sit in a locked base.
local function grabOne(hrp, target)
    local sp, fruit, part = target.sp, target.fruit, target.part
    if not (sp and sp.Parent and fruit and fruit.Parent and part and part.Parent) then return false end
    local owner  = tonumber(target.owner) or target.owner
    local beginP = packet("Steal", "BeginSteal")
    if not (beginP and owner and target.plantId) then return false end
    local function locked() return target.plot and ownerHome(target.plot) end   -- owner present now? -> garden LOCKED
    if locked() then return false end                                          -- don't even travel to a locked garden
    local dest = part.Position + STEAL_STAND_OFF
    if not steppedMoveTo(hrp, dest, locked) then return false end              -- abort travel the moment it locks
    for _ = 1, STEAL_PIN_FRAMES do                                              -- PIN so the server registers us in range
        if hrp.Parent == nil or locked() then return false end
        if hrp.Anchored then pcall(function() hrp.Anchored = false end) end
        pcall(function() hrp.CFrame = CFrame.new(dest) end)
        waitFn(STEAL_STEP_WAIT)
    end
    for _ = 1, STEAL_FIRE_TRIES do
        if not (State.alive and State.autoSteal) then break end
        if hrp.Parent == nil or fruit.Parent == nil or locked() then break end  -- bail the instant the owner returns
        pcall(function() hrp.CFrame = CFrame.new(dest) end)
        if sp.Parent and sp.Enabled then fire(sp) end                          -- begin the prompt interaction
        pcall(function() beginP:Fire(owner, target.plantId, target.fruitId or "") end)
        -- LONG-PRESS E and stay pinned in range until the server grants the carry (you must HOLD to steal, not tap)
        pcall(function() VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.E, false, game) end)
        local holdCap = stealHoldSecs(target.name)   -- instant fruit ~1.5s, Bamboo/Mushroom ~4.5s
        local t0 = os.clock()
        while os.clock() - t0 < holdCap do
            if hrp.Parent == nil or fruit.Parent == nil or locked() then break end
            pcall(function() hrp.CFrame = CFrame.new(dest) end)                 -- hold position on the fruit
            if carrying() then break end
            waitFn(0.05)
        end
        pcall(function() VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.E, false, game) end)  -- release E
        if carrying() then return true end                                     -- grabbed -> caller carries it home
        waitFn(0.1)
    end
    return carrying()
end

-- carry the held fruit HOME and DEPOSIT it: stepped-move INTO your own garden (IsInOwnGarden=true) then fire
-- CompleteSteal there to bank it. You MUST deposit before stealing the next one. Returns true if the carry cleared.
local function depositSteal(hrp)
    if not carrying() then return true end
    local base = myBaseCFrame()
    if not base then State.stealStatus = "can't find home to deposit"; return false end
    if not steppedMoveTo(hrp, base.Position) then return false end             -- carry it home (stepped)
    local doneP = packet("Steal", "CompleteSteal")
    for _ = 1, 8 do                                                           -- pin INSIDE the garden + fire the deposit
        if hrp.Parent == nil or not carrying() then break end
        if hrp.Anchored then pcall(function() hrp.Anchored = false end) end
        pcall(function() hrp.CFrame = base end)
        if doneP then pcall(function() doneP:Fire() end) end
        waitFn(0.18)
    end
    return not carrying()
end

local function trySteal()
    if not State.autoSteal then return end
    if State.tpBusy then return end                          -- mutex: another teleporter is active
    if not isNight() then State.stealStatus = "waiting for night ☀️"; return end
    local char = LocalPlayer.Character
    local hrp  = char and char:FindFirstChild("HumanoidRootPart")
    if not hrp then return end
    State.tpBusy, State.stealing = true, true                -- hold the HRP mutex + PAUSE harvest (its prompt-spam rate-limits the steal)
    local saved, wasAnchored = hrp.CFrame, hrp.Anchored
    local got = 0
    pcall(function()
        hrp.Anchored = false
        -- carrying from a prior interrupted sweep? DEPOSIT it first (can't steal while already carrying)
        if carrying() then
            State.stealStatus = "depositing held fruit…"
            if depositSteal(hrp) then got += 1; State.stolen += 1 end
        end
        local targets = scanStealTargets(STEAL_BATCH)
        if #targets == 0 then if got == 0 then State.stealStatus = "no targets (all gardens locked / no night fruit)" end return end
        waitFn(0.25)                                         -- let the harvest prompt-flood drain so steal packets get through
        for i, target in ipairs(targets) do
            if not (State.alive and State.autoSteal and isNight()) then break end
            if hrp.Parent == nil then return end
            if carrying() then break end                                       -- safety: never hold two
            if not (target.fruit and target.fruit.Parent) then continue end
            if target.plot and ownerHome(target.plot) then continue end         -- owner came back -> locked now, skip
            State.stealStatus = ("grabbing %d/%d: %s…"):format(i, #targets, tostring(target.name))
            if grabOne(hrp, target) then
                -- GRABBED -> carry it home and deposit BEFORE moving to the next garden
                State.stealStatus = "depositing " .. tostring(target.name) .. "…"
                if depositSteal(hrp) then
                    got += 1; State.stolen += 1
                    State.stealStatus = "stole + deposited " .. tostring(target.name) .. " 💰"
                else
                    State.stealStatus = "carried " .. tostring(target.name) .. " but couldn't deposit"
                    break                                                       -- still carrying -> stop; retry deposit next sweep
                end
            end
            waitFn(STEAL_TARGET_GAP)                          -- paced gap between targets (rate-limit safe)
        end
    end)
    if hrp.Parent then                                       -- always restore original pose
        pcall(function() hrp.Anchored = wasAnchored end)
        pcall(function() hrp.CFrame = saved end)
    end
    if got > 0 then State.stealStatus = ("stole %d this sweep 💰"):format(got)
    elseif State.stealStatus:find("grabbing") or State.stealStatus:find("depositing") then State.stealStatus = "no steals (server gated / owners home)" end
    State.stealing, State.tpBusy = false, false
end

--===========================================================================--
-- KEY GATE  (enter your key in the UI; validated against your coordinator)
--===========================================================================--
local KEY_FILE = "YumaBlox_key.txt"
local HWID
do  -- per-device id for HWID lock (RbxAnalyticsService client id, with executor fallback)
    local ok, id = pcall(function() return game:GetService("RbxAnalyticsService"):GetClientId() end)
    if ok and type(id) == "string" and id ~= "" then HWID = id
    elseif typeof(gethwid) == "function" then local o, h = pcall(gethwid); HWID = o and tostring(h) or "unknown"
    else HWID = "unknown" end
    HWID = (tostring(HWID):gsub("[^%w%-]", ""))      -- url-safe
end
local function validateKey(k)
    if not k or k == "" then return false, "no key" end
    local ok, body = httpGetAsync(SNIPE_BASE .. "/validate?key=" .. k .. "&hwid=" .. HWID)
    if not ok or type(body) ~= "string" then return false, "server unreachable" end
    local okD, data = pcall(function() return HttpService:JSONDecode(body) end)
    if okD and type(data) == "table" then
        if data.valid == true then return true, data.expires end
        return false, data.reason or "invalid"
    end
    return false, "bad response"
end
local function savedKey()
    if _hasFiles and isfile(KEY_FILE) then
        local ok, k = pcall(readfile, KEY_FILE)
        if ok and type(k) == "string" then return (k:gsub("%s+", "")) end
    end
    return nil
end

local function runKeyGate()
    if _YB.validated then                                -- served via /script (key was in the URL)
        if not _YB.userKey then return true end          -- nothing to HWID-bind
        if validateKey(_YB.userKey) then return true end -- HWID matches/binds on this device -> ok
        -- HWID mismatch (key used on another device) -> fall through to the popup
    end
    local sk = savedKey()                                -- a saved, still-valid key skips the prompt
    if sk and validateKey(sk) then State.userKey = sk; return true end

    local result = nil
    local gui = Instance.new("ScreenGui")
    gui.Name = "YumaBloxKeyGate"; gui.ResetOnSpawn = false; gui.IgnoreGuiInset = true; gui.DisplayOrder = 99999
    if protect_gui_fn then pcall(protect_gui_fn, gui) end
    local parented = gethui_fn and pcall(function() gui.Parent = gethui_fn() end)
    if not parented then parented = pcall(function() gui.Parent = game:GetService("CoreGui") end) end
    if not parented then pcall(function() gui.Parent = LocalPlayer:WaitForChild("PlayerGui") end) end

    local frame = Instance.new("Frame"); frame.Size = UDim2.fromOffset(330, 196); frame.Position = UDim2.new(0.5, -165, 0.5, -98)
    frame.BackgroundColor3 = Color3.fromRGB(26, 26, 32); frame.BorderSizePixel = 0; frame.Parent = gui
    Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 10)
    local strk = Instance.new("UIStroke", frame); strk.Color = Color3.fromRGB(250, 204, 21); strk.Thickness = 1.5; strk.Transparency = 0.35

    local title = Instance.new("TextLabel"); title.BackgroundTransparency = 1; title.Position = UDim2.new(0, 0, 0, 16); title.Size = UDim2.new(1, 0, 0, 24)
    title.Font = Enum.Font.GothamBold; title.TextSize = 18; title.TextColor3 = Color3.fromRGB(250, 204, 21); title.Text = "YumaBlox — Enter Key"; title.Parent = frame

    local box = Instance.new("TextBox"); box.Position = UDim2.new(0.5, -140, 0, 60); box.Size = UDim2.fromOffset(280, 36)
    box.BackgroundColor3 = Color3.fromRGB(44, 44, 52); box.BorderSizePixel = 0; box.Font = Enum.Font.Gotham; box.TextSize = 14
    box.TextColor3 = Color3.fromRGB(235, 235, 235); box.PlaceholderText = "YB-XXXX-XXXX-XXXX"; box.Text = ""; box.ClearTextOnFocus = false; box.Parent = frame
    Instance.new("UICorner", box).CornerRadius = UDim.new(0, 6)

    local status = Instance.new("TextLabel"); status.BackgroundTransparency = 1; status.Position = UDim2.new(0, 10, 0, 102); status.Size = UDim2.new(1, -20, 0, 20)
    status.Font = Enum.Font.Gotham; status.TextSize = 12; status.TextColor3 = Color3.fromRGB(190, 190, 190); status.Text = "Paste your key, then Unlock"; status.Parent = frame

    local btn = Instance.new("TextButton"); btn.Position = UDim2.new(0.5, -140, 0, 130); btn.Size = UDim2.fromOffset(280, 38)
    btn.BackgroundColor3 = Color3.fromRGB(250, 204, 21); btn.Font = Enum.Font.GothamBold; btn.TextSize = 15; btn.TextColor3 = Color3.fromRGB(30, 30, 0)
    btn.Text = "Unlock"; btn.AutoButtonColor = true; btn.BorderSizePixel = 0; btn.Parent = frame
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 6)

    local close = Instance.new("TextButton"); close.Position = UDim2.new(1, -30, 0, 8); close.Size = UDim2.fromOffset(22, 22)
    close.BackgroundTransparency = 1; close.Font = Enum.Font.GothamBold; close.TextSize = 16; close.TextColor3 = Color3.fromRGB(210, 120, 120); close.Text = "X"; close.Parent = frame

    do  -- draggable window (grab the title / empty areas; the textbox & buttons still work normally)
        local dragging, dragStart, startPos
        frame.InputBegan:Connect(function(i)
            if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
                dragging, dragStart, startPos = true, i.Position, frame.Position
            end
        end)
        frame.InputEnded:Connect(function(i)
            if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
                dragging = false
            end
        end)
        UserInputService.InputChanged:Connect(function(i)
            if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
                local d = i.Position - dragStart
                frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
            end
        end)
    end

    local busy = false
    local function attempt()
        if busy then return end
        local k = (box.Text:gsub("%s+", ""))
        busy = true; status.Text = "Checking…"; status.TextColor3 = Color3.fromRGB(190, 190, 190); btn.Active = false
        task.spawn(function()
            local v, exp = validateKey(k)
            if v then
                if _hasFiles then pcall(function() writefile(KEY_FILE, k) end) end
                State.userKey = k
                status.Text = "Valid! Loading…"; status.TextColor3 = Color3.fromRGB(90, 220, 90)
                task.wait(0.4); pcall(function() gui:Destroy() end); result = true
            else
                status.Text = (type(exp) == "string") and exp or "Invalid or expired key"
                status.TextColor3 = Color3.fromRGB(255, 90, 90); btn.Active = true; busy = false
            end
        end)
    end
    btn.MouseButton1Click:Connect(attempt)
    box.FocusLost:Connect(function(enter) if enter then attempt() end end)
    close.MouseButton1Click:Connect(function() pcall(function() gui:Destroy() end); result = false end)

    while result == nil do task.wait(0.15) end
    return result
end

if not runKeyGate() then
    warn("[YumaBlox] no valid key — aborting.")
    State.alive = false
    return
end

--===========================================================================--
-- FARM HELPERS (auto water / plant / sprinkler) + WEATHER (read-only)
--   Remotes verified vs the decompiled controllers; server-acceptance WITHOUT
--   proximity is unconfirmed — if nothing registers, stand on your plot.
--===========================================================================--
local WATER_FIRE_GAP, PLANT_FIRE_GAP = 0.2, 0.15
local WATER_RESCAN, PLANT_RESCAN, SPRINKLE_RESCAN, WEATHER_POLL = 4, 4, 6, 1

local _SM = ReplicatedStorage:FindFirstChild("SharedModules")
local function lazyReq(name, cache)            -- pcall-cached require of a SharedModules child (mirrors getSVD)
    return function()
        if cache.v ~= nil then return cache.v or nil end
        pcall(function() local m = _SM and _SM:FindFirstChild(name); cache.v = m and require(m) or false end)
        return cache.v or nil
    end
end
local getSprinklerData = lazyReq("SprinklerData", {})
local getWeatherData   = lazyReq("WeatherData",   {})

local _sprinklerNames
local function sprinklerNameSet()              -- model-name set, to detect placed sprinklers on the plot
    if _sprinklerNames then return _sprinklerNames end
    _sprinklerNames = {}
    local d = getSprinklerData()
    if type(d) == "table" then for _, v in pairs(d) do if type(v) == "table" and v.SprinklerName then _sprinklerNames[v.SprinklerName] = true end end end
    return _sprinklerNames
end

-- equip (or return) a Tool carrying attribute `attr` (optionally == wantVal); returns the live equipped tool
local function equipToolByAttr(attr, wantVal)
    local char = LocalPlayer.Character; if not char then return nil end
    local eq = char:FindFirstChildWhichIsA("Tool")
    if eq and eq:GetAttribute(attr) ~= nil and (wantVal == nil or eq:GetAttribute(attr) == wantVal) then return eq end
    local hum, bp = char:FindFirstChildWhichIsA("Humanoid"), LocalPlayer:FindFirstChild("Backpack")
    if hum and bp then
        for _, t in ipairs(bp:GetChildren()) do
            if t:IsA("Tool") and t:GetAttribute(attr) ~= nil and (wantVal == nil or t:GetAttribute(attr) == wantVal) then
                pcall(function() hum:EquipTool(t) end)
                return t                                              -- the tool we just equipped (not a stale re-query)
            end
        end
    end
    -- only return an already-equipped tool if it MATCHES the request (or no specific value was asked)
    if eq and eq:GetAttribute(attr) ~= nil and (wantVal == nil or eq:GetAttribute(attr) == wantVal) then return eq end
    return nil
end

-- OWNED seeds: Backpack + equipped Tools carrying a SeedTool attr; count from the stacked Count attr (or 1/tool)
local function ownedSeeds()
    local counts = {}
    local function scan(c) if c then for _, t in ipairs(c:GetChildren()) do
        if t:IsA("Tool") then local sa = t:GetAttribute("SeedTool")
            if sa ~= nil then local nm = tostring(sa); counts[nm] = (counts[nm] or 0) + (tonumber(t:GetAttribute("Count")) or 1) end
        end
    end end end
    scan(LocalPlayer:FindFirstChild("Backpack")); scan(LocalPlayer.Character)
    local names = {} for nm in pairs(counts) do names[#names + 1] = nm end
    table.sort(names)
    return names, counts
end
local function ownedSeedLabels()
    local names, counts = ownedSeeds()
    local labels = {} for _, nm in ipairs(names) do labels[#labels + 1] = ("%s (x%d)"):format(nm, counts[nm]) end
    return labels, names, counts
end
local function seedFromLabel(label)
    if type(label) ~= "string" then return nil end
    return (label:gsub("%s*%(x%d+%)%s*$", ""))
end

-- ALL seed types in the game (from SeedData) — so the user can pre-pick a seed they DON'T own yet;
-- tryPlant then auto-plants it the moment they get it (e.g. from Auto Buy). Cached after first read.
local _allSeedCache
local function allSeedNames()
    if _allSeedCache then return _allSeedCache end
    local names = {}
    pcall(function()
        local sm = ReplicatedStorage:FindFirstChild("SharedModules")
        local sd = sm and sm:FindFirstChild("SeedData")
        local data = sd and require(sd)
        if type(data) == "table" then
            local seen = {}
            for _, v in pairs(data) do
                if type(v) == "table" and type(v.SeedName) == "string" and not seen[v.SeedName] then
                    seen[v.SeedName] = true; names[#names + 1] = v.SeedName
                end
            end
        end
    end)
    table.sort(names)
    if #names > 0 then _allSeedCache = names end
    return names
end
-- label for one seed name with its CURRENT owned count ("(x0)" = not owned yet)
local function seedLabelFor(name)
    if type(name) ~= "string" or name == "" then return nil end
    local _, counts = ownedSeeds()
    return ("%s (x%d)"):format(name, counts[name] or 0)
end
-- dropdown values = EVERY seed, owned ones first (with count), then the rest as "(x0)"
local function allSeedLabels()
    local names = allSeedNames()
    if #names == 0 then return ownedSeedLabels() end   -- SeedData unreadable → fall back to owned-only
    local _, counts = ownedSeeds()
    local owned, rest = {}, {}
    for _, nm in ipairs(names) do
        local c = counts[nm] or 0
        if c > 0 then owned[#owned + 1] = ("%s (x%d)"):format(nm, c)
        else rest[#rest + 1] = ("%s (x0)"):format(nm) end
    end
    local labels = {}
    for _, l in ipairs(owned) do labels[#labels + 1] = l end
    for _, l in ipairs(rest)  do labels[#labels + 1] = l end
    return labels
end
-- labels for the currently-selected plant seeds (for the multi-dropdown Default/restore)
local function plantSeedLabels()
    local t = {}
    for nm in pairs(State.plantSeeds or {}) do t[#t + 1] = seedLabelFor(nm) end
    return t
end

local function plantAreaParts(plot)            -- PlantArea-tagged BaseParts under the plot
    local out = {}
    for _, d in ipairs(plot:GetDescendants()) do
        if d:IsA("BasePart") and CollectionService:HasTag(d, "PlantArea") then out[#out + 1] = d end
    end
    return out
end

local function gridPoints(part, pitch)         -- world points on a part's TOP surface, `pitch` studs apart
    local pts, sz, cf = {}, part.Size, part.CFrame
    local hx, hz = sz.X / 2, sz.Z / 2
    local x = -hx + pitch / 2
    while x < hx do
        local z = -hz + pitch / 2
        while z < hz do pts[#pts + 1] = (cf * CFrame.new(x, sz.Y / 2, z)).Position; z = z + pitch end
        x = x + pitch
    end
    return pts
end

local _plantRng = Random.new()
local function randomTopPoints(part, n, inset)  -- random world points on a part's top surface ("random spot")
    local pts, sz, cf = {}, part.Size, part.CFrame
    local hx = math.max(0, sz.X / 2 - (inset or 1))
    local hz = math.max(0, sz.Z / 2 - (inset or 1))
    for _ = 1, n do
        pts[#pts + 1] = (cf * CFrame.new(_plantRng:NextNumber(-hx, hx), sz.Y / 2, _plantRng:NextNumber(-hz, hz))).Position
    end
    return pts
end

local function existingPlantPoints(plot)       -- XZ of existing plants (>1-stud planting gate)
    local out, plants = {}, plot:FindFirstChild("Plants")
    if plants then for _, m in ipairs(plants:GetChildren()) do
        local ok, piv = pcall(function() return m:GetPivot().Position end)
        if ok then out[#out + 1] = Vector2.new(piv.X, piv.Z) end
    end end
    return out
end

------------------------------------------------------------------ AUTO WATER
local function tryWaterAll()
    if not State.autoWater then return end
    local plot = findMyPlot(); if not plot then State.waterStatus = "no plot"; return end
    local plants = plot:FindFirstChild("Plants")
    if not plants or #plants:GetChildren() == 0 then State.waterStatus = "no plants yet"; return end
    local tool = equipToolByAttr("WateringCan"); if not tool then State.waterStatus = "no Watering Can (own/equip one)"; return end
    local canName = tool:GetAttribute("WateringCan")
    local p = packet("WateringCan", "UseWateringCan"); if not p then return end
    State.waterStatus = "watering…"
    for _, m in ipairs(plants:GetChildren()) do
        if not (State.alive and State.autoWater) then break end
        local ok, pos = pcall(function() return m:GetPivot().Position end)
        if ok then
            pcall(function() p:Fire(pos - Vector3.new(0, 0.3, 0), canName, tool) end)
            State.watered = (State.watered or 0) + 1
            waitFn(WATER_FIRE_GAP)
        end
    end
    State.waterStatus = ("watered %d plant(s)"):format(#plants:GetChildren())
end

------------------------------------------------------------------ AUTO PLANT
local PLANT_PER_PASS = 25
local function tryPlant()
    if not State.autoPlant then return end
    local plot = findMyPlot(); if not plot then State.plantStatus = "no plot"; return end
    -- multi-select: plant whichever of the selected seeds you OWN (rotates as each runs out).
    -- none selected = plant ANY owned seed. NO fallback to an unselected seed.
    local picks = {}
    for nm in pairs(State.plantSeeds or {}) do picks[#picks + 1] = nm end
    table.sort(picks)
    local tool, chosen
    if #picks > 0 then
        for _, nm in ipairs(picks) do
            local t = equipToolByAttr("SeedTool", nm)
            if t then tool, chosen = t, nm; break end                -- first selected seed we actually own
        end
        if not tool then State.plantStatus = "own/buy: " .. table.concat(picks, ", "); return end
    else
        tool = equipToolByAttr("SeedTool")
        if not tool then State.plantStatus = "no seed owned — pick or buy a seed"; return end
    end
    local seedAttr = tool:GetAttribute("SeedTool")
    if not seedAttr then State.plantStatus = "equipped tool has no SeedTool attr"; return end
    if chosen and seedAttr ~= chosen then State.plantStatus = "equipping " .. chosen .. "…"; return end   -- wait for the swap; never plant the wrong one
    local areas = plantAreaParts(plot); if #areas == 0 then State.plantStatus = "no plant area"; return end
    local p = packet("Plant", "PlantSeed"); if not p then State.plantStatus = "no PlantSeed remote"; return end
    local spacing = math.max(1.5, tonumber(State.plantSpacing) or 2)
    local taken = existingPlantPoints(plot)
    local function plantsCount() local pf = plot:FindFirstChild("Plants"); return pf and #pf:GetChildren() or 0 end
    State.plantStatus = "planting " .. tostring(seedAttr) .. "…"
    local placed, candidates = 0, {}
    local feet = (State.plantMode == "At my feet")
    if feet then
        -- "At my feet": fill a CLUSTER of empty cells AROUND where you stand (nearest first) so it plants
        -- MANY, not just the one spot. Cells are `spacing` apart (server min 1.5); walk to lay more.
        local char = LocalPlayer.Character
        local hrp  = char and char:FindFirstChild("HumanoidRootPart")
        if hrp then
            local rp = RaycastParams.new(); rp.FilterType = Enum.RaycastFilterType.Exclude
            rp.FilterDescendantsInstances = { char }
            local hit = workspace:Raycast(hrp.Position, Vector3.new(0, -14, 0), rp)
            local base = hit and hit.Position or (hrp.Position - Vector3.new(0, 3, 0))
            local R = 4                                              -- (2R+1)^2 cells around the feet
            for dx = -R, R do for dz = -R, R do
                candidates[#candidates + 1] = base + Vector3.new(dx * spacing, 0, dz * spacing)
            end end
            table.sort(candidates, function(a, b) return (a - base).Magnitude < (b - base).Magnitude end)
        end
    else
        -- placement mode: "Grid" = neat lined-up rows at `spacing`; otherwise random scatter
        local grid = (State.plantMode == "Grid")
        for _, area in ipairs(areas) do
            local pts = grid and gridPoints(area, spacing) or randomTopPoints(area, PLANT_PER_PASS, 1)
            for _, pos in ipairs(pts) do candidates[#candidates + 1] = pos end
        end
    end
    for _, pos in ipairs(candidates) do
        if not (State.alive and State.autoPlant) then return end
        if placed >= PLANT_PER_PASS then break end
        local t                                                  -- re-acquire each fire (strictly the chosen seed)
        if chosen then t = equipToolByAttr("SeedTool", chosen) else t = equipToolByAttr("SeedTool") end
        if not t then State.plantStatus = "ran out of seeds"; break end
        local attr = t:GetAttribute("SeedTool")
        if not attr then break end
        if chosen and attr ~= chosen then break end              -- holding the wrong seed -> STOP (don't plant a non-selected seed)
        local xz, clear = Vector2.new(pos.X, pos.Z), true
        for _, q in ipairs(taken) do if (q - xz).Magnitude < spacing then clear = false; break end end   -- skip cells too close to an existing plant (all modes)
        if clear then
            local before = plantsCount()
            pcall(function() p:Fire(pos, attr, t) end)
            waitFn(PLANT_FIRE_GAP)
            if plantsCount() > before then placed += 1; State.planted = (State.planted or 0) + 1; taken[#taken + 1] = xz end
        end
    end
    State.plantStatus = ("planted %d this pass — %d on plot"):format(placed, plantsCount())
end

------------------------------------------------------------------ CLEANUP GARDEN  (shovel unwanted plant TYPES)
-- Dig up whole plants whose SeedName is ticked. Mechanism (decompiled ShovelController):
--   Networking.Shovel.UseShovel:Fire(plantId, "", shovelAttrValue, shovelTool)  — "" fruitId = whole plant.
-- The legit hold-to-delete aims via camera raycast (no proximity), so we just fire it per plant — no teleport.
local CLEANUP_FIRE_GAP = 0.75   -- MUST stay above the server's ~0.65s shovel cooldown, or it silently drops most digs (verified live)
local function gardenPlantTypes()                                 -- unique SeedNames currently on YOUR plot
    local out, seen = {}, {}
    local plot = findMyPlot(); if not plot then return out end
    local plants = plot:FindFirstChild("Plants"); if not plants then return out end
    for _, m in ipairs(plants:GetChildren()) do
        local t = m:GetAttribute("SeedName")
        if t and not seen[t] then seen[t] = true; out[#out + 1] = t end
    end
    table.sort(out)
    return out
end
local function tryCleanup()                                       -- shovel every plant whose SeedName is selected (button-triggered)
    if State.tpBusy then return end                               -- don't fight a buy/steal teleport (tool swap)
    if not next(State.cleanupTypes or {}) then State.cleanupStatus = "no plant types selected"; return end
    local plot = findMyPlot(); if not plot then State.cleanupStatus = "no plot"; return end
    local plants = plot:FindFirstChild("Plants"); if not plants then State.cleanupStatus = "no plants"; return end
    local targets = {}
    for _, m in ipairs(plants:GetChildren()) do
        -- UseShovel expects the plant MODEL's Name (e.g. "<UserId>_<PlantId>") as plantId — verified
        -- in decompiled ShovelController.GetHighlightTarget (plantId = v5.Name), NOT the PlantId attr.
        local t = m:GetAttribute("SeedName")
        if t and State.cleanupTypes[t] then targets[#targets + 1] = { m = m, pid = m.Name } end
    end
    if #targets == 0 then State.cleanupStatus = "nothing matching to remove"; return end
    local tool = equipToolByAttr("Shovel"); if not tool then State.cleanupStatus = "no Shovel (own/equip one)"; return end
    local shovelAttr = tool:GetAttribute("Shovel")
    local p = packet("Shovel", "UseShovel"); if not p then State.cleanupStatus = "no UseShovel remote"; return end
    State.cleanupStatus = ("removing %d plant(s)…"):format(#targets)
    local n = 0
    for _, t in ipairs(targets) do
        if not State.alive then break end
        if t.m.Parent then
            pcall(function() p:Fire(t.pid, "", shovelAttr, tool) end)   -- dig up the WHOLE plant
            n += 1; State.cleaned = (State.cleaned or 0) + 1
            waitFn(CLEANUP_FIRE_GAP)
        end
    end
    State.cleanupStatus = ("removed %d plant(s) (total %d)"):format(n, State.cleaned or 0)
end

------------------------------------------------------------------ PACK PLANTS (TROWEL — real server-side move)
-- Uses the Trowel's MovePlant remote (decompiled TrowelController.ConfirmMove):
--   Networking.Trowel.MovePlant:Fire(plantModelName, targetPos, rotationDeg)
-- The server only accepts EMPTY spots on a PlantArea-tagged strip (no overlap), so we move every
-- plant into the nearest free ~4-stud grid cell to the character — a tight, PERMANENT cluster.
local PACK_SPACING  = 1      -- studs between packed plants. VERIFIED live: server accepts gaps down to 0.5 (the plant Base is only 1x1x1); only the EXACT-same occupied cell is rejected. 1 = tight 1-stud grid.
local PACK_FIRE_GAP = 0.3    -- gap between moves (no real server cooldown, but be gentle)
local function tryPackPlants()
    if State.tpBusy then return end
    local plot = findMyPlot(); if not plot then State.stackStatus = "no plot"; return end
    local plants = plot:FindFirstChild("Plants"); if not plants then State.stackStatus = "no plants"; return end
    local hrp = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    if not hrp then State.stackStatus = "no character"; return end
    local tool = equipToolByAttr("Trowel"); if not tool then State.stackStatus = "no Trowel (own/equip one)"; return end
    local rem = packet("Trowel", "MovePlant"); if not rem then State.stackStatus = "no MovePlant remote"; return end

    local list = {}
    for _, m in ipairs(plants:GetChildren()) do if m:IsA("Model") and m:GetAttribute("PlantId") then list[#list + 1] = m end end
    if #list == 0 then State.stackStatus = "no plants"; return end
    local baseY = list[1]:GetPivot().Position.Y

    -- candidate grid on every PlantArea strip, sorted nearest-to-character first
    local cands = {}
    for _, strip in ipairs(game:GetService("CollectionService"):GetTagged("PlantArea")) do
        if strip:IsDescendantOf(plot) and strip:IsA("BasePart") and strip.Size.X > 5 then
            local hx, hz = strip.Size.X / 2 - 2, strip.Size.Z / 2 - 2
            for dx = -hx, hx, PACK_SPACING do for dz = -hz, hz, PACK_SPACING do
                local wp = strip.CFrame * CFrame.new(dx, 0, dz)
                cands[#cands + 1] = Vector3.new(wp.X, baseY, wp.Z)
            end end
        end
    end
    if #cands == 0 then State.stackStatus = "no plant-area cells found"; return end
    local cxz = Vector2.new(hrp.Position.X, hrp.Position.Z)
    table.sort(cands, function(a, b) return (Vector2.new(a.X, a.Z) - cxz).Magnitude < (Vector2.new(b.X, b.Z) - cxz).Magnitude end)

    -- greedily move each plant to the nearest cell NOT occupied by another plant (tracked live so
    -- replication lag doesn't double-book a cell)
    local intended = {}
    local function occupied(cell, skip)
        local v = Vector2.new(cell.X, cell.Z)
        for _, m in ipairs(list) do
            if m ~= skip then
                local q = intended[m]
                if not q then local p = m:GetPivot().Position; q = Vector2.new(p.X, p.Z) end
                if (q - v).Magnitude < (PACK_SPACING - 0.1) then return true end   -- margin so adjacent 1-stud cells aren't float-rejected
            end
        end
        return false
    end
    State.stackStatus = ("packing %d plant(s)…"):format(#list)
    local moved = 0
    for _, m in ipairs(list) do
        if not State.alive then break end
        local tgt
        for _, c in ipairs(cands) do if not occupied(c, m) then tgt = c; break end end
        if not tgt then break end
        if m.Parent then
            pcall(function() rem:Fire(m.Name, tgt, 0) end)
            intended[m] = Vector2.new(tgt.X, tgt.Z)
            moved += 1
            waitFn(PACK_FIRE_GAP)
        end
    end
    State.stackStatus = ("packed %d plant(s) near you"):format(moved)
end

------------------------------------------------------------------ AUTO SPRINKLER
local function plotSprinklers(plot)
    local set, out = sprinklerNameSet(), {}
    for _, m in ipairs(plot:GetDescendants()) do
        if m:IsA("Model") and m.PrimaryPart and set[m.Name] then out[#out + 1] = m.PrimaryPart.Position end
    end
    return out
end
-- SprinklerData by name: { luck=SizeLuckBonus, radius=Radius, grow=GrowSpeedBonus, life=Lifetime }
local _sprInfo
local function sprinklerInfo()
    if _sprInfo then return _sprInfo end
    _sprInfo = {}
    local d = getSprinklerData()
    if type(d) == "table" then for _, v in pairs(d) do if type(v) == "table" and v.SprinklerName then
        _sprInfo[v.SprinklerName] = { luck = tonumber(v.SizeLuckBonus) or 0, radius = tonumber(v.Radius) or 20,
            grow = tonumber(v.GrowSpeedBonus) or 1, life = tonumber(v.Lifetime) or 120 }
    end end end
    return _sprInfo
end
-- LIVE-VERIFIED: placed sprinklers sit in plot.Sprinklers as models named "<UserId>_<GUID>" with a
-- SprinklerName attribute (the tier) + a SprinklerTimerUI showing "M:SS" remaining. (The old code matched
-- the model NAME to the tier name — it never matched, so it thought nothing was placed and kept re-equipping.)
local function placedSprinklerTypes(plot)              -- SprinklerName -> count currently on the plot
    local counts = {}
    local spf = plot:FindFirstChild("Sprinklers")
    if spf then for _, m in ipairs(spf:GetChildren()) do
        if m:IsA("Model") then local nm = m:GetAttribute("SprinklerName"); if nm then counts[nm] = (counts[nm] or 0) + 1 end end
    end end
    return counts
end
local function parseTimer(txt)                         -- "0:45" -> 45 ; "118" -> 118
    txt = tostring(txt or "")
    local mm, ss = txt:match("(%d+):(%d+)")
    if mm then return tonumber(mm) * 60 + tonumber(ss) end
    local n = txt:match("(%d+)")
    return n and tonumber(n) or nil
end
local function sprinklerMinRemaining(plot)             -- soonest-expiring sprinkler's remaining seconds
    local spf = plot:FindFirstChild("Sprinklers"); if not spf then return nil end
    local minR
    for _, m in ipairs(spf:GetChildren()) do
        if m:IsA("Model") and m:GetAttribute("SprinklerName") then
            local ui  = m:FindFirstChild("SprinklerTimerUI", true)
            local lbl = ui and ui:FindFirstChildWhichIsA("TextLabel", true)
            local r   = lbl and parseTimer(lbl.Text)
            if r and (not minR or r < minR) then minR = r end
        end
    end
    return minR
end
local function fmtClock(sec) sec = math.max(0, math.floor(sec or 0)); return ("%d:%02d"):format(math.floor(sec / 60), sec % 60) end
local function plantPositions(plot)                    -- Vector3 of every plant
    local out, plants = {}, plot:FindFirstChild("Plants")
    if plants then for _, m in ipairs(plants:GetChildren()) do
        local ok, piv = pcall(function() return m:GetPivot().Position end); if ok then out[#out + 1] = piv end
    end end
    return out
end

-- SPRINKLER METHOD: keep the size-luck at the 100 cap with the FEWEST sprinklers (highest tier first —
-- 1 Super alone = 100), placed on the DENSEST plant cluster; auto-replace each as it expires (120s).
-- "Max mutations" mode instead stacks 1 of EVERY owned tier (past the cap = more mutation chance).
local SIZE_LUCK_CAP = 100
local function tryPlaceSprinklers()
    if not State.autoSprinkle then return end
    local plot = findMyPlot(); if not plot then State.sprinkleStatus = "no plot"; return end
    local plotId = tonumber(tostring(plot.Name):match("%d+")); if not plotId then State.sprinkleStatus = "no plotId"; return end
    local rem = packet("Place", "PlaceSprinkler"); if not rem then return end
    local info = sprinklerInfo()
    -- owned sprinkler tiers, highest size-luck first
    local tiers = {}
    for _, src in ipairs({ LocalPlayer.Character, LocalPlayer:FindFirstChild("Backpack") }) do
        if src then for _, t in ipairs(src:GetChildren()) do
            local nm = t:IsA("Tool") and t:GetAttribute("Sprinkler")
            if nm and not table.find(tiers, nm) then tiers[#tiers + 1] = nm end
        end end
    end
    if #tiers == 0 then State.sprinkleStatus = "own a Sprinkler"; return end
    table.sort(tiers, function(a, b) return (info[a] and info[a].luck or 0) > (info[b] and info[b].luck or 0) end)
    -- densest plant cluster (radius = biggest sprinkler we might place)
    local pts = plantPositions(plot)
    if #pts == 0 then State.sprinkleStatus = "no plants to cover"; return end
    local R = 20; for _, nm in ipairs(tiers) do if info[nm] then R = math.max(R, info[nm].radius) end end
    local center, bestN
    for _, c in ipairs(pts) do
        local n = 0
        for _, q in ipairs(pts) do if (Vector2.new(q.X, q.Z) - Vector2.new(c.X, c.Z)).Magnitude <= R then n += 1 end end
        if not bestN or n > bestN then center, bestN = c, n end
    end
    if not center then return end
    -- size-luck from whatever is ALREADY in the garden (counts manual placements too)
    local function curLuck()
        local l = 0; for nm, cnt in pairs(placedSprinklerTypes(plot)) do l += (info[nm] and info[nm].luck or 0) * cnt end; return l
    end
    -- place sprinklers: SIZE mode = climb to 100 luck with the fewest (highest tier first, STOP once capped);
    -- MUTATIONS mode = stack 1 of every owned tier. Placing a missing tier also REPLACES an expired one.
    local placedNow, idx = 0, 0
    for _, nm in ipairs(tiers) do
        if not (State.alive and State.autoSprinkle) then return end
        if (not State.sprinkleMutations) and curLuck() >= SIZE_LUCK_CAP then break end   -- size mode: already at the cap
        if (placedSprinklerTypes(plot)[nm] or 0) < 1 then
            local t = equipToolByAttr("Sprinkler", nm)
            if t then
                local off = Vector3.new((idx % 3) * 3 - 3, 0, math.floor(idx / 3) * 3)   -- tiny spread so they don't exactly overlap
                local before = placedSprinklerTypes(plot)[nm] or 0
                pcall(function() rem:Fire(center + off, nm, t, plotId) end)
                waitFn(0.6)
                if (placedSprinklerTypes(plot)[nm] or 0) > before then State.sprinkled = (State.sprinkled or 0) + 1; placedNow += 1 end
            end
        end
        idx += 1
    end
    -- status + "100 size-luck CAPPED" notification — fires whenever luck >= 100, in EITHER mode
    local active, luckNow = 0, 0
    for nm, cnt in pairs(placedSprinklerTypes(plot)) do active += cnt; luckNow += (info[nm] and info[nm].luck or 0) * cnt end
    local remain = sprinklerMinRemaining(plot)
    local timerTxt = remain and fmtClock(remain) or "?"
    State.sprinkleStatus = ("%d active · %d/%d size-luck · refreshes in %s · densest (%d plants)")
        :format(active, math.min(luckNow, SIZE_LUCK_CAP), SIZE_LUCK_CAP, timerTxt, bestN or 0)
    if luckNow >= SIZE_LUCK_CAP then
        -- notify on the FIRST cap AND every time a fresh sprinkler is placed (replacement) — so it
        -- re-appears with the new timer instead of showing once and never again.
        if (not State._sprCapped) or placedNow > 0 then
            State.notify("Sprinklers", "100 size-luck CAPPED 🍀  (timer: " .. timerTxt .. ")", 5)
        end
        State._sprCapped = true
    else
        State._sprCapped = false
    end
end

------------------------------------------------------------------ WEATHER (deterministic moon-phase predictor)
-- Replicates TimeCycleController EXACTLY: phases from TimeCycleData.Data sorted by StartOrder; sum of Lasts (=600);
-- cycleIndex=floor(os.time()/sum); weather=pickWeather(phase, Random.new(cycle*1000 + phaseArrayIndex)). We require the
-- LIVE TimeCycleData so pickWeather walks the SAME .Weathers table the game does -> bit-identical picks. Forward-scans
-- future cycles for the next Goldmoon / Rainbow Moon with os.time-aligned countdowns.
local getTimeCycleData = lazyReq("TimeCycleData", {})
local _wx
local function weatherModel()
    if _wx then return _wx end
    local data = getTimeCycleData()
    data = data and (data.Data or data)
    if type(data) ~= "table" then return nil end
    local phases = {}
    for name, v in pairs(data) do
        if type(v) == "table" and v.Weathers then
            phases[#phases + 1] = { Name = name, Weathers = v.Weathers, Duration = v.Lasts, Order = v.StartOrder }
        end
    end
    if #phases == 0 then return nil end
    table.sort(phases, function(a, b) return (a.Order or 0) < (b.Order or 0) end)
    local sum, offsets, acc = 0, {}, 0
    for i, p in ipairs(phases) do offsets[i] = acc; acc = acc + (p.Duration or 0); sum = sum + (p.Duration or 0) end
    local night, nightIdx
    for i, p in ipairs(phases) do
        if p.Weathers and (p.Weathers["Goldmoon"] or p.Weathers["Rainbow Moon"] or p.Weathers["Bloodmoon"]) then night, nightIdx = p, i; break end
    end
    _wx = { phases = phases, offsets = offsets, sum = (sum > 0 and sum or 600), night = night, nightIdx = nightIdx }
    return _wx
end
local function pickWeather(phase, rng)
    local total = 0
    for _, w in pairs(phase.Weathers) do total = total + w.Chance end
    local r, cum = rng:NextNumber() * total, 0
    for name, w in pairs(phase.Weathers) do cum = cum + w.Chance; if r <= cum then return name end end
    for name in pairs(phase.Weathers) do return name end
    return nil
end
local function weatherForPhase(cycleIndex, phaseArrayIndex, phase)
    return pickWeather(phase, Random.new(cycleIndex * 1000 + phaseArrayIndex))
end
local function getCycleState(wx)
    local cycleIndex = math.floor(os.time() / wx.sum)
    local activePhase = Workspace:GetAttribute("ActivePhase")
    local phaseEnd    = Workspace:GetAttribute("PhaseDuration")
    if type(activePhase) == "string" then
        for i, p in ipairs(wx.phases) do
            if p.Name == activePhase then
                local left
                if type(phaseEnd) == "number" and phaseEnd > 0 then left = math.max(0, phaseEnd - Workspace:GetServerTimeNow())
                else local into = os.time() % wx.sum; left = math.max(0, (wx.offsets[i] + p.Duration) - into) end
                return cycleIndex, i, p, left
            end
        end
    end
    local into = os.time() % wx.sum
    for i, p in ipairs(wx.phases) do
        if into >= wx.offsets[i] and into < wx.offsets[i] + p.Duration then return cycleIndex, i, p, (wx.offsets[i] + p.Duration) - into end
    end
    return cycleIndex, #wx.phases, wx.phases[#wx.phases], 0
end
local function nightStartTime(wx, cycleIndex) return cycleIndex * wx.sum + (wx.offsets[wx.nightIdx] or 0) end
local function nextNight(wx, fromCycle, wantWeather, horizon)
    local nowt = os.time()
    for c = fromCycle, fromCycle + horizon do
        if weatherForPhase(c, wx.nightIdx, wx.night) == wantWeather then
            local startT = nightStartTime(wx, c)
            if startT + wx.night.Duration > nowt then return math.max(0, startT - nowt), startT end
        end
    end
    return nil
end
local WEATHER_HORIZON = 288
local function readWeather()
    local wx = weatherModel()
    if not wx or not wx.night then State.weatherStatus = "n/a (TimeCycleData unreadable)"; return end
    local cycleIndex, phaseIdx, phase, left = getCycleState(wx)
    local liveW = Workspace:GetAttribute("ActiveWeather")
    local curW
    if type(liveW) == "string" and phase.Weathers[liveW] then curW = liveW else curW = weatherForPhase(cycleIndex, phaseIdx, phase) end
    State.weatherNow, State.weatherStatus, State.weatherPhase, State.weatherLeft, State.weatherCycle = curW, curW, phase.Name, left, cycleIndex
    if curW and not State.weatherSeen[curW] then State.weatherSeen[curW] = os.time() end
    State.nextGold,  State.nextGoldAt  = nextNight(wx, cycleIndex, "Goldmoon",     WEATHER_HORIZON)
    State.nextRbow,  State.nextRbowAt  = nextNight(wx, cycleIndex, "Rainbow Moon", WEATHER_HORIZON)
    State.nextBlood, State.nextBloodAt = nextNight(wx, cycleIndex, "Bloodmoon",    WEATHER_HORIZON)
    State.tonightW = weatherForPhase(cycleIndex, wx.nightIdx, wx.night)
    -- SELF-VERIFY: while it's actually Night with a server weather set, compare the formula's pick for THIS
    -- cycle to the server's real ActiveWeather. If they differ, the server isn't following the client formula,
    -- so the forecast can't be trusted (and we say so in the panel).
    if phase == wx.night and type(liveW) == "string" and wx.night.Weathers[liveW] then
        local predicted = weatherForPhase(cycleIndex, wx.nightIdx, wx.night)
        if predicted == liveW then State.weatherCalib = "ok"
        else State.weatherCalib = ("OFF: predicted %s, server=%s"):format(tostring(predicted), tostring(liveW)) end
    end
end

--===========================================================================--
-- ENGINE LOOPS
--===========================================================================--
task.spawn(function() while State.alive do if State.autoWater    then pcall(tryWaterAll) end;       waitFn(WATER_RESCAN) end end)
task.spawn(function() while State.alive do if State.autoPlant    then pcall(tryPlant) end;           waitFn(PLANT_RESCAN) end end)
task.spawn(function() while State.alive do if State.autoSprinkle then pcall(tryPlaceSprinklers) end; waitFn(SPRINKLE_RESCAN) end end)
task.spawn(function() while State.alive do pcall(readWeather);                                       waitFn(WEATHER_POLL) end end)

task.spawn(function()                                        -- buy loop (shops + pets)
    while State.alive do
        if State.autoBuy then pcall(tryBuy) end
        if State.autoBuyPets then pcall(tryBuyPets) end
        waitFn(BUY_RESCAN)
    end
end)

--===========================================================================--
-- AUTO-SHOVEL-HIT — LONGER + AGGRESSIVE. Whacks enemy players (the game's own PvP defense).
-- Verified from decompiled ShovelController:
--   * server requires dist <= 12 studs AND facing dot >= 0.3 for a landed HitPlayer
--   * one swing can hit MANY players (the blade's Touched fires HitPlayer per character)
--   * per-target cooldown ~0.5s; the 0.65s "swing" gate is CLIENT-INPUT only — firing the
--     remote directly bypasses it, so we're bound by the 0.5s per-target limit, not 0.65s.
-- So we make it:
--   * LONGER  — 12-stud hard hit cap can't be beaten, so we DASH to close the gap on any
--               enemy within CHASE_RANGE, whack, then snap back to where we were.
--   * AGGRESSIVE — multi-hit EVERY enemy in front + in range each swing, fast 0.5s cycle.
--===========================================================================--
do
    local Players = game:GetService("Players")
    local HIT_RANGE    = 12          -- studs — server hard cap for a landed hit (dist <= 12)
    local CHASE_RANGE  = 28          -- studs — dash to close the gap on any enemy within this
    local FACE_DOT     = 0.3         -- server needs facing dot >= 0.3 (we face the primary target)
    local SWING_COOLDOWN  = 0.5      -- sec between our swing cycles (per-target server limit)
    local TARGET_COOLDOWN = 0.5      -- sec per same target (server ~0.5)
    local _lastSwing = 0
    local _hitAt = {}                    -- player -> os.clock()

    local function equipShovel()
        local char = LocalPlayer.Character
        local hum  = char and char:FindFirstChildWhichIsA("Humanoid")
        if not (char and hum) then return nil end
        -- already holding the shovel?
        local eq = char:FindFirstChildWhichIsA("Tool")
        if eq and (eq:GetAttribute("Shovel") ~= nil or eq.Name:lower():find("shovel")) then return eq end
        local bp = LocalPlayer:FindFirstChild("Backpack")
        if bp then
            for _, t in ipairs(bp:GetChildren()) do
                if t:IsA("Tool") and (t:GetAttribute("Shovel") ~= nil or t.Name:lower():find("shovel")) then
                    pcall(function() hum:EquipTool(t) end)
                    return t
                end
            end
        end
        return nil
    end

    -- ONE aggressive swing: face the primary target so the arc covers it, fire SwingShovel,
    -- then fire HitPlayer for EVERY enemy within HIT_RANGE + the facing cone whose per-target
    -- cooldown is up (mirrors the real blade hitting everyone it touches in front). Returns the
    -- list of names actually hit.
    local function swingHit(hrp, primaryPh)
        if primaryPh then
            local flat = Vector3.new(primaryPh.Position.X,0,primaryPh.Position.Z) - Vector3.new(hrp.Position.X,0,hrp.Position.Z)
            if flat.Magnitude > 0.1 then
                pcall(function() hrp.CFrame = CFrame.lookAt(hrp.Position, Vector3.new(primaryPh.Position.X, hrp.Position.Y, primaryPh.Position.Z)) end)
                task.wait()   -- let the facing replicate one frame before the server reads dot
            end
        end
        local swingP = packet("Shovel", "SwingShovel")
        local hitP   = packet("Shovel", "HitPlayer")
        if swingP then pcall(function() swingP:Fire() end) end

        local now  = os.clock()
        local look = hrp.CFrame.LookVector
        local flatLook = Vector3.new(look.X, 0, look.Z)
        flatLook = flatLook.Magnitude > 0.001 and flatLook.Unit or look
        local hitNames = {}
        for _, p in ipairs(Players:GetPlayers()) do
            if p ~= LocalPlayer and p.Character then
                local ph = p.Character:FindFirstChild("HumanoidRootPart")
                local hh = p.Character:FindFirstChildWhichIsA("Humanoid")
                if ph and hh and hh.Health > 0 then
                    local d = (ph.Position - hrp.Position).Magnitude
                    if d <= HIT_RANGE and (now - (_hitAt[p] or 0)) > TARGET_COOLDOWN then
                        local flat = Vector3.new(ph.Position.X,0,ph.Position.Z) - Vector3.new(hrp.Position.X,0,hrp.Position.Z)
                        local dot  = flat.Magnitude > 0.1 and flat.Unit:Dot(flatLook) or 1
                        if dot >= FACE_DOT then
                            if hitP then pcall(function() hitP:Fire(p.UserId) end) end
                            _hitAt[p] = os.clock()
                            hitNames[#hitNames+1] = p.Name
                        end
                    end
                end
            end
        end
        return hitNames
    end

    local function tryShovelHit()
        if not State.autoShovelHit then return end
        if State.tpBusy then return end                          -- don't fight bot teleports/steal/escort move
        if State.stealing then return end
        local char = LocalPlayer.Character
        local hrp  = char and char:FindFirstChild("HumanoidRootPart")
        if not hrp then return end

        -- scan: nearest enemy already in HIT_RANGE (cooldown up), and nearest enemy within
        -- CHASE_RANGE to dash at if nobody is in range yet.
        local now = os.clock()
        local hitTarget, hitPh, hitD
        local chaseTarget, chasePh, chaseD
        for _, p in ipairs(Players:GetPlayers()) do
            if p ~= LocalPlayer and p.Character then
                local ph = p.Character:FindFirstChild("HumanoidRootPart")
                local hh = p.Character:FindFirstChildWhichIsA("Humanoid")
                if ph and hh and hh.Health > 0 then
                    local d = (ph.Position - hrp.Position).Magnitude
                    if d <= HIT_RANGE then
                        if (now - (_hitAt[p] or 0)) > TARGET_COOLDOWN and (not hitD or d < hitD) then
                            hitTarget, hitPh, hitD = p, ph, d
                        end
                    elseif d <= CHASE_RANGE then
                        if not chaseD or d < chaseD then chaseTarget, chasePh, chaseD = p, ph, d end
                    end
                end
            end
        end

        if not hitTarget and not chaseTarget then
            State.shovelStatus = "watching… (no enemy near)"
            return
        end
        if (now - _lastSwing) < SWING_COOLDOWN then return end    -- swing cycle cooldown

        local shovel = equipShovel()
        if not shovel then State.shovelStatus = "no shovel tool owned"; return end

        local hitNames
        if hitTarget then
            -- someone's already in range → whack them + everyone clustered in front
            hitNames = swingHit(hrp, hitPh)
        elseif chaseTarget then
            -- AGGRESSIVE GAP-CLOSE: dash to ~5 studs from the enemy, whack, snap back home.
            State.shovelStatus = "charging " .. chaseTarget.Name .. "…"
            local saved = hrp.CFrame
            State.tpBusy = true
            pcall(function()
                for _ = 1, 5 do
                    if not (chasePh and chasePh.Parent) then break end
                    local tp   = chasePh.Position
                    local flat = Vector3.new(tp.X,0,tp.Z) - Vector3.new(hrp.Position.X,0,hrp.Position.Z)
                    if flat.Magnitude <= (HIT_RANGE - 2) then break end
                    local stand = Vector3.new(tp.X, hrp.Position.Y, tp.Z) - flat.Unit * 5
                    pcall(function() hrp.CFrame = CFrame.lookAt(stand, Vector3.new(tp.X, hrp.Position.Y, tp.Z)) end)
                    task.wait()
                end
            end)
            if chasePh and chasePh.Parent and (chasePh.Position - hrp.Position).Magnitude <= HIT_RANGE then
                hitNames = swingHit(hrp, chasePh)
            end
            pcall(function() if hrp.Parent then hrp.CFrame = saved end end)   -- snap back to where we were
            State.tpBusy = false
        end

        _lastSwing = os.clock()
        if hitNames and #hitNames > 0 then
            State.shovelHits = (State.shovelHits or 0) + #hitNames
            State.shovelStatus = "hit " .. table.concat(hitNames, ", ") .. "  (total ×" .. State.shovelHits .. ")"
        end
    end

    task.spawn(function()
        while State.alive do
            if State.autoShovelHit then pcall(tryShovelHit) else State.shovelStatus = "off" end
            -- prune stale per-target cooldowns
            for p, t in pairs(_hitAt) do
                if (os.clock() - t) > 30 or not p.Parent then _hitAt[p] = nil end
            end
            waitFn(0.1)   -- check ~10×/sec; actual hits gated by SWING_COOLDOWN
        end
    end)
end

--===========================================================================--
-- ESCORT / PROTECT bought pets — a pet you buy WALKS to your garden ("walking_to_garden")
-- and is STEALABLE the whole walk (its BuyPrompt stays enabled for everyone else). The only
-- real defense is being NEAR it so Auto-Shovel-Hit whacks any thief who comes within the
-- ~12-stud re-buy range. This follows YOUR walking pets until they're secured (reach garden →
-- the WildPetRef part is removed). Pair with Auto-Shovel Hit for the actual protection.
--===========================================================================--
do
    -- your own pets currently walking to your garden (authoritative WildPetRef attributes)
    local function ownWalkingPets()
        local out = {}
        local map = workspace:FindFirstChild("Map")
        local ref = map and map:FindFirstChild("WildPetRef")
        if ref then
            for _, p in ipairs(ref:GetChildren()) do
                if p:IsA("BasePart") then
                    local owner = tonumber(p:GetAttribute("OwnerUserId")) or 0
                    -- ANY pet we own that's still a WildPetRef = bought but NOT yet secured
                    -- (it's walking to our garden). Don't require an exact State string — the
                    -- ref disappears the instant it's secured, so presence here == still walking.
                    if owner == LocalPlayer.UserId then
                        out[#out+1] = p
                    end
                end
            end
        end
        return out
    end

    task.spawn(function()
        while State.alive do
            if State.autoProtectPets and not State.tpBusy and not State.stealing then
                local pets = ownWalkingPets()
                if #pets > 0 then
                    local char = LocalPlayer.Character
                    local hrp  = char and char:FindFirstChild("HumanoidRootPart")
                    if hrp then
                        -- escort the nearest walking pet: stay within ~6 studs so Auto-Shovel
                        -- (which targets enemies near YOU) covers any thief approaching the pet.
                        local best, bestD
                        for _, p in ipairs(pets) do
                            local d = (p.Position - hrp.Position).Magnitude
                            if not bestD or d < bestD then best, bestD = p, d end
                        end
                        if best and best.Parent then
                            State.protectStatus = ("escorting %d pet(s)"):format(#pets)
                            if bestD > 6 then
                                State.tpBusy = true
                                pcall(function()
                                    local destPos = best.Position + Vector3.new(0, 3, 0)
                                    local startP  = hrp.Position
                                    local steps   = math.clamp(math.ceil((destPos - startP).Magnitude / 8), 1, 30)
                                    for si = 1, steps do
                                        if not (State.autoProtectPets and best.Parent) then break end
                                        if hrp.Parent == nil then break end
                                        -- re-read the pet's CURRENT position (it keeps walking)
                                        local cur = best.Position + Vector3.new(0, 3, 0)
                                        pcall(function() hrp.CFrame = CFrame.new(hrp.Position:Lerp(cur, si / steps)) end)
                                        task.wait(0.04)
                                    end
                                end)
                                State.tpBusy = false
                            end
                        end
                    end
                else
                    State.protectStatus = "watching… (no pets walking)"
                end
            else
                State.protectStatus = "off"
            end
            waitFn(0.25)
        end
    end)
end

-- tpBusy WATCHDOG: the HRP mutex (shared by buy-pets / steal / collect) can get stuck
-- on `true` if a teleport coroutine is interrupted mid-action (respawn, slow chase,
-- script re-exec). A stuck tpBusy permanently blocks ALL pet buying. This force-clears
-- it if it's been held >20s — far longer than any legit teleport action needs.
task.spawn(function()
    local heldSince = nil
    while State.alive do
        if State.tpBusy then
            heldSince = heldSince or os.clock()
            if (os.clock() - heldSince) > 20 then
                State.tpBusy   = false
                State.stealing = false
                heldSince = nil
                warn("[YumaBlox] tpBusy stuck >20s → force-cleared (pet-buy unblocked)")
            end
        else
            heldSince = nil
        end
        task.wait(2)
    end
end)

-- instant pet detection: fire tryBuyPets the moment a new wild pet spawns
-- instead of waiting for the next BUY_RESCAN tick (was up to 5s delay)
task.spawn(function()
    local wps = wildPetSpawns()
    if not wps then
        -- wait for map to load then hook
        local map = workspace:WaitForChild("Map", 30)
        wps = map and map:WaitForChild("WildPetSpawns", 30)
    end
    if not wps then return end
    wps.ChildAdded:Connect(function(newPet)
        if not State.autoBuyPets then return end
        -- small settle so the pet's RootPart and BuyPrompt are parented
        task.wait(0.3)
        if not State.tpBusy then pcall(tryBuyPets) end
    end)
end)

task.spawn(function()                                        -- wild event-seed collector (Gold/Rainbow Models in workspace.DroppedItems)
    while State.alive do
        if State.autoCollectWild then
            pcall(tryCollectWild)
        else
            State.collectStatus = "off"
        end
        waitFn(COLLECT_RESCAN)
    end
end)

task.spawn(function()                                        -- steal loop (night only)
    while State.alive do
        if State.autoSteal and not (State.protectBase and isNight()) then   -- guarding base takes precedence over raiding
            pcall(trySteal)
            State.stealing = false                       -- finally: never leave harvest paused if trySteal errored
        end
        waitFn(STEAL_RESCAN)
    end
end)

--===========================================================================--
-- PROTECT BASE (night) — stand inside your own garden so it's LOCKED (un-stealable).
--   A plot is un-stealable while its owner is present (IsInOwnGarden==true, LIVE-VERIFIED).
--   So at night we keep the character home; if pushed/flung out, snap straight back. Claims
--   the tpBusy mutex during the hop so Anti-Fling + the steal/buy teleporters don't fight it.
--===========================================================================--
task.spawn(function()
    while State.alive do
        if not State.protectBase then
            waitFn(0.5)
        elseif not isNight() then
            State.stealStatus = "🛡️ Protect Base: waiting for night ☀️"
            waitFn(1.0)
        elseif State.stealing or State.tpBusy then
            waitFn(0.3)                                   -- a steal/buy teleport is mid-flight; don't tug-of-war
        else
            local base = myBaseCFrame()
            local char = LocalPlayer.Character
            local hrp  = char and char:FindFirstChild("HumanoidRootPart")
            if not base or not hrp then
                State.stealStatus = "🛡️ Protect Base: no plot / character"
                waitFn(1.0)
            elseif LocalPlayer:GetAttribute("IsInOwnGarden") ~= true then
                State.tpBusy = true                       -- claim HRP mutex (Anti-Fling whitelists tpBusy)
                pcall(function() hrp.CFrame = base end)   -- snap home -> IsInOwnGarden flips true -> plot LOCKED
                waitFn(0.15)                              -- let Anti-Fling re-anchor to the new spot
                State.tpBusy = false
                State.stealStatus = "🛡️ Protect Base: returning home…"
                waitFn(0.2)
            else
                State.stealStatus = "🛡️ Protect Base: GUARDING 🔒 (no one can steal)"
                waitFn(0.35)
            end
        end
    end
end)

task.spawn(function()                                        -- /finds -> webhook (gated: only runs once BigFroot is detected)
    local G = getgenv and getgenv() or _G
    G.YB_WH_SENT = G.YB_WH_SENT or {}

    -- flexible BigFroot search: scans all of CoreGui + PlayerGui up to depth 8
    -- works on PC and mobile regardless of where BigFroot puts its UI
    -- CACHED: the recursive CoreGui+PlayerGui depth-8 scan is expensive on mobile, so we cache
    -- the found ScrollingFrame and only re-scan when the cache goes stale (unparented / gone).
    local _bfSf = nil
    local function findBFSf()
        if _bfSf and _bfSf.Parent then return _bfSf end   -- cache hit — no scan
        _bfSf = nil
        local function search(root, depth)
            if depth > 8 then return nil end
            for _, v in ipairs(root:GetChildren()) do
                if v:IsA("ScrollingFrame") then
                    local par = v.Parent
                    if par then
                        for _, sib in ipairs(par:GetChildren()) do
                            if sib:IsA("TextLabel") and tostring(sib.Text):find("Current server:") then
                                return v
                            end
                        end
                    end
                end
                local found = search(v, depth + 1)
                if found then return found end
            end
        end
        local ok1, r1 = pcall(search, game:GetService("CoreGui"), 0)
        if ok1 and r1 then _bfSf = r1; return r1 end
        local ok2, r2 = pcall(search, game:GetService("Players").LocalPlayer.PlayerGui, 0)
        if ok2 and r2 then _bfSf = r2; return r2 end
        return nil
    end
    local function bfReady() return findBFSf() ~= nil end

    while State.alive and not bfReady() do
        waitFn(2)   -- poll every 2s until BigFroot loads
    end

    -- BigFroot is live — now start the /finds webhook loop
    while State.alive do
        pcall(function()
            if not bfReady() then return end   -- BigFroot vanished (e.g. BF unloaded) — skip this tick
            local ok, body = httpGetAsync(SNIPE_BASE .. "/finds?key=" .. SNIPE_KEY)
            if not ok or type(body) ~= "string" then return end
            local okD, data = pcall(function() return HttpService:JSONDecode(body) end)
            if not okD or type(data) ~= "table" or type(data.finds) ~= "table" then return end
            for _, f in ipairs(data.finds) do pcall(whPost, f) end
        end)
        waitFn(5)   -- webhook forwarding is dedup'd per-find — 5s is plenty (was 1.5s + a GUI scan)
    end
end)

do  --[[ ============================================================
   BIGFROOT SERVER SCANNER  —  EVENT-DRIVEN real-time + coordinator design

   * ChildAdded on BigFroot's ScrollingFrame fires the INSTANT BigFroot
     adds a new server row — zero polling delay, truly real-time.
   * ChildRemoved keeps YB_BF_FINDS in sync so the UI tab never shows
     stale servers that BigFroot has already dropped.
   * A lightweight 5s heartbeat re-hooks if BigFroot rebuilds its panel
     (e.g. after a refresh) and prunes the cooldown map.
   * Rarity gate (BF_MIN_RANK), cooldown dedup (BF_WH_COOLDOWN), bounded
     serialised webhook queue + 429 retry — all match the coordinator.
   ============================================================ ]]
    local BF_WH_COOLDOWN  = 120    -- sec: don't re-post the SAME server within this window
    local BF_WH_MIN_GAP   = 0.55   -- sec between webhook posts (~Discord 5/s limit)
    local BF_WH_QUEUE_MAX = 50     -- hard cap; oldest dropped when full
    local BF_MIN_RANK     = 4      -- 4=Epic+. 5=Legendary+, 6=Mythic+ only.
    local BF_HEARTBEAT    = 5      -- sec between re-hook checks (handles BF panel rebuilds)

    local BF_RAR_RANK  = { common=1, uncommon=2, rare=3, epic=4, legendary=5, mythic=6, mythical=6, super=7, secret=8 }
    local BF_RAR_ICON  = { Mythic="🔴", Super="🌈", Secret="✨", Legendary="🟡", Epic="🟣", Rare="🔵", Uncommon="🟢", Common="⚪" }
    local BF_RAR_COLOR = { Mythic=0xED4245, Super=0xFF73FA, Secret=0xFFFFFF, Legendary=0xFFCC15, Epic=0x9B59B6, Rare=0x5865F2, Uncommon=0x57F287, Common=0xAAAAAA }

    local G = getgenv and getgenv() or _G
    G.YB_BF_FINDS    = G.YB_BF_FINDS    or {}   -- live UI feed  (jobId -> entry)
    G.YB_BF_RECENT   = G.YB_BF_RECENT   or {}   -- jobId -> last-webhook os.time
    G.YB_BF_WH_QUEUE = G.YB_BF_WH_QUEUE or {}   -- bounded FIFO of JSON strings
    G.YB_BF_REPORT_Q = G.YB_BF_REPORT_Q or {}   -- bounded FIFO of coordinator /report JSON bodies

    -- ── serialised webhook sender (single coroutine, 429-aware) ──────────────
    task.spawn(function()
        while State.alive do
            local payload = table.remove(G.YB_BF_WH_QUEUE, 1)
            if payload and _wh_req and WH_URL ~= "" then
                local ok, res = pcall(_wh_req, {
                    Url = WH_URL, Method = "POST",
                    Headers = { ["Content-Type"] = "application/json" },
                    Body = payload,
                })
                local code = ok and res and (res.StatusCode or res.status_code) or 0
                if code == 429 then
                    local retry = 2
                    pcall(function()
                        retry = math.min(game:GetService("HttpService"):JSONDecode(res.Body or res.body or "{}").retry_after or 2, 30)
                    end)
                    table.insert(G.YB_BF_WH_QUEUE, 1, payload)   -- re-queue, retry after back-off
                    waitFn(retry + 0.5)
                else
                    waitFn(BF_WH_MIN_GAP)
                end
            else
                waitFn(0.2)
            end
        end
    end)

    -- ── serialised coordinator /report sender — drains at a steady ~12/s so seeding 200+
    --    BigFroot servers can't fire 200+ HTTP POSTs in one burst and hitch the client ──
    task.spawn(function()
        local _r = (syn and syn.request) or (http and http.request) or http_request or request
        while State.alive do
            local body = table.remove(G.YB_BF_REPORT_Q, 1)
            if body and _r and SNIPE_BASE ~= "" then
                pcall(_r, {
                    Url = SNIPE_BASE .. "/report", Method = "POST",
                    Headers = { ["Content-Type"] = "application/json", ["X-PH-Key"] = SNIPE_BOT_KEY },
                    Body = body,
                })
                waitFn(0.08)
            else
                waitFn(0.3)
            end
        end
    end)

    local function bfEnqueue(payload)
        while #G.YB_BF_WH_QUEUE >= BF_WH_QUEUE_MAX do table.remove(G.YB_BF_WH_QUEUE, 1) end
        G.YB_BF_WH_QUEUE[#G.YB_BF_WH_QUEUE + 1] = payload
    end

    -- ── extract jobId from a Join button's upvalues ───────────────────────────
    -- Read BigFroot's STRUCTURED server entry straight from the Join button's click-handler
    -- upvalue. This is HoshiHub's generated data (the real source) — exact and complete, far more
    -- reliable than scraping the row's label text. Shape (verified live via dex):
    --   { jobId=string, placeId=number, age=number(seconds), players=number, maxPlayers=number,
    --     score=number, source="HoshiHub", version=number,
    --     pets = { { n=name, r=rarity, s=size, m=mutation }, ... } }
    local function getEntry(btn)
        if not btn then return nil end
        local ok, conns = pcall(getconnections, btn.MouseButton1Click)
        if not ok or type(conns) ~= "table" then return nil end
        for _, conn in ipairs(conns) do
            local f = conn and conn.Function
            if f then
                local ok2, ups = pcall(debug.getupvalues, f)
                if ok2 and type(ups) == "table" then
                    for _, uv in ipairs(ups) do
                        if type(uv) == "table" and type(uv.jobId) == "string" and uv.pets ~= nil then
                            return uv
                        end
                    end
                end
            end
        end
        return nil
    end
    local function getJobId(btn)   -- thin wrapper kept for ChildRemoved
        local e = getEntry(btn); return e and e.jobId or nil
    end

    -- ── process one new entry (called from ChildAdded) ────────────────────────
    local _bfSeen = {}   -- frame identity dedup (set before yield to prevent race)
    -- DEBOUNCED redraw: BigFroot lists 200+ servers; redrawing per row would rebuild the UI
    -- list hundreds of times in a burst. Coalesce every update into ONE redraw per ~0.25s.
    local _renderQueued = false
    local function queueRender()
        if _renderQueued then return end
        _renderQueued = true
        task.spawn(function()
            task.wait(0.25)
            _renderQueued = false
            if State.bfRender then pcall(State.bfRender) end
        end)
    end
    local function processEntry(entry)
        if not entry:IsA("Frame") then return end
        -- dedup by the INSTANCE itself. BUG FIX: tostring(row) is "Frame" for EVERY row, so the
        -- old `_bfSeen[tostring(entry)]` key COLLIDED — after the first row it skipped all the
        -- rest, so only 1 of ~265 BigFroot servers was ever detected. Instances are unique keys.
        if _bfSeen[entry] then return end
        _bfSeen[entry] = true

        -- poll until BigFroot populates the row (button + structured entry), up to 0.6s
        local deadline = os.clock() + 0.6
        local btn, data
        repeat
            task.wait()
            if not entry.Parent then return end
            btn  = entry:FindFirstChildWhichIsA("TextButton")
            data = btn and getEntry(btn)
        until data or os.clock() > deadline
        if not entry.Parent then return end

        local jobId, placeId, ageSecs, petName, rar, rank, pet, players
        local allNames = {}
        if data then
            -- ===== STRUCTURED PATH (preferred): exact data from BigFroot / HoshiHub =====
            jobId   = data.jobId
            placeId = tonumber(data.placeId) or game.PlaceId
            ageSecs = tonumber(data.age)
            rank    = -1
            if type(data.pets) == "table" then
                local disp = {}
                for _, p in ipairs(data.pets) do
                    local nm = tostring(p.n or "?")
                    allNames[#allNames + 1] = nm
                    disp[#disp + 1] = nm .. " (" .. tostring(p.r or "?") .. ")"
                    local rk = BF_RAR_RANK[tostring(p.r or ""):lower()] or 0
                    if rk > rank then rank, rar, petName = rk, tostring(p.r or ""), nm end   -- keep HIGHEST rarity in the server
                end
                pet = table.concat(disp, ", ")
            end
            if not petName then return end
            players = (data.players and data.maxPlayers)
                and (tostring(data.players) .. "/" .. tostring(data.maxPlayers) .. " players") or ""
        else
            -- ===== TEXT FALLBACK: parse the row labels (only if the upvalue read failed) =====
            pet, players = "", ""
            for _, v in ipairs(entry:GetChildren()) do
                if v:IsA("TextLabel") then
                    if tostring(v.Text):find("players") then players = v.Text
                    elseif v.Text ~= "" then pet = v.Text end
                end
            end
            if pet == "" then return end
            jobId   = getJobId(btn)
            placeId = game.PlaceId
            if players ~= "" then
                local m, s = players:match("(%d+)%s*m%s*(%d+)%s*s%s*ago")
                local sOnly = players:match("%D*(%d+)%s*s%s*ago")
                if m and s then ageSecs = tonumber(m) * 60 + tonumber(s)
                elseif sOnly then ageSecs = tonumber(sOnly) end
            end
            petName = pet:match("^(.-)%s*%(") or pet
            rar     = pet:match("%((.-)%)") or ""
            rank    = BF_RAR_RANK[rar:lower()] or 0
        end
        if ageSecs and ageSecs > 30 then return end   -- only skip when age is KNOWN and stale
        local uiKey = jobId or (tostring(petName) .. "|" .. tostring(ageSecs))

        -- update live UI feed immediately + force redraw
        -- insertedAt timestamp enables TTL eviction so stale dead servers expire automatically
        G.YB_BF_FINDS[uiKey] = {
            name = petName .. " ★", rarity = rar,
            job = jobId, place = placeId,
            secondsLeft = 0, players = players, source = "bigfroot",
            insertedAt = os.clock(),
            ageSecs = ageSecs,   -- 0 = brand-new "0s ago", nil = unknown, >0 = stale
            allPets = allNames,  -- every pet in this server (structured), not just the headline one
        }
        queueRender()

        -- INSTANT SNIPE TRIGGER: if this is a brand-new "0s ago" server and auto-snipe is ON,
        -- fire the join immediately without waiting for the next 1.5s poll cycle.
        -- The poller ignores old info; this path reacts the moment BigFroot finds it.
        if ageSecs == 0 and jobId and State.snipeAuto and not State.snipeBusy then
            local rank = (RAR_RANK or {})
            -- reuse the BF_RAR_RANK table defined in the BigFroot scanner block
            local G2 = getgenv and getgenv() or _G
            task.spawn(function()
                if not State.snipeAuto or State.snipeBusy then return end
                if not snipeMatch(petName, rar) then return end   -- rarity not selected, or not one of the chosen pets
                if jobId == game.JobId then return end        -- already in this server (fixed: was `jb` which was undeclared)
                local G3 = getgenv and getgenv() or _G
                G3.YB_SNIPE_RECENT  = G3.YB_SNIPE_RECENT  or {}
                G3.YB_SNIPE_FAILED  = G3.YB_SNIPE_FAILED  or {}
                if G3.YB_SNIPE_FAILED[jobId] then return end
                if G3.YB_SNIPE_RECENT[jobId] and (os.time()-G3.YB_SNIPE_RECENT[jobId]) < 120 then return end
                if (os.time()-(G3.YB_LAST_SNIPE or 0)) < 10 then return end  -- arriving cooldown
                -- lock and snipe
                State.snipeBusy = true
                G3.YB_SNIPE_RECENT[jobId] = os.time()
                G3.YB_LAST_SNIPE = os.time()
                State.snipeStatus = "⚡ instant snipe " .. tostring(petName or pet) .. " (0s ago)…"
                armReload()
                local TS3 = game:GetService("TeleportService")
                local tpFailed, tpResult = false, nil
                local conn
                pcall(function()
                    conn = TS3.TeleportInitFailed:Connect(function(_, res)
                        tpFailed = true; tpResult = res
                    end)
                end)
                -- spam TP: 4 join requests over ~1 second (250ms apart)
                for _s = 1, 4 do
                    if tpFailed then break end
                    pcall(function() TS3:TeleportToPlaceInstance(placeId, jobId, LocalPlayer) end)
                    task.wait(0.25)
                end
                local t0 = os.clock()
                repeat task.wait(0.1) until tpFailed or (os.clock()-t0 > 3)
                if conn then pcall(function() conn:Disconnect() end) end
                if tpFailed then
                    if tpResult == Enum.TeleportResult.Unauthorized
                        or tpResult == Enum.TeleportResult.GameNotFound
                        or tpResult == Enum.TeleportResult.GameEnded then
                        G3.YB_SNIPE_FAILED[jobId] = os.time()
                        -- notify coordinator
                        local _r2 = (syn and syn.request) or http_request or request
                        if _r2 and SNIPE_BASE ~= "" then
                            pcall(_r2, {
                                Url = SNIPE_BASE.."/report773", Method = "POST",
                                Headers = {["Content-Type"]="application/json",["X-PH-Key"]=SNIPE_BOT_KEY},
                                Body = game:GetService("HttpService"):JSONEncode({bot="autosnipe",job=jobId,petName=petName,rarity=rar,place=placeId}),
                            })
                        end
                    end
                else
                    State.snipeStatus = "⚡ sniped " .. tostring(pet)
                end
                State.snipeBusy = false
            end)
        end

        -- report to coordinator so it appears in /finds for the Live Wild Pets tab
        -- the coordinator adds it with SNIPE_DEFAULT_TTL (90s) expiry
        if jobId and petName ~= "" and rar ~= "" then
            -- queue it — the /report sender coroutine drains at ~12/s so a 200+ server seed
            -- doesn't fire 200+ POSTs at once. Bound the queue so a down coordinator can't leak.
            local q = G.YB_BF_REPORT_Q
            while #q >= 120 do table.remove(q, 1) end
            q[#q + 1] = game:GetService("HttpService"):JSONEncode({
                bot     = "bigfroot",
                job     = jobId,
                place   = placeId,
                players = tonumber((players or ""):match("(%d+)/")) or 0,
                pets    = {{ name = petName, rarity = rar }},
            })
        end

        -- rarity + cooldown gate for webhook
        if rank < BF_MIN_RANK then return end
        if not jobId then return end   -- need jobId for the webhook join command
        local now = os.time()
        if (now - (G.YB_BF_RECENT[jobId] or 0)) < BF_WH_COOLDOWN then return end
        G.YB_BF_RECENT[jobId] = now

        local icon    = BF_RAR_ICON[rar]  or "\xf0\x9f\x90\xbe"
        local color   = BF_RAR_COLOR[rar] or 0xFFCC15
        local joinCmd = "```\nTeleportToPlaceInstance(" .. tostring(placeId) .. ', "' .. jobId .. '")\n```'
        bfEnqueue(game:GetService("HttpService"):JSONEncode({
            username = "Pet Hunter",
            embeds   = {{
                title       = icon .. " " .. pet,
                description = "• **" .. pet .. "**  —  " .. players,
                color       = color,
                fields      = {
                    { name = "Server (JobId)", value = "`" .. jobId .. "`",   inline = false },
                    { name = "Players",        value = players,                inline = true  },
                    { name = "Place",          value = tostring(placeId),      inline = true  },
                    { name = "Join",           value = joinCmd,                inline = false },
                },
                footer = { text = "pet-hunter" },
            }},
        }))
    end

    -- ── hook onto a ScrollingFrame: ChildAdded fires on every new row ─────────
    local hookedSf = nil
    local sfConns  = {}
    local function hookSf(sf)
        if sf == hookedSf then return end
        for _, c in ipairs(sfConns) do pcall(function() c:Disconnect() end) end
        sfConns, hookedSf = {}, sf

        -- seed existing rows; clear _bfSeen so re-seeding isn't blocked by prior run
        table.clear(_bfSeen)
        G.YB_BF_FINDS = {}
        -- seed in ONE throttled coroutine (~5 rows / frame) instead of spawning 200+ at once —
        -- that thundering herd of getupvalues + queued reports was the real per-hook spike.
        task.spawn(function()
            local n = 0
            for _, entry in ipairs(sf:GetChildren()) do
                if hookedSf ~= sf then break end   -- a newer hook replaced us → abandon this seed
                pcall(processEntry, entry)
                n += 1
                if n % 5 == 0 then task.wait() end
            end
        end)

        -- real-time: fires the instant BigFroot adds a new server row
        sfConns[#sfConns+1] = sf.ChildAdded:Connect(function(entry)
            task.spawn(processEntry, entry)
        end)

        -- keep UI feed in sync when BigFroot removes a server
        -- capture jobId SYNCHRONOUSLY before task.spawn — entry children may be
        -- inaccessible after one yield on some executors
        sfConns[#sfConns+1] = sf.ChildRemoved:Connect(function(entry)
            _bfSeen[entry] = nil   -- free the dedup key so a re-listed row can be re-detected
            local btn   = entry:FindFirstChildWhichIsA("TextButton")
            local jobId = getJobId(btn)
            -- also capture fallback uiKey in case getJobId returns nil
            local pet, players2 = "", ""
            pcall(function()
                for _, v in ipairs(entry:GetChildren()) do
                    if v:IsA("TextLabel") then
                        if v.Text:find("players") then players2 = v.Text
                        elseif v.Text ~= "" then pet = v.Text end
                    end
                end
            end)
            local petName = pet:match("^(.-)%s*%(") or pet
            local fallbackKey = petName ~= "" and (petName .. "|" .. players2) or nil
            task.spawn(function()
                task.wait()   -- let BF potentially re-add before removing
                if jobId then G.YB_BF_FINDS[jobId] = nil end
                if fallbackKey then G.YB_BF_FINDS[fallbackKey] = nil end
                queueRender()
            end)
        end)
    end

    -- ── heartbeat: re-hook if BF rebuilds its panel, prune cooldown map ───────
    task.spawn(function()
        while State.alive do
            pcall(function()
                local now = os.time()
                for jid, t in pairs(G.YB_BF_RECENT) do
                    if now - t > BF_WH_COOLDOWN * 2 then G.YB_BF_RECENT[jid] = nil end
                end
                local sf = nil
                -- try fast hardcoded path first, fall back to flexible deep search
                pcall(function()
                    local main = game:GetService("CoreGui").RobloxGui.BigFrootServerBrowser.Main
                    for _, c in ipairs(main:GetChildren()) do
                        if c:IsA("Frame") then
                            local candidate = c:FindFirstChildWhichIsA("ScrollingFrame")
                            if candidate then sf = candidate; break end
                        end
                    end
                end)
                if not sf then
                    -- flexible fallback: search CoreGui + PlayerGui for the panel
                    local function search(root, depth)
                        if depth > 8 then return nil end
                        for _, v in ipairs(root:GetChildren()) do
                            if v:IsA("ScrollingFrame") then
                                local par = v.Parent
                                if par then
                                    for _, sib in ipairs(par:GetChildren()) do
                                        if sib:IsA("TextLabel") and tostring(sib.Text):find("Current server:") then
                                            return v
                                        end
                                    end
                                end
                            end
                            local found = search(v, depth + 1)
                            if found then return found end
                        end
                    end
                    pcall(function() sf = search(game:GetService("CoreGui"), 0) end)
                    if not sf then pcall(function() sf = search(game:GetService("Players").LocalPlayer.PlayerGui, 0) end) end
                end
                if sf then hookSf(sf) end
            end)
            waitFn(BF_HEARTBEAT)
        end
    end)

end

local RESCAN_BUSY = 0.05   -- near-zero gap between sweeps while fruit is still ripening/draining
task.spawn(function()                                        -- harvest + sell loop (incremental, no HTTP, no dead time)
    local seen = {}                                          -- prompt -> os.clock() when we last fired it
    while State.alive do
        if not State.running then
            State.status = "paused"; table.clear(seen); waitFn(0.25)
        elseif PAUSE_HARVEST_WHILE_STEALING and State.stealing then
            trySell(); State.status = "harvest paused — stealing"; State.ripe = 0; waitFn(0.2)
        else
            trySell()
            local plot = findMyPlot()
            if not plot then
                State.status = "waiting for plot…"; State.ripe = 0; table.clear(seen); waitFn(1.0)
            else
                local now = os.clock()
                for prompt in pairs(seen) do                 -- prune harvested (prompt destroyed or no longer ripe)
                    if prompt.Parent == nil or not prompt.Enabled then seen[prompt] = nil; State.harvested += 1 end
                end
                local batch = collectPrompts(plot, seen, now)   -- new ripe prompts + grace-expired retries
                State.ripe = #batch
                if #batch == 0 then
                    if next(seen) ~= nil then State.status = "draining…"; trySell(); waitFn(RESCAN_BUSY)
                    else State.status = "idle — no ripe fruit"; waitFn(RESCAN_DELAY) end
                else
                    State.status = ("harvesting %d…"):format(#batch)
                    for i, e in ipairs(batch) do
                        if not (State.alive and State.running) then break end
                        if PAUSE_HARVEST_WHILE_STEALING and State.stealing then break end
                        if e.prompt.Parent ~= nil and e.prompt.Enabled then
                            fire(e.prompt); State.fires += 1
                            seen[e.prompt] = os.clock()
                            if i % 10 == 0 then trySell() end
                            waitFn(State.fireGap)                -- speed slider is authoritative
                        end
                    end
                    waitFn(RESCAN_BUSY)
                end
            end
        end
    end
end)

--===========================================================================--
-- FRUIT WEIGHT/PRICE ESP  — floats "kg | $price" over each fruit in MY garden.
--   Bounded to my own plot, refreshes ~2x/sec, reuses billboards (no per-frame work).
--   Weight = SizeMulti * 7.5; price uses the game's own value formula.
--===========================================================================--
do
    local labels = {}                       -- fruitModel -> BillboardGui
    local function clearAll()
        for f, bb in pairs(labels) do pcall(function() bb:Destroy() end); labels[f] = nil end
    end
    local function partOf(fruit)
        return fruit.PrimaryPart or fruit:FindFirstChild("HarvestPart") or fruit:FindFirstChildWhichIsA("BasePart", true)
    end
    local function fmtVal(v)
        if v >= 1e9 then return ("$%.2fB"):format(v / 1e9)
        elseif v >= 1e6 then return ("$%.2fM"):format(v / 1e6)
        elseif v >= 1e3 then return ("$%.1fK"):format(v / 1e3)
        else return ("$%d"):format(v) end
    end
    local function makeBB(part)
        local bb = Instance.new("BillboardGui")
        bb.Name = "YB_FruitInfo"
        bb.Size = UDim2.fromOffset(160, 30)
        bb.StudsOffset = Vector3.new(0, 2.4, 0)
        bb.AlwaysOnTop = true
        bb.MaxDistance = 140
        bb.LightInfluence = 0
        bb.Adornee = part
        local tl = Instance.new("TextLabel")
        tl.Name = "T"
        tl.AnchorPoint = Vector2.new(0.5, 0.5)
        tl.Position = UDim2.fromScale(0.5, 0.5)
        tl.AutomaticSize = Enum.AutomaticSize.XY           -- hug the text so the bg stays small
        tl.Size = UDim2.fromOffset(0, 0)
        tl.BackgroundTransparency = 0.45                   -- small, subtle background pill
        tl.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
        tl.Font = Enum.Font.GothamBold
        tl.TextSize = 13
        tl.TextColor3 = Color3.fromRGB(150, 255, 150)
        tl.TextStrokeTransparency = 0.4
        tl.Text = ""
        local pad = Instance.new("UIPadding", tl)
        pad.PaddingLeft, pad.PaddingRight = UDim.new(0, 5), UDim.new(0, 5)
        pad.PaddingTop, pad.PaddingBottom = UDim.new(0, 1), UDim.new(0, 1)
        local corner = Instance.new("UICorner", tl)
        corner.CornerRadius = UDim.new(0, 4)
        tl.Parent = bb
        bb.Parent = part
        return bb
    end
    task.spawn(function()
        while State.alive do
            if not State.espWeight then
                if next(labels) then clearAll() end
                waitFn(0.4)
            else
                local plot = findMyPlot()
                local plants = plot and plot:FindFirstChild("Plants")
                local present = {}
                if plants then
                    for _, pl in ipairs(plants:GetChildren()) do
                        local fr = pl:FindFirstChild("Fruits")
                        if fr then for _, f in ipairs(fr:GetChildren()) do
                            local part = partOf(f)
                            if part then
                                present[f] = true
                                local w, core = fruitWeight(f)
                                local age, maxA = tonumber(f:GetAttribute("Age")), tonumber(f:GetAttribute("MaxAge"))
                                local ripe = (not age) or (not maxA) or age >= maxA   -- price only once fully grown
                                local bb = labels[f]
                                if not bb or bb.Parent == nil then bb = makeBB(part); labels[f] = bb end
                                local t = bb:FindFirstChild("T")
                                if t then
                                    if ripe then
                                        t.Text = ("%.2fkg  %s"):format(w, fmtVal(fruitSellValue(f, w, core)))
                                        t.TextColor3 = Color3.fromRGB(150, 255, 150)   -- green = harvestable
                                    else
                                        t.Text = ("%.2fkg  growing"):format(w)
                                        t.TextColor3 = Color3.fromRGB(205, 205, 205)   -- grey = still growing, no price yet
                                    end
                                end
                            end
                        end end
                    end
                end
                for f, bb in pairs(labels) do
                    if not present[f] then pcall(function() bb:Destroy() end); labels[f] = nil end
                end
                waitFn(0.5)
            end
        end
        clearAll()                          -- tear down on unload (no leftover labels)
    end)
end

--===========================================================================--
-- ANTI-AFK + ANTI-FLING  (always connected; gated by State flags so toggles work live)
--===========================================================================--
do  -- Anti-AFK: defeat Roblox's ~20-min Idled kick AND the game's custom idle server-hop
    local VirtualUser = game:GetService("VirtualUser")
    table.insert(State.conns, LocalPlayer.Idled:Connect(function()
        if not State.antiAfk then return end
        pcall(function() VirtualUser:CaptureController(); VirtualUser:ClickButton2(Vector2.new()) end)
    end))
    task.spawn(function()                                    -- override AntiAfkController's idle timer (verified attr)
        while State.alive do
            if State.antiAfk then pcall(function() LocalPlayer:SetAttribute("AntiAfkIdleOverride", 1e9) end) end
            task.wait(20)
        end
    end)
end

do  -- PERFECT ANTI-FLING v3 — movement-aware. Instead of "detect a >80 stud/s spike then snap
    -- to the last slow spot" (which left a 40–80 stud/s dead zone and a stale anchor while moving),
    -- this PREDICTS your intended motion every frame from WalkSpeed·MoveDirection and clamps ANY
    -- displacement/velocity the game didn't explain. Result: impossible to fling whether you're
    -- standing still OR walking, with zero interference to legit walking/jumping.
    local RunService = game:GetService("RunService")
    local FLING_MOVERS = {
        BodyVelocity=true, BodyForce=true, BodyThrust=true, BodyGyro=true, BodyPosition=true, BodyAngularVelocity=true,
        LinearVelocity=true, AngularVelocity=true, VectorForce=true, Torque=true, AlignPosition=true, AlignOrientation=true,
    }
    local SPIN_LIMIT  = 14      -- rad/s — anything spinnier than a normal turn is a spin-fling
    local VEL_MARGIN  = 14      -- studs/s allowed above WalkSpeed (covers slopes/minor physics)
    local STEP_MARGIN = 3       -- extra studs/frame of horizontal displacement tolerance
    local lastGood = nil        -- last known-legit CFrame
    local function stripMovers(char)
        for _, d in ipairs(char:GetDescendants()) do if FLING_MOVERS[d.ClassName] then pcall(function() d:Destroy() end) end end
    end
    table.insert(State.conns, RunService.Stepped:Connect(function(_, dt)
        if not State.antiFling then
            lastGood = nil
            if State.flingStatus ~= "off" then State.flingStatus = "off" end
            return
        end
        local char = LocalPlayer.Character
        local hum  = char and char:FindFirstChildWhichIsA("Humanoid")
        local hrp  = char and char:FindFirstChild("HumanoidRootPart")
        if not (hum and hrp) then lastGood = nil; return end
        -- never fight our own teleports/steals or our own fling action, or an external anchor
        if State.tpBusy or State.stealing or State.flinging or hrp.Anchored then
            lastGood = hrp.CFrame; return
        end

        local vel  = hrp.AssemblyLinearVelocity
        local horizSpeed = Vector3.new(vel.X, 0, vel.Z).Magnitude
        local spin = hrp.AssemblyAngularVelocity.Magnitude
        local maxHoriz = (hum.WalkSpeed or 16) + VEL_MARGIN

        local flung = false
        if horizSpeed > maxHoriz then flung = true end            -- excess horizontal velocity = fling
        if spin > SPIN_LIMIT then flung = true end                 -- spin-fling
        if lastGood then                                           -- teleport-style yank (moved farther than walk allows)
            local cp, gp = hrp.Position, lastGood.Position
            local hd = (Vector3.new(cp.X,0,cp.Z) - Vector3.new(gp.X,0,gp.Z)).Magnitude
            if hd > maxHoriz * dt + STEP_MARGIN then flung = true end
        end

        if flung then
            pcall(function()
                -- cancel horizontal velocity + ALL spin; keep vertical so jumps/gravity still work
                hrp.AssemblyLinearVelocity  = Vector3.new(0, math.clamp(vel.Y, -120, 60), 0)
                hrp.AssemblyAngularVelocity = Vector3.zero
                -- restore horizontal position to the last legit spot, keep current Y + facing
                if lastGood then
                    local gp = lastGood.Position
                    local _, ry = lastGood:ToOrientation()
                    hrp.CFrame = CFrame.new(gp.X, hrp.Position.Y, gp.Z) * CFrame.Angles(0, ry, 0)
                end
            end)
            pcall(function() stripMovers(char) end)
            State.flingsBlocked = (State.flingsBlocked or 0) + 1
            State.flingStatus = "blocked " .. State.flingsBlocked
        else
            -- legit motion → record this as the new good position
            lastGood = hrp.CFrame
            if State.flingStatus ~= "off" and not tostring(State.flingStatus):match("^blocked") then
                State.flingStatus = "protected"
            end
        end
    end))
end

--===========================================================================--
-- ANTI-WHEELBARROW  (two things, decompiled + LIVE-VERIFIED)
--   1) FRIEND-GATE BYPASS: WheelbarrowController force-unequips your Wheelbarrow on equip unless
--      LocalPlayer:GetAttribute("Friends") > 0. Keep it positive -> you can use the wheelbarrow solo.
--   2) ANTI-GRIEF: when ANOTHER player's wheelbarrow touches you, the FakeSeat system
--      (PropVisualizerController.FakeSeat) sets Humanoid.Sit=true + welds your HRP to a "FakeSeat"-tagged
--      part (SeatWeld, Part1=HRP) and carries you. The game's own escape is JUMPING. So when we detect that
--      SeatWeld we trigger the game's clean unsit (ChangeState Jumping) + destroy the weld + Sit=false.
--===========================================================================--
do
    local RunService = game:GetService("RunService")
    local CS = game:GetService("CollectionService")
    task.spawn(function()                                        -- 1) friend-gate bypass (slow loop is fine)
        while State.alive do
            if State.antiWheelbarrow then
                pcall(function() if (tonumber(LocalPlayer:GetAttribute("Friends")) or 0) <= 0 then LocalPlayer:SetAttribute("Friends", 1) end end)
                if State.wbStatus == "off" or State.wbStatus == nil then State.wbStatus = "armed (solo + anti-grab)" end
            else
                State.wbStatus = "off"
            end
            task.wait(0.5)
        end
    end)
    -- 2) ROBUST anti-grab: escapes ANY forced seating, not just "FakeSeat"-tagged seats.
    -- The wheelbarrow grab forces you into a Seat (CanCollide=false) and carries/flings you.
    -- This game has no seats you'd ever use legitimately, so the moment Humanoid.Sit OR
    -- Humanoid.SeatPart appears, we break every weld holding us and force-stand instantly.
    table.insert(State.conns, RunService.Heartbeat:Connect(function()
        if not State.antiWheelbarrow then return end
        local char = LocalPlayer.Character
        local hum  = char and char:FindFirstChildWhichIsA("Humanoid")
        local hrp  = char and char:FindFirstChild("HumanoidRootPart")
        if not (hum and hrp) then return end

        local seatPart = hum.SeatPart
        if not (hum.Sit or seatPart or hum.PlatformStand) then return end   -- cheap gate: only act when grabbed

        -- 1. destroy the SeatWeld living inside the seat that grabbed us
        if seatPart then
            local w = seatPart:FindFirstChild("SeatWeld")
            if w then pcall(function() w:Destroy() end) end
        end
        -- 2. destroy ANY weld/constraint attaching our HRP to a foreign part (grab welds, fake seats)
        for _, d in ipairs(char:GetDescendants()) do
            if (d:IsA("Weld") or d:IsA("WeldConstraint") or d:IsA("Motor6D")) then
                local p0, p1 = d.Part0, d.Part1
                if (p1 == hrp or p0 == hrp) then
                    -- keep the character's own internal joints; only break ones tying us to a Seat/foreign part
                    local foreign = (p0 and not p0:IsDescendantOf(char)) or (p1 and not p1:IsDescendantOf(char))
                    local toSeat  = (p0 and p0:IsA("Seat")) or (p0 and p0:IsA("VehicleSeat"))
                                 or (p1 and p1:IsA("Seat")) or (p1 and p1:IsA("VehicleSeat"))
                                 or d.Name == "SeatWeld"
                    if foreign or toSeat then pcall(function() d:Destroy() end) end
                end
            end
        end
        -- 3. legacy FakeSeat-tagged escape (kept for that grab variant)
        for _, seat in ipairs(CS:GetTagged("FakeSeat")) do
            local w = seat:FindFirstChild("SeatWeld")
            if w and (w.Part1 == hrp or w.Part0 == hrp) then pcall(function() w:Destroy() end) end
        end
        -- 4. force-stand: clear seat/platformstand flags + trigger the game's clean unsit (jump)
        pcall(function() hum.Sit = false end)
        pcall(function() hum.PlatformStand = false end)
        pcall(function() hum:ChangeState(Enum.HumanoidStateType.Jumping) end)
        pcall(function() hum.Jump = true end)
        State.wbBlocked = (State.wbBlocked or 0) + 1
        State.wbStatus = "escaped grab " .. State.wbBlocked
    end))
end

--===========================================================================--
-- ANTI-SHOVEL — negate being whacked by an ENEMY's shovel. The server-applied shovel hit tags
-- YOUR Character with a "HitHighlight" instance (confirmed in decompiled ShovelController:
-- ShovelFX.Protected -> Instance.new("Highlight", Name="HitHighlight") on the hit player). We
-- watch our own character for that exact tag and, for a short window after each hit, CANCEL the
-- knockback velocity and force you OUT of any ragdoll / stun (PlatformStand / FallingDown).
-- It only reacts to a CONFIRMED hit, so it never fights legitimate sitting / wheelbarrow use, and
-- it works even when Anti-Fling is off. Gated on tpBusy/stealing so it never fights our teleports.
--===========================================================================--
do
    local RunService = game:GetService("RunService")
    local _hitUntil = 0
    local _guard = nil

    local function startGuard()
        if _guard then return end
        _guard = RunService.Heartbeat:Connect(function()
            if os.clock() > _hitUntil then
                if _guard then _guard:Disconnect(); _guard = nil end
                return
            end
            if State.tpBusy or State.stealing or State.flinging then return end
            local char = LocalPlayer.Character
            local hrp  = char and char:FindFirstChild("HumanoidRootPart")
            local hum  = char and char:FindFirstChildWhichIsA("Humanoid")
            if not (hrp and hum) then return end
            -- 1) break ragdoll / stun (shovel knockdown), WITHOUT touching Sit (keep wheelbarrow legit)
            if hum.PlatformStand then pcall(function() hum.PlatformStand = false end) end
            local st = hum:GetState()
            if st == Enum.HumanoidStateType.FallingDown or st == Enum.HumanoidStateType.Ragdoll then
                pcall(function() hum:ChangeState(Enum.HumanoidStateType.GettingUp) end)
            end
            -- 2) cancel knockback velocity (keep downward Y for gravity / allow jumps)
            local v = hrp.AssemblyLinearVelocity
            local horiz = Vector3.new(v.X, 0, v.Z)
            local cap = (hum.WalkSpeed or 16) + 6
            if horiz.Magnitude > cap then
                pcall(function() hrp.AssemblyLinearVelocity = Vector3.new(0, math.min(v.Y, 0), 0) end)
            end
        end)
    end

    local function onShovelHit()
        if not State.antiShovel then return end
        State.shovelBlocked = (State.shovelBlocked or 0) + 1
        State.shovelDefStatus = "blocked ×" .. State.shovelBlocked
        _hitUntil = os.clock() + 0.6   -- counter the knockback/stun for 0.6s (re-hit extends it)
        startGuard()
    end

    local function hookChar(char)
        if not char then return end
        char.ChildAdded:Connect(function(c)
            if c.Name == "HitHighlight" then onShovelHit() end
        end)
    end
    hookChar(LocalPlayer.Character)
    LocalPlayer.CharacterAdded:Connect(hookChar)

    -- idle status so the UI shows armed/off (never overwrites a "blocked ×N" line)
    task.spawn(function()
        while State.alive do
            if State.antiShovel then
                if State.shovelDefStatus == "off" or State.shovelDefStatus == nil then State.shovelDefStatus = "armed" end
            else
                State.shovelDefStatus = "off"
            end
            waitFn(0.5)
        end
    end)
end

--===========================================================================--
-- LOCK POSITION (smart) — anchored while IDLE so other players can't shove your body, and it
--   auto-UNLOCKS the instant YOU try to move (WASD / arrows / joystick / touch), then re-locks ~0.35s
--   after you stop. Live-verified anchoring holds (no anti-cheat). Gated on State.tpBusy so the bot's
--   own teleports still work; released on toggle-off.
--===========================================================================--
do
    local RunService = game:GetService("RunService")
    local UIS = game:GetService("UserInputService")
    local MOVE_KEYS = { Enum.KeyCode.W, Enum.KeyCode.A, Enum.KeyCode.S, Enum.KeyCode.D,
                        Enum.KeyCode.Up, Enum.KeyCode.Down, Enum.KeyCode.Left, Enum.KeyCode.Right, Enum.KeyCode.Space }
    local LOCK_GRACE = 0.35
    local lastMove = 0
    local function wantsMove(hum)
        if hum and hum.MoveDirection.Magnitude > 0.05 then return true end   -- covers touch / gamepad / any input
        if not UIS:GetFocusedTextBox() then                                  -- (don't unlock while typing)
            for _, k in ipairs(MOVE_KEYS) do if UIS:IsKeyDown(k) then return true end end
        end
        return false
    end
    table.insert(State.conns, RunService.Heartbeat:Connect(function()
        if not State.lockPosition then return end
        local char = LocalPlayer.Character
        local hum  = char and char:FindFirstChildWhichIsA("Humanoid")
        local hrp  = char and char:FindFirstChild("HumanoidRootPart")
        if not (hum and hrp) then return end
        if State.tpBusy or State.stealing then            -- a bot teleport/STEAL is active -> RELEASE the lock so it works
            if hrp.Anchored then pcall(function() hrp.Anchored = false end) end
            return
        end
        if wantsMove(hum) then
            lastMove = os.clock()
            if hrp.Anchored then pcall(function() hrp.Anchored = false end) end       -- you want to move -> free
        elseif (os.clock() - lastMove) > LOCK_GRACE and not hrp.Anchored then
            pcall(function() hrp.Anchored = true end)                                  -- idle -> lock (unpushable)
        end
    end))
end

--===========================================================================--
-- CONTROL API
--===========================================================================--
function State.start()  State.running = true  end
function State.stop()   State.running = false end
function State.toggle() State.running = not State.running end
function State.cleanup()
    State.running = false
    State.alive   = false
    for _, c in ipairs(State.conns) do pcall(function() c:Disconnect() end) end
    State.conns = {}
    pcall(function() if State.toggleGui then State.toggleGui:Destroy() end end)
    -- clear the acrylic blur (global Lighting effect), then do the LIBRARY-level
    -- teardown (destroys the ScreenGui + dropdown canvases, not just the window).
    pcall(function() if State.fluent and State.fluent.ToggleAcrylic then State.fluent:ToggleAcrylic(false) end end)
    pcall(function()
        if State.fluent and State.fluent.Destroy then State.fluent:Destroy()
        elseif State.window then State.window:Destroy() end
    end)
end

--===========================================================================--
-- UI  (Fluent library)
--===========================================================================--
local function setFromMulti(v)            -- Fluent multi-dropdown value -> {name=true} (handles dict OR array form)
    local set = {}
    if type(v) == "table" then
        for k, val in pairs(v) do
            if type(k) == "number" and type(val) == "string" then set[val] = true   -- array {"a","b"}
            elseif val == true then set[k] = true end                                -- dict {a=true}
        end
    end
    return set
end

local function setToArray(set)        -- {name=true} -> {"name", ...} for a Fluent dropdown Default
    local t = {}
    for k, v in pairs(set) do if v then t[#t + 1] = k end end
    return t
end

--===========================================================================--
-- AUTO MAIL  — auto-repeat gift one item TYPE to a recipient (derived from MailboxController).
--   Send:   Networking.Mailbox.SendBatch:Fire(userId, {{Category,ItemKey,Count},...}, message)  (<=20/gift)
--   Lookup: Networking.Mailbox.LookupPlayer:Fire(name) -> recipient userId
--   Items:  PlayerStateClient:GetLocalReplica().Data.Inventory[category]. HarvestedFruits/Pets are keyed
--           by unique id (ItemKey=id, Count=1); other categories are name -> count. Status text reports
--           every step so any failure is visible. (Not yet live-verified end-to-end.)
--===========================================================================--
local MAIL_MAX_BATCH = 20
local MAIL_GAP       = 6
local _psc
local function mailInventory()
    if _psc == nil then
        _psc = false
        pcall(function()
            local m = ReplicatedStorage:FindFirstChild("PlayerStateClient", true)
            if m then _psc = require(m) end
        end)
    end
    if not _psc then return nil end
    local rep
    pcall(function() rep = _psc:GetLocalReplica() end)
    if not rep then pcall(function() rep = _psc.GetLocalReplica() end) end
    return rep and rep.Data and rep.Data.Inventory or nil
end
local function mailTypeName(entry, key)
    if type(entry) == "table" then
        return entry.Fruit or entry.FruitName or entry.Name or entry.PetType or entry.Pet
            or entry.Type or entry.ItemName or entry.DisplayName or tostring(key)
    end
    return tostring(key)
end
-- sendable item TYPES grouped: returns labels[] + map[label] = {cat, typeName, count}
local function mailItemLabels()
    local inv = mailInventory()
    local groups = {}
    if type(inv) == "table" then
        for cat, items in pairs(inv) do
            if type(items) == "table" then
                for key, entry in pairs(items) do
                    if type(entry) == "table" and entry.Equipped == true then continue end   -- can't gift an equipped item
                    local stackable = type(entry) == "number"
                    local tn  = stackable and tostring(key) or mailTypeName(entry, key)
                    local add = stackable and entry or 1
                    if type(add) ~= "number" then add = 1 end
                    local gk = tostring(cat) .. "\1" .. tostring(tn)
                    local g = groups[gk]
                    if not g then g = { cat = cat, typeName = tn, count = 0 }; groups[gk] = g end
                    g.count = g.count + add
                end
            end
        end
    end
    local list = {}
    for _, g in pairs(groups) do list[#list + 1] = g end
    table.sort(list, function(a, b) return tostring(a.typeName) < tostring(b.typeName) end)
    local labels, map = {}, {}
    for _, g in ipairs(list) do
        local label = ("%s  (%s) x%d"):format(tostring(g.typeName), tostring(g.cat), g.count)
        labels[#labels + 1] = label
        map[label] = g
    end
    return labels, map
end
-- build ONE send batch (<=20 items total) drawing from ALL selected types, keeping `leave` of EACH type
local function mailGatherMulti(picks, leave)
    local inv = mailInventory(); if type(inv) ~= "table" then return nil end
    leave = tonumber(leave) or 0
    local out, budget = {}, MAIL_MAX_BATCH
    for _, p in ipairs(picks or {}) do
        if budget <= 0 then break end
        local items = inv[p.cat]
        if type(items) == "table" then
            local avail = 0
            for key, entry in pairs(items) do
                if type(entry) == "number" then
                    if tostring(key) == p.typeName then avail = avail + entry end
                elseif entry.Equipped ~= true and mailTypeName(entry, key) == p.typeName then
                    avail = avail + 1
                end
            end
            local canSend = math.min(math.max(0, avail - leave), budget)
            for key, entry in pairs(items) do
                if canSend <= 0 then break end
                if type(entry) == "number" then
                    if tostring(key) == p.typeName then
                        local c = math.min(entry, canSend)
                        if c > 0 then out[#out + 1] = { Category = p.cat, ItemKey = key, Count = c }; canSend = canSend - c; budget = budget - c end
                    end
                elseif entry.Equipped ~= true and mailTypeName(entry, key) == p.typeName then
                    out[#out + 1] = { Category = p.cat, ItemKey = key, Count = 1 }; canSend = canSend - 1; budget = budget - 1
                end
            end
        end
    end
    return out
end
local _mailUid, _mailUidName
local function mailResolveUserId(name)
    local r = packet("Mailbox", "LookupPlayer"); if not r then return nil, "no LookupPlayer remote" end
    local ok, res = pcall(function() return r:Fire(name) end)
    if not ok then return nil, "lookup error" end
    if type(res) == "number" then return res end
    if type(res) == "table" then
        local uid = res.userId or res.UserId or res.Id or res.id
        if type(uid) == "number" then return uid end
    end
    return nil, "player not found"
end
local function tryMail(manual)
    if not (manual or State.autoMail) then return end
    local name = tostring(State.mailTo or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then State.mailStatus = "set a recipient name"; return end
    if not State.mailItems or #State.mailItems == 0 then State.mailStatus = "pick item(s) to send"; return end
    if _mailUid == nil or _mailUidName ~= name then
        local uid, err = mailResolveUserId(name)
        if not uid then State.mailStatus = "can't find '" .. name .. "' (" .. tostring(err) .. ")"; return end
        _mailUid, _mailUidName = uid, name
    end
    local items = mailGatherMulti(State.mailItems, State.mailLeave)
    if items == nil then State.mailStatus = "inventory unavailable"; return end
    if #items == 0 then State.mailStatus = ("nothing to send (kept 'leave %d' / none owned)"):format(tonumber(State.mailLeave) or 0); return end
    local send = packet("Mailbox", "SendBatch"); if not send then State.mailStatus = "no SendBatch remote"; return end
    local ok, result, result2 = pcall(function() return send:Fire(_mailUid, items, "") end)
    if not ok then State.mailStatus = "send error"; return end
    if result then
        local n = 0; for _, it in ipairs(items) do n = n + (tonumber(it.Count) or 1) end
        State.mailSent = (State.mailSent or 0) + n
        State.mailStatus = ("sent %d item(s) -> %s (total %d)"):format(n, name, State.mailSent)
    else
        State.mailStatus = "rejected: " .. tostring(result2 or "server said no")
    end
end
State.tryMail = tryMail
task.spawn(function()                                        -- auto-mail loop (auto-repeat)
    while State.alive do
        if State.autoMail then pcall(tryMail); waitFn(MAIL_GAP)
        else waitFn(0.5) end
    end
end)

local function buildGui()
    local ok, Fluent = pcall(function() return loadstring(game:HttpGet(FLUENT_URL))() end)
    if not ok or type(Fluent) ~= "table" then
        warn("[YumaBlox] Fluent UI failed to load (" .. tostring(Fluent) .. "). Engine still runs; "
            .. "use getgenv().AutoHarvestFruit to control it.")
        return
    end
    State.fluent = Fluent
    uiBuilding = true   -- controls fire OnChanged SYNCHRONOUSLY during construction; ignore those (cleared at end)

    local Window = Fluent:CreateWindow({
        Title = "YumaBlox", SubTitle = "Grow a Garden",
        TabWidth = 150, Size = UDim2.fromOffset(500, 404),
        Acrylic = false, Theme = "Dark", MinimizeKey = Enum.KeyCode.RightShift,
    })
    State.window = Window
    -- event-driven stop: if the user closes Fluent's window, halt the engine at once
    pcall(function()
        if State.fluent.GUI then
            State.fluent.GUI.Destroying:Connect(function() State.alive = false end)
        end
    end)

    -- floating draggable circle to open/close the window. Works on MOBILE (no
    -- Right-Shift there): tap = toggle window, drag = reposition the circle.
    do
        local tgui = Instance.new("ScreenGui")
        tgui.Name = "AHF_Toggle"; tgui.ResetOnSpawn = false; tgui.IgnoreGuiInset = true
        tgui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling; tgui.DisplayOrder = 9999
        if protect_gui_fn then pcall(protect_gui_fn, tgui) end
        local parented = gethui_fn and pcall(function() tgui.Parent = gethui_fn() end)
        if not parented then parented = pcall(function() tgui.Parent = game:GetService("CoreGui") end) end
        if not parented then pcall(function() tgui.Parent = LocalPlayer:WaitForChild("PlayerGui") end) end
        State.toggleGui = tgui

        local btn = Instance.new("TextButton")
        btn.Size = UDim2.fromOffset(52, 52)
        btn.Position = UDim2.new(0, 16, 0.4, 0)
        btn.BackgroundColor3 = Color3.fromRGB(250, 204, 21)
        btn.AutoButtonColor = true; btn.BorderSizePixel = 0; btn.Active = true
        btn.Font = Enum.Font.GothamBold; btn.TextSize = 26; btn.TextColor3 = Color3.fromRGB(40, 30, 0)
        btn.Text = "Y"; btn.ZIndex = 10; btn.Parent = tgui
        Instance.new("UICorner", btn).CornerRadius = UDim.new(1, 0)   -- full circle
        local grad = Instance.new("UIGradient", btn); grad.Rotation = 45
        grad.Color = ColorSequence.new(Color3.fromRGB(253, 224, 71), Color3.fromRGB(234, 179, 8))
        local strk = Instance.new("UIStroke", btn); strk.Color = Color3.fromRGB(255, 255, 255); strk.Transparency = 0.45; strk.Thickness = 1.5

        local dragging, moved, sPos, bStart
        btn.InputBegan:Connect(function(i)
            if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
                dragging, moved, sPos, bStart = true, false, i.Position, btn.Position
            end
        end)
        table.insert(State.conns, UserInputService.InputChanged:Connect(function(i)
            if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
                local d = i.Position - sPos
                if d.Magnitude > 6 then moved = true end
                btn.Position = UDim2.new(bStart.X.Scale, bStart.X.Offset + d.X, bStart.Y.Scale, bStart.Y.Offset + d.Y)
            end
        end))
        table.insert(State.conns, UserInputService.InputEnded:Connect(function(i)
            if dragging and (i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch) then
                dragging = false
                if not moved then pcall(function() Window:Minimize() end) end   -- tap = open/close the panel
            end
        end))
    end

    local farm  = Window:AddTab({ Title = "Farm",     Icon = "" })
    local shop  = Window:AddTab({ Title = "Shop",     Icon = "" })
    local stealT = Window:AddTab({ Title = "Steal",   Icon = "" })
    local liveT  = Window:AddTab({ Title = "Live Wild Pets", Icon = "" })
    local snipeT = Window:AddTab({ Title = "Snipe",   Icon = "" })
    local eventT = Window:AddTab({ Title = "Moon Events", Icon = "" })
    local fhT    = Window:AddTab({ Title = "Farm Helpers", Icon = "" })
    local weaT   = Window:AddTab({ Title = "Weather", Icon = "" })
    local mailT = Window:AddTab({ Title = "Mail",     Icon = "" })
    local cfgTab = Window:AddTab({ Title = "Config",  Icon = "" })
    local misc  = Window:AddTab({ Title = "Settings", Icon = "" })
    local mailPar, mailToIn, mailItemDD, mailLeaveS, autoMailT, _miMap   -- forward-declared (Reset, restore + refresh loop reference them)

    ---------------------------------------------------------------- FARM
    local statPar = farm:AddParagraph({ Title = "Live stats", Content = "starting…" })
    local hT = farm:AddToggle("ahf_harvest", { Title = "Auto Harvest", Description = "Harvest ripe fruit on your plot", Default = State.running })
    hT:OnChanged(function(v) if uiBuilding then return end; State.running = v; saveConfig() end)
    local sT = farm:AddToggle("ahf_sell", { Title = "Auto Sell", Description = "Sell fruit via SellAll.", Default = State.autoSell })
    sT:OnChanged(function(v) if uiBuilding then return end; State.autoSell = v; saveConfig() end)
    local sModeDD = farm:AddDropdown("ahf_sellmode", { Title = "Sell mode", Description = "Instant = sell as you go; Full = only at capacity.", Values = { "Instant", "Full" }, Multi = false, Default = State.sellMode or "Instant" })
    sModeDD:OnChanged(function(v) if uiBuilding then return end; State.sellMode = v; saveConfig() end)
    local spdT = farm:AddSlider("ahf_speed", {
        Title = "Harvest Speed",
        Description = "Higher = faster (10 = max).",
        Default = State.harvestSpeed, Min = 1, Max = 10, Rounding = 0,
    })
    spdT:OnChanged(function(v) if uiBuilding then return end; State.harvestSpeed = v; State.fireGap = math.max(0, (10 - v) * 0.025); saveConfig() end)
    local wlimT = farm:AddToggle("ahf_wlim", { Title = "Limit harvest weight", Description = "Skip fruit above the weight set below.", Default = State.limitHarvestKg })
    wlimT:OnChanged(function(v) if uiBuilding then return end; State.limitHarvestKg = v; saveConfig() end)
    local wmaxT = farm:AddSlider("ahf_wmax", {
        Title = "Max harvest weight (kg)",
        Description = "Skip fruit above this weight.",
        Default = State.maxHarvestKg, Min = 1, Max = 1000, Rounding = 0,
    })
    wmaxT:OnChanged(function(v) if uiBuilding then return end; State.maxHarvestKg = v; saveConfig() end)

    ---------------------------------------------------------------- SHOP
    local bT = shop:AddToggle("ahf_buy", { Title = "Auto Buy", Description = "Buy the seeds & gears below whenever they're in stock", Default = State.autoBuy })
    bT:OnChanged(function(v) if uiBuilding then return end; State.autoBuy = v; saveConfig() end)
    local seedDD = shop:AddDropdown("ahf_seeds", { Title = "Seeds to buy", Description = "tick the seeds to auto-buy", Values = shopItems("SeedShop"), Multi = true, Default = setToArray(State.buySeeds) })
    seedDD:OnChanged(function(v) if uiBuilding then return end; State.buySeeds = setFromMulti(v); saveConfig() end)
    shop:AddButton({ Title = "Select ALL seeds", Description = "Tick all seeds.", Callback = function()
        local set = {}; for _, n in ipairs(seedDD.Values or {}) do set[n] = true end   -- Fluent multi takes a {name=true} dict, and Values is the live option list
        State.buySeeds = set; pcall(function() seedDD:SetValue(set) end); saveConfig()
    end })
    local gearDD = shop:AddDropdown("ahf_gears", { Title = "Gears to buy", Description = "tick the gears to auto-buy", Values = shopItems("GearShop"), Multi = true, Default = setToArray(State.buyGears) })
    gearDD:OnChanged(function(v) if uiBuilding then return end; State.buyGears = setFromMulti(v); saveConfig() end)
    shop:AddButton({ Title = "Select ALL gears", Description = "Tick all gears.", Callback = function()
        local set = {}; for _, n in ipairs(gearDD.Values or {}) do set[n] = true end
        State.buyGears = set; pcall(function() gearDD:SetValue(set) end); saveConfig()
    end })
    local petT = shop:AddToggle("ahf_buypets", { Title = "Auto Buy Pets  (teleports!)", Description = "Buy ticked wild pets (teleports).", Default = State.autoBuyPets })
    petT:OnChanged(function(v) if uiBuilding then return end; State.autoBuyPets = v; State.buyArmed = true; saveConfig() end)
    local petOnceT = shop:AddToggle("ahf_buyonce", { Title = "Buy Once Only", Description = "Buy one pet per snipe-join.", Default = State.buyOnce })
    petOnceT:OnChanged(function(v) if uiBuilding then return end; State.buyOnce = v; State.buyArmed = true; saveConfig() end)
    local petDD = shop:AddDropdown("ahf_pets", { Title = "Pets to buy", Description = "Pick pet types to buy.", Values = getPetTypes(), Multi = true, Default = setToArray(State.buyPets) })
    petDD:OnChanged(function(v) if uiBuilding then return end; State.buyPets = setFromMulti(v); saveConfig() end)
    local stockPar = shop:AddParagraph({ Title = "Selected — in stock now", Content = "—" })
    State.ui = { harvest = hT, sell = sT, buy = bT, buypets = petT, seeds = seedDD, gears = gearDD, pets = petDD }

    ---------------------------------------------------------------- MOON EVENTS
    eventT:AddParagraph({ Title = "🌙 Moon Events — Wild Gold & Rainbow Seeds",
        Content = "Teleport-collect rain seeds during Moon events." })
    local cwT = eventT:AddToggle("ahf_collectwild", {
        Title = "Auto-Pickup Wild Seeds  (teleports!)",
        Description = "Grab event seeds as they spawn.",
        Default = State.autoCollectWild,
    })
    cwT:OnChanged(function(v) if uiBuilding then return end; State.autoCollectWild = v; saveConfig() end)
    local evDD = eventT:AddDropdown("ahf_eventseed_list", { Title = "Seeds to pick up", Description = "Only these spawn in the wild.", Values = { "Gold", "Rainbow" }, Multi = true, Default = setToArray(State.eventSeeds) })
    evDD:OnChanged(function(v) if uiBuilding then return end; State.eventSeeds = setFromMulti(v); saveConfig() end)
    local evPar = eventT:AddParagraph({ Title = "Status", Content = "off" })
    State.ui.eventDD = evDD; State.ui.eventPar = evPar; State.ui.collectWild = cwT

    ---------------------------------------------------------------- FARM HELPERS
    fhT:AddParagraph({ Title = "Auto Farm Actions",
        Content = "Water / plant / sprinkle. Needs the matching tools." })
    local wT = fhT:AddToggle("ahf_water", { Title = "Auto Water", Description = "Speed plant growth. Needs a Watering Can.", Default = State.autoWater })
    wT:OnChanged(function(v) if uiBuilding then return end; State.autoWater = v; saveConfig() end)
    local plT = fhT:AddToggle("ahf_plant", { Title = "Auto Plant", Description = "Plant the seeds below.", Default = State.autoPlant })
    plT:OnChanged(function(v) if uiBuilding then return end; State.autoPlant = v; saveConfig() end)
    local plDD = fhT:AddDropdown("ahf_plantseed", { Title = "Seeds to plant", Description = "Rotates through owned seeds; '(x0)' = not owned yet.", Values = allSeedLabels(), Multi = true, Default = plantSeedLabels() })
    plDD:OnChanged(function(v) if uiBuilding then return end; local set = {}; for label in pairs(setFromMulti(v)) do local nm = seedFromLabel(label); if nm and nm ~= "" then set[nm] = true end end; State.plantSeeds = set; saveConfig() end)
    local plSp = fhT:AddSlider("ahf_plantspace", { Title = "Plant spacing (studs)", Description = "Gap for Random mode (min 1.5).", Default = State.plantSpacing, Min = 1.5, Max = 4, Rounding = 1 })
    plSp:OnChanged(function(v) if uiBuilding then return end; State.plantSpacing = v; saveConfig() end)
    local plMode = fhT:AddDropdown("ahf_plantmode", { Title = "Seed placement", Description = "Random / Grid / At my feet.", Values = { "Random", "Grid", "At my feet" }, Multi = false, Default = State.plantMode or "Random" })
    plMode:OnChanged(function(v) if uiBuilding then return end; State.plantMode = v; saveConfig() end)
    fhT:AddButton({ Title = "Pack plants near me (Trowel)", Description = "Pack all plants to a 1-stud grid. Needs Trowel.", Callback = function()
        task.spawn(function() pcall(tryPackPlants) end)
    end })
    fhT:AddButton({ Title = "Refresh owned seeds", Description = "Rescan backpack for seeds.", Callback = function()
        pcall(function() plDD:SetValues(allSeedLabels()) end)
    end })
    local spT = fhT:AddToggle("ahf_sprinkle", { Title = "Auto Place Sprinklers", Description = "Hold 100 size-luck with the fewest sprinklers.", Default = State.autoSprinkle })
    spT:OnChanged(function(v) if uiBuilding then return end; State.autoSprinkle = v; saveConfig() end)
    local spMutT = fhT:AddToggle("ahf_sprinkle_mut", { Title = "Sprinklers: max mutations", Description = "On = stack all tiers for mutations.", Default = State.sprinkleMutations })
    spMutT:OnChanged(function(v) if uiBuilding then return end; State.sprinkleMutations = v; saveConfig() end)

    local cleanDD = fhT:AddDropdown("ahf_cleanup", { Title = "Cleanup: plant types to remove", Description = "Shovel out the ticked types. Needs Shovel.", Values = gardenPlantTypes(), Multi = true, Default = setToArray(State.cleanupTypes) })
    cleanDD:OnChanged(function(v) if uiBuilding then return end; State.cleanupTypes = setFromMulti(v); saveConfig() end)
    fhT:AddButton({ Title = "Cleanup now (shovel selected)", Description = "Dig up the ticked plant types.", Callback = function()
        task.spawn(function() pcall(tryCleanup) end)
    end })

    local fhPar = fhT:AddParagraph({ Title = "Status", Content = "off" })
    State.ui.water = wT; State.ui.plant = plT; State.ui.plantDD = plDD; State.ui.plantSp = plSp
    State.ui.sprinkle = spT; State.ui.sprinkleMut = spMutT; State.ui.farmPar = fhPar
    State.ui.cleanupDD = cleanDD

    ---------------------------------------------------------------- WEATHER
    local weaPar = weaT:AddParagraph({ Title = "Current phase + weather", Content = "reading cycle…" })
    local weaFcPar = weaT:AddParagraph({ Title = "🌙 Moon forecast (deterministic)", Content = "computing…" })
    weaT:AddParagraph({ Title = "How it works",
        Content = "Exact, deterministic Moon countdowns." })
    State.ui.weatherPar = weaPar
    State.ui.weatherFcPar = weaFcPar

    ---------------------------------------------------------------- STEAL
    local stealPar = stealT:AddParagraph({ Title = "Steal status", Content = "…" })
    local stT = stealT:AddToggle("ahf_steal", {
        Title = "Auto Steal  (NIGHT only — teleports!)",
        Description = "Steal fruit at night (teleports).",
        Default = State.autoSteal,
    })
    stT:OnChanged(function(v) if uiBuilding then return end; State.autoSteal = v; saveConfig() end)
    local protectBaseT = stealT:AddToggle("ahf_protectbase", {
        Title = "Protect Base at Night (stand guard)",
        Description = "Guard your base at night (un-stealable).",
        Default = State.protectBase,
    })
    protectBaseT:OnChanged(function(v) if uiBuilding then return end; State.protectBase = v; saveConfig() end)
    local targetPar = stealT:AddParagraph({ Title = "Top targets (value = sell price × size)", Content = "—" })
    stealT:AddButton({ Title = "Steal one now", Description = "Steal one now (night).", Callback = function()
        task.spawn(function() pcall(trySteal) end)
    end })
    State.ui.steal = stT

    ---------------------------------------------------------------- LIVE WILD PETS (scroll list, Join per row)
    local snipePar = liveT:AddParagraph({ Title = "Live wild pets — rarest first", Content = "connecting to coordinator…" })
    local RAR_COLOR = {
        Common = Color3.fromRGB(180, 180, 180), Uncommon = Color3.fromRGB(90, 220, 90), Rare = Color3.fromRGB(80, 150, 255),
        Epic = Color3.fromRGB(190, 90, 255), Legendary = Color3.fromRGB(255, 210, 60), Mythic = Color3.fromRGB(255, 70, 70), Super = Color3.fromRGB(255, 120, 220),
    }
    -- ANTI-LAG: the feed can carry hundreds of pets (mostly Common/Uncommon). Rendering one UI row each
    -- lags the window, so we only show RARE and rarer, capped at LIVE_MAX_ROWS (finds arrive rarest-first).
    local RAR_RANK = { common = 1, uncommon = 2, rare = 3, epic = 4, legendary = 5,
                       mythic = 6, mythical = 6, super = 7, secret = 8, divine = 9, og = 10 }
    local LIVE_MIN_RANK = 3      -- 3 = Rare. Raise to 5 for Legendary+ only.
    local LIVE_MAX_ROWS = 25     -- hard cap on rendered rows -> the list never builds hundreds of frames
    local function visibleFinds(finds)
        local out = {}
        for _, f in ipairs(finds) do
            if (RAR_RANK[tostring(f.rarity):lower()] or 0) >= LIVE_MIN_RANK then
                out[#out + 1] = f
                if #out >= LIVE_MAX_ROWS then break end
            end
        end
        return out
    end
    -- Fluent has no per-row button, so build a real scrolling list inside this tab's container.
    local petScroll
    pcall(function()
        petScroll = Instance.new("ScrollingFrame")
        petScroll.Name = "LiveWildPetsList"
        petScroll.Size = UDim2.new(1, 0, 0, 300)
        petScroll.BackgroundColor3 = Color3.fromRGB(28, 28, 34)
        petScroll.BackgroundTransparency = 0.15
        petScroll.BorderSizePixel = 0
        petScroll.ScrollBarThickness = 5
        petScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
        petScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
        Instance.new("UICorner", petScroll).CornerRadius = UDim.new(0, 6)
        local lay = Instance.new("UIListLayout", petScroll); lay.Padding = UDim.new(0, 4); lay.SortOrder = Enum.SortOrder.LayoutOrder
        local pdg = Instance.new("UIPadding", petScroll)
        pdg.PaddingTop, pdg.PaddingBottom, pdg.PaddingLeft, pdg.PaddingRight = UDim.new(0, 5), UDim.new(0, 5), UDim.new(0, 5), UDim.new(0, 5)
        petScroll.Parent = liveT.Container
    end)
    local rowByKey = {}
    local renderRows   -- forward declaration
    local function mergeAndRender()
        if not renderRows then return end
        local G2 = getgenv and getgenv() or _G
        local allFinds = {}
        for _, f in ipairs(State.snipeFinds or {}) do allFinds[#allFinds+1] = f end
        -- evict BF entries older than 120s before merging (same TTL as snipe poller)
        local BF_TTL2 = 120
        local now3 = os.clock()
        for k, f in pairs(G2.YB_BF_FINDS or {}) do
            if f.insertedAt and (now3 - f.insertedAt) > BF_TTL2 then
                G2.YB_BF_FINDS[k] = nil
            else
                allFinds[#allFinds+1] = f
            end
        end
        local shown = visibleFinds(allFinds)
        pcall(renderRows, shown)
    end
    State.bfRender = mergeAndRender   -- expose so the BigFroot scanner can force an immediate redraw
    renderRows = function(finds)
        if not petScroll then return end
        local seen = {}
        for i, f in ipairs(finds) do
            if f.place then   -- job may be nil for BigFroot entries; still render them
                local key = tostring(f.job or "") .. "|" .. tostring(f.name)
                seen[key] = true
                -- "ago" = how long since this server was last SEEN/reported (replaces the despawn timer).
                -- coordinator entries carry reportedAt (epoch sighting time); local BigFroot entries
                -- carry ageSecs (age when first seen) + insertedAt (os.clock when added).
                local ago
                if f.source == "bigfroot" then
                    ago = (tonumber(f.ageSecs) or 0) + (os.clock() - (tonumber(f.insertedAt) or os.clock()))
                elseif tonumber(f.reportedAt) and tonumber(f.reportedAt) > 0 then
                    ago = os.time() - tonumber(f.reportedAt)
                end
                ago = ago and math.max(0, math.floor(ago)) or nil
                local tm = (not ago and "now")
                    or (ago >= 60 and ("%dm %02ds ago"):format(math.floor(ago / 60), ago % 60))
                    or (ago .. "s ago")
                local rec = rowByKey[key]
                if rec then
                    rec.lbl.Text = ("%s     🕐%s"):format(tostring(f.name), tm)
                    rec.row.LayoutOrder = i
                else
                    local row = Instance.new("Frame")
                    row.Size = UDim2.new(1, 0, 0, 32); row.BackgroundColor3 = Color3.fromRGB(42, 42, 50); row.BorderSizePixel = 0; row.LayoutOrder = i
                    Instance.new("UICorner", row).CornerRadius = UDim.new(0, 5)
                    local dot = Instance.new("Frame"); dot.Size = UDim2.new(0, 10, 0, 10); dot.Position = UDim2.new(0, 8, 0.5, -5)
                    dot.BackgroundColor3 = RAR_COLOR[tostring(f.rarity)] or Color3.fromRGB(150, 150, 150); dot.BorderSizePixel = 0; dot.Parent = row
                    Instance.new("UICorner", dot).CornerRadius = UDim.new(1, 0)
                    local lbl = Instance.new("TextLabel"); lbl.BackgroundTransparency = 1; lbl.Position = UDim2.new(0, 26, 0, 0); lbl.Size = UDim2.new(1, -98, 1, 0)
                    lbl.Font = Enum.Font.GothamMedium; lbl.TextSize = 13; lbl.TextXAlignment = Enum.TextXAlignment.Left; lbl.TextColor3 = Color3.fromRGB(235, 235, 235)
                    lbl.Text = ("%s     🕐%s"):format(tostring(f.name), tm); lbl.Parent = row
                    local btn = Instance.new("TextButton"); btn.Size = UDim2.new(0, 62, 0, 24); btn.Position = UDim2.new(1, -68, 0.5, -12)
                    btn.BackgroundColor3 = Color3.fromRGB(250, 204, 21); btn.Font = Enum.Font.GothamBold; btn.TextSize = 12; btn.TextColor3 = Color3.fromRGB(35, 30, 0)
                    btn.Text = "Join"; btn.AutoButtonColor = true; btn.BorderSizePixel = 0; btn.Parent = row
                    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 5)
                    local job, place, nm = f.job, f.place, f.name
                    btn.MouseButton1Click:Connect(function()
                        pcall(function() Fluent:Notify({ Title = "YumaBlox Snipe", Content = "→ " .. tostring(nm), Duration = 4 }) end)
                        pcall(function() game:GetService("TeleportService"):TeleportToPlaceInstance(place, job, LocalPlayer) end)
                    end)
                    row.Parent = petScroll
                    rowByKey[key] = { row = row, lbl = lbl }
                end
            end
        end
        for key, rec in pairs(rowByKey) do
            if not seen[key] then pcall(function() rec.row:Destroy() end); rowByKey[key] = nil end
        end
    end

    ---------------------------------------------------------------- SNIPE (auto-join config)
    local snAutoT = snipeT:AddToggle("ahf_snipe_auto", {
        Title = "Auto-Snipe  (TELEPORTS you!)",
        Description = "Teleport to the rarest matching pet.",
        Default = State.snipeAuto,
    })
    snAutoT:OnChanged(function(v) if uiBuilding then return end; State.snipeAuto = v; State.snipedJob = nil; saveConfig() end)
    local RARITIES = { "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic", "Super" }
    local snPetDD   -- forward-declared so the rarity dropdown's OnChanged can refresh it
    local snRarDD = snipeT:AddDropdown("ahf_snipe_rar", { Title = "Auto-Snipe rarities", Description = "which rarities trigger an instant join", Values = RARITIES, Multi = true, Default = setToArray(State.snipeRar) })
    snRarDD:OnChanged(function(v) if uiBuilding then return end; State.snipeRar = setFromMulti(v); pcall(function() if snPetDD then snPetDD:SetValues(snipePetCatalog()) end end); saveConfig() end)
    snPetDD = snipeT:AddDropdown("ahf_snipe_pets", { Title = "Pets to snipe (optional)", Description = "Empty = all of the rarities; or pick specific pets.", Values = snipePetCatalog(), Multi = true, Default = setToArray(State.snipePets) })
    snPetDD:OnChanged(function(v) if uiBuilding then return end; State.snipePets = setFromMulti(v); saveConfig() end)
    snipeT:AddButton({ Title = "Refresh pet list", Description = "Update pet list.", Callback = function() pcall(function() if snPetDD then snPetDD:SetValues(snipePetCatalog()) end end) end })
    State.ui.snipeRar = snRarDD; State.ui.snipeAuto = snAutoT; State.ui.snipePets = snPetDD

    local snSkipOldT = snipeT:AddToggle("ahf_snipe_skipold", {
        Title = "Only join freshest servers",
        Description = "Only join brand-new servers.",
        Default = State.snipeSkipOld,
    })
    snSkipOldT:OnChanged(function(v) if uiBuilding then return end; State.snipeSkipOld = v; saveConfig() end)

    local snMaxAgeS = snipeT:AddSlider("ahf_snipe_maxage", {
        Title = "Max server age (seconds)",
        Description = "Max server age, seconds (5 = best).",
        Min = 3, Max = 15, Default = State.snipeMaxAge, Rounding = 0,
    })
    snMaxAgeS:OnChanged(function(v) if uiBuilding then return end; State.snipeMaxAge = v; saveConfig() end)
    State.ui.snipeSkipOld = snSkipOldT; State.ui.snipeMaxAge = snMaxAgeS

    -- local rarity lookup + "is a target pet in THIS server right now?" (so auto-snipe waits to buy)
    local _ybPetData
    local function petRarityLocal(name)
        if _ybPetData == nil then
            local ok, pd = pcall(function()
                local sd = ReplicatedStorage:FindFirstChild("SharedData")
                local m = sd and sd:FindFirstChild("PetData")
                if not m then local sm = ReplicatedStorage:FindFirstChild("SharedModules"); m = sm and sm:FindFirstChild("PetData") end
                return m and require(m)
            end)
            _ybPetData = (ok and type(pd) == "table") and pd or false
        end
        if _ybPetData and type(_ybPetData[name]) == "table" then return _ybPetData[name].Rarity end
    end
    local function hasLocalMatchingPet()
        local map = workspace:FindFirstChild("Map")
        local wps = map and map:FindFirstChild("WildPetSpawns")
        if not wps then return false end
        for _, m in ipairs(wps:GetChildren()) do
            local nm = m:GetAttribute("PetName")
            if nm and snipeMatch(nm, petRarityLocal(nm)) then return true end
        end
        return false
    end

    -- SNIPE feed poller: pull /finds from the coordinator, render rarest-first, auto-snipe matches
    local RAR_ICON = { Common = "⚪", Uncommon = "🟢", Rare = "🔵", Epic = "🟣", Legendary = "🟡", Mythic = "🔴", Super = "🌈" }
    task.spawn(function()
        while State.alive and not (State.fluent and State.fluent.Unloaded) do
            -- LAG FIX: the /finds fetch is a ~430ms BLOCKING round-trip to the coordinator that
            -- intermittently drops frames (measured). The decode is trivial (0.3ms) — it's the HTTP
            -- call itself. So issue ZERO HTTP while just farming; only poll when the data is needed:
            -- auto-sniping, OR the Live Wild Pets tab is open. (&limit=80 trims the payload too.)
            local autoOn  = State.snipeAuto
            local viewing = false
            pcall(function() viewing = liveT.Container.Visible end)
            if not autoOn and not viewing then
                State.snipeBusy = false
                waitFn(3)
            else
            local ok, body = httpGetAsync(SNIPE_BASE .. "/finds?key=" .. SNIPE_KEY .. "&limit=80")
            if ok and type(body) == "string" then
                local okD, data = pcall(function() return HttpService:JSONDecode(body) end)
                if okD and type(data) == "table" and type(data.finds) == "table" then
                    State.snipeFinds = data.finds   -- only update on SUCCESS (keep last known good on failure)
                end
            end
            local finds = State.snipeFinds or {}
            -- merge BigFroot server entries into the live list
            local G2 = getgenv and getgenv() or _G
            local allFinds = {}
            for _, f in ipairs(finds) do allFinds[#allFinds+1] = f end
            -- BigFroot entries: evict any older than 120s (no coordinator TTL, so enforce locally)
            -- This prevents dead/closed servers from showing indefinitely in Live Wild Pets
            local BF_ENTRY_TTL = 120
            local now2 = os.clock()
            for k, f in pairs(G2.YB_BF_FINDS or {}) do
                if f.insertedAt and (now2 - f.insertedAt) > BF_ENTRY_TTL then
                    G2.YB_BF_FINDS[k] = nil   -- evict stale entry
                else
                    allFinds[#allFinds+1] = f
                end
            end
            local shown = visibleFinds(allFinds)
            pcall(renderRows, shown)
            pcall(function() snipePar:SetDesc(#shown > 0 and (("showing %d Rare+ pet(s) (of %d live) — tap Join to snipe"):format(#shown, #allFinds))
                or (#allFinds > 0 and (("%d live pet(s), none Rare+ right now"):format(#allFinds))
                or ("no wild pets right now\n(coordinator: " .. (ok and "reachable" or "UNREACHABLE — check SNIPE_BASE/key") .. ")"))) end)
            if State.snipeAuto then
                local G = getgenv and getgenv() or _G
                G.YB_SNIPE_RECENT  = G.YB_SNIPE_RECENT  or {}
                G.YB_SNIPE_FAILED  = G.YB_SNIPE_FAILED  or {}   -- jobId -> true (private/dead servers)
                local now = os.time()
                -- prune stale failed entries every 5 min so private servers can be retried later
                for jb, t in pairs(G.YB_SNIPE_FAILED) do
                    if type(t) == "number" and (now - t) > 300 then G.YB_SNIPE_FAILED[jb] = nil end
                end
                -- use phHasTargetPet (pet_hunter approach) instead of hasLocalMatchingPet
                -- to avoid the _ybPetData permanent-false bug
                if phHasTargetPet() then
                    State.snipeStatus = "pet here — buy it!"
                    pcall(function() snipePar:SetDesc("✅ a target pet is in THIS server — BUY IT! (auto-snipe is waiting)") end)
                elseif (now - (G.YB_LAST_SNIPE or 0)) < 10 then
                    State.snipeStatus = "arriving…"
                elseif not State.snipeBusy then
                    -- collect ALL matching candidates (not just the first)
                    local candidates = {}
                    -- use allFinds so BigFroot entries (G.YB_BF_FINDS) are also sniped,
                    -- not just coordinator /finds entries
                    for _, f in ipairs(allFinds) do
                        local jb = f.job
                        if f.rarity and snipeMatch(f.name, f.rarity) and jb and f.place
                            and jb ~= game.JobId
                            and not G.YB_SNIPE_FAILED[jb]
                            and not (G.YB_SNIPE_RECENT[jb] and (now - G.YB_SNIPE_RECENT[jb]) < 120) then

                            -- age filter: skip servers older than snipeMaxAge seconds
                            local tooOld = false

                            if f.source == "bigfroot" then
                                -- BigFroot entries: ONLY join "0s ago" servers
                                -- ageSecs=0 → brand-new this scan cycle → spam join
                                -- ageSecs=1+ → already 1s old → competitors there → SKIP
                                -- ageSecs=nil → age unknown → skip to be safe
                                if f.ageSecs == nil or f.ageSecs > 0 then
                                    tooOld = true
                                end
                                -- also skip if we've held it locally for >2s (took too long to process)
                                if f.insertedAt and (os.clock() - f.insertedAt) > 2 then
                                    tooOld = true
                                end
                            elseif State.snipeSkipOld then
                                -- coordinator entry: reportedAt = TRUE sighting time (coordinator stores now-bfAge).
                                -- join if within snipeMaxAge sec (default 5 — absorbs the ~3s pipeline).
                                -- If reportedAt is MISSING (old coordinator not yet restarted), we can't
                                -- verify freshness — ALLOW the join anyway (better to snipe than never).
                                if f.reportedAt and f.reportedAt > 0 then
                                    local serverAge = os.time() - math.floor(f.reportedAt)
                                    if serverAge > (State.snipeMaxAge or 5) then tooOld = true end
                                end
                            end

                            if not tooOld then
                                candidates[#candidates + 1] = f
                            end
                        end
                    end
                    if #candidates > 0 then
                        State.snipeBusy = true
                        task.spawn(function()
                            local TS2  = game:GetService("TeleportService")
                            local HS2  = game:GetService("HttpService")
                            local _req2 = _httpReq or request
                            local retryCt = {}   -- per-jobId retry count within this task
                            -- armReload() is called before EVERY attempt (see per-candidate loop).
                            -- TeleportInitFailed may clear the queue on some executors, so we re-arm
                            -- before each fire to guarantee the queue is always fresh.
                            -- Multiple executions on arrival are SAFE — the re-entry guard at script
                            -- start kills the prior instance (prior.alive=false) so only the last survives.

                            -- notify coordinator a server is dead so it quarantines it for all clients
                            local function reportDone(jb)
                                if SNIPE_BASE == "" or not _req2 then return end
                                task.spawn(function()
                                    pcall(_req2, {
                                        Url     = SNIPE_BASE .. "/done",
                                        Method  = "POST",
                                        Headers = { ["Content-Type"] = "application/json", ["X-PH-Key"] = SNIPE_BOT_KEY },
                                        Body    = HS2:JSONEncode({ bot = "autosnipe", job = jb, reason = "teleport_failed" }),
                                    })
                                end)
                            end

                            local i = 1
                            while i <= #candidates do
                                local f  = candidates[i]
                                local jb = f.job
                                if jb == game.JobId then i += 1; continue end

                                local tpFailed, tpResult = false, nil
                                local conn
                                pcall(function()
                                    conn = TS2.TeleportInitFailed:Connect(function(_, result)
                                        tpFailed = true; tpResult = result
                                    end)
                                end)

                                G.YB_SNIPE_RECENT[jb] = os.time()
                                -- NOTE: G.YB_LAST_SNIPE is set ONLY on confirmed success below,
                                -- NOT here — fixes the false "arriving…" gate after failed attempts.
                                State.snipeStatus = "trying " .. tostring(f.name) .. "…"
                                pcall(function() Fluent:Notify({ Title = "YumaBlox Snipe", Content = "→ " .. tostring(f.rarity) .. " " .. tostring(f.name), Duration = 3 }) end)
                                armReload()   -- re-arm before every attempt in case TeleportInitFailed cleared the queue
                                -- "0s ago" BF servers: spam 4 join requests over ~1s to beat competitors
                                -- regular servers: single attempt
                                if f.source == "bigfroot" and (f.ageSecs or 1) == 0 then
                                    State.snipeStatus = "⚡ SPAM joining " .. tostring(f.name) .. "…"
                                    for _s = 1, 4 do
                                        if tpFailed then break end
                                        pcall(function() TS2:TeleportToPlaceInstance(f.place, jb, LocalPlayer) end)
                                        task.wait(0.25)   -- 4 requests / 1 second
                                    end
                                else
                                    pcall(function() TS2:TeleportToPlaceInstance(f.place, jb, LocalPlayer) end)
                                end

                                -- wait up to 3s for failure signal
                                local t0 = os.clock()
                                repeat task.wait(0.1) until tpFailed or (os.clock() - t0 > 3)
                                if conn then pcall(function() conn:Disconnect() end) end

                                if not tpFailed then
                                    -- SUCCESS — the arrival check runs as a STARTUP TASK in the NEW
                                    -- server (via queue_on_teleport re-execution) using pet_hunter's
                                    -- phWaitReady()+phScanPets() approach. Do NOT check pets here —
                                    -- this coroutine still runs in the OLD server's context.
                                    G.YB_LAST_SNIPE = os.time()
                                    State.snipeStatus = "sniping " .. tostring(f.name)
                                    break
                                end

                                -- ── classify failure ──────────────────────────────────────────
                                local res = tpResult

                                if res == Enum.TeleportResult.GameFull then
                                    -- 772: server full — pet still EXISTS, just no slots.
                                    -- Tell coordinator via /done (reason≠"teleport_failed") so it:
                                    --   • releases the claim (another bot can get a different server)
                                    --   • sets 90s visited cooldown (mark_visited, not mark_dead)
                                    --   • KEEPS the /finds entry so other users still see the pet
                                    task.spawn(function()
                                        if _req2 and SNIPE_BASE ~= "" then
                                            pcall(_req2, {
                                                Url     = SNIPE_BASE .. "/done",
                                                Method  = "POST",
                                                Headers = { ["Content-Type"] = "application/json", ["X-PH-Key"] = SNIPE_BOT_KEY },
                                                Body    = HS2:JSONEncode({ bot = "autosnipe", job = jb, reason = "gameFull" }),
                                            })
                                        end
                                    end)
                                    G.YB_SNIPE_RECENT[jb] = os.time() + 55   -- local 60s block
                                    State.snipeStatus = "full (772) → notified coordinator → next…"
                                    task.wait(0.2)
                                    i += 1

                                elseif res == Enum.TeleportResult.Unauthorized then
                                    -- 773: report to coordinator on FIRST occurrence so ALL other
                                    -- clients immediately stop seeing this server in Live Wild Pets.
                                    -- Still retry locally 2x (transient infra faults clear on retry).
                                    retryCt[jb] = (retryCt[jb] or 0) + 1
                                    if retryCt[jb] == 1 then
                                        -- first 773 → tell coordinator immediately (removes from /finds for everyone)
                                        task.spawn(function()
                                            if not _req2 or SNIPE_BASE == "" then return end
                                            pcall(_req2, {
                                                Url    = SNIPE_BASE .. "/report773",
                                                Method = "POST",
                                                Headers = { ["Content-Type"] = "application/json", ["X-PH-Key"] = SNIPE_BOT_KEY },
                                                Body   = HS2:JSONEncode({
                                                    bot     = "autosnipe",
                                                    job     = jb,
                                                    petName = tostring(f.name or "?"),
                                                    rarity  = tostring(f.rarity or "?"),
                                                    place   = f.place,
                                                }),
                                            })
                                        end)
                                    end
                                    if retryCt[jb] <= 2 then
                                        State.snipeStatus = ("773 → reported + retry %d/2…"):format(retryCt[jb])
                                        task.wait(1.5)
                                        -- do NOT increment i — retry same server
                                    else
                                        -- 3x confirmed — quarantine locally too
                                        G.YB_SNIPE_FAILED[jb] = os.time()
                                        State.snipeStatus = "773 confirmed → skip…"
                                        task.wait(0.3)
                                        i += 1
                                    end

                                elseif res == Enum.TeleportResult.Flooded then
                                    -- rate-limited — wait 15s then retry SAME server once
                                    retryCt[jb] = (retryCt[jb] or 0) + 1
                                    if retryCt[jb] <= 1 then
                                        State.snipeStatus = "flooded → wait 15s…"
                                        task.wait(15)
                                        -- retry same server
                                    else
                                        State.snipeStatus = "still flooded → next poll…"
                                        break   -- stop for this cycle, next poll will retry
                                    end

                                elseif res == Enum.TeleportResult.GameNotFound
                                    or res == Enum.TeleportResult.GameEnded then
                                    -- server dead — quarantine + notify coordinator immediately
                                    G.YB_SNIPE_FAILED[jb] = os.time()
                                    reportDone(jb)
                                    State.snipeStatus = "server dead → next…"
                                    task.wait(0.2)
                                    i += 1

                                elseif res == Enum.TeleportResult.IsTeleporting then
                                    -- already in progress — wait and retry
                                    State.snipeStatus = "already teleporting… waiting"
                                    task.wait(3)
                                    -- retry same server

                                else
                                    -- generic Failure or nil — retry once then skip
                                    retryCt[jb] = (retryCt[jb] or 0) + 1
                                    if retryCt[jb] <= 1 then
                                        State.snipeStatus = "error → retry…"
                                        task.wait(2)
                                    else
                                        State.snipeStatus = "error → next…"
                                        task.wait(0.5)
                                        i += 1
                                    end
                                end
                            end
                            State.snipeBusy = false
                        end)
                    end
                end
            end
            -- fast while sniping (catch fresh servers); medium while watching the tab
            waitFn(autoOn and SNIPE_POLL_FAST or 2.5)
            end   -- close the "sniping OR tab-open" gate
        end
    end)

    ---------------------------------------------------------------- PERFORMANCE
    misc:AddParagraph({ Title = "Performance", Content = "Reduces GPU/CPU load. Wild pet spawns are never hidden." })
    local perfT = misc:AddToggle("ahf_perfmode", {
        Title = "Performance Mode",
        Description = "Disable effects, cap FPS at 30.",
        Default = State.perfMode,
    })
    perfT:OnChanged(function(v) if uiBuilding then return end; State.perfMode = v; pcall(applyPerfMode, v); saveConfig() end)

    local hidePlantsT = misc:AddToggle("ahf_hideplants", {
        Title = "Hide ALL Gardens (plants/fruits/garden)",
        Description = "Hide all gardens (visual only).",
        Default = State.hidePlants,
    })
    hidePlantsT:OnChanged(function(v) if uiBuilding then return end; State.hidePlants = v; pcall(applyHidePlants, v); saveConfig() end)

    local hideAvatarT = misc:AddToggle("ahf_hideavatar", {
        Title = "Hide Avatar Accessories",
        Description = "Hide your accessories.",
        Default = State.hideAvatar,
    })
    hideAvatarT:OnChanged(function(v) if uiBuilding then return end; State.hideAvatar = v; pcall(applyHideAvatar, v); saveConfig() end)

    misc:AddParagraph({ Title = "Fruit info", Content = "Show each fruit's weight (kg) and sell price floating in your garden." })
    local espWT = misc:AddToggle("ahf_espweight", {
        Title = "Show Fruit Weight + Price",
        Description = "Show kg + price over each fruit.",
        Default = State.espWeight,
    })
    espWT:OnChanged(function(v) if uiBuilding then return end; State.espWeight = v; saveConfig() end)

    ---------------------------------------------------------------- SETTINGS
    local afkT = misc:AddToggle("ahf_antiafk", { Title = "Anti-AFK", Description = "Stop idle kick + server-hop.", Default = State.antiAfk })
    afkT:OnChanged(function(v) if uiBuilding then return end; State.antiAfk = v; saveConfig() end)
    local flingT = misc:AddToggle("ahf_antifling", { Title = "Anti-Fling (perfect)", Description = "Block flings (won't fight your movement).", Default = State.antiFling })
    flingT:OnChanged(function(v) if uiBuilding then return end; State.antiFling = v; saveConfig() end)
    local wbT = misc:AddToggle("ahf_antiwb", { Title = "Anti-Wheelbarrow", Description = "Solo wheelbarrow + auto-escape.", Default = State.antiWheelbarrow })
    wbT:OnChanged(function(v) if uiBuilding then return end; State.antiWheelbarrow = v; saveConfig() end)
    local antiShovelT = misc:AddToggle("ahf_antishovel", { Title = "Anti-Shovel (block enemy whacks)", Description = "Block enemy shovel knockback.", Default = State.antiShovel })
    antiShovelT:OnChanged(function(v) if uiBuilding then return end; State.antiShovel = v; saveConfig() end)
    local shovelHitT = misc:AddToggle("ahf_shovelhit", { Title = "Auto-Shovel Hit (whack enemies)", Description = "Whack nearby enemies. Needs a Shovel.", Default = State.autoShovelHit })
    shovelHitT:OnChanged(function(v) if uiBuilding then return end; State.autoShovelHit = v; saveConfig() end)
    local protectT = misc:AddToggle("ahf_protectpets", { Title = "Escort Bought Pets", Description = "Whack thieves chasing your bought pets.", Default = State.autoProtectPets })
    protectT:OnChanged(function(v) if uiBuilding then return end; State.autoProtectPets = v; if v and not State.autoShovelHit then State.autoShovelHit = true; pcall(function() shovelHitT:SetValue(true) end) end; saveConfig() end)
    local lockT = misc:AddToggle("ahf_lockpos", { Title = "Lock Position (anti-push)", Description = "Block pushes while standing still.", Default = State.lockPosition })
    lockT:OnChanged(function(v) if uiBuilding then return end; State.lockPosition = v; if not v then pcall(function() local c = LocalPlayer.Character; local h = c and c:FindFirstChild("HumanoidRootPart"); if h then h.Anchored = false end end) end; saveConfig() end)
    misc:AddButton({ Title = "Refresh shop catalogs", Description = "Re-read the seed, gear & pet lists", Callback = function()
        pcall(function() seedDD:SetValues(shopItems("SeedShop")) end)
        pcall(function() gearDD:SetValues(shopItems("GearShop")) end)
        pcall(function() petDD:SetValues(getPetTypes()) end)
        Fluent:Notify({ Title = "YumaBlox", Content = "Catalogs refreshed.", Duration = 3 })
    end })
    misc:AddButton({ Title = "Reset settings", Description = "Clear ALL toggles & selections back to defaults", Callback = function()
        uiBuilding = true   -- suppress each control's OnChanged save; we write once below
        -- restore EVERY config-backed field to its default
        State.running, State.autoSell, State.autoBuy, State.autoBuyPets, State.autoSteal = false, false, false, false, false   -- Reset = clean slate: ALL automation OFF
        State.protectBase = false
        State.sellMode = "Instant"
        State.limitHarvestKg, State.maxHarvestKg, State.espWeight = false, 50, false
        State.autoMail, State.mailTo, State.mailItems, State.mailLeave, State.mailStatus = false, "", {}, 0, "off"
        State.buyOnce, State.buyArmed = false, true
        State.buySeeds, State.buyGears, State.buyPets = {}, {}, {}
        State.harvestSpeed, State.fireGap = 6, FIRE_INTERVAL
        State.autoCollectWild = false
        State.eventSeeds = { Gold = true, Rainbow = true }
        State.autoWater, State.autoPlant, State.autoSprinkle = false, false, false
        State.plantSeeds, State.plantSpacing, State.plantMode, State.sprinkleMutations = {}, 2, "Random", false
        State.cleanupTypes = {}
        State.snipeAuto, State.snipeRar, State.snipePets = false, { Legendary = true, Mythic = true, Super = true }, {}
        State.antiAfk, State.antiFling, State.antiFlingReset = true, false, false
        State.antiWheelbarrow, State.lockPosition = false, false
        State.antiShovel = false
        State.autoShovelHit = false
        State.autoProtectPets = false
        State.snipeSkipOld, State.snipeMaxAge = true, 5
        State.perfMode, State.hidePlants, State.hideAvatar = false, false, false
        pcall(applyPerfMode, false); pcall(applyHidePlants, false); pcall(applyHideAvatar, false)   -- undo the on-screen effects, not just the flags
        pcall(function() local c = LocalPlayer.Character; local h = c and c:FindFirstChild("HumanoidRootPart"); if h then h.Anchored = false end end)
        -- push every value into its matching UI control (multi-dropdowns take the array form)
        pcall(function() hT:SetValue(false) end);      pcall(function() sT:SetValue(false) end);  pcall(function() sModeDD:SetValue("Instant") end)
        pcall(function() bT:SetValue(false) end);      pcall(function() petT:SetValue(false) end)
        pcall(function() petOnceT:SetValue(false) end)
        pcall(function() stT:SetValue(false) end);     pcall(function() spdT:SetValue(6) end)
        pcall(function() protectBaseT:SetValue(false) end)
        pcall(function() wlimT:SetValue(false) end);   pcall(function() wmaxT:SetValue(50) end);   pcall(function() espWT:SetValue(false) end)
        pcall(function() seedDD:SetValue({}) end);     pcall(function() gearDD:SetValue({}) end);  pcall(function() petDD:SetValue({}) end)
        pcall(function() cwT:SetValue(false) end);     pcall(function() evDD:SetValue(setToArray({ Gold = true, Rainbow = true })) end)
        pcall(function() wT:SetValue(false) end);      pcall(function() plT:SetValue(false) end);   pcall(function() spT:SetValue(false) end)
        pcall(function() plDD:SetValue({}) end)
        pcall(function() if autoMailT then autoMailT:SetValue(false) end end);  pcall(function() if mailLeaveS then mailLeaveS:SetValue(0) end end);  pcall(function() if mailToIn then mailToIn:SetValue("") end end);  pcall(function() if mailItemDD then mailItemDD:SetValue({}) end end)
        pcall(function() plSp:SetValue(2) end);        pcall(function() spMutT:SetValue(false) end);   pcall(function() plMode:SetValue("Random") end)
        pcall(function() cleanDD:SetValue({}) end)
        pcall(function() snAutoT:SetValue(false) end); pcall(function() snRarDD:SetValue(setToArray({ Legendary = true, Mythic = true, Super = true })) end);   pcall(function() if snPetDD then snPetDD:SetValue({}) end end)
        pcall(function() afkT:SetValue(true) end);     pcall(function() flingT:SetValue(false) end)
        pcall(function() wbT:SetValue(false) end);     pcall(function() lockT:SetValue(false) end); pcall(function() shovelHitT:SetValue(false) end); pcall(function() protectT:SetValue(false) end)
        pcall(function() antiShovelT:SetValue(false) end)
        pcall(function() snSkipOldT:SetValue(true) end); pcall(function() snMaxAgeS:SetValue(5) end)
        pcall(function() perfT:SetValue(false) end);   pcall(function() hidePlantsT:SetValue(false) end);   pcall(function() hideAvatarT:SetValue(false) end)
        uiBuilding = false
        saveConfig()
        Fluent:Notify({ Title = "YumaBlox", Content = "All settings reset to defaults.", Duration = 3 })
    end })
    misc:AddButton({ Title = "Unload / Stop", Description = "Stop the bot and close this window", Callback = function() State.cleanup() end })
    misc:AddParagraph({ Title = "Tips", Content = "Settings auto-save.\nRight Shift hides the window.\nSteal works at night only." })

    ---------------------------------------------------------------- MAIL (auto-repeat gift)
    pcall(function()
        mailPar = mailT:AddParagraph({ Title = "Auto Mail status", Content = "off" })
        mailToIn = mailT:AddInput("ahf_mailto", { Title = "Recipient (username)", Default = State.mailTo or "", Placeholder = "exact username", Numeric = false, Finished = true,
            Callback = function(v) if uiBuilding then return end; State.mailTo = tostring(v or ""); _mailUid, _mailUidName = nil, nil; saveConfig() end })
        local labels, map = mailItemLabels(); _miMap = map
        local _selLabels = {}
        for _, lab in ipairs(labels) do local g = map[lab]; if g then for _, p in ipairs(State.mailItems or {}) do if p.cat == g.cat and p.typeName == g.typeName then _selLabels[#_selLabels + 1] = lab; break end end end end
        mailItemDD = mailT:AddDropdown("ahf_mailitem", { Title = "Items to send", Description = "Pick items to mail.", Values = labels, Multi = true, Default = _selLabels })
        mailItemDD:OnChanged(function(v) if uiBuilding then return end; local arr = {}; for lab in pairs(setFromMulti(v)) do local g = _miMap and _miMap[lab]; if g then arr[#arr + 1] = { cat = g.cat, typeName = g.typeName } end end; State.mailItems = arr; saveConfig() end)
        mailLeaveS = mailT:AddSlider("ahf_mailleave", { Title = "Leave at least", Description = "Keep this many.", Default = State.mailLeave or 0, Min = 0, Max = 200, Rounding = 0 })
        mailLeaveS:OnChanged(function(v) if uiBuilding then return end; State.mailLeave = v; saveConfig() end)
        autoMailT = mailT:AddToggle("ahf_automail", { Title = "Auto Mail (repeat send)", Description = "Keep mailing the items to the recipient.", Default = State.autoMail })
        autoMailT:OnChanged(function(v) if uiBuilding then return end; State.autoMail = v; if not v then State.mailStatus = "off" end; saveConfig() end)
        mailT:AddButton({ Title = "Send one batch now", Description = "Send one batch now.", Callback = function() task.spawn(function() pcall(tryMail, true) end) end })
        mailT:AddButton({ Title = "Refresh sendable items", Description = "Re-read your inventory into the picker.", Callback = function() pcall(function() local l, m = mailItemLabels(); _miMap = m; mailItemDD:SetValues(l) end) end })
    end)

    ---------------------------------------------------------------- CONFIG (share settings across accounts)
    cfgTab:AddParagraph({ Title = "Share your settings", Content = "Reuse your settings on another account — Copy here, Load there." })
    local _cfgPaste = ""
    local cfgIn = cfgTab:AddInput("ahf_cfgcode", { Title = "Config code", Default = "", Placeholder = "paste a config code here, then Load", Numeric = false, Finished = false,
        Callback = function(v) _cfgPaste = tostring(v or "") end })
    cfgTab:AddButton({ Title = "📋 Copy my config", Description = "Copy settings to clipboard.", Callback = function()
        local code = exportConfig()
        local setcb = setclipboard or toclipboard or (syn and syn.write_clipboard)
        local copied = setcb and select(1, pcall(setcb, code)) or false
        pcall(function() cfgIn:SetValue(code) end); _cfgPaste = code
        State.notify("Config", copied and ("Copied! ("..#code.." chars) — paste it on your alt + Load.") or "Clipboard unavailable — copy the code from the box above.", 6)
    end })
    cfgTab:AddButton({ Title = "✅ Load config", Description = "Apply a pasted config.", Callback = function()
        local code = _cfgPaste
        if (not code or code == "") then
            local getcb = getclipboard or (syn and syn.get_clipboard)
            if getcb then local ok, c = pcall(getcb); if ok and type(c) == "string" then code = c end end
        end
        if not code or code == "" then State.notify("Config", "Paste a config code into the box first.", 5); return end
        if importConfig(code) then State.notify("Config", "✅ Config loaded + applied to all settings!", 5)
        else State.notify("Config", "❌ That's not a valid config code.", 5) end
    end })
    cfgTab:AddParagraph({ Title = "Presets", Content = "One-click ready-made setups." })
    cfgTab:AddButton({ Title = "⚡ AutoFarm", Description = "Apply the built-in AutoFarm setup instantly.", Callback = function()
        local code = [[{"espWeight":false,"autoSell":true,"snipeSkipOld":true,"harvestSpeed":6,"autoShovelHit":false,"autoPlant":false,"running":true,"autoBuy":false,"sprinkleMutations":false,"antiWheelbarrow":true,"antiFlingReset":false,"buyOnce":false,"lockPosition":true,"mailLeave":0,"autoWater":false,"antiShovel":true,"mailTo":"","sellMode":"Instant","autoSprinkle":false,"antiFling":true,"perfMode":false,"antiAfk":true,"plantSeeds":[],"limitHarvestKg":false,"eventSeeds":{"Rainbow":true,"Gold":true},"autoProtectPets":true,"protectBase":true,"autoSteal":false,"buyGears":[],"mailItems":[{"cat":"Pets","typeName":"Unicorn"}],"maxHarvestKg":50,"hideAvatar":true,"hidePlants":true,"snipeRar":{"Mythic":true,"Legendary":true,"Super":true},"cleanupTypes":[],"autoCollectWild":true,"buyPets":[],"buySeeds":[],"plantMode":"Random","plantSpacing":2,"snipePets":[],"snipeMaxAge":5,"autoMail":false,"autoBuyPets":false,"snipeAuto":false}]]
        if importConfig(code) then State.notify("Config", "✅ AutoFarm config loaded + applied!", 5)
        else State.notify("Config", "❌ AutoFarm config failed to load.", 5) end
    end })

    Window:SelectTab(1)
    Fluent:Notify({ Title = "YumaBlox", Content = "Loaded. Pick seeds/gears in the Shop tab.", Duration = 6 })
    if type(SCRIPT_EXPIRES) == "number" then
        local left = SCRIPT_EXPIRES - os.time()
        local msg = left > 0 and ("Key valid — expires " .. os.date("%Y-%m-%d %H:%M", SCRIPT_EXPIRES)
            .. (" (" .. math.floor(left / 86400) .. "d left)")) or "Key EXPIRED"
        Fluent:Notify({ Title = "YumaBlox Key", Content = msg, Duration = 7 })
    end
    -- force every control to match the CURRENT State. Wrapped as refreshUI() so it can be re-applied
    -- after importing a config code. uiBuilding guards the SetValues so they don't trigger saves.
    local function refreshUI()
        local prev = uiBuilding; uiBuilding = true
    pcall(function() hT:SetValue(State.running) end)
    pcall(function() sT:SetValue(State.autoSell) end)
    pcall(function() sModeDD:SetValue(State.sellMode or "Instant") end)
    pcall(function() spdT:SetValue(State.harvestSpeed) end)
    pcall(function() wlimT:SetValue(State.limitHarvestKg) end)
    pcall(function() wmaxT:SetValue(State.maxHarvestKg) end)
    pcall(function() espWT:SetValue(State.espWeight) end)
    pcall(function() perfT:SetValue(State.perfMode); pcall(applyPerfMode, State.perfMode) end)
    pcall(function() hidePlantsT:SetValue(State.hidePlants); pcall(applyHidePlants, State.hidePlants) end)
    pcall(function() hideAvatarT:SetValue(State.hideAvatar); pcall(applyHideAvatar, State.hideAvatar) end)
    pcall(function() afkT:SetValue(State.antiAfk) end)
    pcall(function() flingT:SetValue(State.antiFling) end)
    pcall(function() wbT:SetValue(State.antiWheelbarrow) end)
    pcall(function() antiShovelT:SetValue(State.antiShovel) end)
    pcall(function() shovelHitT:SetValue(State.autoShovelHit) end)
    pcall(function() protectT:SetValue(State.autoProtectPets) end)
    pcall(function() lockT:SetValue(State.lockPosition) end)
    pcall(function() wT:SetValue(State.autoWater) end)
    pcall(function() plT:SetValue(State.autoPlant) end)
    pcall(function() local labels = allSeedLabels(); plDD:SetValues(labels); local s = {}; for _, label in ipairs(labels) do local nm = seedFromLabel(label); if nm and State.plantSeeds[nm] then s[label] = true end end; plDD:SetValue(s) end)
    pcall(function() plSp:SetValue(State.plantSpacing) end)
    pcall(function() plMode:SetValue(State.plantMode or "Random") end)
    pcall(function() spT:SetValue(State.autoSprinkle) end)
    pcall(function() spMutT:SetValue(State.sprinkleMutations) end)
    pcall(function() cleanDD:SetValue(State.cleanupTypes) end)
    pcall(function() bT:SetValue(State.autoBuy) end)
    pcall(function() petT:SetValue(State.autoBuyPets) end)
    pcall(function() petOnceT:SetValue(State.buyOnce) end)
    pcall(function() stT:SetValue(State.autoSteal) end)
    pcall(function() protectBaseT:SetValue(State.protectBase) end)
    pcall(function() if autoMailT then autoMailT:SetValue(State.autoMail) end end)
    pcall(function() if mailLeaveS then mailLeaveS:SetValue(State.mailLeave) end end)
    pcall(function() if mailToIn then mailToIn:SetValue(State.mailTo or "") end end)
    pcall(function() if mailItemDD and _miMap then local t = {} for label, g in pairs(_miMap) do for _, p in ipairs(State.mailItems or {}) do if p.cat == g.cat and p.typeName == g.typeName then t[label] = true; break end end end mailItemDD:SetValue(t) end end)
    pcall(function() snAutoT:SetValue(State.snipeAuto) end)
    pcall(function() snRarDD:SetValue(State.snipeRar) end)
    pcall(function() if snPetDD then snPetDD:SetValues(snipePetCatalog()); snPetDD:SetValue(State.snipePets) end end)
    pcall(function() snSkipOldT:SetValue(State.snipeSkipOld) end)
    pcall(function() snMaxAgeS:SetValue(State.snipeMaxAge) end)
    pcall(function() seedDD:SetValue(State.buySeeds) end)
    pcall(function() gearDD:SetValue(State.buyGears) end)
    pcall(function() petDD:SetValue(State.buyPets) end)
    pcall(function() cwT:SetValue(State.autoCollectWild) end)
    pcall(function() evDD:SetValue(State.eventSeeds) end)
        uiBuilding = prev
    end
    State.refreshUI = refreshUI
    refreshUI()
    uiBuilding = false   -- everything synced to loaded State -> real user changes now apply + save

    -- AUTO-POPULATE the shop catalogs: the SeedShop/GearShop GUIs aren't built yet when this panel
    -- is created, so the Seeds/Gears dropdowns start EMPTY (and the Pets list can be partial). Wait
    -- for the game to finish populating the shops, then fill the lists + re-apply saved ticks — so
    -- the user never has to press "Refresh shop catalogs".
    task.spawn(function()
        for _ = 1, 45 do                       -- ~45s of load grace
            if not State.alive then return end
            local sI, gI, pI = shopItems("SeedShop"), shopItems("GearShop"), getPetTypes()
            if #sI > 0 and #gI > 0 then
                uiBuilding = true               -- programmatic fills must not trigger OnChanged saves
                pcall(function() seedDD:SetValues(sI) end)
                pcall(function() gearDD:SetValues(gI) end)
                pcall(function() petDD:SetValues(pI) end)
                pcall(function() seedDD:SetValue(State.buySeeds) end)   -- re-tick saved selections
                pcall(function() gearDD:SetValue(State.buyGears) end)
                pcall(function() petDD:SetValue(State.buyPets) end)
                uiBuilding = false
                return
            end
            task.wait(1)
        end
    end)

    ---------------------------------------------------------------- YumaBlox yellow accent
    -- Fluent has no yellow theme, so recolor its Accent (toggles/tabs/sliders/highlights) to gold.
    -- The color tables aren't exposed publicly, so reach them via upvalues: SetTheme -> Creator ->
    -- UpdateTheme -> the Themes table. Fully guarded so a library change can never break the panel.
    pcall(function()
        if typeof(debug) ~= "table" or typeof(debug.getupvalues) ~= "function" then return end
        local YELLOW = Color3.fromRGB(250, 204, 21)
        local function findUp(fn, pred)
            if typeof(fn) ~= "function" then return nil end
            local ok, ups = pcall(debug.getupvalues, fn)
            if not ok then return nil end
            for _, v in pairs(ups) do if pred(v) then return v end end
            return nil
        end
        local Creator = findUp(Fluent.SetTheme, function(v) return type(v) == "table" and type(rawget(v, "UpdateTheme")) == "function" end)
        if not Creator then return end
        local Themes = findUp(Creator.UpdateTheme, function(v) return type(v) == "table" and type(rawget(v, "Dark")) == "table" and rawget(v.Dark, "Accent") ~= nil end)
        if not Themes then return end
        for _, theme in pairs(Themes) do
            if type(theme) == "table" and theme.Accent ~= nil then
                theme.Accent = YELLOW
                if theme.ToggleToggled ~= nil then theme.ToggleToggled = YELLOW end
            end
        end
        Creator.UpdateTheme()                                -- re-apply to every built element
    end)

    ---------------------------------------------------------------- live refresh
    local stealTick = 0
    task.spawn(function()
        while State.alive and not Fluent.Unloaded do
            refreshInventory()
            local fc  = math.floor(tonumber(State.fruitCount) or 0)
            local cap = math.floor(tonumber(State.maxFruit) or 0)
            pcall(function()
                statPar:SetDesc(("Harvested: %d      Sold: %d\nInventory: %d / %d\nRipe now: %d\nStatus: %s")
                    :format(State.harvested, State.sold, fc, cap, State.ripe, State.status))
            end)
            -- steal status (cheap every tick) + top-targets list (throttled — scanning all plots is heavier)
            local night = isNight()
            pcall(function()
                stealPar:SetDesc(("Night now: %s   (stealing only works at night)\nStolen: %d\nStatus: %s")
                    :format(night and "YES 🌙" or "no ☀️", State.stolen, State.stealStatus))
            end)
            pcall(function() if mailPar then mailPar:SetDesc(("Sent: %d\nStatus: %s"):format(State.mailSent or 0, tostring(State.mailStatus or "off"))) end end)
            stealTick = (stealTick + 1) % 4
            if stealTick == 0 then
                local tt = scanStealTargets(8)
                local tl = {}
                for _, t in ipairs(tt) do
                    tl[#tl + 1] = ("%s   val %d   (x%.2f)"):format(t.name, math.floor(t.value + 0.5), tonumber(t.fruit:GetAttribute("SizeMulti")) or 1)
                end
                pcall(function() targetPar:SetDesc(#tl > 0 and table.concat(tl, "\n") or "no stealable fruit found in server") end)
            end
            local lines = {}
            for _, spec in ipairs(SHOPS) do
                for name in pairs(State[spec.sel]) do
                    lines[#lines + 1] = ("%s   x%d"):format(name, shopStock(spec.gui, name))
                end
            end
            if next(State.buyPets) then
                local spawned, wps = {}, wildPetSpawns()
                if wps then for _, m in ipairs(wps:GetChildren()) do local n = m:GetAttribute("PetName"); if n then spawned[n] = (spawned[n] or 0) + 1 end end end
                for name in pairs(State.buyPets) do lines[#lines + 1] = ("%s (pet)   x%d wild"):format(name, spawned[name] or 0) end
            end
            table.sort(lines)
            pcall(function() stockPar:SetDesc(#lines > 0 and table.concat(lines, "\n") or "nothing selected") end)
            if State.ui and State.ui.eventPar then
                -- count Gold/Rainbow seed packs spawned on the map right now (Map.SeedPackSpawn* folders)
                local wildN = 0
                local map = Workspace:FindFirstChild("Map")
                if map and State._wantsPack then
                    for _, fn in ipairs({ "SeedPackSpawnServerLocations", "SeedPackSpawnClient" }) do
                        local f = map:FindFirstChild(fn)
                        if f then for _, m in ipairs(f:GetChildren()) do if State._wantsPack(m) then wildN += 1 end end end
                    end
                end
                local head = State.autoCollectWild and (State.collectStatus or "watching…") or "OFF — toggle on to arm"
                local moon = wildN > 0 and "🌙 EVENT ACTIVE" or "no event right now"
                pcall(function() State.ui.eventPar:SetDesc(("%s\nStatus: %s\nSeeds on map now: %d\nPicked up: %d")
                    :format(moon, head, wildN, State.wildCollected)) end)
            end
            if State.ui and State.ui.farmPar then
                pcall(function() State.ui.farmPar:SetDesc(("Water: %s  (%d)\nPlant: %s  (%d)\nSprinkler: %s  (%d)\nCleanup: %s  (%d)\nPack: %s")
                    :format(State.autoWater and State.waterStatus or "off", State.watered,
                            State.autoPlant and State.plantStatus or "off", State.planted,
                            State.autoSprinkle and State.sprinkleStatus or "off", State.sprinkled,
                            State.cleanupStatus or "off", State.cleaned or 0,
                            State.stackStatus or "off")) end)
            end
            if State.ui and State.ui.weatherPar then
                local function fmt(s) s = math.max(0, math.floor(s or 0)); return s >= 60 and ("%dm %02ds"):format(math.floor(s / 60), s % 60) or (s .. "s") end
                local cur
                if State.weatherNow then
                    cur = ("Phase: %s\nWeather: %s\nPhase ends in: %s"):format(tostring(State.weatherPhase or "?"), tostring(State.weatherStatus), fmt(State.weatherLeft))
                    if State.tonightW and State.weatherPhase ~= "Night" then cur = cur .. ("\nTonight's roll: %s"):format(tostring(State.tonightW)) end
                else cur = "reading cycle…" end
                pcall(function() State.ui.weatherPar:SetDesc(cur) end)
            end
            if State.ui and State.ui.weatherFcPar then
                local function fmt(s) s = math.max(0, math.floor(s or 0)); if s >= 3600 then return ("%dh %dm"):format(math.floor(s / 3600), math.floor((s % 3600) / 60)) end return s >= 60 and ("%dm %02ds"):format(math.floor(s / 60), s % 60) or (s .. "s") end
                local function line(label, secs) if secs == nil then return label .. ": none in next 48h" end if secs <= 0 then return label .. ": ACTIVE NOW 🌙" end return ("%s in %s"):format(label, fmt(secs)) end
                local calib = State.weatherCalib
                local hdr = (calib == "ok" and "✓ verified vs server last night")
                    or (calib and ("⚠ " .. calib .. " — server differs, forecast unreliable"))
                    or "estimate — server has final say (confirms at next night)"
                pcall(function() State.ui.weatherFcPar:SetDesc(hdr .. "\n" .. table.concat({ line("Next Gold Moon", State.nextGold), line("Next Rainbow Moon", State.nextRbow), line("Next Blood Moon", State.nextBlood) }, "\n")) end)
            end
            waitFn(0.5)
        end
        State.alive = false      -- window closed by user -> stop the bot
    end)
end

pcall(buildGui)

print("[YumaBlox] loaded with Fluent UI. getgenv().AutoHarvestFruit.cleanup() to stop.")
