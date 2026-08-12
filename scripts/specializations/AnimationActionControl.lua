--[[
    Animation Action Control (ACC) - FS25
    --------------------------------
    Author: [SoSi] Benny
    Version: 1.0.0.0
    Date: 2026/01/12
    --------------------------------
    Copyright (c) SoSi-Modding, 2026

    This script may not be modified or used in other mods without permission by the author.
]]

source(Utils.getFilename("scripts/utils/SoSiLogger.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/events/AACSetAnimationEvent.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/events/AACSetSoundEvent.lua", g_currentModDirectory))
local sosiLog = SoSiLogger.new(g_currentModName, "AnimationActionControl.lua")

AnimationActionControl = {}

AnimationActionControl.MOD_NAME = g_currentModName
AnimationActionControl.CONFIG_NAME = "soundControl"
AnimationActionControl.CONFIG_NAMESPACE = "vehicleAssistanceSystem.animationActionControl"

-- ==================== UTILS ====================
-- Resolve optional text attributes that may contain L10n keys (must start with $l10n_)
local function resolveText(text)
    if text == nil or text == "" then
        return text
    end
    -- Only resolve if text starts with $l10n_ prefix
    if g_i18n ~= nil and type(text) == "string" and string.startsWith(text, "$l10n_") then
        local key = string.sub(text, 7) -- Remove the "$l10n_" prefix
        return g_i18n:getText(key) or text
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

function AnimationActionControl.prerequisitesPresent(specializations)
    return true
end

function AnimationActionControl.initSpecialization()
    if g_vehicleConfigurationManager:getConfigurationDescByName(AnimationActionControl.CONFIG_NAME) == nil then
        g_vehicleConfigurationManager:addConfigurationType(AnimationActionControl.CONFIG_NAME, g_i18n:getText("vas_configuration_soundControl"), AnimationActionControl.CONFIG_NAMESPACE, VehicleConfigurationItem)
    end

    local schema = Vehicle.xmlSchema
    schema:setXMLSpecializationType("AnimationActionControl")

    -- AnimationActionControl
    local animationKey = "vehicle.vehicleAssistanceSystem.animationActionControl.animations.animation(?)"
    schema:register(XMLValueType.STRING, animationKey .. "#name", "Animation name")
    schema:register(XMLValueType.STRING, animationKey .. "#animationInputButton", "InputAction")
    schema:register(XMLValueType.STRING,animationKey .. "#actionTextPriority", "GS_PRIO_NORMAL | GS_PRIO_HIGH | GS_PRIO_LOW", "GS_PRIO_NORMAL")
    
    schema:register(XMLValueType.STRING, animationKey .. ".toggleText#text", "Toggle text (both states)")
    schema:register(XMLValueType.STRING, animationKey .. ".toggleText#on", "Toggle text ON (supports $l10n_ prefix)")
    schema:register(XMLValueType.STRING, animationKey .. ".toggleText#off", "Toggle text OFF (supports $l10n_ prefix)")

    local animDepKey = animationKey .. ".configurationFilter(?)"
    schema:register(XMLValueType.STRING, animDepKey .. "#name", "Configuration name", nil, true)
    schema:register(XMLValueType.STRING, animDepKey .. "#index", "Allowed configuration indices (1-based, space separated)", nil, true)

    -- SoundControl
    local soundConfigKey = "vehicle.vehicleAssistanceSystem.animationActionControl.soundControlConfigurations.soundControlConfiguration(?)"
    schema:register(XMLValueType.STRING, soundConfigKey .. "#toggleSoundGroupButton", "Button to toggle first sound group", nil, true)
    schema:register(XMLValueType.STRING, soundConfigKey .. "#switchSoundGroupButton", "Button to switch to next sound group", nil, true)
    schema:register(XMLValueType.STRING, soundConfigKey .. "#inputMode", "HOLD|TOGGLE", "TOGGLE")
    schema:register(XMLValueType.STRING, soundConfigKey .. "#actionTextPriority", "GS_PRIO_NORMAL | GS_PRIO_HIGH | GS_PRIO_LOW", "GS_PRIO_NORMAL")

    local scDepKey = soundConfigKey .. ".configurationFilter(?)"
    schema:register(XMLValueType.STRING, scDepKey .. "#name", "Configuration name", nil, true)
    schema:register(XMLValueType.STRING, scDepKey .. "#index", "Allowed configuration indices (1-based, space separated)", nil, true)

    local soundGroupKey = soundConfigKey .. ".soundGroup(?)"
    schema:register(XMLValueType.STRING, soundGroupKey .. "#name", "Sound group name (supports $l10n_ prefix)")
    schema:register(XMLValueType.STRING, soundGroupKey .. "#animation", "Animation to play when sound group is active (optional)")

    SoundManager.registerSampleXMLPaths(schema, soundGroupKey, "sound")

    -- Simple Sounds (no configuration)
    local soundKey = "vehicle.vehicleAssistanceSystem.animationActionControl.sounds.sound(?)"
    schema:register(XMLValueType.STRING, soundKey .. "#name", "Sound name (supports $l10n_ prefix)", "", true)
    schema:register(XMLValueType.STRING, soundKey .. "#soundInputButton", "Sound input button", nil, true)
    schema:register(XMLValueType.STRING, soundKey .. "#inputMode", "HOLD|TOGGLE", "TOGGLE")
    schema:register(XMLValueType.STRING, soundKey .. "#actionTextPriority", "GS_PRIO_NORMAL | GS_PRIO_HIGH | GS_PRIO_LOW", "GS_PRIO_NORMAL")
    schema:register(XMLValueType.STRING, soundKey .. "#animation", "Animation to play when sound is active (optional)")

    local ssDepKey = soundKey .. ".configurationFilter(?)"
    schema:register(XMLValueType.STRING, ssDepKey .. "#name", "Configuration name", nil, true)
    schema:register(XMLValueType.STRING, ssDepKey .. "#index", "Allowed configuration indices (1-based, space separated)", nil, true)


    SoundManager.registerSampleXMLPaths(schema, soundKey, "sound")

    schema:setXMLSpecializationType()

    -- Savegame XML Safe
    local schemaSavegame = Vehicle.xmlSchemaSavegame
    local modName = AnimationActionControl.MOD_NAME

    local saveAnimKey = ("vehicles.vehicle(?).%s.animationActionControl.animations.animation(?)"):format(modName)
    schemaSavegame:register(XMLValueType.BOOL, saveAnimKey .. "#state", "Saved animation state", false)
    local saveSoundKey = ("vehicles.vehicle(?).%s.animationActionControl.soundGroupIndex"):format(modName)
    schemaSavegame:register(XMLValueType.INT, saveSoundKey, "Saved sound group index", 0)
    local saveSimpleSoundKey = ("vehicles.vehicle(?).%s.animationActionControl.simpleSound(?)"):format(modName)
    schemaSavegame:register(XMLValueType.BOOL, saveSimpleSoundKey .. "#isPlaying", "Saved simple sound state (TOGGLE)", false)
end

function AnimationActionControl.registerFunctions(vehicleType)
    SpecializationUtil.registerFunction(vehicleType, "loadAnimationActionControlFromXML", AnimationActionControl.loadAnimationActionControlFromXML)
    SpecializationUtil.registerFunction(vehicleType, "toggleAnimationActionControl", AnimationActionControl.toggleAnimationActionControl)
    SpecializationUtil.registerFunction(vehicleType, "getAnimationActionControlByToggleInput", AnimationActionControl.getAnimationActionControlByToggleInput)
    SpecializationUtil.registerFunction(vehicleType, "loadSoundControlFromXML", AnimationActionControl.loadSoundControlFromXML)
    SpecializationUtil.registerFunction(vehicleType, "loadSimpleSounds", AnimationActionControl.loadSimpleSounds)
    SpecializationUtil.registerFunction(vehicleType, "handleSoundControl", AnimationActionControl.handleSoundControl)
    SpecializationUtil.registerFunction(vehicleType, "handleSimpleSound", AnimationActionControl.handleSimpleSound)
    SpecializationUtil.registerFunction(vehicleType, "activateSoundGroup", AnimationActionControl.activateSoundGroup)
    SpecializationUtil.registerFunction(vehicleType, "deactivateSoundGroup", AnimationActionControl.deactivateSoundGroup)
    SpecializationUtil.registerFunction(vehicleType, "switchToSoundGroup", AnimationActionControl.switchToSoundGroup)
end

function AnimationActionControl.registerEventListeners(vehicleType)
    SpecializationUtil.registerEventListener(vehicleType, "onPreLoad", AnimationActionControl)
    SpecializationUtil.registerEventListener(vehicleType, "onLoad", AnimationActionControl)
    SpecializationUtil.registerEventListener(vehicleType, "onPostLoad", AnimationActionControl)
    SpecializationUtil.registerEventListener(vehicleType, "onDelete", AnimationActionControl)
    SpecializationUtil.registerEventListener(vehicleType, "onWriteStream", AnimationActionControl)
    SpecializationUtil.registerEventListener(vehicleType, "onReadStream", AnimationActionControl)
    SpecializationUtil.registerEventListener(vehicleType, "onRegisterActionEvents", AnimationActionControl)
    SpecializationUtil.registerEventListener(vehicleType, "saveToXMLFile", AnimationActionControl)
end

-- ==================== LOAD ====================
function AnimationActionControl:onPreLoad()
    self.spec_animationActionControl = {
        actionEvents = {},
        animations = {},
        soundGroups = {},
        soundGroupIndex = 0,
        soundGroupByInput = {},
        soundConfigurations = {},
        soundConfigurationsList = {}
    }
end

function AnimationActionControl:onLoad()
    self:loadAnimationActionControlFromXML()
    local cfg = Utils.getNoNil(self.configurations[AnimationActionControl.CONFIG_NAME], 1)
    self:loadSoundControlFromXML(cfg)
    self:loadSimpleSounds()
end

-- ==================== POST LOAD (SAVEGAME) ====================
function AnimationActionControl:onPostLoad(savegame)
    local spec = self.spec_animationActionControl
    
    if savegame == nil or savegame.resetVehicles then
        return
    end

    local xmlFile = savegame.xmlFile

    local baseKey = string.format(
        "%s.%s.animationActionControl",
        savegame.key,
        AnimationActionControl.MOD_NAME
    )

    for i, anim in ipairs(spec.animations) do
        local state = xmlFile:getValue(
            string.format("%s.animations.animation(%d)#state", baseKey, i - 1),
            false
        )
        if state then
            anim.animationState = true
            self:playAnimation(anim.animationName, 1, nil, true)
        end
    end

    local cfg = Utils.getNoNil(self.configurations[AnimationActionControl.CONFIG_NAME], 1)
    local soundConfig = spec.soundConfigurations[cfg]
    local soundGroupIndex = xmlFile:getValue(baseKey .. ".soundGroupIndex", 0)

    if soundConfig ~= nil and soundConfig.soundGroups ~= nil and #soundConfig.soundGroups > 0 then
        local maxIndex = #soundConfig.soundGroups - 1
        if soundGroupIndex < 0 then
            soundGroupIndex = 0
        elseif soundGroupIndex > maxIndex then
            soundGroupIndex = maxIndex
        end
        spec.soundGroupIndex = soundGroupIndex
    else
        spec.soundGroupIndex = 0
    end

    if spec.simpleSoundsConfig and spec.simpleSoundsConfig.soundGroups then
        local s = 0
        for _, group in ipairs(spec.simpleSoundsConfig.soundGroups) do
            if group.inputMode == "TOGGLE" then
                local playing = xmlFile:getValue(
                    string.format("%s.simpleSound(%d)#isPlaying", baseKey, s),
                    false
                )
                group.isPlaying = false

                if playing and isConfigurationAllowed(self, group.dependentConfigurations) then
                    group.isPlaying = true
                    if self.isClient and group.sound ~= nil then
                        g_soundManager:playSample(group.sound)
                    end
                end
                s = s + 1
            end
        end
    end
end

-- ==================== SAVEGAME WRITE ====================
function AnimationActionControl:saveToXMLFile(xmlFile, key)
    local spec = self.spec_animationActionControl

    for i, anim in ipairs(spec.animations) do
        xmlFile:setValue(string.format("%s.animations.animation(%d)#state", key, i - 1), anim.animationState)
    end

    xmlFile:setValue(key .. ".soundGroupIndex", spec.soundGroupIndex)

    if spec.simpleSoundsConfig and spec.simpleSoundsConfig.soundGroups then
        local s = 0
        for _, group in ipairs(spec.simpleSoundsConfig.soundGroups) do
            if group.inputMode == "TOGGLE" then
                xmlFile:setValue(string.format("%s.simpleSound(%d)#isPlaying", key, s), group.isPlaying)
                s = s + 1
            end
        end
    end
end

-- ==================== DELETE ====================
function AnimationActionControl:onDelete()
    if not self.isClient then return end
    local spec = self.spec_animationActionControl
    for _, soundConfig in pairs(spec.soundConfigurations) do
        for _, group in ipairs(soundConfig.soundGroups) do
            if group.sound ~= nil then
                g_soundManager:deleteSample(group.sound)
            end
        end
    end
end

-- ==================== XML LOAD: ANIMATION ====================
function AnimationActionControl:loadAnimationActionControlFromXML()
    local spec = self.spec_animationActionControl
    local i = 0

    while true do
        local key = string.format("vehicle.vehicleAssistanceSystem.animationActionControl.animations.animation(%d)", i)
        local name = self.xmlFile:getValue(key .. "#name")
        local inputStr = self.xmlFile:getValue(key .. "#animationInputButton")
        if name == nil or inputStr == nil then break end

        local inputAction = InputAction[inputStr]
        if inputAction ~= nil then
            local prioStr = self.xmlFile:getValue(key .. "#actionTextPriority", "GS_PRIO_NORMAL")
            local textPriority = resolvePriority(prioStr)
            
            table.insert(spec.animations, {
                animationName = name,
                inputAction = inputAction,
                animationState = false,
                textPriority = textPriority,
                dependentConfigurations = parseDependentConfigurations(self.xmlFile, key),
                toggleTextRaw = {
                    text = self.xmlFile:getValue(key .. ".toggleText#text"),
                    on   = self.xmlFile:getValue(key .. ".toggleText#on"),
                    off  = self.xmlFile:getValue(key .. ".toggleText#off")
                }
            })
        end

        i = i + 1
    end
end

-- ==================== XML LOAD: SOUND ====================
function AnimationActionControl:loadSoundControlFromXML(configId)
    local spec = self.spec_animationActionControl

    configId = tonumber(configId) or 1

    spec.soundGroups = {}
    spec.soundGroupIndex = 0
    spec.soundConfigurationsList = {}

    local baseKey = string.format("vehicle.vehicleAssistanceSystem.animationActionControl.soundControlConfigurations.soundControlConfiguration(%d)", configId - 1)
    
    local soundConfig = {
        toggleButton = self.xmlFile:getValue(baseKey .. "#toggleSoundGroupButton"),
        switchButton = self.xmlFile:getValue(baseKey .. "#switchSoundGroupButton"),
        inputMode = self.xmlFile:getValue(baseKey .. "#inputMode", "HOLD"),
        textPriority = resolvePriority(self.xmlFile:getValue(baseKey .. "#actionTextPriority", "GS_PRIO_NORMAL")),
        dependentConfigurations = parseDependentConfigurations(self.xmlFile, baseKey),
        soundGroups = {}
    }

    local i = 0
    while true do
        local key = string.format("%s.soundGroup(%d)", baseKey, i)
        local groupRawName = self.xmlFile:getValue(key .. "#name")
        if groupRawName == nil then break end

        local sound = nil
        if self.isClient then
            sound = g_soundManager:loadSampleFromXML(
                self.xmlFile, key, "sound",
                self.baseDirectory, self.components,
                0, AudioGroup.VEHICLE, self.i3dMappings, self
            )
        end

        table.insert(soundConfig.soundGroups, {
            name = resolveText(groupRawName),
            sound = sound,
            isPlaying = false,
            animation = self.xmlFile:getValue(key .. "#animation")
        })

        i = i + 1
    end

    spec.soundConfigurations[configId] = soundConfig
    table.insert(spec.soundConfigurationsList, soundConfig)
end

-- ==================== XML LOAD: SIMPLE SOUNDS ====================
function AnimationActionControl:loadSimpleSounds()
    local spec = self.spec_animationActionControl
    local baseKey = "vehicle.vehicleAssistanceSystem.animationActionControl.sounds.sound"

    if spec.simpleSoundsConfig == nil then
        spec.simpleSoundsConfig = {
            soundGroups = {},
            soundGroupsByInput = {}
        }
    end

    local i = 0
    while true do
        local key = string.format("%s(%d)", baseKey, i)
        local inputStr = self.xmlFile:getValue(key .. "#soundInputButton")
        if inputStr == nil then break end

        local inputAction = InputAction[inputStr]
        if inputAction ~= nil then
            local prioStr = self.xmlFile:getValue(key .. "#actionTextPriority", "GS_PRIO_NORMAL")
            local textPriority = resolvePriority(prioStr)

            local sound = nil
            if self.isClient then
                sound = g_soundManager:loadSampleFromXML(
                    self.xmlFile, key, "sound",
                    self.baseDirectory, self.components,
                    0, AudioGroup.VEHICLE, self.i3dMappings, self
                )
            end

            local simpleSoundName = self.xmlFile:getValue(key .. "#name")
            local group = {
                name = resolveText(simpleSoundName),
                inputAction = inputAction,
                inputMode = self.xmlFile:getValue(key .. "#inputMode", "HOLD"),
                sound = sound,
                isPlaying = false,
                animation = self.xmlFile:getValue(key .. "#animation"),
                dependentConfigurations = parseDependentConfigurations(self.xmlFile, key),
                textPriority = textPriority
            }

            table.insert(spec.simpleSoundsConfig.soundGroups, group)
            spec.simpleSoundsConfig.soundGroupsByInput[inputAction] = group
        else
            sosiLog:xmlWarn(self.xmlFile, "Invalid soundInputButton '%s' in '%s'", inputStr, key)
        end

        i = i + 1
    end
end


-- ==================== MP STREAM ====================
function AnimationActionControl:onWriteStream(streamId)
    local spec = self.spec_animationActionControl
    
    -- Write animation states based on local animations
    for _, anim in ipairs(spec.animations) do
        streamWriteBool(streamId, anim.animationState)
    end
    
    -- Write sound configuration states based on local configurations
    for _, soundConfig in ipairs(spec.soundConfigurationsList) do
        streamWriteInt32(streamId, spec.soundGroupIndex)
    end
end

function AnimationActionControl:onReadStream(streamId)
    local spec = self.spec_animationActionControl
    
    -- Read animation states based on local animations (same order as written)
    for _, anim in ipairs(spec.animations) do
        local state = streamReadBool(streamId)
        anim.animationState = state
        self:playAnimation(anim.animationName, state and 1 or -1, nil, true)
    end
    
    -- Read sound configuration states based on local configurations
    for _, soundConfig in ipairs(spec.soundConfigurationsList) do
        local soundGroupIndex = streamReadInt32(streamId)
        
        if soundConfig ~= nil and soundConfig.soundGroups ~= nil and #soundConfig.soundGroups > 0 then
            local maxIndex = #soundConfig.soundGroups - 1
            if soundGroupIndex < 0 then
                soundGroupIndex = 0
            elseif soundGroupIndex > maxIndex then
                soundGroupIndex = maxIndex
            end
            spec.soundGroupIndex = soundGroupIndex
        else
            spec.soundGroupIndex = 0
        end
    end
end

-- ==================== ACTION EVENTS ====================
function AnimationActionControl:getAnimationActionControlByToggleInput(actionName)
    for _, anim in ipairs(self.spec_animationActionControl.animations) do
        if anim.inputAction == actionName then
            return anim
        end
    end
end

function AnimationActionControl:toggleAnimationActionControl(actionName, noEventSend)
    local anim = self:getAnimationActionControlByToggleInput(actionName)
    if anim == nil then return end
    if not isConfigurationAllowed(self, anim.dependentConfigurations) then return end

    AACSetAnimationEvent.sendEvent(self, actionName, noEventSend)

    anim.animationState = not anim.animationState
    self:playAnimation(anim.animationName, anim.animationState and 1 or -1, nil, true)

    if self.isClient and self.getIsEntered ~= nil and self:getIsEntered() and g_currentMission ~= nil and g_currentMission.addIngameNotification ~= nil then
        local msg = nil

        if anim.animationState and anim.toggleTextRaw and anim.toggleTextRaw.on ~= nil then
            msg = resolveText(anim.toggleTextRaw.on)
        elseif not anim.animationState and anim.toggleTextRaw and anim.toggleTextRaw.off ~= nil then
            msg = resolveText(anim.toggleTextRaw.off)
        elseif anim.toggleTextRaw and anim.toggleTextRaw.text ~= nil then
            msg = resolveText(anim.toggleTextRaw.text)
        end

        if msg ~= nil then
            g_currentMission:addIngameNotification(
                FSBaseMission.INGAME_NOTIFICATION_INFO,
                msg
            )
        end
    end
end

function AnimationActionControl:onRegisterActionEvents()
    if not self.isClient then return end

    local spec = self.spec_animationActionControl
    self:clearActionEventsTable(spec.actionEvents)
    if not self:getIsActiveForInput(true, true) then return end

    for _, anim in ipairs(spec.animations) do
        if isConfigurationAllowed(self, anim.dependentConfigurations) then
            local _, id = self:addActionEvent(
                spec.actionEvents,
                anim.inputAction,
                self,
                AnimationActionControl.actionEventToggleAnimationActionControl,
                false, true, false, true
            )
            local prio = anim.textPriority
            if type(prio) ~= "number" then
                prio = tonumber(prio) or GS_PRIO_NORMAL
            end
            g_inputBinding:setActionEventTextPriority(id, prio)
        end
    end

    for _, soundConfig in ipairs(spec.soundConfigurationsList) do
        if isConfigurationAllowed(self, soundConfig.dependentConfigurations) then
            if soundConfig.toggleButton ~= nil then
            local toggleAction = InputAction[soundConfig.toggleButton]
            if toggleAction ~= nil then
                local triggerUp = soundConfig.inputMode == "TOGGLE"
                local triggerDown = soundConfig.inputMode == "HOLD"
                local _, id = self:addActionEvent(
                    spec.actionEvents,
                    toggleAction,
                    self,
                    AnimationActionControl.actionEventSoundToggle,
                    triggerUp, triggerDown, false, true
                )
                local prio = soundConfig.textPriority
                if type(prio) ~= "number" then
                    prio = tonumber(prio) or GS_PRIO_NORMAL
                end
                g_inputBinding:setActionEventTextPriority(id, prio)
            else
                sosiLog:warn("Invalid toggleSoundGroupButton '%s' in sound config", soundConfig.toggleButton)
            end
        end

        if soundConfig.switchButton ~= nil then
            local switchAction = InputAction[soundConfig.switchButton]
            if switchAction ~= nil then
                local _, id = self:addActionEvent(
                    spec.actionEvents,
                    switchAction,
                    self,
                    AnimationActionControl.actionEventSoundSwitch,
                    true, false, false, true
                )
                local prio = soundConfig.textPriority
                if type(prio) ~= "number" then
                    prio = tonumber(prio) or GS_PRIO_NORMAL
                end
                g_inputBinding:setActionEventTextPriority(id, prio)
            else
                sosiLog:warn("Invalid switchSoundGroupButton '%s' in sound config", soundConfig.switchButton)
            end
        end
        end
    end

    if spec.simpleSoundsConfig and spec.simpleSoundsConfig.soundGroups then
        for _, group in ipairs(spec.simpleSoundsConfig.soundGroups) do
            if isConfigurationAllowed(self, group.dependentConfigurations) then
                local _, id = self:addActionEvent(
                    spec.actionEvents,
                    group.inputAction,
                    self,
                    AnimationActionControl.actionEventSimpleSound,
                    true, true, false, true
                )
                local displayName = group.name
                if displayName ~= nil then
                    g_inputBinding:setActionEventText(id, displayName)
                end
                local prio = group.textPriority
                if type(prio) ~= "number" then
                    prio = tonumber(prio) or GS_PRIO_NORMAL
                end
                g_inputBinding:setActionEventTextPriority(id, prio)
            end
        end
    end
end

-- ==================== SOUND ACTION ====================
function AnimationActionControl:handleSoundControl(actionName, inputValue, configId, isSwitch, noEventSend, forcedGroupIndex)
    local spec = self.spec_animationActionControl
    local soundConfig = spec.soundConfigurations[configId]
    if soundConfig == nil or not isConfigurationAllowed(self, soundConfig.dependentConfigurations) or soundConfig.soundGroups == nil or #soundConfig.soundGroups == 0 then return end

    -- Validate current index
    if spec.soundGroupIndex < 0 then
        spec.soundGroupIndex = 0
    elseif spec.soundGroupIndex >= #soundConfig.soundGroups then
        spec.soundGroupIndex = #soundConfig.soundGroups - 1
    end

    if isSwitch then
        -- If we receive a forced index from network, use it directly as target
        local targetIndex
        if forcedGroupIndex ~= nil then
            targetIndex = forcedGroupIndex
        else
            -- Calculate next index locally
            targetIndex = (spec.soundGroupIndex + 1) % #soundConfig.soundGroups
        end
        
        local currentGroup = soundConfig.soundGroups[spec.soundGroupIndex + 1]
        local wasPlaying = currentGroup and currentGroup.isPlaying
        
        -- Send event BEFORE making changes (only if not already from network)
        AACSetSoundEvent.sendEvent(self, actionName, inputValue, configId, targetIndex, isSwitch, false, noEventSend)
        
        -- If current sound is playing, stop it first
        if wasPlaying then
            self:deactivateSoundGroup(configId, spec.soundGroupIndex)
        end
        
        -- Update to new index
        spec.soundGroupIndex = targetIndex
        
        -- If sound was playing, activate the new one
        if wasPlaying then
            self:activateSoundGroup(configId, targetIndex)
        end
    else
        -- For non-switch (toggle/hold), use forced index if provided
        if forcedGroupIndex ~= nil then
            spec.soundGroupIndex = forcedGroupIndex
        end
        
        -- Send event BEFORE making changes
        AACSetSoundEvent.sendEvent(self, actionName, inputValue, configId, spec.soundGroupIndex, isSwitch, false, noEventSend)
        
        if soundConfig.inputMode == "HOLD" then
            if inputValue > 0 then
                self:activateSoundGroup(configId, spec.soundGroupIndex)
            else
                self:deactivateSoundGroup(configId, spec.soundGroupIndex)
            end
        elseif soundConfig.inputMode == "TOGGLE" and inputValue == 0 then
            local group = soundConfig.soundGroups[spec.soundGroupIndex + 1]
            if group and group.isPlaying then
                self:deactivateSoundGroup(configId, spec.soundGroupIndex)
            else
                self:activateSoundGroup(configId, spec.soundGroupIndex)
            end
        end
    end
end

function AnimationActionControl:activateSoundGroup(configId, groupIndex)
    local spec = self.spec_animationActionControl
    local soundConfig = spec.soundConfigurations[configId]
    if soundConfig == nil or groupIndex >= #soundConfig.soundGroups then return end

    local group = soundConfig.soundGroups[groupIndex + 1]
    if group and not group.isPlaying then
        if self.isClient and group.sound ~= nil then
            g_soundManager:playSample(group.sound)
        end
        if group.animation ~= nil then
            self:playAnimation(group.animation, 1, nil, true)
        end
        group.isPlaying = true
    end
end

function AnimationActionControl:deactivateSoundGroup(configId, groupIndex)
    local spec = self.spec_animationActionControl
    local soundConfig = spec.soundConfigurations[configId]
    if soundConfig == nil or groupIndex >= #soundConfig.soundGroups then return end

    local group = soundConfig.soundGroups[groupIndex + 1]
    if group and group.isPlaying then
        if self.isClient and group.sound ~= nil then
            g_soundManager:stopSample(group.sound)
        end
        if group.animation ~= nil then
            self:playAnimation(group.animation, -1, nil, true)
        end
        group.isPlaying = false
    end
end

function AnimationActionControl:switchToSoundGroup(configId, newIndex)
    local spec = self.spec_animationActionControl
    local soundConfig = spec.soundConfigurations[configId]
    if soundConfig == nil or newIndex >= #soundConfig.soundGroups then return end

    local newGroup = soundConfig.soundGroups[newIndex + 1]
    
    local oldGroup = soundConfig.soundGroups[spec.soundGroupIndex + 1]
    if oldGroup and oldGroup.isPlaying then
        if self.isClient and oldGroup.sound ~= nil then
            g_soundManager:stopSample(oldGroup.sound)
        end
        if oldGroup.animation ~= nil then
            self:playAnimation(oldGroup.animation, -1, nil, true)
        end
        oldGroup.isPlaying = false
    end

    spec.soundGroupIndex = newIndex
    if newGroup then
        if self.isClient and newGroup.sound ~= nil then
            g_soundManager:playSample(newGroup.sound)
        end
        if newGroup.animation ~= nil then
            self:playAnimation(newGroup.animation, 1, nil, true)
        end
        newGroup.isPlaying = true
    end
end

function AnimationActionControl.actionEventSoundToggle(self, actionName, inputValue)
    local spec = self.spec_animationActionControl
    local cfg = Utils.getNoNil(self.configurations[AnimationActionControl.CONFIG_NAME], 1)
    self:handleSoundControl(actionName, inputValue, cfg, false, false)
end

function AnimationActionControl.actionEventSoundSwitch(self, actionName, inputValue)
    local spec = self.spec_animationActionControl
    local cfg = Utils.getNoNil(self.configurations[AnimationActionControl.CONFIG_NAME], 1)
    if inputValue == 0 then
        self:handleSoundControl(actionName, inputValue, cfg, true, false)
    end
end

function AnimationActionControl.actionEventSimpleSound(self, actionName, inputValue)
    self:handleSimpleSound(actionName, inputValue, false)
end

function AnimationActionControl:handleSimpleSound(actionName, inputValue, noEventSend)
    if self.spec_animationActionControl.simpleSoundsConfig == nil then return end
    
    local group = self.spec_animationActionControl.simpleSoundsConfig.soundGroupsByInput[actionName]
    if group == nil then return end
    if not isConfigurationAllowed(self, group.dependentConfigurations) then return end

    AACSetSoundEvent.sendEvent(self, actionName, inputValue, 0, 0, false, true, noEventSend)

    if group.inputMode == "HOLD" then
        if inputValue > 0 and not group.isPlaying then
            if self.isClient and group.sound ~= nil then
                g_soundManager:playSample(group.sound)
            end
            if group.animation ~= nil then
                self:playAnimation(group.animation, 1, nil, true)
            end
            group.isPlaying = true
        elseif inputValue == 0 and group.isPlaying then
            if self.isClient and group.sound ~= nil then
                g_soundManager:stopSample(group.sound)
            end
            if group.animation ~= nil then
                self:playAnimation(group.animation, -1, nil, true)
            end
            group.isPlaying = false
        end
    elseif group.inputMode == "TOGGLE" and inputValue == 0 then
        group.isPlaying = not group.isPlaying
        if self.isClient and group.sound ~= nil then
            if group.isPlaying then
                g_soundManager:playSample(group.sound)
                if group.animation ~= nil then
                    self:playAnimation(group.animation, 1, nil, true)
                end
            else
                g_soundManager:stopSample(group.sound)
                if group.animation ~= nil then
                    self:playAnimation(group.animation, -1, nil, true)
                end
            end
        end
    end
end

function AnimationActionControl.actionEventToggleAnimationActionControl(self, actionName)
    self:toggleAnimationActionControl(actionName, false)
end