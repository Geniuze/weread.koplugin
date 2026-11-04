-- Focused tests for the end-of-book flow on WeRead books: a single-chapter
-- file with a successor opens the next chapter directly, every other case
-- keeps the quick menu (which reports the last chapter itself).

package.path = "./?.lua;" .. package.path

local dialog_shown
package.preload["weread.ui.end_of_book_dialog"] = function()
    return { show = function() dialog_shown = true end }
end
package.preload["weread.lib.content"] = function() return {} end
package.preload["weread.lib.logger"] = function()
    return { scoped = function() return {} end }
end
package.preload["weread.lib.protocol"] = function()
    return { is_mp_book = function() return false end }
end
package.preload["ui/uimanager"] = function() return {} end
package.preload["weread.lib.plugin_util"] = function()
    return { tr = function(text) return text end, T = function(text) return text end }
end

local Lifecycle = require("weread.lib.reader_lifecycle")

local checks, failures = 0, 0
local function expect(value, label)
    checks = checks + 1
    if not value then
        failures = failures + 1
        print("FAIL " .. label)
    end
end

local G_reader_settings

local function make_host(chapters, chapter_info)
    local host
    host = {
        ui = { document = { file = "/cache/wr-1/ch2.html" } },
        settings = { get = function() return { ["wr-1"] = { book_id = "wr-1" } } end },
        detectWeReadBook = function() return "wr-1" end,
        ensureChaptersLoaded = function(_self, book)
            book.chapters = chapters
            return chapters
        end,
        getChapterInfoFromFile = function()
            return chapter_info[1], chapter_info[2], chapter_info[3]
        end,
        openChapter = function(_self, book, chapter)
            host.opened = { book = book, chapter = chapter }
        end,
        showEndOfBookDialog = function(_self, book_id)
            host.dialog_book_id = book_id
            return true
        end,
        showInfo = function(_self, text) host.info = text end,
    }
    for key, value in pairs(Lifecycle) do
        if host[key] == nil then host[key] = value end
    end
    host._orig_onEndOfBook = function()
        host.fell_back = true
        return true
    end
    return host
end

local chapters = {
    { chapterUid = 1 }, { chapterUid = 2 }, { chapterUid = 3 },
}

-- end_document_action is irrelevant now: a successor opens directly, the
-- quick menu handles every remaining case. Assert both global settings.
for _, action in ipairs({ "pop-up", "next_file" }) do
    G_reader_settings = { readSetting = function() return action end }
    _G.G_reader_settings = G_reader_settings

    local host = make_host(chapters, { 2, chapters[2], false })
    host:handleEndOfBook({})
    expect(host.opened ~= nil and host.opened.chapter == chapters[3],
        action .. ": successor chapter opens directly, no dialog")
    expect(dialog_shown ~= true,
        action .. ": quick menu is skipped when a successor exists")

    host = make_host(chapters, { #chapters, chapters[#chapters], false })
    host:handleEndOfBook({})
    expect(host.opened == nil and host.dialog_book_id == "wr-1",
        action .. ": last chapter still shows the quick menu")

    host = make_host(chapters, { nil, nil, true })
    host:handleEndOfBook({})
    expect(host.opened == nil and host.dialog_book_id == "wr-1",
        action .. ": full-book EPUB still shows the quick menu")
end

print(string.format(
    "reader_end_of_book_flow_spec: %d checks, %d failure(s)",
    checks, failures))
os.exit(failures == 0 and 0 or 1)
