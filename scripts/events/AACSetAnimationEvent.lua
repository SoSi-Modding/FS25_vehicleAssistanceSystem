---@class AACSetAnimationEvent

AACSetAnimationEvent = {}
local setAnimationPerKeyEvent_event = Class(AACSetAnimationEvent, Event)

InitEventClass(AACSetAnimationEvent, "AACSetAnimationEvent")

---@return AACSetAnimationEvent
function AACSetAnimationEvent.emptyNew()
    local self = Event.new(setAnimationPerKeyEvent_event)
    return self
end

function AACSetAnimationEvent.new(object, actionName)
    local self = AACSetAnimationEvent.emptyNew()

    self.object = object
    self.actionName = actionName

    return self
end

function AACSetAnimationEvent:readStream(streamId, connection)
    self.object = NetworkUtil.readNodeObject(streamId)
    self.actionName = streamReadString(streamId)
    self:run(connection)
end

function AACSetAnimationEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.object)
    streamWriteString(streamId, self.actionName)
end

function AACSetAnimationEvent:run(connection)
    if not connection:getIsServer() then
        g_server:broadcastEvent(self, false, connection, self.object)
    end

    self.object:toggleAnimationActionControl(self.actionName, true)
end

function AACSetAnimationEvent.sendEvent(object, actionName, noEventSend)
    if noEventSend then
        return
    end

    -- avoid sending for missing/unsynced/deleted objects (can spam net warnings)
    if object == nil or object.isDeleted then
        return
    end
    if object.getIsSynchronized ~= nil and not object:getIsSynchronized() then
        return
    end

    if g_server ~= nil then
        g_server:broadcastEvent(AACSetAnimationEvent.new(object, actionName), nil, nil, object)
    elseif g_client ~= nil and g_client:getServerConnection() ~= nil then
        g_client:getServerConnection():sendEvent(AACSetAnimationEvent.new(object, actionName))
    end
end