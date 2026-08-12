---@class AACSetSoundEvent

AACSetSoundEvent = {}
local setSoundControlEvent_mt = Class(AACSetSoundEvent, Event)

InitEventClass(AACSetSoundEvent, "AACSetSoundEvent")

---@return AACSetSoundEvent
function AACSetSoundEvent.emptyNew()
    local self = Event.new(setSoundControlEvent_mt)
    return self
end

---@param object table
---@param actionName string
---@param inputValue number
---@param configId integer|nil
---@param groupIndex integer|nil
---@param isSwitch boolean|nil
---@param isSimple boolean|nil -- true when the event targets simple sounds
---@return AACSetSoundEvent
function AACSetSoundEvent.new(object, actionName, inputValue, configId, groupIndex, isSwitch, isSimple)
    local self = AACSetSoundEvent.emptyNew()

    self.object = object
    self.actionName = actionName
    self.inputValue = inputValue or 0
    self.configId = configId or 0
    self.groupIndex = groupIndex or 0
    self.isSwitch = isSwitch == true
    self.isSimple = isSimple == true

    return self
end

function AACSetSoundEvent:readStream(streamId, connection)
    self.object = NetworkUtil.readNodeObject(streamId)
    self.actionName = streamReadString(streamId)
    self.inputValue = streamReadFloat32(streamId)
    self.configId = streamReadInt32(streamId)
    self.groupIndex = streamReadInt32(streamId)
    self.isSwitch = streamReadBool(streamId)
    self.isSimple = streamReadBool(streamId)
    self:run(connection)
end

function AACSetSoundEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.object)
    streamWriteString(streamId, self.actionName)
    streamWriteFloat32(streamId, self.inputValue)
    streamWriteInt32(streamId, self.configId)
    streamWriteInt32(streamId, self.groupIndex)
    streamWriteBool(streamId, self.isSwitch)
    streamWriteBool(streamId, self.isSimple)
end

function AACSetSoundEvent:run(connection)
    if not connection:getIsServer() then
        g_server:broadcastEvent(self, false, connection, self.object)
    end

    if self.isSimple then
        if self.object.handleSimpleSound ~= nil then
            self.object:handleSimpleSound(self.actionName, self.inputValue, true)
        end
    else
        self.object:handleSoundControl(self.actionName, self.inputValue, self.configId, self.isSwitch, true, self.groupIndex)
    end
end

function AACSetSoundEvent.sendEvent(object, actionName, inputValue, configId, groupIndex, isSwitch, isSimple, noEventSend)
    if noEventSend then
        return
    end

    -- prevent network spam for deleted/unsynced objects
    if object == nil or object.isDeleted then
        return
    end
    if object.getIsSynchronized ~= nil and not object:getIsSynchronized() then
        return
    end

    if g_server ~= nil then
        g_server:broadcastEvent(AACSetSoundEvent.new(object, actionName, inputValue, configId, groupIndex, isSwitch, isSimple), nil, nil, object)
    elseif g_client ~= nil and g_client:getServerConnection() ~= nil then
        g_client:getServerConnection():sendEvent(AACSetSoundEvent.new(object, actionName, inputValue, configId, groupIndex, isSwitch, isSimple))
    end
end