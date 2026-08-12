--[[
    Global Specializations - FS25
    --------------------------------
    Author: [SoSi] Janni1101
    Version: 1.1.0.0
    Date: 2026/01/05
    --------------------------------
    Copyright (c) SoSi-Modding, 2026

    This script may not be modified or used in other mods without permission by the author.
]]

source(Utils.getFilename("scripts/utils/SoSiLogger.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/utils/SoSiL10n.lua", g_currentModDirectory))

local modDirectory = g_currentModDirectory
local modName = g_currentModName
local sosiLog = SoSiLogger.new(modName, "GlobalSpecializations.lua")

---@class GlobalSpecializations
GlobalSpecializations = {}
GlobalSpecializations.MOD_NAME = modName
GlobalSpecializations.MOD_DIR = modDirectory
GlobalSpecializations.XML_KEY = "modDesc.globalSpecializations.globalSpecialization"

local schema = XMLSchema.new("globalSpecializations")
schema:register(XMLValueType.STRING, "modDesc.globalSpecializations.globalSpecialization(?)#name", "Name of the global specialization")
schema:register(XMLValueType.STRING, "modDesc.globalSpecializations.globalSpecialization(?)#className", "Class name of the global specialization")
schema:register(XMLValueType.STRING, "modDesc.globalSpecializations.globalSpecialization(?)#filename", "Path to the specialization file")
schema:register(XMLValueType.STRING, "modDesc.globalSpecializations.globalSpecialization(?)#requiredDLC", "Required DLC mod name (optional)")

---Load and merge VAS L10n
local function load()
    SoSiL10n.mergeModTranslations(g_i18n)
end

local function getClassObject(className)
    local parts = string.split(className, ".")
    local current = _G[parts[1]]
    if type(current) ~= "table" then
        return nil
    end

    for i = 2, #parts do
        current = current[parts[i]]
        if type(current) ~= "table" then
            return nil
        end
    end

    return current
end

local function dlcCheck(requiredDLC)
    if requiredDLC == nil or requiredDLC == "" then
        return true
    end

    if g_modIsLoaded[requiredDLC] then
        return true
    end

    return false
end

---Register all global specializations from modDesc.xml
local function registerSpecializations()
    local modDescPath = GlobalSpecializations.MOD_DIR .. "modDesc.xml"
    local modDesc = XMLFile.load("ModFile", modDescPath)

    modDesc:iterate(GlobalSpecializations.XML_KEY, function(_, key)
        local specName = modDesc:getString(key .. "#name")
        local className = modDesc:getString(key .. "#className")
        local fileName = modDesc:getString(key .. "#filename")
        local requiredDLC = modDesc:getString(key .. "#requiredDLC")

        if specName == nil or specName == "" then
            sosiLog:xmlError(modDesc, "Missing value for 'name' in globalSpecialization %s", key)
            return
        end

        if className == nil or className == "" then
            sosiLog:xmlError(modDesc, "Missing value for 'className' in globalSpecialization %s", key)
            return
        end

        if fileName == nil or fileName == "" then
            sosiLog:xmlError(modDesc, "Missing value for 'filename' in globalSpecialization %s", key)
            return
        end

        local filePath = Utils.getFilename(fileName, GlobalSpecializations.MOD_DIR)
        if filePath == nil or filePath == "" then
            sosiLog:xmlError(modDesc, "Invalid value for 'filename' in globalSpecialization %s", key)
            return
        end

        if not dlcCheck(requiredDLC) then
            sosiLog:info("Skipping global specialization '%s' because DLC '%s' is not loaded", specName, requiredDLC)
            return
        end

        source(filePath)
        local class = getClassObject(className)

        if class == nil then
            sosiLog:error("Class '%s' not found in file '%s'", className, fileName)
            return
        end

        if class.prerequisitesPresent == nil then
            sosiLog:error("Function 'prerequisitesPresent' not found in class '%s'", className)
            return
        end

        if g_specializationManager:getSpecializationByName(specName) == nil then
            g_specializationManager:addSpecialization(specName, className, filePath, nil)
        end

        local addedCount = 0
        local totalCount = 0
        for vehicleTypeName, vehicleType in pairs(g_vehicleTypeManager.types) do
            totalCount = totalCount + 1
            if vehicleType ~= nil and class.prerequisitesPresent(vehicleType.specializations) then
                g_vehicleTypeManager:addSpecialization(vehicleTypeName, specName)
                addedCount = addedCount + 1
            end
        end
        
        if addedCount > 0 then
            sosiLog:info("Registered global specialization '%s' for %d of %d total vehicle types", specName, addedCount, totalCount)
        end
    end)
end

---Initialize the mod
local function init()
    load()
    registerSpecializations()
end

init()