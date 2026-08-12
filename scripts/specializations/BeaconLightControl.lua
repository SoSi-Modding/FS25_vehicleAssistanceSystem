--[[
    Beacon Light Control (BLC) - FS25
    --------------------------------
    Author: [SoSi] Benny
    Version: 1.0.0.1
    Date: 2026/02/12
    --------------------------------
    Copyright (c) SoSi-Modding, 2026

    This script may not be modified or used in other mods without permission by the author.
]]

source(Utils.getFilename("scripts/utils/SoSiLogger.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/events/BLCSetBeaconLightEvent.lua", g_currentModDirectory))
local sosiLog = SoSiLogger.new(g_currentModName, "BeaconLightControl.lua")

BeaconLightControl = {}

-- ==================== UTILS ====================
function BeaconLightControl.resolveText(text)
    if text == nil then
        return nil
    end
    if g_i18n ~= nil then
        return g_i18n:convertText(text, nil)
    end
    return text
end

local function parseDependentConfigurations(xmlFile, baseKey)
    if xmlFile == nil or baseKey == nil then
        return {}
    end
    
    local list = {}
    local i = 0

    while true do
        local key = string.format("%s.configurationFilter(%d)", baseKey, i)
        local name = xmlFile:getValue(key .. "#name")
        local indexStr = xmlFile:getValue(key .. "#index")

        if name == nil or indexStr == nil then
            break
        end

        local indices = {}
        for num in string.gmatch(indexStr, "%d+") do
            table.insert(indices, tonumber(num))
        end

        table.insert(list, {
            name = name,
            indices = indices
        })

        i = i + 1
    end

    return list
end

local function resolvePriority(prioStr)
    if prioStr == nil then
        return GS_PRIO_NORMAL
    end

    local value = _G[prioStr]
    if type(value) == "number" then
        return value
    end

    local num = tonumber(prioStr)
    if num ~= nil then
        return num
    end

    return GS_PRIO_NORMAL
end

local function isConfigurationAllowed(self, dependentConfigurations)
    if dependentConfigurations == nil or #dependentConfigurations == 0 then
        return true
    end

    for _, cfg in ipairs(dependentConfigurations) do
        local currentIndex = self.configurations[cfg.name]
        if currentIndex == nil then
            return false
        end
        
        if type(currentIndex) == "string" then
            currentIndex = tonumber(currentIndex) or 0
        end
        
        local matched = false
        for _, allowedIndex in ipairs(cfg.indices) do
            if currentIndex == allowedIndex then
                matched = true
                break
            end
        end
        
        if not matched then
            return false
        end
    end

    return true
end

-- ==================== SPECIALIZATION ====================

function BeaconLightControl.prerequisitesPresent(specializations)
    return true
end

function BeaconLightControl.initSpecialization()
    local schema = Vehicle.xmlSchema
    schema:setXMLSpecializationType("BeaconLightControl")

    -- BeaconLightControl groups
    local groupKey = "vehicle.vehicleAssistanceSystem.beaconLightControl.beaconLightGroups.beaconLightGroup(?)"
    schema:register(XMLValueType.STRING, groupKey .. "#name", "BeaconLight group name")
    schema:register(XMLValueType.STRING, groupKey .. "#inputButton", "InputAction to toggle beacon lights")
    schema:register(XMLValueType.STRING, groupKey .. "#actionTextPriority", "GS_PRIO_NORMAL | GS_PRIO_HIGH | GS_PRIO_LOW", "GS_PRIO_NORMAL")
    schema:register(XMLValueType.STRING, groupKey .. "#animation", "Animation to play when beacon lights are active (optional)")
    
    -- Toggle text
    schema:register(XMLValueType.STRING, groupKey .. ".toggleText#text", "Toggle text (both states)")
    schema:register(XMLValueType.STRING, groupKey .. ".toggleText#on", "Toggle text ON (supports $l10n_ prefix)")
    schema:register(XMLValueType.STRING, groupKey .. ".toggleText#off", "Toggle text OFF (supports $l10n_ prefix)")
    
    -- Configuration filter
    local filterKey = groupKey .. ".configurationFilter(?)"
    schema:register(XMLValueType.STRING, filterKey .. "#name", "Configuration name")
    schema:register(XMLValueType.STRING, filterKey .. "#index", "Configuration indices (space separated)")
    
    -- Register beaconLight paths (using vanilla BeaconLight system)
    BeaconLight.registerVehicleXMLPaths(schema, groupKey .. ".beaconLight(?)")

    schema:setXMLSpecializationType()
end

function BeaconLightControl.registerFunctions(vehicleType)
    SpecializationUtil.registerFunction(vehicleType, "toggleBeaconLightGroup", BeaconLightControl.toggleBeaconLightGroup)
    SpecializationUtil.registerFunction(vehicleType, "setBeaconLightGroupState", BeaconLightControl.setBeaconLightGroupState)
    SpecializationUtil.registerFunction(vehicleType, "getBeaconLightToggleText", BeaconLightControl.getBeaconLightToggleText)
end

function BeaconLightControl.registerEventListeners(vehicleType)
    SpecializationUtil.registerEventListener(vehicleType, "onLoad", BeaconLightControl)
    SpecializationUtil.registerEventListener(vehicleType, "onDelete", BeaconLightControl)
    SpecializationUtil.registerEventListener(vehicleType, "onReadStream", BeaconLightControl)
    SpecializationUtil.registerEventListener(vehicleType, "onWriteStream", BeaconLightControl)
    SpecializationUtil.registerEventListener(vehicleType, "onUpdate", BeaconLightControl)
    SpecializationUtil.registerEventListener(vehicleType, "onRegisterActionEvents", BeaconLightControl)
end

-- ==================== EVENT LISTENERS ====================

function BeaconLightControl:onLoad(savegame)
    self.spec_beaconLightControl = self.spec_beaconLightControl or {}
    local spec = self.spec_beaconLightControl

    spec.beaconLightGroups = {}
    spec.actionEvents = {}

    local xmlFile = self.xmlFile
    local baseKey = "vehicle.vehicleAssistanceSystem.beaconLightControl.beaconLightGroups"

    xmlFile:iterate(baseKey .. ".beaconLightGroup", function(_, groupKey)
        local groupName = xmlFile:getValue(groupKey .. "#name")
        if groupName == nil or groupName == "" then
            sosiLog:xmlError(xmlFile, "Missing 'name' in beaconLightGroup at %s", groupKey)
            return
        end

        local inputButton = xmlFile:getValue(groupKey .. "#inputButton")
        if inputButton == nil or inputButton == "" then
            sosiLog:xmlError(xmlFile, "Missing 'inputButton' in beaconLightGroup '%s'", groupName)
            return
        end

        local dependentConfigurations = parseDependentConfigurations(xmlFile, groupKey)
        local actionTextPriority = resolvePriority(xmlFile:getValue(groupKey .. "#actionTextPriority"))
        local animationName = xmlFile:getValue(groupKey .. "#animation")
        
        local toggleTextRaw = {
            text = xmlFile:getValue(groupKey .. ".toggleText#text"),
            on   = xmlFile:getValue(groupKey .. ".toggleText#on"),
            off  = xmlFile:getValue(groupKey .. ".toggleText#off")
        }

        -- Load beaconLights using vanilla BeaconLight system
        local beaconLights = {}
        xmlFile:iterate(groupKey .. ".beaconLight", function (_, beaconKey)
            BeaconLight.loadFromVehicleXML(beaconLights, xmlFile, beaconKey, self)
        end)

        local group = {
            name = groupName,
            inputButton = inputButton,
            actionTextPriority = actionTextPriority,
            toggleTextRaw = toggleTextRaw,
            animationName = animationName,
            beaconLights = beaconLights,
            isActive = false,
            actionEventId = nil,
            dependentConfigurations = dependentConfigurations
        }

        table.insert(spec.beaconLightGroups, group)
    end)
end

function BeaconLightControl:onDelete()
    local spec = self.spec_beaconLightControl
    if spec == nil then
        return
    end

    for _, group in ipairs(spec.beaconLightGroups) do
        if BeaconLight ~= nil and BeaconLight.deleteBeaconLights ~= nil then
            BeaconLight.deleteBeaconLights(group.beaconLights)
        end
    end
end

function BeaconLightControl:onWriteStream(streamId, connection)
    local spec = self.spec_beaconLightControl
    if spec == nil then
        return
    end
    
    for _, group in ipairs(spec.beaconLightGroups) do
        streamWriteBool(streamId, group.isActive)
    end
end

function BeaconLightControl:onReadStream(streamId, connection)
    local spec = self.spec_beaconLightControl
    if spec == nil then
        return
    end
    
    for _, group in ipairs(spec.beaconLightGroups) do
        local isActive = streamReadBool(streamId)
        if isActive then
            self:setBeaconLightGroupState(group.name, true, true)
        end
    end
end

function BeaconLightControl:onUpdate(dt)
    local spec = self.spec_beaconLightControl
    if spec == nil then
        return
    end
    
    if not self.isClient then
        return
    end

    for _, group in ipairs(spec.beaconLightGroups) do
        if group.isActive and BeaconLight ~= nil and BeaconLight.updateBeaconLights ~= nil then
            BeaconLight.updateBeaconLights(self, group.beaconLights, true, dt)
        end
    end
end

function BeaconLightControl:onRegisterActionEvents(isActiveForInput, isActiveForInputIgnoreSelection)
    if self.isClient then
        local spec = self.spec_beaconLightControl
        if spec == nil then
            return
        end
        self:clearActionEventsTable(spec.actionEvents)

        if isActiveForInputIgnoreSelection then
            for _, group in ipairs(spec.beaconLightGroups) do
                if isConfigurationAllowed(self, group.dependentConfigurations) then
                    local _, actionEventId = self:addActionEvent(spec.actionEvents, InputAction[group.inputButton], 
                        self, BeaconLightControl.actionEventToggleBeaconLight, false, true, false, true, nil)
                    
                    g_inputBinding:setActionEventTextPriority(actionEventId, group.actionTextPriority)
                    g_inputBinding:setActionEventTextVisibility(actionEventId, true)
                    
                    group.actionEventId = actionEventId
                    
                    local toggleText = self:getBeaconLightToggleText(group)
                    if toggleText ~= nil and toggleText ~= "" then
                        g_inputBinding:setActionEventText(actionEventId, toggleText)
                    end
                end
            end
        end
    end
end

-- ==================== FUNCTIONS ====================

function BeaconLightControl:toggleBeaconLightGroup(groupName, noEventSend)
    local spec = self.spec_beaconLightControl
    if spec == nil then return end
    
    for _, group in ipairs(spec.beaconLightGroups) do
        if group.name == groupName then
            self:setBeaconLightGroupState(groupName, not group.isActive, noEventSend)
            break
        end
    end
end

function BeaconLightControl:setBeaconLightGroupState(groupName, state, noEventSend)
    local spec = self.spec_beaconLightControl
    if spec == nil then return end
    
    BLCSetBeaconLightEvent.sendEvent(self, groupName, state, noEventSend)
    
    for _, group in ipairs(spec.beaconLightGroups) do
        if group.name == groupName then
            group.isActive = state
            
            if group.animationName ~= nil and self.playAnimation ~= nil then
                local animDir = state and 1 or -1
                self:playAnimation(group.animationName, animDir, nil, true)
            end
            
            for _, beaconLight in ipairs(group.beaconLights) do
                if beaconLight ~= nil and beaconLight.setIsActive ~= nil then
                    beaconLight:setIsActive(state)
                end
            end
            
            if group.actionEventId ~= nil then
                local toggleText = self:getBeaconLightToggleText(group)
                if toggleText ~= nil and toggleText ~= "" then
                    g_inputBinding:setActionEventText(group.actionEventId, toggleText)
                end
            end
            break
        end
    end
end

function BeaconLightControl:getBeaconLightToggleText(group)
    if group.toggleTextRaw == nil then
        return nil
    end
    
    local raw = group.toggleTextRaw
    
    if raw.text ~= nil and raw.text ~= "" then
        return BeaconLightControl.resolveText(raw.text)
    end
    
    local textKey = group.isActive and raw.on or raw.off
    if textKey ~= nil and textKey ~= "" then
        return BeaconLightControl.resolveText(textKey)
    end
    
    return nil
end

function BeaconLightControl:actionEventToggleBeaconLight(actionName, inputValue, callbackState, isAnalog)
    local spec = self.spec_beaconLightControl
    
    for _, group in ipairs(spec.beaconLightGroups) do
        if InputAction[group.inputButton] == actionName then
            self:toggleBeaconLightGroup(group.name, false)
            break
        end
    end
end
