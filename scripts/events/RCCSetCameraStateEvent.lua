---@class RCCSetCameraStateEvent

RCCSetCameraStateEvent = {}
local setCameraStateEvent = Class(RCCSetCameraStateEvent, Event)

InitEventClass(RCCSetCameraStateEvent, "RCCSetCameraStateEvent")

---@return RCCSetCameraStateEvent
function RCCSetCameraStateEvent.emptyNew()
    local self = Event.new(setCameraStateEvent)
    return self
end

function RCCSetCameraStateEvent.new(object, cameraIndex, isActive, wasReverseActive)
    local self = RCCSetCameraStateEvent.emptyNew()

    self.object = object
    self.cameraIndex = cameraIndex
    self.isActive = isActive
    self.wasReverseActive = wasReverseActive

    return self
end

function RCCSetCameraStateEvent:readStream(streamId, connection)
    self.object = NetworkUtil.readNodeObject(streamId)
    self.cameraIndex = streamReadUInt8(streamId)
    self.isActive = streamReadBool(streamId)
    self.wasReverseActive = streamReadBool(streamId)
    
    if self.object == nil or self.object.spec_reverseCameraControl == nil then
        Logging.warning("RCCSetCameraStateEvent: Invalid target vehicle or spec_reverseCameraControl not found")
        return
    end
    
    self:run(connection)
end

function RCCSetCameraStateEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.object)
    streamWriteUInt8(streamId, self.cameraIndex)
    streamWriteBool(streamId, self.isActive)
    streamWriteBool(streamId, self.wasReverseActive)
end

function RCCSetCameraStateEvent:run(connection)
    if not connection:getIsServer() then
        g_server:broadcastEvent(self, false, connection, self.object)
    end

    self.object:setReverseCameraState(self.cameraIndex, self.isActive, self.wasReverseActive, true)
end

function RCCSetCameraStateEvent.sendEvent(object, cameraIndex, isActive, wasReverseActive, noEventSend)
    if noEventSend then
        return
    end

    -- avoid sending for missing/unsynced/deleted objects (can spam net warnings)
    if object == nil or object.isDeleted then
        return
    end
    
    -- CRITICAL: Verify that the object actually has ReverseCameraControl spec
    -- This prevents event routing conflicts with other mods like InteractiveControl
    if object.spec_reverseCameraControl == nil then
        Logging.warning("RCCSetCameraStateEvent.sendEvent: Target object does not have spec_reverseCameraControl. Ignoring event to prevent conflicts with other mods.")
        return
    end
    
    if object.getIsSynchronized ~= nil and not object:getIsSynchronized() then
        return
    end

    if g_server ~= nil then
        g_server:broadcastEvent(RCCSetCameraStateEvent.new(object, cameraIndex, isActive, wasReverseActive), nil, nil, object)
    elseif g_client ~= nil and g_client:getServerConnection() ~= nil then
        g_client:getServerConnection():sendEvent(RCCSetCameraStateEvent.new(object, cameraIndex, isActive, wasReverseActive))
    end
end
