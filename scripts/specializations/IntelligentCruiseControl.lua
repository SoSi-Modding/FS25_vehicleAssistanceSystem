--[[
    Intelligent Cruise Control (ICC) - FS25
    --------------------------------
    Author: [SoSi] Janni1101
    Version: 1.0.0.1
    Date: 2026/02/12
    --------------------------------
    Copyright (c) SoSi-Modding, 2026

    This script may not be modified or used in other mods without permission by the author.
]]

source(Utils.getFilename("scripts/utils/SoSiLogger.lua", g_currentModDirectory))
local sosiLog = SoSiLogger.new(g_currentModName, "IntelligentCruiseControl.lua")

IntelligentCruiseControl = {}

IntelligentCruiseControl.MOD_NAME = g_currentModName
IntelligentCruiseControl.MOD_DIR = g_currentModDirectory
IntelligentCruiseControl.SPEC_NAME = "intelligentCruiseControl"
IntelligentCruiseControl.SPEC = "spec_intelligentCruiseControl"

-- ICC Activation threshold
local MIN_SPEED_FORWARD = 10 -- km/h
local BASE_FOLLOW_DISTANCE = 16 -- meters
local MAX_SENSOR_RANGE = 80 -- meters
local SENSOR_WIDTH_FACTOR = 1.2

local RAYCAST_MASK = 
    CollisionFlag.VEHICLE + 
    CollisionFlag.TRAFFIC_VEHICLE

-- Dynamic following distance based on speed (simple linear scaling)
local function computeDynamicFollowDistance(speedKmh)
    local minDist = BASE_FOLLOW_DISTANCE
    local maxDist = 55 -- allow more margin at high speed
    local v = math.max(speedKmh or 0, 0)
    -- 2.0s rule: distance = speed (m/s) * 2.0 (earlier reaction)
    local dist = v / 3.6 * 2.0
    dist = math.max(minDist, math.min(dist, maxDist))
    return dist
end

function IntelligentCruiseControl.prerequisitesPresent(specializations)
    return SpecializationUtil.hasSpecialization(Motorized, specializations)
        and SpecializationUtil.hasSpecialization(Drivable, specializations)
        and SpecializationUtil.hasSpecialization(Enterable, specializations)
end

function IntelligentCruiseControl.initSpecialization()
    local schema = Vehicle.xmlSchema
    schema:setXMLSpecializationType(IntelligentCruiseControl.SPEC_NAME)
    schema:setXMLSpecializationType()

    -- Register savegame schema path for per-vehicle state
    local saveSchema = Vehicle.xmlSchemaSavegame
    if saveSchema ~= nil then
        local path = string.format("vehicles.vehicle(?).%s.intelligentCruiseControl#active", IntelligentCruiseControl.MOD_NAME)
        saveSchema:register(XMLValueType.BOOL, path, "ICC active state", true)
    end
end

function IntelligentCruiseControl.registerFunctions(vehicleType)
    SpecializationUtil.registerFunction(vehicleType, "iccRaycastCallback", IntelligentCruiseControl.iccRaycastCallback)
    SpecializationUtil.registerFunction(vehicleType, "updateIccControl", IntelligentCruiseControl.updateIccControl)
    SpecializationUtil.registerFunction(vehicleType, "actionEventToggleICC", IntelligentCruiseControl.actionEventToggleICC)
end

function IntelligentCruiseControl.registerEventListeners(vehicleType)
    SpecializationUtil.registerEventListener(vehicleType, "onPreLoad", IntelligentCruiseControl)
    SpecializationUtil.registerEventListener(vehicleType, "onLoad", IntelligentCruiseControl)
    SpecializationUtil.registerEventListener(vehicleType, "onUpdate", IntelligentCruiseControl)
    SpecializationUtil.registerEventListener(vehicleType, "onDelete", IntelligentCruiseControl)
    SpecializationUtil.registerEventListener(vehicleType, "onRegisterActionEvents", IntelligentCruiseControl)
    SpecializationUtil.registerEventListener(vehicleType, "onReadStream", IntelligentCruiseControl)
    SpecializationUtil.registerEventListener(vehicleType, "onWriteStream", IntelligentCruiseControl)
    SpecializationUtil.registerEventListener(vehicleType, "onReadUpdateStream", IntelligentCruiseControl)
    SpecializationUtil.registerEventListener(vehicleType, "onWriteUpdateStream", IntelligentCruiseControl)
end

function IntelligentCruiseControl:onPreLoad(savegame)
    -- Read saved state early from savegame vehicles.xml
    if savegame ~= nil and savegame.xmlFile ~= nil and savegame.key ~= nil then
        local xmlFile = savegame.xmlFile
        local key = savegame.key
        local modSection = "." .. IntelligentCruiseControl.MOD_NAME .. ".intelligentCruiseControl#active"
        local baseKey
        if string.sub(key, -#modSection + 8) == ("." .. IntelligentCruiseControl.MOD_NAME .. ".intelligentCruiseControl") then
            baseKey = key .. "#active"
        else
            baseKey = key .. "." .. IntelligentCruiseControl.MOD_NAME .. ".intelligentCruiseControl#active"
        end
        local v = xmlFile:getValue(baseKey)
        if v ~= nil then
            self.__iccSavedActive = v
        end
    end
end

function IntelligentCruiseControl:onLoad()
    local spec = {}
    self[IntelligentCruiseControl.SPEC] = spec
    spec.vehicle = self

    -- ICC defaults to active, overridden by savegame
    spec.active = true
    spec.closestDistance = math.huge
    spec.hitThisFrame = false
    spec.lastSpeed = 0
    spec.vehicleLength = (self.size and self.size.length) or 5
    spec.vehicleWidth = (self.size and self.size.width) or 2.5
    spec.originalCruiseSpeed = nil
    spec.cruiseReduced = false

    -- Input & net sync
    spec.actionEventIdToggle = nil
    spec.actionEvents = {}
    spec.dirtyFlag = self:getNextDirtyFlag()

    -- Apply saved state if present
    if self.__iccSavedActive ~= nil then
        spec.active = self.__iccSavedActive
        self.__iccSavedActive = nil
    end
end

function IntelligentCruiseControl:onDelete()
    -- Nothing to clean up for now
end

function IntelligentCruiseControl:onUpdate(dt)
    local spec = self[IntelligentCruiseControl.SPEC]
    if spec == nil or not spec.active then return end

    -- Get current speed
    local lastSpeed = 0
    if self.getLastSpeed ~= nil then
        lastSpeed = self:getLastSpeed()
    end
    spec.lastSpeed = lastSpeed

    -- Only active when moving forward at min speed and cruise control is on
    local motor = self.getMotor ~= nil and self:getMotor() or nil
    local drivingDir = 0
    if motor ~= nil and motor.currentDirection ~= nil then
        drivingDir = motor.currentDirection
    end
    if drivingDir <= 0 or lastSpeed < MIN_SPEED_FORWARD then
        -- Restore cruise speed if needed
        if spec.cruiseReduced and self.spec_drivable and self.spec_drivable.cruiseControl then
            if spec.originalCruiseSpeed then
                self.spec_drivable.cruiseControl.speed = spec.originalCruiseSpeed
            end
            spec.cruiseReduced = false
        end
        return
    end

    -- Frame reset
    spec.closestDistance = math.huge
    spec.hitThisFrame = false

    -- Sensor logic (front raycast, similar to AEB)
    local x, y, z = getWorldTranslation(self.rootNode)
    local dx, dy, dz = localDirectionToWorld(self.rootNode, 0, 0, 1)
    local len = math.sqrt(dx*dx + dy*dy + dz*dz)
    if len > 0 then
        dx = dx / len
        dy = dy / len
        dz = dz / len
    end
    local sensorStartDist = spec.vehicleLength * 0.4
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
    local rayCount = 5 -- more rays for wider detection
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
            "iccRaycastCallback",
            self,
            RAYCAST_MASK,
            true
        )
    end

    self:updateIccControl(dt)
end

function IntelligentCruiseControl:iccRaycastCallback(hitObjectId, x, y, z, distance)
    if getRootNode(hitObjectId) == self.rootNode then return end

    local obj = nil
    if g_currentMission and g_currentMission.nodeToObject then
        obj = g_currentMission.nodeToObject[hitObjectId]
        if obj == nil then
            local rootNode = getRootNode(hitObjectId)
            if rootNode ~= nil and rootNode ~= 0 then
                obj = g_currentMission.nodeToObject[rootNode]
            end
        end

        if obj == nil then
            local parent = getParent(hitObjectId)
            while parent ~= nil and parent ~= 0 do
                obj = g_currentMission.nodeToObject[parent]
                if obj ~= nil then break end
                parent = getParent(parent)
            end
        end
    end

    if obj ~= nil and obj.getRootVehicle ~= nil and self.getRootVehicle ~= nil then
        if obj:getRootVehicle() == self:getRootVehicle() then
            return
        end
    end

    local spec = self[IntelligentCruiseControl.SPEC]
    spec.hitThisFrame = true
    if distance < spec.closestDistance then
        spec.closestDistance = distance
    end
end

function IntelligentCruiseControl:updateIccControl(dt)
    local spec = self[IntelligentCruiseControl.SPEC]
    if not spec.hitThisFrame then
        -- No vehicle ahead: restore cruise speed if it was reduced
        if spec.cruiseReduced and self.spec_drivable and self.spec_drivable.cruiseControl then
            if spec.originalCruiseSpeed then
                self.spec_drivable.cruiseControl.speed = spec.originalCruiseSpeed
            end
            spec.cruiseReduced = false
        end
        return
    end

    local followDist = computeDynamicFollowDistance(spec.lastSpeed)
    if spec.closestDistance < followDist then
        -- Too close: reduce cruise speed only (never below 10 km/h)
        if self.spec_drivable and self.spec_drivable.cruiseControl then
            if not spec.cruiseReduced then
                spec.originalCruiseSpeed = self.spec_drivable.cruiseControl.speed
                spec.cruiseReduced = true
            end
            -- Reduce cruise speed to match safe distance (proportional, min 10 km/h)
            local safeSpeed = math.max(10, (spec.closestDistance / followDist) * spec.originalCruiseSpeed)
            -- Only reduce, never increase above original
            safeSpeed = math.min(safeSpeed, spec.originalCruiseSpeed)
            self.spec_drivable.cruiseControl.speed = safeSpeed
        end
    else
        -- Safe: restore cruise speed if reduced
        if spec.cruiseReduced and self.spec_drivable and self.spec_drivable.cruiseControl then
            if spec.originalCruiseSpeed then
                self.spec_drivable.cruiseControl.speed = spec.originalCruiseSpeed
            end
            spec.cruiseReduced = false
        end
    end
end

-- Register input toggle when the vehicle is active for input
function IntelligentCruiseControl:onRegisterActionEvents(isActiveForInput, isActiveForInputIgnoreSelection)
    if self.isClient then
        local spec = self[IntelligentCruiseControl.SPEC]
        if spec == nil then return end

        self:clearActionEventsTable(spec.actionEvents)

        -- Register hotkey if vehicle is active for input, or as fallback for vehicles that might not support isActiveForInput
        if isActiveForInput or isActiveForInputIgnoreSelection then
            local _, actionEventId = g_inputBinding:registerActionEvent(
                InputAction.VAS_TOGGLE_INTELLIGENT_CRUISE_CONTROL,
                self,
                IntelligentCruiseControl.actionEventToggleICC,
                false,
                true,
                false,
                true
            )

            if actionEventId ~= nil then
                spec.actionEventIdToggle = actionEventId
                local text = g_i18n and g_i18n:getText("input_VAS_TOGGLE_INTELLIGENT_CRUISE_CONTROL") or "Toggle Intelligent Cruise Control"
                g_inputBinding:setActionEventText(actionEventId, text)
                g_inputBinding:setActionEventTextPriority(actionEventId, GS_PRIO_NORMAL)
                table.insert(spec.actionEvents, actionEventId)
            end
        end
    end
end

-- Toggle handler
function IntelligentCruiseControl:actionEventToggleICC()
    local spec = self[IntelligentCruiseControl.SPEC]
    if spec == nil then return end

    spec.active = not spec.active

    -- If disabling while cruise was reduced, restore immediately
    if not spec.active and spec.cruiseReduced and self.spec_drivable and self.spec_drivable.cruiseControl then
        if spec.originalCruiseSpeed then
            self.spec_drivable.cruiseControl.speed = spec.originalCruiseSpeed
        end
        spec.cruiseReduced = false
    end

    -- Small user feedback
    local msg = spec.active and (g_i18n and g_i18n:getText("vas_notification_intelligentCruiseControl_enabled") or "ICC: Enabled")
                    or (g_i18n and g_i18n:getText("vas_notification_intelligentCruiseControl_disabled") or "ICC: Disabled")
    if g_currentMission and g_currentMission.addIngameNotification ~= nil then
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_INFO, msg)
    elseif sosiLog then
        sosiLog:info("%s", msg)
    end

    -- MP sync
    self:raiseDirtyFlags(spec.dirtyFlag)
end

-- Save per-vehicle state into vehicles.xml
function IntelligentCruiseControl:saveToXMLFile(xmlFile, key)
    local spec = self[IntelligentCruiseControl.SPEC]
    if spec == nil then return end
    local modSection = "." .. IntelligentCruiseControl.MOD_NAME .. ".intelligentCruiseControl"
    local baseKey
    if string.sub(key, -#modSection) == modSection then
        baseKey = key .. "#active"
    else
        baseKey = key .. modSection .. "#active"
    end
    xmlFile:setValue(baseKey, spec.active)
end

-- Load per-vehicle state from vehicles.xml
function IntelligentCruiseControl:loadFromXMLFile(xmlFile, key)
    local spec = self[IntelligentCruiseControl.SPEC]
    if spec == nil then return end
    local modSection = "." .. IntelligentCruiseControl.MOD_NAME .. ".intelligentCruiseControl"
    local baseKey
    if string.sub(key, -#modSection) == modSection then
        baseKey = key .. "#active"
    else
        baseKey = key .. modSection .. "#active"
    end
    local v = xmlFile:getValue(baseKey)
    if v ~= nil then
        spec.active = v
    end
end

-- Initial state sync
function IntelligentCruiseControl:onWriteStream(streamId, connection)
    local spec = self[IntelligentCruiseControl.SPEC]
    if spec == nil then return end
    streamWriteBool(streamId, spec.active)
end

function IntelligentCruiseControl:onReadStream(streamId, connection)
    local spec = self[IntelligentCruiseControl.SPEC]
    if spec == nil then return end
    spec.active = streamReadBool(streamId)
end

-- Delta MP sync when toggled
function IntelligentCruiseControl:onWriteUpdateStream(streamId, connection, dirtyMask)
    local spec = self[IntelligentCruiseControl.SPEC]
    if spec == nil then return end
    local has = bitAND(dirtyMask, spec.dirtyFlag) ~= 0
    streamWriteBool(streamId, has)
    if has then
        streamWriteBool(streamId, spec.active)
    end
end

function IntelligentCruiseControl:onReadUpdateStream(streamId, timestamp, connection)
    local spec = self[IntelligentCruiseControl.SPEC]
    if spec == nil then return end
    if streamReadBool(streamId) then
        spec.active = streamReadBool(streamId)
    end
end