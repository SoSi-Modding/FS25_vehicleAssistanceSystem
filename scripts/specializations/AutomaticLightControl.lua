--[[
    Automatic Light Control (ALC) - FS25
    --------------------------------
    Author: [SoSi] Janni1101
    Version: 1.0.0.1
    Date: 2026/02/13
    --------------------------------
    Copyright (c) SoSi-Modding, 2026

    This script may not be modified or used in other mods without permission by the author.
]]

source(Utils.getFilename("scripts/utils/SoSiLogger.lua", g_currentModDirectory))
local sosiLog = SoSiLogger.new(g_currentModName, "AutomaticLightControl.lua")

AutomaticLightControl = {}

AutomaticLightControl.MOD_NAME = g_currentModName
AutomaticLightControl.MOD_DIR = g_currentModDirectory
AutomaticLightControl.SPEC_NAME = "automaticLightControl"
AutomaticLightControl.SPEC = "spec_automaticLightControl"

-- Helper thresholds for weather conditions
local WEATHER_RAIN_THRESHOLD = 0.1
local WEATHER_SNOW_THRESHOLD = 0.1
local WEATHER_FOG_THRESHOLD = 0.1
local AHEAD_BLOCK_DIST = 50 -- meters: vehicle directly ahead blocks high-beam
local ONCOMING_BLOCK_DIST = 75 -- meters: oncoming traffic within this distance blocks high-beam

-- Raycast for high beam logic (ICC style)
local MAX_SENSOR_RANGE = 80
local SENSOR_WIDTH_FACTOR = 3 -- Wide enough to cover opposite lane
local RAYCAST_MASK = bit32.bor(CollisionFlag.VEHICLE, CollisionFlag.TRAFFIC_VEHICLE)

function AutomaticLightControl.prerequisitesPresent(specializations)
    return SpecializationUtil.hasSpecialization(Lights, specializations)
end

function AutomaticLightControl.initSpecialization()
    local schema = Vehicle.xmlSchema
    schema:setXMLSpecializationType(AutomaticLightControl.SPEC_NAME)
    schema:setXMLSpecializationType()

    -- Register savegame schema path for per-vehicle state
    local saveSchema = Vehicle.xmlSchemaSavegame
    if saveSchema ~= nil then
        local path = string.format("vehicles.vehicle(?).%s.automaticLightControl#lowBeamActive", AutomaticLightControl.MOD_NAME)
        saveSchema:register(XMLValueType.BOOL, path, "ALC low beam active state", true)
        path = string.format("vehicles.vehicle(?).%s.automaticLightControl#highBeamActive", AutomaticLightControl.MOD_NAME)
        saveSchema:register(XMLValueType.BOOL, path, "ALC high beam active state", true)
    end
end

function AutomaticLightControl.registerFunctions(vehicleType)
    SpecializationUtil.registerFunction(vehicleType, "alcRaycastCallback", AutomaticLightControl.alcRaycastCallback)
    SpecializationUtil.registerFunction(vehicleType, "updateAutomaticLightControl", AutomaticLightControl.updateAutomaticLightControl)
    SpecializationUtil.registerFunction(vehicleType, "actionEventToggleLowBeam", AutomaticLightControl.actionEventToggleLowBeam)
    SpecializationUtil.registerFunction(vehicleType, "actionEventToggleHighBeam", AutomaticLightControl.actionEventToggleHighBeam)
end

function AutomaticLightControl.registerEventListeners(vehicleType)
    SpecializationUtil.registerEventListener(vehicleType, "onPreLoad", AutomaticLightControl)
    SpecializationUtil.registerEventListener(vehicleType, "onLoad", AutomaticLightControl)
    SpecializationUtil.registerEventListener(vehicleType, "onUpdate", AutomaticLightControl)
    SpecializationUtil.registerEventListener(vehicleType, "onDelete", AutomaticLightControl)
    SpecializationUtil.registerEventListener(vehicleType, "onRegisterActionEvents", AutomaticLightControl)
    SpecializationUtil.registerEventListener(vehicleType, "onReadStream", AutomaticLightControl)
    SpecializationUtil.registerEventListener(vehicleType, "onWriteStream", AutomaticLightControl)
    SpecializationUtil.registerEventListener(vehicleType, "onReadUpdateStream", AutomaticLightControl)
    SpecializationUtil.registerEventListener(vehicleType, "onWriteUpdateStream", AutomaticLightControl)
end

function AutomaticLightControl:onPreLoad(savegame)
    -- Read saved state early from savegame vehicles.xml
    if savegame ~= nil and savegame.xmlFile ~= nil and savegame.key ~= nil then
        local xmlFile = savegame.xmlFile
        local key = savegame.key
        local modSection = "." .. AutomaticLightControl.MOD_NAME .. ".automaticLightControl#lowBeamActive"
        local baseKey
        if string.sub(key, -#modSection + 8) == ("." .. AutomaticLightControl.MOD_NAME .. ".automaticLightControl") then
            baseKey = key .. "#lowBeamActive"
        else
            baseKey = key .. "." .. AutomaticLightControl.MOD_NAME .. ".automaticLightControl#lowBeamActive"
        end
        local v = xmlFile:getValue(baseKey)
        if v ~= nil then
            self.__alcSavedLowBeamActive = v
        end
        
        -- High beam
        modSection = "." .. AutomaticLightControl.MOD_NAME .. ".automaticLightControl#highBeamActive"
        if string.sub(key, -#modSection + 8) == ("." .. AutomaticLightControl.MOD_NAME .. ".automaticLightControl") then
            baseKey = key .. "#highBeamActive"
        else
            baseKey = key .. "." .. AutomaticLightControl.MOD_NAME .. ".automaticLightControl#highBeamActive"
        end
        v = xmlFile:getValue(baseKey)
        if v ~= nil then
            self.__alcSavedHighBeamActive = v
        end
    end
end

function AutomaticLightControl:onLoad()
    local spec = {}
    self[AutomaticLightControl.SPEC] = spec
    spec.active = true
    spec.lowBeamControlActive = true  -- Default on
    spec.highBeamControlActive = false -- Default off
    spec.closestDistance = math.huge
    spec.hitThisFrame = false
    spec.vehicleLength = (self.size and self.size.length) or 5
    spec.vehicleWidth = (self.size and self.size.width) or 2.5
    spec.highBeamBlocked = false
    -- High-beam control state
    spec.highBeamOncomingTimer = 0 -- ms hysteresis for oncoming traffic
    spec.highBeamAheadTimer = 0    -- ms hysteresis for vehicle ahead
    spec.lastHighBeamState = false
    spec.hitOncomingThisFrame = false
    spec.isFogThisFrame = false
    spec.forwardDirX, spec.forwardDirY, spec.forwardDirZ = 0, 0, 1
    spec.oncomingClosestDistance = math.huge
    
    -- Input & net sync
    spec.actionEventIdToggleLowBeam = nil
    spec.actionEventIdToggleHighBeam = nil
    spec.actionEvents = {}
    spec.dirtyFlag = self:getNextDirtyFlag()
    
    -- Apply saved state if present
    if self.__alcSavedLowBeamActive ~= nil then
        spec.lowBeamControlActive = self.__alcSavedLowBeamActive
        self.__alcSavedLowBeamActive = nil
    end
    if self.__alcSavedHighBeamActive ~= nil then
        spec.highBeamControlActive = self.__alcSavedHighBeamActive
        self.__alcSavedHighBeamActive = nil
    end
end

function AutomaticLightControl:onDelete()
    -- Nothing to clean up
end

function AutomaticLightControl:onUpdate(dt)
    local spec = self[AutomaticLightControl.SPEC]
    if not spec or not spec.active then return end

    -- Only the root vehicle should drive automatic lighting logic.
    if self.getRootVehicle ~= nil and self:getRootVehicle() ~= self then
        return
    end

    -- Get lighting conditions from game environment
    local env = g_currentMission.environment
    local isNight = not env.isSunOn  -- Game's primary day/night flag
    
    -- Weather checks
    local weather = env.weather
    local isRain = weather and weather.getRainFallScale and weather:getRainFallScale() > WEATHER_RAIN_THRESHOLD
    local isSnow = weather and weather.getSnowFallScale and weather:getSnowFallScale() > WEATHER_SNOW_THRESHOLD
    local isFog = weather and weather.getFogScale and weather:getFogScale() > WEATHER_FOG_THRESHOLD
    local isHail = weather and weather.getIsHailing and weather:getIsHailing()
    local badWeather = isRain or isSnow or isFog or isHail

    -- Raycast for high beam logic (ICC style)
    spec.closestDistance = math.huge
    spec.hitThisFrame = false
    spec.hitOncomingThisFrame = false
    spec.isFogThisFrame = isFog
    spec.oncomingClosestDistance = math.huge
    if isNight then
        local x, y, z = getWorldTranslation(self.rootNode)
        local dx, dy, dz = localDirectionToWorld(self.rootNode, 0, 0, 1)
        local len = math.sqrt(dx*dx + dy*dy + dz*dz)
        if len > 0 then
            dx = dx / len
            dy = dy / len
            dz = dz / len
        end
        spec.forwardDirX, spec.forwardDirY, spec.forwardDirZ = dx, dy, dz
        -- start a bit further ahead to avoid hitting own front attachments
        local sensorStartDist = math.max(spec.vehicleLength * 0.6, 2.0)
        local sensorX = x + dx * sensorStartDist
        local sensorY = y + 1.5
        local sensorZ = z + dz * sensorStartDist
        local lateralDx, lateralDy, lateralDz = localDirectionToWorld(self.rootNode, 1, 0, 0)
        len = math.sqrt(lateralDx*lateralDx + lateralDy*lateralDy + lateralDz*lateralDz)
        if len > 0 then
            lateralDx = lateralDx / len
            lateralDy = lateralDy / len
            lateralDz = lateralDz / len
        end
        local sensorWidth = spec.vehicleWidth * SENSOR_WIDTH_FACTOR
        local rayCount = 5
        for i = 1, rayCount do
            local offsetFactor = (i - 1) / (rayCount - 1) - 0.5
            local rayLateralOffset = offsetFactor * sensorWidth
            local rayStartX = sensorX + lateralDx * rayLateralOffset
            local rayStartY = sensorY
            local rayStartZ = sensorZ + lateralDz * rayLateralOffset
            raycastAll(
                rayStartX, rayStartY, rayStartZ,
                dx, dy, dz,
                MAX_SENSOR_RANGE,
                "alcRaycastCallback",
                self,
                RAYCAST_MASK,
                true
            )
        end
    end

    -- Update hysteresis timers based on detections
    if spec.hitOncomingThisFrame and (spec.oncomingClosestDistance <= ONCOMING_BLOCK_DIST) then
        spec.highBeamOncomingTimer = 1500
    else
        spec.highBeamOncomingTimer = math.max((spec.highBeamOncomingTimer or 0) - dt, 0)
    end
    if spec.closestDistance < AHEAD_BLOCK_DIST then
        spec.highBeamAheadTimer = 800
    else
        spec.highBeamAheadTimer = math.max((spec.highBeamAheadTimer or 0) - dt, 0)
    end

    self:updateAutomaticLightControl(dt, isNight, badWeather)
end

function AutomaticLightControl:alcRaycastCallback(hitObjectId, x, y, z, distance)
    local spec = self[AutomaticLightControl.SPEC]
    
    -- Try multiple paths to find the vehicle object
    local obj = nil
    if g_currentMission and g_currentMission.nodeToObject then
        obj = g_currentMission.nodeToObject[hitObjectId]
        if obj == nil then
            local rootNode = getRootNode(hitObjectId)
            if rootNode ~= nil and rootNode ~= 0 then
                obj = g_currentMission.nodeToObject[rootNode]
            end
        end
        -- Also try parent nodes
        if obj == nil then
            local parent = getParent(hitObjectId)
            while parent ~= nil and parent ~= 0 do
                obj = g_currentMission.nodeToObject[parent]
                if obj ~= nil then break end
                parent = getParent(parent)
            end
        end
    end
    
    -- Ignore own vehicle and attachments
    if obj ~= nil and obj.getRootVehicle ~= nil then
        if obj:getRootVehicle() == self:getRootVehicle() then
            return
        end
    end
    
    spec.hitThisFrame = true
    if distance < spec.closestDistance then
        spec.closestDistance = distance
    end
    
    -- Oncoming detection via forward vector dot product
    if obj ~= nil and obj.rootNode ~= nil then
        local otherNode = obj.rootNode
        local odx, ody, odz = localDirectionToWorld(otherNode, 0, 0, 1)
        local lenO = math.sqrt(odx*odx + ody*ody + odz*odz)
        if lenO > 0 then 
            odx, ody, odz = odx/lenO, ody/lenO, odz/lenO
            local dot = odx*spec.forwardDirX + ody*spec.forwardDirY + odz*spec.forwardDirZ
            -- More lenient threshold for oncoming detection
            if dot < -0.3 then
                spec.hitOncomingThisFrame = true
                if distance < spec.oncomingClosestDistance then
                    spec.oncomingClosestDistance = distance
                end
            end
        end
    end
end

function AutomaticLightControl:updateAutomaticLightControl(dt, isNight, badWeather)
    local spec = self[AutomaticLightControl.SPEC]
    local lightsSpec = self.spec_lights
    if not lightsSpec then return end

    -- Only override light state if automatic control is active
    if not spec.lowBeamControlActive and not spec.highBeamControlActive then
        return -- Don't override anything if both are off
    end

    -- Check if lights should be enabled (electrics on / ignition on)
    local lightsEnabled = false
    local motorizedSpec = self.spec_motorized
    if motorizedSpec ~= nil then
        -- Lights are enabled when motor state is at least IGNITION (not OFF)
        lightsEnabled = motorizedSpec.motorState ~= MotorState.OFF
    end

    -- Get current light state (might be manually set by user)
    local currentMask = lightsSpec.lightsTypesMask or 0
    local desiredMask = currentMask

    -- Only override low beam if automatic control is active AND conditions require automatic action
    if spec.lowBeamControlActive then
        local needLowBeam = lightsEnabled and (isNight or badWeather)
        local lowBeamMask = lightsSpec.automaticLightsTypesMask or 0
        local hasLowBeam = bit32.band(currentMask, lowBeamMask) ~= 0
        
        -- Automatically turn lights on when needed, and turn them off when not needed
        if needLowBeam and not hasLowBeam then
            desiredMask = bit32.bor(desiredMask, lowBeamMask)
        elseif not needLowBeam and hasLowBeam then
            desiredMask = bit32.band(desiredMask, bit32.bnot(lowBeamMask))
        end
    end
    
    -- Only override high beam if automatic control is active
    if spec.highBeamControlActive then
        local needHighBeam = lightsEnabled and isNight and (not badWeather) and (spec.highBeamOncomingTimer <= 0) and (spec.highBeamAheadTimer <= 0)
        local highBeamType = Lights.LIGHT_TYPE_HIGHBEAM or 2
        local highBeamBit = 2^highBeamType
        if needHighBeam then
            desiredMask = bit32.bor(desiredMask, highBeamBit)
        else
            desiredMask = bit32.band(desiredMask, bit32.bnot(highBeamBit))
        end
    end

    if desiredMask ~= currentMask then
        self:setLightsTypesMask(desiredMask)
    end
    spec.lastHighBeamState = spec.highBeamControlActive and lightsEnabled and isNight and (not badWeather) and (spec.highBeamOncomingTimer <= 0) and (spec.highBeamAheadTimer <= 0)
end

-- Register input toggles when the vehicle is active for input
function AutomaticLightControl:onRegisterActionEvents(isActiveForInput, isActiveForInputIgnoreSelection)
    if self.isClient then
        local spec = self[AutomaticLightControl.SPEC]
        if spec == nil then return end

        self:clearActionEventsTable(spec.actionEvents)

        -- Register hotkeys if vehicle is active for input, or as fallback for vehicles that might not support isActiveForInput
        if isActiveForInput or isActiveForInputIgnoreSelection then
            -- Low beam toggle
            local _, actionEventId = g_inputBinding:registerActionEvent(
                InputAction.VAS_TOGGLE_AUTOMATIC_LOWBEAM,
                self,
                AutomaticLightControl.actionEventToggleLowBeam,
                false,
                true,
                false,
                true
            )

            if actionEventId ~= nil then
                spec.actionEventIdToggleLowBeam = actionEventId
                local text = g_i18n and g_i18n:getText("input_VAS_TOGGLE_AUTOMATIC_LOWBEAM") or "Toggle Automatic Low Beam"
                g_inputBinding:setActionEventText(actionEventId, text)
                g_inputBinding:setActionEventTextPriority(actionEventId, GS_PRIO_NORMAL)
                table.insert(spec.actionEvents, actionEventId)
            end

            -- High beam toggle
            _, actionEventId = g_inputBinding:registerActionEvent(
                InputAction.VAS_TOGGLE_AUTOMATIC_HIGHBEAM,
                self,
                AutomaticLightControl.actionEventToggleHighBeam,
                false,
                true,
                false,
                true
            )

            if actionEventId ~= nil then
                spec.actionEventIdToggleHighBeam = actionEventId
                local text = g_i18n and g_i18n:getText("input_VAS_TOGGLE_AUTOMATIC_HIGHBEAM") or "Toggle Automatic High Beam"
                g_inputBinding:setActionEventText(actionEventId, text)
                g_inputBinding:setActionEventTextPriority(actionEventId, GS_PRIO_NORMAL)
                table.insert(spec.actionEvents, actionEventId)
            end
        end
    end
end

-- Low beam toggle handler
function AutomaticLightControl:actionEventToggleLowBeam()
    local spec = self[AutomaticLightControl.SPEC]
    if spec == nil then return end

    spec.lowBeamControlActive = not spec.lowBeamControlActive

    -- User feedback
    local msg = spec.lowBeamControlActive and (g_i18n and g_i18n:getText("vas_notification_automaticLowBeam_enabled") or "ALC Low Beam: Enabled")
                    or (g_i18n and g_i18n:getText("vas_notification_automaticLowBeam_disabled") or "ALC Low Beam: Disabled")
    if g_currentMission and g_currentMission.addIngameNotification ~= nil then
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_INFO, msg)
    elseif sosiLog then
        sosiLog:info("%s", msg)
    end

    -- MP sync
    self:raiseDirtyFlags(spec.dirtyFlag)
end

-- High beam toggle handler
function AutomaticLightControl:actionEventToggleHighBeam()
    local spec = self[AutomaticLightControl.SPEC]
    if spec == nil then return end

    spec.highBeamControlActive = not spec.highBeamControlActive

    -- User feedback
    local msg = spec.highBeamControlActive and (g_i18n and g_i18n:getText("vas_notification_automaticHighBeam_enabled") or "ALC High Beam: Enabled")
                    or (g_i18n and g_i18n:getText("vas_notification_automaticHighBeam_disabled") or "ALC High Beam: Disabled")
    if g_currentMission and g_currentMission.addIngameNotification ~= nil then
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_INFO, msg)
    elseif sosiLog then
        sosiLog:info("%s", msg)
    end

    -- MP sync
    self:raiseDirtyFlags(spec.dirtyFlag)
end

-- Save per-vehicle state into vehicles.xml
function AutomaticLightControl:saveToXMLFile(xmlFile, key)
    local spec = self[AutomaticLightControl.SPEC]
    if spec == nil then return end
    local modSection = "." .. AutomaticLightControl.MOD_NAME .. ".automaticLightControl"
    local baseKey
    if string.sub(key, -#modSection) == modSection then
        baseKey = key .. "#lowBeamActive"
    else
        baseKey = key .. modSection .. "#lowBeamActive"
    end
    xmlFile:setValue(baseKey, spec.lowBeamControlActive)
    
    -- High beam
    if string.sub(key, -#modSection) == modSection then
        baseKey = key .. "#highBeamActive"
    else
        baseKey = key .. modSection .. "#highBeamActive"
    end
    xmlFile:setValue(baseKey, spec.highBeamControlActive)
end

-- Load per-vehicle state from vehicles.xml
function AutomaticLightControl:loadFromXMLFile(xmlFile, key)
    local spec = self[AutomaticLightControl.SPEC]
    if spec == nil then return end
    local modSection = "." .. AutomaticLightControl.MOD_NAME .. ".automaticLightControl"
    local baseKey
    if string.sub(key, -#modSection) == modSection then
        baseKey = key .. "#lowBeamActive"
    else
        baseKey = key .. modSection .. "#lowBeamActive"
    end
    local v = xmlFile:getValue(baseKey)
    if v ~= nil then
        spec.lowBeamControlActive = v
    end
    
    -- High beam
    if string.sub(key, -#modSection) == modSection then
        baseKey = key .. "#highBeamActive"
    else
        baseKey = key .. modSection .. "#highBeamActive"
    end
    v = xmlFile:getValue(baseKey)
    if v ~= nil then
        spec.highBeamControlActive = v
    end
end

-- Initial state sync
function AutomaticLightControl:onWriteStream(streamId, connection)
    local spec = self[AutomaticLightControl.SPEC]
    if spec == nil then return end
    streamWriteBool(streamId, spec.lowBeamControlActive)
    streamWriteBool(streamId, spec.highBeamControlActive)
end

function AutomaticLightControl:onReadStream(streamId, connection)
    local spec = self[AutomaticLightControl.SPEC]
    if spec == nil then return end
    spec.lowBeamControlActive = streamReadBool(streamId)
    spec.highBeamControlActive = streamReadBool(streamId)
end

-- Delta MP sync when toggled
function AutomaticLightControl:onWriteUpdateStream(streamId, connection, dirtyMask)
    local spec = self[AutomaticLightControl.SPEC]
    if spec == nil then return end
    local has = bitAND(dirtyMask, spec.dirtyFlag) ~= 0
    streamWriteBool(streamId, has)
    if has then
        streamWriteBool(streamId, spec.lowBeamControlActive)
        streamWriteBool(streamId, spec.highBeamControlActive)
    end
end

function AutomaticLightControl:onReadUpdateStream(streamId, timestamp, connection)
    local spec = self[AutomaticLightControl.SPEC]
    if spec == nil then return end
    if streamReadBool(streamId) then
        spec.lowBeamControlActive = streamReadBool(streamId)
        spec.highBeamControlActive = streamReadBool(streamId)
    end
end