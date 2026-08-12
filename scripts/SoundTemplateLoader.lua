--[[
    Sound Template Loader - FS25
    --------------------------------
    Author: [SoSi] Benny
    Version: 1.0.0.0
    Date: 2026/01/25
    --------------------------------
    Copyright (c) SoSi-Modding, 2026

    This script may not be modified or used in other mods without permission by the author.
]]

source(Utils.getFilename("scripts/utils/SoSiLogger.lua", g_currentModDirectory))
local sosiLog = SoSiLogger.new(g_currentModName, "SoundTemplateLoader.lua")

---@class SoundTemplateLoader
SoundTemplateLoader = {}

SoundTemplateLoader.DEFAULT_SOUND_TEMPLATES_FILE = "shared/soundTemplates.xml"
SoundTemplateLoader.modTemplates = SoundTemplateLoader.modTemplates or {}
SoundTemplateLoader.modTemplateFiles = SoundTemplateLoader.modTemplateFiles or {}

---@param xmlFilename string Path to the sound templates XML file
---@return boolean true if loading was successful, false otherwise
function SoundTemplateLoader:loadTemplates(xmlFilename)
    if g_soundManager == nil then
        sosiLog:error("SoundManager is not initialized")
        return false
    end

    -- Ensure sound template containers exist
    if g_soundManager.soundTemplates == nil then
        g_soundManager.soundTemplates = {}
    end

    -- Use default file if none specified
    if xmlFilename == nil or xmlFilename == "" then
        xmlFilename = SoundTemplateLoader.DEFAULT_SOUND_TEMPLATES_FILE
    end

    -- Resolve mod directory path
    xmlFilename = Utils.getFilename(xmlFilename, g_currentModDirectory)

    -- Load the XML file
    local xmlFile = loadXMLFile("soundTemplates", xmlFilename)
    if xmlFile == 0 then
        sosiLog:error("Failed to load sound templates file: %s", xmlFilename)
        return false
    end

    -- Parse all template definitions and register without overwriting base templates
    local templateCount = 0
    local i = 0

    while true do
        local templateKey = string.format("soundTemplates.template(%d)", i)

        -- Check if template exists at this key
        if not hasXMLProperty(xmlFile, templateKey) then
            break
        end

        -- Get template name
        local templateName = getXMLString(xmlFile, templateKey .. "#name")
        if templateName ~= nil and templateName ~= "" then
            -- Store the template key in SoundManager for later reference (but do not wipe existing)
            if g_soundManager.soundTemplates[templateName] == nil then
                g_soundManager.soundTemplates[templateName] = templateKey
                templateCount = templateCount + 1
            else
                sosiLog:warn("Sound template '%s' already exists and will be skipped", templateName)
            end

            -- Keep per-template XML handle so we don't overwrite the base template file
            SoundTemplateLoader.modTemplates[templateName] = {
                xmlFile = xmlFile,
                key = templateKey
            }
        else
            sosiLog:warn("Template at index %d has no name attribute", i)
        end

        i = i + 1
    end

    sosiLog:info("Registered %d additional sound templates from %s", templateCount, xmlFilename)
    return true
end


---Reload all sound templates
---This function clears existing templates and reloads them from the XML file
---@return boolean true if reloading was successful, false otherwise
function SoundTemplateLoader:reloadTemplates()
    if g_soundManager == nil then
        sosiLog:error("SoundManager is not initialized")
        return false
    end

    -- Remove only templates that were added by this loader
    for templateName, entry in pairs(SoundTemplateLoader.modTemplates or {}) do
        g_soundManager.soundTemplates[templateName] = nil
        if entry.xmlFile ~= nil and entityExists(entry.xmlFile) then
            delete(entry.xmlFile)
        end
        SoundTemplateLoader.modTemplates[templateName] = nil
    end

    return self:loadTemplates(SoundTemplateLoader.DEFAULT_SOUND_TEMPLATES_FILE)
end


---Get a template by name
---@param templateName string Name of the template to retrieve
---@return string|nil XML key of the template, or nil if not found
function SoundTemplateLoader:getTemplate(templateName)
    if g_soundManager == nil then
        sosiLog:error("SoundManager is not initialized")
        return nil
    end

    if g_soundManager.soundTemplates == nil then
        return nil
    end

    return g_soundManager.soundTemplates[templateName]
end


---Check if a template exists
---@param templateName string Name of the template to check
---@return boolean true if template exists, false otherwise
function SoundTemplateLoader:hasTemplate(templateName)
    if g_soundManager == nil then
        return false
    end

    if g_soundManager.soundTemplates == nil then
        return false
    end

    return g_soundManager.soundTemplates[templateName] ~= nil
end


---Get all loaded template names
---@return table Array of template names
function SoundTemplateLoader:getTemplateNames()
    if g_soundManager == nil then
        return {}
    end

    local names = {}
    for templateName, _ in pairs(g_soundManager.soundTemplates or {}) do
        table.insert(names, templateName)
    end
    return names
end


---Initialize the SoundTemplateLoader and load default templates
---This should be called after SoundManager is initialized
---@return boolean true if initialization was successful, false otherwise
function SoundTemplateLoader:initialize()
    sosiLog:info("Initializing sound template system")
    return self:loadTemplates(SoundTemplateLoader.DEFAULT_SOUND_TEMPLATES_FILE)
end


---Debug information about loaded templates
---@return string Formatted debug information
function SoundTemplateLoader:getDebugInfo()
    if g_soundManager == nil then
        return "SoundManager not initialized"
    end

    local templateCount = 0
    for _, _ in pairs(g_soundManager.soundTemplates) do
        templateCount = templateCount + 1
    end

    return string.format("Loaded Templates: %d\nXML File Handle: %s", templateCount, tostring(g_soundManager.soundTemplateXMLFile))
end


-- Create global singleton instance if needed
if g_soundTemplateLoader == nil then
    g_soundTemplateLoader = SoundTemplateLoader
end

-- Initialize after map load to ensure SoundManager is ready
function SoundTemplateLoader:loadMapFinished()
    if g_soundManager == nil then
        return
    end

    if g_soundManager.soundTemplates == nil then
        g_soundManager.soundTemplates = {}
    end

    -- Always add/refresh our templates without touching base ones
    SoundTemplateLoader:reloadTemplates()
end

-- Register for mission lifecycle events and trigger early init if the SoundManager is already present
addModEventListener(SoundTemplateLoader)
if g_soundManager ~= nil then
    SoundTemplateLoader:loadMapFinished()
end

-- Patch SoundManager to support per-template XML handles for mod templates without clobbering base templates
if SoundManager ~= nil and SoundManager._vasOrigLoadSampleAttributesFromTemplate == nil then
    SoundManager._vasOrigLoadSampleAttributesFromTemplate = SoundManager.loadSampleAttributesFromTemplate

    function SoundManager:loadSampleAttributesFromTemplate(sample, templateName, baseDir, defaultLoops, xmlFile, sampleKey)
        local entry = SoundTemplateLoader.modTemplates and SoundTemplateLoader.modTemplates[templateName]
        if entry ~= nil and entry.xmlFile ~= nil then
            local templateSample = {}
            templateSample.is2D = sample.is2D
            templateSample.sampleName = sample.sampleName
            templateSample.templateName = templateName
            if not self:loadSampleAttributesFromXML(templateSample, entry.xmlFile, entry.key, baseDir, defaultLoops, false) then
                return nil
            end
            return templateSample
        end

        return SoundManager._vasOrigLoadSampleAttributesFromTemplate(self, sample, templateName, baseDir, defaultLoops, xmlFile, sampleKey)
    end
end

return SoundTemplateLoader