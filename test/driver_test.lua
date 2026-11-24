-- Standalone regression harness for the Frigate camera driver.
--
-- Mocks the DriverWorks C4 API with the behaviours observed on real hardware
-- (OS 3.4.3), so that the bugs fixed in v0.8.12-v0.8.15 cannot regress:
--   * C4:AddVariable returns a BOOLEAN, not a variable id (issue #27)
--   * C4:SetVariable raises unless the identifier is a number/string (#27)
--   * C4:RecordHistory does NOT store when passed the metadata table (#24)
--   * Navigator only renders history matching a C4:RegisterEvents registration (#24)
--
-- Usage: lua test/driver_test.lua camera-driver/driver.lua
-- Exit code 0 = all pass, 1 = one or more failures.

local driverPath = arg[1] or error("usage: lua test/driver_test.lua <driver.lua>")

vars, events, history, props = {}, {}, {}, {}
registeredCategory, registeredSubcategory, registeredTypes = nil, nil, {}

-- When true, the metadata-table form of RecordHistory does not store, as on
-- OS 3.4.3. Flip to false to model firmware that accepts it.
rejectTable = true

C4 = {}
function C4:AddVariable(name, value, vtype)
    assert(type(name) == "string", "AddVariable name must be a string")
    vars[name] = value
    return true                      -- firmware returns a boolean, NOT an id
end
function C4:SetVariable(id, value)
    if type(id) ~= "number" and type(id) ~= "string" then
        error("identifier should be a number/string", 2)
    end
    if vars[id] == nil then error("unknown variable: " .. tostring(id), 2) end
    vars[id] = value
end
function C4:FireEvent(name) events[#events + 1] = name end
function C4:RecordHistory(severity, etype, category, subcategory, meta)
    if meta ~= nil and rejectTable then return nil end
    history[#history + 1] = {severity = severity, etype = etype, category = category,
                             subcategory = subcategory, meta = meta}
    return "hist-evnt-recd-uuid"
end
function C4:RegisterEvents(xml)
    registeredCategory    = xml:match('<category name="([^"]+)"')
    registeredSubcategory = xml:match('<subcategory name="([^"]+)"')
    for t in xml:gmatch('<type name="([^"]+)"') do registeredTypes[t] = true end
    return 0
end
function C4:UpdateProperty(name, value) props[name] = value end
function C4:GetProxyDevices() return {[827] = "camera"} end
function C4:GetDeviceID() return 1586 end
function C4:XmlEscapeString(s) return s end
function C4:ErrorLog(msg) end
function C4:AddDynamicBinding() end
function C4:SendToProxy() end
-- Timeline agent. `timelineAgentId` nil models a system where the agent was
-- never installed, which is the common case and must stay a silent no-op.
timelineAgentId   = nil
timelinePayloads  = {}
timelineReply     = "<success>true</success>"
sentToDevice      = {}

function C4:GetDevicesByC4iName(name)
    if name == "agent-timeline.c4z" then
        if not timelineAgentId then return {} end
        return { [timelineAgentId] = "Timeline" }
    end
    if name == "frigate-camera.c4z" then
        return { [1586] = "Frigate Camera" }   -- matches GetDeviceID()
    end
    return {}
end
-- Records the plaintext so a test can assert on the payload the driver built,
-- and returns something that is clearly not the plaintext.
lastBase64Plain = nil
function C4:Base64Encode(str) lastBase64Plain = str; return "B64(" .. #str .. ")" end
function C4:GetDeviceDisplayName(id) return "Back Yard" end
function C4:SendToDevice(id, cmd, params)
    sentToDevice[#sentToDevice + 1] = { id = id, cmd = cmd, params = params }
    if cmd == "SetPastEvent" then
        timelinePayloads[#timelinePayloads + 1] = lastBase64Plain
        return timelineReply
    end
end
function C4:urlEncode(s) return s end
function C4:urlGet() return 0 end
function C4:GetDriverConfigInfo() return "" end
function C4:AllowExecuteDeviceCommand() end
-- Timer callbacks are recorded so a test can run them; the driver looks for
-- agents again on a timer because they are not always up when it loads.
timerCallbacks = {}
function C4:SetTimer(ms, fn)
    if type(fn) == "function" then timerCallbacks[#timerCallbacks + 1] = fn end
    return #timerCallbacks
end
function runTimers()
    local pending = timerCallbacks
    timerCallbacks = {}
    for _, fn in ipairs(pending) do fn() end
end
function C4:KillTimer() end
function C4:GetTime() return "12:00:00" end
function C4:UpdateBoundDevice() end

Properties = {
    ["Camera Name"]  = "bbq",
    ["Frigate Host"] = "192.168.1.50",
    ["Log Level"]    = "1 - Error",
    ["Log Mode"]     = "Off",
}

local realWrite = io.write
print = function() end               -- silence driver logging during load
dofile(driverPath)
OnDriverLateInit()

local failures = 0
function check(desc, ok, detail)
    realWrite(string.format("%-58s %s\n", desc, ok and "PASS" or ("FAIL  " .. tostring(detail))))
    if not ok then failures = failures + 1 end
end

------------------------------------------------------------------------
-- Person detected: variables, events, history, Last Event
------------------------------------------------------------------------
events, history = {}, {}
local ok, err = pcall(ExecuteCommand, "FRIGATE_DETECTION",
    { object_type = "person", count = 1, event_type = "new" })

check("handleDetection(person, new) does not raise", ok, err)
check("PERSON_DETECTED == true", vars.PERSON_DETECTED == "true", vars.PERSON_DETECTED)
check("PERSON_COUNT == 1", vars.PERSON_COUNT == "1", vars.PERSON_COUNT)
check("PERSON_LAST_SEEN populated", (vars.PERSON_LAST_SEEN or "") ~= "")

local fired = {}
for _, e in ipairs(events) do fired[e] = true end
check("fired 'Person Detected'", fired["Person Detected"] == true)
check("fired 'Object Detected'", fired["Object Detected"] == true)

local h = history[1]
check("recorded a history entry", h ~= nil)
check("history severity == Info", h and h.severity == "Info", h and h.severity)
check("history type == 'Person Detected'", h and h.etype == "Person Detected", h and h.etype)
check("history category == 'Cameras'", h and h.category == "Cameras", h and h.category)
check("history subcategory == 'Frigate'", h and h.subcategory == "Frigate", h and h.subcategory)
check("stored via the plain four-argument form", h and h.meta == nil, h and type(h.meta))
check("recorded category matches RegisterEvents",
      h and h.category == registeredCategory, registeredCategory)
check("recorded subcategory matches RegisterEvents",
      h and h.subcategory == registeredSubcategory, registeredSubcategory)
check("recorded type is a registered type",
      h and registeredTypes[h.etype] == true, h and h.etype)
check("Last Event property updated", (props["Last Event"] or "") ~= "")

------------------------------------------------------------------------
-- Person left
------------------------------------------------------------------------
events = {}
ok, err = pcall(ExecuteCommand, "FRIGATE_DETECTION",
    { object_type = "person", count = 0, event_type = "end" })
fired = {}
for _, e in ipairs(events) do fired[e] = true end
check("handleDetection(person, end) does not raise", ok, err)
check("PERSON_DETECTED == false", vars.PERSON_DETECTED == "false", vars.PERSON_DETECTED)
check("fired 'Person Left'", fired["Person Left"] == true)

------------------------------------------------------------------------
-- Motion, delivered as the string "True" the way C4 serialises it
------------------------------------------------------------------------
events = {}
ok, err = pcall(ExecuteCommand, "FRIGATE_MOTION", { active = "True" })
fired = {}
for _, e in ipairs(events) do fired[e] = true end
check("handleMotion(active='True') does not raise", ok, err)
check("MOTION_DETECTED == true", vars.MOTION_DETECTED == "true", vars.MOTION_DETECTED)
check("fired 'Motion Detected'", fired["Motion Detected"] == true)

events = {}
ok, err = pcall(ExecuteCommand, "FRIGATE_MOTION", { active = "false" })
fired = {}
for _, e in ipairs(events) do fired[e] = true end
check("handleMotion(active='false') does not raise", ok, err)
check("MOTION_DETECTED == false", vars.MOTION_DETECTED == "false", vars.MOTION_DETECTED)
check("fired 'Motion Stopped'", fired["Motion Stopped"] == true)

------------------------------------------------------------------------
-- Audio, loitering, health
------------------------------------------------------------------------
ok, err = pcall(ExecuteCommand, "FRIGATE_AUDIO", { audio_type = "speech" })
check("handleAudio(speech) does not raise", ok, err)
check("SPEECH_LAST_HEARD populated", (vars.SPEECH_LAST_HEARD or "") ~= "")

ok, err = pcall(ExecuteCommand, "FRIGATE_LOITERING", { zone = "driveway" })
check("handleLoitering does not raise", ok, err)
check("LOITERING_DETECTED == true", vars.LOITERING_DETECTED == "true", vars.LOITERING_DETECTED)

ok, err = pcall(ExecuteCommand, "FRIGATE_HEALTH", { online = false })
check("handleHealth does not raise", ok, err)
check("CAMERA_ONLINE == false", vars.CAMERA_ONLINE == "false", vars.CAMERA_ONLINE)

------------------------------------------------------------------------
-- FRIGATE_EVENT caches the last event (#25)
------------------------------------------------------------------------
ok, err = pcall(ExecuteCommand, "FRIGATE_EVENT",
    { event_id = "1755012345.678901-abc123", has_snapshot = true, label = "person" })
check("FRIGATE_EVENT does not raise", ok, err)

local le = __lastEvent()
check("cached the event id", le.id == "1755012345.678901-abc123", le.id)
check("cached hasSnapshot", le.hasSnapshot == true, tostring(le.hasSnapshot))
check("stamped a timestamp", type(le.timestamp) == "number" and le.timestamp > 0, le.timestamp)

-- has_snapshot arrives as the STRING "false" over SendToDevice, which is
-- truthy in Lua — the classic C4 serialisation trap.
ok, err = pcall(ExecuteCommand, "FRIGATE_EVENT",
    { event_id = "1755000000.0-nosnap", has_snapshot = "false", label = "car" })
le = __lastEvent()
check("string 'false' has_snapshot treated as false", le.hasSnapshot == false,
      tostring(le.hasSnapshot))

-- A missing event_id must not clobber the cache.
pcall(ExecuteCommand, "FRIGATE_EVENT", { has_snapshot = true })
le = __lastEvent()
check("missing event_id leaves the cache intact", le.id == "1755000000.0-nosnap", le.id)

------------------------------------------------------------------------
-- Notification attachment URL selection (#25)
------------------------------------------------------------------------
local EVENT_URL = "http://192.168.1.50:5000/api/events/1755012345.678901-abc123/snapshot.jpg?bbox=1&h=480"
local LIVE_URL  = "http://192.168.1.50:5000/api/bbq/latest.jpg"

local function setEvent(id, hasSnapshot, ageSeconds)
    local le = __lastEvent()
    le.id, le.hasSnapshot = id, hasSnapshot
    le.timestamp = os.time() - (ageSeconds or 0)
end

Properties["Notification Image Freshness (seconds)"] = "60"

setEvent("1755012345.678901-abc123", true, 0)
check("fresh event returns the event snapshot URL",
      GetNotificationAttachmentURL(1001, {}) == EVENT_URL, GetNotificationAttachmentURL(1001, {}))

setEvent("1755012345.678901-abc123", true, 60)
check("event exactly at the window is still fresh",
      GetNotificationAttachmentURL(1001, {}) == EVENT_URL, GetNotificationAttachmentURL(1001, {}))

setEvent("1755012345.678901-abc123", true, 61)
check("event past the window falls back to live",
      GetNotificationAttachmentURL(1001, {}) == LIVE_URL, GetNotificationAttachmentURL(1001, {}))

setEvent("1755012345.678901-abc123", false, 0)
check("event without a snapshot falls back to live",
      GetNotificationAttachmentURL(1001, {}) == LIVE_URL, GetNotificationAttachmentURL(1001, {}))

setEvent(nil, false, 0)
check("no event at all falls back to live",
      GetNotificationAttachmentURL(1001, {}) == LIVE_URL, GetNotificationAttachmentURL(1001, {}))

Properties["Notification Image Freshness (seconds)"] = "Off"
setEvent("1755012345.678901-abc123", true, 0)
check("freshness Off always returns live",
      GetNotificationAttachmentURL(1001, {}) == LIVE_URL, GetNotificationAttachmentURL(1001, {}))

Properties["Notification Image Freshness (seconds)"] = nil
setEvent("1755012345.678901-abc123", true, 0)
check("absent property defaults to 60s and uses the event",
      GetNotificationAttachmentURL(1001, {}) == EVENT_URL, GetNotificationAttachmentURL(1001, {}))

Properties["Notification Image Freshness (seconds)"] = "60"
local savedHost = Properties["Frigate Host"]
Properties["Frigate Host"] = ""
check("unset host returns empty string", GetNotificationAttachmentURL(1001, {}) == "")
Properties["Frigate Host"] = savedHost

------------------------------------------------------------------------
-- History category switches
------------------------------------------------------------------------
local function historyTypes()
    local t = {}
    for _, h in ipairs(history) do t[h.etype] = true end
    return t
end

-- Motion is the reason these switches exist: frigate/<camera>/motion toggles
-- constantly, so every transition used to land in the history.
history = {}
ExecuteCommand("FRIGATE_MOTION", { active = true })
ExecuteCommand("FRIGATE_MOTION", { active = false })
check("motion is not recorded by default", #history == 0, #history)

local firedMotion = {}
for _, e in ipairs(events) do firedMotion[e] = true end
check("suppressing motion history still fires the Composer event",
      firedMotion["Motion Detected"] == true)

Properties["Record Motion Events"] = "Yes"
history = {}
ExecuteCommand("FRIGATE_MOTION", { active = true })
check("motion is recorded once switched on",
      historyTypes()["Motion Detected"] == true, #history)
Properties["Record Motion Events"] = nil

-- The other categories keep the previous always-record behaviour.
history = {}
ExecuteCommand("FRIGATE_DETECTION", { object_type = "person", count = 1, event_type = "new" })
check("object detections record by default",
      historyTypes()["Person Detected"] == true, #history)

Properties["Record Object Detections"] = "No"
history = {}
ExecuteCommand("FRIGATE_DETECTION", { object_type = "person", count = 1, event_type = "new" })
check("object detections can be switched off", #history == 0, #history)
Properties["Record Object Detections"] = nil

Properties["Record Zone Events"] = "No"
history = {}
ExecuteCommand("FRIGATE_ZONE", { zone = "driveway", object_type = "person", count = 1 })
check("zone events can be switched off", #history == 0, #history)
Properties["Record Zone Events"] = nil

history = {}
ExecuteCommand("FRIGATE_ZONE", { zone = "driveway", object_type = "person", count = 1 })
check("zone events record by default",
      historyTypes()["Zone Entered"] == true, #history)

-- A switch gates what is written, never what Navigator can display: the
-- registration must cover every type so turning one back on needs no reload.
check("motion types stay registered while suppressed",
      registeredTypes["Motion Detected"] and registeredTypes["Motion Stopped"])
check("every object type stays registered",
      registeredTypes["Person Detected"] and registeredTypes["Object Left"])
check("audio and status types stay registered",
      registeredTypes["Audio: Speech"] and registeredTypes["Camera Offline"]
      and registeredTypes["Recording Disabled"])

------------------------------------------------------------------------
-- Timeline agent reporting
------------------------------------------------------------------------
-- No agent installed: the common case, and it must stay silent.
timelineAgentId, timelinePayloads = nil, {}
history = {}
local okNoAgent = pcall(ExecuteCommand, "FRIGATE_DETECTION",
    { object_type = "person", count = 1, event_type = "new" })
check("a missing Timeline agent does not raise", okNoAgent)
check("a missing Timeline agent sends nothing", #timelinePayloads == 0, #timelinePayloads)
check("a missing Timeline agent still records history", #history > 0, #history)
check("status says the agent is not installed",
      (props["Timeline Status"] or ""):find("no Timeline agent") ~= nil,
      props["Timeline Status"])

-- Agent present.
timelineAgentId, timelinePayloads = 4242, {}
OnDriverLateInit()
check("the driver schedules a second look for the agent", #timerCallbacks > 0)
runTimers()                          -- the agent came up after the driver did
check("the retry finds an agent that appeared late",
      (props["Timeline Status"] or ""):find("agent 4242") ~= nil,
      props["Timeline Status"])

-- Object detections feed the history, not the Timeline: the per-camera count
-- topics fire several times per incident, so they make a poor Timeline.
timelinePayloads, history = {}, {}
ExecuteCommand("FRIGATE_DETECTION", { object_type = "person", count = 1, event_type = "new" })
check("an object detection records history but not a Timeline entry",
      #history > 0 and #timelinePayloads == 0,
      ("history=%d timeline=%d"):format(#history, #timelinePayloads))

------------------------------------------------------------------------
-- Review segments drive the Timeline
------------------------------------------------------------------------
local function review(t)
    local p = {
        id = t.id or "rev1", review_type = t.review_type or "end",
        severity = t.severity or "alert",
        start_time = t.start_time or 1755012345,
        objects = t.objects or "person", sub_labels = t.sub_labels or "",
        title = t.title or "", summary = t.summary or "",
        threat_level = t.threat_level or 0,
    }
    ExecuteCommand("FRIGATE_REVIEW", p)
end

-- An ended review is held for its summary rather than reported at once.
Properties["Timeline Summary Wait (seconds)"] = "45"
timelinePayloads, timerCallbacks = {}, {}
review({ id = "rev-hold" })
check("an ended review is not reported immediately", #timelinePayloads == 0)
check("it is held on a timer", #timerCallbacks > 0)

-- The summary arrives before the wait expires: its title is what gets used.
review({ id = "rev-hold", review_type = "genai", title = "Person taking out trash" })
check("the summary is reported as soon as it lands", #timelinePayloads == 1,
      #timelinePayloads)
check("the GenAI title is the Timeline label",
      (timelinePayloads[1] or ""):find('"displayName":"Person taking out trash"') ~= nil,
      timelinePayloads[1])
check("the entry is stamped with the review's own start time, not now",
      (timelinePayloads[1] or ""):find('"timestamp":1755012345') ~= nil,
      timelinePayloads[1])

-- The held timer still fires afterwards; it must not report a second time.
runTimers()
check("the expired hold does not double-report", #timelinePayloads == 1,
      #timelinePayloads)

-- A repeat of the same review id is ignored.
review({ id = "rev-hold", review_type = "genai", title = "Person taking out trash" })
check("a repeated review id is reported once", #timelinePayloads == 1,
      #timelinePayloads)

-- No summary arrives: the object list is the label.
timelinePayloads, timerCallbacks = {}, {}
review({ id = "rev-nogenai", objects = "person, car" })
runTimers()
check("without a summary the object list is used", #timelinePayloads == 1,
      #timelinePayloads)
check("the object list is the Timeline label",
      (timelinePayloads[1] or ""):find('"displayName":"person, car"') ~= nil,
      timelinePayloads[1])

-- A recognised face is worth naming.
timelinePayloads, timerCallbacks = {}, {}
review({ id = "rev-sub", objects = "person", sub_labels = "Joe" })
runTimers()
check("a sub label is named alongside the object",
      (timelinePayloads[1] or ""):find('"displayName":"Joe %(person%)"') ~= nil,
      timelinePayloads[1])

-- Detections are below the bar by default.
timelinePayloads, timerCallbacks = {}, {}
review({ id = "rev-det", severity = "detection" })
runTimers()
check("a review detection is skipped under 'Alerts only'",
      #timelinePayloads == 0, #timelinePayloads)

Properties["Timeline Review Severity"] = "Alerts and detections"
timelinePayloads, timerCallbacks = {}, {}
review({ id = "rev-det2", severity = "detection" })
runTimers()
check("a review detection is reported when both are wanted",
      #timelinePayloads == 1, #timelinePayloads)
Properties["Timeline Review Severity"] = nil

-- Wait Off reports the moment the review ends.
Properties["Timeline Summary Wait (seconds)"] = "Off"
timelinePayloads, timerCallbacks = {}, {}
review({ id = "rev-nowait" })
check("wait Off reports without holding", #timelinePayloads == 1, #timelinePayloads)
Properties["Timeline Summary Wait (seconds)"] = "45"

-- A review with no id cannot be deduplicated, so it is dropped.
timelinePayloads, timerCallbacks = {}, {}
local okNoId = pcall(ExecuteCommand, "FRIGATE_REVIEW", { severity = "alert" })
check("a review without an id is dropped rather than raising", okNoId)
check("a review without an id reports nothing", #timelinePayloads == 0)

-- Its own master switch still wins.
Properties["Timeline Reporting"] = "No"
timelinePayloads, timerCallbacks = {}, {}
review({ id = "rev-off", review_type = "genai", title = "Someone at the door" })
check("Timeline Reporting = No suppresses review reporting",
      #timelinePayloads == 0, #timelinePayloads)
OnPropertyChanged("Timeline Reporting")
check("status reflects being switched off",
      props["Timeline Status"] == "Disabled", props["Timeline Status"])
Properties["Timeline Reporting"] = nil
OnPropertyChanged("Timeline Reporting")

-- A rejecting agent is reported, not swallowed.
timelineReply, timelinePayloads, timerCallbacks = "<success>false</success>", {}, {}
review({ id = "rev-reject", review_type = "genai", title = "Car in driveway" })
check("a rejected event is surfaced in the status",
      (props["Timeline Status"] or ""):find("rejected") ~= nil,
      props["Timeline Status"])
timelineReply = "<success>true</success>"

-- The set of reported ids is bounded: a driver runs for months.
Properties["Timeline Summary Wait (seconds)"] = "Off"
timelinePayloads = {}
for i = 1, 500 do
    review({ id = "bulk-" .. i, review_type = "genai", title = "Event " .. i })
end
check("every distinct review was reported", #timelinePayloads == 500,
      #timelinePayloads)
local seenSize = 0
for _ in pairs(reviewSeenForTest()) do seenSize = seenSize + 1 end
check("the reported-id set stays bounded", seenSize <= 200, seenSize)
-- Trimming must not forget an id recent enough to still see a duplicate.
timelinePayloads = {}
review({ id = "bulk-500", review_type = "genai", title = "Event 500" })
check("a recent id is still deduplicated after trimming",
      #timelinePayloads == 0, #timelinePayloads)
Properties["Timeline Summary Wait (seconds)"] = "45"

------------------------------------------------------------------------
-- GenAI object descriptions
------------------------------------------------------------------------
history, timelinePayloads = {}, {}
ExecuteCommand("FRIGATE_OBJECT_DESCRIPTION",
    { id = "1755012345.1-abc", description = "A delivery driver leaves a parcel by the door." })
check("an object description is recorded in history", #history == 1, #history)
check("the description text is what is stored",
      (history[1] or {}).etype == "Object Described", (history[1] or {}).etype)
check("the description type is registered",
      registeredTypes["Object Described"] == true)
check("a description does not also create a Timeline entry",
      #timelinePayloads == 0, #timelinePayloads)

history = {}
ExecuteCommand("FRIGATE_OBJECT_DESCRIPTION", { id = "x", description = "" })
check("an empty description is ignored", #history == 0, #history)

Properties["Record Object Detections"] = "No"
history = {}
ExecuteCommand("FRIGATE_OBJECT_DESCRIPTION", { id = "x", description = "Someone walked past." })
check("descriptions follow the object-detection switch", #history == 0, #history)
Properties["Record Object Detections"] = nil

realWrite(failures == 0 and "\nALL PASS\n" or ("\n" .. failures .. " FAILURE(S)\n"))
os.exit(failures == 0 and 0 or 1)
