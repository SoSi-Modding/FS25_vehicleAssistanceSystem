--[[
    Automatic Emergency Braking (AEB) - FS25
    --------------------------------
    Author: [SoSi] Janni1101
    Version: 1.0.0.0
    Date: 2026/01/08
    --------------------------------
    Copyright (c) SoSi-Modding, 2026

    This script may not be modified or used in other mods without permission by the author.
]]

source(Utils.getFilename("scripts/utils/SoSiLogger.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/MenuManager.lua", g_currentModDirectory))
local sosiLog = SoSiLogger.new(g_currentModName, "AutomaticEmergencyBraking.lua")

AutomaticEmergencyBraking = {}

AutomaticEmergencyBraking.MOD_NAME = g_currentModName
AutomaticEmergencyBraking.MOD_DIR = g_currentModDirectory
AutomaticEmergencyBraking.SPEC_NAME = "automaticEmergencyBraking"
AutomaticEmergencyBraking.SPEC = "spec_automaticEmergencyBraking"
AutomaticEmergencyBraking.SETTINGS_XML = AutomaticEmergencyBraking.MOD_DIR .. "shared/vehicleAssistanceSystemSettings.xml"
AutomaticEmergencyBraking.SETTINGS_SCHEMA = XMLSchema.new("automaticEmergencyBrakingSettings")
AutomaticEmergencyBraking.injectionsByXMLFilename = {}

-- AEB Activation threshold
local MIN_SPEED_FORWARD = 10 -- km/h
local WARNING_DISTANCE = 5 -- meters
local EMERGENCY_BRAKE_DISTANCE = 3.25 -- meters
local MAX_SENSOR_RANGE = 20 -- meters
local SENSOR_WIDTH_FACTOR = 1.2 -- Sensor width factor relative to vehicle width

-- Only detect real obstacles, not triggers or irrelevant objects
local RAYCAST_MASK = 
    CollisionFlag.PLAYER +
    CollisionFlag.TERRAIN + 
    CollisionFlag.ROAD +
    CollisionFlag.BUILDING +
    CollisionFlag.STATIC_OBJECT + 
    CollisionFlag.DYNAMIC_OBJECT + 
    CollisionFlag.TREE +
    CollisionFlag.VEHICLE + 
    CollisionFlag.TRAFFIC_VEHICLE

-- Mild, capped scaling for vehicle hits to avoid excessive early warnings
-- If turn signal is active (excluding hazard), distances are halved
local function computeDynamicDistances(isVehicle, speedKmh, isTurnSignalActive)
    -- Base distances
    local warnDist = WARNING_DISTANCE
    local brakeDist = EMERGENCY_BRAKE_DISTANCE
    
    -- For vehicles, apply speed-based scaling
    if isVehicle then
        local v = math.max(speedKmh or 0, 0)
        -- Scaling above ~25 km/h
        if v >= 25 then
            -- Mild growth with speed (sqrt), capped
            local factor = 1 + math.sqrt(v) / 15  -- ~1.63x @ 90 km/h
            local maxFactor = 2.2                 -- cap to keep realism
            factor = math.min(factor, maxFactor)
            
            warnDist = WARNING_DISTANCE * factor
            brakeDist = EMERGENCY_BRAKE_DISTANCE * factor
        end
    end
    
    -- Apply turn signal reduction (for both vehicles and static obstacles)
    if isTurnSignalActive then
        warnDist = warnDist * 0.5
        brakeDist = brakeDist * 0.5
    end
    
    return warnDist, brakeDist
end

-- Helper: Check if turn signal is active (excluding hazard lights)
local function checkTurnSignalActive(vehicle)
    if vehicle.spec_lights == nil then
        return false
    end
    
    local spec = vehicle.spec_lights
    local turnLightState = spec.turnLightState

    if turnLightState == nil then
        return false
    end
    
    -- Use Lights constants if available, otherwise fallback to values
    -- Based on FS25 code: TURNLIGHT_OFF = 0, TURNLIGHT_LEFT = 1, TURNLIGHT_RIGHT = 2, TURNLIGHT_HAZARD = 3
    local TURNLIGHT_OFF = Lights.TURNLIGHT_OFF or 0
    local TURNLIGHT_LEFT = Lights.TURNLIGHT_LEFT or 1
    local TURNLIGHT_RIGHT = Lights.TURNLIGHT_RIGHT or 2
    local TURNLIGHT_HAZARD = Lights.TURNLIGHT_HAZARD or 3
    
    -- Check if turn signal is active
    local isActive = turnLightState == TURNLIGHT_LEFT or turnLightState == TURNLIGHT_RIGHT
    
    return isActive
end

------------------------------------------------
-- Prerequisites
------------------------------------------------
function AutomaticEmergencyBraking.prerequisitesPresent(specializations)
    return SpecializationUtil.hasSpecialization(Motorized, specializations)
        and SpecializationUtil.hasSpecialization(Drivable, specializations)
        and SpecializationUtil.hasSpecialization(Enterable, specializations)
end

------------------------------------------------
-- XML Schema
------------------------------------------------
function AutomaticEmergencyBraking.initSpecialization()
    local schema = Vehicle.xmlSchema
    schema:setXMLSpecializationType(AutomaticEmergencyBraking.SPEC_NAME)

    schema:register(XMLValueType.BOOL,
        "vehicle.vehicleAssistanceSystem.automaticEmergencyBraking#active", "AEB active", false)

    -- Warning sound
    schema:register(
        XMLValueType.STRING,
        "vehicle.vehicleAssistanceSystem.automaticEmergencyBraking.sounds.sound(?)#name",
        "Name of the AEB warning sound"
    )

    SoundManager.registerSampleXMLPaths(
        schema,
        "vehicle.vehicleAssistanceSystem.automaticEmergencyBraking.sounds.sound(?)",
        "sound"
    )

    -- Play animations
    schema:register(XMLValueType.STRING,
        "vehicle.vehicleAssistanceSystem.automaticEmergencyBraking.playAnimation(?)#name",
        "Name of the animation to play")
    schema:register(XMLValueType.FLOAT,
        "vehicle.vehicleAssistanceSystem.automaticEmergencyBraking.playAnimation(?)#playTime",
        "Play time for the animation in seconds", "1")
    schema:register(XMLValueType.STRING,
        "vehicle.vehicleAssistanceSystem.automaticEmergencyBraking.playAnimation(?)#trigger",
        "Trigger type: warning or brake", "warning")

    schema:setXMLSpecializationType()

    -- Settings schema (defaults + sounds)
    schema = AutomaticEmergencyBraking.SETTINGS_SCHEMA
    schema:setXMLSpecializationType("AutomaticEmergencyBrakingSettings")

    local basePath = "vehicleAssistanceSystemSettings.automaticEmergencyBraking"
    local soundsPath = basePath .. ".defaultSounds"
    schema:register(XMLValueType.STRING, soundsPath .. ".defaultSound(?)#name", "Name of the default AEB sound")

    SoundManager.registerSampleXMLPaths(
        schema,
        soundsPath .. ".defaultSound(?)",
        "sound"
    )

    schema:register(XMLValueType.STRING, basePath .. ".supportedVehicles.vehicle(?)#path", "Path to vehicle XML")

    schema:setXMLSpecializationType()
end

------------------------------------------------
-- Register Functions and Events
------------------------------------------------
function AutomaticEmergencyBraking.registerFunctions(vehicleType)
    SpecializationUtil.registerFunction(vehicleType, "aebRaycastCallback", AutomaticEmergencyBraking.aebRaycastCallback)
    SpecializationUtil.registerFunction(vehicleType, "updateAebWarning", AutomaticEmergencyBraking.updateAebWarning)
    SpecializationUtil.registerFunction(vehicleType, "updateAebBraking", AutomaticEmergencyBraking.updateAebBraking)
    SpecializationUtil.registerFunction(vehicleType, "loadAebSettings", AutomaticEmergencyBraking.loadAebSettings)
end

---Inject XML data for supported vehicles
---@param xmlFile XMLFile
function AutomaticEmergencyBraking.injectXMLData(xmlFile)
    if xmlFile.handle == nil or xmlFile.filename == nil then
        return
    end
    
    -- Normalize the filename for comparison (convert backslashes to forward slashes)
    local normalizedFilename = xmlFile.filename:gsub("\\", "/")
    local parentFilename = xmlFile.parentFilename ~= nil and tostring(xmlFile.parentFilename):gsub("\\", "/") or nil

    -- Check if this filename matches any of our stored resolved keys
    for pattern, injections in pairs(AutomaticEmergencyBraking.injectionsByXMLFilename) do
        local normalizedPattern = tostring(pattern):gsub("\\", "/")

        local matched = false

        -- exact match
        if normalizedFilename == normalizedPattern then
            matched = true
        end

        -- parent filename exact match
        if not matched and xmlFile.parentFilename ~= nil then
            local parentNormalized = tostring(xmlFile.parentFilename):gsub("\\", "/")
            if parentNormalized == normalizedPattern then
                matched = true
            end
        end

        -- fallback: substring match for backwards compatibility
        if not matched and normalizedFilename:find(normalizedPattern, 1, true) then
            matched = true
        end

        if matched then
            sosiLog:devInfo("Injecting AutomaticEmergencyBraking into vehicle: %s", xmlFile.filename)
            for _, entry in ipairs(injections) do
                xmlFile:setValue(entry.key, entry.value)
            end
            break
        end
    end
end

function AutomaticEmergencyBraking.registerEventListeners(vehicleType)
    SpecializationUtil.registerEventListener(vehicleType, "onPreLoad", AutomaticEmergencyBraking)
    SpecializationUtil.registerEventListener(vehicleType, "onLoad", AutomaticEmergencyBraking)
    SpecializationUtil.registerEventListener(vehicleType, "onUpdate", AutomaticEmergencyBraking)
    SpecializationUtil.registerEventListener(vehicleType, "onDelete", AutomaticEmergencyBraking)
end

------------------------------------------------
-- Helper: Set sound attributes
------------------------------------------------
local function setSoundAttributes(sample)
    if sample ~= nil then
        sample.indoorAttributes = sample.indoorAttributes or {}
        sample.outdoorAttributes = sample.outdoorAttributes or {}
        sample.outdoorAttributes.volume = 0.25
    end
end

------------------------------------------------
-- Load Settings (defaults, sounds, supportedVehicles)
------------------------------------------------
function AutomaticEmergencyBraking:loadAebSettings(loadSounds)
    local settingsFile = XMLFile.load("aebSettings", AutomaticEmergencyBraking.SETTINGS_XML, AutomaticEmergencyBraking.SETTINGS_SCHEMA)
    if settingsFile == nil then
        sosiLog:warn("Failed to load settings file: %s", tostring(AutomaticEmergencyBraking.SETTINGS_XML))
        return { defaultSounds = {} }
    end

    local basePath = "vehicleAssistanceSystemSettings.automaticEmergencyBraking"

    local settings = {
        defaultSounds = {}
    }

    -- default sounds (client only)
    if loadSounds then
        settingsFile:iterate(basePath .. ".defaultSounds.defaultSound", function(_, key)
            local name = settingsFile:getValue(key .. "#name")
            if name ~= nil then
                local sample = g_soundManager:loadSampleFromXML(
                    settingsFile,
                    key,
                    "sound",
                    AutomaticEmergencyBraking.MOD_DIR,
                    self.components,
                    0,
                    AudioGroup.VEHICLE,
                    self.i3dMappings,
                    self
                )
                
                if sample ~= nil then
                    setSoundAttributes(sample)
                    settings.defaultSounds[name] = sample
                end
            end
        end)
    end

    -- Load supportedVehicles for XML injection AND runtime checking
    AutomaticEmergencyBraking.injectionsByXMLFilename = {}
    settings.supportedVehicles = {}
    settingsFile:iterate(basePath .. ".supportedVehicles.vehicle", function(_, key)
        local vehiclePath = settingsFile:getValue(key .. "#path")
        
        if vehiclePath ~= nil then
            -- Resolve network placeholders (data, $moddir$, $pdlcdir$)
            local success, resolved = pcall(NetworkUtil.convertFromNetworkFilename, vehiclePath)
            local resolvedPath = nil

            if success and type(resolved) == "string" and resolved ~= "" then
                resolvedPath = resolved
            else
                -- Fallback: use the raw vehiclePath if convertFromNetworkFilename failed
                resolvedPath = vehiclePath
            end

            -- Normalize separators to forward slashes for consistent matching
            resolvedPath = resolvedPath:gsub("\\", "/")

            if resolvedPath ~= nil and resolvedPath ~= "" then
                -- Store for XML injection
                if AutomaticEmergencyBraking.injectionsByXMLFilename[resolvedPath] == nil then
                    AutomaticEmergencyBraking.injectionsByXMLFilename[resolvedPath] = {}
                end
                table.insert(AutomaticEmergencyBraking.injectionsByXMLFilename[resolvedPath], {
                    key = "vehicle.vehicleAssistanceSystem.automaticEmergencyBraking#active",
                    value = true
                })
                -- Also store in settings for runtime checking in onLoad
                settings.supportedVehicles[resolvedPath] = true
            end
        end
    end)

    settingsFile:delete()
    return settings
end

------------------------------------------------
-- onPreLoad
------------------------------------------------
function AutomaticEmergencyBraking:onPreLoad(savegame)
    -- Inject XML data before vehicle loads configuration
    AutomaticEmergencyBraking.injectXMLData(self.xmlFile)
end

------------------------------------------------
-- onLoad
------------------------------------------------
function AutomaticEmergencyBraking:onLoad()
    local spec = {}
    self[AutomaticEmergencyBraking.SPEC] = spec
    spec.vehicle = self -- Reference for resetAebAnimations

    local basePath = "vehicle.vehicleAssistanceSystem.automaticEmergencyBraking"

    -- Load settings first
    local settings = self:loadAebSettings(self.isClient)

    -- Check if AEB is active (from XML or supportedVehicles list)
    spec.active = self.xmlFile:getValue(basePath .. "#active", false)
    
    -- If not active in XML, check if vehicle is in supportedVehicles list
    if not spec.active and settings.supportedVehicles ~= nil then
        local configFile = self.configFileName or self.customEnvironment or ""
        local normConfigFile = configFile:gsub("\\", "/")
        for path, _ in pairs(settings.supportedVehicles) do
            if normConfigFile:find(path, 1, true) then
                spec.active = true
                sosiLog:devInfo("AEB activated for supported vehicle: %s", tostring(configFile))
                break
            end
        end
    end
    
    if not spec.active then
        return
    end

    -- Base state
    spec.closestDistance = math.huge
    spec.hitThisFrame = false
    spec.hitVehicle = false
    spec.warningActive = false
    spec.brakingActive = false
    spec.warningTimer = 0
    spec.warningSound = nil
    spec.lastBrakeForce = 0
    spec.originalBrakeForce = nil
    spec.animationTimers = {}
    spec.playAnimations = {}
    spec.lastPlayedAnimations = {}

    -- For warning sound logic
    spec.warningTriggerTimer = 0
    spec.warningTriggerDistance = nil

    -- Get vehicle dimensions
    local baseSize = self.size
    spec.vehicleLength = baseSize.length or 5
    spec.vehicleWidth = baseSize.width or 2.5

    -- Load play animations
    local animIndex = 0
    while true do
        local key = string.format("vehicle.vehicleAssistanceSystem.automaticEmergencyBraking.playAnimation(%d)", animIndex)
        if not self.xmlFile:hasProperty(key) then
            break
        end

        local animName = self.xmlFile:getValue(key .. "#name")
        local playTime = self.xmlFile:getValue(key .. "#playTime", 1)
        local trigger = self.xmlFile:getValue(key .. "#trigger", "warning")

        if animName ~= nil then
            table.insert(spec.playAnimations, {
                name = animName,
                playTime = playTime,
                trigger = trigger
            })
            --sosiLog:info("AEB: Loaded animation '%s' with playTime=%.1fs, trigger=%s", animName, playTime, trigger)
        end

        animIndex = animIndex + 1
    end

    -- Load warning sound (client only)
    if self.isClient then
        -- Try to load sound from vehicle XML (named "warning")
        local i = 0
        while true do
            local key = string.format("vehicle.vehicleAssistanceSystem.automaticEmergencyBraking.sounds.sound(%d)", i)
            if not self.xmlFile:hasProperty(key) then
                break
            end

            local name = self.xmlFile:getValue(key .. "#name")
            if name == "warning" then
                spec.warningSound = g_soundManager:loadSampleFromXML(
                    self.xmlFile,
                    key,
                    "sound",
                    self.baseDirectory,
                    self.components,
                    0,
                    AudioGroup.VEHICLE,
                    self.i3dMappings,
                    self,
                    false
                )
                if spec.warningSound ~= nil then
                    setSoundAttributes(spec.warningSound)
                end
                break
            end

            i = i + 1
        end
        
        -- Fallback: Use default warning sound from settings if not defined in vehicle XML
        if spec.warningSound == nil and settings.defaultSounds["warning"] ~= nil then
            spec.warningSound = settings.defaultSounds["warning"]
        end
    end
end

------------------------------------------------
-- onDelete
------------------------------------------------
function AutomaticEmergencyBraking:onDelete()
    local spec = self[AutomaticEmergencyBraking.SPEC]
    if spec == nil then return end

    if spec.warningSound ~= nil then
        g_soundManager:deleteSample(spec.warningSound)
    end
end

------------------------------------------------
-- Helper: Play animations for AEB events
------------------------------------------------
local function playAebAnimations(vehicle, spec, triggerType)
    for _, anim in ipairs(spec.playAnimations) do
        if anim.trigger == triggerType then
            if not spec.lastPlayedAnimations[anim.name] then
                if vehicle.playAnimation ~= nil and vehicle.getAnimationTime ~= nil then
                    -- Play forward (speed scale = 1) from current time
                    local currentTime = vehicle:getAnimationTime(anim.name) or 0
                    vehicle:playAnimation(anim.name, 1, currentTime, true)
                    spec.lastPlayedAnimations[anim.name] = true
                end
            end
            -- If playTime is not set or 0, reverse animation when trigger is no longer active
            if (anim.playTime == nil or anim.playTime == 0) then
                -- Mark that this animation should be reversed when the trigger is no longer active
                spec.animationTimers[anim.name] = -1 -- -1 as marker for "reverse immediately when trigger off"
            else
                -- Normal timer logic for playTime > 0
                if spec.lastPlayedAnimations[anim.name] and (anim.playTime or 0) > 0 then
                    spec.animationTimers[anim.name] = anim.playTime
                end
            end
        end
    end
end

-- Helper: Reset animation tracking when warning/braking stops
local function resetAebAnimations(spec)
    for name, _ in pairs(spec.lastPlayedAnimations) do
        -- If animation with playTime=0 or not set, reverse now
        if spec.animationTimers[name] == -1 then
            if spec.vehicle and spec.vehicle.playAnimation ~= nil and spec.vehicle.getAnimationTime ~= nil then
                local currentTime = spec.vehicle:getAnimationTime(name) or 0
                spec.vehicle:playAnimation(name, -1, currentTime, true)
            end
        end
        spec.lastPlayedAnimations[name] = false
    end
    for name, _ in pairs(spec.animationTimers) do
        spec.animationTimers[name] = nil
    end
end

-- Helper: Update timers and reverse animations when due
local function updateAebAnimationTimers(vehicle, spec, dt)
    if spec.animationTimers == nil then return end
    local deltaSec = (dt or 0) / 1000.0
    for name, remaining in pairs(spec.animationTimers) do
        if remaining ~= nil then
            remaining = remaining - deltaSec
            if remaining <= 0 then
                -- Reverse animation (speed = -1) from current time
                if vehicle.playAnimation ~= nil and vehicle.getAnimationTime ~= nil then
                    local currentTime = vehicle:getAnimationTime(name) or 0
                    vehicle:playAnimation(name, -1, currentTime, true)
                end
                spec.animationTimers[name] = nil
                spec.lastPlayedAnimations[name] = false
                --sosiLog:devInfo("AEB: Reversing animation '%s'", name)
            else
                spec.animationTimers[name] = remaining
            end
        end
    end
end

------------------------------------------------
-- Helper: Stop AEB systems
------------------------------------------------
local function stopAeb(spec, vehicle)
    if spec.warningSound ~= nil then
        g_soundManager:stopSample(spec.warningSound)
    end

    -- Restore original brake force
    if spec.originalBrakeForce ~= nil and vehicle ~= nil then
        local motorSpec = vehicle.spec_motorized
        if motorSpec ~= nil and motorSpec.motor ~= nil then
            motorSpec.motor.brakeForce = spec.originalBrakeForce
            spec.originalBrakeForce = nil
        end
    end

    spec.warningActive = false
    spec.brakingActive = false
    spec.warningTimer = 0
    spec.hitThisFrame = false
    spec.closestDistance = math.huge
    spec.lastBrakeForce = 0
end

------------------------------------------------
-- onUpdate
------------------------------------------------
function AutomaticEmergencyBraking:onUpdate(dt)
    local spec = self[AutomaticEmergencyBraking.SPEC]
    if spec == nil or not spec.active then return end
    
    -- Check if automatic emergency braking is enabled in settings
    if not MenuManager:getSetting("automaticEmergencyBraking") then
        stopAeb(spec, self)
        return
    end
    
    -- Always progress animation timers regardless of AEB state transitions
    updateAebAnimationTimers(self, spec, dt)

    -- Engine must be running
    if self.getIsMotorStarted ~= nil and not self:getIsMotorStarted() then
        stopAeb(spec, self)
        return
    end

    -- Get current speed
    local lastSpeed = 0
    if self.getLastSpeed ~= nil then
        lastSpeed = self:getLastSpeed()
    end
    spec.lastSpeed = lastSpeed

    -- AEB only active when moving forward at min speed
    local motor = self.getMotor ~= nil and self:getMotor() or nil
    local drivingDir = 0
    if motor ~= nil and motor.currentDirection ~= nil then
        drivingDir = motor.currentDirection
    end

    if drivingDir <= 0 or lastSpeed < MIN_SPEED_FORWARD then
        stopAeb(spec, self)
        return
    end

    -- Frame reset
    spec.closestDistance = math.huge
    spec.hitThisFrame = false
    spec.hitVehicle = false

    -- Check if turn signal is active (excluding hazard)
    local isTurnSignal = checkTurnSignalActive(self)

    -- Get steering angle for sensor adjustment
    local steeringAngle = 0
    if self.getSteeringAngle ~= nil then
        steeringAngle = self:getSteeringAngle()
    end

    -- Perform raycasts for front sensor
    local x, y, z = getWorldTranslation(self.rootNode)
    
    -- Forward direction
    local dx, dy, dz = localDirectionToWorld(self.rootNode, 0, 0, 1)
    
    -- Normalize forward direction
    local len = math.sqrt(dx*dx + dy*dy + dz*dz)
    if len > 0 then
        dx = dx / len
        dy = dy / len
        dz = dz / len
    end

    -- Sensor starts from vehicle front (higher to avoid ground bumps)
    local sensorStartDist = spec.vehicleLength * 0.4
    local sensorX = x + dx * sensorStartDist
    local sensorY = y + 1.5 -- Bumper height - avoids detecting ground/small obstacles
    local sensorZ = z + dz * sensorStartDist

    -- Get lateral direction for ray spreading
    local lateralDx, lateralDy, lateralDz = localDirectionToWorld(self.rootNode, 1, 0, 0)
    
    -- Normalize lateral direction
    len = math.sqrt(lateralDx*lateralDx + lateralDy*lateralDy + lateralDz*lateralDz)
    if len > 0 then
        lateralDx = lateralDx / len
        lateralDy = lateralDy / len
        lateralDz = lateralDz / len
    end

    -- Raycast width (multiple rays for coverage)
    local sensorWidth = spec.vehicleWidth * SENSOR_WIDTH_FACTOR
    local rayCount = 5  -- More rays for better curve detection
    
    for i = 1, rayCount do
        -- Calculate lateral offset for this ray
        local offsetFactor = (i - 1) / (rayCount - 1) - 0.5 -- -0.5 to 0.5
        local rayLateralOffset = offsetFactor * sensorWidth
        
        -- Apply steering angle to lateral offset (follow vehicle direction in curves)
        local steerAdjustment = math.tan(steeringAngle) * 2
        
        -- Calculate ray start position with curve adjustment
        local rayStartX = sensorX + lateralDx * rayLateralOffset + dx * steerAdjustment
        local rayStartY = sensorY
        local rayStartZ = sensorZ + lateralDz * rayLateralOffset + dz * steerAdjustment

        -- Shoot ray forward to detect obstacles
        raycastAll(
            rayStartX, rayStartY, rayStartZ,
            dx, dy, dz,
            MAX_SENSOR_RANGE,
            "aebRaycastCallback",
            self,
            RAYCAST_MASK,
            true
        )
    end

    self:updateAebWarning(dt, isTurnSignal)
    self:updateAebBraking(dt, isTurnSignal)
end

------------------------------------------------
-- Raycast Callback
------------------------------------------------
function AutomaticEmergencyBraking:aebRaycastCallback(hitObjectId, x, y, z, distance)
    if getRootNode(hitObjectId) == self.rootNode then
        return
    end

    local spec = self[AutomaticEmergencyBraking.SPEC]
    spec.hitThisFrame = true

    -- Detect vehicles by collision GROUP flags (player and AI traffic)
    local group = getCollisionFilterGroup(hitObjectId) or 0
    if bit32.band(group, CollisionFlag.VEHICLE) ~= 0 or bit32.band(group, CollisionFlag.TRAFFIC_VEHICLE) ~= 0 then
        spec.hitVehicle = true
    end

    if distance < spec.closestDistance then
        spec.closestDistance = distance
    end
end

------------------------------------------------
-- Warning System
------------------------------------------------
function AutomaticEmergencyBraking:updateAebWarning(dt, isTurnSignal)
    local spec = self[AutomaticEmergencyBraking.SPEC]
    local warnDist, _ = computeDynamicDistances(spec.hitVehicle, spec.lastSpeed, isTurnSignal or false)

    if not spec.hitThisFrame or spec.closestDistance >= warnDist then
        if spec.warningActive and spec.warningSound ~= nil then
            g_soundManager:stopSample(spec.warningSound)
        end
        spec.warningActive = false
        spec.warningTimer = 0
        spec.warningTriggerTimer = 0
        spec.warningTriggerDistance = nil
        return
    end

    -- Logic: Only play sound if after 0.5s the distance is still decreasing
    if spec.warningTriggerDistance == nil then
        -- First time below threshold: start timer and remember distance
        spec.warningTriggerTimer = 0
        spec.warningTriggerDistance = spec.closestDistance
    else
        -- Increase timer
        spec.warningTriggerTimer = spec.warningTriggerTimer + dt
        -- If distance increases again, reset timer and reference distance
        if spec.closestDistance > spec.warningTriggerDistance then
            spec.warningTriggerTimer = 0
            spec.warningTriggerDistance = spec.closestDistance
        end
    end

    -- Only play sound if 0.5s have passed and distance is still decreasing
    if spec.warningTriggerTimer >= 0.5 and spec.closestDistance < spec.warningTriggerDistance then
        spec.warningActive = true
        if self.isClient and spec.warningSound ~= nil then
            if not g_soundManager:getIsSamplePlaying(spec.warningSound) then
                g_soundManager:setSampleVolume(spec.warningSound, 1.0)
                g_soundManager:playSample(spec.warningSound)
            end
        end
        playAebAnimations(self, spec, "warning")
    else
        spec.warningActive = false
        if spec.warningSound ~= nil then
            g_soundManager:stopSample(spec.warningSound)
        end
    end

    spec.warningTimer = spec.warningTimer + dt
    updateAebAnimationTimers(self, spec, dt)
end

------------------------------------------------
-- Emergency Braking System
------------------------------------------------
function AutomaticEmergencyBraking:updateAebBraking(dt, isTurnSignal)
    local spec = self[AutomaticEmergencyBraking.SPEC]

    local _, brakeDist = computeDynamicDistances(spec.hitVehicle, spec.lastSpeed, isTurnSignal or false)

    if not spec.hitThisFrame or spec.closestDistance >= brakeDist then
        -- Restore brake force if it was doubled
        if spec.originalBrakeForce ~= nil then
            local motorSpec = self.spec_motorized
            if motorSpec ~= nil and motorSpec.motor ~= nil then
                motorSpec.motor.brakeForce = spec.originalBrakeForce
                spec.originalBrakeForce = nil
            end
        end
        spec.brakingActive = false
        spec.lastBrakeForce = 0
        return
    end

    -- Full emergency braking
    spec.brakingActive = true

    -- Double brake force for emergency braking
    local motorSpec = self.spec_motorized
    if motorSpec ~= nil and motorSpec.motor ~= nil then
        if spec.originalBrakeForce == nil then
            spec.originalBrakeForce = motorSpec.motor.brakeForce
            motorSpec.motor.brakeForce = motorSpec.motor.brakeForce * 3
        end
    end

    -- Play animations with BRAKE trigger
    playAebAnimations(self, spec, "brake")

    -- Disable cruise control when emergency braking
    if self.spec_drivable ~= nil then
        if self.spec_drivable.cruiseControl ~= nil then
            self.spec_drivable.cruiseControl.state = 0
        end
        -- Override player input: cancel acceleration, apply full brake
        if self.setAccelerationPedalInput ~= nil then
            self:setAccelerationPedalInput(0.0) -- Cancel gas input
        end
        if self.setBrakePedalInput ~= nil then
            self:setBrakePedalInput(1.0) -- Full braking (0.0 to 1.0)
        end
    end
    
    -- Update any scheduled animation reversals
    updateAebAnimationTimers(self, spec, dt)
end