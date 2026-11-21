-- Kennel (simple): ONE pet button + an ammo icon.
--   Left click : pet dead -> Revive Pet; no pet -> Call Pet; pet alive and out of combat -> Feed Pet
--   Right click: Revive Pet (name looked up in the spellbook)
--   Ammo icon  : how much of your equipped ammo you have (bags + equipped)
-- Slash: /kennel

local defaults = {
    food = "",
    lowAmmo = 200,
    lowFood = 5,
    autoBuyAmmo = true,
    ammoTarget = 1000,
    locked = false,
    shown = true,
    scale = 1,
    point = "CENTER",
    x = 0,
    y = -200,
}

local SIZE, GAP = 40, 6
local AMMO_SLOT = 0 -- INVSLOT_AMMO; re-checked with SlotId() at login
local QUESTION = "Interface\\Icons\\INV_Misc_QuestionMark"

local bar, petBtn, ammo
local callSpell = "Call Pet" -- replaced by the real name found in the spellbook
local ToggleOptions -- defined with the options window, used earlier by the drag handle
local autoFood   -- { id, name, count, kind } chosen automatically from your bags, or nil
local foodDirty = true -- set when bags/pet change; food is re-picked on the next tick out of combat
local lastFeedTry, lastFeedTime -- food id and time of the last left click, to learn from refusals

local function Print(msg)
    print("|cff33ff99Kennel:|r " .. tostring(msg))
end

-- run fn; if it errors, print the error in chat once instead of failing silently
local reported = {}
local function Try(label, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
        local key = label .. ":" .. tostring(err)
        if not reported[key] then
            reported[key] = true
            Print("|cffff4444error in " .. label .. ":|r " .. tostring(err))
        end
    end
    return ok
end

-- newer clients moved these into C_Item; use whichever exists
local function ItemInfoInstant(item)
    local f = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if not f or not item then return nil end
    return f(item)
end

local function ItemCount(item)
    local f = (C_Item and C_Item.GetItemCount) or GetItemCount
    if not f or not item then return nil end
    return f(item)
end

local function ItemIcon(itemID)
    if not itemID then return nil end
    if C_Item and C_Item.GetItemIconByID then return C_Item.GetItemIconByID(itemID) end
    if GetItemIcon then return GetItemIcon(itemID) end
    return nil
end

-- ask the game for a slot number by name; fall back to the Classic number
local function SlotId(name, default)
    if GetInventorySlotInfo then
        local ok, id = pcall(GetInventorySlotInfo, name)
        if ok and type(id) == "number" then return id end
    end
    return default
end

-- fixed icons used when the game won't give us the spell's own icon
local CALL_ICON   = "Interface\\Icons\\Ability_Hunter_BeastCall"
local REVIVE_ICON = "Interface\\Icons\\Ability_Hunter_BeastSoothe"
local FEED_ICON   = "Interface\\Icons\\Ability_Hunter_BeastTraining"

local function SpellIcon(name)
    local tex
    if name and C_Spell and C_Spell.GetSpellTexture then
        local ok, t = pcall(C_Spell.GetSpellTexture, name)
        if ok then tex = t end
    end
    if not tex and name and GetSpellTexture then
        local ok, t = pcall(GetSpellTexture, name)
        if ok then tex = t end
    end
    if tex == 0 or tex == "" then tex = nil end
    return tex or QUESTION
end

-- set a texture; if it comes out blank, try the next one in the list
local function SetIcon(texture, ...)
    for i = 1, select("#", ...) do
        local t = select(i, ...)
        if t and t ~= QUESTION then
            texture:SetTexture(t)
            if texture:GetTexture() then return t end
        end
    end
    texture:SetTexture(QUESTION)
    return QUESTION
end

-- name of spellbook entry i, using whichever API this client has
local function SpellBookName(i)
    if C_SpellBook and C_SpellBook.GetSpellBookItemName and Enum and Enum.SpellBookSpellBank then
        local ok, name = pcall(C_SpellBook.GetSpellBookItemName, i, Enum.SpellBookSpellBank.Player)
        if ok and name then return name end
    end
    if GetSpellBookItemName then
        local ok, name = pcall(GetSpellBookItemName, i, BOOKTYPE_SPELL or "spell")
        if ok and name then return name end
    end
    if GetSpellName then
        local ok, name = pcall(GetSpellName, i, BOOKTYPE_SPELL or "spell")
        if ok and name then return name end
    end
    return nil
end

-- icon of spellbook entry i
local function SpellBookIcon(i)
    if C_SpellBook and C_SpellBook.GetSpellBookItemTexture and Enum and Enum.SpellBookSpellBank then
        local ok, t = pcall(C_SpellBook.GetSpellBookItemTexture, i, Enum.SpellBookSpellBank.Player)
        if ok and t then return t end
    end
    if GetSpellBookItemTexture then
        local ok, t = pcall(GetSpellBookItemTexture, i, BOOKTYPE_SPELL or "spell")
        if ok and t then return t end
    end
    if GetSpellTexture then
        local ok, t = pcall(GetSpellTexture, i, BOOKTYPE_SPELL or "spell")
        if ok and t then return t end
    end
    return nil
end

-- Forever renames some pet spells after your pet (e.g. "Call Pet" -> "Call <pet's name>").
-- For each pet spell, look in the spellbook for, best first:
--   1. the Classic name ("Call Pet") or "<Word> <name of the last pet we saw>"
--   2. any other spell starting with "<Word> " (but not "<Word> of ...")
local PET_SPELL_WORD = { call = "Call", revive = "Revive", feed = "Feed" }
-- Classic spell IDs. A spell's ID normally stays the same even when its name changes.
local PET_SPELL_ID = { call = 883, revive = 982, feed = 6991 }
-- Call Pet 1-5 (one per stable slot) on the modern engine Forever runs on
local CALL_SLOT_IDS = { 883, 83242, 83243, 83244, 83245 }
local petSpells = {
    call   = { name = "Call Pet" },
    revive = { name = "Revive Pet" },
    feed   = { name = "Feed Pet" },
}

-- spell ID of spellbook entry i, using whichever API this client has
local function SpellBookID(i)
    if C_SpellBook and C_SpellBook.GetSpellBookItemInfo and Enum and Enum.SpellBookSpellBank then
        local ok, info = pcall(C_SpellBook.GetSpellBookItemInfo, i, Enum.SpellBookSpellBank.Player)
        if ok and type(info) == "table" then
            -- a pop-out (flyout) entry has a flyout number, not a spell ID: skip it
            local flyout = Enum.SpellBookItemType and Enum.SpellBookItemType.Flyout
            if flyout and info.itemType == flyout then return nil end
            return info.spellID
        end
    end
    if GetSpellBookItemInfo then
        local ok, kind, id = pcall(GetSpellBookItemInfo, i, BOOKTYPE_SPELL or "spell")
        if ok and id and kind ~= "FLYOUT" then return id end
    end
    return nil
end

-- the name the game shows for a spell ID (Forever may show "Revive <pet name>")
local function SpellNameByID(id)
    if C_Spell and C_Spell.GetSpellName then
        local ok, n = pcall(C_Spell.GetSpellName, id)
        if ok and n then return n end
    end
    if C_Spell and C_Spell.GetSpellInfo then
        local ok, info = pcall(C_Spell.GetSpellInfo, id)
        if ok and type(info) == "table" and info.name then return info.name end
    end
    if GetSpellInfo then
        local ok, n = pcall(GetSpellInfo, id)
        if ok and type(n) == "string" then return n end
    end
    return nil
end

local function KnowsSpell(id)
    -- (not ipairs: it would stop at the first missing function)
    local checks = { IsPlayerSpell or false, IsSpellKnown or false, (C_SpellBook and C_SpellBook.IsSpellKnown) or false }
    for i = 1, 3 do
        local f = checks[i]
        if f then
            local ok, known = pcall(f, id)
            if ok and known then return true end
        end
    end
    return false
end

-- For each pet spell work out what to cast, best first:
--   1. spellbook entry named "<Word> Pet" or "<Word> <pet's name>"
--   2. spellbook entry with the Classic spell ID
--   3. any other spellbook entry starting with "<Word> " (not "<Word> of ...")
--   4. the Classic spell ID, if the game says you know it
--   5. the plain Classic name
-- Clicks that can cast by ID do so (works whatever the spell is called).
local function FindPetSpells()
    local petName = KennelDB.lastPet
    local found = {}
    for i = 1, 400 do
        local name = SpellBookName(i)
        if name then
            local id
            for key, word in pairs(PET_SPELL_WORD) do
                local rank
                if name == word .. " Pet" or (petName and name == word .. " " .. petName) then
                    rank = 1
                else
                    id = id or SpellBookID(i)
                    if id and id == PET_SPELL_ID[key] then
                        rank = 2
                    elseif name:find("^" .. word .. " ") and not name:find("^" .. word .. " of ") then
                        rank = 3
                    end
                end
                if rank and (not found[key] or rank < found[key].rank) then
                    found[key] = { name = name, id = id or SpellBookID(i), icon = SpellBookIcon(i),
                                   rank = rank, found = true, via = "spellbook" }
                end
            end
        end
    end
    for key, word in pairs(PET_SPELL_WORD) do
        local sp = found[key]
        if not sp then
            local id = PET_SPELL_ID[key]
            if KnowsSpell(id) then
                sp = { name = SpellNameByID(id) or (word .. " Pet"), id = id, found = true, via = "spell ID" }
            else
                sp = { name = SpellNameByID(id) or (word .. " Pet"), via = "guess" }
            end
        end
        -- a name from the ID beats a guessed name for macros
        if sp.id and not sp.found then sp.name = SpellNameByID(sp.id) or sp.name end
        -- the standard ID beats one read from the spellbook, if the game says you know it
        if KnowsSpell(PET_SPELL_ID[key]) then
            sp.id, sp.found = PET_SPELL_ID[key], true
            sp.via = (sp.via or "") .. "+id"
        end
        petSpells[key] = sp
    end

    -- Forever's engine has one summon spell per stable slot: Call Pet 1-5.
    -- The spellbook may show them as "Call <pet's name>". Use the slot whose
    -- shown name matches your last pet, else the first slot you know.
    local wanted = petName and ("Call " .. petName)
    local first, match
    for slot, id in ipairs(CALL_SLOT_IDS) do
        if KnowsSpell(id) then
            local n = SpellNameByID(id) or ("Call Pet " .. slot)
            local e = { id = id, name = n, slot = slot, found = true, via = "call slot " .. slot,
                        icon = petSpells.call.icon }
            first = first or e
            if wanted and n == wanted then match = e break end
        end
    end
    if match or first then petSpells.call = match or first end
    callSpell = petSpells.call.name
end

-- remember the pet's name so we can pick the matching "Call <name>" spell
local function RememberPetName()
    if not UnitExists("pet") then return false end
    local name = UnitName("pet")
    if not name or name == "" or name == UNKNOWNOBJECT then return false end
    if KennelDB.lastPet ~= name then
        KennelDB.lastPet = name
        return true
    end
    return false
end

---------------------------------------------------------------------
-- pet button
---------------------------------------------------------------------
-- Left click changes with the pet's state. A secure "state driver" switches it,
-- which also works in combat:
--   dead           -> cast Revive (by spell ID)
--   no pet         -> cast Call (by spell ID), or Revive if Kennel knows the pet died
--   alive          -> macro: Feed Pet, then use the food (out of combat only)
-- Casting by ID matters on Forever: "/cast Call Neko" fails because "Call Neko"
-- is only the name shown for the spell, but its ID always works.
local PET_STATE = "[@pet,dead] dead; [nopet] nopet; alive"

local STATE_SNIPPET = [[
    local revive = self:GetAttribute("kennel-revive")
    if newstate == "dead" or (newstate == "nopet" and self:GetAttribute("kennel-petdead")) then
        self:SetAttribute("type1", "spell")
        self:SetAttribute("spell1", revive)
    elseif newstate == "nopet" then
        self:SetAttribute("type1", "spell")
        self:SetAttribute("spell1", self:GetAttribute("kennel-call"))
    else
        self:SetAttribute("type1", "macro")
    end
]]

local function ApplyMacros()
    if InCombatLockdown() then
        bar.pendingMacros = true
        return
    end
    bar.pendingMacros = false

    FindPetSpells()
    local call = petSpells.call.id or callSpell
    local revive = petSpells.revive.id or petSpells.revive.name
    local food = KennelDB.food or ""

    local feed = "/cast [@pet,exists,nodead,nocombat] " .. petSpells.feed.name
    if food ~= "" then
        feed = feed .. "\n/use [@pet,exists,nodead,nocombat] " .. food      -- your own choice
    elseif autoFood then
        feed = feed .. "\n/use [@pet,exists,nodead,nocombat] item:" .. autoFood.id -- picked from your bags
    end

    petBtn:SetAttribute("kennel-call", call)
    petBtn:SetAttribute("kennel-revive", revive)
    petBtn:SetAttribute("kennel-petdead", KennelDB.petDead and true or nil)
    petBtn:SetAttribute("macrotext1", feed)
    -- right click always revives (by ID when known)
    petBtn:SetAttribute("type2", "spell")
    petBtn:SetAttribute("spell2", revive)

    -- set left click for the state the pet is in right now
    local state = SecureCmdOptionParse and SecureCmdOptionParse(PET_STATE) or "nopet"
    if state == "dead" or (state == "nopet" and KennelDB.petDead) then
        petBtn:SetAttribute("type1", "spell"); petBtn:SetAttribute("spell1", revive)
    elseif state == "nopet" then
        petBtn:SetAttribute("type1", "spell"); petBtn:SetAttribute("spell1", call)
    else
        petBtn:SetAttribute("type1", "macro")
    end
end

-- remember whether the pet is dead, also after its body disappears
local function SetPetDead(isDead)
    if (KennelDB.petDead or false) ~= isDead then
        KennelDB.petDead = isDead or nil
        Try("macros", ApplyMacros) -- waits until combat ends if needed
    end
end

local function UpdatePetIcon()
    if not petBtn then return end
    local exists = UnitExists("pet")
    local dead = exists and UnitIsDead("pet")
    if exists then SetPetDead(dead and true or false) end

    petBtn.icon:SetVertexColor(1, 1, 1)
    if not exists and KennelDB.petDead then
        -- pet died and its body is gone: the button revives
        petBtn.iconSource = SetIcon(petBtn.icon, SpellIcon(petSpells.revive.name), petSpells.revive.icon, REVIVE_ICON)
        petBtn.icon:SetVertexColor(1, 0.4, 0.4)
        petBtn.state = "dead"
    elseif not exists then
        petBtn.iconSource = SetIcon(petBtn.icon, SpellIcon(callSpell), petSpells.call.icon, CALL_ICON)
        petBtn.state = "call"
    elseif dead then
        petBtn.iconSource = SetIcon(petBtn.icon, SpellIcon(petSpells.revive.name), petSpells.revive.icon, REVIVE_ICON)
        petBtn.icon:SetVertexColor(1, 0.4, 0.4)
        petBtn.state = "dead"
    else
        petBtn.iconSource = SetIcon(petBtn.icon, SpellIcon(petSpells.feed.name), petSpells.feed.icon, FEED_ICON)
        petBtn.state = "feed"
        local happiness = GetPetHappiness and GetPetHappiness()
        if happiness == 1 then
            petBtn.icon:SetVertexColor(1, 0.4, 0.4)
        elseif happiness == 2 then
            petBtn.icon:SetVertexColor(1, 0.9, 0.5)
        end
    end
end

local function CreatePetButton()
    local btn = CreateFrame("Button", "KennelPet", bar, "SecureActionButtonTemplate, SecureHandlerStateTemplate")
    btn:SetSize(SIZE, SIZE)
    btn:SetPoint("LEFT", bar, "LEFT", 0, 0)

    -- act once per click: on key down or key up, as the game's
    -- "cast on key down" setting says (both made it fire twice)
    local ok, useDown = pcall(function() return GetCVar("ActionButtonUseKeyDown") == "1" end)
    btn:RegisterForClicks((ok and useDown) and "AnyDown" or "AnyUp")

    -- switch what left click does when the pet appears, dies or goes away
    btn:SetAttribute("_onstate-petstate", STATE_SNIPPET)
    RegisterStateDriver(btn, "petstate", PET_STATE)

    btn.back = btn:CreateTexture(nil, "BACKGROUND")
    btn.back:SetPoint("TOPLEFT", -1, 1)
    btn.back:SetPoint("BOTTOMRIGHT", 1, -1)
    btn.back:SetColorTexture(0, 0, 0, 0.6)

    btn.icon = btn:CreateTexture(nil, "ARTWORK")
    btn.icon:SetAllPoints()
    btn.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    btn.icon:SetTexture(QUESTION)

    btn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")

    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Pet", 1, 1, 1)
        if self.state == "dead" then
            GameTooltip:AddLine("Your pet is dead. Left or right click: " .. petSpells.revive.name, 1, 0.5, 0.5, true)
        elseif self.state == "call" then
            GameTooltip:AddLine("Left click: " .. callSpell, 0.8, 0.8, 0.8, true)
        else
            GameTooltip:AddLine("Left click: " .. petSpells.feed.name .. " (out of combat)", 0.8, 0.8, 0.8, true)
        end
        GameTooltip:AddLine("Right click: " .. petSpells.revive.name, 0.8, 0.8, 0.8, true)
        if (KennelDB.food or "") ~= "" then
            GameTooltip:AddLine("Food: " .. KennelDB.food .. " (set by you, /kennel food auto to undo)", 0.6, 1, 0.6, true)
        elseif autoFood then
            GameTooltip:AddLine("Food: " .. autoFood.name .. " x" .. autoFood.count .. " (auto, " .. autoFood.kind .. ")", 0.6, 1, 0.6, true)
        elseif UnitExists("pet") then
            GameTooltip:AddLine("No food your pet eats found in your bags", 1, 0.6, 0.2, true)
        end
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    btn:SetScript("PostClick", function(self, button, down)
        if KennelDB.showClicks then
            local what
            if button == "RightButton" then
                what = "cast spell " .. tostring(self:GetAttribute("spell2"))
            elseif self:GetAttribute("type1") == "spell" then
                what = "cast spell " .. tostring(self:GetAttribute("spell1"))
            else
                what = (tostring(self:GetAttribute("macrotext1")):gsub("\n", " | "))
            end
            Print("click " .. tostring(button) .. (down and " (down)" or " (up)") .. ": " .. what)
        end
    end)
    btn:SetScript("PreClick", function(self, button, down)
        if KennelDB.showClicks then
            Print("button got " .. tostring(button) .. (down and " (down)" or " (up)"))
        end
        self.lastClick, self.lastClickTime = (button == "RightButton") and "dead" or self.state, GetTime()
        if (KennelDB.food or "") == "" and autoFood then
            lastFeedTry, lastFeedTime = autoFood.id, GetTime()
        end
    end)

    petBtn = btn
end

---------------------------------------------------------------------
-- ammo icon
---------------------------------------------------------------------
local RANGED_SLOT = 18 -- re-checked with SlotId() at login
local ARROW_ICON  = "Interface\\Icons\\INV_Ammo_Arrow_02"
local BULLET_ICON = "Interface\\Icons\\INV_Ammo_Bullet_02"

-- what kind of ammo does the equipped ranged weapon use? "arrow", "bullet" or nil
local function WeaponAmmoType()
    local item = GetInventoryItemID("player", RANGED_SLOT) or GetInventoryItemLink("player", RANGED_SLOT)
    if not item then return nil end
    local _, _, _, _, _, classID, subClassID = ItemInfoInstant(item)
    if classID ~= 2 then return nil end             -- not a weapon
    if subClassID == 2 or subClassID == 18 then     -- bow, crossbow
        return "arrow"
    elseif subClassID == 3 then                     -- gun
        return "bullet"
    end
    return nil
end

-- what kind of ammo is in the ammo slot? "arrow", "bullet" or nil
local function EquippedAmmoType(item)
    if not item then return nil end
    local _, _, _, _, _, classID, subClassID = ItemInfoInstant(item)
    if classID ~= 6 then return nil end             -- not a projectile
    if subClassID == 2 then return "arrow" end
    if subClassID == 3 then return "bullet" end
    return nil
end

-- one bag slot -> itemID, stack count, icon (works with old and new bag APIs)
local function BagSlot(bag, slot)
    if C_Container and C_Container.GetContainerItemInfo then
        local info = C_Container.GetContainerItemInfo(bag, slot)
        if info then return info.itemID, info.stackCount, info.iconFileID end
        return nil
    end
    if GetContainerItemInfo then
        local tex, count, _, _, _, _, link, _, _, itemID = GetContainerItemInfo(bag, slot)
        if not itemID and link then itemID = tonumber(link:match("item:(%d+)")) end
        return itemID, count, tex
    end
    return nil
end

local function BagSize(bag)
    if C_Container and C_Container.GetContainerNumSlots then return C_Container.GetContainerNumSlots(bag) or 0 end
    if GetContainerNumSlots then return GetContainerNumSlots(bag) or 0 end
    return 0
end

-- find every arrow and bullet stack in your bags (quiver and ammo pouch included)
-- returns: totals by kind, and a list of { id, kind, count, icon } per ammo item
local function ScanBagAmmo()
    local totals = { arrow = 0, bullet = 0 }
    local byID, list = {}, {}
    local lastBag = NUM_BAG_SLOTS or 4
    for bag = 0, lastBag do
        for slot = 1, BagSize(bag) do
            local id, count, icon = BagSlot(bag, slot)
            if id then
                local kind = EquippedAmmoType(id)
                if kind then
                    count = count or 1
                    totals[kind] = totals[kind] + count
                    local e = byID[id]
                    if not e then
                        e = { id = id, kind = kind, count = 0, icon = icon }
                        byID[id] = e
                        list[#list + 1] = e
                    end
                    e.count = e.count + count
                end
            end
        end
    end
    table.sort(list, function(x, y) return x.count > y.count end)
    return totals, list, byID
end

local function UpdateAmmo()
    if not ammo then return end
    local want = WeaponAmmoType()                   -- what your weapon fires
    local slotID = GetInventoryItemID("player", AMMO_SLOT)
    local slotKind = EquippedAmmoType(slotID)
    local totals, list, byID = ScanBagAmmo()

    -- which kind to count: your weapon's, else whatever is in the ammo slot, else whatever you carry most of
    local kind = want or slotKind
    if not kind then
        kind = (totals.bullet > totals.arrow) and "bullet" or ((totals.arrow > 0) and "arrow" or nil)
    end

    -- which item to show: the one in the ammo slot, else your biggest stack of the right kind
    local show
    if slotID then
        show = byID[slotID] or { id = slotID, kind = slotKind, count = GetInventoryItemCount("player", AMMO_SLOT) or 0 }
    else
        for _, e in ipairs(list) do
            if e.kind == kind then show = e break end
        end
    end

    ammo.list, ammo.kind, ammo.slotID, ammo.want = list, kind, slotID, want
    ammo.icon:SetVertexColor(1, 1, 1)
    ammo.icon:SetDesaturated(false)

    if not show then
        -- no ammo of the right kind anywhere
        local fallback = (kind == "arrow" and ARROW_ICON) or (kind == "bullet" and BULLET_ICON) or QUESTION
        ammo.icon:SetTexture(fallback)
        ammo.icon:SetDesaturated(true)
        ammo.count:SetText("0")
        ammo.count:SetTextColor(1, 0.2, 0.2)
        ammo.showID = nil
        ammo.problem = kind and ("No " .. kind .. "s in your bags") or "No ammo found"
        return
    end

    local n = (kind and totals[kind]) or show.count or 0
    if n == 0 then n = show.count or 0 end
    local icon = (slotID and GetInventoryItemTexture("player", AMMO_SLOT)) or show.icon or ItemIcon(show.id)
        or (show.kind == "arrow" and ARROW_ICON) or (show.kind == "bullet" and BULLET_ICON) or QUESTION

    ammo.showID = show.id
    ammo.icon:SetTexture(icon)
    ammo.count:SetText(tostring(n))
    ammo.problem = nil

    if want and show.kind and want ~= show.kind then
        -- wrong ammo for your weapon (e.g. arrows with a gun)
        ammo.icon:SetVertexColor(1, 0.3, 0.3)
        ammo.count:SetTextColor(1, 0.2, 0.2)
        ammo.problem = "Wrong ammo: your weapon uses " .. want .. "s"
    elseif n <= (KennelDB.lowAmmo or 200) then
        ammo.count:SetTextColor(1, 0.2, 0.2)
    else
        ammo.count:SetTextColor(1, 1, 1)
    end
    if not slotID then
        ammo.note = "Ammo slot reads empty: if you can't shoot, drag these into your ammo slot"
    else
        ammo.note = nil
    end
end

---------------------------------------------------------------------
-- auto-buy ammo at vendors
---------------------------------------------------------------------
-- When a vendor window opens: find the highest-level arrows or bullets
-- you can use that fit your weapon, and buy enough to reach KennelDB.ammoTarget
-- (all ammo of that kind in your bags counts). Never spends more than you
-- have or buys more stacks than you have free bag slots.
local function MerchantItem(i)
    local name, price, perBuy, available, purchasable, usable
    if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
        local ok, info = pcall(C_MerchantFrame.GetItemInfo, i)
        if ok and type(info) == "table" then
            name, price, perBuy, available = info.name, info.price, info.stackCount, info.numAvailable
            purchasable, usable = info.isPurchasable, info.isUsable
        end
    end
    if not name and GetMerchantItemInfo then
        local _
        name, _, price, perBuy, available, purchasable, usable = GetMerchantItemInfo(i)
    end
    local id = GetMerchantItemID and GetMerchantItemID(i)
    if not id and GetMerchantItemLink then
        local link = GetMerchantItemLink(i)
        id = link and tonumber(link:match("item:(%d+)"))
    end
    return id, name, price or 0, perBuy or 1, available or -1, purchasable ~= false, usable ~= false
end

local function FreeBagSlots()
    local free = 0
    for bag = 0, (NUM_BAG_SLOTS or 4) do
        local n
        if C_Container and C_Container.GetContainerNumFreeSlots then
            n = C_Container.GetContainerNumFreeSlots(bag)
        elseif GetContainerNumFreeSlots then
            n = GetContainerNumFreeSlots(bag)
        end
        free = free + (n or 0)
    end
    return free
end

local function Money(copper)
    if GetCoinTextureString then return GetCoinTextureString(copper) end
    return string.format("%dg %ds %dc", copper / 10000, (copper / 100) % 100, copper % 100)
end

local buying = false

local function AutoBuyAmmo()
    if not KennelDB.autoBuyAmmo or buying then return end
    local kind = WeaponAmmoType()
    if not kind then return end -- no bow, crossbow or gun equipped
    local count = GetMerchantNumItems and GetMerchantNumItems() or 0
    if count == 0 then return end

    -- best ammo on sale: highest required level you meet, then highest item level, then cheapest
    local myLevel = UnitLevel("player") or 1
    local best
    for i = 1, count do
        local id, name, price, perBuy, available, purchasable, usable = MerchantItem(i)
        if id and purchasable and usable and available ~= 0 and EquippedAmmoType(id) == kind then
            local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
            local _, _, _, itemLevel, minLevel = getInfo(id)
            minLevel, itemLevel = minLevel or 0, itemLevel or 0
            if minLevel <= myLevel then
                local better = not best or minLevel > best.minLevel
                    or (minLevel == best.minLevel and itemLevel > best.itemLevel)
                    or (minLevel == best.minLevel and itemLevel == best.itemLevel and price < best.price)
                if better then
                    best = { index = i, id = id, name = name, price = price, perBuy = math.max(perBuy, 1),
                             available = available, minLevel = minLevel, itemLevel = itemLevel }
                end
            end
        end
    end
    if not best then return end

    local totals = ScanBagAmmo()
    local need = (KennelDB.ammoTarget or 1000) - (totals[kind] or 0)
    if need <= 0 then return end

    -- each purchase gives perBuy items (usually a stack of 200)
    local buys = math.ceil(need / best.perBuy)
    if best.available > 0 then buys = math.min(buys, best.available) end
    if best.price > 0 then buys = math.min(buys, math.floor(GetMoney() / best.price)) end
    buys = math.min(buys, FreeBagSlots())
    if buys <= 0 then
        Print("wanted to buy " .. best.name .. " but you're out of money or bag space.")
        return
    end

    -- buy one stack at a time, a moment apart, so the vendor keeps up
    buying = true
    local done = 0
    local function step()
        if not buying or not MerchantFrame or not MerchantFrame:IsShown() then buying = false return end
        BuyMerchantItem(best.index) -- one purchase = one vendor bundle (usually 200)
        done = done + 1
        if done < buys then
            C_Timer.After(0.3, step)
        else
            buying = false
            Print("bought " .. (done * best.perBuy) .. " " .. best.name .. " for " .. Money(done * best.price) .. ".")
        end
    end
    step()
end

local function CreateAmmo()
    local f = CreateFrame("Frame", nil, bar)
    f:SetSize(SIZE, SIZE)
    f:SetPoint("LEFT", bar, "LEFT", 2 * (SIZE + GAP), 0)
    f:EnableMouse(true)

    f.back = f:CreateTexture(nil, "BACKGROUND")
    f.back:SetPoint("TOPLEFT", -1, 1)
    f.back:SetPoint("BOTTOMRIGHT", 1, -1)
    f.back:SetColorTexture(0, 0, 0, 0.6)

    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.icon:SetAllPoints()
    f.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    f.count = f:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    f.count:SetPoint("BOTTOMRIGHT", -2, 2)

    f:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        if self.slotID then
            GameTooltip:SetInventoryItem("player", AMMO_SLOT)
        elseif self.showID and GameTooltip.SetItemByID then
            GameTooltip:SetItemByID(self.showID)
        else
            GameTooltip:AddLine("Ammo", 1, 1, 1)
        end
        if self.problem then GameTooltip:AddLine(self.problem, 1, 0.3, 0.3, true) end
        if self.note then GameTooltip:AddLine(self.note, 1, 0.8, 0.3, true) end
        if self.list and #self.list > 0 then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("In your bags:", 1, 1, 1)
            for _, e in ipairs(self.list) do
                local name = (GetItemInfo and GetItemInfo(e.id)) or (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(e.id)) or ("item " .. e.id)
                GameTooltip:AddDoubleLine(name, tostring(e.count), 0.8, 0.8, 0.8, 1, 1, 1)
            end
        end
        GameTooltip:AddLine("Red at " .. tostring(KennelDB.lowAmmo) .. " or less (/kennel ammo <number>)", 0.6, 0.6, 0.6, true)
        GameTooltip:Show()
    end)
    f:SetScript("OnLeave", function() GameTooltip:Hide() end)

    ammo = f
end

---------------------------------------------------------------------
-- pet food: pick it automatically from your bags
---------------------------------------------------------------------
-- The game has no "what diet is this item" function, so food kinds are guessed
-- from the item name. If the pet refuses a food, Kennel remembers and skips it.
local FOOD_WORDS = {
    meat   = { "meat", "flank", "haunch", "ribs", "chop", "steak", "jerky", "venison", "bacon",
               "sausage", "wing", "wings", "leg", "kabob", "ham", "mutton", "pork", "loin",
               "sirloin", "shank", "liver", "snout", "chunk" },
    fish   = { "fish", "smallfish", "mightfish", "snapper", "salmon", "mackerel", "catfish", "sagefish",
               "yellowtail", "eel", "grouper", "squid", "lobster", "crab", "clam", "trout", "bass",
               "cod", "filet", "fillet", "darter", "rockscale" },
    bread  = { "bread", "biscuit", "biscuits", "muffin", "muffins", "bun", "buns", "roll", "rolls",
               "cornbread", "pumpernickel", "croissant", "bagel" },
    cheese = { "cheese", "cheddar", "brie", "gouda", "swiss", "bleu", "sharp" },
    fruit  = { "apple", "apples", "banana", "bananas", "melon", "watermelon", "peach", "peaches",
               "grape", "grapes", "fruit", "raisin", "raisins", "berry", "berries", "plum",
               "orange", "pear", "tangerine", "mango" },
    fungus = { "mushroom", "mushrooms", "morel", "morels", "truffle", "fungus", "spore", "spores",
               "shroom", "cap", "caps" },
}

local function FoodKind(name)
    if not name then return nil end
    local lower = " " .. name:lower() .. " "
    for kind, words in pairs(FOOD_WORDS) do
        for _, w in ipairs(words) do
            if lower:find("%f[%a]" .. w .. "%f[%A]") then return kind end
        end
    end
    return nil
end

local function ItemInfo(id)
    local f = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    if not f then return nil end
    return f(id)
end

-- which food kinds does the current pet eat? nil = the game won't say (then every kind is tried)
local function PetDiet()
    if not GetPetFoodTypes then return nil end
    local ok, a, b, c, d, e, f = pcall(GetPetFoodTypes)
    if not ok or not a then return nil end
    local diet, any = {}, false
    for _, t in ipairs({ a, b, c, d, e, f }) do
        local k = t:lower()
        for kind in pairs(FOOD_WORDS) do
            if k:find(kind) then diet[kind] = true; any = true end
        end
    end
    return any and diet or nil
end

local function PetKey()
    return (UnitCreatureFamily and UnitCreatureFamily("pet")) or UnitName("pet") or "pet"
end

-- has this pet refused this food before?
local function Refused(id)
    local fam = KennelDB.refused and KennelDB.refused[PetKey()]
    if fam and fam[id] then return true end
    local low = KennelDB.tooLow and KennelDB.tooLow[id]
    if low and (UnitLevel("pet") or 0) >= low then return true end
    return false
end

local foodList = {} -- every food in your bags the pet will eat, best first
local foodFrame

local function PickFood()
    foodDirty = false
    local old = autoFood and autoFood.id
    if (KennelDB.food or "") ~= "" then
        autoFood, foodList = nil, {}
    elseif UnitExists("pet") and not UnitIsDead("pet") then
        -- (with no pet out the diet is unknown, so keep the last choice)
        local diet = PetDiet()
        local seen, list = {}, {}
        for bag = 0, (NUM_BAG_SLOTS or 4) do
            for slot = 1, BagSize(bag) do
                local id, count, icon = BagSlot(bag, slot)
                if id then
                    local e = seen[id]
                    if e then
                        e.count = e.count + (count or 1)
                    elseif e == nil then
                        local name, _, _, itemLevel, _, _, _, _, _, _, _, classID = ItemInfo(id)
                        local kind = FoodKind(name)
                        -- food & drink (0) or cooking ingredients (7) only, of a kind the pet eats
                        if name and kind and (classID == 0 or classID == 7)
                            and (not diet or diet[kind]) and not Refused(id) then
                            e = { id = id, name = name, kind = kind, count = count or 1, level = itemLevel or 0, icon = icon }
                            seen[id] = e
                            list[#list + 1] = e
                        else
                            seen[id] = false
                        end
                    end
                end
            end
        end
        -- lowest-level food first (saves your better food); ties: the biggest stack
        table.sort(list, function(x, y)
            if x.level ~= y.level then return x.level < y.level end
            return x.count > y.count
        end)
        foodList = list
        autoFood = list[1]
    end
    if (autoFood and autoFood.id) ~= old then ApplyMacros() end
end

---------------------------------------------------------------------
-- food icon: the food the next feed will use, and how many you have
---------------------------------------------------------------------
local FOOD_ICON = "Interface\\Icons\\INV_Misc_Food_14"

local function UpdateFood()
    local f = foodFrame
    if not f then return end
    local manual = KennelDB.food or ""
    local id, count, icon, name
    if manual ~= "" then
        local mid, _, _, _, micon = ItemInfoInstant(manual)
        id, icon, name = mid, micon, manual
        count = ItemCount(mid or manual) or 0
    elseif autoFood then
        id, name = autoFood.id, autoFood.name
        count = ItemCount(id) or autoFood.count or 0
        icon = autoFood.icon or ItemIcon(id)
    end
    f.itemID, f.foodName = id, name

    f.icon:SetVertexColor(1, 1, 1)
    if not name then
        SetIcon(f.icon, FOOD_ICON)
        f.icon:SetDesaturated(true)
        f.count:SetText("0")
        f.count:SetTextColor(1, 0.2, 0.2)
        return
    end
    SetIcon(f.icon, icon, FOOD_ICON)
    f.icon:SetDesaturated(count == 0)
    f.count:SetText(tostring(count))
    if count <= (KennelDB.lowFood or 5) then
        f.count:SetTextColor(1, 0.2, 0.2)
    else
        f.count:SetTextColor(1, 1, 1)
    end
end

local function CreateFood()
    local f = CreateFrame("Frame", nil, bar)
    f:SetSize(SIZE, SIZE)
    f:SetPoint("LEFT", bar, "LEFT", SIZE + GAP, 0)
    f:EnableMouse(true)

    f.back = f:CreateTexture(nil, "BACKGROUND")
    f.back:SetPoint("TOPLEFT", -1, 1)
    f.back:SetPoint("BOTTOMRIGHT", 1, -1)
    f.back:SetColorTexture(0, 0, 0, 0.6)

    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.icon:SetAllPoints()
    f.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    f.count = f:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    f.count:SetPoint("BOTTOMRIGHT", -2, 2)

    f:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        if self.itemID and GameTooltip.SetItemByID then
            GameTooltip:SetItemByID(self.itemID)
        else
            GameTooltip:AddLine("Pet food", 1, 1, 1)
        end
        if (KennelDB.food or "") ~= "" then
            GameTooltip:AddLine("Set by you (/kennel food auto to pick automatically)", 0.6, 1, 0.6, true)
        elseif autoFood then
            GameTooltip:AddLine("Next feed uses this (picked automatically)", 0.6, 1, 0.6, true)
        elseif not UnitExists("pet") then
            GameTooltip:AddLine("Call your pet so Kennel can see what it eats", 1, 0.8, 0.3, true)
        else
            GameTooltip:AddLine("No food your pet eats found in your bags", 1, 0.3, 0.3, true)
        end
        if #foodList > 0 then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Food your pet eats in your bags:", 1, 1, 1)
            for _, e in ipairs(foodList) do
                local c = ItemCount(e.id) or e.count
                local r, g, b = 0.8, 0.8, 0.8
                if autoFood and e.id == autoFood.id then r, g, b = 0.6, 1, 0.6 end
                GameTooltip:AddDoubleLine(e.name .. " (" .. e.kind .. ")", tostring(c), r, g, b, 1, 1, 1)
            end
        end
        GameTooltip:AddLine("Feed with a left click on the pet button.", 0.6, 0.6, 0.6, true)
        GameTooltip:Show()
    end)
    f:SetScript("OnLeave", function() GameTooltip:Hide() end)

    foodFrame = f
end

-- the game refused a call or revive: fix our idea of whether the pet is dead
local function LearnPetState(msg)
    if not msg or not petBtn or not petBtn.lastClickTime or GetTime() - petBtn.lastClickTime > 5 then return end
    local lower = msg:lower()
    if not lower:find("pet") then return end
    local saysNotDead = lower:find("not dead") or lower:find("isn't dead") or lower:find("is alive")
    if petBtn.lastClick == "call" and lower:find("dead") and not saysNotDead then
        petBtn.lastClickTime = nil
        SetPetDead(true)
        Print("your pet is dead. Click the pet button again to revive it.")
    elseif petBtn.lastClick == "dead" and saysNotDead and KennelDB.petDead and not UnitExists("pet") then
        petBtn.lastClickTime = nil
        SetPetDead(false)
        Print("your pet isn't dead. Click the pet button again to call it.")
    end
end

-- the game said no to the food we just tried: remember it and pick another
local function LearnFromError(msg)
    if not msg or not lastFeedTry or not lastFeedTime or GetTime() - lastFeedTime > 5 then return end
    local lower = msg:lower()
    local tooLow = (SPELL_FAILED_FOOD_LOWLEVEL and msg == SPELL_FAILED_FOOD_LOWLEVEL)
        or (lower:find("food") and lower:find("level"))
    local wrong = (SPELL_FAILED_WRONG_PET_FOOD and msg == SPELL_FAILED_WRONG_PET_FOOD)
        or (not tooLow and lower:find("food"))
    local name = (autoFood and autoFood.id == lastFeedTry and autoFood.name) or ("item " .. lastFeedTry)
    if tooLow then
        KennelDB.tooLow = KennelDB.tooLow or {}
        KennelDB.tooLow[lastFeedTry] = UnitLevel("pet") or 1
        Print(name .. " is too low level for your pet. Picking another food.")
    elseif wrong then
        local key = PetKey()
        KennelDB.refused = KennelDB.refused or {}
        KennelDB.refused[key] = KennelDB.refused[key] or {}
        KennelDB.refused[key][lastFeedTry] = true
        Print("your pet won't eat " .. name .. ". Picking another food.")
    else
        return
    end
    lastFeedTry = nil
    foodDirty = true
end

---------------------------------------------------------------------
-- bar frame, layout, slash commands
---------------------------------------------------------------------
local function ApplyLayout()
    if InCombatLockdown() then
        bar.pendingLayout = true
        return
    end
    bar.pendingLayout = false
    bar:ClearAllPoints()
    bar:SetPoint(KennelDB.point, UIParent, KennelDB.point, KennelDB.x, KennelDB.y)
    bar:SetScale(KennelDB.scale)
    bar.handle:SetShown(not KennelDB.locked)
    bar:SetShown(KennelDB.shown)
end

local function BuildBar()
    bar = CreateFrame("Frame", "KennelFrame", UIParent)
    bar:SetSize(SIZE * 3 + GAP * 2, SIZE)
    bar:SetPoint("CENTER", UIParent, "CENTER", 0, -200)
    bar:SetMovable(true)
    bar:SetClampedToScreen(true)

    bar.handle = CreateFrame("Frame", nil, bar)
    bar.handle:SetPoint("BOTTOMLEFT", bar, "TOPLEFT", 0, 2)
    bar.handle:SetPoint("BOTTOMRIGHT", bar, "TOPRIGHT", 0, 2)
    bar.handle:SetHeight(12)
    bar.handle:EnableMouse(true)
    bar.handle:RegisterForDrag("LeftButton")
    local bg = bar.handle:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.2, 0.8, 0.4, 0.6)
    local label = bar.handle:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("CENTER")
    label:SetText("drag  |  right-click: options")
    bar.handle:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" then ToggleOptions() end
    end)
    bar.handle:SetScript("OnDragStart", function()
        if not InCombatLockdown() then bar:StartMoving() end
    end)
    bar.handle:SetScript("OnDragStop", function()
        bar:StopMovingOrSizing()
        bar:SetUserPlaced(false)
        local point, _, _, x, y = bar:GetPoint()
        KennelDB.point, KennelDB.x, KennelDB.y = point, x, y
    end)

    CreatePetButton()
    CreateFood()
    CreateAmmo()

    -- light refresh in case an event is missed
    local elapsed = 0
    bar:SetScript("OnUpdate", function(_, dt)
        elapsed = elapsed + dt
        if elapsed >= 0.5 then
            elapsed = 0
            Try("pet icon", UpdatePetIcon)
            Try("ammo", UpdateAmmo)
            if foodDirty and not InCombatLockdown() then Try("food", PickFood) end
            Try("food icon", UpdateFood)
        end
    end)
end

---------------------------------------------------------------------
-- options window (/kennel, or right-click the drag handle)
---------------------------------------------------------------------
local options

local function MakeCheck(parent, label, x, y, get, set)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT", x, y)
    cb:SetSize(26, 26)
    local text = cb.text or cb.Text
    if not text then text = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlight") end
    text:SetFontObject("GameFontHighlight")
    text:ClearAllPoints()
    text:SetPoint("LEFT", cb, "RIGHT", 2, 1)
    text:SetText(label)
    cb:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
    cb.refresh = function() cb:SetChecked(get() and true or false) end
    return cb
end

local function MakeSlider(parent, label, x, y, minV, maxV, step, fmt, get, set)
    local title = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", x, y)
    title:SetText(label)

    local sl = CreateFrame("Slider", nil, parent)
    sl:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 2, -8)
    sl:SetSize(180, 16)
    sl:SetOrientation("HORIZONTAL")
    sl:SetMinMaxValues(minV, maxV)
    sl:SetValueStep(step)
    if sl.SetObeyStepOnDrag then sl:SetObeyStepOnDrag(true) end
    sl:EnableMouse(true)
    sl:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    local track = sl:CreateTexture(nil, "BACKGROUND")
    track:SetPoint("LEFT", 0, 0)
    track:SetPoint("RIGHT", 0, 0)
    track:SetHeight(6)
    track:SetColorTexture(0.25, 0.25, 0.25, 1)

    local low = sl:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    low:SetPoint("TOPLEFT", sl, "BOTTOMLEFT", 0, -2)
    low:SetText(string.format(fmt, minV))
    local high = sl:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    high:SetPoint("TOPRIGHT", sl, "BOTTOMRIGHT", 0, -2)
    high:SetText(string.format(fmt, maxV))
    local value = sl:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    value:SetPoint("LEFT", sl, "RIGHT", 12, 0)

    sl:SetScript("OnValueChanged", function(self, v)
        v = math.floor(v / step + 0.5) * step
        v = tonumber(string.format(fmt, v)) or v
        value:SetText(string.format(fmt, v))
        if not self.refreshing then set(v) end
    end)
    sl.refresh = function()
        sl.refreshing = true
        sl:SetValue(get())
        value:SetText(string.format(fmt, get()))
        sl.refreshing = false
    end
    return sl
end

local function MakeButton(parent, label, width, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width, 22)
    b:SetText(label)
    b:SetScript("OnClick", onClick)
    return b
end

local function FoodSummary()
    if (KennelDB.food or "") ~= "" then
        return "Using: |cffffffff" .. KennelDB.food .. "|r (" .. tostring(ItemCount(KennelDB.food) or 0) .. " in bags)"
    elseif autoFood then
        return "Next feed: |cffffffff" .. autoFood.name .. "|r x" .. tostring(ItemCount(autoFood.id) or autoFood.count)
            .. " (" .. autoFood.kind .. ", " .. #foodList .. " kinds your pet eats in bags)"
    elseif not UnitExists("pet") then
        return "Call your pet so Kennel can see what it eats."
    end
    return "|cffff6666No food your pet eats found in your bags.|r"
end

local function BuildOptions()
    local f = CreateFrame("Frame", "KennelOptions", UIParent)
    f:SetSize(400, 560)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:Hide()
    tinsert(UISpecialFrames, "KennelOptions") -- Esc closes it

    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.05, 0.05, 0.07, 0.95)
    for _, side in ipairs({ { "TOPLEFT", "TOPRIGHT", nil, 1 }, { "BOTTOMLEFT", "BOTTOMRIGHT", nil, 1 },
                            { "TOPLEFT", "BOTTOMLEFT", 1, nil }, { "TOPRIGHT", "BOTTOMRIGHT", 1, nil } }) do
        local e = f:CreateTexture(nil, "BORDER")
        e:SetPoint(side[1]); e:SetPoint(side[2])
        if side[3] then e:SetWidth(side[3]) else e:SetHeight(side[4]) end
        e:SetColorTexture(0.6, 0.5, 0.2, 1)
    end

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -14)
    title:SetText("Kennel")
    local sub = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    sub:SetPoint("LEFT", title, "RIGHT", 8, -1)
    sub:SetText("pet, food and ammo bar")

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -2, -2)

    local widgets = {}
    local function add(w) widgets[#widgets + 1] = w; return w end
    local function heading(text, y)
        local h = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        h:SetPoint("TOPLEFT", 16, y)
        h:SetText(text)
        local line = f:CreateTexture(nil, "ARTWORK")
        line:SetPoint("LEFT", h, "RIGHT", 8, 0)
        line:SetPoint("RIGHT", f, "RIGHT", -16, 0)
        line:SetHeight(1)
        line:SetColorTexture(0.6, 0.5, 0.2, 0.5)
    end

    -- bar
    heading("Bar", -46)
    add(MakeCheck(f, "Show the bar", 16, -62,
        function() return KennelDB.shown end,
        function(v) KennelDB.shown = v; ApplyLayout() end))
    add(MakeCheck(f, "Lock position (hide the drag handle)", 16, -88,
        function() return KennelDB.locked end,
        function(v) KennelDB.locked = v; ApplyLayout() end))
    add(MakeSlider(f, "Size", 20, -120, 0.5, 2, 0.1, "%.1f",
        function() return KennelDB.scale end,
        function(v) KennelDB.scale = v; ApplyLayout() end))
    local resetPos = MakeButton(f, "Reset position", 120, function()
        KennelDB.point, KennelDB.x, KennelDB.y = defaults.point, defaults.x, defaults.y
        ApplyLayout()
    end)
    resetPos:SetPoint("TOPRIGHT", -16, -64)

    -- food
    heading("Pet food", -180)
    local autoCheck, manualCheck
    autoCheck = add(MakeCheck(f, "Pick food from my bags automatically", 16, -196,
        function() return (KennelDB.food or "") == "" end,
        function()
            KennelDB.food = ""
            foodDirty = true
            Try("macros", ApplyMacros)
            options.refresh()
        end))
    manualCheck = add(MakeCheck(f, "Always use this food:", 16, -222,
        function() return (KennelDB.food or "") ~= "" end,
        function() options.foodBox:SetFocus(); options.refresh() end))

    local box = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    box:SetSize(150, 20)
    box:SetPoint("TOPLEFT", 200, -225)
    box:SetAutoFocus(false)
    local function useBoxFood()
        local name = (box:GetText() or ""):match("^%s*(.-)%s*$")
        box:ClearFocus()
        KennelDB.food = name
        foodDirty = true
        Try("macros", ApplyMacros)
        options.refresh()
    end
    box:SetScript("OnEnterPressed", useBoxFood)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus(); options.refresh() end)
    local useBtn = MakeButton(f, "Use", 44, useBoxFood)
    useBtn:SetPoint("LEFT", box, "RIGHT", 6, 0)

    local foodLine = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    foodLine:SetPoint("TOPLEFT", 22, -252)
    foodLine:SetWidth(360)
    foodLine:SetJustifyH("LEFT")

    add(MakeSlider(f, "Food count turns red at", 20, -276, 0, 40, 1, "%d",
        function() return KennelDB.lowFood or 5 end,
        function(v) KennelDB.lowFood = v end))
    local forget = MakeButton(f, "Forget refused foods", 140, function()
        KennelDB.refused, KennelDB.tooLow = nil, nil
        foodDirty = true
        Print("forgot every food your pets refused.")
    end)
    forget:SetPoint("TOPRIGHT", -16, -290)

    -- ammo
    heading("Ammo", -336)
    add(MakeSlider(f, "Ammo count turns red at", 20, -352, 0, 1000, 50, "%d",
        function() return KennelDB.lowAmmo or 200 end,
        function(v) KennelDB.lowAmmo = v end))

    -- troubleshooting
    add(MakeCheck(f, "Buy ammo automatically at vendors", 16, -400,
        function() return KennelDB.autoBuyAmmo end,
        function(v) KennelDB.autoBuyAmmo = v end))
    local buyNote = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    buyNote:SetPoint("TOPLEFT", 44, -424)
    buyNote:SetWidth(330)
    buyNote:SetJustifyH("LEFT")
    buyNote:SetText("Buys the highest-level arrows or bullets you can use for your weapon.")
    add(MakeSlider(f, "Top up to (ammo in bags)", 20, -440, 200, 4000, 100, "%d",
        function() return KennelDB.ammoTarget or 1000 end,
        function(v) KennelDB.ammoTarget = v end))

    heading("Troubleshooting", -496)
    add(MakeCheck(f, "Show clicks in chat", 16, -512,
        function() return KennelDB.showClicks end,
        function(v) KennelDB.showClicks = v or nil end))
    local spellsBtn = MakeButton(f, "Check pet spells", 130, function() SlashCmdList["KENNEL"]("spells") end)
    spellsBtn:SetPoint("TOPRIGHT", -16, -514)

    options = f
    options.foodBox = box
    options.refresh = function()
        for _, w in ipairs(widgets) do w.refresh() end
        if not box:HasFocus() then box:SetText(KennelDB.food or "") end
        foodLine:SetText(FoodSummary())
    end
    f:SetScript("OnShow", options.refresh)
    local t = 0
    f:SetScript("OnUpdate", function(_, dt)
        t = t + dt
        if t > 1 then t = 0; foodLine:SetText(FoodSummary()) end
    end)
end

ToggleOptions = function()
    if not options then Try("options window", BuildOptions) end
    if not options then return end
    if options:IsShown() then options:Hide() else options:Show() end
end

-- entry in the game's own Options > AddOns list (if this client has one)
local function RegisterGameOptions()
    local panel = CreateFrame("Frame")
    panel.name = "Kennel"
    local t = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    t:SetPoint("TOPLEFT", 16, -16)
    t:SetText("Kennel")
    local b = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    b:SetSize(180, 24)
    b:SetPoint("TOPLEFT", t, "BOTTOMLEFT", 0, -12)
    b:SetText("Open Kennel options")
    b:SetScript("OnClick", function()
        for _, frame in ipairs({ SettingsPanel or false, InterfaceOptionsFrame or false, GameMenuFrame or false }) do
            if frame and frame:IsShown() then pcall(HideUIPanel, frame) end
        end
        if not (options and options:IsShown()) then ToggleOptions() end
    end)
    if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
        local category = Settings.RegisterCanvasLayoutCategory(panel, "Kennel")
        Settings.RegisterAddOnCategory(category)
    elseif InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(panel)
    end
end

local function ShowHelp()
    Print("commands:")
    print("  /kennel food              - show the food that will be used")
    print("  /kennel food auto         - pick food from your bags automatically (default)")
    print("  /kennel food <item name>  - always use this food instead")
    print("  /kennel food forget       - forget foods your pets refused")
    print("  /kennel ammo <number>     - ammo count where the number turns red")
    print("  /kennel buy <number>|on|off - auto-buy ammo at vendors up to this amount")
    print("  /kennel lock | unlock     - hide/show the drag handle")
    print("  /kennel show | hide       - show or hide the bar")
    print("  /kennel scale <0.5-2>     - resize the bar")
    print("  /kennel reset             - reset position and settings (food kept)")
    print("  /kennel spells            - check the pet spells were found")
    print("  /kennel debug             - print details to send when something is wrong")
    print("  /kennel clicks            - show in chat what each click does (on/off)")
    print("  /kennel                   - open the options window")
    print("Short form: /kn. Keybinds: Esc > Key Bindings > Kennel.")
end

SLASH_KENNEL1 = "/kennel"
SLASH_KENNEL2 = "/kn"
SlashCmdList["KENNEL"] = function(msg)
    if not bar then
        Print("only loads on a Hunter.")
        return
    end
    msg = msg or ""
    local cmd, rest = msg:match("^(%S*)%s*(.-)$")
    cmd = (cmd or ""):lower()

    if cmd == "" or cmd == "options" or cmd == "config" then
        ToggleOptions()
    elseif cmd == "food" then
        local arg = rest:lower()
        if rest == "" then
            if KennelDB.food ~= "" then
                Print("food: " .. KennelDB.food .. " (set by you). /kennel food auto to pick automatically.")
            elseif autoFood then
                Print("food: " .. autoFood.name .. " x" .. autoFood.count .. " (auto, " .. autoFood.kind .. ")")
            else
                Print("food: auto, but nothing your pet eats was found in your bags.")
            end
        elseif arg == "auto" then
            KennelDB.food = ""
            foodDirty = true
            Print("food: picked automatically from your bags.")
        elseif arg == "forget" then
            KennelDB.refused, KennelDB.tooLow = nil, nil
            foodDirty = true
            Print("forgot every food your pets refused.")
        else
            KennelDB.food = rest
            foodDirty = true
            ApplyMacros()
            Print("food set to: " .. rest .. " (/kennel food auto to go back to automatic)")
            if InCombatLockdown() then Print("in combat: it will apply when combat ends.") end
        end
    elseif cmd == "ammo" then
        local n = tonumber(rest)
        if n and n >= 0 then
            KennelDB.lowAmmo = math.floor(n)
            UpdateAmmo()
            Print("low-ammo warning set to " .. KennelDB.lowAmmo)
        else
            Print("usage: /kennel ammo <number>")
        end
    elseif cmd == "spells" then
        -- quick in-game check that every spell name the addon uses is known
        if not InCombatLockdown() then ApplyMacros() end
        for _, key in ipairs({ "call", "revive", "feed" }) do
            local sp = petSpells[key]
            local cid = PET_SPELL_ID[key]
            Print(key .. " -> \"" .. sp.name .. "\" id " .. tostring(sp.id) .. " via " .. tostring(sp.via) .. ": "
                .. (sp.found and "|cff33ff33OK|r" or "|cffff3333NOT FOUND|r")
                .. " | classic id " .. cid .. " known=" .. tostring(KnowsSpell(cid))
                .. " name=" .. tostring(SpellNameByID(cid)))
        end
        Print("right click casts: " .. tostring(petBtn:GetAttribute("spell2"))
            .. " | left click: " .. tostring(petBtn:GetAttribute("type1")) .. " " .. tostring(petBtn:GetAttribute("spell1")))
        for slot, id in ipairs(CALL_SLOT_IDS) do
            if KnowsSpell(id) then
                Print("call slot " .. slot .. ": id " .. id .. " = " .. tostring(SpellNameByID(id)))
            end
        end
    elseif cmd == "clicks" then
        KennelDB.showClicks = not KennelDB.showClicks
        Print("click messages " .. (KennelDB.showClicks and "on: click the pet button and watch chat" or "off"))
    elseif cmd == "debug" then
        local v, build, _, toc = GetBuildInfo()
        Print("client " .. tostring(v) .. " build " .. tostring(build) .. " interface " .. tostring(toc))
        Print("slots: ammo=" .. tostring(AMMO_SLOT) .. " ranged=" .. tostring(RANGED_SLOT))
        Print("ammo id=" .. tostring(GetInventoryItemID("player", AMMO_SLOT))
            .. " link=" .. tostring(GetInventoryItemLink("player", AMMO_SLOT))
            .. " tex=" .. tostring(GetInventoryItemTexture("player", AMMO_SLOT))
            .. " slotcount=" .. tostring(GetInventoryItemCount("player", AMMO_SLOT)))
        Print("ranged id=" .. tostring(GetInventoryItemID("player", RANGED_SLOT)) .. " weapon fires=" .. tostring(WeaponAmmoType()))
        local okScan, totals, list = pcall(ScanBagAmmo)
        if okScan then
            Print("bags: arrows=" .. totals.arrow .. " bullets=" .. totals.bullet .. " stacks=" .. #list
                .. " C_Container=" .. tostring(C_Container ~= nil))
        else
            Print("bag scan error: " .. tostring(totals))
        end
        Print("summon spell=" .. tostring(callSpell) .. " icon=" .. tostring(SpellIcon(callSpell))
            .. " book icon=" .. tostring(petSpells.call.icon)
            .. " | feed icon=" .. tostring(SpellIcon("Feed Pet")))
        Print("pet button: state=" .. tostring(petBtn and petBtn.state)
            .. " icon used=" .. tostring(petBtn and petBtn.iconSource)
            .. " shown texture=" .. tostring(petBtn and petBtn.icon:GetTexture()))
        Print("api: C_Spell=" .. tostring(C_Spell and C_Spell.GetSpellTexture ~= nil)
            .. " GetSpellTexture=" .. tostring(GetSpellTexture ~= nil)
            .. " C_Item=" .. tostring(C_Item ~= nil)
            .. " GetItemInfoInstant=" .. tostring(GetItemInfoInstant ~= nil)
            .. " GetPetHappiness=" .. tostring(GetPetHappiness ~= nil)
            .. " C_SpellBook=" .. tostring(C_SpellBook ~= nil))
        Print("food: manual=" .. tostring(KennelDB.food) .. " auto=" .. tostring(autoFood and (autoFood.name .. " id " .. autoFood.id))
            .. " GetPetFoodTypes=" .. tostring(GetPetFoodTypes ~= nil)
            .. " diet=" .. tostring(GetPetFoodTypes and table.concat({ pcall(GetPetFoodTypes) }, ",", 2) or "?"))
        Print("bar shown=" .. tostring(bar:IsShown()) .. " visible=" .. tostring(bar:IsVisible())
            .. " petbtn=" .. tostring(petBtn ~= nil) .. " ammo=" .. tostring(ammo ~= nil))
    elseif cmd == "buy" then
        local n = tonumber(rest)
        if rest:lower() == "off" then
            KennelDB.autoBuyAmmo = false; Print("auto-buy ammo off")
        elseif rest:lower() == "on" then
            KennelDB.autoBuyAmmo = true; Print("auto-buy ammo on: top up to " .. KennelDB.ammoTarget)
        elseif n and n >= 0 then
            KennelDB.ammoTarget = math.floor(n); KennelDB.autoBuyAmmo = true
            Print("auto-buy ammo on: top up to " .. KennelDB.ammoTarget)
        else
            Print("/kennel buy <number> | on | off")
        end
    elseif cmd == "lock" then
        KennelDB.locked = true; ApplyLayout(); Print("locked")
    elseif cmd == "unlock" then
        KennelDB.locked = false; ApplyLayout(); Print("unlocked: drag the green handle")
    elseif cmd == "show" then
        KennelDB.shown = true; ApplyLayout()
    elseif cmd == "hide" then
        KennelDB.shown = false; ApplyLayout()
    elseif cmd == "scale" then
        local s = tonumber(rest)
        if s and s >= 0.5 and s <= 2 then
            KennelDB.scale = s; ApplyLayout()
        else
            Print("scale must be between 0.5 and 2")
        end
    elseif cmd == "reset" then
        local food, lastPet = KennelDB.food, KennelDB.lastPet
        for k, v in pairs(defaults) do KennelDB[k] = v end
        KennelDB.food, KennelDB.lastPet = food, lastPet
        ApplyLayout(); Print("position and settings reset (food kept)")
    else
        ShowHelp()
    end
end

-- key binding labels (see Bindings.xml)
BINDING_HEADER_KENNEL = "Kennel"
_G["BINDING_NAME_CLICK KennelPet:LeftButton"] = "Revive / call / feed pet"
_G["BINDING_NAME_CLICK KennelPet:RightButton"] = "Revive pet"

local events = CreateFrame("Frame")
for _, ev in ipairs({
    "PLAYER_LOGIN", "PLAYER_REGEN_ENABLED", "PLAYER_REGEN_DISABLED",
    "PLAYER_ENTERING_WORLD", "UNIT_PET", "UNIT_HAPPINESS", "UNIT_HEALTH",
    "UNIT_INVENTORY_CHANGED", "BAG_UPDATE", "SPELLS_CHANGED",
    "UI_ERROR_MESSAGE", "UNIT_LEVEL", "GET_ITEM_INFO_RECEIVED",
    "MERCHANT_SHOW", "MERCHANT_CLOSED",
}) do
    -- pcall: if Forever lacks an event (e.g. UNIT_HAPPINESS), skip it instead of erroring
    pcall(events.RegisterEvent, events, ev)
end
events:SetScript("OnEvent", function(_, event, arg1, arg2)
    if event == "PLAYER_LOGIN" then
        local _, class = UnitClass("player")
        if class ~= "HUNTER" then return end
        KennelDB = KennelDB or {}
        for k, v in pairs(defaults) do
            if KennelDB[k] == nil then KennelDB[k] = v end
        end
        AMMO_SLOT = SlotId("AmmoSlot", 0)
        RANGED_SLOT = SlotId("RangedSlot", 18)
        if not Try("building the bar", BuildBar) and not bar then return end
        Try("pet name", RememberPetName)
        Try("macros", ApplyMacros)
        Try("layout", ApplyLayout)
        Try("pet icon", UpdatePetIcon)
        Try("ammo", UpdateAmmo)
        Try("game options entry", RegisterGameOptions)
        Print("loaded. Type /kennel for options, /kennel help for commands.")
    elseif not bar then
        return
    elseif event == "PLAYER_REGEN_ENABLED" then
        if bar.pendingMacros then Try("macros", ApplyMacros) end
        if bar.pendingLayout then Try("layout", ApplyLayout) end
        Try("pet icon", UpdatePetIcon)
    elseif event == "SPELLS_CHANGED" then
        Try("macros", ApplyMacros) -- spellbook loaded or changed: find the summon spell again
        Try("pet icon", UpdatePetIcon)
    elseif event == "UNIT_PET" then
        local ok, changed = pcall(RememberPetName)
        if ok and changed then Try("macros", ApplyMacros) end
        foodDirty = true
        Try("pet icon", UpdatePetIcon)
    elseif event == "UI_ERROR_MESSAGE" then
        -- newer clients send (type, message); older ones send (message)
        local msg = type(arg2) == "string" and arg2 or arg1
        Try("pet state", LearnPetState, msg)
        Try("food", LearnFromError, msg)
    elseif event == "MERCHANT_SHOW" then
        -- wait a moment so the vendor's item list has loaded
        C_Timer.After(0.5, function() Try("auto-buy ammo", AutoBuyAmmo) end)
    elseif event == "MERCHANT_CLOSED" then
        buying = false
    elseif event == "GET_ITEM_INFO_RECEIVED" or event == "UNIT_LEVEL" then
        foodDirty = true
    elseif event == "UNIT_HEALTH" then
        if arg1 == "pet" then Try("pet icon", UpdatePetIcon) end
    else
        if event == "BAG_UPDATE" then foodDirty = true end
        Try("pet icon", UpdatePetIcon)
        Try("ammo", UpdateAmmo)
    end
end)
