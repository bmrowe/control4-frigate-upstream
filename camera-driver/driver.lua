--[[
  Frigate Camera Driver for Control4
  Phase 3 — Streams + detection events + history + variables

  Streams:
    MJPEG:    http://<host>:1984/api/stream.mjpeg?src=<cam>[_sub]
    RTSP:     rtsp://<host>:8554/<cam>_sub  (H.264)
    Snapshot: http://<host>:5000/api/<cam>/latest.jpg

  Events received from NVR parent driver via C4:SendToDevice():
    SET_FRIGATE_CONFIG  { host, camera_name, use_sub_stream }
    FRIGATE_DETECTION   { object_type, count, zone, event_type }
    FRIGATE_MOTION      { active }
    FRIGATE_ZONE        { zone, object_type, count }
    FRIGATE_HEALTH      { online }

  Variables exposed for Composer programming:
    PERSON_DETECTED, CAR_DETECTED, DOG_DETECTED, CAT_DETECTED (bool)
    MOTION_DETECTED (bool), CAMERA_ONLINE (bool)
    PERSON_COUNT, CAR_COUNT (int)
    PERSON_LAST_SEEN, CAR_LAST_SEEN, DOG_LAST_SEEN, CAT_LAST_SEEN, MOTION_LAST_SEEN, LOITERING_LAST_SEEN (string)
    AUDIO_LAST_HEARD, SPEECH_LAST_HEARD, BARK_LAST_HEARD, etc. (string)
]]

-- Property name constants
local PROP_VERSION     = "Driver Version"
local PROP_HOST        = "Frigate Host"
local PROP_CAMERA      = "Camera Name"
local PROP_SUB_STREAM  = "Use Sub Stream"
local PROP_STATUS      = "Camera Status"
local PROP_LAST_EVENT  = "Last Event"
local PROP_LAST_MOTION = "Last Motion"
local PROP_LOG_LEVEL   = "Log Level"
local PROP_NOTIFY_FRESHNESS = "Notification Image Freshness (seconds)"

-- History category switches. Frigate toggles frigate/<camera>/motion
-- constantly, so recording every transition buries the object detections the
-- history is there for; that one defaults off and the rest keep the previous
-- behaviour.
local PROP_HIST_REVIEWS = "Record Review Incidents"
local PROP_HIST_OBJECTS = "Record Object Detections"
local PROP_HIST_MOTION  = "Record Motion Events"
local PROP_HIST_ZONES   = "Record Zone Events"
local PROP_HIST_AUDIO   = "Record Audio Events"
local PROP_HIST_STATUS  = "Record Camera Status"

local PROP_TIMELINE          = "Timeline Reporting"
local PROP_TIMELINE_SEVERITY = "Timeline Review Severity"
local PROP_TIMELINE_WAIT     = "Timeline Summary Wait (seconds)"
local PROP_HIST_IMAGES       = "Attach Detection Images"
local PROP_TIMELINE_STATUS = "Timeline Status"

-- The Timeline agent is a separate destination from the history: Navigator
-- renders it as its own scrubbing view. It is absent on systems whose dealer
-- never added it, so reporting is a no-op there rather than an error.
local TIMELINE_AGENT_FILE  = "agent-timeline.c4z"
-- Must match this driver's own package name, or the agent cannot associate
-- the events it is sent with the driver that sent them.
local TIMELINE_SOURCE_FILE = "frigate-camera.c4z"

-- Log levels
local LOG_FATAL   = 0
local LOG_ERROR   = 1
local LOG_WARNING = 2
local LOG_INFO    = 3
local LOG_DEBUG   = 4
local LOG_TRACE   = 5

local LOG_LEVEL_MAP = {
    ["0 - Fatal"]   = LOG_FATAL,
    ["1 - Error"]   = LOG_ERROR,
    ["2 - Warning"] = LOG_WARNING,
    ["3 - Info"]    = LOG_INFO,
    ["4 - Debug"]   = LOG_DEBUG,
    ["5 - Trace"]   = LOG_TRACE,
}

local PROP_LOG_MODE    = "Log Mode"

local function log(level, msg)
    local current = LOG_LEVEL_MAP[Properties[PROP_LOG_LEVEL] or "2 - Warning"] or LOG_WARNING
    if level > current then return end
    local mode = Properties[PROP_LOG_MODE] or "Off"
    if mode == "Off" then return end

    local cam = Properties[PROP_CAMERA] or "?"
    local fullMsg = "[Frigate Camera][" .. cam .. "] " .. msg

    if mode == "Print" or mode == "Print and Log" then
        print(fullMsg)
    end
    if mode == "Log" or mode == "Print and Log" then
        C4:ErrorLog(fullMsg)
    end
end

-- Ports
-- MJPEG and snapshots both served by Frigate API on port 5000
-- go2rtc MJPEG (1984) doesn't start sources on-demand — unusable for Control4
local PORT_HTTP     = 5000
local PORT_RTSP     = 8554

-- Proxy binding ID (must match driver.xml)
local PROXY_ID = 5001

-- Variable names. C4:SetVariable is called by name, NOT with the return
-- value of C4:AddVariable — that return is a boolean, not an identifier,
-- and passing it to SetVariable raises "identifier should be a
-- number/string" (issue #27).
local VAR = {
    -- Boolean
    PERSON_DETECTED    = "PERSON_DETECTED",
    CAR_DETECTED       = "CAR_DETECTED",
    DOG_DETECTED       = "DOG_DETECTED",
    CAT_DETECTED       = "CAT_DETECTED",
    MOTION_DETECTED    = "MOTION_DETECTED",
    CAMERA_ONLINE      = "CAMERA_ONLINE",

    -- Numeric
    PERSON_COUNT       = "PERSON_COUNT",
    CAR_COUNT          = "CAR_COUNT",

    -- State
    DETECTION_ENABLED  = "DETECTION_ENABLED",
    RECORDING_ENABLED  = "RECORDING_ENABLED",
    LOITERING_DETECTED = "LOITERING_DETECTED",

    -- Last-seen timestamps (object/motion/loitering)
    PERSON_LAST_SEEN    = "PERSON_LAST_SEEN",
    CAR_LAST_SEEN       = "CAR_LAST_SEEN",
    DOG_LAST_SEEN       = "DOG_LAST_SEEN",
    CAT_LAST_SEEN       = "CAT_LAST_SEEN",
    MOTION_LAST_SEEN    = "MOTION_LAST_SEEN",
    LOITERING_LAST_SEEN = "LOITERING_LAST_SEEN",

    -- Last-heard timestamps (audio)
    AUDIO_LAST_HEARD          = "AUDIO_LAST_HEARD",
    SPEECH_LAST_HEARD         = "SPEECH_LAST_HEARD",
    BARK_LAST_HEARD           = "BARK_LAST_HEARD",
    SCREAM_LAST_HEARD         = "SCREAM_LAST_HEARD",
    YELL_LAST_HEARD           = "YELL_LAST_HEARD",
    FIRE_ALARM_LAST_HEARD     = "FIRE_ALARM_LAST_HEARD",
    GLASS_BREAKING_LAST_HEARD = "GLASS_BREAKING_LAST_HEARD",
    SIREN_LAST_HEARD          = "SIREN_LAST_HEARD",
    CAR_HORN_LAST_HEARD       = "CAR_HORN_LAST_HEARD",
    MUSIC_LAST_HEARD          = "MUSIC_LAST_HEARD",
}

-- Last Frigate event seen for this camera, used to attach that event's
-- snapshot to push notifications (#25). In-memory only: a driver reload
-- falls back to the live snapshot until the next detection.
local lastEvent = { id = nil, timestamp = 0, hasSnapshot = false }

--- Test accessor. The driver's own code uses the local directly.
function __lastEvent() return lastEvent end

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

local function streamName()
    local cam = Properties[PROP_CAMERA] or ""
    if cam == "" then return nil end
    if Properties[PROP_SUB_STREAM] == "Yes" then
        return cam .. "_sub"
    end
    return cam
end

local function cameraName()
    local cam = Properties[PROP_CAMERA] or ""
    if cam == "" then return nil end
    return cam
end

local function setStatus(msg)
    C4:UpdateProperty(PROP_STATUS, msg)
end

--- Get a human-readable timestamp for history entries.
local function timestamp()
    return os.date("%Y-%m-%d %H:%M:%S")
end

--- Convert a Frigate object type to a friendly name.
--- e.g. "person" -> "Person", "car" -> "Car"
local function friendlyObject(objType)
    if not objType or objType == "" then return "Object" end
    return objType:sub(1, 1):upper() .. objType:sub(2)
end

--- Convert a Frigate zone name to a friendly name.
--- e.g. "illegal_parking" -> "Illegal Parking"
local function friendlyZone(zone)
    if not zone or zone == "" then return "" end
    return zone:gsub("_", " "):gsub("(%a)([%w]*)", function(first, rest)
        return first:upper() .. rest
    end)
end

------------------------------------------------------------------------
-- Variables (Composer conditionals)
------------------------------------------------------------------------

--- Create the driver variables with their initial values.
--- The return value of C4:AddVariable is deliberately ignored — see the
--- VAR table above. Variables are updated by name via setVar().
local function initVariables()
    -- Boolean variables
    C4:AddVariable(VAR.PERSON_DETECTED,    "false", "BOOL")
    C4:AddVariable(VAR.CAR_DETECTED,       "false", "BOOL")
    C4:AddVariable(VAR.DOG_DETECTED,       "false", "BOOL")
    C4:AddVariable(VAR.CAT_DETECTED,       "false", "BOOL")
    C4:AddVariable(VAR.MOTION_DETECTED,    "false", "BOOL")
    C4:AddVariable(VAR.CAMERA_ONLINE,      "true",  "BOOL")

    -- Numeric variables
    C4:AddVariable(VAR.PERSON_COUNT, "0", "NUMBER")
    C4:AddVariable(VAR.CAR_COUNT,    "0", "NUMBER")

    -- State variables
    C4:AddVariable(VAR.DETECTION_ENABLED,  "true",  "BOOL")
    C4:AddVariable(VAR.RECORDING_ENABLED,  "true",  "BOOL")
    C4:AddVariable(VAR.LOITERING_DETECTED, "false", "BOOL")

    -- Last-seen timestamps (object/motion/loitering)
    C4:AddVariable(VAR.PERSON_LAST_SEEN,    "", "STRING")
    C4:AddVariable(VAR.CAR_LAST_SEEN,       "", "STRING")
    C4:AddVariable(VAR.DOG_LAST_SEEN,       "", "STRING")
    C4:AddVariable(VAR.CAT_LAST_SEEN,       "", "STRING")
    C4:AddVariable(VAR.MOTION_LAST_SEEN,    "", "STRING")
    C4:AddVariable(VAR.LOITERING_LAST_SEEN, "", "STRING")

    -- Last-heard timestamps (audio)
    C4:AddVariable(VAR.AUDIO_LAST_HEARD,          "", "STRING")
    C4:AddVariable(VAR.SPEECH_LAST_HEARD,         "", "STRING")
    C4:AddVariable(VAR.BARK_LAST_HEARD,           "", "STRING")
    C4:AddVariable(VAR.SCREAM_LAST_HEARD,         "", "STRING")
    C4:AddVariable(VAR.YELL_LAST_HEARD,           "", "STRING")
    C4:AddVariable(VAR.FIRE_ALARM_LAST_HEARD,     "", "STRING")
    C4:AddVariable(VAR.GLASS_BREAKING_LAST_HEARD, "", "STRING")
    C4:AddVariable(VAR.SIREN_LAST_HEARD,          "", "STRING")
    C4:AddVariable(VAR.CAR_HORN_LAST_HEARD,       "", "STRING")
    C4:AddVariable(VAR.MUSIC_LAST_HEARD,          "", "STRING")
end

--- Update a driver variable by name. Never let a bad variable name abort
--- the calling handler — a failed SetVariable must not stop events from
--- firing (issue #27).
local function setVar(varName, value)
    if type(varName) ~= "string" or varName == "" then
        log(LOG_ERROR, "setVar called with invalid variable name: " .. tostring(varName))
        return
    end
    local ok, err = pcall(function()
        C4:SetVariable(varName, tostring(value))
    end)
    if not ok then
        log(LOG_ERROR, "SetVariable failed for " .. varName .. ": " .. tostring(err))
    end
end

------------------------------------------------------------------------
-- History (visible in Control4 app + touchscreens)
------------------------------------------------------------------------

--- History category/subcategory. These MUST match the values registered with
--- C4:RegisterEvents() in registerNotificationEvents() below — the registration
--- declares which (category, subcategory, type) tuples this device emits, and
--- Navigator only surfaces recorded events that match a registration. Recording
--- under a different category is why history was invisible in the Control4 app
--- despite appearing in the History agent (issue #24).
local HISTORY_CATEGORY    = "Cameras"
local HISTORY_SUBCATEGORY = "Frigate"

-- Every event type that can reach the history, with the category that gates
-- it. RegisterEvents is generated from this list, so a type cannot be
-- recorded without also being registered -- previously the two were parallel
-- lists kept in step by hand.
local HISTORY_EVENTS = {
    -- Object detection
    { "Person Detected", "objects" }, { "Person Left", "objects" },
    { "Car Detected",    "objects" }, { "Car Left",    "objects" },
    { "Dog Detected",    "objects" }, { "Dog Left",    "objects" },
    { "Cat Detected",    "objects" }, { "Cat Left",    "objects" },
    { "Object Detected", "objects" }, { "Object Left", "objects" },
    -- Motion
    { "Motion Detected", "motion" },  { "Motion Stopped", "motion" },
    -- Zones
    { "Zone Entered", "zones" }, { "Zone Exited", "zones" },
    { "Loitering Detected", "zones" },
    -- Health
    { "Camera Online", "status" }, { "Camera Offline", "status" },
    -- Audio detection
    { "Audio: Speech", "audio" }, { "Audio: Bark", "audio" },
    { "Audio: Scream", "audio" },  { "Audio: Yell", "audio" },
    { "Audio: Fire Alarm", "audio" }, { "Audio: Glass Breaking", "audio" },
    { "Audio: Siren", "audio" }, { "Audio: Car Horn", "audio" },
    { "Audio: Music", "audio" },
    -- Review incidents
    { "Review Alert", "reviews" },
    -- GenAI object descriptions
    { "Object Described", "objects" },
    -- State changes
    { "Detection Enabled", "status" }, { "Detection Disabled", "status" },
    { "Recording Enabled", "status" }, { "Recording Disabled", "status" },
}

local HISTORY_CATEGORY_OF = {}
for _, e in ipairs(HISTORY_EVENTS) do HISTORY_CATEGORY_OF[e[1]] = e[2] end

local HISTORY_CATEGORY_PROP = {
    reviews = PROP_HIST_REVIEWS,
    objects = PROP_HIST_OBJECTS,
    motion  = PROP_HIST_MOTION,
    zones   = PROP_HIST_ZONES,
    audio   = PROP_HIST_AUDIO,
    status  = PROP_HIST_STATUS,
}

-- Default for a property Composer has not written yet. Only motion differs
-- from the previous always-record behaviour.
local HISTORY_CATEGORY_DEFAULT = {
    reviews = true, objects = true, motion = false,
    zones = true, audio = true, status = true,
}

--- Whether this event type should be written to the history.
--- An unknown type records, so adding one cannot silently lose it.
local function historyEnabled(eventType)
    local category = HISTORY_CATEGORY_OF[eventType]
    if not category then return true end
    local value = Properties[HISTORY_CATEGORY_PROP[category]]
    if value == nil or value == "" then
        return HISTORY_CATEGORY_DEFAULT[category]
    end
    return value == "Yes"
end

------------------------------------------------------------------------
-- Timeline Agent
------------------------------------------------------------------------

local timelineId          = nil
local timelineResolveAfter = 0
local timelineFileOk      = nil

local function setTimelineStatus(text)
    pcall(C4.UpdateProperty, C4, PROP_TIMELINE_STATUS, tostring(text or ""))
end

--- Confirm the agent will see our events as coming from this driver.
--- A mismatch is not fatal, but the events will not be attributed, so it is
--- worth saying out loud rather than leaving as a silent oddity.
local function verifyTimelineSourceFile()
    local me = C4:GetDeviceID()
    local found = false
    pcall(function()
        for id in pairs(C4:GetDevicesByC4iName(TIMELINE_SOURCE_FILE) or {}) do
            if tonumber(id) == tonumber(me) then found = true end
        end
    end)
    timelineFileOk = found
    if not found then
        log(LOG_WARNING, "Timeline: source fileName '" .. TIMELINE_SOURCE_FILE
            .. "' does not match this driver's package — events may not be "
            .. "associated with it")
    end
    return found
end

--- Locate the Timeline agent, retrying at most once a minute while absent.
local function resolveTimeline(force)
    if not force and not timelineId and os.time() < timelineResolveAfter then
        return nil
    end
    local id
    pcall(function() id = next(C4:GetDevicesByC4iName(TIMELINE_AGENT_FILE)) end)
    timelineId = id
    timelineResolveAfter = id and 0 or (os.time() + 60)
    if id then
        log(LOG_INFO, "Timeline: agent at device " .. tostring(id))
        verifyTimelineSourceFile()
    else
        log(LOG_DEBUG, "Timeline: agent not present — skipping")
    end
    return id
end

local function tlEscape(v)
    v = tostring(v or ""):gsub("\\", "\\\\"):gsub('"', '\\"')
    return (v:gsub("[\r\n\t]", { ["\r"] = "\\r", ["\n"] = "\\n", ["\t"] = "\\t" }))
end

-- Unseeded, every camera runs from identical state and emits the same
-- sequence of "unique" ids. The device id is what makes each stream distinct.
local tlSeeded = false
local function tlSeedRandom()
    if tlSeeded then return end
    tlSeeded = true
    local entropy = os.time() * 1000
    pcall(function() entropy = entropy + (tonumber(C4:GetDeviceID()) or 0) * 7919 end)
    entropy = entropy + math.floor((os.clock() * 1000000) % 100000)
    math.randomseed(entropy % 2147483647)
    for _ = 1, 8 do math.random() end
end

local function tlUuid()
    tlSeedRandom()
    local t = {}
    for i = 1, 8 do t[i] = ("%04x"):format(math.random(0, 0xffff)) end
    return ("%s%s-%s-4%s-%s-%s%s%s"):format(t[1], t[2], t[3], t[4]:sub(2),
        t[5], t[6], t[7], t[8])
end

--- Report one event to the Timeline agent.
--- Gated by the same category switches as the history, so motion does not
--- flood the Timeline either, plus its own master switch.
local function reportTimeline(eventType, ts)
    if (Properties[PROP_TIMELINE] or "Yes") ~= "Yes" then return end
    if not timelineId then resolveTimeline() end
    if not timelineId then return end

    local disp = cameraName()
    if not disp or disp == "" then
        pcall(function() disp = C4:GetDeviceDisplayName(C4:GetDeviceID()) end)
    end

    local eventId = tlUuid()
    local json = table.concat({
        '{"source":{',
            '"deviceId":', tostring(C4:GetDeviceID()), ',',
            '"displayName":"', tlEscape(disp or "Camera"), '",',
            '"fileName":"', tlEscape(TIMELINE_SOURCE_FILE), '"',
        '},"event":{',
            '"id":"', eventId, '",',
            '"displayName":"', tlEscape(eventType), '",',
            '"timestamp":', tostring(math.floor(ts or os.time())),
        '}}',
    })

    local b64
    if not pcall(function() b64 = C4:Base64Encode(json) end) or not b64 then
        log(LOG_WARNING, "Timeline: Base64Encode failed")
        return
    end

    local reply
    pcall(function()
        reply = C4:SendToDevice(timelineId, "SetPastEvent", { payload = b64 })
    end)

    if tostring(reply) == "<success>true</success>" then
        log(LOG_DEBUG, "Timeline: reported " .. eventType)
        setTimelineStatus("Reported " .. eventType .. " (agent "
            .. tostring(timelineId) .. ")")
    else
        log(LOG_WARNING, "Timeline: agent rejected the event — " .. tostring(reply))
        setTimelineStatus("Agent " .. tostring(timelineId)
            .. " rejected the last event")
    end
end

--- Describe the Timeline setup in Composer without waiting for a detection.
local function refreshTimelineStatus()
    if (Properties[PROP_TIMELINE] or "Yes") ~= "Yes" then
        setTimelineStatus("Disabled")
        return
    end
    if not timelineId then resolveTimeline() end
    if not timelineId then
        setTimelineStatus("Enabled — but no Timeline agent is installed")
    elseif timelineFileOk == false then
        setTimelineStatus("Enabled — agent " .. tostring(timelineId)
            .. ", but this driver's fileName does not match")
    else
        setTimelineStatus("Enabled — agent " .. tostring(timelineId)
            .. ", waiting for a detection")
    end
end

------------------------------------------------------------------------
-- History agent (detection images)
------------------------------------------------------------------------
--
-- C4:RecordHistory writes a text row and offers no way to attach a picture.
-- The History agent does: RECORD_HISTORICAL_EVENT returns a record uuid, and
-- SET_METADATA_ON_RECORD attaches `media_filename` to it. That value is a
-- path on the controller's own filesystem, not a URL, so the image has to be
-- fetched to disk first -- which is the whole reason this pipeline exists
-- rather than simply handing Frigate's snapshot URL to Control4.

--- Frigate's REST API base, or "" when the host is not configured yet.
local function frigateBase()
    local host = Properties[PROP_HOST] or ""
    if host == "" then return "" end
    return "http://" .. host .. ":" .. PORT_HTTP
end

--- The proxy device the history is recorded against. Navigator matches a
--- stored record to a registration by this id, so both must use the same one.
local function proxyDeviceIdForHistory()
    local proxyDevices = C4:GetProxyDevices()
    if type(proxyDevices) ~= "table" then return nil end
    for id in pairs(proxyDevices) do return id end
    return nil
end

local HISTORY_AGENT_NAMES = {
    "history.c4i", "history.c4z",
    "agent_history.c4i", "agent_history.c4z",
    "control4_agent_history.c4i", "control4_agent_history.c4z",
    "agent-history.c4z",
}

local historyAgentId    = nil
local historyAgentAfter = 0

local function resolveHistoryAgent(force)
    if not force and not historyAgentId and os.time() < historyAgentAfter then
        return nil
    end
    for _, fn in ipairs(HISTORY_AGENT_NAMES) do
        local id
        pcall(function() id = next(C4:GetDevicesByC4iName(fn)) end)
        if id then
            historyAgentId, historyAgentAfter = id, 0
            log(LOG_INFO, "History agent: found '" .. fn .. "' at device " .. tostring(id))
            return id
        end
    end
    for _, nm in ipairs({ "History", "History Agent" }) do
        local id
        pcall(function()
            for devId, devName in pairs(C4:GetDevicesByName(nm) or {}) do
                if tostring(devName) == nm then id = devId end
            end
        end)
        if id then
            historyAgentId, historyAgentAfter = id, 0
            log(LOG_INFO, "History agent: found by name '" .. nm .. "' at device " .. tostring(id))
            return id
        end
    end
    historyAgentAfter = os.time() + 60
    log(LOG_DEBUG, "History agent: not found — entries will be text only")
    return nil
end

-- Images are written to a small ring of files rather than accumulating: a
-- busy camera would otherwise fill the controller's disk over months.
local IMAGE_SLOTS   = 20
local IMAGE_MAX     = 2 * 1024 * 1024
local imageSlot     = 0
local imageInFlight = 0
local IMAGE_IN_FLIGHT_MAX = 4

--- Fetch a JPEG to a local file and hand its path to `cb`, or nil.
local function fetchImage(url, cb)
    if imageInFlight >= IMAGE_IN_FLIGHT_MAX then
        log(LOG_DEBUG, "Image fetch skipped — " .. imageInFlight .. " already in flight")
        cb(nil)
        return
    end

    imageSlot = (imageSlot % IMAGE_SLOTS) + 1
    local name = ("detection_%02d.jpg"):format(imageSlot)
    local dir
    pcall(function() dir = C4:GetDriverFileDirectory() end)
    local path = (dir and dir ~= "") and (dir .. "/" .. name) or name

    imageInFlight = imageInFlight + 1
    local done = false
    local function finish(result)
        if done then return end
        done = true
        imageInFlight = math.max(0, imageInFlight - 1)
        cb(result)
    end

    local ok = pcall(function()
        C4:urlGet(url, { ["Accept"] = "image/jpeg" }, false,
            function(ticket, data, code, headers, err)
                if code ~= 200 or not data or #data < 200 then
                    log(LOG_DEBUG, "Image fetch failed: code=" .. tostring(code)
                        .. " err=" .. tostring(err))
                    finish(nil); return
                end
                if #data > IMAGE_MAX then
                    log(LOG_DEBUG, "Image is " .. #data .. " bytes, over the cap — ignoring")
                    finish(nil); return
                end
                -- A Frigate error page returns 200 with HTML; only a real JPEG
                -- is worth attaching, and the magic bytes are the cheap check.
                if data:byte(1) ~= 0xff or data:byte(2) ~= 0xd8 then
                    log(LOG_DEBUG, "Response is not a JPEG — ignoring")
                    finish(nil); return
                end
                local f = io.open(path, "wb")
                if not f then
                    log(LOG_WARNING, "Cannot write " .. path)
                    finish(nil); return
                end
                f:write(data); f:close()
                log(LOG_DEBUG, "Wrote " .. path .. " (" .. #data .. " bytes)")
                finish(path)
            end)
    end)
    if not ok then finish(nil) end
end

--- Record through the History agent so an image can be attached.
--- Returns the record uuid, or nil when the agent is unavailable.
local function recordViaAgent(severity, eventType, description)
    if not historyAgentId then resolveHistoryAgent() end
    if not historyAgentId then return nil end

    local reply
    local ok = pcall(function()
        reply = C4:SendUIRequest(historyAgentId, "RECORD_HISTORICAL_EVENT", {
            DEVICE_ID   = proxyDeviceIdForHistory(),
            SEVERITY    = severity,
            CATEGORY    = HISTORY_CATEGORY,
            SUBCATEGORY = HISTORY_SUBCATEGORY,
            TYPE        = eventType,
            DESCRIPTION = description,
        })
    end)
    if not ok or not reply then
        log(LOG_DEBUG, "History agent: RECORD_HISTORICAL_EVENT failed")
        return nil
    end

    local uuid
    pcall(function()
        local parsed = C4:ParseXml(reply)
        if parsed and parsed.Name == "uuid" then uuid = parsed.Value end
    end)
    if not uuid then uuid = tostring(reply):match("<uuid>([^<]+)</uuid>") end
    return uuid
end

--- Attach a already-downloaded image to a record the agent returned.
local function attachImage(uuid, path)
    if not uuid or not path or path == "" or not historyAgentId then return end
    pcall(function()
        C4:SendToDevice(historyAgentId, "SET_METADATA_ON_RECORD", {
            RECORD_UUID    = uuid,
            METADATA_NAME  = "media_filename",
            METADATA_VALUE = path,
        })
    end)
    log(LOG_DEBUG, "Attached " .. path .. " to record " .. uuid)
end

-- Forward declaration: a review incident is recorded in the history, but
-- recordHistory needs the agent helpers above, so it is defined after this.
local recordHistory

------------------------------------------------------------------------
-- Review segments
------------------------------------------------------------------------
--
-- A review segment is one incident. Object-count topics fire several times
-- per incident, so they make a poor Timeline: a single "Person taking out
-- trash" beats eight rows of "Person Detected". Frigate ends a segment
-- before its GenAI summary exists, so an ended segment is held briefly to
-- see whether a title arrives; the Timeline entry is stamped with the
-- segment's own start time, so the wait does not move it.

-- Reported ids are remembered only to suppress the duplicate that arrives
-- when a held review's timer fires after its summary already did. A driver
-- runs for months, so the set is bounded rather than left to grow.
local REVIEW_SEEN_MAX = 200
local reviewSeen      = {}   -- review id -> sequence number
local reviewSeenCount = 0
local reviewSeenSeq   = 0
local reviewPending   = {}   -- review id -> { timer, params }

local function rememberReview(id)
    if reviewSeen[id] then return end
    reviewSeenSeq   = reviewSeenSeq + 1
    reviewSeen[id]  = reviewSeenSeq
    reviewSeenCount = reviewSeenCount + 1
    if reviewSeenCount <= REVIEW_SEEN_MAX then return end
    -- Drop the oldest half, so trimming is occasional rather than per-event.
    local cutoff = reviewSeenSeq - (REVIEW_SEEN_MAX / 2)
    for k, seq in pairs(reviewSeen) do
        if seq <= cutoff then
            reviewSeen[k] = nil
            reviewSeenCount = reviewSeenCount - 1
        end
    end
end

local function reviewWaitSeconds()
    local raw = Properties[PROP_TIMELINE_WAIT]
    if raw == nil or raw == "" then return 45 end
    if raw == "Off" then return 0 end
    return tonumber(raw) or 45
end

-- Test seam: the harness asserts the set stays bounded over a long run.
function reviewSeenForTest() return reviewSeen end

--- What to call this incident on the Timeline.
--- The GenAI title when there is one, otherwise the objects Frigate saw.
local function reviewLabel(p)
    local title = p.title
    if title and title ~= "" then return title end
    local objects = p.objects
    if objects and objects ~= "" then
        local subs = p.sub_labels
        if subs and subs ~= "" then return subs .. " (" .. objects .. ")" end
        return objects
    end
    return "Activity"
end

local function emitReview(id, p)
    if reviewSeen[id] then return end
    rememberReview(id)
    reviewPending[id] = nil

    local label = reviewLabel(p)
    reportTimeline(label, tonumber(p.start_time))

    -- The incident is also worth a history entry, and unlike the Timeline the
    -- history can carry the picture. The review names the tracked objects it
    -- was built from, so the first one's snapshot is the image for the whole
    -- incident.
    local description = p.summary
    if not description or description == "" then description = label end
    recordHistory(description, (tonumber(p.threat_level) or 0) >= 2 and "Warning" or "Info",
                  "Review Alert", (p.detections or ""):match("^[^,]+"))
end

--- Handle a review segment forwarded by the NVR.
--- tParams: { id, review_type, severity, start_time, end_time,
---            objects, sub_labels, zones, title, summary, threat_level }
local function handleReview(tParams)
    local id = tParams.id or ""
    if id == "" then return end

    local wanted = Properties[PROP_TIMELINE_SEVERITY] or "Alerts only"
    local severity = tParams.severity or ""
    if wanted == "Alerts only" and severity ~= "alert" then
        log(LOG_DEBUG, "Review " .. id .. " is a " .. severity .. " — skipping")
        return
    end

    -- The summary landed: report now with the title, cancelling any wait.
    if (tParams.review_type or "") == "genai" then
        local pending = reviewPending[id]
        if pending and pending.timer then pcall(C4.KillTimer, C4, pending.timer) end
        emitReview(id, tParams)
        return
    end

    if reviewSeen[id] or reviewPending[id] then return end

    local wait = reviewWaitSeconds()
    if wait <= 0 then
        emitReview(id, tParams)
        return
    end

    -- Hold for a summary. If none arrives, the object list is a fair label.
    local entry = { params = tParams }
    reviewPending[id] = entry
    entry.timer = C4:SetTimer(wait * 1000, function()
        local held = reviewPending[id]
        if held then
            log(LOG_DEBUG, "Review " .. id .. ": no summary after "
                .. wait .. "s — reporting the object list")
            emitReview(id, held.params)
        end
    end)
end

--- Record an event in the history database.
---
--- Signature per the DriverWorks API reference (Helper Interface, 1.6.0+):
---   C4:RecordHistory(severity, eventType, category, subcategory, metadata)
---     severity     "Critical" | "Warning" | "Info"
---     eventType    the specific event, e.g. "Person Detected" — this is the
---                  text Navigator displays, and must match a registered type
---     category     "Cameras"
---     subcategory  optional — "Frigate"
---     metadata     optional table of name-value pairs (NOT a description string)
---
--- Returns the UUID of the stored record, or nil if it was not recorded — so
--- the return value is a reliable success check. Matches the call pattern used
--- by shipping third-party camera drivers.
--- The four-argument form is the one used by shipping third-party camera
--- drivers and is treated as authoritative. The optional metadata table is
--- documented but was observed to stop records being stored on OS 3.4.3
--- (v0.8.14-beta regression), so it is attempted only as an enhancement and
--- immediately falls back to the plain form if it does not return a UUID.
--- `eventId` is a Frigate event id; when one is given and images are on, the
--- entry is recorded through the History agent so its snapshot can be
--- attached. Everything else goes the plain C4:RecordHistory route.
function recordHistory(message, severity, eventType, eventId)
    severity = severity or "Info"
    if severity ~= "Info" and severity ~= "Warning" and severity ~= "Critical" then
        severity = "Info"
    end
    eventType = eventType or "Camera Event"

    if not historyEnabled(eventType) then
        log(LOG_DEBUG, "History suppressed by settings: " .. eventType)
        return
    end

    -- An entry with a picture is worth far more than one without, but only the
    -- agent route can carry one. Fall through to the API when the agent is
    -- missing or declines, so a missing agent costs the image, not the entry.
    if eventId and eventId ~= "" and (Properties[PROP_HIST_IMAGES] or "Yes") == "Yes" then
        local uuid = recordViaAgent(severity, eventType, tostring(message))
        if uuid then
            local base = frigateBase()
            if base ~= "" then
                fetchImage(base .. "/api/events/" .. eventId .. "/snapshot.jpg?bbox=1&h=480",
                    function(path) attachImage(uuid, path) end)
            end
            log(LOG_DEBUG, "History recorded via agent: " .. eventType .. " (" .. uuid .. ")")
            return
        end
        log(LOG_DEBUG, "History agent unavailable — recording " .. eventType
            .. " through the API, without an image")
    end

    local function record(...)
        local ok, uuid = pcall(C4.RecordHistory, C4, ...)
        if not ok then return nil, tostring(uuid) end
        if uuid == nil or uuid == "" then return nil, nil end
        return uuid, nil
    end

    -- Plain four-argument form first: proven, and the one that matters.
    local uuid, err = record(severity, eventType, HISTORY_CATEGORY, HISTORY_SUBCATEGORY)

    if uuid then
        log(LOG_DEBUG, "History recorded: " .. eventType .. " (" .. uuid .. ")")
        return
    end

    -- Only if the plain form failed, try with the documented metadata table —
    -- covers firmware where the extra argument is required rather than fatal.
    local uuid2, err2 = record(severity, eventType, HISTORY_CATEGORY, HISTORY_SUBCATEGORY,
                               { Description = tostring(message),
                                 Camera      = cameraName() or "" })
    if uuid2 then
        log(LOG_DEBUG, "History recorded (with metadata): " .. eventType .. " (" .. uuid2 .. ")")
        return
    end

    log(LOG_WARNING, "RecordHistory did not store '" .. tostring(message)
        .. "' — plain form: " .. (err or "nil UUID")
        .. "; with metadata: " .. (err2 or "nil UUID")
        .. ". Check the History agent is installed and running.")
end

--- Handle a GenAI description of a tracked object, forwarded by the NVR.
--- It arrives long after the detection, so it is its own history entry
--- rather than an amendment to one already written.
local function handleObjectDescription(tParams)
    local description = tParams.description or ""
    if description == "" then return end
    recordHistory(description, "Info", "Object Described", tParams.id)
end

------------------------------------------------------------------------
-- Event Firing (for Composer programming)
------------------------------------------------------------------------

--- Event name to numeric ID mapping (must match driver.xml <event><id>).
local EVENT_IDS = {
    ["Person Detected"]      = 1,
    ["Person Left"]          = 2,
    ["Car Detected"]         = 3,
    ["Car Left"]             = 4,
    ["Dog Detected"]         = 5,
    ["Cat Detected"]         = 6,
    ["Object Detected"]      = 7,
    ["Object Left"]          = 8,
    ["Motion Detected"]      = 9,
    ["Motion Stopped"]  = 10,
    ["Zone Entered"]         = 11,
    ["Zone Exited"]          = 12,
    ["Loitering Detected"]   = 13,
    ["Camera Online"]        = 14,
    ["Camera Offline"]       = 15,
    ["Audio: Speech"]        = 16,
    ["Audio: Bark"]          = 17,
    ["Audio: Scream"]        = 18,
    ["Audio: Yell"]          = 19,
    ["Audio: Fire Alarm"]    = 20,
    ["Audio: Glass Breaking"] = 21,
    ["Audio: Siren"]         = 22,
    ["Audio: Car Horn"]      = 23,
    ["Audio: Music"]         = 24,
    ["Audio Detected"]       = 25,
    ["Detection Enabled"]    = 26,
    ["Detection Disabled"]   = 27,
    ["Recording Enabled"]    = 28,
    ["Recording Disabled"]   = 29,
}

--- Fire a named event declared in driver.xml <events>.
local function fireEvent(eventName)
    local eventId = EVENT_IDS[eventName]
    if eventId then
        C4:FireEvent(eventName)
        log(LOG_DEBUG, "Fired event: " .. eventName .. " (id=" .. eventId .. ")")
    end
end

------------------------------------------------------------------------
-- Detection Event Handlers (called by NVR driver via SendToDevice)
------------------------------------------------------------------------

--- Handle object detection count changes from MQTT.
--- tParams: { object_type="person", count=1, event_type="new"|"update"|"end" }
local function handleDetection(tParams)
    local objType = tParams.object_type or "object"
    local count = tonumber(tParams.count) or 0
    local eventType = tParams.event_type or ""
    local cam = cameraName() or "camera"
    local friendly = friendlyObject(objType)
    local ts = timestamp()

    if objType == "person" then
        setVar(VAR.PERSON_COUNT, count)
        setVar(VAR.PERSON_DETECTED, count > 0 and "true" or "false")
        if count > 0 then setVar(VAR.PERSON_LAST_SEEN, ts) end
        if count > 0 and eventType == "new" then
            fireEvent("Person Detected")
            fireEvent("Object Detected")
            recordHistory(friendly .. " detected", "Info", friendly .. " Detected")
        elseif count == 0 then
            fireEvent("Person Left")
            fireEvent("Object Left")
            recordHistory(friendly .. " left", "Info", friendly .. " Left")
        end
    elseif objType == "car" then
        setVar(VAR.CAR_COUNT, count)
        setVar(VAR.CAR_DETECTED, count > 0 and "true" or "false")
        if count > 0 then setVar(VAR.CAR_LAST_SEEN, ts) end
        if count > 0 and eventType == "new" then
            fireEvent("Car Detected")
            fireEvent("Object Detected")
            recordHistory(friendly .. " detected", "Info", friendly .. " Detected")
        elseif count == 0 then
            fireEvent("Car Left")
            fireEvent("Object Left")
            recordHistory(friendly .. " left", "Info", friendly .. " Left")
        end
    elseif objType == "dog" then
        setVar(VAR.DOG_DETECTED, count > 0 and "true" or "false")
        if count > 0 then setVar(VAR.DOG_LAST_SEEN, ts) end
        if count > 0 and eventType == "new" then
            fireEvent("Dog Detected")
            fireEvent("Object Detected")
            recordHistory(friendly .. " detected", "Info", friendly .. " Detected")
        elseif count == 0 then
            fireEvent("Object Left")
            recordHistory(friendly .. " left", "Info", friendly .. " Left")
        end
    elseif objType == "cat" then
        setVar(VAR.CAT_DETECTED, count > 0 and "true" or "false")
        if count > 0 then setVar(VAR.CAT_LAST_SEEN, ts) end
        if count > 0 and eventType == "new" then
            fireEvent("Cat Detected")
            fireEvent("Object Detected")
            recordHistory(friendly .. " detected", "Info", friendly .. " Detected")
        elseif count == 0 then
            fireEvent("Object Left")
            recordHistory(friendly .. " left", "Info", friendly .. " Left")
        end
    else
        -- Generic object
        if count > 0 and eventType == "new" then
            fireEvent("Object Detected")
            recordHistory(friendly .. " detected", "Info", friendly .. " Detected")
        elseif count == 0 then
            fireEvent("Object Left")
            recordHistory(friendly .. " left", "Info", friendly .. " Left")
        end
    end

    C4:UpdateProperty(PROP_LAST_EVENT, friendly .. (count > 0 and " detected" or " left") .. " — " .. ts)
end

--- Handle motion on/off from MQTT.
--- tParams: { active=true|false }
local function handleMotion(tParams)
    local raw = tParams.active
    log(LOG_DEBUG, "handleMotion: active = " .. tostring(raw) .. " (type: " .. type(raw) .. ")")
    local active = (raw ~= false and raw ~= "false" and raw ~= "False" and raw ~= 0 and raw ~= "0" and raw ~= nil)
    setVar(VAR.MOTION_DETECTED, active and "true" or "false")

    if active then
        local ts = timestamp()
        setVar(VAR.MOTION_LAST_SEEN, ts)
        C4:UpdateProperty(PROP_LAST_MOTION, ts)
        fireEvent("Motion Detected")
        recordHistory("Motion detected", "Info", "Motion Detected")
    else
        fireEvent("Motion Stopped")
        recordHistory("Motion stopped", "Info", "Motion Stopped")
    end
end

--- Handle zone events from MQTT.
--- tParams: { zone="zone_name", object_type="person", count=1 }
local function handleZone(tParams)
    local zone = tParams.zone or ""
    local objType = tParams.object_type or "object"
    local count = tonumber(tParams.count) or 0
    local friendly = friendlyObject(objType)
    local friendlyZ = friendlyZone(zone)

    if count > 0 then
        fireEvent("Zone Entered")
        recordHistory(friendly .. " entered zone: " .. friendlyZ, "Info", "Zone Entered")
    else
        -- Reset loitering when zone clears
        setVar(VAR.LOITERING_DETECTED, "false")
        fireEvent("Zone Exited")
        recordHistory(friendly .. " left zone: " .. friendlyZ, "Info", "Zone Exited")
    end
end

--- Handle loitering events from MQTT.
--- tParams: { zone="zone_name", object_type="person" }
local function handleLoitering(tParams)
    local zone = tParams.zone or ""
    local objType = tParams.object_type or "object"
    local friendly = friendlyObject(objType)
    local friendlyZ = friendlyZone(zone)

    setVar(VAR.LOITERING_DETECTED, "true")
    setVar(VAR.LOITERING_LAST_SEEN, timestamp())

    fireEvent("Loitering Detected")
    recordHistory(friendly .. " loitering in zone: " .. friendlyZ, "Warning", "Loitering Detected")
    C4:UpdateProperty(PROP_LAST_EVENT, friendly .. " loitering in " .. friendlyZ .. " — " .. timestamp())
end

--- Handle camera health status.
--- tParams: { online=true|false }
local function handleHealth(tParams)
    local raw = tParams.online
    local online = (raw ~= false and raw ~= "false" and raw ~= "False" and raw ~= 0 and raw ~= "0" and raw ~= nil)
    setVar(VAR.CAMERA_ONLINE, online and "true" or "false")

    if online then
        fireEvent("Camera Online")
        setStatus("Online — " .. (cameraName() or ""))
        recordHistory("Camera came online", "Info", "Camera Online")
    else
        fireEvent("Camera Offline")
        setStatus("Offline")
        recordHistory("Camera went offline", "Warning", "Camera Offline")
    end
end

------------------------------------------------------------------------
-- Audio Detection Handler
------------------------------------------------------------------------

--- Map Frigate audio type names to event names.
local AUDIO_EVENTS = {
    speech         = "Audio: Speech",
    bark           = "Audio: Bark",
    scream         = "Audio: Scream",
    yell           = "Audio: Yell",
    fire_alarm     = "Audio: Fire Alarm",
    glass_breaking = "Audio: Glass Breaking",
    siren          = "Audio: Siren",
    car_horn       = "Audio: Car Horn",
    music          = "Audio: Music",
}

--- Handle audio detection from Frigate.
--- tParams: { audio_type="speech" }
local function handleAudio(tParams)
    local audioType = tParams.audio_type or "unknown"
    local friendly = friendlyObject(audioType:gsub("_", " "))
    local ts = timestamp()

    -- Update last-heard timestamps
    setVar(VAR.AUDIO_LAST_HEARD, ts)
    local AUDIO_LAST_HEARD_VARS = {
        speech         = VAR.SPEECH_LAST_HEARD,
        bark           = VAR.BARK_LAST_HEARD,
        scream         = VAR.SCREAM_LAST_HEARD,
        yell           = VAR.YELL_LAST_HEARD,
        fire_alarm     = VAR.FIRE_ALARM_LAST_HEARD,
        glass_breaking = VAR.GLASS_BREAKING_LAST_HEARD,
        siren          = VAR.SIREN_LAST_HEARD,
        car_horn       = VAR.CAR_HORN_LAST_HEARD,
        music          = VAR.MUSIC_LAST_HEARD,
    }
    if AUDIO_LAST_HEARD_VARS[audioType] then
        setVar(AUDIO_LAST_HEARD_VARS[audioType], ts)
    end

    local eventName = AUDIO_EVENTS[audioType]
    if eventName then
        fireEvent(eventName)
    end
    fireEvent("Audio Detected")
    recordHistory("Audio: " .. friendly, "Info", "Audio: " .. friendly)
    C4:UpdateProperty(PROP_LAST_EVENT, "Audio: " .. friendly .. " — " .. ts)
end

------------------------------------------------------------------------
-- State Change Handlers
------------------------------------------------------------------------

--- Handle detection/recording/audio state changes from Frigate.
--- tParams: { setting="detect"|"recordings"|"audio", enabled=true|false }
local function handleStateChange(tParams)
    local setting = tParams.setting or ""
    local raw_enabled = tParams.enabled
    local enabled = (raw_enabled ~= false and raw_enabled ~= "false" and raw_enabled ~= "False" and raw_enabled ~= 0 and raw_enabled ~= "0" and raw_enabled ~= nil)

    if setting == "detect" then
        setVar(VAR.DETECTION_ENABLED, enabled and "true" or "false")
        if enabled then
            fireEvent("Detection Enabled")
            recordHistory("Detection enabled", "Info", "Detection Enabled")
        else
            fireEvent("Detection Disabled")
            recordHistory("Detection disabled", "Warning", "Detection Disabled")
        end
    elseif setting == "recordings" then
        setVar(VAR.RECORDING_ENABLED, enabled and "true" or "false")
        if enabled then
            fireEvent("Recording Enabled")
            recordHistory("Recording enabled", "Info", "Recording Enabled")
        else
            fireEvent("Recording Disabled")
            recordHistory("Recording disabled", "Warning", "Recording Disabled")
        end
    end
end

------------------------------------------------------------------------
-- Notification Attachment (snapshot for push notifications)
------------------------------------------------------------------------

--- Called by the Notification Agent when a push notification fires.
--- Returns the URL to the current snapshot JPEG.
function GetNotificationAttachmentURL(idBinding, tParams)
    local host = Properties[PROP_HOST] or ""
    local cam = cameraName()
    log(LOG_DEBUG, "GetNotificationAttachmentURL called (binding=" .. tostring(idBinding)
        .. " cam=" .. tostring(cam) .. ")")
    if host == "" or not cam then return "" end

    local base = "http://" .. host .. ":" .. PORT_HTTP

    -- "Off" disables event snapshots; an absent or unparseable value defaults
    -- to 60s. Composer does not enforce type constraints, so parse defensively.
    local raw = Properties[PROP_NOTIFY_FRESHNESS]
    local window = (raw == "Off") and 0 or (tonumber(raw) or 60)

    if window > 0 and lastEvent.id and lastEvent.hasSnapshot
       and (os.time() - lastEvent.timestamp) <= window then
        local url = base .. "/api/events/" .. lastEvent.id .. "/snapshot.jpg?bbox=1&h=480"
        log(LOG_DEBUG, "Notification image: event snapshot " .. url)
        return url
    end

    local url = base .. "/api/" .. cam .. "/latest.jpg"
    log(LOG_DEBUG, "Notification image: live snapshot " .. url)
    return url
end

--- Register detection events with the History Agent for push notifications.
local function registerNotificationEvents()
    local proxyDeviceId = proxyDeviceIdForHistory()
    if not proxyDeviceId then
        log(LOG_WARNING, "RegisterEvents skipped — no proxy device id found; "
            .. "history will not surface in the Control4 app")
        return
    end

    -- Registered from HISTORY_EVENTS, so a type that can be recorded is always
    -- one Navigator can match a stored record against. Every type is
    -- registered whatever the category switches say: the switches decide what
    -- gets written, not what Navigator is able to display, so turning one back
    -- on needs no re-registration.
    local typeList = ""
    for _, e in ipairs(HISTORY_EVENTS) do
        typeList = typeList .. '<type name="' .. C4:XmlEscapeString(e[1]) .. '"/>'
    end

    local xml = '<events>'
        .. '<device id="' .. proxyDeviceId .. '"/>'
        .. '<categories><category name="' .. HISTORY_CATEGORY .. '">'
        .. '<subcategories><subcategory name="' .. HISTORY_SUBCATEGORY .. '">'
        .. '<types>' .. typeList .. '</types>'
        .. '</subcategory></subcategories>'
        .. '</category></categories></events>'

    local result = C4:RegisterEvents(xml)
    if result == 0 then
        log(LOG_INFO, "Registered notification events for device " .. proxyDeviceId)
    else
        log(LOG_WARNING, "RegisterEvents returned: " .. tostring(result))
    end
end

------------------------------------------------------------------------
-- Dynamic Stream URL Handlers
------------------------------------------------------------------------

function UIRequest(sCommand, tParams)
    log(LOG_DEBUG, "UIRequest: " .. tostring(sCommand))
    if sCommand == "GET_STREAM_URLS" then
        return getStreamURLs(tParams)
    end
    if sCommand == "GET_SNAPSHOT_QUERY_STRING" then
        return getSnapshotQueryString()
    end
    if sCommand == "GET_MJPEG_QUERY_STRING" then
        return getMJPEGQueryString()
    end
    if sCommand == "GET_RTSP_H264_QUERY_STRING" then
        return getRTSPH264QueryString()
    end
end

function getStreamURLs(tParams)
    local host = Properties[PROP_HOST] or ""
    local cam = cameraName()
    local src = streamName()

    if host == "" or cam == nil then
        setStatus("Not Configured")
        return ""
    end

    local mjpegURL    = "http://" .. host .. ":" .. PORT_HTTP .. "/api/" .. cam
    local snapshotURL = "http://" .. host .. ":" .. PORT_HTTP .. "/api/" .. cam .. "/latest.jpg"
    local rtspURL     = "rtsp://" .. host .. ":" .. PORT_RTSP .. "/" .. (src or cam)

    local key = tParams and tParams["KEY"] or "1"

    local xml = '<streams key="' .. key .. '" camera_address="' .. host .. '">'
    xml = xml .. '<stream url="' .. C4:XmlEscapeString(snapshotURL) .. '" codec="jpeg" />'
    xml = xml .. '<stream url="' .. C4:XmlEscapeString(mjpegURL) .. '" codec="mjpeg" />'
    xml = xml .. '<stream url="' .. C4:XmlEscapeString(rtspURL) .. '" codec="h264" />'
    xml = xml .. '</streams>'

    setStatus("Online — " .. cam)
    return xml
end

------------------------------------------------------------------------
-- Legacy Query String Handlers (fallback for older navigators)
------------------------------------------------------------------------

function getMJPEGQueryString()
    local cam = cameraName()
    if not cam then return "" end
    -- Frigate serves MJPEG at /api/<camera_name> (multipart/x-mixed-replace)
    local path = "api/" .. cam
    return "<mjpeg_query_string>" .. C4:XmlEscapeString(path) .. "</mjpeg_query_string>"
end

function getRTSPH264QueryString()
    local src = streamName()
    if not src then return "" end
    return "<rtsp_h264_query_string>" .. C4:XmlEscapeString(src) .. "</rtsp_h264_query_string>"
end

function getSnapshotQueryString()
    local cam = cameraName()
    if not cam then return "" end
    local path = "api/" .. cam .. "/latest.jpg"
    return "<snapshot_query_string>" .. C4:XmlEscapeString(path) .. "</snapshot_query_string>"
end

------------------------------------------------------------------------
-- Proxy Command Handlers
------------------------------------------------------------------------

function PRX_CMD(idBinding, sCommand, tParams)
    -- Ignore standard camera proxy setup commands — we use our own properties
end

------------------------------------------------------------------------
-- Proxy Update Helper
------------------------------------------------------------------------

--- Check if the camera's snapshot URL is reachable from the controller.
local function checkCameraHealth()
    local host = Properties[PROP_HOST] or ""
    local cam = cameraName()
    if host == "" or not cam then return end

    local snapshotURL = "http://" .. host .. ":" .. PORT_HTTP .. "/api/" .. cam .. "/latest.jpg"
    local mjpegURL = "http://" .. host .. ":" .. PORT_HTTP .. "/api/stream.mjpeg?src=" .. (streamName() or cam)

    log(LOG_DEBUG, "Health check: " .. snapshotURL)

    C4:urlGet(snapshotURL, {}, false, function(ticketId, strData, responseCode, tHeaders, strError)
        if responseCode == 200 and (not strError or strError == "") then
            setStatus("Online — " .. cam)
            log(LOG_INFO, cam .. " snapshot OK (HTTP 200, " .. tostring(#(strData or "")) .. " bytes)")
        else
            local err = (strError and strError ~= "") and strError or ("HTTP " .. tostring(responseCode))
            setStatus("Offline — " .. cam .. " (" .. err .. ")")
            log(LOG_ERROR, cam .. " snapshot FAILED: " .. err)
        end

        log(LOG_DEBUG, "Health check MJPEG: " .. mjpegURL)
    end)
end

--- Update the camera proxy with current address, ports, and stream URLs.
--- Must be called whenever host, camera name, or sub-stream changes.
local function updateProxy()
    local host = Properties[PROP_HOST] or ""
    local cam = cameraName()

    if host ~= "" and cam then
        -- Update proxy address and ports (try both DEFAULT and active notifications)
        C4:SendToProxy(PROXY_ID, "ADDRESS_CHANGED", { ADDRESS = host })
        C4:SendToProxy(PROXY_ID, "HTTP_PORT_CHANGED", { PORT = tostring(PORT_HTTP) })
        C4:SendToProxy(PROXY_ID, "RTSP_PORT_CHANGED", { PORT = tostring(PORT_RTSP) })
        C4:SendToProxy(PROXY_ID, "DEFAULT_HTTP_PORT_CHANGED", { PORT = tostring(PORT_HTTP) })
        C4:SendToProxy(PROXY_ID, "DEFAULT_RTSP_PORT_CHANGED", { PORT = tostring(PORT_RTSP) })
        C4:SendToProxy(PROXY_ID, "AUTHENTICATION_REQUIRED_CHANGED", { REQUIRED = "False" })
        C4:SendToProxy(PROXY_ID, "DEFAULT_AUTHENTICATION_REQUIRED_CHANGED", { REQUIRED = "False" })
        C4:SendToProxy(PROXY_ID, "STREAM_URLS_READY", {})
        log(LOG_INFO, "Proxy updated: " .. host .. ":" .. PORT_HTTP .. "/" .. PORT_RTSP .. " / " .. cam)

        -- Run health check to verify streams are reachable
        checkCameraHealth()
    else
        setStatus("Not Configured")
    end
end

------------------------------------------------------------------------
-- Inter-Driver Command Handler (from NVR parent driver)
------------------------------------------------------------------------

function ExecuteCommand(sCommand, tParams)
    if sCommand == "SET_FRIGATE_CONFIG" then
        if tParams then
            local cam = tParams.camera_name or "(unknown)"
            local sub = tParams.use_sub_stream or "(nil)"
            log(LOG_DEBUG, "SET_FRIGATE_CONFIG: cam=" .. cam .. " sub=" .. sub .. " host=" .. (tParams.host or ""))
            if tParams.host and tParams.host ~= "" then
                C4:UpdateProperty(PROP_HOST, tParams.host)
            end
            if tParams.camera_name and tParams.camera_name ~= "" then
                C4:UpdateProperty(PROP_CAMERA, tParams.camera_name)
            end
            if tParams.use_sub_stream ~= nil then
                C4:UpdateProperty(PROP_SUB_STREAM, tParams.use_sub_stream)
            end
            updateProxy()
        end
    elseif sCommand == "FRIGATE_DETECTION" then
        handleDetection(tParams or {})
    elseif sCommand == "FRIGATE_EVENT" then
        local p = tParams or {}
        if p.event_id and p.event_id ~= "" then
            -- SendToDevice serialises booleans as strings; "false" is truthy
            -- in Lua, so check explicitly (see c4-conventions §2).
            local raw = p.has_snapshot
            local hasSnapshot = (raw ~= false and raw ~= "false" and raw ~= "False"
                                 and raw ~= 0 and raw ~= "0" and raw ~= nil)
            lastEvent.id          = p.event_id
            lastEvent.hasSnapshot = hasSnapshot
            lastEvent.timestamp   = os.time()
            log(LOG_DEBUG, "Cached event " .. p.event_id
                .. " (snapshot=" .. tostring(hasSnapshot) .. ")")
        end
    elseif sCommand == "FRIGATE_MOTION" then
        handleMotion(tParams or {})
    elseif sCommand == "FRIGATE_ZONE" then
        handleZone(tParams or {})
    elseif sCommand == "FRIGATE_LOITERING" then
        handleLoitering(tParams or {})
    elseif sCommand == "FRIGATE_HEALTH" then
        handleHealth(tParams or {})
    elseif sCommand == "FRIGATE_AUDIO" then
        handleAudio(tParams or {})
    elseif sCommand == "FRIGATE_REVIEW" then
        handleReview(tParams)
    elseif sCommand == "FRIGATE_OBJECT_DESCRIPTION" then
        handleObjectDescription(tParams)
    elseif sCommand == "FRIGATE_STATE" then
        handleStateChange(tParams or {})
    elseif sCommand == "IDENTIFY_CAMERA" then
        -- NVR driver is asking us what camera we are (for orphan adoption)
        local parentId = tParams and tonumber(tParams.parent_device_id) or nil
        local cam = Properties[PROP_CAMERA] or ""
        if parentId and cam ~= "" then
            C4:SendToDevice(parentId, "ADOPT_RESPONSE", {
                camera_name = cam,
                device_id = C4:GetDeviceID()
            })
        end
    end
end

------------------------------------------------------------------------
-- Property Change Handler
------------------------------------------------------------------------

function OnPropertyChanged(sProperty)
    if sProperty == PROP_HOST or sProperty == PROP_CAMERA or sProperty == PROP_SUB_STREAM then
        updateProxy()
    elseif sProperty == PROP_TIMELINE then
        refreshTimelineStatus()
    end
end

------------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------------

function OnDriverLateInit()
    C4:UpdateProperty(PROP_VERSION, C4:GetDriverConfigInfo("version") or "23")

    -- Initialize variables for Composer programming
    initVariables()

    -- Register events for push notification support
    registerNotificationEvents()

    -- Update proxy with current config (address, ports, stream URLs)
    updateProxy()

    -- Agents are not always up when a driver loads, so look again shortly
    -- after rather than reporting "not installed" for the rest of the session.
    -- This applies to the History agent as much as the Timeline one: without
    -- it, every entry silently loses its picture for the rest of the session.
    refreshTimelineStatus()
    C4:SetTimer(15000, function()
        resolveTimeline(true)
        refreshTimelineStatus()
        resolveHistoryAgent(true)
    end)
end

function OnDriverDestroyed()
    -- Variables are cleaned up automatically by the system
end
