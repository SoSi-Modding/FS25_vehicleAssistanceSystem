--[[
    SoSi L10n Helper - FS25
    --------------------------------
    Author: [SoSi] Benny
    Version: 1.0.0.0
    Date: 2026/01/20
    --------------------------------
    Copyright (c) SoSi-Modding, 2026

    This script may not be modified or used in other mods without permission by the author.
]]

---@class SoSiL10n
SoSiL10n = {}

---@param i18n I18N g_i18n instance or table with .texts property
function SoSiL10n.mergeModTranslations(i18n)
    if i18n == nil then
        return
    end

    local textsToMerge = i18n.texts or i18n
    
    if textsToMerge == nil or type(textsToMerge) ~= "table" then
        return
    end

    local modEnvMeta = getmetatable(_G)
    if modEnvMeta == nil or modEnvMeta.__index == nil then
        return
    end

    local env = modEnvMeta.__index
    if env == nil or env.g_i18n == nil or env.g_i18n.texts == nil then
        return
    end

    local global = env.g_i18n.texts
    for key, text in pairs(textsToMerge) do
        global[key] = text
    end
end