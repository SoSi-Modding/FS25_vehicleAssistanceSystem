---@class BLCSetBeaconLightEvent

BLCSetBeaconLightEvent = {}
local setBeaconLightEvent = Class(BLCSetBeaconLightEvent, Event)

InitEventClass(BLCSetBeaconLightEvent, "BLCSetBeaconLightEvent")

---@return BLCSetBeaconLightEvent
function BLCSetBeaconLightEvent.emptyNew()
    local self = Event.new(setBeaconLightEvent)
    return self
end

function BLCSetBeaconLightEvent.new(object, groupName, state)
    local self = BLCSetBeaconLightEvent.emptyNew()

    self.object = object
    self.groupName = groupName
    self.state = state

    return self
end

function BLCSetBeaconLightEvent:readStream(streamId, connection)
    self.object = NetworkUtil.readNodeObject(streamId)
    self.groupName = streamReadString(streamId)
    self.state = streamReadBool(streamId)
    self:run(connection)
end

function BLCSetBeaconLightEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.object)
    streamWriteString(streamId, self.groupName)
    streamWriteBool(streamId, self.state)
end

function BLCSetBeaconLightEvent:run(connection)
    if not connection:getIsServer() then
        g_server:broadcastEvent(self, false, connection, self.object)
    end

    self.object:setBeaconLightGroupState(self.groupName, self.state, true)
end

function BLCSetBeaconLightEvent.sendEvent(object, groupName, state, noEventSend)
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
        g_server:broadcastEvent(BLCSetBeaconLightEvent.new(object, groupName, state), nil, nil, object)
    elseif g_client ~= nil and g_client:getServerConnection() ~= nil then
        g_client:getServerConnection():sendEvent(BLCSetBeaconLightEvent.new(object, groupName, state))
    end
end
