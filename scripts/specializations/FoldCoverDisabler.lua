--[[
    Fold/Cover/TurnOn Disabler - FS25
    --------------------------------
    Author: [SoSi] Benny
    Version: 1.0.0.1
    Date: 2026/02/12
    --------------------------------
    Copyright (c) SoSi-Modding, 2026

    This script may not be modified or used in other mods without permission by the author.
]]

source(Utils.getFilename("scripts/utils/SoSiLogger.lua", g_currentModDirectory))
local sosiLog = SoSiLogger.new(g_currentModName, "FoldCoverDisabler.lua")

FoldCoverDisabler = {}
FoldCoverDisabler.MOD_NAME = g_currentModName
FoldCoverDisabler.MOD_DIR = g_currentModDirectory

-- ==================== SPECIALIZATION ====================
function FoldCoverDisabler.prerequisitesPresent(specializations)
    return true
end

function FoldCoverDisabler.initSpecialization()
    local schema = Vehicle.xmlSchema
    schema:setXMLSpecializationType("FoldCoverDisabler")

    local baseKey = "vehicle.vehicleAssistanceSystem"
    schema:register(XMLValueType.BOOL, baseKey .. "#disableFoldable", "Disable foldable specialization", false)
    schema:register(XMLValueType.BOOL, baseKey .. "#disableCover", "Disable cover specialization", false)
    schema:register(XMLValueType.BOOL, baseKey .. "#disableTurnOnVehicle", "Disable turnOnVehicle specialization", false)

    schema:setXMLSpecializationType()
end

function FoldCoverDisabler.registerEventListeners(vehicleType)
    SpecializationUtil.registerEventListener(vehicleType, "onPreLoad", FoldCoverDisabler)
    SpecializationUtil.registerEventListener(vehicleType, "onLoad", FoldCoverDisabler)
    SpecializationUtil.registerEventListener(vehicleType, "onRegisterActionEvents", FoldCoverDisabler)
end

function FoldCoverDisabler.registerOverwrittenFunctions(vehicleType)
    SpecializationUtil.registerOverwrittenFunction(vehicleType, "getIsFoldAllowed", FoldCoverDisabler.getIsFoldAllowed)
    SpecializationUtil.registerOverwrittenFunction(vehicleType, "getIsCoverAllowed", FoldCoverDisabler.getIsCoverAllowed)
    SpecializationUtil.registerOverwrittenFunction(vehicleType, "getCanBeTurnedOn", FoldCoverDisabler.getCanBeTurnedOn)
    SpecializationUtil.registerOverwrittenFunction(vehicleType, "getCanToggleTurnedOn", FoldCoverDisabler.getCanToggleTurnedOn)
end

-- ==================== LOAD ====================
function FoldCoverDisabler:onPreLoad()
    self.spec_foldCoverDisabler = {
        disableFoldable = false,
        disableCover = false,
        disableTurnOn = false
    }
end

function FoldCoverDisabler:onLoad()
    local spec = self.spec_foldCoverDisabler
    if spec == nil then return end
    local baseKey = "vehicle.vehicleAssistanceSystem"
    spec.disableFoldable = self.xmlFile:getValue(baseKey .. "#disableFoldable", false)
    spec.disableCover = self.xmlFile:getValue(baseKey .. "#disableCover", false)
    spec.disableTurnOn = self.xmlFile:getValue(baseKey .. "#disableTurnOnVehicle", false)

    if spec.disableFoldable then
        sosiLog:info("Foldable specialization disabled for vehicle '%s'", self.configFileName or "Unknown")
    end
    if spec.disableCover then
        sosiLog:info("Cover specialization disabled for vehicle '%s'", self.configFileName or "Unknown")
    end
    if spec.disableTurnOn then
        sosiLog:info("TurnOnVehicle specialization disabled for vehicle '%s'", self.configFileName or "Unknown")
    end
end

-- ==================== OVERWRITES ====================
function FoldCoverDisabler.getIsFoldAllowed(self, superFunc, direction, onAiTurnOn)
    local spec = self.spec_foldCoverDisabler
    if spec ~= nil and spec.disableFoldable then
        return false, nil
    end
    if superFunc ~= nil then
        return superFunc(self, direction, onAiTurnOn)
    end
    return true, nil
end

function FoldCoverDisabler.getIsCoverAllowed(self, superFunc)
    local spec = self.spec_foldCoverDisabler
    if spec ~= nil and spec.disableCover then
        return false, nil
    end
    if superFunc ~= nil then
        return superFunc(self)
    end
    return true, nil
end

function FoldCoverDisabler.getCanBeTurnedOn(self, superFunc)
    local spec = self.spec_foldCoverDisabler
    if spec ~= nil and spec.disableTurnOn then
        return false
    end
    if superFunc ~= nil then
        return superFunc(self)
    end
    return true
end

function FoldCoverDisabler.getCanToggleTurnedOn(self, superFunc)
    local spec = self.spec_foldCoverDisabler
    if spec ~= nil and spec.disableTurnOn then
        return false
    end
    if superFunc ~= nil then
        return superFunc(self)
    end
    return true
end

-- ==================== ACTION EVENTS ====================
function FoldCoverDisabler:onRegisterActionEvents()
    if not self.isClient then return end
    local spec = self.spec_foldCoverDisabler
    if spec == nil then return end

    local function hideEventTable(tbl, specName)
        if tbl == nil then return end
        local hidCount = 0
        for _, actionData in pairs(tbl) do
            if actionData.actionEventId ~= nil then
                g_inputBinding:setActionEventActive(actionData.actionEventId, false)
                g_inputBinding:setActionEventTextVisibility(actionData.actionEventId, false)
                hidCount = hidCount + 1
            end
        end
    end

    if spec.disableFoldable and self.spec_foldable ~= nil then
        hideEventTable(self.spec_foldable.actionEvents, "foldable.actionEvents")
        hideEventTable(self.spec_foldable.actionEventsLowering, "foldable.actionEventsLowering")
    end

    if spec.disableCover and self.spec_cover ~= nil then
        hideEventTable(self.spec_cover.actionEvents, "cover.actionEvents")
    end

    if spec.disableTurnOn and self.spec_turnOnVehicle ~= nil then
        hideEventTable(self.spec_turnOnVehicle.actionEvents, "turnOnVehicle.actionEvents")
    end
end
