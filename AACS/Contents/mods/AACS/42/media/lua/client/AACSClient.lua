-- AACSClient.lua (Build 42)
-- Client UI + context menu + server command handling.
-- Designed for MP stability: client requests, server validates.

if (not isClient()) and isServer() then
    return
end

local ok = pcall(require, "AACSShared")
if not ok then return end

require "ISUI/ISCollapsableWindow"
require "ISUI/ISScrollingListBox"
require "ISUI/ISButton"
require "ISUI/ISLabel"
require "ISUI/ISComboBox"
require "ISUI/ISTextEntryBox"
require "ISUI/ISToolTip"

require "AACSOverrideShared" -- ensure patches load

AACS = AACS or {}
AACS.UI = AACS.UI or {}
AACS.ClientCache = AACS.ClientCache or { myEntries = {}, allEntries = {}, interactEntries = {} }
AACS.PendingMenu = AACS.PendingMenu or {}

AACS.PlayerLastLoginDB = AACS.PlayerLastLoginDB or nil -- client cache (username -> unix seconds)

local _openUserManager
local _unadoptByUID

local function _t(key, ...)
    local msg = getText(key)
    local args = { ... }
    for i = 1, #args do
        msg = msg:gsub("%%" .. i, tostring(args[i]))
    end
    return msg
end

local function _entryAllowListContains(entry, username)
    if not entry or not entry.AllowList or not username then return false end
    for _, u in ipairs(entry.AllowList) do
        if u == username then return true end
    end
    return false
end

local function _entryModeAllows(owner, username, mode)
    if not owner or not username then return false end
    if mode == AACS.MODE_SAFEHOUSE then
        return AACS.IsSafehouseMember(owner, username)
    elseif mode == AACS.MODE_FACTION then
        return AACS.IsFactionMember(owner, username)
    elseif mode == AACS.MODE_SAFE_OR_FACT then
        return AACS.IsSafehouseMember(owner, username) or AACS.IsFactionMember(owner, username)
    end
    return false
end

local function _canInteractEntry(entry)
    if not entry then return false end
    local p = getPlayer()
    if not p then return false end
    local username = p:getUsername()
    if not username or username == "" then return false end

    if entry.Owner == username then return true end

    local sv = (SandboxVars and SandboxVars.AACS) or {}
    if sv.AdminBypass and AACS.IsAdmin(p) then return true end
    if _entryAllowListContains(entry, username) then return true end

    local pickupMode = tonumber(entry.PickupMode) or AACS.MODE_OWNER_ONLY
    local leashMode = tonumber(entry.LeashMode) or AACS.MODE_OWNER_ONLY
    return _entryModeAllows(entry.Owner, username, pickupMode) or _entryModeAllows(entry.Owner, username, leashMode)
end

local function _upsertEntry(list, entry)
    for i=1,#list do
        if list[i].UID == entry.UID then
            list[i] = entry
            return
        end
    end
    table.insert(list, entry)
end

local function _removeEntry(list, uid)
    for i=#list,1,-1 do
        if list[i].UID == uid then
            table.remove(list, i)
        end
    end
end

local function _notifyLocal(msg, kind)
    local p = getPlayer()
    if not p then return end

    local function tryHalo(colorObj)
        if not HaloTextHelper or not HaloTextHelper.addText then return false end

        -- B42: HaloTextHelper.addText overloads can differ; try safest signatures first.
        if pcall(HaloTextHelper.addText, p, msg) then
            return true
        end

        -- If a ColorRGB is available, try extracting rgb components and call the numeric overload.
        local r, g, b
        if colorObj ~= nil then
            pcall(function() r = colorObj.r; g = colorObj.g; b = colorObj.b end)
            if r == nil then pcall(function() r = colorObj:getR(); g = colorObj:getG(); b = colorObj:getB() end) end
        end
        if r ~= nil and g ~= nil and b ~= nil then
            if pcall(HaloTextHelper.addText, p, msg, r, g, b) then
                return true
            end
        end
        return false
    end

    local color = nil
    if HaloTextHelper then
        if kind == "bad" and HaloTextHelper.getColorRed then color = HaloTextHelper.getColorRed() end
        if kind == "good" and HaloTextHelper.getColorGreen then color = HaloTextHelper.getColorGreen() end
        if (not color) and HaloTextHelper.getColorWhite then color = HaloTextHelper.getColorWhite() end
    end

    if not tryHalo(color) then
        p:Say(msg)
    end
end

function AACS.OnServerCommand(module, command, args)
    if module ~= "AACS" then return end
    args = args or {}

    if command == "notify" then
        -- Prefer translating on the client (MP-safe). Some servers may not have
        -- translation tables loaded or may run in a different language than the
        -- player. If the server sends a translation key + args, localize here.
        if args.key then
            local a = args.args
            if type(a) ~= "table" then a = { a } end
            local okMsg, msg = pcall(function()
                local unpacker = (table and table.unpack) or unpack
                if unpacker then
                    return _t(args.key, unpacker(a or {}))
                end
                return _t(args.key)
            end)
            _notifyLocal(okMsg and msg or (args.msg or ""), args.kind or "info")
        else
            _notifyLocal(args.msg or "", args.kind or "info")
        end
        return
    end
    if command == "forceTeleport" then
        local x = tonumber(args.x)
        local y = tonumber(args.y)
        local z = tonumber(args.z) or 0
        local p = getPlayer()
        if p and x and y then
            if p.teleportTo then
                pcall(function() p:teleportTo(x, y, z) end)
            else
                pcall(function() if p.setX then p:setX(x) end end)
                pcall(function() if p.setY then p:setY(y) end end)
                pcall(function() if p.setZ then p:setZ(z) end end)
            end
        end
        return
    end


    if command == "updateClientLastLogin" then
        local u = args.username
        local ts = tonumber(args.ts)
        if u and ts then
            AACS.PlayerLastLoginDB = AACS.PlayerLastLoginDB or {}
            AACS.PlayerLastLoginDB[u] = ts

            -- Also try to update GlobalModData table if already created on client.
            if ModData and ModData.getOrCreate and AACS and AACS.LASTLOGIN_KEY then
                pcall(function()
                    local db = ModData.getOrCreate(AACS.LASTLOGIN_KEY)
                    db[u] = ts
                end)
            end

            -- Refresh open windows so the label changes immediately.
            if AACS.UI and AACS.UI.UserManager and AACS.UI.UserManager.setDetails and AACS.UI.UserManager.selectedEntry then
                pcall(function() AACS.UI.UserManager:setDetails(AACS.UI.UserManager.selectedEntry) end)
            end
            if AACS.UI and AACS.UI.AdminManager and AACS.UI.AdminManager.setDetails and AACS.UI.AdminManager.selectedEntry then
                pcall(function() AACS.UI.AdminManager:setDetails(AACS.UI.AdminManager.selectedEntry) end)
            end
        end
        return
    end


    if command == "myAnimalsData" then
        AACS.ClientCache.myEntries = args.entries or {}
        if AACS.UI.UserManager and AACS.UI.UserManager.updateFromCache then
            AACS.UI.UserManager:updateFromCache()
        end
        return
    end

    if command == "interactableAnimalsData" then
        AACS.ClientCache.interactEntries = args.entries or {}
        if AACS.UI.UserManager and AACS.UI.UserManager.updateFromCache then
            AACS.UI.UserManager:updateFromCache()
        end
        return
    end

    if command == "allAnimalsData" then
        AACS.ClientCache.allEntries = args.entries or {}
        if AACS.UI.AdminManager and AACS.UI.AdminManager.updateFromCache then
            AACS.UI.AdminManager:updateFromCache()
        end
        return
    end

    if command == "updateEntry" then
        local e = args.entry
        if not e or not e.UID then return end

        local me = ""
        local p = getPlayer()
        if p and p.getUsername then me = tostring(p:getUsername() or "") end
        if me ~= "" and e.Owner == me then
            _upsertEntry(AACS.ClientCache.myEntries, e)
        else
            _removeEntry(AACS.ClientCache.myEntries, e.UID)
        end

        _upsertEntry(AACS.ClientCache.allEntries, e)

        if _canInteractEntry(e) then
            _upsertEntry(AACS.ClientCache.interactEntries, e)
        else
            _removeEntry(AACS.ClientCache.interactEntries, e.UID)
        end

        if AACS.UI.UserManager and AACS.UI.UserManager.updateFromCache then
            AACS.UI.UserManager:updateFromCache()
        end
        if AACS.UI.AdminManager and AACS.UI.AdminManager.updateFromCache then
            AACS.UI.AdminManager:updateFromCache()
        end
        return
    end

    if command == "removeEntry" then
        local uid = args.uid
        if not uid then return end

        AACS.Log("[removeEntry] Removing UID " .. uid .. " from client cache")
        _removeEntry(AACS.ClientCache.myEntries, uid)
        _removeEntry(AACS.ClientCache.allEntries, uid)
        _removeEntry(AACS.ClientCache.interactEntries, uid)

        -- Force immediate UI refresh (simple approach - just update, no close/reopen)
        if AACS.UI.UserManager then
            AACS.Log("[removeEntry] Refreshing UserManager UI")
            if AACS.UI.UserManager.updateFromCache then
                AACS.UI.UserManager:updateFromCache()
            end
        end

        if AACS.UI.AdminManager then
            AACS.Log("[removeEntry] Refreshing AdminManager UI")
            if AACS.UI.AdminManager.updateFromCache then
                AACS.UI.AdminManager:updateFromCache()
            end
        end
        return
    end
    if command == "animalStatus" then
        local rid = tostring(args.requestId or "")
        if rid == "" then return end
        local pending = AACS.PendingMenu and AACS.PendingMenu[rid] or nil
        if not pending then return end
        AACS.PendingMenu[rid] = nil

        -- Update context menu options (works even after menu is shown; it redraws next frame)
        if args.found == false then
            if pending.adoptOpt then
                pending.adoptOpt.notAvailable = true
            end
            return
        end

        if args.claimed then
            local owner = args.owner or "?"
            local menuTarget = (pending.sub or pending.context)
            if menuTarget and pending.ownerOpt == nil then
                local infoOpt = menuTarget:addOption(getText("ContextMenu_AACS_OwnedBy", owner), nil, nil)
                if infoOpt then infoOpt.notAvailable = true end
                pending.ownerOpt = infoOpt
            end
            if pending.adoptOpt then
                pending.adoptOpt.notAvailable = true
            end

            if args.canManage and menuTarget and args.uid then
                menuTarget:addOption(getText("ContextMenu_AACS_ManageThisAnimal"), nil, _openUserManager, nil)
                menuTarget:addOption(getText("ContextMenu_AACS_UnadoptAnimal"), nil, _unadoptByUID, tostring(args.uid))
            end
        else
            if pending.adoptOpt then
                pending.adoptOpt.notAvailable = false
            end
        end
        return
    end

end


local function _calcWindow(xDefault, yDefault, wDefault, hDefault)
    local core = getCore()
    local sw = core and core.getScreenWidth and core:getScreenWidth() or 1280
    local sh = core and core.getScreenHeight and core:getScreenHeight() or 720

    local w = math.min(wDefault, math.floor(sw * 0.88))
    local h = math.min(hDefault, math.floor(sh * 0.82))
    w = math.max(720, w)
    h = math.max(500, h)

    local x = math.max(0, math.floor((sw - w) / 2))
    local y = math.max(0, math.floor((sh - h) / 2))

    return x, y, w, h
end

local function _isAdmin(playerObj)
    return AACS.IsAdmin(playerObj or getPlayer())
end

_openUserManager = function()
    if AACS.UI.UserManager and AACS.UI.UserManager:getIsVisible() then
        AACS.UI.UserManager:bringToTop()
        return
    end
    require "UI/AACSUserManagerMain"
    local x,y,w,h = _calcWindow(200, 100, 900, 750)  -- Increased height from 680 to 750
    AACS.UI.UserManager = AACSUserManagerMain:new(x, y, w, h)
    AACS.UI.UserManager:initialise()
    AACS.UI.UserManager:addToUIManager()
    AACS.UI.UserManager:setVisible(true)

    if isClient() then
        sendClientCommand(getPlayer(), "AACS", "requestInteractableAnimals", {})
        sendClientCommand(getPlayer(), "AACS", "requestMyAnimals", {})
    else
        -- SP: build cache from local registry (best-effort)
        AACS.ClientCache.myEntries = AACS.UI.UserManager:spBuildMyEntries()
        AACS.ClientCache.interactEntries = AACS.UI.UserManager:spBuildInteractEntries()
        AACS.UI.UserManager:updateFromCache()
    end
end

local function _openAdminManager()
    if not _isAdmin(getPlayer()) then return end

    if AACS.UI.AdminManager and AACS.UI.AdminManager:getIsVisible() then
        AACS.UI.AdminManager:bringToTop()
        return
    end
    require "UI/AACSAdminManagerMain"
    local x,y,w,h = _calcWindow(240, 120, 980, 650)
    AACS.UI.AdminManager = AACSAdminManagerMain:new(x, y, w, h)
    AACS.UI.AdminManager:initialise()
    AACS.UI.AdminManager:addToUIManager()
    AACS.UI.AdminManager:setVisible(true)

    if isClient() then
        sendClientCommand(getPlayer(), "AACS", "requestAllAnimals", {})
    else
        AACS.ClientCache.allEntries = AACS.UI.AdminManager:spBuildAllEntries()
        AACS.UI.AdminManager:updateFromCache()
    end
end

local function _getAnimalFromWorldObjects(worldObjects, playerObj)
    -- B42 can pass worldObjects as a Lua table OR a Java ArrayList.
    -- IMPORTANT: do NOT "radius scan" nearby squares; only show adoption when the click actually targets an animal.
    local function scan(o)
        if not o then return nil end

        if instanceof(o, "IsoAnimal") then
            return o
        end

        -- Blacklist known non-animal types before any fallback
        if instanceof(o, "IsoZombie") or instanceof(o, "IsoPlayer") or instanceof(o, "IsoSurvivor") or instanceof(o, "IsoDeadBody") then
            return nil
        end

        if instanceof(o, "IsoMovingObject") then
            if o.isAnimal and type(o.isAnimal) == "function" then
                local ok, res = pcall(function() return o:isAnimal() end)
                if ok and res == true then return o end
            end
        end

        if type(o) == "table" then
            local cand = o.animal or o.obj or o.object or o.mo or o.target
            if cand then
                if instanceof(cand, "IsoAnimal") then return cand end
                if instanceof(cand, "IsoZombie") or instanceof(cand, "IsoPlayer") or instanceof(cand, "IsoSurvivor") then return nil end
                if instanceof(cand, "IsoMovingObject") and cand.isAnimal and type(cand.isAnimal) == "function" then
                    local ok, res = pcall(function() return cand:isAnimal() end)
                    if ok and res == true then return cand end
                end
            end
        end

        return nil
    end

    local function scanList(listObj)
        if not listObj then return nil end
        if type(listObj) == "table" then
            for _, v in ipairs(listObj) do
                local a = scan(v)
                if a then return a end
            end
            return nil
        end

        local okSize, size = pcall(function() return listObj:size() end)
        if okSize and size and size > 0 then
            for i = 0, size - 1 do
                local a = scan(listObj:get(i))
                if a then return a end
            end
        end
        return nil
    end

    -- 1) Strict: what was clicked (worldObjects)
    if worldObjects then
        local a = scanList(worldObjects)
        if a then return a end
    end

    -- 2) Fallback: exact mouse square only (no radius)
    if getMouseSquare then
        local msq = getMouseSquare()
        if msq then
            if msq.getMovingObjects then
                local a = scanList(msq:getMovingObjects())
                if a then return a end
            end
            if msq.getStaticMovingObjects then
                local ok, smov = pcall(function() return msq:getStaticMovingObjects() end)
                if ok and smov then
                    local a = scanList(smov)
                    if a then return a end
                end
            end
        end
    end

    return nil
end


local function _iterList(listObj, fn)
    if not listObj or not fn then return end

    -- Lua table
    if type(listObj) == "table" then
        for _, v in ipairs(listObj) do
            fn(v)
        end
        return
    end

    -- Java ArrayList / similar (B42 often passes these)
    local okSize, size = pcall(function() return listObj:size() end)
    if okSize and size and size > 0 then
        for i = 0, size - 1 do
            local okGet, v = pcall(function() return listObj:get(i) end)
            if okGet then
                fn(v)
            end
        end
        return
    end

    -- Fallback: Iterable collections
    local okIter, it = pcall(function() return listObj:iterator() end)
    if okIter and it then
        while it:hasNext() do
            fn(it:next())
        end
    end
end

local function _getSquareObjectLists(sq)
    local lists = {}
    if not sq then return lists end

    -- moving objects
    if sq.getMovingObjects then
        local ok, mov = pcall(function() return sq:getMovingObjects() end)
        if ok and mov then lists[#lists+1] = mov end
    end

    -- some B42 animals (esp. vanilla) may be in staticMovingObjects depending on state/replication
    if sq.getStaticMovingObjects then
        local ok, smov = pcall(function() return sq:getStaticMovingObjects() end)
        if ok and smov then lists[#lists+1] = smov end
    end

    return lists
end

local function _scanSquareForAnimal(sq)
    if not sq then return nil end
    local lists = _getSquareObjectLists(sq)
    for _, lst in ipairs(lists) do
        local found = nil
        _iterList(lst, function(o)
            if found or (not o) then return end
            if instanceof(o, "IsoAnimal") then
                found = o
                return
            end
            -- Skip known non-animal types
            if instanceof(o, "IsoZombie") or instanceof(o, "IsoPlayer") or instanceof(o, "IsoSurvivor") or instanceof(o, "IsoDeadBody") then return end
            if instanceof(o, "IsoMovingObject") then
                if o.isAnimal and type(o.isAnimal) == "function" then
                    local ok, res = pcall(function() return o:isAnimal() end)
                    if ok and res == true then
                        found = o
                        return
                    end
                end
                -- NOTE: Do NOT use getAnimalType/getDisplayName/getFullName as heuristics!
                -- These methods exist on IsoPlayer, IsoZombie, etc. and cause false positives.
            end
        end)
        if found then return found end
    end
    return nil
end

local function _getAnimalDisplayName(animal)
    if not animal then return nil end
    if animal.getDisplayName then
        local ok, n = pcall(function() return animal:getDisplayName() end)
        if ok and n and n ~= "" then return n end
    end
    if animal.getFullName then
        local ok, n = pcall(function() return animal:getFullName() end)
        if ok and n and n ~= "" then return n end
    end
    if animal.getName then
        local ok, n = pcall(function() return animal:getName() end)
        if ok and n and n ~= "" then return n end
    end
    return nil
end

local function _isAnimalObject(o)
    if not o then return false end

    -- Gold standard: instanceof IsoAnimal is the ONLY reliable check in B42.
    if instanceof(o, "IsoAnimal") then return true end

    -- Blacklist: reject known non-animal types BEFORE any fallback.
    if instanceof(o, "IsoZombie") then return false end
    if instanceof(o, "IsoPlayer") then return false end
    if instanceof(o, "IsoSurvivor") then return false end
    if instanceof(o, "IsoVehicle") then return false end
    if instanceof(o, "IsoDeadBody") then return false end

    -- Secondary: IsoMovingObject with isAnimal() == true (some B42 builds)
    if instanceof(o, "IsoMovingObject") then
        if o.isAnimal and type(o.isAnimal) == "function" then
            local ok, res = pcall(function() return o:isAnimal() end)
            if ok and res == true then return true end
        end
        -- NOTE: Do NOT use getAnimalType/getDisplayName/getFullName as heuristics!
        -- These methods exist on IsoPlayer, IsoZombie, etc. and cause false positives.
    end

    return false
end

local function _getAnimalFromContextMenu(context)
    if not context or not context.options then return nil end

    local function scanAny(v)
        if not v then return nil end
        if _isAnimalObject(v) then return v end

        if type(v) == "table" then
            local cand = v.animal or v.obj or v.object or v.mo or v.target
            if _isAnimalObject(cand) then return cand end
        end

        return nil
    end

    local function scanOption(opt, depth)
        if not opt or depth > 3 then return nil end

        -- Direct fields commonly used by ISContextMenu options
        local a = scanAny(opt.target) or scanAny(opt.animal) or scanAny(opt.obj) or scanAny(opt.object)
        if a then return a end

        -- Params (vanilla commonly stores objects here)
        for i = 1, 10 do
            local key = "param" .. tostring(i)
            local v = opt[key]
            a = scanAny(v)
            if a then return a end
        end

        -- Recurse into submenus if present
        local sub = opt.subMenu or opt.subOption
        if sub and sub.options then
            _iterList(sub.options, function(sopt)
                if not a then
                    a = scanOption(sopt, depth + 1)
                end
            end)
            if a then return a end
        end

        return nil
    end

    local found = nil
    _iterList(context.options, function(opt)
        if not found then
            found = scanOption(opt, 1)
        end
    end)

    return found
end

-- Robust fallback: match the vanilla "animal line" in the context menu (by name)
-- and then find that animal object near the click square. This avoids showing on bare ground.
local function _getClickSquareFromWorldObjects(worldObjects)
    -- Prefer the real click/mouse square.
    -- Some builds include the player in worldObjects; if we pick the first getSquare(),
    -- we end up using the player's square and the adoption option can appear on unrelated clicks.
    if getMouseSquare then
        local msq = getMouseSquare()
        if msq then return msq end
    end

    local sq = nil
    if worldObjects then
        _iterList(worldObjects, function(o)
            if sq then return end
            if o and o.getSquare and o:getSquare() then
                sq = o:getSquare()
            end
        end)
    end
    return sq
end

local function _normName(s)
    if not s then return nil end
    s = tostring(s)
    -- strip simple markup tags (if any)
    s = s:gsub("<[^>]+>", "")
    -- normalize whitespace
    s = s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return s:lower()
end

local function _collectOptionNames(context)
    local names = {}
    if not context or not context.options then return names end
    _iterList(context.options, function(opt)
        if opt and opt.name and opt.name ~= "" then
            names[opt.name] = true
            local nn = _normName(opt.name)
            if nn then names[nn] = true end
        end
    end)
    return names
end

-- Heuristic: filter out common non-animal option names to avoid scanning on bare ground.
local function _looksLikeAnimalName(raw)
    if not raw then return false end
    local nn = _normName(raw)
    if not nn or nn == "" then return false end

    -- stoplist (lowercased)
    local stop = {
        ["walk to"] = true, ["andar até"] = true,
        ["sit on ground"] = true, ["sentar no chão"] = true,
        ["gardening"] = true, ["window"] = true,
        ["debug"] = true,
    }
    if stop[nn] then return false end

    if nn:find("tile report", 1, true) then return false end
    if nn:find("coordinates report", 1, true) then return false end
    if nn:find("animal adoption", 1, true) then return false end
    if nn:find("adoção", 1, true) then return false end
    if nn:find("adopt", 1, true) then return false end
    if nn:find("gerenciar", 1, true) then return false end
    if nn:find("remover", 1, true) then return false end
    if nn:find("dono:", 1, true) then return false end

    -- Reject zombie/player/survivor-related names to prevent false positives
    if nn:find("zombie", 1, true) then return false end
    if nn:find("zumbi", 1, true) then return false end
    if nn:find("crawler", 1, true) then return false end
    if nn:find("shambler", 1, true) then return false end
    if nn:find("survivor", 1, true) then return false end
    if nn:find("sobrevivente", 1, true) then return false end
    if nn:find("player", 1, true) then return false end
    if nn:find("jogador", 1, true) then return false end
    if nn:find("bandit", 1, true) then return false end

    -- Most animal display names have at least 2 words (breed/species + sex, etc.)
    -- but some B42.13.2 variants expose short names (ex: "Cow", "Hen").
    local _, spaces = nn:gsub(" ", "")
    return spaces >= 1 or #nn >= 3
end

local function _menuLooksLikeAnimalSubmenu(context, opt)
    if not context or not opt then return false end

    local subRef = opt.subOption or opt.subMenu
    if not subRef then return false end

    local sub = nil
    if type(subRef) == "table" then
        sub = subRef
    elseif type(subRef) == "number" then
        if context.getSubMenu then
            sub = context:getSubMenu(subRef)
        end
        if (not sub) and context.instanceMap then
            sub = context.instanceMap[subRef]
        end
    end

    if not sub or not sub.options then return false end

    local keywords = {
        "leash", "lasso", "laçar", "lacar", "pegar", "pickup", "pick up",
        "carry", "carregar", "kill", "matar", "slaughter", "abater",
    }

    local found = false
    _iterList(sub.options, function(subOpt)
        if found or not subOpt or not subOpt.name then return end
        local name = _normName(subOpt.name)
        if not name then return end
        for _, kw in ipairs(keywords) do
            if name:find(kw, 1, true) then
                found = true
                return
            end
        end
    end)

    return found
end

local _getMenuAnimalName

-- Robust fallback: match the vanilla "animal line" in the context menu (by (fuzzy) name)
-- and then find that animal object near the click square. This avoids showing on bare ground.
local function _getAnimalByMenuName(context, worldObjects)
    local menuName = _getMenuAnimalName(context)
    if not menuName then return nil end

    local sq = _getClickSquareFromWorldObjects(worldObjects)
    if not sq then return nil end

    local cell = getCell()
    if not cell then return nil end

    local targetNN = _normName(menuName)
    local cx, cy, cz = sq:getX(), sq:getY(), sq:getZ()
    local best, bestScore, bestD2 = nil, -1, 999999
    local R = 2 -- keep strict: only consider animals very close to the click

    local function getObjXY(o)
        if not o then return nil end
        local okX, ox = pcall(function() return o:getX() end)
        local okY, oy = pcall(function() return o:getY() end)
        if okX and okY and ox and oy then return ox, oy end
        if o.getSquare then
            local okS, osq = pcall(function() return o:getSquare() end)
            if okS and osq then return osq:getX(), osq:getY() end
        end
        return nil
    end

    local function scoreName(anName)
        local nn = _normName(anName)
        if not nn or not targetNN then return -1 end
        if nn == targetNN then return 100 end
        if nn:find(targetNN, 1, true) or targetNN:find(nn, 1, true) then return 70 end

        -- token overlap (cheap fuzzy)
        local tok = {}
        for w in targetNN:gmatch("%w+") do tok[w] = (tok[w] or 0) + 1 end
        local common, total = 0, 0
        for w in nn:gmatch("%w+") do
            total = total + 1
            if tok[w] then common = common + 1 end
        end
        if total == 0 then return -1 end
        return math.floor(40 + (common / total) * 30)
    end

    for dx = -R, R do
        for dy = -R, R do
            local s2 = cell:getGridSquare(cx + dx, cy + dy, cz)
            if s2 then
                local lists = _getSquareObjectLists(s2)
                for _, lst in ipairs(lists) do
                    _iterList(lst, function(o)
                        if o and _isAnimalObject(o) then
                            local name = _getAnimalDisplayName(o)
                            local sc = scoreName(name)
                            if sc >= 40 then
                                local ox, oy = getObjXY(o)
                                if ox and oy then
                                    local d2 = (ox - cx) * (ox - cx) + (oy - cy) * (oy - cy)
                                    if (sc > bestScore) or (sc == bestScore and d2 < bestD2) then
                                        bestScore = sc
                                        bestD2 = d2
                                        best = o
                                    end
                                end
                            end
                        end
                    end)
                end
            end
        end
    end

    return best
end



local function _findCachedEntryNear(x, y, z, menuName)
    local nn = _normName(menuName)
    if not nn then return nil end

    local best, bestD2 = nil, 999999
    local function scan(list)
        if type(list) ~= "table" then return end
        for i=1, #list do
            local e = list[i]
            if e and e.LastX and e.LastY and e.LastZ then
                local ex, ey, ez = tonumber(e.LastX) or 0, tonumber(e.LastY) or 0, tonumber(e.LastZ) or 0
                if ez == z then
                    local d2 = (ex - x)*(ex - x) + (ey - y)*(ey - y)
                    if d2 <= 36 then -- 6 tiles
                        local en = _normName(e.AnimalName or "")
                        if en and (en == nn or en:find(nn, 1, true) or nn:find(en, 1, true)) then
                            if d2 < bestD2 then
                                bestD2 = d2
                                best = e
                            end
                        end
                    end
                end
            end
        end
    end

    scan(AACS.ClientCache and AACS.ClientCache.myEntries)
    scan(AACS.ClientCache and AACS.ClientCache.interactEntries)
    scan(AACS.ClientCache and AACS.ClientCache.allEntries)
    return best
end

local function _adoptAtXYZ(_wo, x, y, z)
    x, y, z = tonumber(x), tonumber(y), tonumber(z)
    if not x or not y or not z then return end

    if isClient() then
        sendClientCommand(getPlayer(), "AACS", "adoptAnimal", { x = x, y = y, z = z })
        return
    end

    -- SP: find any animal near and adopt (best effort)
    local cell = getCell()
    if not cell then return end
    local best, bestD2 = nil, 999999
    for dx=-2,2 do
        for dy=-2,2 do
            local sq = cell:getGridSquare(x+dx, y+dy, z)
            if sq then
                local lists = _getSquareObjectLists(sq)
                for _, lst in ipairs(lists) do
                    _iterList(lst, function(o)
                        if o and _isAnimalObject(o) then
                            local ox, oy = o:getX(), o:getY()
                            local d2 = (ox-x)*(ox-x) + (oy-y)*(oy-y)
                            if d2 < bestD2 then
                                bestD2 = d2
                                best = o
                            end
                        end
                    end)
                end
            end
        end
    end
    if not best then
        _notifyLocal(getText("IGUI_AACS_Notify_AnimalNotFoundRetry"), "bad")
        return
    end

    local reg = AACS.SP_GetRegistry()
    local uid = AACS.GenerateUID()
    local entry = AACS.MakeEntry(getPlayer():getUsername(), best, uid)
    reg[uid] = entry
    AACS.SetAnimalClaimModData(best, entry)
    _notifyLocal(_t("IGUI_AACS_Notify_AdoptedCode", uid), "good")
end

_unadoptByUID = function(_wo, uid)
    uid = tostring(uid or "")
    AACS.Log("[_unadoptByUID] Chamada recebida com UID: " .. uid)
    
    if uid == "" then 
        AACS.Log("[_unadoptByUID] UID vazio! Abortando.")
        _notifyLocal(getText("IGUI_AACS_Notify_UidMissing"), "bad")
        return 
    end
    
    if isClient() then
        AACS.Log("[_unadoptByUID] Enviando comando ao servidor: unadoptAnimal com UID: " .. uid)
        sendClientCommand(getPlayer(), "AACS", "unadoptAnimal", { uid = uid })
        _notifyLocal(getText("IGUI_AACS_Notify_UnadoptRequested"), "info")
        return
    end
    
    -- SP: just remove from registry; best effort clear nearby
    AACS.Log("[_unadoptByUID] Modo singleplayer - removendo do registro")
    local reg = AACS.SP_GetRegistry()
    reg[uid] = nil
    _notifyLocal(_t("IGUI_AACS_Notify_UnadoptedCode", uid), "good")
end

local function _adoptAnimal(_wo, animal)
    -- _wo is worldObjects/target from context menu; ignore
    -- Allow legacy calling conventions (in case someone calls _adoptAnimal(animal))
    if (not animal) and _wo and _wo.getSquare then animal = _wo end
    local sq = animal:getSquare()
    if not sq then return end

    if isClient() then
        sendClientCommand(getPlayer(), "AACS", "adoptAnimal", { x = sq:getX(), y = sq:getY(), z = sq:getZ() })
        return
    end

    -- SP: apply directly
    local reg = AACS.SP_GetRegistry()
    local uid = AACS.GenerateUID()
    local entry = AACS.MakeEntry(getPlayer():getUsername(), animal, uid)
    reg[uid] = entry
    AACS.SetAnimalClaimModData(animal, entry)
    _notifyLocal(_t("IGUI_AACS_Notify_AdoptedCode", uid), "good")
end

local function _unadoptAnimal(_wo, animal)
    -- _wo is worldObjects/target from context menu; ignore
    -- Allow legacy calling conventions
    if (not animal) and _wo then
        animal = _wo
    end
    
    -- Debug: verificar o que estamos recebendo
    AACS.Log("[_unadoptAnimal] Chamada recebida")
    AACS.Log("[_unadoptAnimal] animal type: " .. type(animal))
    
    local uid = AACS.GetAnimalUID(animal)
    AACS.Log("[_unadoptAnimal] UID obtido: " .. tostring(uid))
    
    if not uid then 
        _notifyLocal(getText("IGUI_AACS_Notify_AnimalIdentifyFailed"), "bad")
        return 
    end

    if isClient() then
        AACS.Log("[_unadoptAnimal] Enviando comando ao servidor com UID: " .. uid)
        sendClientCommand(getPlayer(), "AACS", "unadoptAnimal", { uid = uid })
        return
    end

    -- SP
    local reg = AACS.SP_GetRegistry()
    reg[uid] = nil
    AACS.ClearAnimalClaimModData(animal)
    _notifyLocal(_t("IGUI_AACS_Notify_UnadoptedCode", uid), "good")
end


-- Extract the vanilla animal parent-line name from the context menu.
-- We ONLY trust options that have a submenu arrow (subMenu/subOption) AND look like an animal name.
-- This mirrors the old stable behaviour, but WITHOUT the dangerous fallback that guessed names from unrelated entries.
_getMenuAnimalName = function(context)
    if not context or not context.options then return nil end

    local best = nil
    _iterList(context.options, function(opt)
        if best then return end
        if not opt or not opt.name or opt.name == "" then return end

        -- Vanilla animal lines have a submenu (arrow). Accept either representation.
        local sub = opt.subOption or opt.subMenu
        if not sub then return end

        local looksLikeAnimal = _looksLikeAnimalName(opt.name) or _menuLooksLikeAnimalSubmenu(context, opt)
        if not looksLikeAnimal then return end

        -- Avoid matching our own menus/categories.
        local n = _normName(opt.name)
        if (n:find("adoção", 1, true) or n:find("adocao", 1, true)) and (n:find("animais", 1, true) or n:find("animals", 1, true) or n:find("animal", 1, true)) then
            return
        end
        if (n:find("adoption", 1, true) and (n:find("animal", 1, true) or n:find("animals", 1, true))) then
            return
        end

        best = opt.name
    end)

    return best
end

-- NEW: Get ALL animal menu names from context (not just the first one)
local function _getAllMenuAnimalNames(context)
    if not context or not context.options then return {} end

    local names = {}
    _iterList(context.options, function(opt)
        if not opt or not opt.name or opt.name == "" then return end

        -- Vanilla animal lines have a submenu (arrow)
        local sub = opt.subOption or opt.subMenu
        if not sub then return end

        local looksLikeAnimal = _looksLikeAnimalName(opt.name)
        if not looksLikeAnimal then
            -- B42.13.2 can render shorter parent names; fallback to submenu-action detection.
            looksLikeAnimal = _menuLooksLikeAnimalSubmenu(context, opt)
        end
        if not looksLikeAnimal then return end

        -- Avoid matching our own menus/categories
        local n = _normName(opt.name)
        if (n:find("adoção", 1, true) or n:find("adocao", 1, true)) and (n:find("animais", 1, true) or n:find("animals", 1, true) or n:find("animal", 1, true)) then
            return
        end
        if (n:find("adoption", 1, true) and (n:find("animal", 1, true) or n:find("animals", 1, true))) then
            return
        end

        table.insert(names, opt.name)
    end)

    return names
end

-- NEW: Get all animals from context, returning a list of { animal, menuName } pairs
local function _getAllAnimalsFromContext(context, worldObjects, playerObj)
    local result = {}

    -- Get all animal menu names from the context
    local menuNames = _getAllMenuAnimalNames(context)

    -- For each menu name, create a proxy animal
    -- We use proxies because we can't reliably match multiple animals from worldObjects
    for _, menuName in ipairs(menuNames) do
        local sq = _getClickSquareFromWorldObjects(worldObjects)
        if sq then
            local animal = { __aacsProxy = true, x = sq:getX(), y = sq:getY(), z = sq:getZ(), menuName = menuName }
            table.insert(result, { animal = animal, menuName = menuName })
        end
    end

    return result
end


local function _getFallbackXYZ(worldObjects)
    if getMouseSquare then
        local sq = getMouseSquare()
        if sq then
            return sq:getX(), sq:getY(), sq:getZ()
        end
    end

    -- fallback: try any world object square
    local function tryObj(o)
        if not o then return nil end
        if o.getSquare then
            local sq = o:getSquare()
            if sq then return sq:getX(), sq:getY(), sq:getZ() end
        end
        if type(o) == "table" then
            local cand = o.object or o.obj or o.mo or o.target
            if cand and cand.getSquare then
                local sq = cand:getSquare()
                if sq then return sq:getX(), sq:getY(), sq:getZ() end
            end
        end
        return nil
    end

    if worldObjects then
        if type(worldObjects) == "table" then
            for _, o in ipairs(worldObjects) do
                local x,y,z = tryObj(o)
                if x then return x,y,z end
            end
        else
            local okSize, size = pcall(function() return worldObjects:size() end)
            if okSize and size and size > 0 then
                for i = 0, size - 1 do
                    local x,y,z = tryObj(worldObjects:get(i))
                    if x then return x,y,z end
                end
            end
        end
    end

    return nil
end

local function _findAnimalNear(x, y, z, radius)
    radius = radius or 2
    local cell = getCell()
    if not cell then return nil end

    local best = nil
    local bestD2 = 999999

    for dx = -radius, radius do
        for dy = -radius, radius do
            local sq = cell:getGridSquare(x + dx, y + dy, z)
            if sq then
                local lists = _getSquareObjectLists(sq)
                for _, lst in ipairs(lists) do
                    _iterList(lst, function(o)
                        if o and _isAnimalObject(o) then
                            local okX, ox = pcall(function() return o:getX() end)
                            local okY, oy = pcall(function() return o:getY() end)
                            if okX and okY then
                                local d2 = (ox - x)*(ox - x) + (oy - y)*(oy - y)
                                if d2 < bestD2 then
                                    bestD2 = d2
                                    best = o
                                end
                            end
                        end
                    end)
                end
            end
        end
    end

    return best
end

local function _adoptAnimalAtXYZ(_wo, x, y, z)
    -- _wo is worldObjects/target from context menu; ignore
    -- Allow legacy calling conventions
    if (not z) and (type(_wo)=="number" or tonumber(_wo)) and (type(x)=="number" or tonumber(x)) and (type(y)=="number" or tonumber(y)) then
        -- called as _adoptAnimalAtXYZ(x,y,z)
        z = y; y = x; x = _wo; _wo = nil
    end
    x = tonumber(x); y = tonumber(y); z = tonumber(z)
    if not x then return end

    if isClient() then
        sendClientCommand(getPlayer(), "AACS", "adoptAnimal", { x = x, y = y, z = z })
        return
    end

    -- SP: find the animal near the click and adopt it
    local a = _findAnimalNear(x, y, z, 3)
    if not a then
        _notifyLocal(getText("IGUI_AACS_Notify_NoAnimalNearClick"), "bad")
        return
    end
    _adoptAnimal(a)
end

local function _pingAnimal(animal)
    local uid = AACS.GetAnimalUID(animal)
    if not uid or not isClient() then return end
    local sq = animal:getSquare()
    if not sq then return end
    sendClientCommand(getPlayer(), "AACS", "pingAnimal", { uid = uid, x = sq:getX(), y = sq:getY(), z = sq:getZ() })
end

function AACS.OnPreFillWorldObjectContextMenu(player, context, worldObjects, test)
    if test then return end
    local playerObj = getSpecificPlayer(player)

    context:addOption(getText("ContextMenu_AACS_OpenManager"), worldObjects, _openUserManager, nil)
    if _isAdmin(playerObj) then
        context:addOption(getText("ContextMenu_AACS_OpenAdminManager"), worldObjects, _openAdminManager, nil)
    end
end

local function _findAnimalMenuOption(context, animal)
    if not context or not context.options or not animal then return nil end
    local display = _getAnimalDisplayName(animal)
    if not display or display == "" then
        display = tostring(animal.getAnimalType and animal:getAnimalType() or "Animal")
    end

    local normalizedDisplay = _normName(display)
    local found = nil

    _iterList(context.options, function(opt)
        if found then return end
        if not opt or not opt.name then return end

        -- Correspondência exata
        if opt.name == display then
            found = opt
            return
        end

        -- Correspondência normalizada
        local normalizedOpt = _normName(opt.name)
        if normalizedOpt and normalizedDisplay and normalizedOpt == normalizedDisplay then
            found = opt
            return
        end

        -- Verifica se a opção tem um submenu (indicador de que é uma linha de animal)
        if (opt.subMenu or opt.subOption) and _looksLikeAnimalName(opt.name) then
            -- Verifica se o nome contém partes similares
            if normalizedOpt and normalizedDisplay then
                if normalizedOpt:find(normalizedDisplay, 1, true) or normalizedDisplay:find(normalizedOpt, 1, true) then
                    found = opt
                    return
                end
            end
        end
    end)
    return found
end

local function _findMenuOptionByName(context, menuName)
    if not context or not context.options or not menuName or menuName == "" then return nil end
    local found = nil
    local normalizedTarget = _normName(menuName)

    _iterList(context.options, function(opt)
        if found then return end
        if not opt or not opt.name then return end

        -- Primeiro tenta correspondência exata
        if opt.name == menuName then
            found = opt
            return
        end

        -- Depois tenta correspondência normalizada (case-insensitive)
        local normalizedOpt = _normName(opt.name)
        if normalizedOpt and normalizedTarget and normalizedOpt == normalizedTarget then
            found = opt
            return
        end
    end)
    return found
end

local function _getOrCreateSubMenu(context, parentOpt)
    if not parentOpt then return nil end
    -- Reaproveita qualquer submenu já criado pelo vanilla:
    -- alguns builds usam subMenu, outros subOption.
    if parentOpt.subMenu then return parentOpt.subMenu end
    if parentOpt.subOption then return parentOpt.subOption end

    -- Se ainda não existir submenu, cria um novo sem
    -- substituir opções já presentes.
    local sub = ISContextMenu:getNew(context)
    context:addSubMenu(parentOpt, sub)
    return sub
end

function AACS.OnFillWorldObjectContextMenu(player, context, worldObjects, test)
    if test then return end
    local playerObj = getSpecificPlayer(player)
    if not playerObj then return end

    AACS.Log("[OnFillMenu] ===== INÍCIO OnFillWorldObjectContextMenu =====")

    -- NEW APPROACH: Process ALL animals in the context menu
    local animals = _getAllAnimalsFromContext(context, worldObjects, playerObj)
    AACS.Log("[OnFillMenu] Número de animais detectados: " .. #animals)

    if #animals == 0 then
        AACS.Log("[OnFillMenu] NENHUM ANIMAL ENCONTRADO - saindo")
        return
    end

    -- Process each animal separately
    for _, animalData in ipairs(animals) do
        local animal = animalData.animal
        local menuName = animalData.menuName

        AACS.Log("[OnFillMenu] ===== Processando animal: " .. tostring(menuName) .. " =====")

        -- Find the submenu for THIS SPECIFIC animal by its menuName
        local animalMenuOpt = _findMenuOptionByName(context, menuName)
        AACS.Log("[OnFillMenu] Procurando submenu por nome: " .. tostring(menuName) .. " - Encontrado: " .. tostring(animalMenuOpt ~= nil))

        if not animalMenuOpt then
            AACS.Log("[OnFillMenu] AVISO: Submenu não encontrado para " .. menuName .. " - pulando este animal")
            goto continue
        end

        -- Get the submenu using context:getSubMenu(number)
        local subRef = animalMenuOpt.subMenu or animalMenuOpt.subOption
        AACS.Log("[OnFillMenu] subRef = " .. tostring(subRef) .. ", tipo: " .. tostring(type(subRef)))

        local sub = nil

        if subRef and type(subRef) == "number" then
            -- subRef é um índice, usa context:getSubMenu(índice)
            if context and context.getSubMenu then
                sub = context:getSubMenu(subRef)
                AACS.Log("[OnFillMenu] Tentou context:getSubMenu(" .. subRef .. "), resultado: " .. tostring(sub ~= nil))
            end

            -- Fallback: tenta instanceMap diretamente
            if not sub and context and context.instanceMap then
                sub = context.instanceMap[subRef]
                AACS.Log("[OnFillMenu] Tentou context.instanceMap[" .. subRef .. "], resultado: " .. tostring(sub ~= nil))
            end
        elseif subRef and type(subRef) == "table" then
            -- subRef já é o submenu
            sub = subRef
            AACS.Log("[OnFillMenu] subRef já era uma tabela, usando diretamente")
        end

        if not sub then
            AACS.Log("[OnFillMenu] AVISO: Submenu não obtido para " .. menuName .. " - pulando este animal")
            goto continue
        end

        AACS.Log("[OnFillMenu] Submenu obtido com sucesso para: " .. menuName)

        local username = playerObj:getUsername()
        local isAdmin = _isAdmin(playerObj)

        _pingAnimal(animal)

        local uid = AACS.GetAnimalUID(animal)
        local owner = AACS.GetAnimalOwner(animal)

        if uid then
            owner = owner or "?"

            AACS.Log("[OnFillMenu] Animal já adotado - UID: " .. uid .. ", Owner: " .. owner)

        -- Always show simple owner line + disabled adopt (red) when already registered
        local infoOpt = sub:addOption(getText("ContextMenu_AACS_OwnedBy", owner), worldObjects, nil)
        if infoOpt then infoOpt.notAvailable = true end

        local adoptOpt = sub:addOption(getText("ContextMenu_AACS_AdoptAnimal"), worldObjects, nil)
        if adoptOpt then adoptOpt.notAvailable = true end

        -- Owner or admin can still manage/remove adoption
        -- Adiciona as opções de gerenciamento no submenu do animal específico
        if owner == username or isAdmin then
            AACS.Log("[OnFillMenu] Adicionando opções de gerenciamento - Username: " .. username .. ", isAdmin: " .. tostring(isAdmin))
            sub:addOption(getText("ContextMenu_AACS_ManageThisAnimal"), worldObjects, _openUserManager, nil)
            sub:addOption(getText("ContextMenu_AACS_UnadoptAnimal"), nil, _unadoptByUID, uid)
        end

        -- [FIX-1] Disable vanilla animal submenu options for unauthorized players.
        -- The vanilla context menu creates a submenu under the animal's display name
        -- with options like "Laçar Animal", "Pegar <name>", "Matar Animal".
        -- We find that submenu and mark restricted options as notAvailable.
        local canPickup = (owner == username) or isAdmin
        local canLeash  = (owner == username) or isAdmin
        local canKill   = (owner == username) or isAdmin
        
        -- Check detailed permissions from modData/cache
        if not canPickup and animal and (not animal.__aacsProxy) then
            canPickup = AACS.CanPlayerDo(playerObj, animal, "pickup")
        end
        if not canLeash and animal and (not animal.__aacsProxy) then
            canLeash = AACS.CanPlayerDo(playerObj, animal, "leash")
        end
        -- Kill requires at least pickup OR owner
        if not canKill and canPickup then canKill = true end

        -- Also check from client cache entries
        if (not canPickup or not canLeash or not canKill) then
            local cacheEntry = nil
            for _, e in ipairs(AACS.ClientCache.myEntries or {}) do
                if e.UID == uid then cacheEntry = e; break end
            end
            if not cacheEntry then
                for _, e in ipairs(AACS.ClientCache.interactEntries or {}) do
                    if e.UID == uid then cacheEntry = e; break end
                end
            end
            if cacheEntry then
                if _canInteractEntry(cacheEntry) then
                    -- Player has some level of interaction permission
                    canPickup = canPickup or _entryModeAllows(cacheEntry.Owner, username, tonumber(cacheEntry.PickupMode) or 1)
                                         or _entryAllowListContains(cacheEntry, username)
                    canLeash  = canLeash  or _entryModeAllows(cacheEntry.Owner, username, tonumber(cacheEntry.LeashMode) or 1)
                                         or _entryAllowListContains(cacheEntry, username)
                    canKill   = canKill or canPickup
                end
            end
        end

        -- Now scan the context menu for the vanilla animal submenu and disable options
        local animalMenuOptPerms = animalMenuOpt or _findAnimalMenuOption(context, animal)
        if animalMenuOptPerms then
            local subPerms = sub or _getOrCreateSubMenu(context, animalMenuOptPerms)
            if subPerms and subPerms.options then
                -- Keywords for each action (EN + PTBR + common variations)
                local leashKeys = { "leash", "lasso", "laçar", "lacar", "rope", "attach", "amarrar", "tie" }
                local pickupKeys = { "pickup", "pick up", "pegar", "carry", "grab", "carregar" }
                local killKeys = { "kill", "slaughter", "matar", "abater" }
                
                local function matchesAny(name, keywords)
                    local n = _normName(name)
                    if not n then return false end
                    for _, kw in ipairs(keywords) do
                        if n:find(kw, 1, true) then return true end
                    end
                    return false
                end
                
                _iterList(subPerms.options, function(opt)
                    if not opt or not opt.name then return end
                    
                    if not canLeash and matchesAny(opt.name, leashKeys) then
                        opt.notAvailable = true
                        opt.toolTip = getText("IGUI_AACS_Notify_Protected", owner, uid)
                        AACS.Log("[OnFillMenu] Disabled leash option: " .. tostring(opt.name))
                    end
                    
                    if not canPickup and matchesAny(opt.name, pickupKeys) then
                        opt.notAvailable = true
                        opt.toolTip = getText("IGUI_AACS_Notify_Protected", owner, uid)
                        AACS.Log("[OnFillMenu] Disabled pickup option: " .. tostring(opt.name))
                    end
                    
                    if not canKill and matchesAny(opt.name, killKeys) then
                        opt.notAvailable = true
                        opt.toolTip = getText("IGUI_AACS_Notify_Protected", owner, uid)
                        AACS.Log("[OnFillMenu] Disabled kill option: " .. tostring(opt.name))
                    end
                end)
            end
        end

        else
            -- No owner/UID => allow adopt (with new requirement checks)
            -- [NEW] Client-side pre-checks for UI feedback (server still validates)
            local canAdopt = true
            local blockReason = nil

            -- Check adoption limit (client hint)
            local maxAnimals = AACS.GetMaxAnimalsPerPlayer()
            if maxAnimals > 0 then
                local currentCount = AACS.CountPlayerAdoptions(username)
                if currentCount >= maxAnimals then
                    canAdopt = false
                    blockReason = _t("IGUI_AACS_Require_Limit", currentCount, maxAnimals)
                end
            end

            -- Check document requirement (client hint)
            if canAdopt and AACS.RequiresDocument() then
                if not AACS.PlayerHasDocument(playerObj) then
                    canAdopt = false
                    blockReason = getText("IGUI_AACS_Require_Document")
                end
            end

            if type(animal) == "table" and animal.__aacsProxy then
                AACS.Log("[OnFillMenu] Adicionando 'Adotar animal' (proxy) em: SUBMENU")
                local adoptOpt = sub:addOption(getText("ContextMenu_AACS_AdoptAnimal"), worldObjects, _adoptAtXYZ, animal.x, animal.y, animal.z)

                if not canAdopt then
                    adoptOpt.notAvailable = true
                    if blockReason then
                        local tooltip = ISToolTip:new()
                        tooltip:initialise()
                        tooltip:setVisible(false)
                        tooltip.description = blockReason
                        adoptOpt.toolTip = tooltip
                    end
                end

                -- Vanilla animals sometimes don't expose the object reference on client.
                if isClient() then
                    local rid = tostring(AACS.Now()) .. tostring(ZombRand(1000, 9999))
                    AACS.PendingMenu[rid] = { context = context, sub = sub, adoptOpt = adoptOpt }
                    sendClientCommand(getPlayer(), "AACS", "queryAnimalAt", {
                        x = animal.x, y = animal.y, z = animal.z,
                        name = animal.menuName,
                        requestId = rid,
                    })
                end
            else
                AACS.Log("[OnFillMenu] Adicionando 'Adotar animal' (direto) em: SUBMENU")
                local adoptOpt = sub:addOption(getText("ContextMenu_AACS_AdoptAnimal"), worldObjects, _adoptAnimal, animal)

                if not canAdopt then
                    adoptOpt.notAvailable = true
                    if blockReason then
                        local tooltip = ISToolTip:new()
                        tooltip:initialise()
                        tooltip:setVisible(false)
                        tooltip.description = blockReason
                        adoptOpt.toolTip = tooltip
                    end
                end
            end
        end

        ::continue::
    end -- end for loop

    AACS.Log("[OnFillMenu] ===== FIM OnFillWorldObjectContextMenu =====")
end

-- Login heartbeat (used by Adoption Expiry on the server)
function AACS._sendLoginPingOnce()
    if not isClient() then
        Events.OnTick.Remove(AACS._sendLoginPingOnce)
        return
    end
    local p = getPlayer()
    if not p then return end

    -- Same approach as AVCS: request GlobalModData snapshot on join,
    -- then ping the server to update this player's last-login/seen time.
    if ModData and ModData.request and AACS and AACS.LASTLOGIN_KEY then
        pcall(function() ModData.request(AACS.LASTLOGIN_KEY) end)
    end

    sendClientCommand(p, "AACS", "updateLastLogin", { reason = "login" })
    Events.OnTick.Remove(AACS._sendLoginPingOnce)
end


-- Receive Global ModData snapshots (AVCS-style)
function AACS.ClientOnReceiveGlobalModData(key, modData)
    if key == (AACS and AACS.LASTLOGIN_KEY or "AACS_PlayerLastLogin") then
        AACS.PlayerLastLoginDB = modData

        -- If a manager window is open, refresh the selected entry so "Expires at" updates.
        if AACS.UI and AACS.UI.UserManager and AACS.UI.UserManager.setDetails and AACS.UI.UserManager.selectedEntry then
            pcall(function() AACS.UI.UserManager:setDetails(AACS.UI.UserManager.selectedEntry) end)
        end
        if AACS.UI and AACS.UI.AdminManager and AACS.UI.AdminManager.setDetails and AACS.UI.AdminManager.selectedEntry then
            pcall(function() AACS.UI.AdminManager:setDetails(AACS.UI.AdminManager.selectedEntry) end)
        end
    end
end

function AACS.ClientEveryHours()
    if not isClient() then return end
    local p = getPlayer()
    if not p then return end
    sendClientCommand(p, "AACS", "updateLastLogin", { reason = "heartbeat" })
end

function AACS.AfterGameStart()
    Events.OnServerCommand.Add(AACS.OnServerCommand)

    -- Avoid duplicate registrations (some hosted setups reload UI scripts)
    if AACS._loginEventsAdded then return end
    AACS._loginEventsAdded = true

    if isClient() then
        Events.OnTick.Add(AACS._sendLoginPingOnce)
        Events.EveryHours.Add(AACS.ClientEveryHours)
    end
end

Events.OnReceiveGlobalModData.Add(AACS.ClientOnReceiveGlobalModData)
Events.OnPreFillWorldObjectContextMenu.Add(AACS.OnPreFillWorldObjectContextMenu)
Events.OnFillWorldObjectContextMenu.Add(AACS.OnFillWorldObjectContextMenu)
Events.OnGameStart.Add(AACS.AfterGameStart)
