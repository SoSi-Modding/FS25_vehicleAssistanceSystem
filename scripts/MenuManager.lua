--[[
    Menu Manager - FS25
    --------------------------------
    Author: [SoSi] Janni1101
    Version: 1.0.0.0
    Date: 2026/01/11
    --------------------------------
    Copyright (c) SoSi-Modding, 2026

    This script may not be modified or used in other mods without permission by the author.
]]

source(Utils.getFilename("scripts/utils/SoSiLogger.lua", g_currentModDirectory))
local sosiLog = SoSiLogger.new(g_currentModName, "MenuManager.lua")

---@class MenuManager
MenuManager = {}
MenuManager.MOD_NAME = g_currentModName
MenuManager.MOD_DIR = g_currentModDirectory

-- Setup XML Schema for settings storage
MenuManager.SETTINGS_SCHEMA = XMLSchema.new("menuManagerSettings")
MenuManager.SETTINGS_SCHEMA:register(XMLValueType.BOOL, "settings.setting(?)#value", "Value of binary setting")
MenuManager.SETTINGS_SCHEMA:register(XMLValueType.STRING, "settings.setting(?)#name", "Name of setting")

-- Track loaded mod settings
MenuManager.sections = {}
MenuManager.settingsCreated = false
MenuManager.settingsDirectory = nil

---Parse modDesc.xml for menuManager configuration
function MenuManager:loadConfig()
    local modDescPath = self.MOD_DIR .. "modDesc.xml"
    local xmlId = loadXMLFile("MenuManagerConfig", modDescPath)
    
    if xmlId == nil or xmlId == 0 then
        sosiLog:error("Failed to load modDesc.xml")
        return false
    end
    
    local sectionIndex = 0
    while true do
        local sectionKey = string.format("modDesc.menuManager.section(%d)", sectionIndex)
        local menuTab = getXMLString(xmlId, sectionKey .. "#menuTab")
        
        if menuTab == nil then
            break
        end
        
        local section = {
            menuTab = menuTab,
            title = getXMLString(xmlId, sectionKey .. "#title"),
            savefile = getXMLString(xmlId, sectionKey .. "#savefile") or "modSettings.xml",
            saveInSavegame = getXMLBool(xmlId, sectionKey .. "#saveInSavegame") ~= false,
            settings = {},
            settingsByName = {}
        }
        
        -- Load settings for this section
        local settingIndex = 0
        while true do
            local settingKey = string.format("%s.setting(%d)", sectionKey, settingIndex)
            local name = getXMLString(xmlId, settingKey .. "#name")
            
            if name == nil then
                break
            end
            
            local defaultOption = getXMLString(xmlId, settingKey .. "#defaultOption") or "no"
            local isYesNoOption = getXMLBool(xmlId, settingKey .. "#isYesNoOption") ~= false
            
            local setting = {
                name = name,
                title = getXMLString(xmlId, settingKey .. "#title"),
                tooltip = getXMLString(xmlId, settingKey .. "#tooltip"),
                yesText = getXMLString(xmlId, settingKey .. "#yesText") or "ui_on",
                noText = getXMLString(xmlId, settingKey .. "#noText") or "ui_off",
                isYesNoOption = isYesNoOption,
                value = (defaultOption == "yes")
            }
            
            table.insert(section.settings, setting)
            section.settingsByName[name] = setting
            settingIndex = settingIndex + 1
        end
        
        if (section.menuTab == "generalSettings" or section.menuTab == "gameSettings") and #section.settings > 0 then
            table.insert(self.sections, section)
            sosiLog:devInfo("Loaded menu section: %s with %d settings", section.title or menuTab, #section.settings)
        end
        
        sectionIndex = sectionIndex + 1
    end
    
    delete(xmlId)
    
    return #self.sections > 0
end

---Get the directory path for saving a section
function MenuManager:getSaveDirectory(section)
    if section.saveInSavegame then
        local savegameFolder = g_currentMission and g_currentMission.missionInfo and g_currentMission.missionInfo.savegameDirectory
        if savegameFolder then
            return savegameFolder .. "/"
        end
    end
    return self.settingsDirectory
end

---Load settings from XML
function MenuManager:loadFromXML()
    for _, section in ipairs(self.sections) do
        local directory = self:getSaveDirectory(section)
        local filePath = directory .. section.savefile
        local xmlFile = XMLFile.loadIfExists("MenuManagerSettings", filePath, self.SETTINGS_SCHEMA)
        
        if xmlFile ~= nil then
            xmlFile:iterate("settings.setting", function(_, settingKey)
                local name = xmlFile:getValue(settingKey .. "#name")
                local value = xmlFile:getValue(settingKey .. "#value", false)
                
                local setting = section.settingsByName[name]
                if setting ~= nil then
                    setting.value = value
                end
            end)
            
            xmlFile:delete()
            sosiLog:info("Loaded settings from: %s", filePath)
        end
    end
end

---Save settings to XML
function MenuManager:saveToXMLFile()
    for _, section in ipairs(self.sections) do
        local directory = self:getSaveDirectory(section)
        local filePath = directory .. section.savefile
        
        -- Ensure directory exists
        createFolder(directory)
        
        local xmlFile = XMLFile.create("MenuManagerSettings", filePath, "settings", self.SETTINGS_SCHEMA)
        
        if xmlFile ~= nil then
            for index, setting in ipairs(section.settings) do
                local settingKey = string.format("settings.setting(%d)", index - 1)
                xmlFile:setValue(settingKey .. "#name", setting.name)
                xmlFile:setValue(settingKey .. "#value", setting.value)
            end
            
            xmlFile:save(false, false)
            xmlFile:delete()
            sosiLog:info("Saved settings to: %s", filePath)
        end
    end
end

---Create GUI element for a setting
function MenuManager:createGuiElement(settingsFrame, setting, section)
    local cloneRef = settingsFrame["checkActiveSuspensionCamera"]
    
    if cloneRef == nil then
        sosiLog:warn("Could not find reference element 'checkActiveSuspensionCamera'")
        return nil
    end
    
    -- Clone the parent element (contains both setting and label)
    local element = cloneRef.parent:clone()
    element.id = setting.name .. "Box"
    
    local settingElement = element.elements[1]
    local settingTitle = element.elements[2]
    local toolTip = settingElement.elements[1]
    
    settingTitle:setText(g_i18n:getText(setting.title))
    
    if setting.tooltip then
        toolTip:setText(g_i18n:getText(setting.tooltip))
    end
    
    settingElement.id = setting.name
    settingElement.target = self
    settingElement:setCallback("onClickCallback", "onSettingChanged")
    settingElement:setDisabled(false)
    settingElement:setIsChecked(setting.value)
    
    -- Set yes/no texts
    settingElement:setTexts({
        g_i18n:getText(setting.noText),
        g_i18n:getText(setting.yesText)
    })
    
    element:reloadFocusHandling(true)
    
    return element
end

---Get the layout for a given menuTab
function MenuManager:getLayoutForTab(settingsFrame, menuTab)
    if menuTab == "gameSettings" then
        return settingsFrame.gameSettingsLayout
    end
    return settingsFrame.generalSettingsLayout
end

---Initialize GUI
function MenuManager:initGui(settingsFrame, element)
    if self.settingsCreated then
        return
    end
    
    for _, section in ipairs(self.sections) do
        local layout = self:getLayoutForTab(settingsFrame, section.menuTab)
        local settingsElements = settingsFrame[section.title]
        
        if settingsElements == nil then
            -- Find header reference
            local headerRef = nil
            for _, _element in ipairs(layout.elements) do
                if _element.name == 'sectionHeader' then
                    headerRef = _element
                    break
                end
            end
            
            if headerRef ~= nil then
                local headerElement = headerRef:clone()
                headerElement.id = section.title
                headerElement:setText(g_i18n:getText(section.title))
                layout:addElement(headerElement)
            end
            
            -- Create setting elements
            settingsElements = {}
            
            for _, setting in ipairs(section.settings) do
                local createdElement = self:createGuiElement(settingsFrame, setting, section)
                
                if createdElement ~= nil then
                    settingsElements[setting.name] = createdElement
                    layout:addElement(createdElement)
                end
            end
            
            layout:invalidateLayout()
            settingsFrame[section.title] = settingsElements
        end
    end
    
    self.settingsCreated = true
end

---Update GUI
function MenuManager:updateGui(settingsFrame)
    for _, section in ipairs(self.sections) do
        local settingsElements = settingsFrame[section.title]
        
        if settingsElements ~= nil then
            for _, setting in ipairs(section.settings) do
                local containerElement = settingsElements[setting.name]
                
                if containerElement ~= nil then
                    -- The actual setting element is the first child
                    local settingElement = containerElement.elements[1]
                    if settingElement ~= nil then
                        settingElement:setIsChecked(setting.value)
                    end
                end
            end
        end
    end
end

---Called when setting changed
function MenuManager:onSettingChanged(state, element)
    local settingName = element.id
    local newValue = element:getIsChecked()
    
    -- Find and update setting
    for _, section in ipairs(self.sections) do
        local setting = section.settingsByName[settingName]
        if setting ~= nil then
            setting.value = newValue
            sosiLog:devInfo("Setting changed: %s = %s", settingName, tostring(newValue))
            break
        end
    end
end

---Get setting value
function MenuManager:getSetting(path)
    for _, section in ipairs(self.sections) do
        local setting = section.settingsByName[path]
        if setting ~= nil then
            return setting.value
        end
    end
    return false
end

---Set setting value
function MenuManager:setSetting(path, value)
    for _, section in ipairs(self.sections) do
        local setting = section.settingsByName[path]
        if setting ~= nil then
            setting.value = value
            return true
        end
    end
    return false
end

-- Initialize and register hooks
local function init()
    -- Store settings directory at init time
    MenuManager.settingsDirectory = g_currentModSettingsDirectory
    
    if not MenuManager:loadConfig() then
        sosiLog:info("No menuManager configuration found")
        return
    end
    
    MenuManager:loadFromXML()
    
    -- Register hooks
    local origOnFrameOpen = InGameMenuSettingsFrame.onFrameOpen
    InGameMenuSettingsFrame.onFrameOpen = function(self, element)
        origOnFrameOpen(self, element)
        MenuManager:initGui(self, element)
    end
    
    local origUpdateGeneralSettings = InGameMenuSettingsFrame.updateGeneralSettings
    InGameMenuSettingsFrame.updateGeneralSettings = function(self)
        origUpdateGeneralSettings(self)
        MenuManager:updateGui(self)
    end
    
    local origSaveToXMLFile = GameSettings.saveToXMLFile
    GameSettings.saveToXMLFile = function(...)
        origSaveToXMLFile(...)
        MenuManager:saveToXMLFile()
    end
    
    sosiLog:info("MenuManager initialized successfully")
end

init()
