-- Standalone harness for the NVR driver's frigate/events JSON parsing.
--
-- Separate from driver_test.lua because the NVR needs different C4 mocks and
-- must NOT have OnDriverLateInit() called (that would start MQTT and timers).
--
-- Usage: lua test/nvr_test.lua nvr-driver/driver.lua

local driverPath = arg[1] or error("usage: lua test/nvr_test.lua <driver.lua>")

sent = {}          -- captured C4:SendToDevice calls

C4 = {}
function C4:SendToDevice(deviceId, command, params)
    sent[#sent + 1] = { deviceId = deviceId, command = command, params = params }
end
-- The NVR resolves a camera name to a device id through its persisted
-- managed-cameras table; seed it so sendToCamera() finds "bbq".
function C4:PersistGetValue(key)
    if key == "managed_cameras" then
        return { bbq = { deviceId = 1586, proxyId = 5001 } }
    end
    return nil
end
function C4:PersistSetValue(key, value) end
function C4:UpdateProperty(name, value) end
function C4:GetDeviceID() return 1000 end
function C4:ErrorLog(msg) end
function C4:AddTimer() return 0 end
function C4:KillTimer() end
function C4:urlGet() return 0 end
function C4:GetDriverConfigInfo() return "" end
function C4:AddDevice() return 0 end
function C4:RenameDevice() end
function C4:RoomGetId() return 0 end
function C4:GetDevicesByC4iName() return {} end
function C4:CreateTCPClient() return { OnConnect = function() end,
                                       OnError = function() end,
                                       Connect = function() end } end
function C4:MQTT() return nil end
function C4:FileExists() return false end
function C4:FileSetDir() return 0 end
function C4:FileOpen() return nil end
function C4:FileWrite() end
function C4:FileClose() end
function C4:FileDelete() end
function C4:FileSetPos() end
function C4:Base() return {} end

Properties = {
    ["Frigate Host"] = "192.168.1.50",
    ["Log Level"]    = "1 - Error",
    ["Log Mode"]     = "Off",
}

local realWrite = io.write
print = function() end
dofile(driverPath)

local failures = 0
local function check(desc, ok, detail)
    realWrite(string.format("%-58s %s\n", desc, ok and "PASS" or ("FAIL  " .. tostring(detail))))
    if not ok then failures = failures + 1 end
end

local function findSent(command)
    for _, s in ipairs(sent) do if s.command == command then return s end end
    return nil
end

------------------------------------------------------------------------
-- A realistic frigate/events payload. Note has_snapshot is false in
-- `before` and true in `after` — reading it from `before` is the bug this
-- test exists to catch.
------------------------------------------------------------------------
local payload = [[
{"type":"update",
 "before":{"id":"1755012345.678901-abc123","camera":"bbq","label":"person",
           "current_zones":["driveway"],"has_snapshot":false,"has_clip":false},
 "after":{"id":"1755012345.678901-abc123","camera":"bbq","label":"person",
          "current_zones":["driveway"],"has_snapshot":true,"has_clip":true}}
]]

sent = {}
local ok, err = pcall(handleEventJSON, payload)
check("handleEventJSON does not raise", ok, err)

local ev = findSent("FRIGATE_EVENT")
check("sends FRIGATE_EVENT", ev ~= nil)
check("routed to the camera's device id", ev and ev.deviceId == 1586, ev and ev.deviceId)
check("event_id extracted", ev and ev.params.event_id == "1755012345.678901-abc123",
      ev and ev.params.event_id)
check("has_snapshot read from `after`, not `before`",
      ev and ev.params.has_snapshot == true, ev and tostring(ev.params.has_snapshot))
check("label forwarded", ev and ev.params.label == "person", ev and ev.params.label)

------------------------------------------------------------------------
-- has_snapshot false in BOTH objects must forward false
------------------------------------------------------------------------
sent = {}
pcall(handleEventJSON, [[
{"type":"new",
 "before":{"id":"1755000000.0-nosnap","camera":"bbq","label":"car","has_snapshot":false},
 "after":{"id":"1755000000.0-nosnap","camera":"bbq","label":"car","has_snapshot":false}}
]])
ev = findSent("FRIGATE_EVENT")
check("has_snapshot false forwarded as false",
      ev and ev.params.has_snapshot == false, ev and tostring(ev.params.has_snapshot))

------------------------------------------------------------------------
-- Inverted payload: has_snapshot true in `before`, false in `after`.
-- This is the one shape that discriminates a scoped `after`-only read
-- from an unscoped whole-payload read (jsonBool matches only "key":true,
-- so it would find the `before` true and forward the wrong value).
------------------------------------------------------------------------
sent = {}
pcall(handleEventJSON, [[
{"type":"update",
 "before":{"id":"1755000001.0-inverted","camera":"bbq","label":"car","has_snapshot":true},
 "after":{"id":"1755000001.0-inverted","camera":"bbq","label":"car","has_snapshot":false}}
]])
ev = findSent("FRIGATE_EVENT")
check("has_snapshot read from `after` when `before` is true and `after` is false",
      ev and ev.params.has_snapshot == false, ev and tostring(ev.params.has_snapshot))

------------------------------------------------------------------------
-- Malformed and empty payloads must not raise and must not send
------------------------------------------------------------------------
sent = {}
ok = pcall(handleEventJSON, "not json at all")
check("malformed payload does not raise", ok)
check("malformed payload sends nothing", findSent("FRIGATE_EVENT") == nil)

sent = {}
ok = pcall(handleEventJSON, "")
check("empty payload does not raise", ok)
check("empty payload sends nothing", findSent("FRIGATE_EVENT") == nil)

------------------------------------------------------------------------
-- Regression: loitering detection still works from the same payload
------------------------------------------------------------------------
sent = {}
pcall(handleEventJSON, [[
{"type":"update",
 "before":{"id":"1755999999.0-loiter","camera":"bbq","label":"person",
           "current_zones":["driveway"],"loitering":false,"has_snapshot":true},
 "after":{"id":"1755999999.0-loiter","camera":"bbq","label":"person",
          "current_zones":["driveway"],"loitering":true,"has_snapshot":true}}
]])
local loiter = findSent("FRIGATE_LOITERING")
check("loitering still detected", loiter ~= nil)
check("loitering zone forwarded", loiter and loiter.params.zone == "driveway",
      loiter and loiter.params.zone)

------------------------------------------------------------------------
-- frigate/reviews
------------------------------------------------------------------------
-- A review segment that has just ended, before any GenAI summary exists.
sent = {}
local okEnd = pcall(handleReviewJSON, [[
{"type":"end",
 "before":{"id":"1755012345.1-rev","camera":"bbq","severity":"alert",
           "start_time":1755012345.5,"end_time":null,
           "data":{"objects":["person"],"sub_labels":[],"zones":["driveway"],
                   "detections":["1755012345.1-abc"]}},
 "after":{"id":"1755012345.1-rev","camera":"bbq","severity":"alert",
          "start_time":1755012345.5,"end_time":1755012399.0,
          "data":{"objects":["person","car"],"sub_labels":["Joe"],
                  "zones":["driveway","street"],
                  "detections":["1755012345.1-abc"]}}}
]])
check("handleReviewJSON does not raise", okEnd, err)
local rev = findSent("FRIGATE_REVIEW")
check("sends FRIGATE_REVIEW", rev ~= nil)
check("routed to the camera's device id", rev and rev.deviceId == 1586,
      rev and rev.deviceId)
check("forwards the review id",
      rev and rev.params.id == "1755012345.1-rev", rev and rev.params.id)
check("forwards the message type", rev and rev.params.review_type == "end")
check("forwards the severity", rev and rev.params.severity == "alert")
-- Fields must come from `after`, not the first match inside `before`.
check("objects come from after, not before",
      rev and rev.params.objects == "person, car", rev and rev.params.objects)
check("sub labels come from after",
      rev and rev.params.sub_labels == "Joe", rev and rev.params.sub_labels)
check("zones come from after",
      rev and rev.params.zones == "driveway, street", rev and rev.params.zones)
check("start time is forwarded as a number",
      rev and rev.params.start_time == 1755012345.5, rev and rev.params.start_time)
check("no summary yet", rev and rev.params.title == "", rev and rev.params.title)

-- The GenAI summary, published separately once it has been generated.
sent = {}
pcall(handleReviewJSON, [[
{"type":"genai",
 "before":{"id":"1755012345.1-rev","camera":"bbq","severity":"alert",
           "start_time":1755012345.5,
           "data":{"objects":["person"],"sub_labels":[],"zones":[]}},
 "after":{"id":"1755012345.1-rev","camera":"bbq","severity":"alert",
          "start_time":1755012345.5,
          "data":{"objects":["person"],"sub_labels":[],"zones":[],
                  "metadata":{"title":"Person taking out trash",
                              "scene":"A person walks from the side gate...",
                              "shortSummary":"Someone took the bins out.",
                              "confidence":0.92,"other_concerns":[],
                              "potential_threat_level":0}}}}
]])
local gen = findSent("FRIGATE_REVIEW")
check("the genai message is forwarded", gen ~= nil)
check("message type is genai", gen and gen.params.review_type == "genai")
check("the title is extracted from data.metadata",
      gen and gen.params.title == "Person taking out trash", gen and gen.params.title)
check("the short summary is extracted",
      gen and gen.params.summary == "Someone took the bins out.", gen and gen.params.summary)
check("the threat level is extracted",
      gen and gen.params.threat_level == 0, gen and gen.params.threat_level)

-- A raised threat level must survive, not be read as the default.
sent = {}
pcall(handleReviewJSON, [[
{"type":"genai","before":{},
 "after":{"id":"r2","camera":"bbq","severity":"alert","start_time":1,
          "data":{"objects":["person"],
                  "metadata":{"title":"Someone trying door handles",
                              "shortSummary":"A person tried several doors.",
                              "potential_threat_level":2}}}}
]])
local threat = findSent("FRIGATE_REVIEW")
check("a raised threat level is forwarded",
      threat and threat.params.threat_level == 2, threat and threat.params.threat_level)

-- Interim messages are noise: one incident should not produce several entries.
sent = {}
pcall(handleReviewJSON, [[
{"type":"new","before":{},"after":{"id":"r3","camera":"bbq","severity":"alert",
 "start_time":1,"data":{"objects":["person"]}}}
]])
check("a 'new' review is not forwarded", findSent("FRIGATE_REVIEW") == nil)
sent = {}
pcall(handleReviewJSON, [[
{"type":"update","before":{},"after":{"id":"r3","camera":"bbq","severity":"alert",
 "start_time":1,"data":{"objects":["person"]}}}
]])
check("an 'update' review is not forwarded", findSent("FRIGATE_REVIEW") == nil)

sent = {}
check("a review with no camera does not raise",
      pcall(handleReviewJSON, [[{"type":"end","after":{"id":"r4","severity":"alert"}}]]))
check("a review with no camera is dropped", findSent("FRIGATE_REVIEW") == nil)
check("an empty review payload does not raise", pcall(handleReviewJSON, ""))

------------------------------------------------------------------------
-- frigate/tracked_object_update
------------------------------------------------------------------------
sent = {}
local okDesc = pcall(handleObjectDescription,
  [[{"type":"description","id":"1755012345.1-abc","camera":"bbq",
     "description":"A delivery driver leaves a parcel by the door."}]])
check("handleObjectDescription does not raise", okDesc)
local desc = findSent("FRIGATE_OBJECT_DESCRIPTION")
check("sends FRIGATE_OBJECT_DESCRIPTION", desc ~= nil)
check("routed to the camera's device id", desc and desc.deviceId == 1586)
check("forwards the description text",
      desc and desc.params.description == "A delivery driver leaves a parcel by the door.",
      desc and desc.params.description)
check("forwards the tracked object id",
      desc and desc.params.id == "1755012345.1-abc", desc and desc.params.id)

-- tracked_object_update carries other types too; only descriptions matter here.
sent = {}
pcall(handleObjectDescription,
  [[{"type":"end","id":"1755012345.1-abc","camera":"bbq"}]])
check("a non-description update is ignored",
      findSent("FRIGATE_OBJECT_DESCRIPTION") == nil)
sent = {}
pcall(handleObjectDescription,
  [[{"type":"description","id":"x","camera":"bbq","description":""}]])
check("an empty description is ignored",
      findSent("FRIGATE_OBJECT_DESCRIPTION") == nil)

------------------------------------------------------------------------
-- Zone topics are not cameras
------------------------------------------------------------------------
-- Frigate publishes zone counts on frigate/<zone>/<object>, the same shape
-- as frigate/<camera>/<object>. Without the configured zone names, every
-- zone looked like a camera that did not exist.
local CONFIG = [[
{"mqtt":{"host":"192.168.1.146","port":1883},
 "cameras":{
   "bbq":{"ffmpeg":{"inputs":[{"path":"rtsp://x","roles":["detect"]}]},
          "detect":{"width":1280,"height":720},
          "zones":{"valid_area":{"coordinates":"0,0,1,1"},
                   "valid_area_bottom":{"coordinates":"0,0,1,1"}}},
   "driveway":{"ffmpeg":{"inputs":[]},
               "zones":{"street":{"coordinates":"0,0,1,1"}}},
   "nozones":{"ffmpeg":{"inputs":[]}}}}
]]
buildZoneMap(CONFIG, { "bbq", "driveway", "nozones" })
check("a camera's zones are mapped to it",
      zoneToCamera["valid_area"] == "bbq"
      and zoneToCamera["valid_area_bottom"] == "bbq",
      tostring(zoneToCamera["valid_area"]))
check("each camera's zones map to that camera",
      zoneToCamera["street"] == "driveway", tostring(zoneToCamera["street"]))
check("a camera with no zones adds none", zoneToCamera["nozones"] == nil)
check("camera names are not treated as zones", zoneToCamera["bbq"] == nil)
-- The walker must skip into zones only, not pick up sibling config keys.
check("sibling config keys are not mistaken for zones",
      zoneToCamera["ffmpeg"] == nil and zoneToCamera["detect"] == nil
      and zoneToCamera["coordinates"] == nil,
      tostring(zoneToCamera["detect"]))

-- The live symptom: a zone count arriving as if it were a camera.
sent = {}
onMQTTMessageForTest("frigate/valid_area/person", "1")
local z = findSent("FRIGATE_ZONE")
check("a zone count is routed as a zone event", z ~= nil)
check("it goes to the camera that owns the zone",
      z and z.deviceId == 1586, z and z.deviceId)
check("the zone name is forwarded", z and z.params.zone == "valid_area",
      z and z.params.zone)
check("the object type is forwarded", z and z.params.object_type == "person",
      z and z.params.object_type)
check("the count is forwarded as a number", z and z.params.count == 1,
      z and z.params.count)
check("a zone is never reported as an unmatched camera",
      findSent("FRIGATE_DETECTION") == nil)

-- Zero means the zone cleared, which the camera driver reads as an exit.
sent = {}
onMQTTMessageForTest("frigate/valid_area/person", "0")
local zc = findSent("FRIGATE_ZONE")
check("a cleared zone is forwarded with count 0",
      zc and zc.params.count == 0, zc and zc.params.count)

-- A real camera must still be routed as a camera.
sent = {}
onMQTTMessageForTest("frigate/bbq/person", "1")
check("a camera count is still a detection", findSent("FRIGATE_DETECTION") ~= nil)
check("a camera count is not a zone event", findSent("FRIGATE_ZONE") == nil)

-- Other zone sub-topics must not fall through and look like a camera.
sent = {}
onMQTTMessageForTest("frigate/valid_area/person/active", "1")
check("a zone's /active topic is swallowed, not mistaken for a camera",
      #sent == 0, #sent)

-- MQTT connects before the config fetch returns and Frigate's zone counts are
-- retained, so a zone is usually recorded as an unmatched camera first.
-- Nothing else would ever clear it: unmatched entries are only cleared when a
-- name resolves to a camera device, which a zone never does.
zoneToCamera = {}
sent = {}
onMQTTMessageForTest("frigate/valid_area/person", "1")
check("before the config arrives, a zone is recorded as unmatched",
      unmatchedForTest()["valid_area"] == true)
buildZoneMap(CONFIG, { "bbq", "driveway", "nozones" })
check("learning the zones clears them from the unmatched list",
      unmatchedForTest()["valid_area"] == nil
      and unmatchedForTest()["valid_area_bottom"] == nil)
check("a genuinely unknown name is left in the unmatched list",
      (function()
          zoneToCamera = {}
          sent = {}
          onMQTTMessageForTest("frigate/not_a_camera/person", "1")
          buildZoneMap(CONFIG, { "bbq", "driveway", "nozones" })
          return unmatchedForTest()["not_a_camera"] == true
      end)())

-- An unknown name is still an unmatched camera, which is the real warning.
sent = {}
onMQTTMessageForTest("frigate/not_a_thing/person", "1")
check("an unknown name is still treated as a camera",
      findSent("FRIGATE_ZONE") == nil)

realWrite(failures == 0 and "\nALL PASS\n" or ("\n" .. failures .. " FAILURE(S)\n"))
os.exit(failures == 0 and 0 or 1)
