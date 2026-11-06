-- Focused tests for start-of-chapter backward navigation: a backward page
-- turn at the very start of a single downloaded chapter opens the previous
-- chapter; every other case falls through to the native page turn.

package.path = "./?.lua;" .. package.path

package.preload["weread.lib.content"] = function() return {} end
package.preload["weread.lib.logger"] = function()
    return { scoped = function() return {} end }
end
package.preload["weread.lib.protocol"] = function()
    return { is_mp_book = function() return false end }
end
package.preload["ui/uimanager"] = function() return {} end
package.preload["weread.lib.plugin_util"] = function()
    return {
        tr = function(text) return text end,
        T = function(text) return text end,
        display_error = tostring,
        file_exists = function() return false end,
        log_error = tostring,
        catalog_healed = setmetatable({}, { __mode = "v" }),
    }
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

local function make_host(chapters, chapter_info, opts)
    opts = opts or {}
    local host
    host = {
        _current_weread_book_id = "wr-1",
        ui = {
            document = { file = "/cache/wr-1/ch2.epub" },
            view = { view_mode = opts.view_mode or "scroll" },
            rolling = { onGotoViewRel = function(_, diff)
                host.native_calls[#host.native_calls + 1] = diff
                return true
            end },
        },
        settings = {
            get = function(_self, key)
                if key == "books" then
                    return { ["wr-1"] = { book_id = "wr-1", chapters = chapters } }
                end
                return nil
            end,
        },
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
        native_calls = {},
    }
    for key, value in pairs(Lifecycle) do
        if host[key] == nil then host[key] = value end
    end
    return host
end

local chapters = {
    { chapterUid = 1 }, { chapterUid = 2 }, { chapterUid = 3 },
}
local host

-- scroll mode: position probe decides "at start"
host = make_host(chapters, { 2, chapters[2], false })
host.getCurrentPos = function() return 0 end
host.ui.document.getCurrentPos = function() return 0 end
expect(host:_installStartOfChapterTurn(), "rolling handler installs on a WeRead book")
expect(host:_openPrevChapterAtStart(),
    "backward turn at scroll start resolves the previous chapter")
expect(host.opened ~= nil and host.opened.chapter == chapters[1]
        and host.opened.book.book_id == "wr-1",
    "scroll start opens chapters[1] of the same book")
expect(#host.native_calls == 0, "native turn is skipped when navigation fired")

host.getCurrentPos = function() return 0 end
host.ui.document.getCurrentPos = function() return 400 end
host.opened = nil
host.ui.rolling.onGotoViewRel(host.ui.rolling, -1)
expect(host.opened == nil,
    "mid-chapter backward turn does not navigate")
expect(#host.native_calls == 1 and host.native_calls[1] == -1,
    "mid-chapter turn falls through to the native handler")

-- ctx memoization: repeated start turns without an intervening file change
-- must not re-resolve (no ensureChaptersLoaded chatter per turn)
host.ui.document.getCurrentPos = function() return 0 end
host.ensure_calls = 0
host.ensureChaptersLoaded = function(_self, book)
    host.ensure_calls = host.ensure_calls + 1
    book.chapters = chapters
    return chapters
end
expect(host:_openPrevChapterAtStart() and host.ensure_calls == 0,
    "start-turn context is memoized across turns")

-- page mode: first visible page counts as start
host = make_host(chapters, { 2, chapters[2], false })
host.ui.view.view_mode = "page"
host.ui.document.getVisiblePageNumberCount = function() return 1 end
host.ui.document.getCurrentPage = function() return 1 end
expect(host:_openPrevChapterAtStart() and host.opened.chapter == chapters[1],
    "page-mode first page opens the previous chapter")
host.ui.document.getCurrentPage = function() return 2 end
expect(not host:_openPrevChapterAtStart(), "page-mode second page does not navigate")

-- first chapter: no predecessor, no navigation
host = make_host(chapters, { 1, chapters[1], false })
host.ui.document.getCurrentPos = function() return 0 end
expect(host:_installStartOfChapterTurn(),
    "handler reinstalls for a new document")
expect(not host:_openPrevChapterAtStart(),
    "first chapter has no predecessor to open")

-- full-book EPUB: never navigates
host = make_host(chapters, { nil, nil, true })
host.ui.document.getCurrentPos = function() return 0 end
expect(not host:_openPrevChapterAtStart(),
    "full-book EPUB keeps native backward turns")

-- non-WeRead document: no book, no navigation
host = make_host(chapters, { nil, nil, false })
host._current_weread_book_id = nil
host.detectWeReadBook = function() return nil end
host.ui.document.getCurrentPos = function() return 0 end
expect(not host:_openPrevChapterAtStart(),
    "non-WeRead document never navigates")

-- wrapper honors the native handler for forward turns
host = make_host(chapters, { 2, chapters[2], false })
host.ui.document.getCurrentPos = function() return 0 end
host:_installStartOfChapterTurn()
expect(host.ui.rolling.onGotoViewRel(host.ui.rolling, 1),
    "forward turns delegate to the native handler")

-- teardown restores the original handler
expect(host:_removeStartOfChapterTurn() == nil,
    "teardown returns nil")
expect(type(host.ui.rolling.onGotoViewRel) == "function",
    "native rolling handler is restored after teardown")

print(string.format(
    "reader_start_of_chapter_turn_spec: %d checks, %d failure(s)",
    checks, failures))
os.exit(failures == 0 and 0 or 1)
