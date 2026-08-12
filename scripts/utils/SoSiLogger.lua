--[[
    SoSi Logger - FS25
    --------------------------------
    Author: [SoSi] Janni1101
    Version: 1.0.0.0
    Date: 2026/01/07
    --------------------------------
    Copyright (c) SoSi-Modding, 2026

    This script may not be modified or used in other mods without permission by the author.
]]

---@class SoSiLogger
---@field public modName string Name of the mod
---@field public scriptName string Name of the script/module (optional, for debug context)
SoSiLogger = {}

local SoSiLogger_mt = Class(SoSiLogger)

---Create new instance of SoSiLogger
---@param modName string Mod name to display in logs
---@param scriptName? string Optional script/module name for context
---@return SoSiLogger
function SoSiLogger.new(modName, scriptName)
    local self = setmetatable({}, SoSiLogger_mt)

    self.modName = modName or "SoSiLogger"
    self.scriptName = scriptName or nil

    return self
end

---Format log prefix with optional script name
---@return string
function SoSiLogger:getPrefix()
    if self.scriptName ~= nil and self.scriptName ~= "" then
        return string.format("[%s] (%s) ", self.modName, self.scriptName)
    else
        return string.format("[%s] ", self.modName)
    end
end

---Log info message
---@param message string Message to log
function SoSiLogger:info(message, ...)
    if select('#', ...) > 0 then
        message = string.format(tostring(message), ...)
    end
    Logging.info(self:getPrefix() .. tostring(message))
end

---Log warning message
---@param message string Message to log
function SoSiLogger:warn(message, ...)
    if select('#', ...) > 0 then
        message = string.format(tostring(message), ...)
    end
    Logging.warning(self:getPrefix() .. tostring(message))
end

---Log error message
---@param message string Message to log
function SoSiLogger:error(message, ...)
    if select('#', ...) > 0 then
        message = string.format(tostring(message), ...)
    end
    Logging.error(self:getPrefix() .. tostring(message))
end

---Log dev info message (only with -devWarnings)
---@param message string Message to log
function SoSiLogger:devInfo(message, ...)
    if select('#', ...) > 0 then
        message = string.format(tostring(message), ...)
    end
    Logging.devInfo(self:getPrefix() .. tostring(message))
end

---Log dev warning message (only with -devWarnings)
---@param message string Message to log
function SoSiLogger:devWarn(message, ...)
    if select('#', ...) > 0 then
        message = string.format(tostring(message), ...)
    end
    Logging.devWarning(self:getPrefix() .. tostring(message))
end

---Log dev error message (only with -devWarnings)
---@param message string Message to log
function SoSiLogger:devError(message, ...)
    if select('#', ...) > 0 then
        message = string.format(tostring(message), ...)
    end
    Logging.devError(self:getPrefix() .. tostring(message))
end

---Log XML info message with file context
---@param xmlFile XMLFile XML file object
---@param message string Message to log
function SoSiLogger:xmlInfo(xmlFile, message, ...)
    if select('#', ...) > 0 then
        message = string.format(tostring(message), ...)
    end
    Logging.xmlInfo(xmlFile, self:getPrefix() .. tostring(message))
end

---Log XML warning message with file context
---@param xmlFile XMLFile XML file object
---@param message string Message to log
function SoSiLogger:xmlWarn(xmlFile, message, ...)
    if select('#', ...) > 0 then
        message = string.format(tostring(message), ...)
    end
    Logging.xmlWarning(xmlFile, self:getPrefix() .. tostring(message))
end

---Log XML error message with file context
---@param xmlFile XMLFile XML file object
---@param message string Message to log
function SoSiLogger:xmlError(xmlFile, message, ...)
    if select('#', ...) > 0 then
        message = string.format(tostring(message), ...)
    end
    Logging.xmlError(xmlFile, self:getPrefix() .. tostring(message))
end
