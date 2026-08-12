--[[
    Parking Distance Control (PDC) - FS25
    --------------------------------
    Author: [SoSi] Benny & [SoSi] Janni1101
    Version: 1.0.0.0
    Date: 2026/01/08
    --------------------------------
    Copyright (c) SoSi-Modding, 2026

    This script may not be modified or used in other mods without permission by the author.
]]

source(Utils.getFilename("scripts/utils/SoSiLogger.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/MenuManager.lua", g_currentModDirectory))
local sosiLog = SoSiLogger.new(g_currentModName, "ParkingDistanceControl.lua")

ParkingDistanceControl = {}

ParkingDistanceControl.MOD_NAME = g_currentModName
ParkingDistanceControl.MOD_DIR = g_currentModDirectory
ParkingDistanceControl.SPEC_NAME = "parkingDistanceControl"
ParkingDistanceControl.SPEC      = "spec_parkingDistanceControl"
ParkingDistanceControl.SETTINGS_XML = ParkingDistanceControl.MOD_DIR .. "shared/vehicleAssistanceSystemSettings.xml"
ParkingDistanceControl.SETTINGS_SCHEMA = XMLSchema.new("parkingDistanceControlSettings")

local FRONT_MOVE_THRESHOLD = 0.1 -- minimal speed to consider forward motion armed
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

------------------------------------------------
-- Prerequisites throught required specializations
------------------------------------------------
function ParkingDistanceControl.prerequisitesPresent(specializations)
    return SpecializationUtil.hasSpecialization(Motorized, specializations)
        and SpecializationUtil.hasSpecialization(Drivable, specializations)
        and SpecializationUtil.hasSpecialization(Enterable, specializations)
end

------------------------------------------------
-- XML Schema
------------------------------------------------
function ParkingDistanceControl.initSpecialization()
    local schema = Vehicle.xmlSchema
    schema:setXMLSpecializationType(ParkingDistanceControl.SPEC_NAME)

    schema:register(XMLValueType.FLOAT,
        "vehicle.vehicleAssistanceSystem.parkingDistanceControl#maxDistance", "Max distance (m)", 1.5)
    schema:register(XMLValueType.FLOAT,
        "vehicle.vehicleAssistanceSystem.parkingDistanceControl#maxSpeed", "Max speed (km/h)", 8)

    -- sensors
    schema:register(XMLValueType.NODE_INDEX,
        "vehicle.vehicleAssistanceSystem.parkingDistanceControl.sensors.sensor(?)#node", "PDC sensor node")
    schema:register(XMLValueType.STRING,
        "vehicle.vehicleAssistanceSystem.parkingDistanceControl.sensors.sensor(?)#type", "Sensor type (front|back)", "back")

    -- zones
    schema:register(XMLValueType.FLOAT,
        "vehicle.vehicleAssistanceSystem.parkingDistanceControl.zones.zone(?)#distance")
    schema:register(XMLValueType.INT,
        "vehicle.vehicleAssistanceSystem.parkingDistanceControl.zones.zone(?)#interval")
    schema:register(XMLValueType.FLOAT,
        "vehicle.vehicleAssistanceSystem.parkingDistanceControl.zones.zone(?)#volume")
    schema:register(XMLValueType.FLOAT,
        "vehicle.vehicleAssistanceSystem.parkingDistanceControl.zones.zone(?)#pitch")
    schema:register(XMLValueType.BOOL,
        "vehicle.vehicleAssistanceSystem.parkingDistanceControl.zones.zone(?)#continuous")
    schema:register(XMLValueType.STRING,
        "vehicle.vehicleAssistanceSystem.parkingDistanceControl.zones.zone(?)#playAnimation",
        "Name of the animation to play for this zone")

    -- named sounds
    schema:register(
        XMLValueType.STRING,
        "vehicle.vehicleAssistanceSystem.parkingDistanceControl.sounds.sound(?)#name",
        "Name of the pdc sound (beep / continuous)"
    )

    SoundManager.registerSampleXMLPaths(
        schema,
        "vehicle.vehicleAssistanceSystem.parkingDistanceControl.sounds.sound(?)",
        "sound"
    )

    schema:setXMLSpecializationType()

    -- Settings schema (defaults + sounds)
    schema = ParkingDistanceControl.SETTINGS_SCHEMA
    schema:setXMLSpecializationType("ParkingDistanceControlSettings")

    local basePath = "vehicleAssistanceSystemSettings.parkingDistanceControl"
    schema:register(XMLValueType.FLOAT, basePath .. "#defaultMaxDistance", "Default max distance (m)", 2.0)
    schema:register(XMLValueType.FLOAT, basePath .. "#defaultMaxSpeed", "Default max speed (km/h)", 10)

    local zonesPath = basePath .. ".defaultZones.defaultZone(?)"
    schema:register(XMLValueType.FLOAT, zonesPath .. "#distance", "Default zone distance")
    schema:register(XMLValueType.INT, zonesPath .. "#interval", "Default zone interval")
    schema:register(XMLValueType.FLOAT, zonesPath .. "#volume", "Default zone volume")
    schema:register(XMLValueType.FLOAT, zonesPath .. "#pitch", "Default zone pitch")
    schema:register(XMLValueType.BOOL, zonesPath .. "#continuous", "Default zone continuous", false)

    local soundsPath = basePath .. ".defaultSounds"
    schema:register(XMLValueType.STRING, soundsPath .. ".defaultSound(?)#name", "Name of the default PDC sound")

    SoundManager.registerSampleXMLPaths(
        schema,
        soundsPath .. ".defaultSound(?)",
        "sound"
    )

    -- Supported vehicles (for sensor injection)
    local supportedVehiclesPath = basePath .. ".supportedVehicles.vehicle(?)"
    schema:register(XMLValueType.STRING, supportedVehiclesPath .. "#path", "Path to vehicle XML")
    schema:register(XMLValueType.STRING, supportedVehiclesPath .. ".sensors.sensor(?)#position", "Sensor position (x y z)")
    schema:register(XMLValueType.STRING, supportedVehiclesPath .. ".sensors.sensor(?)#type", "Sensor type (front|back)", "back")

    schema:setXMLSpecializationType()
end

------------------------------------------------
-- Register
------------------------------------------------
function ParkingDistanceControl.registerFunctions(vehicleType)
    SpecializationUtil.registerFunction(vehicleType, "pdcRaycastCallback", ParkingDistanceControl.pdcRaycastCallback)
    SpecializationUtil.registerFunction(vehicleType, "updatePdcSound", ParkingDistanceControl.updatePdcSound)
    SpecializationUtil.registerFunction(vehicleType, "loadPdcSettings", ParkingDistanceControl.loadPdcSettings)
end

function ParkingDistanceControl.registerEventListeners(vehicleType)
    SpecializationUtil.registerEventListener(vehicleType, "onLoad", ParkingDistanceControl)
    SpecializationUtil.registerEventListener(vehicleType, "onUpdate", ParkingDistanceControl)
    SpecializationUtil.registerEventListener(vehicleType, "onDelete", ParkingDistanceControl)
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
-- Load Settings (defaults, zones, sounds)
------------------------------------------------
function ParkingDistanceControl:loadPdcSettings(loadSounds)
    local settingsFile = XMLFile.load("pdcSettings", ParkingDistanceControl.SETTINGS_XML, ParkingDistanceControl.SETTINGS_SCHEMA)
    if settingsFile == nil then
        sosiLog:warn("Failed to load settings file: %s", tostring(ParkingDistanceControl.SETTINGS_XML))
        return { defaultSounds = {}, defaultZones = {}, defaultMaxDistance = nil, defaultMaxSpeed = nil }
    end

    local basePath = "vehicleAssistanceSystemSettings.parkingDistanceControl"

    local settings = {
        defaultSounds = {},
        defaultZones = {},
        defaultMaxDistance = settingsFile:getValue(basePath .. "#defaultMaxDistance", 2.0),
        defaultMaxSpeed = settingsFile:getValue(basePath .. "#defaultMaxSpeed", 10)
    }

    -- default zones
    settingsFile:iterate(basePath .. ".defaultZones.defaultZone", function(_, key)
        table.insert(settings.defaultZones, {
            distance = settingsFile:getValue(key .. "#distance"),
            interval = settingsFile:getValue(key .. "#interval"),
            volume = settingsFile:getValue(key .. "#volume"),
            pitch = settingsFile:getValue(key .. "#pitch"),
            continuous = settingsFile:getValue(key .. "#continuous", false)
        })
    end)

    -- default sounds (client only)
    if loadSounds then
        settingsFile:iterate(basePath .. ".defaultSounds.defaultSound", function(_, key)
            local name = settingsFile:getValue(key .. "#name")
            if name ~= nil then
                local sample = g_soundManager:loadSampleFromXML(
                    settingsFile,
                    key,
                    "sound",
                    ParkingDistanceControl.MOD_DIR,
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
    
    -- Parse supportedVehicles for sensor injection
    settings.supportedVehicles = {}
    local supportedVehiclesPath = basePath .. ".supportedVehicles.vehicle"
    settingsFile:iterate(supportedVehiclesPath, function(_, vehicleKey)
        local vehiclePath = settingsFile:getValue(vehicleKey .. "#path")
        if vehiclePath ~= nil then
            -- Resolve network placeholders (data, $moddir$, $pdlcdir$)
            local success, resolved = pcall(NetworkUtil.convertFromNetworkFilename, vehiclePath)
            local resolvedPath = nil
            if success and type(resolved) == "string" and resolved ~= "" then
                resolvedPath = resolved
            else
                resolvedPath = vehiclePath
            end
            -- Normalize separators to forward slashes for consistent matching
            resolvedPath = resolvedPath:gsub("\\", "/")

            local sensors = {}
            settingsFile:iterate(vehicleKey .. ".sensors.sensor", function(_, sensorKey)
                local posStr = settingsFile:getValue(sensorKey .. "#position")
                local sType = settingsFile:getValue(sensorKey .. "#type", "back")
                if sType ~= nil then sType = string.lower(sType) end
                if posStr ~= nil then
                    local x, y, z = string.match(posStr, "([%-%d%.eE]+)%s+([%-%d%.eE]+)%s+([%-%d%.eE]+)")
                    if x and y and z then
                        table.insert(sensors, { x = tonumber(x), y = tonumber(y), z = tonumber(z), type = sType or "back" })
                    end
                end
            end)
            if #sensors > 0 and resolvedPath ~= nil and resolvedPath ~= "" then
                settings.supportedVehicles[resolvedPath] = sensors
            end
        end
    end)

    settingsFile:delete()
    return settings
end

------------------------------------------------
-- onLoad
------------------------------------------------
function ParkingDistanceControl:onLoad()
    local spec = {}
    self[ParkingDistanceControl.SPEC] = spec
    spec.vehicle = self

    local basePath = "vehicle.vehicleAssistanceSystem.parkingDistanceControl"

    -- Base state
    spec.sensors = {}
    spec.zones = {}
    spec.sounds = {}

    spec.closestDistance = math.huge
    spec.hitThisFrame = false
    spec.beepTimer = 0
    spec.continuousActive = false
    spec.frontHasMoved = false

    -- Load settings (defaults)
    local settings = self:loadPdcSettings(self.isClient)

    spec.maxDistance = self.xmlFile:getValue(
        basePath .. "#maxDistance",
        settings.defaultMaxDistance or 2.0
    )
    spec.maxSpeed    = self.xmlFile:getValue(
        basePath .. "#maxSpeed",
        settings.defaultMaxSpeed or 10
    )

    ------------------------------------------------
    -- LOAD ZONES
    ------------------------------------------------
    local i = 0
    while true do
        local key = string.format(basePath .. ".zones.zone(%d)", i)
        if not self.xmlFile:hasProperty(key) then
            break
        end

        table.insert(spec.zones, {
            distance   = self.xmlFile:getValue(key .. "#distance"),
            interval   = self.xmlFile:getValue(key .. "#interval"),
            volume     = self.xmlFile:getValue(key .. "#volume"),
            pitch      = self.xmlFile:getValue(key .. "#pitch"),
            continuous = self.xmlFile:getValue(key .. "#continuous", false),
            playAnimation = self.xmlFile:getValue(key .. "#playAnimation")
        })

        i = i + 1
    end

    spec.zoneAnimationState = {} -- Track which zone animation is currently active
    spec.lastActiveZone = nil

    -- fallback to default zones when none are defined in vehicle XML
    if #spec.zones == 0 and settings.defaultZones ~= nil then
        for _, zone in ipairs(settings.defaultZones) do
            table.insert(spec.zones, {
                distance = zone.distance,
                interval = zone.interval,
                volume = zone.volume,
                pitch = zone.pitch,
                continuous = zone.continuous
            })
        end
    end

    -- sort from near to far
    table.sort(spec.zones, function(a, b)
        return a.distance < b.distance
    end)

    ------------------------------------------------
    -- LOAD SENSORS (from vehicle XML or injected from settings)
    ------------------------------------------------
    local foundXmlSensors = false
    i = 0
    while true do
        local key = string.format(basePath .. ".sensors.sensor(%d)", i)
        if not self.xmlFile:hasProperty(key) then
            break
        end

        local node = self.xmlFile:getValue(
            key .. "#node",
            nil,
            self.components,
            self.i3dMappings
        )

        local sensorType = self.xmlFile:getValue(key .. "#type", "back")
        if sensorType ~= nil then
            sensorType = string.lower(sensorType)
        end

        if node ~= nil then
            table.insert(spec.sensors, { node = node, type = sensorType or "back" })
            foundXmlSensors = true
        end

        i = i + 1
    end

    -- If no sensors in vehicle XML, check for supportedVehicles injection
    if not foundXmlSensors and settings.supportedVehicles ~= nil then
        local configFile = self.configFileName or self.customEnvironment or ""
        -- Normalize configFile for matching
        local normConfigFile = configFile:gsub("\\", "/")
        for path, sensors in pairs(settings.supportedVehicles) do
            if normConfigFile:find(path, 1, true) then
                sosiLog:devInfo("Injecting ParkingDistanceControl sensors into vehicle: %s", tostring(configFile))
                -- Attach transform groups at given positions to main node (0>)
                local mainNode = self.components and self.components[1].node or self.rootNode
                for _, sensor in ipairs(sensors) do
                    local tg = createTransformGroup("pdcSensor")
                    setTranslation(tg, sensor.x, sensor.y, sensor.z)
                    link(mainNode, tg)
                    table.insert(spec.sensors, { node = tg, type = sensor.type or "back" })
                end
                break
            end
        end
    end

    ------------------------------------------------
    -- LOAD SOUNDS
    ------------------------------------------------
    if self.isClient then
        i = 0
        while true do
            local key = string.format(basePath .. ".sounds.sound(%d)", i)
            if not self.xmlFile:hasProperty(key) then
                break
            end

            local name = self.xmlFile:getValue(key .. "#name")
            if name ~= nil then
                spec.sounds[name] = g_soundManager:loadSampleFromXML(
                    self.xmlFile,
                    key,
                    "sound",
                    self.baseDirectory,
                    self.components,
                    0,
                    AudioGroup.VEHICLE,
                    self.i3dMappings,
                    self
                )
                
                setSoundAttributes(spec.sounds[name])
            end

            i = i + 1
        end

        -- Load default sounds if not defined in vehicle
        local defaultSounds = settings.defaultSounds or {}
        
        -- Use default beep sound if not defined
        if spec.sounds["beep"] == nil and defaultSounds["beep"] ~= nil then
            spec.sounds["beep"] = defaultSounds["beep"]
        end
        
        -- Use default continuous sound if not defined
        if spec.sounds["continuous"] == nil and defaultSounds["continuous"] ~= nil then
            spec.sounds["continuous"] = defaultSounds["continuous"]
        end
        
        spec.beepSound       = spec.sounds["beep"]
        spec.continuousSound = spec.sounds["continuous"]
    end
end

------------------------------------------------
-- onDelete
------------------------------------------------
function ParkingDistanceControl:onDelete()
    local spec = self[ParkingDistanceControl.SPEC]
    if spec == nil then return end

    if spec.beepSound ~= nil then
        g_soundManager:deleteSample(spec.beepSound)
    end
    if spec.continuousSound ~= nil then
        g_soundManager:deleteSample(spec.continuousSound)
    end
end

------------------------------------------------
-- Helper function: pdc off
------------------------------------------------
local function stopPdc(spec)
    if spec.beepSound ~= nil then
        g_soundManager:stopSample(spec.beepSound)
    end
    if spec.continuousSound ~= nil then
        g_soundManager:stopSample(spec.continuousSound)
    end

    -- Reverse all zone animations if active
    if spec.zones and spec.zoneAnimationState then
        local vehicle = spec.vehicle or (spec.getVehicle and spec:getVehicle()) or nil
        for i, z in ipairs(spec.zones) do
            if z.playAnimation and spec.zoneAnimationState[i] and vehicle and vehicle.playAnimation and vehicle.getAnimationTime then
                local currentTime = vehicle:getAnimationTime(z.playAnimation) or 0
                vehicle:playAnimation(z.playAnimation, -1, currentTime, true)
                spec.zoneAnimationState[i] = false
            end
        end
    end

    spec.beepTimer = 0
    spec.continuousActive = false
    spec.hitThisFrame = false
    spec.closestDistance = math.huge
end

------------------------------------------------
-- onUpdate
------------------------------------------------
function ParkingDistanceControl:onUpdate(dt)
    local spec = self[ParkingDistanceControl.SPEC]
    if spec == nil then return end

    -- Check if parking distance control is enabled in settings
    if not MenuManager:getSetting("parkingDistanceControl") then
        stopPdc(spec)
        return
    end

    -- engine must be running
    if self.getIsMotorStarted ~= nil and not self:getIsMotorStarted() then
        spec.frontHasMoved = false
        stopPdc(spec)
        return
    end

    local lastSpeed = 0
    if self.getLastSpeed ~= nil then
        lastSpeed = self:getLastSpeed()
    end

    -- speed
    if lastSpeed > spec.maxSpeed then
        stopPdc(spec)
        return
    end

    -- determine driving direction: <0 back, >0 front, else neutral
    local motor = self.getMotor ~= nil and self:getMotor() or nil
    local drivingDir = 0
    if motor ~= nil and motor.currentDirection ~= nil then
        drivingDir = motor.currentDirection
    end

    -- arm front sensors once the vehicle has actually moved forward
    if drivingDir > 0 and lastSpeed > FRONT_MOVE_THRESHOLD then
        spec.frontHasMoved = true
    end

    -- frame reset
    spec.closestDistance = math.huge
    spec.hitThisFrame = false

    -- check if trailer is attached (disable back sensors)
    local trailerAttached = false
    if self.getAttachedImplements ~= nil then
        local attached = self:getAttachedImplements()
        trailerAttached = attached ~= nil and #attached > 0
    end

    local allowBack = drivingDir < 0 and not trailerAttached
    local allowFront = drivingDir > 0 and (lastSpeed > FRONT_MOVE_THRESHOLD or spec.frontHasMoved)

    for _, sensor in ipairs(spec.sensors) do
        local sType = sensor.type or "back"

        if (sType == "back" and allowBack) or (sType == "front" and allowFront) then
            local node = sensor.node
            local x, y, z = getWorldTranslation(node)
            local dirZ = (sType == "front") and 1 or -1
            local dx, dy, dz = localDirectionToWorld(node, 0, 0, dirZ)

            raycastAll(
                x, y, z,
                dx, dy, dz,
                spec.maxDistance,
                "pdcRaycastCallback",
                self,
                RAYCAST_MASK,
                true
            )
        end
    end

    self:updatePdcSound(dt)
end

------------------------------------------------
-- Raycast Callback
------------------------------------------------
function ParkingDistanceControl:pdcRaycastCallback(hitObjectId, x, y, z, distance)
    if getRootNode(hitObjectId) == self.rootNode then
        return
    end

    local spec = self[ParkingDistanceControl.SPEC]
    spec.hitThisFrame = true

    if distance < spec.closestDistance then
        spec.closestDistance = distance
    end
end

------------------------------------------------
-- Sound logic (OEM 3-Steps)
------------------------------------------------
function ParkingDistanceControl:updatePdcSound(dt)
    local spec = self[ParkingDistanceControl.SPEC]

    if not spec.hitThisFrame then
        -- No hit: reverse all zone animations
        for i, z in ipairs(spec.zones) do
            if z.playAnimation and spec.zoneAnimationState[i] then
                if self.playAnimation and self.getAnimationTime then
                    local currentTime = self:getAnimationTime(z.playAnimation) or 0
                    self:playAnimation(z.playAnimation, -1, currentTime, true)
                end
                spec.zoneAnimationState[i] = false
            end
        end
        stopPdc(spec)
        return
    end

    local activeZoneIndex = nil
    for idx, zone in ipairs(spec.zones) do
        if spec.closestDistance <= zone.distance then
            activeZoneIndex = idx
            -- Animation handling: play if entering this zone
            if zone.playAnimation and self.playAnimation and self.getAnimationTime then
                if not spec.zoneAnimationState[idx] then
                    local currentTime = self:getAnimationTime(zone.playAnimation) or 0
                    self:playAnimation(zone.playAnimation, 1, currentTime, true)
                    spec.zoneAnimationState[idx] = true
                end
            end

            -- Reverse animation for all other zones that are not active anymore
            for i, z in ipairs(spec.zones) do
                if i ~= idx and z.playAnimation and spec.zoneAnimationState[i] then
                    if self.playAnimation and self.getAnimationTime then
                        local currentTime = self:getAnimationTime(z.playAnimation) or 0
                        self:playAnimation(z.playAnimation, -1, currentTime, true)
                    end
                    spec.zoneAnimationState[i] = false
                end
            end

            -- continuous beep zone
            if zone.continuous then
                if not spec.continuousActive and spec.continuousSound ~= nil then
                    g_soundManager:stopSample(spec.beepSound)
                    g_soundManager:setSampleVolume(spec.continuousSound, zone.volume)
                    g_soundManager:setSamplePitch(spec.continuousSound, zone.pitch)
                    g_soundManager:playSample(spec.continuousSound)
                    spec.continuousActive = true
                end
                return
            end

            -- beeping (slow/fast)
            if spec.continuousActive then
                g_soundManager:stopSample(spec.continuousSound)
                spec.continuousActive = false
            end

            spec.beepTimer = spec.beepTimer - dt
            if spec.beepTimer <= 0 and spec.beepSound ~= nil then
                g_soundManager:stopSample(spec.beepSound)
                g_soundManager:setSampleVolume(spec.beepSound, zone.volume)
                g_soundManager:setSamplePitch(spec.beepSound, zone.pitch)
                g_soundManager:playSample(spec.beepSound)
                spec.beepTimer = zone.interval
            end
            return
        end
    end

    -- No zone active: reverse all animations
    for i, z in ipairs(spec.zones) do
        if z.playAnimation and spec.zoneAnimationState[i] then
            if self.playAnimation and self.getAnimationTime then
                local currentTime = self:getAnimationTime(z.playAnimation) or 0
                self:playAnimation(z.playAnimation, -1, currentTime, true)
            end
            spec.zoneAnimationState[i] = false
        end
    end

    stopPdc(spec)
end