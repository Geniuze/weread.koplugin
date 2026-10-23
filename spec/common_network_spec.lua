-- Unit tests for shared network task behavior.

package.path = "./?.lua;" .. package.path

local checks = 0

local function eq(got, want, label)
    checks = checks + 1
    if got ~= want then
        error(string.format("%s: got %s, want %s",
            label, tostring(got), tostring(want)))
    end
end

package.preload["ui/bidi"] = function() return {} end
package.preload["ui/widget/confirmbox"] = function() return {} end
package.preload["ui/widget/infomessage"] = function() return {} end
package.preload["ui/widget/menu"] = function() return {} end
package.preload["ui/uimanager"] = function()
    return {
        scheduleIn = function(_self, _delay, callback) callback() end,
    }
end
local network_state = { connected = false, online = false }
package.preload["ui/network/manager"] = function()
    return {
        isOnline = function() return network_state.online end,
        isConnected = function() return network_state.connected end,
    }
end
package.preload["weread.lib.logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
package.preload["weread.lib.plugin_util"] = function()
    return {
        tr = function(text) return text end,
        T = function(text) return text end,
        log_error = tostring,
        display_error = tostring,
        unpack_args = function(args) return unpack(args) end,
    }
end

local Common = require("weread.ui.common")
local offline_notices = 0
local host = setmetatable({
    showOffline = function()
        offline_notices = offline_notices + 1
    end,
}, { __index = Common })

-- Offline (no link): the task must not start.
eq(host:runOnlineTask("automatic", function() end, nil, {
    silent_offline = true,
}), false, "silent offline task does not start")
eq(offline_notices, 0, "silent offline task does not show a notice")

eq(host:runOnlineTask("manual", function() end), false,
    "regular offline task does not start")
eq(offline_notices, 1, "regular offline task still shows a notice")

-- Link connected but DNS broken (isOnline false, isConnected true): the old
-- gate blocked the UI thread on DNS resolution. The task must start; the
-- broken DNS then surfaces inside the request with a bounded timeout.
network_state.connected = true
offline_notices = 0
local ran = false
eq(host:runOnlineTask("dns-broken", function() ran = true end), true,
    "link-connected task with broken DNS must not be gated")
eq(ran, true, "link-connected task did not run")
eq(offline_notices, 0, "link-connected task showed an offline notice")

print(string.format("common_network_spec: %d checks", checks))
