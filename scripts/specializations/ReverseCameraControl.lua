--[[
    Reverse Camera Control (RCC) - FS25
    --------------------------------
    Author: [SoSi] Benny
    Version: 1.0.0.1
    Date: 2026/02/12
    --------------------------------
    Copyright (c) SoSi-Modding, 2026

    This script may not be modified or used in other mods without permission by the author.
]]

source(Utils.getFilename("scripts/utils/SoSiLogger.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/events/RCCSetCameraStateEvent.lua", g_currentModDirectory))
local sosiLog = SoSiLogger.new(g_currentModName, "ReverseCameraControl.lua")

ReverseCameraControl = {}

ReverseCameraControl.MOD_NAME = g_currentModName

function ReverseCameraControl.prerequisitesPresent(specializations)
    return SpecializationUtil.hasSpecialization(Motorized, specializations)
        and SpecializationUtil.hasSpecialization(Drivable, specializations)
        and SpecializationUtil.hasSpecialization(Enterable, specializations)
end

function ReverseCameraControl.initSpecialization()
    local schema = Vehicle.xmlSchema
    schema:setXMLSpecializationType("ReverseCameraControl")
    
    schema:register(XMLValueType.FLOAT, "vehicle.vehicleAssistanceSystem.reverseCameraActive.cameraVisibility(?)#maxForwardSpeed", "Max forward speed km/h")
    schema:register(XMLValueType.STRING, "vehicle.vehicleAssistanceSystem.reverseCameraActive.cameraVisibility(?)#animation", "Animation name (optional)")
    schema:register(XMLValueType.NODE_INDEX, "vehicle.vehicleAssistanceSystem.reverseCameraActive.cameraVisibility(?).node(?)#node", "Node(s) that will be shown/hidden")
    schema:register(XMLValueType.BOOL, "vehicle.animations.animation(?)#removeWithRCC", "Animation will be taken over by RCC script")

    schema:setXMLSpecializationType()
end

function ReverseCameraControl.registerEventListeners(vehicleType)
    SpecializationUtil.registerEventListener(vehicleType, "onPreLoad", ReverseCameraControl)
    SpecializationUtil.registerEventListener(vehicleType, "onLoad", ReverseCameraControl)
    SpecializationUtil.registerEventListener(vehicleType, "onPostLoad", ReverseCameraControl)
    SpecializationUtil.registerEventListener(vehicleType, "onReadStream", ReverseCameraControl)
    SpecializationUtil.registerEventListener(vehicleType, "onWriteStream", ReverseCameraControl)
    SpecializationUtil.registerEventListener(vehicleType, "onUpdateTick", ReverseCameraControl)
end

function ReverseCameraControl.registerFunctions(vehicleType)
    SpecializationUtil.registerFunction(vehicleType, "removeConflictingAnimations", ReverseCameraControl.removeConflictingAnimations)
    SpecializationUtil.registerFunction(vehicleType, "setReverseCameraState", ReverseCameraControl.setReverseCameraState)
end

function ReverseCameraControl:onPreLoad(savegame)
    self.spec_reverseCameraControl = {
        reverseCameraActive = {},
        conflictingAnimations = {},
        isReverseCameraVisible = false  -- Shared state for ReverseCameraGuidelines
    }
end

function ReverseCameraControl:onLoad(savegame)
    local i = 0
    while true do
        local key = string.format("vehicle.vehicleAssistanceSystem.reverseCameraActive.cameraVisibility(%d)", i)

        local maxSpeed = self.xmlFile:getValue(key .. "#maxForwardSpeed")
        if maxSpeed == nil then
            break
        end

        local animName = self.xmlFile:getValue(key .. "#animation")

        local nodes = {}
        local n = 0
        while true do
            local nodeKey = string.format("%s.node(%d)#node", key, n)
            local node = self.xmlFile:getValue(nodeKey, nil, self.components, self.i3dMappings)
            if node == nil then
                break
            end
            table.insert(nodes, node)
            n = n + 1
        end

        table.insert(self.spec_reverseCameraControl.reverseCameraActive, {
            animation = animName,
            nodes = nodes,
            maxForwardSpeed = maxSpeed,
            isActive = false,
            wasReverseActive = false
        })

        if animName ~= nil then
            self:setAnimationTime(animName, 0, true)
        end

        for _, node in ipairs(nodes) do
            setVisibility(node, false)
        end

        i = i + 1
    end
end

function ReverseCameraControl:onPostLoad(savegame)
    self:removeConflictingAnimations()
    
    local spec = self.spec_reverseCameraControl
    for _, animName in ipairs(spec.conflictingAnimations) do
        if self.spec_animatedVehicle ~= nil and self.spec_animatedVehicle.animations ~= nil then
            local anim = self.spec_animatedVehicle.animations[animName]
            if anim ~= nil then
                anim.parts = {}
            end
        end
    end
end

function ReverseCameraControl:onWriteStream(streamId, connection)
    local spec = self.spec_reverseCameraControl
    if spec == nil then
        return
    end
    
    local count = #spec.reverseCameraActive
    streamWriteUInt8(streamId, count)
    
    for i = 1, count do
        local cam = spec.reverseCameraActive[i]
        streamWriteBool(streamId, cam.isActive)
        streamWriteBool(streamId, cam.wasReverseActive)
    end
end

function ReverseCameraControl:onReadStream(streamId, connection)
    local spec = self.spec_reverseCameraControl
    if spec == nil then
        return
    end
    
    local count = streamReadUInt8(streamId)
    for index = 1, count do
        local isActive = streamReadBool(streamId)
        local wasReverseActive = streamReadBool(streamId)
        local cam = spec.reverseCameraActive[index]
        if cam ~= nil then
            if isActive ~= cam.isActive or wasReverseActive ~= cam.wasReverseActive then
                self:setReverseCameraState(index, isActive, wasReverseActive, true)
            end
        end
    end
end

function ReverseCameraControl:removeConflictingAnimations()
    if self.xmlFile == nil then
        return
    end
    
    local spec = self.spec_reverseCameraControl
    
    local animIndex = 0
    while true do
        local animKey = string.format("vehicle.animations.animation(%d)", animIndex)
        local animName = self.xmlFile:getValue(animKey .. "#name")
        
        if animName == nil then
            break
        end
        
        local removeWithRCC = self.xmlFile:getValue(animKey .. "#removeWithRCC", false)
        
        if removeWithRCC then
            sosiLog:devInfo("[%s] Animation '%s' with RCC flag found - will be deactivated", self.xmlFile.filename, animName)
            table.insert(spec.conflictingAnimations, animName)
        end
        
        animIndex = animIndex + 1
    end
end

function ReverseCameraControl:setReverseCameraState(cameraIndex, isActive, wasReverseActive, noEventSend)
    local spec = self.spec_reverseCameraControl
    if spec == nil or spec.reverseCameraActive == nil then
        return
    end
    
    local cam = spec.reverseCameraActive[cameraIndex]
    if cam == nil then
        return
    end
    
    if isActive == nil or wasReverseActive == nil then
        return
    end
    
    RCCSetCameraStateEvent.sendEvent(self, cameraIndex, isActive, wasReverseActive, noEventSend)
    
    cam.isActive = isActive
    cam.wasReverseActive = wasReverseActive
    
    if cam.animation ~= nil then
        if isActive then
            self:playAnimation(cam.animation, 1, self:getAnimationTime(cam.animation), true)
        else
            self:setAnimationTime(cam.animation, 0, true)
        end
    end
    
    for _, node in ipairs(cam.nodes) do
        setVisibility(node, isActive)
    end
    
    -- Update global visibility state for ReverseCameraGuidelines compatibility
    spec.isReverseCameraVisible = false
    for _, camera in ipairs(spec.reverseCameraActive) do
        if camera.isActive then
            spec.isReverseCameraVisible = true
            break
        end
    end
end

function ReverseCameraControl:onUpdateTick(dt)
    local spec = self.spec_reverseCameraControl
    
    -- Only run on server or in single player
    if not self.isServer then
        return
    end
    
    local motor = self.getMotor ~= nil and self:getMotor() or nil
    local speed = self:getLastSpeed()
    local speedKmh = math.abs(speed)
    local drivingDir = 0

    if motor ~= nil then
        if motor.getDrivingDirection ~= nil then
            drivingDir = motor:getDrivingDirection()
        elseif motor.currentDirection ~= nil then
            drivingDir = motor.currentDirection
        end
    end

    if drivingDir == 0 and self.nextMovingDirection ~= nil and self.nextMovingDirection ~= 0 then
        drivingDir = self.nextMovingDirection
    end

    if drivingDir == 0 and self.movingDirection ~= nil and self.movingDirection ~= 0 then
        drivingDir = self.movingDirection
    end

    if drivingDir == 0 and self.getAxisForward ~= nil then
        local axisForward = self:getAxisForward()
        if axisForward ~= nil then
            if axisForward < -0.05 then
                drivingDir = -1
            elseif axisForward > 0.05 then
                drivingDir = 1
            end
        end
    end

    for index, cam in ipairs(spec.reverseCameraActive) do
        local shouldBeActive = false
        local newWasReverseActive = cam.wasReverseActive

        if motor ~= nil and self:getIsMotorStarted() then
            if drivingDir < 0 then
                newWasReverseActive = true
                shouldBeActive = true
            elseif drivingDir > 0 then
                if cam.wasReverseActive then
                    if speedKmh <= cam.maxForwardSpeed then
                        shouldBeActive = true
                    else
                        newWasReverseActive = false
                    end
                end
            end
        else
            newWasReverseActive = false
        end

        if shouldBeActive ~= cam.isActive or newWasReverseActive ~= cam.wasReverseActive then
            self:setReverseCameraState(index, shouldBeActive, newWasReverseActive, false)
        end
    end
end